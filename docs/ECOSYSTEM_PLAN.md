# Bridg Ecosystem Plan

Goal: every device a person owns — Android phone, iPhone, iPad, Mac, Windows PC,
Linux box — connected through Bridg at once, not one Android phone talking to
one Mac.

This file is the plan of record. Each phase ends at a **hardware gate**: it is
not done until it has been verified on real devices. That rule is the lesson of
[android-mac-bridge-plan.md](../android-mac-bridge-plan.md) — code that "exists"
and code that is wired and working were repeatedly different things.

---

## 1. Where we are

```
Android phone ──(dials, TCP 18920, E2E encrypted)──▶ Mac (listens, Bonjour)
```

- **One Mac, one phone.** `ConnectionManager` holds a single `NWConnection`;
  `BridgSocket` holds a single socket; `KeyManager.getPairedPeerPublicKey()`
  returns `.first`.
- The roles are hard-coded as "phone" and "Mac", but the crypto is already
  role-neutral underneath: the nonce direction byte is really
  *responder→initiator (0x00)* / *initiator→responder (0x01)*, and the HKDF info
  is *initiator salt ‖ responder salt*. New platforms need **no wire change** to
  join — only new names for the two roles.

## 2. Target topology

```
             ┌──────────── Mac (hub) ─────────────┐
             │                                    │
  Android ───┤                                    ├─── iPhone / iPad
  (satellite)│                                    │    (satellite, foreground)
             └────────── Windows / Linux (hub) ───┘
                      Mac ◀──────▶ Windows   (desktop ↔ desktop link)
```

- **Hubs** (Mac, Windows, Linux) listen and advertise `_bridg._tcp`. They are
  always on, have no background limits, and own a screen to show things on.
- **Satellites** (Android, iPhone, iPad) dial **every** hub they are paired
  with, one socket each. Phones never listen: iOS cannot keep a listener alive,
  and Android doing so costs battery for nothing.
- **Desktop ↔ desktop**: the device that scanned/pasted the pair code is the
  initiator for that pair, permanently. No tie-break protocol needed.
- **No phone ↔ phone link.** Android and iPhone meet through a hub: a clip
  copied on one reaches the hub and the hub relays it. `ClipboardUpdate.origin_id`
  already exists for exactly this echo/loop prevention.

## 3. What can and cannot be done

✅ doable · ⚠️ doable with a real limit · ❌ not possible for a third-party app

### Android ↔ any hub (Mac / Windows / Linux)

Everything Bridg does today carries over to a Windows or Linux hub. The
limits are the existing Android ones (clipboard phone→hub only while the app is
in the foreground on Android 10+), not new ones.

### Windows as a hub

| Feature | | Notes |
|---|---|---|
| Pairing, resume, encryption | ✅ | Same protocol; Windows 10+ has native DNS-SD/mDNS |
| Notifications + inline reply | ✅ | Windows toasts support a text-input reply |
| Clipboard (background) | ✅ | `AddClipboardFormatListener` — no background limit, unlike macOS polling |
| Files | ✅ | |
| Screen mirroring + input | ✅ | H.264 decode via Media Foundation or WebCodecs in WebView2 |
| Battery / ring / open link / media keys | ✅ | Pure protocol, nothing platform-specific |
| Calls | ⚠️ | Answer/decline works as on Mac. Call *audio* on the PC needs Windows to act as a Bluetooth hands-free unit, which Phone Link does with private APIs — spike before promising |
| Distribution | ⚠️ | Unsigned `.exe` triggers SmartScreen; a code-signing cert costs money. Firewall prompt on first listen |

Linux is the same as Windows except: notification reply depends on the desktop
environment, and **Wayland** restricts background clipboard reading (needs the
`wlr-data-control` / `ext-data-control` protocol, which GNOME does not ship).

### iPhone as a satellite

The single constraint behind most rows: **iOS suspends a backgrounded app
within seconds and will not keep its socket open.** There is no sanctioned way
around this for a sync app (VoIP/audio background modes are rejected in review
for this use; push-to-wake requires a server, which breaks "no data leaves your
network").

| Feature | | Notes |
|---|---|---|
| Send files iPhone → hub | ✅ | Share Extension from any app's share sheet |
| Receive files hub → iPhone | ⚠️ | Only while Bridg is open; saved to its own folder in Files |
| Clipboard | ⚠️ | Foreground only. Reading shows the iOS "Allow Paste" prompt unless the user sets *Paste from Other Apps → Allow* |
| Battery on the hub | ⚠️ | Only while the app is open — goes stale in the background |
| Open link on iPhone | ⚠️ | Only while the app is open |
| Screen mirroring iPhone → hub | ⚠️ | **View-only**, via a ReplayKit broadcast extension the user starts from Control Center each time; 50 MB memory cap in the extension |
| Controlling the iPhone from the hub | ❌ | No input-injection API exists |
| Reading other apps' notifications | ❌ | No API. Two partial escapes, both spikes: **(a)** ANCS over Bluetooth LE — how Phone Link gets iPhone notifications on Windows; works on Windows/Linux, unverified from a macOS app. **(b)** EU only, iOS 26.3+: `AccessoryNotifications`, built for accessories you make, one at a time, and it turns off Apple Watch notifications while active |
| SMS / iMessage | ❌ | No API. (Phone Link reads SMS over Bluetooth MAP on Windows; iMessage is not reachable) |
| Answer/decline/place calls | ❌ | CallKit cannot touch cellular calls |
| Ring phone, media control | ❌ | No background execution; no control of other apps' playback |
| Distribution | ⚠️ | Apple Developer Program ($99/yr) + App Store review |

Note: **iPhone ↔ Mac is Apple's own territory** (Continuity, iPhone Mirroring,
Universal Clipboard, AirDrop). Bridg adds little there; the iPhone client earns
its keep with **Windows/Linux hubs** and as a member of a mixed household.

### iPad

Everything in the iPhone table applies, plus one role that **does** work well:
**iPad as a viewer and controller for the Android phone** — decode the mirror
stream with VideoToolbox and send touches back as `InputEvent`s. The iPad is the
controller there, not the controlled device, so iOS restrictions don't bite
(foreground only, which is fine for a screen you're looking at).

### Desktop ↔ desktop (e.g. Mac ↔ Windows)

| Feature | | Notes |
|---|---|---|
| Clipboard both ways | ✅ | |
| Files both ways | ✅ | |
| Windows notifications → Mac | ✅ | `UserNotificationListener` on Windows |
| Mac notifications → Windows | ❌ | macOS has no API to read other apps' notifications |
| Shared keyboard/mouse, screen sharing | — | Out of scope; Deskflow / RDP / Screen Sharing exist |

## 4. Phases

### Phase 0 — Close the pre-handshake hole ✅ done, verified on hardware

Both sides acted on **plaintext frames received before the handshake**. Anyone
on the Wi-Fi could:
- open port 18920 on the Mac and push clipboard text, fake notifications or
  files, or
- advertise `_bridg._tcp`, let the phone dial in, and send plaintext
  `InputEvent` (taps through the accessibility service), `CallControl ANSWER`
  or `OPEN_URL`.

Fixed in `ConnectionManager.drainFrames` and `BridgSocket`'s receive loop: before
the session key exists, anything but the handshake drops the connection. Rule
added to [PROTOCOL.md](PROTOCOL.md). Tests:
`testOnlyTheHandshakeIsAcceptedBeforeEncryption` (Mac),
`plaintextCommandBeforeHandshakeDropsTheLink` (Android).

**Gate:** ✅ Mac side confirmed by the owner. The phone side first ran on
hardware with the Phase 1 build (the phone had the release-signed 0.3.3, which
a debug build cannot update), and passed there — see Phase 1.

### Phase 1 — The phone links to every paired computer ✅ single-computer gate passed

Re-scoped once the owner said: Windows PC available, iPhone/iPad deferred. The
target is *one Android phone on the Mac and the Windows PC at once*. That needs
the phone to hold several links; it does **not** need the Mac to hold several
phones, so that half moved to Phase 4, where the Windows↔Mac link needs it.

Done:
- `BridgService` keeps one `HubLink` per paired computer — own socket, salt,
  session key, retry timer, queued shares. One computer dropping never touches
  the others.
- Notifications, clipboard, battery, media state, call alerts → every ready
  computer. Pong and file acks → the link they came in on. Mirroring → every
  ready computer (`ponytail:` note — add a picker if two at once hurts).
- Sharing a file with 2+ computers paired asks which one (`EXTRA_HUB_ID`).
- Clipboard received from one computer is passed on to the others, origin_id
  intact — so Mac → PC clipboard already works *through the phone*.
- Hubs advertise TXT `id` = hex of the first 8 bytes of SHA-256(pubkey)
  (`ConnectionManager.hubTag` / `KeyManager.hubTag`, pinned to one vector on
  both sides). The phone now dials only paired computers; an untagged service
  (older Mac build) is used only when exactly one computer is paired.
- `KeyManager`: host per computer (legacy `last_host` migrated once);
  re-pairing the same computer reuses its entry instead of duplicating it.
- UI strings say "computer" instead of "Mac".

**Gate**, Galaxy A35 (Android 16) + macOS 26, 2026-10-09:
- ✅ Fresh QR pairing through `HubLink` (dialled the QR's host directly).
- ✅ Mac app killed and relaunched → phone saw the loss, retried every 5 s,
  resumed without a re-scan; sealed traffic flowed afterwards.
- ✅ Notification phone → Mac (row in the Mac's notifications.db).
- ✅ Clipboard Mac → phone, before and after the resume.
- ✅ File phone → Mac via the share intent, landed in ~/Downloads intact.
- ⏳ Needs a hand on the Mac UI: ring, open link, file Mac → phone, mirroring
  + input, media keys, call answer.
- ⏳ Two computers at once — waits for the Windows hub (Phase 2).

Found on the way: this campus Wi-Fi drops mDNS multicast, so the phone reaches
a computer only at its saved address; when that address changes, only a QR
re-scan recovers. Phase 2 must not depend on Bonjour either — show the address
on the hub and accept a typed-in one, or rescan on failure.

### Phase 2 — Windows + Linux hub

- **Rust core** (framing, X25519 + HKDF + ChaCha20-Poly1305, protobuf via
  `prost`, mDNS) pinned to the **same test vectors** the Mac and Android tests
  already use.
- **Tauri** shell for UI (WebView2 on Windows, WebKitGTK on Linux): one codebase
  for both, and the core runs on this Mac too, so it can be tested against the
  real phone before a Windows box is involved.
- Feature order: pair/resume → clipboard → notifications + reply → files →
  battery/ring/link/media → mirroring + input → calls (spike).
- Chosen over C#/.NET: Windows-only, and .NET has no built-in X25519.

**Gate:** Android ↔ Windows at parity with Android ↔ Mac (calls excepted), on a
real Windows machine.

### Phase 3 — iPhone + iPad satellite — ⏸ deferred by owner (no Apple Developer membership)

- Extract `FrameCodec`, `EncryptedTransport`, `SharedSecretKDF` and
  `KeychainManager` into a shared Swift package (`BridgCore`) used by both the
  Mac app and the iOS app — CryptoKit and Network.framework exist on iOS.
- Add `DeviceInfo { platform, device_name, app_version }` as the first sealed
  frame both ways, so a hub hides what a peer can't do (no Mirror/Ring buttons
  for an iPhone). Lands here, when the second kind of satellite exists.
- Ship the ✅/⚠️ rows from §3: QR pairing, share extension, foreground
  clipboard/battery/links/files.
- iPad: Android mirror viewer + touch controller.
- Stretch: ReplayKit view-only mirroring.

**Gate:** iPhone ↔ Windows and iPhone ↔ Mac on real devices; iPad drives the
Android phone.

### Phase 4 — Desktop ↔ desktop

First, the hub half of the old Phase 1 (moved here): the Mac (and the Windows
hub) hold several sessions — one `PeerSession` per socket, capped at ~16; an
older session for the same device is evicted only **after** the new one opens a
sealed frame (`PairResume` is plaintext with a public hash, so evicting on it
would let anyone kick a device off); per-feature routing to the right peer;
a device list in the UI.

- Pairing without a camera: the hub shows its `bridg://pair/…` string as a
  copyable code; the other desktop pastes it and becomes the initiator.
- Clipboard and files both ways; Windows notifications → Mac.
- Hubs relay clipboard to their other peers, deduplicated on `origin_id`.

**Gate:** copy on the Android phone, paste on the Windows PC, via the Mac.

### Spikes (any time, each a yes/no answer)

- ANCS from Windows (and from macOS) for iPhone notifications.
- EU `AccessoryNotifications` with a desktop as the "accessory".
- Windows as a Bluetooth hands-free unit for call audio.

## 5. Decided against

- **Adopting the KDE Connect protocol** (already on Android, iOS, Windows,
  Linux, macOS). It would bring an instant ecosystem but means replacing a
  transport whose encryption has already been hardened and pinned to test
  vectors. Revisit if Phase 2 stalls.
- **A cloud relay** for iPhone background sync or off-LAN use. It breaks "no data
  leaves your local network," and someone would have to run it.

## 6. Open questions for the owner

1. ~~Windows machine for the Phase 2 gate?~~ Yes.
2. ~~Apple Developer Program for Phase 3?~~ No — iPhone/iPad deferred.
3. Is anyone testing from the EU (only relevant to the `AccessoryNotifications` spike)?
