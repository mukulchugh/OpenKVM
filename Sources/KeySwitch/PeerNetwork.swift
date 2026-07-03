import AppKit
import Foundation
import Network

final class PeerNetwork: ObservableObject {
    static let shared = PeerNetwork()

    @MainActor @Published private(set) var isListening = false
    @MainActor @Published private(set) var discoveredPeers: [String] = []
    @MainActor @Published private(set) var lastStatusMessage: String?
    @MainActor @Published private(set) var peerSetupStatus: PeerSetupSnapshot?
    @MainActor @Published private(set) var peerSetupError: String?
    @MainActor @Published private(set) var isFetchingPeerSetup = false

    private var listener: NWListener?
    private var browser: NWBrowser?
    private var outboundStream: NWConnection?
    private let queue = DispatchQueue(label: "com.keyswitch.network")

    private init() {}

    @MainActor
    func start(config: AppConfig) {
        stop()
        startListener(port: config.listenPort, serviceName: config.thisMacName)
        startBrowser(excludingName: config.thisMacName)
    }

    @MainActor
    func stop() {
        listener?.cancel()
        listener = nil
        browser?.cancel()
        browser = nil
        isListening = false
        discoveredPeers = []
    }

    private func startListener(port: UInt16, serviceName: String) {
        do {
            let params = NWParameters.tcp
            let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
            let advertisedName = serviceName.isEmpty ? (Host.current().localizedName ?? "KeySwitch") : serviceName
            listener.service = NWListener.Service(name: advertisedName, type: "_keyswitch._tcp")
            listener.stateUpdateHandler = { state in
                Task { @MainActor in
                    PeerNetwork.shared.isListening = (state == .ready)
                }
            }
            listener.newConnectionHandler = { connection in
                PeerNetwork.shared.handleIncoming(connection)
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            Task { @MainActor in
                PeerNetwork.shared.lastStatusMessage = "Failed to start listener: \(error.localizedDescription)"
            }
        }
    }

    private func startBrowser(excludingName: String) {
        let params = NWParameters.tcp
        let browser = NWBrowser(for: .bonjour(type: "_keyswitch._tcp", domain: nil), using: params)
        browser.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                Task { @MainActor in
                    PeerNetwork.shared.lastStatusMessage = "Discovery failed: \(error.localizedDescription)"
                }
            }
        }
        browser.browseResultsChangedHandler = { results, _ in
            let selfName = excludingName.isEmpty ? (Host.current().localizedName ?? "") : excludingName
            let names = results.compactMap { result -> String? in
                if case .service(let name, _, _, _) = result.endpoint,
                   name != selfName {
                    return name
                }
                return nil
            }
            Task { @MainActor in
                PeerNetwork.shared.discoveredPeers = names
            }
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    private func handleIncoming(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveNext(on: connection)
    }

    private func receiveNext(on connection: NWConnection) {
        receiveMessage(on: connection) { message in
            Task { @MainActor in
                await PeerNetwork.shared.processIncoming(message, connection: connection)
            }
        }
    }

    @MainActor
    private func processIncoming(_ message: PeerMessage, connection: NWConnection) async {
        let config = ConfigStore.shared.config

        if message.action == .pairRequest {
            await handlePairRequest(message, connection: connection, config: config)
            return
        }

        guard message.token == config.pairingToken, !config.pairingToken.isEmpty else {
            await sendAndClose(
                PeerMessage(action: .status, hostName: config.thisMacName, token: nil, setupStatus: nil),
                on: connection
            )
            return
        }

        switch message.action {
        case .ping:
            await sendAndClose(
                PeerMessage(action: .pong, hostName: config.thisMacName, token: config.pairingToken, setupStatus: nil),
                on: connection
            )
        case .querySetup:
            await sendAndClose(
                PeerMessage(
                    action: .setupStatus,
                    hostName: config.thisMacName,
                    token: config.pairingToken,
                    setupStatus: localSetupSnapshot(config: config)
                ),
                on: connection
            )
        case .keyEvent:
            guard let keyCode = message.keyCode, let keyDown = message.keyDown else {
                receiveNext(on: connection)
                return
            }
            InputBridge.shared.inject(
                keyCode: keyCode,
                keyDown: keyDown,
                flags: message.flags ?? 0,
                isFlagsChanged: message.isFlagsChanged ?? false
            )
            // Stream connection: keep reading further key events, never close.
            receiveNext(on: connection)
        case .mouseEvent:
            if let kind = message.mouseKind {
                InputBridge.shared.injectMouse(MousePayload(
                    kind: kind,
                    dx: message.dx ?? 0,
                    dy: message.dy ?? 0,
                    scrollDX: message.scrollDX ?? 0,
                    scrollDY: message.scrollDY ?? 0,
                    button: message.button ?? 0
                ))
            }
            receiveNext(on: connection)
        default:
            connection.cancel()
        }
    }

    func send(action: PeerMessage.Action, config: AppConfig) async throws -> PeerMessage? {
        guard let endpoint = resolvedPeerEndpoint(config: config) else { throw SwitchError.peerUnreachable }
        let message = PeerMessage(action: action, hostName: config.thisMacName, token: config.pairingToken, setupStatus: nil)
        return try await request(message, to: endpoint)
    }

    private func request(_ message: PeerMessage, to endpoint: NWEndpoint) async throws -> PeerMessage? {
        try await withCheckedThrowingContinuation { continuation in
            let connection = NWConnection(to: endpoint, using: .tcp)
            var finished = false
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    PeerNetwork.shared.send(message: message, on: connection) {
                        PeerNetwork.shared.receiveMessage(on: connection) { response in
                            guard !finished else { return }
                            finished = true
                            connection.cancel()
                            continuation.resume(returning: response)
                        }
                    }
                case .failed(let error):
                    guard !finished else { return }
                    finished = true
                    connection.cancel()
                    continuation.resume(throwing: SwitchError.operationFailed(error.localizedDescription))
                case .cancelled:
                    break
                default:
                    break
                }
            }
            connection.start(queue: queue)

            queue.asyncAfter(deadline: .now() + 8) {
                guard !finished else { return }
                if connection.state != .cancelled {
                    finished = true
                    connection.cancel()
                    continuation.resume(throwing: SwitchError.peerUnreachable)
                }
            }
        }
    }

    // MARK: - One-click pairing (approve-on-the-other-Mac, no manual token typing)

    /// Sends a pairing request to a discovered peer by Bonjour name. The peer shows
    /// an approval prompt; on approval it shares its pairing token (generating one
    /// if it doesn't have one yet) so both Macs end up with the same token.
    @MainActor
    func requestPairing(peerName: String) async -> Result<(token: String, hostName: String), SwitchError> {
        let endpoint = NWEndpoint.service(name: peerName, type: "_keyswitch._tcp", domain: "local.", interface: nil)
        let message = PeerMessage(action: .pairRequest, hostName: ConfigStore.shared.config.thisMacName, token: nil, setupStatus: nil)
        do {
            let response = try await request(message, to: endpoint)
            guard response?.action == .pairResponse else {
                return .failure(.operationFailed("Unexpected response from \(peerName)."))
            }
            guard response?.approved == true, let token = response?.token, let hostName = response?.hostName else {
                return .failure(.operationFailed("Pairing was declined on \(peerName)."))
            }
            return .success((token, hostName))
        } catch let error as SwitchError {
            return .failure(error)
        } catch {
            return .failure(.operationFailed(error.localizedDescription))
        }
    }

    @MainActor
    private func handlePairRequest(_ message: PeerMessage, connection: NWConnection, config: AppConfig) async {
        let requesterName = message.hostName ?? "Another Mac"
        let approved = await confirmPairing(with: requesterName)

        var token = config.pairingToken
        if approved && token.isEmpty {
            token = String(UUID().uuidString.prefix(12))
            ConfigStore.shared.config.pairingToken = token
        }

        await sendAndClose(
            PeerMessage(
                action: .pairResponse,
                hostName: config.thisMacName,
                token: approved ? token : nil,
                setupStatus: nil,
                approved: approved
            ),
            on: connection
        )
    }

    @MainActor
    private func confirmPairing(with requesterName: String) async -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Pair with \(requesterName)?"
        alert.informativeText = "\(requesterName) wants to share its pairing token with this Mac so keyboard forwarding can be set up without typing a passphrase."
        alert.addButton(withTitle: "Approve")
        alert.addButton(withTitle: "Decline")
        alert.alertStyle = .informational
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: - Key event stream (owner side, persistent outbound connection)

    @MainActor
    func beginKeyForwarding(config: AppConfig) async -> Bool {
        stopKeyForwarding()
        guard let endpoint = resolvedPeerEndpoint(config: config) else {
            lastStatusMessage = "Configure the other Mac first."
            return false
        }

        let connection = NWConnection(to: endpoint, using: .tcp)
        outboundStream = connection
        return await withCheckedContinuation { continuation in
            var resumed = false
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    guard !resumed else { return }
                    resumed = true
                    continuation.resume(returning: true)
                case .failed, .cancelled:
                    Task { @MainActor in
                        if self?.outboundStream === connection {
                            self?.stopKeyForwarding()
                        }
                    }
                    guard !resumed else { return }
                    resumed = true
                    continuation.resume(returning: false)
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    @MainActor
    func stopKeyForwarding() {
        outboundStream?.cancel()
        outboundStream = nil
    }

    func sendKeyEvent(keyCode: UInt16, keyDown: Bool, flags: UInt64, isFlagsChanged: Bool, config: AppConfig) {
        guard let connection = outboundStream else { return }
        let message = PeerMessage(
            action: .keyEvent,
            hostName: config.thisMacName,
            token: config.pairingToken,
            setupStatus: nil,
            keyCode: keyCode,
            keyDown: keyDown,
            flags: flags,
            isFlagsChanged: isFlagsChanged
        )
        send(message: message, on: connection)
    }

    func sendMouseEvent(_ m: MousePayload, config: AppConfig) {
        guard let connection = outboundStream else { return }
        var message = PeerMessage(
            action: .mouseEvent,
            hostName: config.thisMacName,
            token: config.pairingToken,
            setupStatus: nil
        )
        message.mouseKind = m.kind
        message.dx = m.dx
        message.dy = m.dy
        message.scrollDX = m.scrollDX
        message.scrollDY = m.scrollDY
        message.button = m.button
        send(message: message, on: connection)
    }

    @MainActor
    func fetchPeerSetupStatus(config: AppConfig) async {
        isFetchingPeerSetup = true
        defer { isFetchingPeerSetup = false }

        guard !config.pairingToken.isEmpty else {
            peerSetupStatus = nil
            peerSetupError = "Set a pairing token to query the other Mac."
            return
        }
        guard !config.peerAddress.isEmpty || !config.peerHostName.isEmpty else {
            peerSetupStatus = nil
            peerSetupError = "Configure the other Mac's name or IP first."
            return
        }

        do {
            let response = try await send(action: .querySetup, config: config)
            if response?.action == .setupStatus, let snapshot = response?.setupStatus {
                peerSetupStatus = snapshot
                peerSetupError = nil
                return
            }
            if response?.action == .status {
                peerSetupStatus = nil
                peerSetupError = "Token mismatch on the other Mac."
                return
            }
            peerSetupStatus = nil
            peerSetupError = "Unexpected response from the other Mac."
        } catch let error as SwitchError {
            peerSetupStatus = nil
            peerSetupError = error.localizedDescription
        } catch {
            peerSetupStatus = nil
            peerSetupError = error.localizedDescription
        }
    }

    @MainActor
    private func localSetupSnapshot(config: AppConfig) -> PeerSetupSnapshot {
        InputBridge.shared.refreshPermissions()
        return PeerSetupSnapshot(
            hostName: config.thisMacName,
            isKeyboardOwner: config.isKeyboardOwner,
            tokenSet: !config.pairingToken.isEmpty,
            peerConfigured: !config.peerHostName.isEmpty || !config.peerAddress.isEmpty,
            networkListening: isListening,
            listenPort: config.listenPort,
            canPost: InputBridge.shared.canPost,
            canCapture: InputBridge.shared.canCapture
        )
    }

    func ping(config: AppConfig) async -> (ok: Bool, detail: String) {
        guard !config.pairingToken.isEmpty else {
            return (false, "Set a pairing token first.")
        }
        guard !config.peerAddress.isEmpty || !config.peerHostName.isEmpty else {
            return (false, "Set the other Mac's name or IP in Other Mac.")
        }
        do {
            let response = try await send(action: .ping, config: config)
            if response?.action == .pong {
                return (true, "OK — peer reachable with matching token")
            }
            if response?.action == .status {
                return (false, "Token mismatch — use the same token on both Macs.")
            }
            return (false, "Unexpected peer response. Is KeySwitch running on the other Mac?")
        } catch let error as SwitchError {
            return (false, error.localizedDescription)
        } catch {
            return (false, error.localizedDescription)
        }
    }

    private func resolvedPeerEndpoint(config: AppConfig) -> NWEndpoint? {
        if !config.peerAddress.isEmpty {
            return NWEndpoint.hostPort(
                host: NWEndpoint.Host(config.peerAddress),
                port: NWEndpoint.Port(rawValue: config.listenPort)!
            )
        }
        if !config.peerHostName.isEmpty {
            return NWEndpoint.service(
                name: config.peerHostName,
                type: "_keyswitch._tcp",
                domain: "local.",
                interface: nil
            )
        }
        return nil
    }

    @MainActor
    private func sendAndClose(_ message: PeerMessage, on connection: NWConnection) async {
        await withCheckedContinuation { continuation in
            send(message: message, on: connection) {
                continuation.resume()
            }
        }
        connection.cancel()
    }

    private func send(message: PeerMessage, on connection: NWConnection, completion: (() -> Void)? = nil) {
        guard let data = try? JSONEncoder().encode(message) else { return }
        var framed = Data()
        var length = UInt32(data.count).bigEndian
        framed.append(Data(bytes: &length, count: 4))
        framed.append(data)
        connection.send(content: framed, completion: .contentProcessed { _ in
            completion?()
        })
    }

    private func receiveMessage(on connection: NWConnection, handler: @escaping (PeerMessage) -> Void) {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { header, _, _, error in
            guard error == nil, let header, header.count == 4 else {
                connection.cancel()
                return
            }
            let length = header.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
            connection.receive(minimumIncompleteLength: Int(length), maximumLength: Int(length)) { body, _, _, error in
                guard error == nil, let body else {
                    connection.cancel()
                    return
                }
                guard let message = try? JSONDecoder().decode(PeerMessage.self, from: body) else {
                    connection.cancel()
                    return
                }
                handler(message)
            }
        }
    }
}