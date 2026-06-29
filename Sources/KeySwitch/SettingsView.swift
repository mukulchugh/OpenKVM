import SwiftUI

struct SettingsView: View {
    @ObservedObject private var configStore = ConfigStore.shared
    @ObservedObject private var bluetooth = BluetoothManager.shared
    @ObservedObject private var network = PeerNetwork.shared
    @State private var pingResult: String?
    @State private var isPinging = false

    var body: some View {
        Form {
            Section("This Mac") {
                TextField("Name", text: $configStore.config.thisMacName)
                Stepper(value: Binding(
                    get: { Int(configStore.config.listenPort) },
                    set: { configStore.config.listenPort = UInt16($0) }
                ), in: 1024...65535) {
                    Text("Listen port: \(configStore.config.listenPort)")
                }
            }

            Section("Keyboard") {
                if let message = bluetooth.authorizationMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Picker("Device", selection: keyboardSelection) {
                    Text("Select a keyboard…").tag("")
                    ForEach(bluetooth.devices.filter(\.isKeyboard)) { device in
                        HStack {
                            Text(device.name)
                            if device.isConnected {
                                Text("● connected").foregroundStyle(.green)
                            }
                        }
                        .tag(device.address)
                    }
                }
                if !configStore.config.keyboardAddress.isEmpty {
                    Text(BluetoothAddress.display(configStore.config.keyboardAddress))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("Refresh devices") { bluetooth.refresh() }
                    Button("Test connect here") {
                        Task { await testLocalConnect() }
                    }
                    .disabled(configStore.config.keyboardAddress.isEmpty)
                }
            }

            Section("Other Mac") {
                TextField("Peer name (Bonjour)", text: $configStore.config.peerHostName)
                TextField("Peer IP (optional fallback)", text: $configStore.config.peerAddress)
                if !network.discoveredPeers.isEmpty {
                    Text("Discovered on network (click to use):")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(network.discoveredPeers, id: \.self) { peer in
                        Button(peer) {
                            configStore.config.peerHostName = peer
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                    }
                }
            }

            Section("Pairing") {
                SecureField("Shared token (same on both Macs)", text: $configStore.config.pairingToken)
                Text("Pick any passphrase and enter the same value on both Macs.")
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
                            .foregroundStyle(pingResult.contains("OK") ? .green : .orange)
                    }
                }
            }

            Section("Magic Keyboard checklist") {
                Label("Pair the keyboard to both Macs once in System Settings → Bluetooth", systemImage: "1.circle")
                Label("Install KeySwitch on both Macs on the same Wi‑Fi", systemImage: "2.circle")
                Label("Select your Magic Keyboard and set the same token on both", systemImage: "3.circle")
                Label("Grant Bluetooth + Local Network when macOS prompts", systemImage: "4.circle")
                Label("If switching fails, toggle the keyboard power switch off/on", systemImage: "5.circle")
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 520)
        .onAppear {
            bluetooth.refresh()
        }
    }

    private var keyboardSelection: Binding<String> {
        Binding(
            get: { configStore.config.keyboardAddress },
            set: { newValue in
                configStore.config.keyboardAddress = newValue
                if let device = bluetooth.devices.first(where: { $0.address == newValue }) {
                    configStore.config.keyboardName = device.name
                }
            }
        )
    }

    private func runPing() async {
        isPinging = true
        defer { isPinging = false }
        let ok = await PeerNetwork.shared.ping(config: configStore.config)
        pingResult = ok ? "OK — peer reachable" : "Failed — check peer IP/name and token"
    }

    private func testLocalConnect() async {
        do {
            try await BluetoothManager.shared.connectLocally(address: configStore.config.keyboardAddress)
            pingResult = "Connected on this Mac"
            bluetooth.refresh()
        } catch {
            pingResult = error.localizedDescription
        }
    }
}