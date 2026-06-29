import Foundation

@MainActor
final class SwitchCoordinator: ObservableObject {
    static let shared = SwitchCoordinator()

    @Published private(set) var isSwitching = false
    @Published private(set) var lastMessage: String?

    private init() {}

    func switchToThisMac() async {
        let config = ConfigStore.shared.config
        guard ConfigStore.shared.isConfigured else {
            lastMessage = "Finish setup in Settings first."
            return
        }

        let address = BluetoothAddress.normalize(config.keyboardAddress)
        guard !BluetoothManager.shared.keyboardConnected(address: address) else {
            lastMessage = "Keyboard is already on this Mac."
            return
        }

        isSwitching = true
        defer { isSwitching = false }

        do {
            _ = try await PeerNetwork.shared.send(action: .disconnectKeyboard, config: config)
            try await Task.sleep(nanoseconds: 1_000_000_000)
            try await BluetoothManager.shared.connectFromPeer(address: address)
            lastMessage = "Magic Keyboard connected to \(config.thisMacName)"
            BluetoothManager.shared.refresh()
        } catch {
            lastMessage = error.localizedDescription
        }
    }

    func switchToOtherMac() async {
        let config = ConfigStore.shared.config
        guard ConfigStore.shared.isConfigured else {
            lastMessage = "Finish setup in Settings first."
            return
        }

        let address = BluetoothAddress.normalize(config.keyboardAddress)
        isSwitching = true
        defer { isSwitching = false }

        do {
            if BluetoothManager.shared.keyboardConnected(address: address) {
                try await BluetoothManager.shared.releaseForHandoff(address: address)
            }
            _ = try await PeerNetwork.shared.send(action: .connectKeyboard, config: config)
            lastMessage = "Magic Keyboard switched to \(config.peerHostName.isEmpty ? "other Mac" : config.peerHostName)"
            BluetoothManager.shared.refresh()
        } catch {
            lastMessage = error.localizedDescription
        }
    }
}