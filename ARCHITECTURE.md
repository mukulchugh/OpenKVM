# KeySwitch — Architecture & Developer Guide

KeySwitch is a macOS menu bar application that lets you use one physical keyboard and mouse across two Macs on the same local network. The Mac with the hardware attached captures input and forwards it over TCP; the other Mac replays those events as if they came from a local device.

This document describes the codebase end to end: project layout, runtime architecture, wire protocol, permissions, build pipeline, and development workflow.

---

## Table of contents

1. [Overview](#overview)
2. [Repository layout](#repository-layout)
3. [Runtime architecture](#runtime-architecture)
4. [Component reference](#component-reference)
5. [Data flows](#data-flows)
6. [Wire protocol](#wire-protocol)
7. [Configuration & persistence](#configuration--persistence)
8. [macOS permissions (TCC)](#macos-permissions-tcc)
9. [Build & distribution](#build--distribution)
10. [Testing & debugging](#testing--debugging)
11. [Design decisions](#design-decisions)

---

## Overview

### What it does

| Role | Mac | Responsibility |
|------|-----|----------------|
| **Owner** | Has the physical keyboard/mouse | Captures HID events via a CGEvent tap, forwards them to the peer over TCP |
| **Receiver** | Other Mac | Injects received key/mouse events via `CGEvent.post` |

Users toggle forwarding with **⌘⇧K** or the menu bar. The hotkey is always handled locally on the owner Mac so you are never locked out.

### What it does not do

- **No Bluetooth management.** The README once described IOBluetooth connect/disconnect; that is not implemented. The keyboard stays paired to the owner Mac; control is forwarded over the network.
- **No encryption.** Traffic is plain TCP on the local network, authenticated by a shared pairing token.
- **No cloud relay.** Peers must be on the same LAN (Bonjour) or reachable by IP.

### Tech stack

| Layer | Technology |
|-------|------------|
| Language | Swift 5.9 |
| UI | AppKit menu bar + SwiftUI settings window |
| Networking | Apple Network.framework (TCP, Bonjour) |
| Input capture | Core Graphics event tap (`CGEvent.tapCreate`) |
| Input injection | Core Graphics event posting (`CGEvent.post`) |
| Persistence | `UserDefaults` (JSON-encoded `AppConfig`) |
| Package manager | Swift Package Manager (single executable target) |
| Minimum OS | macOS 13 (Ventura) |

---

## Repository layout

```
KeySwitch/
├── Package.swift              # SPM manifest — one executable target
├── Sources/KeySwitch/           # All application source
│   ├── KeySwitchApp.swift     # @main entry — NSApplication bootstrap
│   ├── AppDelegate.swift      # Menu bar, lifecycle, settings window
│   ├── SettingsView.swift     # SwiftUI settings UI
│   ├── ConfigStore.swift      # UserDefaults persistence
│   ├── Models.swift           # AppConfig, PeerMessage, errors
│   ├── PeerNetwork.swift      # TCP listener, Bonjour, protocol handler
│   └── InputBridge.swift      # Event tap, capture, injection
├── Resources/
│   ├── Info.plist             # Bundle metadata, Bonjour, LSUIElement
│   └── AppIcon.icns           # Menu bar / app icon
├── icon-source/               # PNG sources for the icon set
├── scripts/
│   ├── build-app.sh           # (via root) universal binary packaging
│   ├── install-on-mac.sh      # Receiver Mac installer from ZIP
│   ├── make-signing-cert.sh   # Stable local codesign identity for TCC
│   ├── test-peer-ping.py      # Manual ping against running app
│   ├── test-peer-ping.swift   # Same, in Swift
│   └── test-peer-setup.py     # Query peer setup snapshot
├── build-app.sh               # arm64 + x86_64 universal .app
├── build-dmg.sh               # DMG + ZIP distribution
├── README.md                  # User-facing quick start
└── ARCHITECTURE.md            # This file
```

Build artifacts land in `.build/` (SPM) and `dist/` (`.app`, `.dmg`, `.zip`). Both are gitignored.

---

## Runtime architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         Menu bar (AppDelegate)                          │
│  Status icon · NSMenu · Settings window · lifecycle hooks              │
└───────────────────────────────┬─────────────────────────────────────────┘
                                │
        ┌───────────────────────┼───────────────────────┐
        ▼                       ▼                       ▼
┌───────────────┐     ┌─────────────────┐     ┌─────────────────┐
│  ConfigStore  │     │   PeerNetwork   │     │   InputBridge   │
│  (UserDefaults)│◄───│  NWListener     │────►│  CGEvent tap    │
│  AppConfig    │     │  NWBrowser      │     │  CGEvent inject │
└───────────────┘     │  TCP framing    │     └─────────────────┘
                      └────────┬────────┘
                               │
                      Bonjour _keyswitch._tcp
                      TCP :9847 (default)
                               │
                      ┌────────▼────────┐
                      │   Other Mac     │
                      │   (same stack)  │
                      └─────────────────┘
```

All three singletons (`ConfigStore.shared`, `PeerNetwork.shared`, `InputBridge.shared`) are `@MainActor` or publish on the main actor. The event-tap callback runs on the main run loop but is `nonisolated`; it uses `MainActor.assumeIsolated` and cached forwarding state to avoid actor hops on the hot path.

### Startup sequence

1. `KeySwitchApp.main()` creates `NSApplication` with `AppDelegate`.
2. `applicationDidFinishLaunching`:
   - Sets activation policy to `.accessory` (menu bar only, no Dock icon).
   - Creates status item and menu.
   - `InputBridge.requestPermissionsIfNeeded()` — prompts for TCC on first launch.
   - `InputBridge.updateOwnerState()` — installs event tap if this Mac is owner.
   - `PeerNetwork.start(config:)` — starts TCP listener + Bonjour browser.
3. On terminate: stops listener/browser and closes the forwarding stream.

---

## Component reference

### `KeySwitchApp.swift`

Minimal entry point. Uses `NSApplication` + `AppDelegate` instead of SwiftUI `@main` because the app is menu-bar-only (`LSUIElement`).

### `AppDelegate.swift`

| Responsibility | Detail |
|----------------|--------|
| Menu bar UI | Dynamic status text, forwarding toggle (⌘⇧K), Settings, Refresh, Quit |
| Status icon | `keyboard` when local; `arrow.left.arrow.right.circle.fill` when forwarding |
| Settings window | Lazy `NSWindow` hosting `SettingsView` via `NSHostingController` |
| Refresh | `forceReinstallTap()` + restart `PeerNetwork` — recovers stale TCC/tap state |
| Active notification | Re-checks permissions when app becomes active |

### `ConfigStore.swift`

- Persists `AppConfig` to `UserDefaults` key `com.keyswitch.config`.
- `@Published config` auto-saves on every change.
- `isConfigured`: non-empty pairing token AND (peer hostname OR peer IP).

### `Models.swift`

**`AppConfig`** — per-Mac settings:

| Field | Default | Purpose |
|-------|---------|---------|
| `peerHostName` | `""` | Bonjour service name of the other Mac |
| `peerAddress` | `""` | Fallback IP if discovery fails |
| `pairingToken` | `""` | Shared secret for all authenticated messages |
| `isKeyboardOwner` | `false` | Whether this Mac captures physical input |
| `thisMacName` | `Host.current().localizedName` | Advertised Bonjour name |
| `listenPort` | `9847` | TCP port for listener |

**`PeerMessage`** — JSON envelope for every wire message. See [Wire protocol](#wire-protocol).

**`PeerSetupSnapshot`** — diagnostic struct returned by `querySetup` (permissions, owner flag, listener state).

**`SwitchError`** — localized errors for unreachable peer, auth failure, accessibility denial.

### `PeerNetwork.swift`

Singleton managing all networking.

| Subsystem | Implementation |
|-----------|----------------|
| Listener | `NWListener` on `listenPort`, advertises `_keyswitch._tcp` |
| Browser | `NWBrowser` for peer discovery; excludes own `thisMacName` |
| Request/response | Short-lived connections for ping, setup query, pairing |
| Forwarding stream | Long-lived `outboundStream` for `keyEvent` / `mouseEvent` |
| Framing | 4-byte big-endian length prefix + JSON body |
| Latency | `NWProtocolTCP.Options.noDelay = true` (disables Nagle) |

**Authentication:** Every message after pairing checks `message.token == config.pairingToken`. Mismatch yields a `status` response and connection close.

**Pairing flow:** `pairRequest` → native `NSAlert` on peer → `pairResponse` with token (generated if empty). No manual token typing required.

### `InputBridge.swift`

| Mode | Behavior |
|------|----------|
| Owner + not forwarding | Tap installed but events pass through locally |
| Owner + forwarding | Tap swallows events; sends to `PeerNetwork` |
| Receiver | No tap; `inject` / `injectMouse` called by `PeerNetwork` |
| Hotkey ⌘⇧K (keyCode 40) | Always local; toggles forwarding |

**Captured event types:** keyDown, keyUp, flagsChanged, mouse move/drag, button down/up, scroll.

**Mouse forwarding:** Uses relative deltas (`mouseEventDeltaX/Y`), not absolute screen coordinates, because the two Macs may have different display layouts. The receiver maintains `injectedCursor` and clamps to the union of active display bounds.

**Permission checks:**

- `canCapture` = `CGPreflightListenEventAccess()` AND `AXIsProcessTrusted()`
- `canPost` = `CGPreflightPostEventAccess()`

---

## Data flows

### 1. Discovery & pairing

```
Mac A (initiator)                    Mac B (responder)
      │                                      │
      │  Bonjour browse finds B              │  NWListener advertising
      │                                      │
      │──── pairRequest (no token) ─────────►│
      │                                      │  NSAlert: "Pair with A?"
      │◄─── pairResponse (token, approved) ──│  (generates token if needed)
      │                                      │
      │  A stores B's name + shared token    │  B already has token
```

### 2. Begin forwarding (owner → receiver)

```
Owner Mac                              Receiver Mac
      │                                      │
      │──── TCP connect (stream) ─────────────►│
      │  (connection stays open)             │
      │                                      │
      │──── keyEvent / mouseEvent ───────────►│  InputBridge.inject(...)
      │──── keyEvent / mouseEvent ───────────►│
      │     ...                              │
      │──── (stopKeyForwarding / disconnect)  │
```

`beginKeyForwarding` opens the stream; individual events use `emit()` without waiting for responses. The receiver's handler calls `receiveNext` in a loop to keep reading.

### 3. Ping / setup query (diagnostics)

```
Client                                 Server
  │──── ping + token ────────────────────►│
  │◄─── pong + token ─────────────────────│  (connection closed)

  │──── querySetup + token ──────────────►│
  │◄─── setupStatus (PeerSetupSnapshot) ──│
```

Used by Settings → "Test connection" and "Check other Mac".

### 4. Toggle forwarding (⌘⇧K)

```
InputBridge.toggleForwarding()
  ├─ if forwarding: stopKeyForwarding(), isForwarding = false
  └─ else: require isConfigured → beginKeyForwarding() → isForwarding = true
```

---

## Wire protocol

### Transport

- **Protocol:** TCP
- **Default port:** 9847
- **Framing:** `[uint32 BE length][UTF-8 JSON]`
- **Serialization:** `JSONEncoder` / `JSONDecoder`, `Codable` types

### Message actions

| Action | Direction | Connection | Auth required |
|--------|-----------|------------|---------------|
| `pairRequest` | Initiator → peer | Short | No |
| `pairResponse` | Peer → initiator | Short | No |
| `ping` | Either | Short | Yes |
| `pong` | Response | Short | Yes |
| `status` | Response (token mismatch) | Short | No |
| `querySetup` | Either | Short | Yes |
| `setupStatus` | Response | Short | Yes |
| `keyEvent` | Owner → receiver | **Stream** | Yes |
| `mouseEvent` | Owner → receiver | **Stream** | Yes |

### `keyEvent` fields

```json
{
  "action": "keyEvent",
  "hostName": "MacBook Pro",
  "token": "abc123def456",
  "keyCode": 40,
  "keyDown": true,
  "flags": 1048576,
  "isFlagsChanged": false
}
```

`keyCode` is the macOS virtual key code (`CGKeyCode`). `flags` is `CGEventFlags.rawValue`.

### `mouseEvent` fields

```json
{
  "action": "mouseEvent",
  "mouseKind": "move",
  "dx": 3.0,
  "dy": -1.0,
  "scrollDX": 0,
  "scrollDY": 0,
  "button": 0
}
```

`mouseKind` values: `move`, `leftDown`, `leftUp`, `rightDown`, `rightUp`, `otherDown`, `otherUp`, `scroll`.

### Example: manual ping (Python)

```bash
python3 scripts/test-peer-ping.py 192.168.1.10 9847 your-token
```

---

## Configuration & persistence

Settings live in `~/Library/Preferences/com.keyswitch.app.plist` (via `UserDefaults`).

**Owner Mac setup:**

1. Enable "This Mac has the physical keyboard".
2. Pair with the other Mac (or set token + peer manually in Advanced).
3. Grant Accessibility + Input Monitoring + Post Event as prompted.

**Receiver Mac setup:**

1. Leave owner toggle **off**.
2. Pair with the owner (approve the dialog when prompted).
3. Grant Accessibility + Post Event so injected input works.

**Advanced overrides:**

- Manual IP when Bonjour fails (same subnet).
- Custom port (must match on both Macs).
- Manual token (normally set automatically by Pair).

---

## macOS permissions (TCC)

KeySwitch requires three privacy grants, depending on role:

| Permission | TCC service | Owner needs | Receiver needs |
|------------|-------------|-------------|----------------|
| Accessibility | `kTCCServiceAccessibility` | Yes (capture) | Yes (inject) |
| Input Monitoring | `kTCCServiceListenEvent` | Yes (capture) | No |
| Post Event | `kTCCServicePostEvent` | No | Yes (inject) |

`Info.plist` declares:

- `NSLocalNetworkUsageDescription` — local network for keyboard forwarding
- `NSBonjourServices` — `_keyswitch._tcp`
- `LSUIElement` — menu bar agent (no Dock icon)

### Code signing and TCC stability

macOS binds TCC grants to the app's code signature. Ad-hoc signing (`codesign -`) changes every build, invalidating permissions.

**Fix:** Run `./scripts/make-signing-cert.sh` once to create a stable `"KeySwitch Dev"` identity. `build-app.sh` uses it automatically. After the next install, grant permissions once more — they persist across rebuilds.

`install-on-mac.sh` on the receiver Mac also runs `tccutil reset` for all three services to clear stale entries from older builds.

---

## Build & distribution

### Prerequisites

- macOS 13+
- Xcode Command Line Tools (`swift`, `lipo`, `codesign`, `hdiutil`)

### Build universal app

```bash
./build-app.sh
```

Steps:

1. `swift build -c release --arch arm64`
2. `swift build -c release --arch x86_64`
3. `lipo -create` → fat binary in `dist/KeySwitch.app`
4. Copy `Info.plist` + `AppIcon.icns`
5. Optional `codesign` with `"KeySwitch Dev"` or ad-hoc `-`

### Build DMG + ZIP

```bash
./build-dmg.sh
```

Produces:

| Artifact | Use case |
|----------|----------|
| `dist/KeySwitch.dmg` | Drag-to-Applications installer |
| `dist/KeySwitch.zip` | Preferred for the other Mac (avoids false "damaged" Gatekeeper errors) |

The ZIP includes `install-on-mac.sh` for turnkey receiver setup.

### Install on receiver Mac

```bash
unzip KeySwitch.zip
chmod +x install-on-mac.sh
./install-on-mac.sh
```

First launch of unsigned builds: right-click → Open.

---

## Testing & debugging

### Peer connectivity

With KeySwitch running on the target Mac:

```bash
# Ping
python3 scripts/test-peer-ping.py 127.0.0.1 9847 <token>

# Setup snapshot
python3 scripts/test-peer-setup.py 127.0.0.1 9847 <token>
```

Swift equivalent: `swift scripts/test-peer-ping.swift 127.0.0.1 9847 <token>`

### In-app diagnostics

- **Settings → Test connection** — ping with configured token/peer
- **Settings → Check other Mac** — fetches `PeerSetupSnapshot` (permissions, owner conflict detection)
- **Menu → Refresh** — reinstalls event tap and restarts network stack

### Common issues

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| "Event tap creation failed" | TCC not granted or stale after rebuild | Grant permissions, quit fully, relaunch, Refresh |
| "Token mismatch" | Different tokens on each Mac | Re-pair or sync token in Advanced |
| "Both Macs claim the keyboard" | `isKeyboardOwner` true on both | Turn off owner toggle on one Mac |
| Peer not in discovery list | Bonjour blocked, different VLAN, firewall | Set peer IP manually; check Local Network permission |
| Mouse lag | Nagle buffering (should be off) | Verify `noDelay = true` in `lowLatencyParams()` |
| DMG "damaged" on other Mac | Unsigned app quarantine | Use ZIP + `install-on-mac.sh` or `xattr -cr` |

---

## Design decisions

### Why Network.framework over URLSession/HTTP?

Low-latency bidirectional TCP with Bonjour integration. HTTP would add overhead; UDP would complicate ordering for keystrokes.

### Why length-prefixed JSON instead of a binary protocol?

Simple to debug with Python scripts; message rate is human typing speed, not gaming-tier throughput. JSON overhead is acceptable.

### Why a persistent stream for forwarding?

Opening a TCP connection per keystroke would add ~milliseconds of latency per key. One connection amortizes handshake cost.

### Why `nonisolated(unsafe)` on `outboundStream`?

The event tap callback cannot hop to `@MainActor` per event. Stream setup/teardown is `@MainActor`; sends happen from the main run loop only. Documented invariant in source.

### Why relative mouse deltas?

Owner and receiver may have different monitor arrangements and cursor positions. Relative movement preserves intent; receiver clamps to its own display union.

### Why ⌘⇧K as escape hatch?

While forwarding, all other keys go to the peer. A local-only hotkey guarantees the user can always reclaim control of the owner Mac.

---

## Version & bundle identity

| Property | Value |
|----------|-------|
| Bundle ID | `com.keyswitch.app` |
| Version | 1.0.0 (CFBundleShortVersionString) |
| Bonjour type | `_keyswitch._tcp` |
| Default port | 9847 |

---

## Future work (not implemented)

- Bluetooth-driven keyboard handoff (IOBluetooth connect/disconnect)
- TLS on the TCP channel
- Multi-peer routing (one keyboard, N Macs)
- Menu bar indication of peer online/offline state