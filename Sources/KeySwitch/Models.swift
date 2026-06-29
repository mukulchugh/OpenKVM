import Foundation

struct PeerMessage: Codable, Sendable {
    enum Action: String, Codable, Sendable {
        case connectKeyboard
        case disconnectKeyboard
        case ping
        case pong
        case status
    }

    let action: Action
    let deviceAddress: String?
    let hostName: String?
    let token: String?
}

struct AppConfig: Codable, Equatable {
    var peerHostName: String
    var peerAddress: String
    var pairingToken: String
    var keyboardAddress: String
    var keyboardName: String
    var thisMacName: String
    var listenPort: UInt16

    static let `default` = AppConfig(
        peerHostName: "",
        peerAddress: "",
        pairingToken: "",
        keyboardAddress: "",
        keyboardName: "",
        thisMacName: Host.current().localizedName ?? "This Mac",
        listenPort: 9847
    )
}

struct BluetoothDeviceInfo: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let address: String
    let isConnected: Bool
    let isKeyboard: Bool
}

enum SwitchError: LocalizedError {
    case bluetoothUnavailable
    case deviceNotFound
    case notPaired
    case peerUnreachable
    case authFailed
    case alreadyOnPeer
    case operationFailed(String)

    var errorDescription: String? {
        switch self {
        case .bluetoothUnavailable:
            return "Bluetooth is unavailable. Enable it in System Settings."
        case .deviceNotFound:
            return "Keyboard not found. Pair it in System Settings → Bluetooth on both Macs."
        case .notPaired:
            return "Keyboard is not paired to this Mac."
        case .peerUnreachable:
            return "Other Mac is unreachable. Is KeySwitch running on both machines?"
        case .authFailed:
            return "Pairing token mismatch. Use the same token on both Macs."
        case .alreadyOnPeer:
            return "Keyboard is already on the other Mac."
        case .operationFailed(let detail):
            return detail
        }
    }
}