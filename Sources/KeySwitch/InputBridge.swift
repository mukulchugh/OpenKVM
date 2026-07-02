import ApplicationServices
import Cocoa

private let hotkeyKeyCode: CGKeyCode = 40 // 'K'

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
    @Published private(set) var hasAccessibility = false
    @Published private(set) var isReceivingFromPeer = false
    @Published var lastMessage: String?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var receivingResetTask: Task<Void, Never>?
    private var promptedForAccessibility = false

    private init() {}

    /// Both sides need Accessibility trust: the owner to capture keystrokes, the
    /// receiver to inject them — macOS silently drops CGEvent.post from untrusted apps.
    func requestAccessibilityIfNeeded() {
        hasAccessibility = AXIsProcessTrusted()
        guard !hasAccessibility, !promptedForAccessibility else { return }
        promptedForAccessibility = true
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
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

    func refreshAccessibilityStatus() {
        hasAccessibility = AXIsProcessTrusted()
    }

    private func installTapIfNeeded() {
        refreshAccessibilityStatus()
        guard eventTap == nil else { return }

        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)

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
            hasAccessibility = false
            lastMessage = SwitchError.accessibilityDenied.localizedDescription
            return
        }

        eventTap = tap
        hasAccessibility = true
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

        let keyDown = type != .keyUp
        let isFlagsChanged = type == .flagsChanged
        Task { @MainActor in
            PeerNetwork.shared.sendKeyEvent(
                keyCode: keyCode,
                keyDown: keyDown,
                flags: flags.rawValue,
                isFlagsChanged: isFlagsChanged,
                config: ConfigStore.shared.config
            )
        }
        return nil
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
            lastMessage = "Keyboard is local."
            return
        }

        guard ConfigStore.shared.isConfigured else {
            lastMessage = "Set the other Mac + pairing token in Settings first."
            return
        }
        let ok = await PeerNetwork.shared.beginKeyForwarding(config: ConfigStore.shared.config)
        isForwarding = ok
        lastMessage = ok
            ? "Forwarding keyboard to \(ConfigStore.shared.config.peerHostName.isEmpty ? "other Mac" : ConfigStore.shared.config.peerHostName)."
            : "Couldn't reach the other Mac. Still local."
    }

    // MARK: - Receiver side (inject)

    func inject(keyCode: UInt16, keyDown: Bool, flags: UInt64, isFlagsChanged: Bool) {
        guard AXIsProcessTrusted() else {
            hasAccessibility = false
            lastMessage = "Keystrokes arriving, but macOS is blocking them — grant Accessibility access to KeySwitch."
            requestAccessibilityIfNeeded()
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
