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
    @State private var startAtLogin = LoginItem.isEnabled

    private var isPaired: Bool { configStore.isConfigured }

    var body: some View {
        Form {
            Section("Keyboard & mouse") {
                Toggle("This Mac has the keyboard & mouse", isOn: Binding(
                    get: { configStore.config.isKeyboardOwner },
                    set: { newValue in
                        configStore.config.isKeyboardOwner = newValue
                        bridge.updateOwnerState()
                    }
                ))

                if configStore.config.isKeyboardOwner && !bridge.canCapture {
                    Label("OpenKVM needs Accessibility AND Input Monitoring to capture the keyboard & mouse.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    HStack {
                        Button("Request access") { bridge.requestPermissions() }
                        Button("Accessibility…") { openPrivacyPane("Privacy_Accessibility") }
                        Button("Input Monitoring…") { openPrivacyPane("Privacy_ListenEvent") }
                    }
                }
                if !configStore.config.isKeyboardOwner && !bridge.canPost {
                    Label("OpenKVM needs permission to control this Mac (type and move the pointer).", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    HStack {
                        Button("Request access") { bridge.requestPermissions() }
                        Button("Accessibility…") { openPrivacyPane("Privacy_Accessibility") }
                    }
                }

                if configStore.config.isKeyboardOwner {
                    Picker("Keyboard", selection: keyboardSelectionBinding) {
                        Text(bridge.resolvedKeyboard.map { "Auto: \($0.name)" } ?? "Auto-detect (none found)").tag("")
                        ForEach(bridge.availableKeyboards.filter { !$0.isBuiltIn }) { kb in
                            Text(kb.name).tag(kb.id)
                        }
                    }
                    Picker("Mouse", selection: mouseSelectionBinding) {
                        Text(bridge.resolvedMouse.map { "Auto: \($0.name)" } ?? "Auto-detect (none found)").tag("")
                        ForEach(bridge.availableMice.filter { !$0.isBuiltIn }) { m in
                            Text(m.name).tag(m.id)
                        }
                    }
                    Text("Only this external keyboard/mouse are captured while forwarding — the built-in trackpad and keyboard on both Macs always keep working.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if configStore.config.isKeyboardOwner && bridge.canCapture && isPaired {
                    HStack {
                        Button(bridge.isForwarding ? "Take control back" : "Control \(peerDisplayName)") {
                            Task { await bridge.toggleForwarding() }
                        }
                        Text("or press \(InputBridge.hotkeyDisplay) anytime")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if bridge.isReceivingFromPeer {
                    Label("Receiving keyboard & mouse from \(peerDisplayName)", systemImage: "keyboard.badge.ellipsis")
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
                    if let peer = network.peerSetupStatus {
                        if peer.isKeyboardOwner && configStore.config.isKeyboardOwner {
                            Label("Both Macs claim input — turn OFF the toggle on \(peer.hostName).", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                        if configStore.config.isKeyboardOwner && peer.canPost == false {
                            Label("\(peer.hostName) can't type yet — grant permission in OpenKVM there.", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                        if configStore.config.isKeyboardOwner && peer.canPost == nil {
                            Label("\(peer.hostName) runs an old build — update OpenKVM there.", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                    }
                    Button("Check other Mac") {
                        Task { await network.fetchPeerSetupStatus(config: configStore.config) }
                    }
                    .disabled(network.isFetchingPeerSetup)
                } else if network.discoveredPeers.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Looking for your other Mac… Open OpenKVM on it (same Wi‑Fi).")
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

                if isPaired {
                    Toggle("Share clipboard between Macs", isOn: Binding(
                        get: { configStore.config.shareClipboard },
                        set: { newValue in
                            configStore.config.shareClipboard = newValue
                            ClipboardSync.shared.setEnabled(newValue)
                        }
                    ))
                    Text("Copying text on either Mac makes it available to paste on the other. Works independently of ⌘⇧K.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Toggle("Start OpenKVM at login", isOn: Binding(
                    get: { startAtLogin },
                    set: { newValue in
                        startAtLogin = LoginItem.setEnabled(newValue) ? newValue : LoginItem.isEnabled
                    }
                ))

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
        .frame(width: 420, height: 510)
        .onAppear {
            startAtLogin = LoginItem.isEnabled
            bridge.refreshPermissions()
            bridge.refreshDeviceList()
            restartNetwork()
            if isPaired {
                Task { await network.fetchPeerSetupStatus(config: configStore.config) }
            }
        }
        .onChange(of: configStore.config.thisMacName) { _ in restartNetwork() }
        .onChange(of: configStore.config.listenPort) { _ in restartNetwork() }
    }

    private var keyboardSelectionBinding: Binding<String> {
        Binding(
            get: {
                let cfg = configStore.config
                return (cfg.externalKeyboardVendorID != 0 || cfg.externalKeyboardProductID != 0)
                    ? "\(cfg.externalKeyboardVendorID):\(cfg.externalKeyboardProductID)" : ""
            },
            set: { newValue in
                if newValue.isEmpty {
                    bridge.selectKeyboard(nil)
                } else if let info = bridge.availableKeyboards.first(where: { $0.id == newValue }) {
                    bridge.selectKeyboard(info)
                }
            }
        )
    }

    private var mouseSelectionBinding: Binding<String> {
        Binding(
            get: {
                let cfg = configStore.config
                return (cfg.externalMouseVendorID != 0 || cfg.externalMouseProductID != 0)
                    ? "\(cfg.externalMouseVendorID):\(cfg.externalMouseProductID)" : ""
            },
            set: { newValue in
                if newValue.isEmpty {
                    bridge.selectMouse(nil)
                } else if let info = bridge.availableMice.first(where: { $0.id == newValue }) {
                    bridge.selectMouse(info)
                }
            }
        )
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

    private func openPrivacyPane(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}
