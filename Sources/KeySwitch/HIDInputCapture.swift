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
private let hidUsageGDKeyboard: UInt32 = 0x06
private let hidUsageGDMouse: UInt32 = 0x02
private let hidUsageGDPointer: UInt32 = 0x01
private let hidUsageGDX: UInt32 = 0x30
private let hidUsageGDY: UInt32 = 0x31
private let hidUsageGDWheel: UInt32 = 0x38

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
    private var keyboardSeized = false
    private var mouseDevice: IOHIDDevice?
    private var modifierState: [UInt32: Bool] = [:]

    var hasKeyboardMonitor: Bool { keyboardDevice != nil }

    /// Fires on Cmd+Shift+K from the monitored/seized keyboard only.
    var onHotkey: (() -> Void)?
    /// keyCode (macOS virtual), keyDown, current CGEventFlags, isModifierKey
    var onKeyEvent: ((UInt16, Bool, UInt64, Bool) -> Void)?
    var onMouseDeltaX: ((Double) -> Void)?
    var onMouseDeltaY: ((Double) -> Void)?
    var onMouseButton: ((String, Int64) -> Void)?
    var onScroll: ((Int64, Int64) -> Void)?

    private init() {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, nil)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
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

    // MARK: - Keyboard (always-on monitor, seized only while forwarding)

    func startKeyboardMonitor(vendorID: Int, productID: Int) -> Bool {
        stopKeyboardMonitor()
        guard let d = resolveKeyboardDevice(vendorID: vendorID, productID: productID) else { return false }
        guard IOHIDDeviceOpen(d, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { return false }
        keyboardDevice = d
        keyboardSeized = false
        registerKeyboardCallback(d)
        return true
    }

    func stopKeyboardMonitor() {
        if let d = keyboardDevice {
            IOHIDDeviceRegisterInputValueCallback(d, nil, nil)
            IOHIDDeviceClose(d, IOOptionBits(keyboardSeized ? kIOHIDOptionsTypeSeizeDevice : kIOHIDOptionsTypeNone))
        }
        keyboardDevice = nil
        keyboardSeized = false
    }

    /// Re-open the monitored keyboard exclusively so its keys stop reaching
    /// local apps and only get forwarded. Called when forwarding turns on.
    @discardableResult
    func seizeKeyboard() -> Bool {
        guard let d = keyboardDevice, !keyboardSeized else { return keyboardSeized }
        IOHIDDeviceRegisterInputValueCallback(d, nil, nil)
        IOHIDDeviceClose(d, IOOptionBits(kIOHIDOptionsTypeNone))
        guard IOHIDDeviceOpen(d, IOOptionBits(kIOHIDOptionsTypeSeizeDevice)) == kIOReturnSuccess else {
            _ = IOHIDDeviceOpen(d, IOOptionBits(kIOHIDOptionsTypeNone))
            registerKeyboardCallback(d)
            return false
        }
        keyboardSeized = true
        registerKeyboardCallback(d)
        return true
    }

    /// Drop back to non-exclusive monitoring so the keyboard resumes fully
    /// normal local behavior. Called when forwarding turns off.
    func releaseKeyboardSeize() {
        guard let d = keyboardDevice, keyboardSeized else { return }
        IOHIDDeviceRegisterInputValueCallback(d, nil, nil)
        IOHIDDeviceClose(d, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        keyboardSeized = false
        _ = IOHIDDeviceOpen(d, IOOptionBits(kIOHIDOptionsTypeNone))
        registerKeyboardCallback(d)
    }

    // MARK: - Mouse (only opened while forwarding)

    @discardableResult
    func seizeMouse(vendorID: Int, productID: Int) -> Bool {
        releaseMouse()
        guard let d = resolveMouseDevice(vendorID: vendorID, productID: productID) else { return false }
        guard IOHIDDeviceOpen(d, IOOptionBits(kIOHIDOptionsTypeSeizeDevice)) == kIOReturnSuccess else { return false }
        mouseDevice = d
        registerMouseCallback(d)
        return true
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
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
    }

    private func registerMouseCallback(_ device: IOHIDDevice) {
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputValueCallback(device, { context, _, _, value in
            guard let context else { return }
            Unmanaged<HIDInputCapture>.fromOpaque(context).takeUnretainedValue().handleMouseValue(value)
        }, ctx)
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
    }

    private func handleKeyboardValue(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        guard IOHIDElementGetUsagePage(element) == hidPageKeyboard else { return }
        let usage = Int(IOHIDElementGetUsage(element))
        let down = IOHIDValueGetIntegerValue(value) != 0
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
            case hidUsageGDX: onMouseDeltaX?(Double(intValue))
            case hidUsageGDY: onMouseDeltaY?(Double(intValue))
            case hidUsageGDWheel: onScroll?(0, Int64(intValue))
            default: break
            }
        } else if usagePage == hidPageButton {
            let down = intValue != 0
            switch usage {
            case 1: onMouseButton?(down ? "leftDown" : "leftUp", 0)
            case 2: onMouseButton?(down ? "rightDown" : "rightUp", 0)
            default: onMouseButton?(down ? "otherDown" : "otherUp", Int64(usage) - 1)
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
