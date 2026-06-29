import Foundation
import Network

final class PeerNetwork: ObservableObject {
    static let shared = PeerNetwork()

    @MainActor @Published private(set) var isListening = false
    @MainActor @Published private(set) var discoveredPeers: [String] = []
    @MainActor @Published private(set) var lastStatusMessage: String?

    private var listener: NWListener?
    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "com.keyswitch.network")

    private init() {}

    @MainActor
    func start(config: AppConfig) {
        stop()
        startListener(port: config.listenPort)
        startBrowser()
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

    private func startListener(port: UInt16) {
        do {
            let params = NWParameters.tcp
            let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
            listener.service = NWListener.Service(name: Host.current().localizedName ?? "KeySwitch", type: "_keyswitch._tcp")
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

    private func startBrowser() {
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
            let selfName = Host.current().localizedName ?? ""
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
        receiveMessage(on: connection) { message in
            Task { @MainActor in
                await PeerNetwork.shared.processIncoming(message, connection: connection)
            }
        }
    }

    @MainActor
    private func processIncoming(_ message: PeerMessage, connection: NWConnection) async {
        let config = ConfigStore.shared.config

        guard message.token == config.pairingToken, !config.pairingToken.isEmpty else {
            send(message: PeerMessage(action: .status, deviceAddress: nil, hostName: config.thisMacName, token: nil), on: connection)
            connection.cancel()
            return
        }

        switch message.action {
        case .ping:
            send(message: PeerMessage(action: .pong, deviceAddress: nil, hostName: config.thisMacName, token: config.pairingToken), on: connection)
        case .connectKeyboard:
            guard let address = message.deviceAddress else { break }
            do {
                try await BluetoothManager.shared.connectFromPeer(address: address)
                lastStatusMessage = "Connected keyboard from \(message.hostName ?? "peer")"
                send(message: PeerMessage(action: .status, deviceAddress: address, hostName: config.thisMacName, token: config.pairingToken), on: connection)
            } catch {
                lastStatusMessage = error.localizedDescription
            }
        case .disconnectKeyboard:
            guard let address = message.deviceAddress else { break }
            do {
                try await BluetoothManager.shared.releaseForHandoff(address: address)
                send(message: PeerMessage(action: .status, deviceAddress: address, hostName: config.thisMacName, token: config.pairingToken), on: connection)
            } catch {
                lastStatusMessage = error.localizedDescription
            }
        default:
            break
        }
        connection.cancel()
    }

    func send(action: PeerMessage.Action, config: AppConfig) async throws -> PeerMessage? {
        let endpoint = resolvedPeerEndpoint(config: config)
        guard endpoint != nil else { throw SwitchError.peerUnreachable }

        return try await withCheckedThrowingContinuation { continuation in
            let connection = NWConnection(to: endpoint!, using: .tcp)
            var finished = false
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let message = PeerMessage(
                        action: action,
                        deviceAddress: config.keyboardAddress,
                        hostName: config.thisMacName,
                        token: config.pairingToken
                    )
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

    func ping(config: AppConfig) async -> Bool {
        do {
            let response = try await send(action: .ping, config: config)
            return response?.action == .pong
        } catch {
            return false
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
                if let message = try? JSONDecoder().decode(PeerMessage.self, from: body) {
                    handler(message)
                }
                connection.cancel()
            }
        }
    }
}