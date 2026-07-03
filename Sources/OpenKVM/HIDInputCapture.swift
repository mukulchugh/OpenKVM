import CoreGraphics
import Foundation
import IOKit.hid

/// One external input device, as seen by IOKit's HID Manager.
struct HIDDeviceInfo: Identifiable, Hashable, Sendable {
    var id: String { "\(vendorID):\(productID)" }
    let vendorID: Int
    let productID: Int
    let name: String
    let isBuiltIn: Bool
}

private let hidPageGenericDesktop: UInt32 = 0x01
private let hidPageKeyboard: UInt32 = 0x07
private let hidPageButton: UInt32 = 0x09
private let hidPageConsumer: UInt32 = 0x0C
private let hidUsageGDKeyboard: UInt32 = 0x06
private let hidUsageGDMouse: UInt32 = 0x02
private let hidUsageGDPointer: UInt32 = 0x01
private let hidUsageGDX: UInt32 = 0x30
private let hidUsageGDY: UInt32 = 0x31
private let hidUsageGDWheel: UInt32 = 0x38

/// USB HID Consumer-page (0x0C) usage → macOS NX_KEYTYPE constant (from
/// IOKit/hidsystem/ev_keymap.h). The Magic Keyboard's F-row sends these
/// instead of plain F1-F12 keycodes unless Fn-lock is set to standard
/// function keys. Covers the classic media keys (volume, brightness, play/
/// pause/next/prev, eject, keyboard illumination) — the ones with a real
/// NX_KEYTYPE. Apple's newer Mission Control/Launchpad/Dictation/Do Not
/// Disturb F-row keys are NOT standard HID Consumer usages and aren't
/// covered; a known, documented gap.
private let hidConsumerUsageToNXKeyType: [Int: Int32] = [
    0xE9: 0,  // Volume Increment -> NX_KEYTYPE_SOUND_UP
    0xEA: 1,  // Volume Decrement -> NX_KEYTYPE_SOUND_DOWN
    0x6F: 2,  // Display Brightness Increment -> NX_KEYTYPE_BRIGHTNESS_UP
    0x70: 3,  // Display Brightness Decrement -> NX_KEYTYPE_BRIGHTNESS_DOWN
    0xE2: 7,  // Mute -> NX_KEYTYPE_MUTE
    0xB8: 14, // Eject -> NX_KEYTYPE_EJECT
    0xCD: 16, // Play/Pause -> NX_KEYTYPE_PLAY
    0xB5: 17, // Scan Next Track -> NX_KEYTYPE_NEXT
    0xB6: 18, // Scan Previous Track -> NX_KEYTYPE_PREVIOUS
    0xB3: 19, // Fast Forward -> NX_KEYTYPE_FAST
    0xB4: 20, // Rewind -> NX_KEYTYPE_REWIND
    0x79: 21, // Keyboard Illumination Up
    0x7A: 22, // Keyboard Illumination Down
    0x7B: 23, // Keyboard Illumination Toggle
]

/// USB HID keyboard-page usage → macOS virtual keycode (the same numbering
/// CGEvent(keyboardEventSource:virtualKey:) expects). Covers letters, digits,
/// punctuation, function keys, arrows, keypad, and modifiers — the set any
/// standard external keyboard (like a Magic Keyboard) actually sends. Media
/// keys (Consumer usage page) aren't covered; a documented, minor gap.
private let hidUsageToMacKeyCode: [Int: UInt16] = [
    0x04: 0x00, 0x05: 0x0B, 0x06: 0x08, 0x07: 0x02, 0x08: 0x0E, 0x09: 0x03,
    0x0A: 0x05, 0x0B: 0x04, 0x0C: 0x22, 0x0D: 0x26, 0x0E: 0x28, 0x0F: 0x25,
    0x10: 0x2E, 0x11: 0x2D, 0x12: 0x1F, 0x13: 0x23, 0x14: 0x0C, 0x15: 0x0F,
    0x16: 0x01, 0x17: 0x11, 0x18: 0x20, 0x19: 0x09, 0x1A: 0x0D, 0x1B: 0x07,
    0x1C: 0x10, 0x1D: 0x06,
    0x1E: 0x12, 0x1F: 0x13, 0x20: 0x14, 0x21: 0x15, 0x22: 0x17, 0x23: 0x16,
    0x24: 0x1A, 0x25: 0x1C, 0x26: 0x19, 0x27: 0x1D,
    0x28: 0x24, // Return
    0x29: 0x35, // Escape
    0x2A: 0x33, // Backspace/Delete
    0x2B: 0x30, // Tab
    0x2C: 0x31, // Space
    0x2D: 0x1B, 0x2E: 0x18, 0x2F: 0x21, 0x30: 0x1E, 0x31: 0x2A,
    0x33: 0x29, 0x34: 0x27, 0x35: 0x32, 0x36: 0x2B, 0x37: 0x2F, 0x38: 0x2C,
    0x39: 0x39, // CapsLock
    0x3A: 0x7A, 0x3B: 0x78, 0x3C: 0x63, 0x3D: 0x76, 0x3E: 0x60, 0x3F: 0x61,
    0x40: 0x62, 0x41: 0x64, 0x42: 0x65, 0x43: 0x6D, 0x44: 0x67, 0x45: 0x6F,
    0x49: 0x72, // Insert -> Help
    0x4A: 0x73, 0x4B: 0x74, 0x4C: 0x75, 0x4D: 0x77, 0x4E: 0x79,
    0x4F: 0x7C, 0x50: 0x7B, 0x51: 0x7D, 0x52: 0x7E,
    0x53: 0x47, // NumLock -> Clear
    0x54: 0x4B, 0x55: 0x43, 0x56: 0x4E, 0x57: 0x45, 0x58: 0x4C,
    0x59: 0x53, 0x5A: 0x54, 0x5B: 0x55, 0x5C: 0x56, 0x5D: 0x57, 0x5E: 0x58,
    0x5F: 0x59, 0x60: 0x5B, 0x61: 0x5C, 0x62: 0x52, 0x63: 0x41,
    0x65: 0x6E, // App/Menu
    0xE0: 0x3B, 0xE1: 0x38, 0xE2: 0x3A, 0xE3: 0x37, // L Ctrl/Shift/Alt/Cmd
    0xE4: 0x3E, 0xE5: 0x3C, 0xE6: 0x3D, 0xE7: 0x36, // R Ctrl/Shift/Alt/Cmd
]

/// Captures keyboard and mouse input directly from a SPECIFIC HID device by
/// vendor/product ID — not system-wide like CGEventTap. This is the only way
/// to leave the built-in trackpad and keyboard completely untouched: they are
/// simply never opened. The selected external keyboard is opened in
/// non-exclusive "monitor" mode at all times (so it keeps working normally —
/// we just also see the hotkey), and gets exclusively SEIZED only while
/// forwarding is active. The selected external mouse is opened only while
/// forwarding is active and fully released the instant it stops.
final class HIDInputCapture {
    static let shared = HIDInputCapture()

    private let manager: IOHIDManager
    private var keyboardDevice: IOHIDDevice?
    private var mouseDevice: IOHIDDevice?
    private var modifierState: [UInt32: Bool] = [:]
    private let hidThread: Thread
    private let hidRunLoop: CFRunLoop
    private static let hidRunLoopMode = CFRunLoopMode.defaultMode.rawValue

    var hasKeyboardMonitor: Bool { keyboardDevice != nil }

    /// Fires on Cmd+Shift+K from the monitored/seized keyboard only.
    var onHotkey: (() -> Void)?
    /// keyCode (macOS virtual), keyDown, current CGEventFlags, isModifierKey
    var onKeyEvent: ((UInt16, Bool, UInt64, Bool) -> Void)?
    /// Media/function-row key from the Consumer usage page: NX_KEYTYPE, keyDown.
    var onMediaKey: ((Int32, Bool) -> Void)?
    // dx/dy/scroll/button all carry current CGEventFlags — modifier state (shift/
    // cmd/etc, held on the keyboard) so shift-click/cmd-click multi-select and
    // option-drag work correctly on the receiver. Ported from Deskflow's
    // "Fix for sticky keys": synthesized mouse events need explicit flags too,
    // not just synthesized key events.
    var onMouseDeltaX: ((Double, UInt64) -> Void)?
    var onMouseDeltaY: ((Double, UInt64) -> Void)?
    var onMouseButton: ((String, Int64, UInt64) -> Void)?
    var onScroll: ((Int64, Int64, UInt64) -> Void)?

    /// HID capture runs on a dedicated, elevated-priority thread with its own
    /// CFRunLoop — NOT the main run loop. Scheduling on CFRunLoopGetMain() (the
    /// original approach) made HID callback delivery compete with AppKit/SwiftUI
    /// for the main thread's attention, adding variable latency that showed up
    /// as mouse jitter. This is the same isolation technique Psychtoolbox uses
    /// for latency-sensitive HID capture.
    private init() {
        final class RunLoopBox: @unchecked Sendable { var runLoop: CFRunLoop? }
        let box = RunLoopBox()
        let ready = DispatchSemaphore(value: 0)

        let thread = Thread {
            box.runLoop = CFRunLoopGetCurrent()
            // A run loop with no sources exits immediately; this timer (never
            // fires) keeps it alive so IOHID sources added later actually run.
            let keepAlive = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + 1e10, 0, 0, 0) { _ in }
            CFRunLoopAddTimer(CFRunLoopGetCurrent(), keepAlive, .defaultMode)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "com.openkvm.hid"
        thread.qualityOfService = QualityOfService.userInteractive
        thread.threadPriority = 1.0
        thread.start()
        ready.wait()

        hidThread = thread
        hidRunLoop = box.runLoop!
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, nil)
        IOHIDManagerScheduleWithRunLoop(manager, hidRunLoop, Self.hidRunLoopMode)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    // MARK: - Discovery

    func listDevices() -> (keyboards: [HIDDeviceInfo], mice: [HIDDeviceInfo]) {
        guard let deviceSet = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return ([], []) }
        var keyboards: [HIDDeviceInfo] = []
        var mice: [HIDDeviceInfo] = []
        for device in deviceSet {
            let info = HIDDeviceInfo(
                vendorID: intProperty(device, kIOHIDVendorIDKey),
                productID: intProperty(device, kIOHIDProductIDKey),
                name: stringProperty(device, kIOHIDProductKey) ?? "Unknown device",
                isBuiltIn: boolProperty(device, kIOHIDBuiltInKey)
            )
            let conformsKeyboard = IOHIDDeviceConformsTo(device, hidPageGenericDesktop, hidUsageGDKeyboard)
            let conformsMouse = IOHIDDeviceConformsTo(device, hidPageGenericDesktop, hidUsageGDMouse)
                || IOHIDDeviceConformsTo(device, hidPageGenericDesktop, hidUsageGDPointer)
            // Logitech (and other) USB receivers commonly expose a decoy keyboard
            // interface alongside the real mouse one on the same dongle. A genuine
            // keyboard never also reports mouse conformance, so treat dual-conformance
            // devices as mice only — otherwise auto-select could randomly grab the
            // dongle's decoy interface instead of an actual keyboard (Set order is
            // non-deterministic).
            if conformsMouse {
                mice.append(info)
            } else if conformsKeyboard {
                keyboards.append(info)
            }
        }
        return (keyboards.sorted { $0.name < $1.name }, mice.sorted { $0.name < $1.name })
    }

    /// First non-built-in device of the given list — the "auto-detect" pick.
    func firstExternal(in devices: [HIDDeviceInfo]) -> HIDDeviceInfo? {
        devices.first { !$0.isBuiltIn }
    }

    /// A composite dongle (e.g. a Logitech receiver) can expose multiple
    /// IOHIDDevice objects sharing the SAME vendor/product ID — one per USB
    /// interface (mouse, decoy keyboard). Matching on vid/pid alone is
    /// ambiguous, so disambiguate with the same conformance rule listDevices()
    /// uses: dual-conformance devices are the mouse interface, not keyboard.
    private func resolveKeyboardDevice(vendorID: Int, productID: Int) -> IOHIDDevice? {
        matchingDevices(vendorID: vendorID, productID: productID).first {
            IOHIDDeviceConformsTo($0, hidPageGenericDesktop, hidUsageGDKeyboard)
                && !IOHIDDeviceConformsTo($0, hidPageGenericDesktop, hidUsageGDMouse)
                && !IOHIDDeviceConformsTo($0, hidPageGenericDesktop, hidUsageGDPointer)
        }
    }

    private func resolveMouseDevice(vendorID: Int, productID: Int) -> IOHIDDevice? {
        matchingDevices(vendorID: vendorID, productID: productID).first {
            IOHIDDeviceConformsTo($0, hidPageGenericDesktop, hidUsageGDMouse)
                || IOHIDDeviceConformsTo($0, hidPageGenericDesktop, hidUsageGDPointer)
        }
    }

    private func matchingDevices(vendorID: Int, productID: Int) -> [IOHIDDevice] {
        guard let deviceSet = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return [] }
        return deviceSet.filter {
            intProperty($0, kIOHIDVendorIDKey) == vendorID && intProperty($0, kIOHIDProductIDKey) == productID
        }
    }

    // MARK: - Keyboard (always non-exclusive — see note below)
    //
    // macOS refuses IOHIDDeviceOpen(..., kIOHIDOptionsTypeSeizeDevice) for
    // keyboards with kIOReturnNotPrivileged unless the process is root or holds
    // a private entitlement — deliberate anti-keylogger hardening, confirmed
    // empirically (mice have no such restriction). So the keyboard can only ever
    // be MONITORED here, never exclusively seized. Capture/hotkey detection both
    // work fine non-exclusively; local suppression while forwarding (so the
    // built-in keyboard's own typing doesn't leak through too) is handled by a
    // separate, forwarding-scoped CGEventTap in InputBridge — see
    // installSuppressionTap()/removeSuppressionTap().

    func startKeyboardMonitor(vendorID: Int, productID: Int) -> Bool {
        stopKeyboardMonitor()
        guard let d = resolveKeyboardDevice(vendorID: vendorID, productID: productID) else { return false }
        guard IOHIDDeviceOpen(d, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { return false }
        keyboardDevice = d
        registerKeyboardCallback(d)
        return true
    }

    func stopKeyboardMonitor() {
        if let d = keyboardDevice {
            IOHIDDeviceRegisterInputValueCallback(d, nil, nil)
            IOHIDDeviceClose(d, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        keyboardDevice = nil
    }

    // MARK: - Mouse (only opened while forwarding)

    @discardableResult
    func seizeMouse(vendorID: Int, productID: Int) -> IOReturn {
        releaseMouse()
        guard let d = resolveMouseDevice(vendorID: vendorID, productID: productID) else { return IOReturn(bitPattern: 0xE00002C2) }
        let result = IOHIDDeviceOpen(d, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        guard result == kIOReturnSuccess else { return result }
        mouseDevice = d
        registerMouseCallback(d)
        return kIOReturnSuccess
    }

    func releaseMouse() {
        if let d = mouseDevice {
            IOHIDDeviceRegisterInputValueCallback(d, nil, nil)
            IOHIDDeviceClose(d, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        }
        mouseDevice = nil
    }

    // MARK: - Callbacks

    private func registerKeyboardCallback(_ device: IOHIDDevice) {
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputValueCallback(device, { context, _, _, value in
            guard let context else { return }
            Unmanaged<HIDInputCapture>.fromOpaque(context).takeUnretainedValue().handleKeyboardValue(value)
        }, ctx)
        IOHIDDeviceScheduleWithRunLoop(device, hidRunLoop, Self.hidRunLoopMode)
    }

    private func registerMouseCallback(_ device: IOHIDDevice) {
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputValueCallback(device, { context, _, _, value in
            guard let context else { return }
            Unmanaged<HIDInputCapture>.fromOpaque(context).takeUnretainedValue().handleMouseValue(value)
        }, ctx)
        IOHIDDeviceScheduleWithRunLoop(device, hidRunLoop, Self.hidRunLoopMode)
    }

    private func handleKeyboardValue(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let usagePage = IOHIDElementGetUsagePage(element)
        let usage = Int(IOHIDElementGetUsage(element))
        let down = IOHIDValueGetIntegerValue(value) != 0

        if usagePage == hidPageConsumer {
            guard let nxKeyType = hidConsumerUsageToNXKeyType[usage] else { return }
            onMediaKey?(nxKeyType, down)
            return
        }
        guard usagePage == hidPageKeyboard else { return }

        let isModifier = usage >= 0xE0 && usage <= 0xE7
        if isModifier { modifierState[UInt32(usage)] = down }

        if !isModifier, usage == 0x0E, down, isCmdDown, isShiftDown {
            onHotkey?()
            return
        }
        guard let keyCode = hidUsageToMacKeyCode[usage] else { return }
        onKeyEvent?(keyCode, down, currentFlags, isModifier)
    }

    private func handleMouseValue(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let usagePage = IOHIDElementGetUsagePage(element)
        let usage = IOHIDElementGetUsage(element)
        let intValue = IOHIDValueGetIntegerValue(value)

        if usagePage == hidPageGenericDesktop {
            switch usage {
            case hidUsageGDX: onMouseDeltaX?(Double(intValue), currentFlags)
            case hidUsageGDY: onMouseDeltaY?(Double(intValue), currentFlags)
            case hidUsageGDWheel: onScroll?(0, Int64(intValue), currentFlags)
            default: break
            }
        } else if usagePage == hidPageButton {
            let down = intValue != 0
            switch usage {
            case 1: onMouseButton?(down ? "leftDown" : "leftUp", 0, currentFlags)
            case 2: onMouseButton?(down ? "rightDown" : "rightUp", 0, currentFlags)
            default: onMouseButton?(down ? "otherDown" : "otherUp", Int64(usage) - 1, currentFlags)
            }
        }
    }

    private var isCmdDown: Bool { modifierState[0xE3] == true || modifierState[0xE7] == true }
    private var isShiftDown: Bool { modifierState[0xE1] == true || modifierState[0xE5] == true }

    private var currentFlags: UInt64 {
        var flags: UInt64 = 0
        if isShiftDown { flags |= CGEventFlags.maskShift.rawValue }
        if modifierState[0xE0] == true || modifierState[0xE4] == true { flags |= CGEventFlags.maskControl.rawValue }
        if modifierState[0xE2] == true || modifierState[0xE6] == true { flags |= CGEventFlags.maskAlternate.rawValue }
        if isCmdDown { flags |= CGEventFlags.maskCommand.rawValue }
        return flags
    }

    // MARK: - Property helpers

    private func intProperty(_ device: IOHIDDevice, _ key: String) -> Int {
        (IOHIDDeviceGetProperty(device, key as CFString) as? Int) ?? 0
    }
    private func stringProperty(_ device: IOHIDDevice, _ key: String) -> String? {
        IOHIDDeviceGetProperty(device, key as CFString) as? String
    }
    private func boolProperty(_ device: IOHIDDevice, _ key: String) -> Bool {
        (IOHIDDeviceGetProperty(device, key as CFString) as? Bool) ?? false
    }
}
