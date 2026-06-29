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

        bluetooth.refresh()
        network.start(config: configStore.config)
        buildMenu()

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
        guard let button = statusItem.button else { return }
        if #available(macOS 11.0, *) {
            let symbol = coordinator.isSwitching ? "arrow.left.arrow.right.circle" : "keyboard"
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "KeySwitch")
        } else {
            button.title = "⌨"
        }
    }

    private func buildMenu() {
        let menu = NSMenu()

        let title = configStore.config.keyboardName.isEmpty ? "KeySwitch" : configStore.config.keyboardName
        menu.addItem(disabled(title))

        if coordinator.isSwitching {
            menu.addItem(disabled("Switching…"))
        } else if let status = coordinator.lastMessage ?? network.lastStatusMessage {
            menu.addItem(disabled(status))
        }

        menu.addItem(.separator())

        let thisName = configStore.config.thisMacName
        let connectHere = NSMenuItem(
            title: "Connect to this Mac (\(thisName))",
            action: #selector(switchToHere),
            keyEquivalent: "2"
        )
        connectHere.target = self
        connectHere.isEnabled = coordinator.canConnectHere && !coordinator.isSwitching
        menu.addItem(connectHere)

        let peerName = configStore.config.peerHostName.isEmpty ? "Other Mac" : configStore.config.peerHostName
        let toPeer = NSMenuItem(
            title: "Switch to \(peerName)",
            action: #selector(switchToPeer),
            keyEquivalent: "1"
        )
        toPeer.target = self
        toPeer.isEnabled = coordinator.canSwitchToPeer && !coordinator.isSwitching
        menu.addItem(toPeer)

        if !coordinator.canConnectHere {
            menu.addItem(disabled("→ Open Settings to pick your keyboard"))
        } else if !coordinator.canSwitchToPeer {
            menu.addItem(disabled("→ Set peer + token to switch away"))
        }

        menu.addItem(.separator())

        let connected = coordinator.canConnectHere &&
            bluetooth.keyboardConnected(address: configStore.config.keyboardAddress)
        menu.addItem(disabled(connected ? "● Connected here" : "○ Not connected here"))

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

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func switchToPeer() {
        Task {
            await coordinator.switchToOtherMac()
            buildMenu()
        }
    }

    @objc private func switchToHere() {
        if !coordinator.canConnectHere {
            openSettings()
            return
        }
        Task {
            await coordinator.switchToThisMac()
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