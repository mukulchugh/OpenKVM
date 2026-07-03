import AppKit

/// Syncs the text clipboard between the two Macs. macOS has no "clipboard
/// changed" notification, so — same architecture Deskflow/Synergy use (they
/// poll PasteboardSynchronize's kPasteboardModified flag) — this polls
/// NSPasteboard.general.changeCount on a timer. Runs independently of
/// keyboard/mouse forwarding: clipboard sharing isn't tied to which Mac is
/// "in control," same as Handoff/Universal Control's clipboard behavior.
@MainActor
final class ClipboardSync {
    static let shared = ClipboardSync()

    private var timer: Timer?
    private var lastChangeCount: Int
    private var suppressNextChange = false

    private init() {
        lastChangeCount = NSPasteboard.general.changeCount
    }

    func setEnabled(_ enabled: Bool) {
        timer?.invalidate()
        timer = nil
        guard enabled else { return }
        lastChangeCount = NSPasteboard.general.changeCount
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollForLocalChange() }
        }
    }

    private func pollForLocalChange() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount

        // A change we just applied FROM the peer bumps changeCount too —
        // skip echoing it straight back (would ping-pong forever).
        if suppressNextChange {
            suppressNextChange = false
            return
        }
        guard let text = pb.string(forType: .string), !text.isEmpty else { return }
        Task { await PeerNetwork.shared.sendClipboard(text: text, config: ConfigStore.shared.config) }
    }

    /// Called when the peer sends us their clipboard.
    func applyRemote(text: String) {
        let pb = NSPasteboard.general
        suppressNextChange = true
        pb.clearContents()
        pb.setString(text, forType: .string)
        lastChangeCount = pb.changeCount
    }
}
