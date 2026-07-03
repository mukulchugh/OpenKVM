import Foundation

struct PeerSetupSnapshot: Codable, Sendable, Equatable {
    var hostName: String
    var isKeyboardOwner: Bool
    var tokenSet: Bool
    var peerConfigured: Bool
    var networkListening: Bool
    var listenPort: UInt16
    // nil when the peer runs an older build
    var canPost: Bool?
    var canCapture: Bool?
}

struct PeerMessage: Codable, Sendable {
    enum Action: String, Codable, Sendable {
        case keyEvent
        case ping
        case pong
        case status
        case querySetup
        case setupStatus
        case pairRequest
        case pairResponse
    }

    let action: Action
    let hostName: String?
    let token: String?
    let setupStatus: PeerSetupSnapshot?
    // keyEvent payload
    var keyCode: UInt16?
    var keyDown: Bool?
    var flags: UInt64?
    var isFlagsChanged: Bool?
    // pairResponse payload
    var approved: Bool?
}

struct AppConfig: Codable, Equatable {
    var peerHostName: String
    var peerAddress: String
    var pairingToken: String
    var isKeyboardOwner: Bool
    var thisMacName: String
    var listenPort: UInt16

    static let `default` = AppConfig(
        peerHostName: "",
        peerAddress: "",
        pairingToken: "",
        isKeyboardOwner: false,
        thisMacName: Host.current().localizedName ?? "This Mac",
        listenPort: 9847
    )
}

enum SwitchError: LocalizedError {
    case peerUnreachable
    case authFailed
    case accessibilityDenied
    case operationFailed(String)

    var errorDescription: String? {
        switch self {
        case .peerUnreachable:
            return "Other Mac is unreachable. Is KeySwitch running on both machines?"
        case .authFailed:
            return "Pairing token mismatch. Use the same token on both Macs."
        case .accessibilityDenied:
            return "Grant Accessibility + Input Monitoring access in System Settings → Privacy & Security, then click Refresh."
        case .operationFailed(let detail):
            return detail
        }
    }
}