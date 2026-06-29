import Foundation

@MainActor
final class SwitchCoordinator: ObservableObject {
    static let shared = SwitchCoordinator()

    @Published private(set) var isSwitching = false
    @Published private(set) var lastMessage: String?

    private init() {}

    var canConnectHere: Bool {
        !ConfigStore.shared.config.keyboardAddress.isEmpty
    }

    var canSwitchToPeer: Bool {
        ConfigStore.shared.isConfigured
    }

    func switchToThisMac() async {
        let config = ConfigStore.shared.config
        guard canConnectHere else {
            lastMessage = "Open Settings and select your keyboard first."
            return
        }

        let address = BluetoothAddress.normalize(config.keyboardAddress)
        guard !BluetoothManager.shared.keyboardConnected(address: address) else {
            lastMessage = "Keyboard is already connected here."
            return
        }

        isSwitching = true
        defer { isSwitching = false }

        do {
            if ConfigStore.shared.isConfigured {
                // Best effort: ask peer to release. Continue even if peer is offline.
                _ = try? await PeerNetwork.shared.send(action: .disconnectKeyboard, config: config)
                try await Task.sleep(nanoseconds: 1_200_000_000)
            }

            try await BluetoothManager.shared.connectFromPeer(address: address)
            lastMessage = "Connected to \(config.thisMacName)"
            BluetoothManager.shared.refresh()
        } catch {
            lastMessage = error.localizedDescription
        }
    }

    func switchToOtherMac() async {
        let config = ConfigStore.shared.config
        guard canSwitchToPeer else {
            lastMessage = "Set peer Mac + token in Settings to switch away."
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
            lastMessage = "Switched to \(config.peerHostName.isEmpty ? "other Mac" : config.peerHostName)"
            BluetoothManager.shared.refresh()
        } catch {
            lastMessage = error.localizedDescription
        }
    }
}