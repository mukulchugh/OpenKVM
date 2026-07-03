import ApplicationServices
import Cocoa

private let hotkeyKeyCode: CGKeyCode = 40 // 'K'

/// A portable mouse action sent over the wire. Movement is a relative delta so it
/// works regardless of the two Macs' differing screen sizes and cursor positions.
struct MousePayload: Sendable {
    var kind: String
    var dx: Double = 0
    var dy: Double = 0
    var scrollDX: Int64 = 0
    var scrollDY: Int64 = 0
    var button: Int64 = 0
}

/// Captures every keystroke on the Mac the physical keyboard is attached to (the
/// "owner") and forwards it to the peer Mac over PeerNetwork instead of letting it
/// reach local apps. The peer replays the events with CGEvent injection. A fixed
/// global hotkey (⌘⇧K) toggles forwarding on/off and is always handled locally,
/// even while forwarding, so the user is never locked out of the owner Mac.
@MainActor
final class InputBridge: ObservableObject {
    static let shared = InputBridge()
    static let hotkeyDisplay = "⌘⇧K"

    @Published private(set) var isForwarding = false
    @Published private(set) var canCapture = false // Accessibility + Input Monitoring
    @Published private(set) var canPost = false    // synthesize events on this Mac
    @Published private(set) var isReceivingFromPeer = false
    @Published var lastMessage: String?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var receivingResetTask: Task<Void, Never>?
    private var promptedForPermissions = false

    private init() {}

    /// macOS tracks three separate TCC permissions here: Accessibility,
    /// Input Monitoring (kTCCServiceListenEvent, needed to capture), and
    /// PostEvent (needed to inject). AXIsProcessTrusted() only covers the first —
    /// the CG preflight/request APIs are the correct checks for the other two.
    func refreshPermissions() {
        canCapture = CGPreflightListenEventAccess() && AXIsProcessTrusted()
        canPost = CGPreflightPostEventAccess()
    }

    func requestPermissionsIfNeeded() {
        refreshPermissions()
        guard !promptedForPermissions else { return }
        promptedForPermissions = true
        requestPermissions()
    }

    func requestPermissions() {
        refreshPermissions()
        if !canPost {
            _ = CGRequestPostEventAccess()
        }
        if !canCapture {
            _ = CGRequestListenEventAccess()
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
        refreshPermissions()
        // If we now have permission (e.g. granted via System Settings), try to activate capture
        if ConfigStore.shared.config.isKeyboardOwner && canCapture {
            installTapIfNeeded()
        }
    }

    // MARK: - Owner side (capture + forward)

    func updateOwnerState() {
        if ConfigStore.shared.config.isKeyboardOwner {
            installTapIfNeeded()
        } else {
            removeTap()
            if isForwarding {
                Task { await toggleForwarding() }
            }
        }
    }

    /// Call this from Refresh or after user indicates permissions were granted externally.
    /// Removes any existing tap (to clear stale state) and re-attempts creation.
    func forceReinstallTap() {
        removeTap()
        refreshPermissions()
        if ConfigStore.shared.config.isKeyboardOwner {
            installTapIfNeeded()
        }
    }

    private func installTapIfNeeded() {
        refreshPermissions()
        guard eventTap == nil else { return }

        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.mouseMoved.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.rightMouseUp.rawValue) |
            (1 << CGEventType.rightMouseDragged.rawValue) |
            (1 << CGEventType.otherMouseDown.rawValue) |
            (1 << CGEventType.otherMouseUp.rawValue) |
            (1 << CGEventType.otherMouseDragged.rawValue) |
            (1 << CGEventType.scrollWheel.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passRetained(event) }
                let bridge = Unmanaged<InputBridge>.fromOpaque(refcon).takeUnretainedValue()
                return bridge.handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            canCapture = false
            lastMessage = "Event tap creation failed. If you already granted Accessibility + Input Monitoring, quit KeySwitch completely and relaunch. Then click Refresh."
            return
        }

        eventTap = tap
        canCapture = true
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func removeTap() {
        guard let tap = eventTap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    private nonisolated func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            Task { @MainActor in
                if let tap = self.eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            }
            return Unmanaged.passRetained(event)
        }

        let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags

        if type == .keyDown, keyCode == hotkeyKeyCode, flags.contains([.maskCommand, .maskShift]) {
            Task { @MainActor in await self.toggleForwarding() }
            return nil
        }

        guard isForwardingSnapshot else { return Unmanaged.passRetained(event) }

        // The tap runs on the main run loop, so send synchronously — no actor hop.
        // connection.send() itself is async internally, so this doesn't block.
        if let mouse = mousePayload(type: type, event: event) {
            PeerNetwork.shared.sendMouseEvent(mouse)
            return nil
        }

        PeerNetwork.shared.sendKeyEvent(
            keyCode: keyCode,
            keyDown: type != .keyUp,
            flags: flags.rawValue,
            isFlagsChanged: type == .flagsChanged
        )
        return nil
    }

    /// Translate a captured mouse CGEvent into a portable payload (relative deltas,
    /// not absolute position, since the two Macs have different screen geometry).
    private nonisolated func mousePayload(type: CGEventType, event: CGEvent) -> MousePayload? {
        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            return MousePayload(
                kind: "move",
                dx: Double(event.getIntegerValueField(.mouseEventDeltaX)),
                dy: Double(event.getIntegerValueField(.mouseEventDeltaY))
            )
        case .leftMouseDown:  return MousePayload(kind: "leftDown")
        case .leftMouseUp:    return MousePayload(kind: "leftUp")
        case .rightMouseDown: return MousePayload(kind: "rightDown")
        case .rightMouseUp:   return MousePayload(kind: "rightUp")
        case .otherMouseDown: return MousePayload(kind: "otherDown", button: event.getIntegerValueField(.mouseEventButtonNumber))
        case .otherMouseUp:   return MousePayload(kind: "otherUp", button: event.getIntegerValueField(.mouseEventButtonNumber))
        case .scrollWheel:
            return MousePayload(
                kind: "scroll",
                scrollDX: event.getIntegerValueField(.scrollWheelEventDeltaAxis2),
                scrollDY: event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
            )
        default:
            return nil
        }
    }

    /// Read from a non-isolated context inside the tap callback. Safe: only ever
    /// written on the main thread, and the tap's run loop source is on the main run loop.
    private nonisolated var isForwardingSnapshot: Bool {
        MainActor.assumeIsolated { isForwarding }
    }

    func toggleForwarding() async {
        if isForwarding {
            PeerNetwork.shared.stopKeyForwarding()
            isForwarding = false
            lastMessage = "Keyboard & mouse are local."
            return
        }

        guard ConfigStore.shared.isConfigured else {
            lastMessage = "Set the other Mac + pairing token in Settings first."
            return
        }
        let ok = await PeerNetwork.shared.beginKeyForwarding(config: ConfigStore.shared.config)
        isForwarding = ok
        lastMessage = ok
            ? "Controlling \(ConfigStore.shared.config.peerHostName.isEmpty ? "other Mac" : ConfigStore.shared.config.peerHostName). Press \(Self.hotkeyDisplay) to come back."
            : "Couldn't reach the other Mac. Still local."
    }

    // MARK: - Receiver side (inject)

    func inject(keyCode: UInt16, keyDown: Bool, flags: UInt64, isFlagsChanged: Bool) {
        guard CGPreflightPostEventAccess() else {
            canPost = false
            lastMessage = "Keystrokes arriving, but macOS is blocking them — click Grant in Settings to allow KeySwitch to type."
            _ = CGRequestPostEventAccess()
            return
        }
        guard let source = CGEventSource(stateID: .hidSystemState),
              let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: keyDown)
        else { return }
        if isFlagsChanged { event.type = .flagsChanged }
        event.flags = CGEventFlags(rawValue: flags)
        event.post(tap: .cghidEventTap)
        markReceiving()
    }

    // Cursor position and button state tracked on the receiver, since incoming
    // movement is relative and buttons determine whether a move is a drag.
    private var injectedCursor: CGPoint?
    private var leftDown = false
    private var rightDown = false
    private var otherDown = false

    func injectMouse(_ m: MousePayload) {
        guard CGPreflightPostEventAccess() else {
            canPost = false
            lastMessage = "Mouse input arriving, but macOS is blocking it — click Grant in Settings to allow KeySwitch to control the pointer."
            _ = CGRequestPostEventAccess()
            return
        }
        let source = CGEventSource(stateID: .hidSystemState)

        switch m.kind {
        case "move":
            var p = injectedCursor ?? currentCursor()
            p.x += m.dx
            p.y += m.dy
            p = clampToDisplays(p)
            injectedCursor = p
            let moveType: CGEventType = leftDown ? .leftMouseDragged : (rightDown ? .rightMouseDragged : (otherDown ? .otherMouseDragged : .mouseMoved))
            let btn: CGMouseButton = leftDown ? .left : (rightDown ? .right : .center)
            if let e = CGEvent(mouseEventSource: source, mouseType: moveType, mouseCursorPosition: p, mouseButton: btn) {
                e.setIntegerValueField(.mouseEventDeltaX, value: Int64(m.dx))
                e.setIntegerValueField(.mouseEventDeltaY, value: Int64(m.dy))
                e.post(tap: .cghidEventTap)
            }
        case "leftDown":  leftDown = true;  postButton(source, .leftMouseDown, .left)
        case "leftUp":    leftDown = false; postButton(source, .leftMouseUp, .left)
        case "rightDown": rightDown = true;  postButton(source, .rightMouseDown, .right)
        case "rightUp":   rightDown = false; postButton(source, .rightMouseUp, .right)
        case "otherDown": otherDown = true;  postButton(source, .otherMouseDown, CGMouseButton(rawValue: UInt32(m.button)) ?? .center)
        case "otherUp":   otherDown = false; postButton(source, .otherMouseUp, CGMouseButton(rawValue: UInt32(m.button)) ?? .center)
        case "scroll":
            if let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: Int32(m.scrollDY), wheel2: Int32(m.scrollDX), wheel3: 0) {
                e.post(tap: .cghidEventTap)
            }
        default:
            break
        }
        markReceiving()
    }

    private func postButton(_ source: CGEventSource?, _ type: CGEventType, _ button: CGMouseButton) {
        let p = injectedCursor ?? currentCursor()
        injectedCursor = p
        if let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: button) {
            e.post(tap: .cghidEventTap)
        }
    }

    private func currentCursor() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    private func clampToDisplays(_ p: CGPoint) -> CGPoint {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        guard count > 0 else { return p }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        var bounds = CGRect.null
        for id in ids { bounds = bounds.union(CGDisplayBounds(id)) }
        guard !bounds.isNull else { return p }
        return CGPoint(
            x: min(max(p.x, bounds.minX), bounds.maxX - 1),
            y: min(max(p.y, bounds.minY), bounds.maxY - 1)
        )
    }

    private func markReceiving() {
        isReceivingFromPeer = true
        receivingResetTask?.cancel()
        receivingResetTask = Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            isReceivingFromPeer = false
        }
    }
}
