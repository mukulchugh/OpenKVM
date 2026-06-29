import CoreBluetooth
import Foundation
import IOBluetooth

@MainActor
final class BluetoothManager: NSObject, ObservableObject {
    static let shared = BluetoothManager()

    @Published private(set) var devices: [BluetoothDeviceInfo] = []
    @Published private(set) var powerState: Bool = true
    @Published private(set) var authorizationMessage: String?

    private let queue = DispatchQueue(label: "com.keyswitch.bluetooth", qos: .userInitiated)
    private var centralManager: CBCentralManager?
    private var pendingPairs: [String: IOBluetoothDevicePair] = [:]
    private var pairWaiters: [String: CheckedContinuation<Bool, Error>] = [:]

    private override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: queue)
    }

    func refresh() {
        powerState = IOBluetoothHostController.default()?.powerState == kBluetoothHCIPowerStateON

        let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
        devices = paired.map { device in
            let address = BluetoothAddress.normalize(device.addressString ?? "")
            let name = device.name ?? address
            let classOfDevice = device.classOfDevice
            let major = (classOfDevice >> 8) & 0x1F
            let minor = (classOfDevice >> 2) & 0x3F
            let isKeyboard = (major == 0x05 && (minor & 0x30) == 0x10) ||
                name.localizedCaseInsensitiveContains("keyboard") ||
                name.localizedCaseInsensitiveContains("magic keyboard")
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
        guard let device = device(for: address) else { return false }
        return device.isConnected()
    }

    func connectLocally(address: String) async throws {
        try await connect(address: address, refreshPairing: false)
    }

    func connectFromPeer(address: String) async throws {
        try await connect(address: address, refreshPairing: true)
    }

    func releaseForHandoff(address: String) async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    try self.releaseOnQueue(address: address)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        try await Task.sleep(nanoseconds: 800_000_000)
        await MainActor.run { self.refresh() }
    }

    private func connect(address: String, refreshPairing: Bool) async throws {
        let normalized = BluetoothAddress.normalize(address)
        let result = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
            queue.async {
                self.pairWaiters[normalized] = continuation
                self.connectOnQueue(address: normalized, refreshPairing: refreshPairing)
            }
        }
        guard result else {
            throw SwitchError.operationFailed("Could not connect to Magic Keyboard. Toggle the keyboard power switch and try again.")
        }
        await MainActor.run { self.refresh() }
    }

    private func device(for address: String) -> IOBluetoothDevice? {
        let normalized = BluetoothAddress.normalize(address)
        if let direct = IOBluetoothDevice(addressString: normalized) {
            return direct
        }
        let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
        return paired.first {
            BluetoothAddress.normalize($0.addressString ?? "") == normalized
        }
    }

    private func connectOnQueue(address: String, refreshPairing: Bool) {
        guard IOBluetoothHostController.default()?.powerState == kBluetoothHCIPowerStateON else {
            finishPairWait(address: address, success: false, error: SwitchError.bluetoothUnavailable)
            return
        }

        guard var btDevice = device(for: address) else {
            finishPairWait(address: address, success: false, error: SwitchError.deviceNotFound)
            return
        }

        if refreshPairing, btDevice.isConnected() {
            finishPairWait(address: address, success: true, error: nil)
            return
        }

        if refreshPairing, btDevice.isPaired() {
            removePairingRecord(btDevice)
            Thread.sleep(forTimeInterval: 0.5)
            if let refreshed = device(for: address) {
                btDevice = refreshed
            }
        }

        if !refreshPairing, btDevice.isPaired() {
            if !btDevice.isConnected() {
                _ = btDevice.openConnection()
                Thread.sleep(forTimeInterval: 0.4)
            }
            finishPairWait(address: address, success: btDevice.isConnected(), error: nil)
            return
        }

        if btDevice.rssi() == 127 {
            finishPairWait(address: address, success: false, error: SwitchError.operationFailed("Magic Keyboard is out of range or asleep. Wake it and try again."))
            return
        }

        guard let devicePair = IOBluetoothDevicePair(device: btDevice) else {
            finishPairWait(address: address, success: false, error: SwitchError.operationFailed("Failed to start Bluetooth pairing."))
            return
        }

        devicePair.delegate = self
        pendingPairs[address] = devicePair

        let pairResult = devicePair.start()
        if pairResult != kIOReturnSuccess {
            pendingPairs.removeValue(forKey: address)
            finishPairWait(address: address, success: false, error: SwitchError.operationFailed("Pairing start failed (error \(pairResult))."))
        }

        queue.asyncAfter(deadline: .now() + 45) { [weak self] in
            guard let self, self.pairWaiters[address] != nil else { return }
            self.pendingPairs.removeValue(forKey: address)
            self.finishPairWait(address: address, success: false, error: SwitchError.operationFailed("Pairing timed out. Toggle the keyboard off/on, then retry."))
        }
    }

    private func releaseOnQueue(address: String) throws {
        guard let btDevice = device(for: address) else {
            throw SwitchError.deviceNotFound
        }

        guard btDevice.isConnected() || btDevice.isPaired() else { return }

        if btDevice.isConnected() {
            if btDevice.responds(to: Selector(("remove"))) {
                btDevice.perform(Selector(("remove")))
            } else {
                let result = btDevice.closeConnection()
                guard result == kIOReturnSuccess else {
                    throw SwitchError.operationFailed("Disconnect failed (error \(result)).")
                }
            }
            Thread.sleep(forTimeInterval: 0.3)
            return
        }
    }

    private func removePairingRecord(_ device: IOBluetoothDevice) {
        if device.responds(to: Selector(("remove"))) {
            device.perform(Selector(("remove")))
        } else if device.isConnected() {
            _ = device.closeConnection()
        }
    }

    private func finishPairWait(address: String, success: Bool, error: Error?) {
        guard let waiter = pairWaiters.removeValue(forKey: address) else { return }
        if let error {
            waiter.resume(throwing: error)
        } else {
            waiter.resume(returning: success)
        }
    }
}

extension BluetoothManager: IOBluetoothDevicePairDelegate {
    nonisolated func devicePairingFinished(_ sender: Any!, error: IOReturn) {
        guard let pair = sender as? IOBluetoothDevicePair,
              let device = pair.device(),
              let address = device.addressString
        else { return }

        let normalized = BluetoothAddress.normalize(address)
        queue.async {
            Task { @MainActor in
                BluetoothManager.shared.pendingPairs.removeValue(forKey: normalized)
            }

            guard error == kIOReturnSuccess else {
                BluetoothManager.shared.finishPairWait(
                    address: normalized,
                    success: false,
                    error: SwitchError.operationFailed("Pairing failed (error \(error)). Toggle keyboard power and retry.")
                )
                return
            }

            if !device.isConnected() {
                _ = device.openConnection()
                Thread.sleep(forTimeInterval: 0.4)
            }

            BluetoothManager.shared.finishPairWait(
                address: normalized,
                success: device.isConnected(),
                error: device.isConnected() ? nil : SwitchError.operationFailed("Paired but not connected. Toggle keyboard power and retry.")
            )
        }
    }

    nonisolated func devicePairingUserConfirmationRequest(_ sender: Any!, numericValue: BluetoothNumericValue) {
        guard let pair = sender as? IOBluetoothDevicePair else { return }
        pair.replyUserConfirmation(true)
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
                BluetoothManager.shared.authorizationMessage = "Grant Bluetooth access in System Settings → Privacy & Security."
                BluetoothManager.shared.powerState = false
            case .unsupported:
                BluetoothManager.shared.authorizationMessage = "Bluetooth is not supported on this Mac."
                BluetoothManager.shared.powerState = false
            default:
                break
            }
            BluetoothManager.shared.refresh()
        }
    }
}