import Foundation
import IOBluetooth

@MainActor
final class BluetoothManager: ObservableObject {
    static let shared = BluetoothManager()

    @Published private(set) var devices: [BluetoothDeviceInfo] = []
    @Published private(set) var powerState: Bool = true

    private init() {}

    func refresh() {
        powerState = IOBluetoothHostController.default()?.powerState == kBluetoothHCIPowerStateON

        let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
        devices = paired.map { device in
            let address = device.addressString ?? ""
            let name = device.name ?? address
            let minor = device.deviceClassMinor
            // IOBluetooth minor class: keyboard=0x10, combo keyboard/pointing=0x28
            let isKeyboard = minor == 0x10 || minor == 0x28 ||
                name.localizedCaseInsensitiveContains("keyboard")
            return BluetoothDeviceInfo(
                id: address,
                name: name,
                address: address,
                isConnected: device.isConnected(),
                isKeyboard: isKeyboard
            )
        }
        .sorted { lhs, rhs in
            if lhs.isKeyboard != rhs.isKeyboard { return lhs.isKeyboard }
            if lhs.isConnected != rhs.isConnected { return lhs.isConnected }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    func keyboardConnected(address: String) -> Bool {
        guard let device = IOBluetoothDevice(addressString: address) else { return false }
        return device.isConnected()
    }

    func connect(address: String) throws {
        guard powerState else { throw SwitchError.bluetoothUnavailable }
        guard let device = IOBluetoothDevice(addressString: address) else {
            throw SwitchError.deviceNotFound
        }
        guard device.isPaired() else { throw SwitchError.notPaired }

        if device.isConnected() { return }

        let result = device.openConnection()
        guard result == kIOReturnSuccess else {
            throw SwitchError.operationFailed("Connect failed (error \(result))")
        }
        refresh()
    }

    func disconnect(address: String) throws {
        guard let device = IOBluetoothDevice(addressString: address) else {
            throw SwitchError.deviceNotFound
        }
        guard device.isConnected() else { return }

        let result = device.closeConnection()
        guard result == kIOReturnSuccess else {
            throw SwitchError.operationFailed("Disconnect failed (error \(result))")
        }
        refresh()
    }
}