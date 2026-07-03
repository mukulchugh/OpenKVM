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
    private var udpListener: NWListener?
    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "com.openkvm.network")
    private let encoder = JSONEncoder()

    // The forwarding stream and cached auth are touched only on the main thread:
    // beginKeyForwarding/stopKeyForwarding are @MainActor, and the event-tap
    // callback runs on the main run loop. nonisolated(unsafe) documents that.
    // outboundStream (TCP) carries keys + buttons, which must never be dropped.
    // outboundUDP carries move/scroll: high-rate and loss-tolerant, so a dropped
    // or reordered packet just gets superseded by the next delta — no TCP
    // head-of-line blocking stalling the whole stream when WiFi hiccups.
    nonisolated(unsafe) private var outboundStream: NWConnection?
    nonisolated(unsafe) private var outboundUDP: NWConnection?
    nonisolated(unsafe) private var fwdToken = ""
    nonisolated(unsafe) private var fwdHost = ""
    nonisolated(unsafe) private var localToken = "" // this Mac's token, for authing incoming hot events

    // Move/scroll coalescing state — accumulated and flushed only on `queue`.
    nonisolated(unsafe) private var pendingDX = 0.0
    nonisolated(unsafe) private var pendingDY = 0.0
    nonisolated(unsafe) private var pendingScrollDX: Int64 = 0
    nonisolated(unsafe) private var pendingScrollDY: Int64 = 0
    nonisolated(unsafe) private var hasPendingMove = false
    nonisolated(unsafe) private var hasPendingScroll = false
    nonisolated(unsafe) private var pendingFlags: UInt64 = 0 // latest modifier state seen this window
    nonisolated(unsafe) private var trailingArmed = false
    // Leading-edge throttle: the first move after idle sends instantly (native
    // latency); rapid follow-ups within this window coalesce into one packet.
    private static let flushIntervalMs = 5

    private init() {}

    /// TCP with Nagle's algorithm disabled — critical for mouse smoothness, since
    /// Nagle would buffer each tiny move packet and add tens of ms of latency.
    private static func lowLatencyParams() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 2
        return NWParameters(tls: nil, tcp: tcp)
    }

    @MainActor private var wantsListening = false

    @MainActor
    func start(config: AppConfig) {
        stop()
        wantsListening = true
        localToken = config.pairingToken
        startListener(port: config.listenPort, serviceName: config.thisMacName)
        startUDPListener(port: config.listenPort)
        startBrowser(excludingName: config.thisMacName)
    }

    @MainActor
    func stop() {
        wantsListening = false
        listener?.cancel()
        listener = nil
        udpListener?.cancel()
        udpListener = nil
        browser?.cancel()
        browser = nil
        isListening = false
        discoveredPeers = []
    }

    /// The listener can fail to bind if a just-killed instance still holds the
    /// port (the recurring "app running but not listening" bug). Self-heal by
    /// retrying until it binds, as long as we still want to listen.
    @MainActor
    private func retryListenerSoon(port: UInt16, serviceName: String) {
        guard wantsListening else { return }
        listener?.cancel()
        listener = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.wantsListening, self.listener == nil else { return }
            self.startListener(port: port, serviceName: serviceName)
        }
    }

    @MainActor
    private func retryUDPListenerSoon(port: UInt16) {
        guard wantsListening else { return }
        udpListener?.cancel()
        udpListener = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.wantsListening, self.udpListener == nil else { return }
            self.startUDPListener(port: port)
        }
    }

    private func startUDPListener(port: UInt16) {
        do {
            let listener = try NWListener(using: .udp, on: NWEndpoint.Port(rawValue: port)!)
            listener.stateUpdateHandler = { state in
                if case .failed = state {
                    Task { @MainActor in PeerNetwork.shared.retryUDPListenerSoon(port: port) }
                }
            }
            listener.newConnectionHandler = { connection in
                connection.start(queue: PeerNetwork.shared.queue)
                PeerNetwork.shared.receiveDatagramLoop(on: connection)
            }
            listener.start(queue: queue)
            self.udpListener = listener
        } catch {
            Task { @MainActor in PeerNetwork.shared.retryUDPListenerSoon(port: port) }
        }
    }

    /// UDP datagrams need no length-prefix framing — one receive = one message.
    private func receiveDatagramLoop(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            if let data, !data.isEmpty, let message = try? JSONDecoder().decode(PeerMessage.self, from: data) {
                _ = self?.injectHotInput(message)
            }
            guard error == nil else { return }
            self?.receiveDatagramLoop(on: connection)
        }
    }

    private func startListener(port: UInt16, serviceName: String) {
        do {
            let params = Self.lowLatencyParams()
            let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
            let advertisedName = serviceName.isEmpty ? (Host.current().localizedName ?? "OpenKVM") : serviceName
            listener.service = NWListener.Service(name: advertisedName, type: "_openkvm._tcp")
            listener.stateUpdateHandler = { state in
                Task { @MainActor in
                    let net = PeerNetwork.shared
                    switch state {
                    case .ready:
                        net.isListening = true
                    case .failed:
                        net.isListening = false
                        net.retryListenerSoon(port: port, serviceName: serviceName)
                    case .cancelled:
                        net.isListening = false
                    default:
                        break
                    }
                }
            }
            listener.newConnectionHandler = { connection in
                PeerNetwork.shared.handleIncoming(connection)
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            Task { @MainActor in
                PeerNetwork.shared.lastStatusMessage = "Listener bind failed, retrying…"
                PeerNetwork.shared.retryListenerSoon(port: port, serviceName: serviceName)
            }
        }
    }

    private func startBrowser(excludingName: String) {
        let params = NWParameters.tcp
        let browser = NWBrowser(for: .bonjour(type: "_openkvm._tcp", domain: nil), using: params)
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
            // Hot input injects synchronously on this network queue — no MainActor
            // hop — so pointer/key timing stays even. Control messages still take
            // the @MainActor path.
            if PeerNetwork.shared.injectHotInput(message) {
                PeerNetwork.shared.receiveNext(on: connection)
            } else {
                Task { @MainActor in
                    await PeerNetwork.shared.processIncoming(message, connection: connection)
                }
            }
        }
    }

    nonisolated private func injectHotInput(_ m: PeerMessage) -> Bool {
        guard !localToken.isEmpty, m.token == localToken else { return false }
        switch m.action {
        case .keyEvent:
            if let kc = m.keyCode, let kd = m.keyDown {
                InputBridge.shared.inject(keyCode: kc, keyDown: kd, flags: m.flags ?? 0, isFlagsChanged: m.isFlagsChanged ?? false)
            }
            return true
        case .mediaKeyEvent:
            if let nx = m.nxKeyType, let kd = m.keyDown {
                InputBridge.shared.injectMediaKey(nxKeyType: nx, keyDown: kd)
            }
            return true
        case .mouseEvent:
            if let kind = m.mouseKind {
                InputBridge.shared.injectMouse(MousePayload(
                    kind: kind, dx: m.dx ?? 0, dy: m.dy ?? 0,
                    scrollDX: m.scrollDX ?? 0, scrollDY: m.scrollDY ?? 0, button: m.button ?? 0,
                    flags: m.flags ?? 0))
            }
            return true
        default:
            return false
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
        case .clipboardSync:
            if config.shareClipboard, let text = message.clipboardText {
                ClipboardSync.shared.applyRemote(text: text)
            }
            await sendAndClose(
                PeerMessage(action: .status, hostName: config.thisMacName, token: config.pairingToken, setupStatus: nil),
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
                    button: message.button ?? 0,
                    flags: message.flags ?? 0
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

    /// Fire-and-forget: clipboard changes are infrequent and non-critical if one
    /// send fails (the next clipboard change will sync anyway).
    func sendClipboard(text: String, config: AppConfig) async {
        guard let endpoint = resolvedPeerEndpoint(config: config) else { return }
        var message = PeerMessage(action: .clipboardSync, hostName: config.thisMacName, token: config.pairingToken, setupStatus: nil)
        message.clipboardText = text
        _ = try? await request(message, to: endpoint)
    }

    private func request(_ message: PeerMessage, to endpoint: NWEndpoint) async throws -> PeerMessage? {
        try await withCheckedThrowingContinuation { continuation in
            let connection = NWConnection(to: endpoint, using: Self.lowLatencyParams())
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
        let endpoint = NWEndpoint.service(name: peerName, type: "_openkvm._tcp", domain: "local.", interface: nil)
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

        let connection = NWConnection(to: endpoint, using: Self.lowLatencyParams())
        outboundStream = connection
        fwdToken = config.pairingToken
        fwdHost = config.thisMacName

        let udp = NWConnection(to: endpoint, using: .udp)
        udp.start(queue: queue)
        outboundUDP = udp

        startMoveFlush()
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
                            InputBridge.shared.forwardingDropped()
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
        stopMoveFlush()
        outboundStream?.cancel()
        outboundStream = nil
        outboundUDP?.cancel()
        outboundUDP = nil
    }

    // Hot send path. Moves and scrolls are COALESCED: their deltas accumulate on
    // the serial network queue and flush as one packet on a ~125Hz timer, so WiFi
    // packet jitter never reaches the cursor/scroll. Keys and buttons send
    // immediately (buttons flush any pending move/scroll first, to keep order).
    // Everything runs on `queue`, so there are no locks and one encoder is safe.

    func sendKeyEvent(keyCode: UInt16, keyDown: Bool, flags: UInt64, isFlagsChanged: Bool) {
        var message = PeerMessage(action: .keyEvent, hostName: fwdHost, token: fwdToken, setupStatus: nil)
        message.keyCode = keyCode
        message.keyDown = keyDown
        message.flags = flags
        message.isFlagsChanged = isFlagsChanged
        queue.async { [self] in emitOnQueue(message) }
    }

    func sendMediaKey(nxKeyType: Int32, keyDown: Bool) {
        var message = PeerMessage(action: .mediaKeyEvent, hostName: fwdHost, token: fwdToken, setupStatus: nil)
        message.nxKeyType = nxKeyType
        message.keyDown = keyDown
        queue.async { [self] in emitOnQueue(message) }
    }

    func sendMouseEvent(_ m: MousePayload) {
        switch m.kind {
        case "move":
            queue.async { [self] in
                pendingDX += m.dx; pendingDY += m.dy; hasPendingMove = true; pendingFlags = m.flags
                schedulePumpOnQueue()
            }
        case "scroll":
            queue.async { [self] in
                pendingScrollDX += m.scrollDX; pendingScrollDY += m.scrollDY; hasPendingScroll = true; pendingFlags = m.flags
                schedulePumpOnQueue()
            }
        default: // buttons: flush pending move/scroll for ordering, then send now
            queue.async { [self] in
                flushPendingOnQueue()
                var message = PeerMessage(action: .mouseEvent, hostName: fwdHost, token: fwdToken, setupStatus: nil)
                message.mouseKind = m.kind
                message.button = m.button
                message.flags = m.flags
                emitOnQueue(message)
            }
        }
    }

    /// Always coalesce for a short fixed window instead of leading-edge-flushing
    /// the very first event. HID delivers X and Y deltas as SEPARATE callbacks
    /// (unlike CGEventTap, which gave both in one event) — an instant flush on
    /// the first one split every diagonal move into a jagged two-step motion.
    /// Waiting a few ms guarantees both axes from the same physical HID report
    /// land in the same packet.
    private func schedulePumpOnQueue() {
        guard !trailingArmed else { return }
        trailingArmed = true
        queue.asyncAfter(deadline: .now() + .milliseconds(Self.flushIntervalMs)) { [self] in
            trailingArmed = false
            flushPendingOnQueue()
        }
    }

    /// Flush accumulated move + scroll as at most one packet each, over UDP —
    /// not TCP — so a lost/delayed packet never blocks the ones behind it. MUST
    /// run on `queue`.
    private func flushPendingOnQueue() {
        if hasPendingMove {
            let dx = pendingDX, dy = pendingDY
            pendingDX = 0; pendingDY = 0; hasPendingMove = false
            var message = PeerMessage(action: .mouseEvent, hostName: fwdHost, token: fwdToken, setupStatus: nil)
            message.mouseKind = "move"; message.dx = dx; message.dy = dy; message.flags = pendingFlags
            emitUDP(message)
        }
        if hasPendingScroll {
            let sx = pendingScrollDX, sy = pendingScrollDY
            pendingScrollDX = 0; pendingScrollDY = 0; hasPendingScroll = false
            var message = PeerMessage(action: .mouseEvent, hostName: fwdHost, token: fwdToken, setupStatus: nil)
            message.mouseKind = "scroll"; message.scrollDX = sx; message.scrollDY = sy; message.flags = pendingFlags
            emitUDP(message)
        }
    }

    /// MUST run on `queue` (uses the shared encoder single-threaded). TCP path
    /// for keys/buttons, which must arrive reliably and in order.
    private func emitOnQueue(_ message: PeerMessage) {
        guard let connection = outboundStream, let data = try? encoder.encode(message) else { return }
        var framed = Data(capacity: data.count + 4)
        var length = UInt32(data.count).bigEndian
        withUnsafeBytes(of: &length) { framed.append(contentsOf: $0) }
        framed.append(data)
        connection.send(content: framed, completion: .idempotent)
    }

    /// UDP path for move/scroll — connectionless, no framing, no head-of-line
    /// blocking. MUST run on `queue`.
    private func emitUDP(_ message: PeerMessage) {
        guard let connection = outboundUDP, let data = try? encoder.encode(message) else { return }
        connection.send(content: data, completion: .idempotent)
    }

    private func startMoveFlush() {
        queue.async { [self] in
            pendingDX = 0; pendingDY = 0; hasPendingMove = false
            pendingScrollDX = 0; pendingScrollDY = 0; hasPendingScroll = false
            trailingArmed = false
        }
    }

    private func stopMoveFlush() {
        queue.async { [self] in flushPendingOnQueue() }
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
            return (false, "Unexpected peer response. Is OpenKVM running on the other Mac?")
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
                type: "_openkvm._tcp",
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