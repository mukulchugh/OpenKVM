# KeySwitch

macOS menu bar app to switch a Bluetooth keyboard between two Macs with one click.

## Requirements

- macOS 13+
- Xcode Command Line Tools (`swift`, `xcodebuild`)
- Keyboard paired to **both** Macs in System Settings → Bluetooth

## Build

```bash
./build-app.sh
```

Output: `dist/KeySwitch.app`

### DMG installer

```bash
chmod +x build-dmg.sh
./build-dmg.sh
```

Output:
- `dist/KeySwitch.zip` — **use this on your other Mac** (avoids false "damaged" errors)
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

First launch: right-click → Open (unsigned build). Grant **Bluetooth** and **Local Network** permissions.

## Setup (both Macs)

1. Install KeySwitch on both machines.
2. Open **Settings** from the menu bar icon.
3. Select your keyboard.
4. Set the same **pairing token** on both Macs.
5. Set the other Mac's Bonjour name (click a discovered peer) or IP address.
6. Use **Test connection** to verify.

## Usage

- **Switch keyboard to [Other Mac]** — disconnect here, connect on peer
- **Switch keyboard to [This Mac]** — pull keyboard back

## Architecture

- **IOBluetooth** — connect/disconnect peripherals
- **Network.framework** — TCP commands between Macs
- **Bonjour** — `_keyswitch._tcp` peer discovery