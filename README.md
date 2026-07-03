# KeySwitch

macOS menu bar app that forwards a physical keyboard and mouse from one Mac to another over the local network.

The Mac with the hardware attached captures keystrokes and pointer events, sends them to your other Mac over TCP, and replays them there. Toggle control with **⌘⇧K** or the menu bar — the hotkey always works locally so you are never locked out.

## Requirements

- macOS 13+
- Xcode Command Line Tools (`swift`, `xcodebuild`)
- Both Macs on the same local network (or reachable by IP)
- KeySwitch installed and running on **both** Macs

## Quick start

1. Build or install KeySwitch on both Macs (see [Install](#install)).
2. On the Mac **with the keyboard**, open **Settings** and enable **This Mac has the physical keyboard**.
3. On either Mac, open **Settings → Other Mac** and click **Pair** next to the discovered peer. Approve the dialog on the other Mac.
4. Grant **Accessibility**, **Input Monitoring**, and **Local Network** when prompted.
5. Press **⌘⇧K** (or use the menu) to forward the keyboard to the other Mac. Press again to bring it back.

## Build

```bash
./build-app.sh
```

Output: `dist/KeySwitch.app` (universal arm64 + x86_64)

For a stable code signature so Accessibility permission survives rebuilds:

```bash
./scripts/make-signing-cert.sh   # once per Mac
./build-app.sh
```

### DMG installer

```bash
chmod +x build-dmg.sh
./build-dmg.sh
```

Output:

- `dist/KeySwitch.zip` — **preferred for your other Mac** (avoids false "damaged" errors)
- `dist/KeySwitch.dmg` — drag-to-Applications installer

## Install

### Other Mac says DMG is "damaged"?

macOS shows that for unsigned apps — the file is not actually corrupted. Use the ZIP instead:

```bash
# On the other Mac, after copying KeySwitch.zip over:
unzip KeySwitch.zip
chmod +x install-on-mac.sh
./install-on-mac.sh
```

Then right-click **KeySwitch → Open** in Applications (first launch only).

If you still want the DMG:

```bash
xattr -cr ~/Downloads/KeySwitch.dmg
open ~/Downloads/KeySwitch.dmg
```

### From DMG (this Mac)

Open `dist/KeySwitch.dmg`, drag KeySwitch to Applications.

### From app bundle

```bash
cp -R dist/KeySwitch.app /Applications/
```

First launch: right-click → Open (unsigned build). Grant **Accessibility**, **Input Monitoring**, **Post Event** (on the receiver), and **Local Network** permissions.

## Setup (both Macs)

| Mac | Settings |
|-----|----------|
| **Owner** (has keyboard) | Enable "This Mac has the physical keyboard" |
| **Receiver** (other Mac) | Leave that toggle **off** |

Pairing (automatic):

1. Open **Settings** on either Mac.
2. Wait for the other Mac to appear under **Other Mac**.
3. Click **Pair**, then click **Approve** on the other Mac.

Manual (if Bonjour discovery fails): open **Advanced**, set the other Mac's IP and ensure both Macs share the same pairing token.

Use **Test connection** (Advanced) to verify reachability.

## Usage

| Action | How |
|--------|-----|
| Forward keyboard & mouse to other Mac | Menu bar → "Switch keyboard to other Mac", or **⌘⇧K** |
| Bring keyboard back to this Mac | Menu bar → "Switch keyboard back to this Mac", or **⌘⇧K** |
| Open settings | Menu bar → Settings…, or **⌘,** |
| Recover stale permissions / network | Menu bar → Refresh, or **⌘R** |

## Architecture

| Component | Role |
|-----------|------|
| **InputBridge** | CGEvent tap (capture) and CGEvent injection (replay) |
| **PeerNetwork** | TCP listener, Bonjour discovery (`_keyswitch._tcp`), wire protocol |
| **ConfigStore** | Persists pairing token, peer, owner flag in UserDefaults |
| **SettingsView** | SwiftUI settings: pairing, permissions, diagnostics |

Default TCP port: **9847**. Messages are length-prefixed JSON.

For the full technical reference — data flows, wire protocol, TCC permissions, build pipeline, and debugging — see **[ARCHITECTURE.md](ARCHITECTURE.md)**.

## Development

```bash
# Run from source (debug)
swift run

# Test peer connectivity (app must be running)
python3 scripts/test-peer-ping.py 127.0.0.1 9847 <your-token>
python3 scripts/test-peer-setup.py 127.0.0.1 9847 <your-token>
```

## Project structure

```
Sources/KeySwitch/     Application source (7 Swift files)
Resources/             Info.plist, app icon
scripts/               Installer, signing cert, test clients
build-app.sh           Universal .app packaging
build-dmg.sh           DMG + ZIP distribution
```