import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject private var configStore = ConfigStore.shared
    @ObservedObject private var network = PeerNetwork.shared
    @ObservedObject private var bridge = InputBridge.shared
    @State private var pingResult: String?
    @State private var isPinging = false
    @State private var isPairing = false

    private var peerTitle: String {
        configStore.config.peerHostName.isEmpty ? "Other Mac" : configStore.config.peerHostName
    }

    var body: some View {
        Form {
            Section("This Mac — setup status") {
                localSetupStatus
                if let message = network.lastStatusMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if !network.isListening {
                    Text("Grant Local Network access if macOS prompted, then click Refresh in the menu.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("\(peerTitle) — setup status") {
                peerSetupStatus
                HStack {
                    Button(network.isFetchingPeerSetup ? "Refreshing…" : "Refresh peer status") {
                        Task { await refreshPeerSetup() }
                    }
                    .disabled(network.isFetchingPeerSetup || !canQueryPeer)
                }
            }

            Section("This Mac") {
                TextField("Bonjour name (other Mac uses this)", text: $configStore.config.thisMacName)
                Text("Advertised on the network as “\(configStore.config.thisMacName.isEmpty ? (Host.current().localizedName ?? "KeySwitch") : configStore.config.thisMacName)”")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Stepper(value: Binding(
                    get: { Int(configStore.config.listenPort) },
                    set: { configStore.config.listenPort = UInt16($0) }
                ), in: 1024...65535) {
                    Text("Listen port: \(configStore.config.listenPort)")
                }
                Text("Use the same port on both Macs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Keyboard sharing") {
                Toggle("This Mac has the physical keyboard", isOn: Binding(
                    get: { configStore.config.isKeyboardOwner },
                    set: { newValue in
                        configStore.config.isKeyboardOwner = newValue
                        bridge.updateOwnerState()
                    }
                ))
                Text("Turn this on only on the one Mac your keyboard is actually connected to.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if configStore.config.isKeyboardOwner {
                    if bridge.hasAccessibility {
                        Label("Accessibility access granted", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Label("Accessibility access needed to capture keystrokes", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Button("Open Privacy & Security Settings") { openAccessibilitySettings() }
                    }

                    HStack {
                        Button(bridge.isForwarding ? "Switch keyboard back to this Mac" : "Switch keyboard to other Mac") {
                            Task { await bridge.toggleForwarding() }
                        }
                        .disabled(!bridge.hasAccessibility || !configStore.isConfigured)
                        Text("Shortcut: \(InputBridge.hotkeyDisplay)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let message = bridge.lastMessage {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if bridge.isReceivingFromPeer {
                    Label("Receiving keyboard input from peer", systemImage: "keyboard.badge.ellipsis")
                        .foregroundStyle(.green)
                }
            }

            Section("Other Mac") {
                TextField("Peer name (Bonjour)", text: $configStore.config.peerHostName)
                TextField("Peer IP (optional fallback)", text: $configStore.config.peerAddress)
                if !configStore.config.peerAddress.isEmpty {
                    Text("IP is used first. Clear it if Bonjour discovery should be used instead.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if network.discoveredPeers.isEmpty {
                    Text("No peers found. KeySwitch must be running on the other Mac on the same Wi‑Fi.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Discovered on network:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(network.discoveredPeers, id: \.self) { peer in
                        HStack {
                            Button(peer) {
                                configStore.config.peerHostName = peer
                            }
                            .buttonStyle(.link)
                            .font(.caption)
                            Spacer()
                            Button(isPairing ? "Pairing…" : "Pair") {
                                Task { await pair(with: peer) }
                            }
                            .font(.caption)
                            .disabled(isPairing)
                        }
                    }
                    Text("“Pair” sends a one-tap approval request to that Mac and copies its token here automatically — no manual passphrase typing.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Pairing") {
                SecureField("Shared token (same on both Macs)", text: $configStore.config.pairingToken)
                Text("Set automatically by clicking “Pair” above. Or type the same passphrase on both Macs manually.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button(isPinging ? "Pinging…" : "Test connection") {
                        Task { await runPing() }
                    }
                    .disabled(isPinging || configStore.config.pairingToken.isEmpty)
                    if let pingResult {
                        Text(pingResult)
                            .font(.caption)
                            .foregroundStyle(pingResult.hasPrefix("OK") || pingResult.hasPrefix("Paired") ? .green : .orange)
                    }
                }
            }

            Section("Setup checklist") {
                Label("Install KeySwitch on both Macs on the same Wi‑Fi", systemImage: "1.circle")
                Label("On the Mac with the physical keyboard, turn on “This Mac has the physical keyboard”", systemImage: "2.circle")
                Label("Grant Accessibility access when macOS prompts", systemImage: "3.circle")
                Label("Set the same pairing token and other-Mac name on both", systemImage: "4.circle")
                Label("Press \(InputBridge.hotkeyDisplay) to switch the keyboard between Macs", systemImage: "5.circle")
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 660)
        .onAppear {
            bridge.refreshAccessibilityStatus()
            restartNetwork()
            Task { await refreshPeerSetup() }
        }
        .onChange(of: configStore.config.thisMacName) { _ in restartNetwork() }
        .onChange(of: configStore.config.listenPort) { _ in restartNetwork() }
        .onChange(of: configStore.config.peerHostName) { _ in Task { await refreshPeerSetup() } }
        .onChange(of: configStore.config.peerAddress) { _ in Task { await refreshPeerSetup() } }
        .onChange(of: configStore.config.pairingToken) { _ in Task { await refreshPeerSetup() } }
    }

    private var canQueryPeer: Bool {
        !configStore.config.pairingToken.isEmpty &&
        (!configStore.config.peerHostName.isEmpty || !configStore.config.peerAddress.isEmpty)
    }

    @ViewBuilder
    private var localSetupStatus: some View {
        setupRow("This Mac has the physical keyboard", ok: configStore.config.isKeyboardOwner)
        setupRow("Pairing token set", ok: !configStore.config.pairingToken.isEmpty)
        setupRow("Other Mac configured", ok: !configStore.config.peerHostName.isEmpty || !configStore.config.peerAddress.isEmpty)
        setupRow("Network listening", ok: network.isListening)
        Text("Port \(configStore.config.listenPort)")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var peerSetupStatus: some View {
        if !canQueryPeer {
            Text("Set a pairing token and the other Mac's name to see its setup status.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if let error = network.peerSetupError {
            Text(error)
                .font(.caption)
                .foregroundStyle(.orange)
        } else if let peer = network.peerSetupStatus {
            setupRow("Reachable", ok: true)
            setupRow("Has the physical keyboard", ok: peer.isKeyboardOwner)
            setupRow("Pairing token set", ok: peer.tokenSet)
            setupRow("This Mac configured on peer", ok: peer.peerConfigured)
            setupRow("Network listening", ok: peer.networkListening)
            Text("Port \(peer.listenPort)")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if network.isFetchingPeerSetup {
            Text("Loading peer status…")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Text("Peer status unavailable. Click Refresh peer status.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func setupRow(_ title: String, ok: Bool) -> some View {
        Label(title, systemImage: ok ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(ok ? .green : .secondary)
    }

    private func refreshPeerSetup() async {
        await network.fetchPeerSetupStatus(config: configStore.config)
    }

    private func restartNetwork() {
        network.stop()
        network.start(config: configStore.config)
    }

    private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func pair(with peer: String) async {
        isPairing = true
        defer { isPairing = false }
        switch await network.requestPairing(peerName: peer) {
        case .success(let pairing):
            configStore.config.peerHostName = peer
            configStore.config.pairingToken = pairing.token
            pingResult = "Paired with \(pairing.hostName)."
            await refreshPeerSetup()
        case .failure(let error):
            pingResult = error.localizedDescription
        }
    }

    private func runPing() async {
        isPinging = true
        defer { isPinging = false }
        let result = await PeerNetwork.shared.ping(config: configStore.config)
        pingResult = result.detail
        await refreshPeerSetup()
    }
}
