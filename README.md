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

## Install

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