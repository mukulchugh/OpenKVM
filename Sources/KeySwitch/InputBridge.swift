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
        canPostCached = canPost
        refreshDisplayBounds()
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
            // HID-level tap: returning nil here suppresses the event before the
            // window server moves the cursor, so the owner's pointer actually
            // freezes while forwarding. Session-level taps see moves too late.
            tap: .cghidEventTap,
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

    /// Called when the forwarding connection drops unexpectedly, so we don't leave
    /// the mouse frozen and forwarding state stuck on.
    func forwardingDropped() {
        guard isForwarding else { return }
        setLocalCursorFrozen(false)
        isForwarding = false
        lastMessage = "Lost the other Mac — keyboard & mouse are local again."
    }

    func toggleForwarding() async {
        if isForwarding {
            PeerNetwork.shared.stopKeyForwarding()
            setLocalCursorFrozen(false)
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
        if ok { setLocalCursorFrozen(true) }
        lastMessage = ok
            ? "Controlling \(ConfigStore.shared.config.peerHostName.isEmpty ? "other Mac" : ConfigStore.shared.config.peerHostName). Press \(Self.hotkeyDisplay) to come back."
            : "Couldn't reach the other Mac. Still local."
    }

    /// While forwarding, decouple the physical mouse from THIS Mac's cursor so it
    /// only drives the peer. Movement events still reach the tap (with deltas), so
    /// we can forward them; the local cursor just stops moving. Must always be undone
    /// (here and on quit) or the user's mouse stays frozen.
    func setLocalCursorFrozen(_ frozen: Bool) {
        CGAssociateMouseAndMouseCursorPosition(frozen ? 0 : 1)
        if frozen {
            CGDisplayHideCursor(CGMainDisplayID())
        } else {
            CGDisplayShowCursor(CGMainDisplayID())
        }
    }

    // MARK: - Receiver side (inject)
    //
    // These run on PeerNetwork's serial network queue (NOT the main actor), so
    // injection timing stays even — a per-event main-actor hop was the main
    // source of pointer jitter. All state below is touched only from that queue.

    nonisolated(unsafe) private var injectedCursor: CGPoint?
    nonisolated(unsafe) private var leftDown = false
    nonisolated(unsafe) private var rightDown = false
    nonisolated(unsafe) private var otherDown = false
    nonisolated(unsafe) private var canPostCached = false
    nonisolated(unsafe) private var cachedDisplayBounds = CGRect.null
    nonisolated(unsafe) private var receivingActive = false
    nonisolated(unsafe) private let injectSource = CGEventSource(stateID: .hidSystemState)

    nonisolated func inject(keyCode: UInt16, keyDown: Bool, flags: UInt64, isFlagsChanged: Bool) {
        guard ensureCanPost() else { return }
        guard let event = CGEvent(keyboardEventSource: injectSource, virtualKey: keyCode, keyDown: keyDown) else { return }
        if isFlagsChanged { event.type = .flagsChanged }
        event.flags = CGEventFlags(rawValue: flags)
        event.post(tap: .cghidEventTap)
        markReceiving()
    }

    nonisolated func injectMouse(_ m: MousePayload) {
        guard ensureCanPost() else { return }
        switch m.kind {
        case "move":
            var p = injectedCursor ?? currentCursor()
            p.x += m.dx
            p.y += m.dy
            p = clampToDisplays(p)
            injectedCursor = p
            let moveType: CGEventType = leftDown ? .leftMouseDragged : (rightDown ? .rightMouseDragged : (otherDown ? .otherMouseDragged : .mouseMoved))
            let btn: CGMouseButton = leftDown ? .left : (rightDown ? .right : .center)
            if let e = CGEvent(mouseEventSource: injectSource, mouseType: moveType, mouseCursorPosition: p, mouseButton: btn) {
                e.setIntegerValueField(.mouseEventDeltaX, value: Int64(m.dx))
                e.setIntegerValueField(.mouseEventDeltaY, value: Int64(m.dy))
                e.post(tap: .cghidEventTap)
            }
        case "leftDown":  leftDown = true;  postButton(.leftMouseDown, .left)
        case "leftUp":    leftDown = false; postButton(.leftMouseUp, .left)
        case "rightDown": rightDown = true;  postButton(.rightMouseDown, .right)
        case "rightUp":   rightDown = false; postButton(.rightMouseUp, .right)
        case "otherDown": otherDown = true;  postButton(.otherMouseDown, CGMouseButton(rawValue: UInt32(m.button)) ?? .center)
        case "otherUp":   otherDown = false; postButton(.otherMouseUp, CGMouseButton(rawValue: UInt32(m.button)) ?? .center)
        case "scroll":
            if let e = CGEvent(scrollWheelEvent2Source: injectSource, units: .pixel, wheelCount: 2, wheel1: Int32(m.scrollDY), wheel2: Int32(m.scrollDX), wheel3: 0) {
                e.post(tap: .cghidEventTap)
            }
        default:
            break
        }
        markReceiving()
    }

    /// Cached permission check — CGPreflightPostEventAccess() per event is a
    /// syscall 100+ times/sec and itself causes jitter. Verify once; refreshPermissions
    /// re-syncs the cache.
    nonisolated private func ensureCanPost() -> Bool {
        if canPostCached { return true }
        guard CGPreflightPostEventAccess() else {
            Task { @MainActor in
                self.canPost = false
                self.lastMessage = "Input arriving, but macOS is blocking it — click Grant in Settings."
                _ = CGRequestPostEventAccess()
            }
            return false
        }
        canPostCached = true
        return true
    }

    nonisolated private func postButton(_ type: CGEventType, _ button: CGMouseButton) {
        let p = injectedCursor ?? currentCursor()
        injectedCursor = p
        if let e = CGEvent(mouseEventSource: injectSource, mouseType: type, mouseCursorPosition: p, mouseButton: button) {
            e.post(tap: .cghidEventTap)
        }
    }

    nonisolated private func currentCursor() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    nonisolated private func clampToDisplays(_ p: CGPoint) -> CGPoint {
        let b = cachedDisplayBounds
        guard !b.isNull else { return p }
        return CGPoint(
            x: min(max(p.x, b.minX), b.maxX - 1),
            y: min(max(p.y, b.minY), b.maxY - 1)
        )
    }

    /// Cache the union of display bounds so the hot inject path doesn't call
    /// CGGetActiveDisplayList per event.
    nonisolated private func refreshDisplayBounds() {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        guard count > 0 else { return }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        var bounds = CGRect.null
        for id in ids { bounds = bounds.union(CGDisplayBounds(id)) }
        cachedDisplayBounds = bounds
    }

    /// Flip the "receiving" UI flag at most about once per 1.5s of activity,
    /// not once per event — the per-event main-actor hop caused jitter.
    nonisolated private func markReceiving() {
        if receivingActive { return }
        receivingActive = true
        Task { @MainActor in
            self.isReceivingFromPeer = true
            self.receivingResetTask?.cancel()
            self.receivingResetTask = Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard !Task.isCancelled else { return }
                self.isReceivingFromPeer = false
                self.receivingActive = false
            }
        }
    }
}
