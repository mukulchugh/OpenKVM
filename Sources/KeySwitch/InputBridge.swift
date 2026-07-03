import ApplicationServices
import Cocoa
import IOKit

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

/// Captures keyboard + mouse from a specific EXTERNAL device (via HIDInputCapture,
/// picked by vendor/product ID — see Settings) and forwards it to the peer Mac.
/// The built-in trackpad is NEVER opened by this class, so it always keeps
/// working locally on both Macs. The mouse is exclusively seized while
/// forwarding (macOS allows this for mice), so only the selected external mouse
/// is affected. The keyboard cannot be exclusively seized — macOS refuses that
/// for ANY app without root, as anti-keylogger hardening — so while forwarding,
/// a small CGEventTap additionally suppresses ALL local keyboard input
/// (built-in included) so it doesn't leak into local apps too; this tap only
/// exists while forwarding is active, never otherwise. ⌘⇧K from the selected
/// external keyboard toggles forwarding and is always handled locally (via the
/// HID monitor, unaffected by the suppression tap), so the user is never locked
/// out of the owner Mac.
@MainActor
final class InputBridge: ObservableObject {
    static let shared = InputBridge()
    static let hotkeyDisplay = "⌘⇧K"

    @Published private(set) var isForwarding = false
    @Published private(set) var canCapture = false // permissions + external keyboard monitor active
    @Published private(set) var canPost = false     // synthesize events on this Mac
    @Published private(set) var isReceivingFromPeer = false
    @Published private(set) var availableKeyboards: [HIDDeviceInfo] = []
    @Published private(set) var availableMice: [HIDDeviceInfo] = []
    @Published var lastMessage: String?

    private var promptedForPermissions = false
    private let hid = HIDInputCapture.shared
    private var suppressionTap: CFMachPort?
    private var suppressionRunLoopSource: CFRunLoopSource?

    private init() {
        hid.onHotkey = { [weak self] in
            Task { @MainActor in await self?.toggleForwarding() }
        }
        hid.onKeyEvent = { keyCode, down, flags, isModifier in
            guard InputBridge.shared.isForwardingSnapshot else { return }
            PeerNetwork.shared.sendKeyEvent(keyCode: keyCode, keyDown: down, flags: flags, isFlagsChanged: isModifier)
        }
        hid.onMouseDeltaX = { dx in
            guard InputBridge.shared.isForwardingSnapshot else { return }
            PeerNetwork.shared.sendMouseEvent(MousePayload(kind: "move", dx: dx, dy: 0))
        }
        hid.onMouseDeltaY = { dy in
            guard InputBridge.shared.isForwardingSnapshot else { return }
            PeerNetwork.shared.sendMouseEvent(MousePayload(kind: "move", dx: 0, dy: dy))
        }
        hid.onMouseButton = { kind, button in
            guard InputBridge.shared.isForwardingSnapshot else { return }
            PeerNetwork.shared.sendMouseEvent(MousePayload(kind: kind, button: button))
        }
        hid.onScroll = { sx, sy in
            guard InputBridge.shared.isForwardingSnapshot else { return }
            PeerNetwork.shared.sendMouseEvent(MousePayload(kind: "scroll", scrollDX: sx, scrollDY: sy))
        }
    }

    /// Read from a non-isolated HID callback context. Safe: only ever written on
    /// the main thread, and HID callbacks are scheduled on the main run loop.
    private nonisolated var isForwardingSnapshot: Bool {
        MainActor.assumeIsolated { isForwarding }
    }

    // MARK: - Permissions

    /// macOS tracks three separate TCC permissions here: Accessibility,
    /// Input Monitoring (needed to open/monitor HID devices), and PostEvent
    /// (needed to inject). AXIsProcessTrusted() only covers the first — the CG
    /// preflight/request APIs are the correct checks for the other two.
    func refreshPermissions() {
        let permsOK = CGPreflightListenEventAccess() && AXIsProcessTrusted()
        canCapture = permsOK && hid.hasKeyboardMonitor
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
        if !CGPreflightListenEventAccess() || !AXIsProcessTrusted() {
            _ = CGRequestListenEventAccess()
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
        if ConfigStore.shared.config.isKeyboardOwner {
            startKeyboardMonitorIfNeeded()
        }
        refreshPermissions()
    }

    // MARK: - Owner side (device selection + capture)

    func updateOwnerState() {
        if ConfigStore.shared.config.isKeyboardOwner {
            startKeyboardMonitorIfNeeded()
        } else {
            hid.stopKeyboardMonitor()
            canCapture = false
            if isForwarding {
                Task { await toggleForwarding() }
            }
        }
    }

    /// Call from Refresh or after permissions/devices change externally.
    func forceReinstallTap() {
        hid.stopKeyboardMonitor()
        refreshPermissions()
        if ConfigStore.shared.config.isKeyboardOwner {
            startKeyboardMonitorIfNeeded()
        }
    }

    func refreshDeviceList() {
        let (keyboards, mice) = hid.listDevices()
        availableKeyboards = keyboards
        availableMice = mice
    }

    /// nil = auto-detect (first non-built-in device found).
    func selectKeyboard(_ info: HIDDeviceInfo?) {
        ConfigStore.shared.config.externalKeyboardVendorID = info?.vendorID ?? 0
        ConfigStore.shared.config.externalKeyboardProductID = info?.productID ?? 0
        ConfigStore.shared.config.externalKeyboardName = info?.name ?? ""
        startKeyboardMonitorIfNeeded()
    }

    func selectMouse(_ info: HIDDeviceInfo?) {
        ConfigStore.shared.config.externalMouseVendorID = info?.vendorID ?? 0
        ConfigStore.shared.config.externalMouseProductID = info?.productID ?? 0
        ConfigStore.shared.config.externalMouseName = info?.name ?? ""
    }

    var resolvedKeyboard: HIDDeviceInfo? {
        let cfg = ConfigStore.shared.config
        if cfg.externalKeyboardVendorID != 0 || cfg.externalKeyboardProductID != 0,
           let match = availableKeyboards.first(where: { $0.vendorID == cfg.externalKeyboardVendorID && $0.productID == cfg.externalKeyboardProductID }) {
            return match
        }
        return hid.firstExternal(in: availableKeyboards)
    }

    var resolvedMouse: HIDDeviceInfo? {
        let cfg = ConfigStore.shared.config
        if cfg.externalMouseVendorID != 0 || cfg.externalMouseProductID != 0,
           let match = availableMice.first(where: { $0.vendorID == cfg.externalMouseVendorID && $0.productID == cfg.externalMouseProductID }) {
            return match
        }
        return hid.firstExternal(in: availableMice)
    }

    private func startKeyboardMonitorIfNeeded() {
        refreshDeviceList()
        guard CGPreflightListenEventAccess() && AXIsProcessTrusted() else {
            canCapture = false
            lastMessage = "Grant Accessibility + Input Monitoring in System Settings, then click Refresh."
            return
        }
        guard let kb = resolvedKeyboard else {
            canCapture = false
            lastMessage = "No external keyboard found. Connect one (e.g. a Magic Keyboard) and click Refresh."
            return
        }
        if hid.startKeyboardMonitor(vendorID: kb.vendorID, productID: kb.productID) {
            canCapture = true
        } else {
            canCapture = false
            lastMessage = "Couldn't open \(kb.name) for monitoring. Click Refresh, or re-grant Input Monitoring."
        }
    }

    func toggleForwarding() async {
        if isForwarding {
            PeerNetwork.shared.stopKeyForwarding()
            hid.releaseMouse()
            removeSuppressionTap()
            setLocalCursorFrozen(false)
            isForwarding = false
            lastMessage = "Keyboard & mouse are local."
            return
        }

        guard ConfigStore.shared.isConfigured else {
            lastMessage = "Set the other Mac + pairing token in Settings first."
            return
        }
        refreshDeviceList()
        guard let mouse = resolvedMouse else {
            lastMessage = "No external mouse found. Connect one (e.g. your G304) and click Refresh."
            return
        }

        let ok = await PeerNetwork.shared.beginKeyForwarding(config: ConfigStore.shared.config)
        guard ok else {
            isForwarding = false
            lastMessage = "Couldn't reach the other Mac. Still local."
            return
        }

        let mouseResult = hid.seizeMouse(vendorID: mouse.vendorID, productID: mouse.productID)
        guard mouseResult == kIOReturnSuccess else {
            PeerNetwork.shared.stopKeyForwarding()
            hid.releaseMouse()
            isForwarding = false
            lastMessage = "Couldn't take exclusive control of the mouse (\(Self.ioReturnName(mouseResult))). Another app may be holding it open."
            return
        }
        guard installSuppressionTap() else {
            PeerNetwork.shared.stopKeyForwarding()
            hid.releaseMouse()
            isForwarding = false
            lastMessage = "Couldn't suppress local typing — check Accessibility & Input Monitoring access."
            return
        }

        setLocalCursorFrozen(true)
        isForwarding = true
        lastMessage = "Controlling \(ConfigStore.shared.config.peerHostName.isEmpty ? "other Mac" : ConfigStore.shared.config.peerHostName). Press \(Self.hotkeyDisplay) to come back."
    }

    /// Since macOS won't let us exclusively seize a keyboard, this tap exists
    /// ONLY while forwarding and unconditionally swallows every keyboard event
    /// system-wide (built-in included) so local apps don't ALSO see what's being
    /// forwarded. The HID monitor (unaffected by this tap) is what actually
    /// captures + forwards the external keyboard's keys and detects ⌘⇧K.
    private func installSuppressionTap() -> Bool {
        removeSuppressionTap()
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { proxy, type, event, refcon in
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let refcon {
                        let bridge = Unmanaged<InputBridge>.fromOpaque(refcon).takeUnretainedValue()
                        Task { @MainActor in
                            if let tap = bridge.suppressionTap { CGEvent.tapEnable(tap: tap, enable: true) }
                        }
                    }
                    return Unmanaged.passRetained(event)
                }
                return nil // swallow everything while this tap exists
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }
        suppressionTap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        suppressionRunLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func removeSuppressionTap() {
        guard let tap = suppressionTap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source = suppressionRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        suppressionTap = nil
        suppressionRunLoopSource = nil
    }

    /// Purely cosmetic now: the external mouse is exclusively seized while
    /// forwarding, so its movement never reaches the local cursor at all — this
    /// just hides the (now-idle) cursor for a cleaner "you're driving the other
    /// Mac" feel. The built-in trackpad is untouched and keeps moving the cursor
    /// normally if used, which is intentional.
    func setLocalCursorFrozen(_ frozen: Bool) {
        if frozen {
            CGDisplayHideCursor(CGMainDisplayID())
        } else {
            CGDisplayShowCursor(CGMainDisplayID())
        }
    }

    /// Decode the handful of IOReturn codes actually worth distinguishing.
    private static func ioReturnName(_ code: IOReturn) -> String {
        switch code {
        case IOReturn(bitPattern: 0xE00002C5): return "exclusive access — already open elsewhere"
        case IOReturn(bitPattern: 0xE00002E2): return "not permitted"
        case IOReturn(bitPattern: 0xE00002C2): return "no device"
        case IOReturn(bitPattern: 0xE00002EB): return "not open"
        default: return "IOReturn 0x\(String(UInt32(bitPattern: code), radix: 16))"
        }
    }

    /// Called when the forwarding connection drops unexpectedly, so we don't
    /// leave devices seized and forwarding state stuck on.
    func forwardingDropped() {
        guard isForwarding else { return }
        hid.releaseMouse()
        removeSuppressionTap()
        setLocalCursorFrozen(false)
        isForwarding = false
        lastMessage = "Lost the other Mac — keyboard & mouse are local again."
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

    private var receivingResetTask: Task<Void, Never>?
}
