import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private let configStore = ConfigStore.shared
    private let bluetooth = BluetoothManager.shared
    private let network = PeerNetwork.shared
    private let coordinator = SwitchCoordinator.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusIcon()

        buildMenu()
        bluetooth.refresh()
        network.start(config: configStore.config)

        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.bluetooth.refresh()
                self?.buildMenu()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        network.stop()
    }

    private func updateStatusIcon() {
        if let button = statusItem.button {
            if #available(macOS 11.0, *) {
                let symbol = coordinator.isSwitching ? "arrow.left.arrow.right.circle" : "keyboard"
                button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "KeySwitch")
            } else {
                button.title = "⌨"
            }
        }
    }

    private func buildMenu() {
        let menu = NSMenu()

        let title = configStore.config.keyboardName.isEmpty ? "KeySwitch" : configStore.config.keyboardName
        let header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        if let status = coordinator.lastMessage ?? network.lastStatusMessage {
            let statusItem = NSMenuItem(title: status, action: nil, keyEquivalent: "")
            statusItem.isEnabled = false
            menu.addItem(statusItem)
        }

        menu.addItem(.separator())

        let peerName = configStore.config.peerHostName.isEmpty ? "Other Mac" : configStore.config.peerHostName
        let thisName = configStore.config.thisMacName

        let toPeer = NSMenuItem(
            title: "Switch keyboard to \(peerName)",
            action: #selector(switchToPeer),
            keyEquivalent: "1"
        )
        toPeer.target = self
        menu.addItem(toPeer)

        let toHere = NSMenuItem(
            title: "Switch keyboard to \(thisName)",
            action: #selector(switchToHere),
            keyEquivalent: "2"
        )
        toHere.target = self
        menu.addItem(toHere)

        menu.addItem(.separator())

        let connected = !configStore.config.keyboardAddress.isEmpty &&
            bluetooth.keyboardConnected(address: configStore.config.keyboardAddress)
        let connItem = NSMenuItem(
            title: connected ? "● Connected here" : "○ Not connected here",
            action: nil,
            keyEquivalent: ""
        )
        connItem.isEnabled = false
        menu.addItem(connItem)

        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let refresh = NSMenuItem(title: "Refresh", action: #selector(refreshState), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit KeySwitch", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
        updateStatusIcon()
    }

    @objc private func switchToPeer() {
        Task {
            await coordinator.switchToOtherMac()
            buildMenu()
        }
    }

    @objc private func switchToHere() {
        Task {
            await coordinator.switchToPeer()
            buildMenu()
        }
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let view = SettingsView()
            let controller = NSHostingController(rootView: view)
            let window = NSWindow(contentViewController: controller)
            window.title = "KeySwitch Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.setContentSize(NSSize(width: 480, height: 540))
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func refreshState() {
        bluetooth.refresh()
        network.stop()
        network.start(config: configStore.config)
        buildMenu()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}