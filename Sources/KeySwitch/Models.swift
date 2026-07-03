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
        case mediaKeyEvent
        case mouseEvent
        case ping
        case pong
        case status
        case querySetup
        case setupStatus
        case pairRequest
        case pairResponse
        case clipboardSync
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
    // mediaKeyEvent payload
    var nxKeyType: Int32?
    // mouseEvent payload
    var mouseKind: String?   // move, leftDown, leftUp, rightDown, rightUp, otherDown, otherUp, scroll
    var dx: Double?
    var dy: Double?
    var scrollDX: Int64?
    var scrollDY: Int64?
    var button: Int64?
    // pairResponse payload
    var approved: Bool?
    // clipboardSync payload
    var clipboardText: String?
}

struct AppConfig: Codable, Equatable {
    var peerHostName: String
    var peerAddress: String
    var pairingToken: String
    var isKeyboardOwner: Bool
    var thisMacName: String
    var listenPort: UInt16
    // 0 = "auto-detect the external device" (never a built-in keyboard/trackpad).
    var externalKeyboardVendorID: Int
    var externalKeyboardProductID: Int
    var externalKeyboardName: String
    var externalMouseVendorID: Int
    var externalMouseProductID: Int
    var externalMouseName: String
    // Off by default: unlike keyboard/mouse forwarding (explicit hotkey, visible
    // in the menu), background clipboard sync copies content across Macs with
    // no per-action confirmation — opt-in is the safer default.
    var shareClipboard: Bool

    static let `default` = AppConfig(
        peerHostName: "",
        peerAddress: "",
        pairingToken: "",
        isKeyboardOwner: false,
        thisMacName: Host.current().localizedName ?? "This Mac",
        listenPort: 9847,
        externalKeyboardVendorID: 0,
        externalKeyboardProductID: 0,
        externalKeyboardName: "",
        externalMouseVendorID: 0,
        externalMouseProductID: 0,
        externalMouseName: "",
        shareClipboard: false
    )

    // Custom decode so configs saved before device selection/clipboard existed
    // still load (new fields default instead of failing the whole decode).
    enum CodingKeys: String, CodingKey {
        case peerHostName, peerAddress, pairingToken, isKeyboardOwner, thisMacName, listenPort
        case externalKeyboardVendorID, externalKeyboardProductID, externalKeyboardName
        case externalMouseVendorID, externalMouseProductID, externalMouseName
        case shareClipboard
    }

    init(
        peerHostName: String, peerAddress: String, pairingToken: String, isKeyboardOwner: Bool,
        thisMacName: String, listenPort: UInt16,
        externalKeyboardVendorID: Int, externalKeyboardProductID: Int, externalKeyboardName: String,
        externalMouseVendorID: Int, externalMouseProductID: Int, externalMouseName: String,
        shareClipboard: Bool
    ) {
        self.peerHostName = peerHostName
        self.peerAddress = peerAddress
        self.pairingToken = pairingToken
        self.isKeyboardOwner = isKeyboardOwner
        self.thisMacName = thisMacName
        self.listenPort = listenPort
        self.externalKeyboardVendorID = externalKeyboardVendorID
        self.externalKeyboardProductID = externalKeyboardProductID
        self.externalKeyboardName = externalKeyboardName
        self.externalMouseVendorID = externalMouseVendorID
        self.externalMouseProductID = externalMouseProductID
        self.externalMouseName = externalMouseName
        self.shareClipboard = shareClipboard
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        peerHostName = try c.decode(String.self, forKey: .peerHostName)
        peerAddress = try c.decode(String.self, forKey: .peerAddress)
        pairingToken = try c.decode(String.self, forKey: .pairingToken)
        isKeyboardOwner = try c.decode(Bool.self, forKey: .isKeyboardOwner)
        thisMacName = try c.decode(String.self, forKey: .thisMacName)
        listenPort = try c.decode(UInt16.self, forKey: .listenPort)
        externalKeyboardVendorID = try c.decodeIfPresent(Int.self, forKey: .externalKeyboardVendorID) ?? 0
        externalKeyboardProductID = try c.decodeIfPresent(Int.self, forKey: .externalKeyboardProductID) ?? 0
        externalKeyboardName = try c.decodeIfPresent(String.self, forKey: .externalKeyboardName) ?? ""
        externalMouseVendorID = try c.decodeIfPresent(Int.self, forKey: .externalMouseVendorID) ?? 0
        externalMouseProductID = try c.decodeIfPresent(Int.self, forKey: .externalMouseProductID) ?? 0
        externalMouseName = try c.decodeIfPresent(String.self, forKey: .externalMouseName) ?? ""
        shareClipboard = try c.decodeIfPresent(Bool.self, forKey: .shareClipboard) ?? false
    }
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