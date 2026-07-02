import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject private var configStore = ConfigStore.shared
    @ObservedObject private var network = PeerNetwork.shared
    @ObservedObject private var bridge = InputBridge.shared
    @State private var statusMessage: String?
    @State private var isPairing = false
    @State private var isPinging = false
    @State private var showAdvanced = false

    private var isPaired: Bool { configStore.isConfigured }

    var body: some View {
        Form {
            Section("Keyboard") {
                Toggle("This Mac has the physical keyboard", isOn: Binding(
                    get: { configStore.config.isKeyboardOwner },
                    set: { newValue in
                        configStore.config.isKeyboardOwner = newValue
                        bridge.updateOwnerState()
                    }
                ))

                if configStore.config.isKeyboardOwner && !bridge.hasAccessibility {
                    Label("KeySwitch needs Accessibility access to capture keystrokes.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Button("Grant access…") { openAccessibilitySettings() }
                }

                if configStore.config.isKeyboardOwner && bridge.hasAccessibility && isPaired {
                    HStack {
                        Button(bridge.isForwarding ? "Bring keyboard back here" : "Send keyboard to \(peerDisplayName)") {
                            Task { await bridge.toggleForwarding() }
                        }
                        Text("or press \(InputBridge.hotkeyDisplay) anytime")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if bridge.isReceivingFromPeer {
                    Label("Receiving keyboard from \(peerDisplayName)", systemImage: "keyboard.badge.ellipsis")
                        .foregroundStyle(.green)
                }
            }

            Section("Other Mac") {
                if isPaired {
                    HStack {
                        Label(peerDisplayName, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Spacer()
                        Button("Unpair") {
                            configStore.config.pairingToken = ""
                            configStore.config.peerHostName = ""
                            configStore.config.peerAddress = ""
                            statusMessage = nil
                        }
                    }
                } else if network.discoveredPeers.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Looking for your other Mac… Open KeySwitch on it (same Wi‑Fi).")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(network.discoveredPeers, id: \.self) { peer in
                        HStack {
                            Text(peer)
                            Spacer()
                            Button(isPairing ? "Pairing…" : "Pair") {
                                Task { await pair(with: peer) }
                            }
                            .disabled(isPairing)
                        }
                    }
                    Text("Click Pair, then click Approve on the other Mac. That's it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let statusMessage {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(statusMessage.hasPrefix("Paired") || statusMessage.hasPrefix("OK") ? .green : .orange)
                }
            }

            Section {
                DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                    TextField("This Mac's name", text: $configStore.config.thisMacName)
                    TextField("Other Mac's IP (if discovery fails)", text: $configStore.config.peerAddress)
                    SecureField("Shared token (set automatically by Pair)", text: $configStore.config.pairingToken)
                    Stepper(value: Binding(
                        get: { Int(configStore.config.listenPort) },
                        set: { configStore.config.listenPort = UInt16($0) }
                    ), in: 1024...65535) {
                        Text("Port: \(String(configStore.config.listenPort))")
                    }
                    Button(isPinging ? "Testing…" : "Test connection") {
                        Task { await runPing() }
                    }
                    .disabled(isPinging || configStore.config.pairingToken.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 380)
        .onAppear {
            bridge.refreshAccessibilityStatus()
            restartNetwork()
        }
        .onChange(of: configStore.config.thisMacName) { _ in restartNetwork() }
        .onChange(of: configStore.config.listenPort) { _ in restartNetwork() }
    }

    private var peerDisplayName: String {
        configStore.config.peerHostName.isEmpty
            ? (configStore.config.peerAddress.isEmpty ? "other Mac" : configStore.config.peerAddress)
            : configStore.config.peerHostName
    }

    private func pair(with peer: String) async {
        isPairing = true
        defer { isPairing = false }
        switch await network.requestPairing(peerName: peer) {
        case .success(let pairing):
            configStore.config.peerHostName = peer
            configStore.config.pairingToken = pairing.token
            statusMessage = "Paired with \(pairing.hostName)."
        case .failure(let error):
            statusMessage = error.localizedDescription
        }
    }

    private func runPing() async {
        isPinging = true
        defer { isPinging = false }
        let result = await PeerNetwork.shared.ping(config: configStore.config)
        statusMessage = result.detail
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
}
