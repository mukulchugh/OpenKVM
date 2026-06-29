import CoreBluetooth
import Foundation
import IOBluetooth

@MainActor
final class BluetoothManager: NSObject, ObservableObject {
    static let shared = BluetoothManager()

    @Published private(set) var devices: [BluetoothDeviceInfo] = []
    @Published private(set) var powerState: Bool = true
    @Published private(set) var authorizationMessage: String?

    private var centralManager: CBCentralManager?

    private override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }

    func refresh() {
        powerState = IOBluetoothHostController.default()?.powerState == kBluetoothHCIPowerStateON
        devices = BluetoothController.shared.listDevices()
        autoSelectKeyboardIfNeeded()
    }

    func keyboardConnected(address: String) -> Bool {
        BluetoothController.shared.isConnected(address: address)
    }

    func connectLocally(address: String) async throws {
        try await BluetoothController.shared.connectLocally(address: address)
        refresh()
    }

    func connectFromPeer(address: String) async throws {
        try await BluetoothController.shared.connectFromPeer(address: address)
        refresh()
    }

    func releaseForHandoff(address: String) async throws {
        try await BluetoothController.shared.releaseForHandoff(address: address)
        refresh()
    }

    private func autoSelectKeyboardIfNeeded() {
        let store = ConfigStore.shared
        guard store.config.keyboardAddress.isEmpty else { return }
        if let magic = devices.first(where: { $0.isKeyboard && $0.name.localizedCaseInsensitiveContains("magic keyboard") }) {
            store.config.keyboardAddress = magic.address
            store.config.keyboardName = magic.name
        } else if let keyboard = devices.first(where: \.isKeyboard) {
            store.config.keyboardAddress = keyboard.address
            store.config.keyboardName = keyboard.name
        }
    }
}

extension BluetoothManager: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            switch central.state {
            case .poweredOn:
                BluetoothManager.shared.authorizationMessage = nil
                BluetoothManager.shared.powerState = true
            case .poweredOff:
                BluetoothManager.shared.authorizationMessage = "Bluetooth is off."
                BluetoothManager.shared.powerState = false
            case .unauthorized:
                BluetoothManager.shared.authorizationMessage = "Grant Bluetooth in System Settings → Privacy & Security."
                BluetoothManager.shared.powerState = false
            case .unsupported:
                BluetoothManager.shared.authorizationMessage = "Bluetooth not supported."
                BluetoothManager.shared.powerState = false
            default:
                break
            }
            BluetoothManager.shared.refresh()
        }
    }
}