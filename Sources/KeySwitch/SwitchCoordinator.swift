import Foundation

@MainActor
final class SwitchCoordinator: ObservableObject {
    static let shared = SwitchCoordinator()

    @Published private(set) var isSwitching = false
    @Published private(set) var lastMessage: String?

    private init() {}

    func switchToPeer() async {
        let config = ConfigStore.shared.config
        guard ConfigStore.shared.isConfigured else {
            lastMessage = "Finish setup in Settings first."
            return
        }

        let address = config.keyboardAddress
        guard !BluetoothManager.shared.keyboardConnected(address: address) else {
            lastMessage = "Keyboard is already on this Mac."
            return
        }

        isSwitching = true
        defer { isSwitching = false }

        do {
            // Ask peer to release if it holds the keyboard, then connect here.
            _ = try await PeerNetwork.shared.send(action: .disconnectKeyboard, config: config)
            try await Task.sleep(nanoseconds: 400_000_000)
            try BluetoothManager.shared.connect(address: address)
            lastMessage = "Keyboard connected to \(config.thisMacName)"
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

        let address = config.keyboardAddress
        isSwitching = true
        defer { isSwitching = false }

        do {
            if BluetoothManager.shared.keyboardConnected(address: address) {
                try BluetoothManager.shared.disconnect(address: address)
                try await Task.sleep(nanoseconds: 400_000_000)
            }
            _ = try await PeerNetwork.shared.send(action: .connectKeyboard, config: config)
            lastMessage = "Keyboard switched to \(config.peerHostName.isEmpty ? "other Mac" : config.peerHostName)"
            BluetoothManager.shared.refresh()
        } catch {
            lastMessage = error.localizedDescription
        }
    }
}