import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private let configStore = ConfigStore.shared
    private let network = PeerNetwork.shared
    private let bridge = InputBridge.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusIcon()

        bridge.requestPermissionsIfNeeded()
        bridge.updateOwnerState()
        network.start(config: configStore.config)
        ClipboardSync.shared.setEnabled(configStore.config.shareClipboard)
        buildMenu()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.bridge.refreshPermissions()
                self?.buildMenu()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        bridge.setLocalCursorFrozen(false) // never leave the mouse decoupled
        network.stop()
        Task { @MainActor in network.stopKeyForwarding() }
    }

    private func updateStatusIcon() {
        guard let button = statusItem.button else { return }
        let symbol = bridge.isForwarding ? "arrow.left.arrow.right.circle.fill" : "keyboard"
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "OpenKVM")
    }

    private func buildMenu() {
        let menu = NSMenu()

        let statusText: String
        if bridge.isReceivingFromPeer {
            statusText = "Receiving keyboard & mouse from peer"
        } else if bridge.isForwarding {
            let peer = configStore.config.peerHostName.isEmpty ? "other Mac" : configStore.config.peerHostName
            statusText = "Controlling \(peer)"
        } else if configStore.config.isKeyboardOwner {
            statusText = "Keyboard & mouse are local"
        } else {
            statusText = "Receive-only Mac"
        }
        menu.addItem(disabled(statusText))

        if let message = bridge.lastMessage ?? network.lastStatusMessage {
            menu.addItem(disabled(message))
        }

        menu.addItem(.separator())

        let hasNeededPermission = configStore.config.isKeyboardOwner ? bridge.canCapture : bridge.canPost
        if !hasNeededPermission {
            menu.addItem(disabled("→ Grant permissions in Settings"))
        } else if configStore.config.isKeyboardOwner {
            let toggle = NSMenuItem(
                title: bridge.isForwarding ? "Take control back to this Mac" : "Control other Mac (keyboard & mouse)",
                action: #selector(toggleForwarding),
                keyEquivalent: "k"
            )
            toggle.keyEquivalentModifierMask = [.command, .shift]
            toggle.target = self
            toggle.isEnabled = ConfigStore.shared.isConfigured
            menu.addItem(toggle)
            if !ConfigStore.shared.isConfigured {
                menu.addItem(disabled("→ Pair with your other Mac in Settings"))
            }
        } else {
            menu.addItem(disabled("→ Enable “This Mac has the keyboard & mouse” on the owner Mac"))
        }

        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let refresh = NSMenuItem(title: "Refresh", action: #selector(refreshState), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit OpenKVM", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
        updateStatusIcon()
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func toggleForwarding() {
        Task {
            await bridge.toggleForwarding()
            buildMenu()
        }
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let view = SettingsView()
            let controller = NSHostingController(rootView: view)
            let window = NSWindow(contentViewController: controller)
            window.title = "OpenKVM Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.setContentSize(NSSize(width: 500, height: 640))
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func refreshState() {
        bridge.forceReinstallTap()
        network.stop()
        network.start(config: configStore.config)
        buildMenu()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
