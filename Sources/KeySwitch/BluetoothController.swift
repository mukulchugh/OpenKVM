import Foundation
import IOBluetooth

final class BluetoothController: NSObject {
    static let shared = BluetoothController()

    private let queue = DispatchQueue(label: "com.keyswitch.bluetooth", qos: .userInitiated)
    private var pendingPairs: [String: IOBluetoothDevicePair] = [:]
    private var pairWaiters: [String: CheckedContinuation<Bool, Error>] = [:]

    private override init() {
        super.init()
    }

    func listDevices() -> [BluetoothDeviceInfo] {
        let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
        return paired.map { device in
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

    func isConnected(address: String) -> Bool {
        device(for: address)?.isConnected() ?? false
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
            throw SwitchError.operationFailed("Could not connect. Toggle the keyboard power switch off/on, then retry.")
        }
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
                Thread.sleep(forTimeInterval: 0.6)
                if !btDevice.isConnected() {
                    // Magic Keyboard often needs a fresh pair after sitting on another Mac.
                    removePairingRecord(btDevice)
                    Thread.sleep(forTimeInterval: 0.5)
                    if let refreshed = device(for: address) {
                        btDevice = refreshed
                    }
                } else {
                    finishPairWait(address: address, success: true, error: nil)
                    return
                }
            } else {
                finishPairWait(address: address, success: true, error: nil)
                return
            }
        }

        if btDevice.rssi() == 127 {
            finishPairWait(address: address, success: false, error: SwitchError.operationFailed("Keyboard is asleep or out of range. Wake it and try again."))
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
            self.finishPairWait(address: address, success: false, error: SwitchError.operationFailed("Pairing timed out. Toggle keyboard power and retry."))
        }
    }

    private func releaseOnQueue(address: String) throws {
        guard let btDevice = device(for: address) else {
            throw SwitchError.deviceNotFound
        }
        guard btDevice.isConnected() else { return }

        if btDevice.responds(to: Selector(("remove"))) {
            btDevice.perform(Selector(("remove")))
        } else {
            let result = btDevice.closeConnection()
            guard result == kIOReturnSuccess else {
                throw SwitchError.operationFailed("Disconnect failed (error \(result)).")
            }
        }
        Thread.sleep(forTimeInterval: 0.3)
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

extension BluetoothController: IOBluetoothDevicePairDelegate {
    func devicePairingFinished(_ sender: Any!, error: IOReturn) {
        guard let pair = sender as? IOBluetoothDevicePair,
              let device = pair.device(),
              let address = device.addressString
        else { return }

        let normalized = BluetoothAddress.normalize(address)
        queue.async {
            self.pendingPairs.removeValue(forKey: normalized)

            guard error == kIOReturnSuccess else {
                self.finishPairWait(
                    address: normalized,
                    success: false,
                    error: SwitchError.operationFailed("Pairing failed. Toggle keyboard power and retry.")
                )
                return
            }

            if !device.isConnected() {
                _ = device.openConnection()
                Thread.sleep(forTimeInterval: 0.6)
            }

            self.finishPairWait(
                address: normalized,
                success: device.isConnected(),
                error: device.isConnected() ? nil : SwitchError.operationFailed("Paired but not connected. Toggle keyboard power and retry.")
            )
        }
    }

    func devicePairingUserConfirmationRequest(_ sender: Any!, numericValue: BluetoothNumericValue) {
        guard let pair = sender as? IOBluetoothDevicePair else { return }
        pair.replyUserConfirmation(true)
    }
}