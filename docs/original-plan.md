# Android↔Mac Bridge — Open Source Build Plan

Codename suggestion: **Bridg** (rename freely). MIT-licensed, no monetization, built on scrcpy for capture.

---

## 0. Repo structure

```
bridg/
├── android/                  # Kotlin app (Gradle)
│   ├── app/
│   │   ├── src/main/kotlin/com/bridg/
│   │   │   ├── pairing/       # QR generation, handshake
│   │   │   ├── transport/     # socket/TLS layer
│   │   │   ├── capture/       # MediaProjection screen capture
│   │   │   ├── input/         # AccessibilityService injection
│   │   │   ├── notify/        # NotificationListenerService
│   │   │   ├── clipboard/     # ClipboardManager hooks
│   │   │   ├── files/         # chunked transfer
│   │   │   ├── camera/        # Camera2 → frame stream
│   │   │   └── service/       # foreground service tying it together
│   │   └── build.gradle.kts
├── mac/                       # Swift app (SwiftPM or Xcode project)
│   ├── Sources/Bridg/
│   │   ├── Pairing/
│   │   ├── Transport/
│   │   ├── Video/              # VideoToolbox decode + render
│   │   ├── Notifications/
│   │   ├── Clipboard/
│   │   ├── Files/
│   │   ├── CameraExtension/    # CoreMediaIO virtual camera
│   │   └── App/
├── proto/                     # shared protocol definitions (protobuf)
│   └── bridg.proto
├── docs/
│   └── PROTOCOL.md
└── README.md
```

Use **protobuf** for every message on the wire (Android and Swift both have solid codegen). Don't hand-roll JSON framing — you'll regret it by Phase 3.

---

## Protocol foundation (build this before Phase 1)

Single persistent connection per session. Envelope every message:

```protobuf
syntax = "proto3";
package bridg;

message Envelope {
  uint64 id = 1;
  oneof payload {
    PairRequest pair_request = 10;
    PairResponse pair_response = 11;
    FileChunk file_chunk = 20;
    FileTransferStart file_start = 21;
    ClipboardUpdate clipboard = 30;
    NotificationEvent notification = 40;
    NotificationAction notif_action = 41;
    InputEvent input_event = 50;
    VideoFrame video_frame = 60;   // or raw stream, see Phase 3
  }
}
```

Transport: raw TCP socket, length-prefixed protobuf frames (4-byte big-endian length + payload). Wrap in TLS once pairing exchanges keys (Phase 1 covers this).

Discovery: **NSD** (Android) / **Bonjour** (Mac), service type `_bridg._tcp.local.`, advertise port + device name + a short pairing-state flag.

---

## Phase 1 — Pairing + Transport + File Transfer

**Goal:** two devices can discover each other, pair once via QR, reconnect automatically, and send a file in either direction. This is the foundation everything else sits on — don't skip proper key handling here to "get to the fun stuff faster."

### 1.1 Pairing
- Mac generates an ephemeral X25519 keypair on first launch, persists it (Keychain).
- Mac renders QR containing: `{mac_pubkey, mac_ip_hint, service_name, pairing_token}`.
- Android scans QR (CameraX + ML Kit barcode scanning), generates its own X25519 keypair, sends its pubkey back over the socket opened via the IP hint.
- Both sides derive a shared secret (ECDH), use it to key a TLS-PSK session or just symmetric AEAD (ChaCha20-Poly1305) for all subsequent frames. Don't reinvent crypto — use `libsodium` bindings on both platforms (has Kotlin and Swift wrappers).
- Persist paired device identity (pubkey + name) in:
  - Android: EncryptedSharedPreferences
  - Mac: Keychain
- Reject any connection whose pubkey doesn't match a stored paired device — this is your entire trust model, get it right.

### 1.2 Reconnect
- On app launch, both sides start NSD/Bonjour advertising + browsing.
- On discovering a service matching a known paired pubkey (advertised as a hash, not the raw key, to avoid leaking identity on open networks), auto-connect and re-derive session key via a lightweight resume handshake (signed nonce challenge, not a full re-pair).
- USB path: detect via `UsbManager` (Android) / `IOKit` USB notifications (Mac), tunnel the same protobuf protocol over `adb forward tcp:<port> tcp:<port>` — i.e., ADB is just a pipe here, not a separate protocol.

### 1.3 File transfer
- `FileTransferStart{filename, size, checksum, transfer_id}` then a stream of `FileChunk{transfer_id, offset, bytes}` (64KB chunks is a reasonable default).
- Receiver acks completion, sender can resume from last acked offset on reconnect — build resumability now, it's much harder to retrofit.
- Android write target: `Downloads/Bridg/`. Mac: `~/Downloads/Bridg/` via security-scoped bookmark if sandboxed.
- Menu-bar drag-and-drop target on Mac (NSDraggingDestination) — defer the UI polish, but stub the entry point now.

### Deliverable / exit criteria
- Two physical devices pair via QR.
- Kill and relaunch both apps — they reconnect without re-scanning.
- Drag a 500MB file onto the Mac app, confirm it lands intact (checksum match) on Android, and reverse.
- Turn off Wi-Fi mid-transfer, confirm it doesn't corrupt (either resumes or cleanly fails — no silent partial file).

---

## Phase 2 — Notifications + Clipboard

**Goal:** phone notifications appear on Mac, clipboard syncs both ways.

### 2.1 Notifications (Android → Mac)
- Android: `NotificationListenerService`, request the permission (user must grant manually in Settings — no programmatic path, be explicit about this in onboarding UX).
- On `onNotificationPosted`, extract: package name, app label, title, text, timestamp, whether it has reply actions (`RemoteInput`), and postable actions.
- Serialize as `NotificationEvent`, send over the socket. Debounce/dedupe rapid updates from progress-bar style notifications (downloads, media players) — don't spam Mac with 50 updates for one download.
- Filtering: let user mute per-app on Android side, enforce there (don't send muted app notifications at all — less to reason about on Mac side, less battery).
- Reply support: if `RemoteInput` is present, Mac sends `NotificationAction{transfer_id, reply_text}` back, Android fires the `PendingIntent` programmatically.

### 2.2 Notifications (Mac rendering)
- Use `UNUserNotificationCenter` to post native macOS notifications from received events.
- Group by conversation/package the way LinkMyMac does — store a rolling history (SQLite via GRDB, or just Core Data) so the user can scroll back, not just see the live toast.

### 2.3 Clipboard sync
- Android: poll `ClipboardManager` (there's no reliable global change listener across all API levels — you'll need `OnPrimaryClipChangedListener` plus a foreground service to keep it alive, since Android kills clipboard access for background apps on API 29+ unless you're the default IME or have a foreground service with visible notification).
- Mac: `NSPasteboard.changeCount` polling (no push API either — poll at ~500ms in an app-active state, back off when idle).
- Only sync text/links/small images (cap image size, e.g. 5MB) — don't try to sync arbitrary pasteboard types.
- Debounce: don't create a loop where Mac's own paste-from-Android triggers a re-sync back to Android. Tag synced items with an origin flag and ignore echoes for N seconds.
- Local history: keep last ~20 items on each side, searchable from Mac menu bar (matches LinkMyMac's clipboard history feature) — trivial with a ring buffer + SQLite.

### Deliverable / exit criteria
- Post a notification with a reply action on Android (e.g., a test messaging app or use `adb shell cmd notification post`), confirm it renders on Mac and a reply sent from Mac fires the intent on Android.
- Copy text on Mac, confirm it's pasteable on Android within ~1s, and vice versa.
- Confirm no ping-pong loop when both sides have active clipboards.

---

## Phase 3 — Screen Mirroring + Input Control

**Goal:** live screen mirror on Mac with mouse/keyboard control of the phone. This is the hard phase — lean on scrcpy.

### 3.1 Don't rebuild scrcpy — embed its approach
- scrcpy (Genymobile, Apache 2.0) already solves: MediaProjection capture → H.264 encode via `MediaCodec` → stream over a socket → native decode on desktop.
- Two integration options:
  1. **Vendor scrcpy's Android-side `scrcpy-server.jar`** as a subprocess/service pushed and run via ADB, and write your own Mac decoder client against its existing wire protocol (documented in scrcpy's repo). Fastest path, but couples you to their protocol and their ADB-push launch model.
  2. **Port scrcpy's capture logic into your own Kotlin service**, using your own protobuf `VideoFrame` messages instead of raw scrcpy protocol. More work, but keeps everything in your existing pairing/transport/crypto layer instead of a second ADB-based channel. **Recommended** — you already built a secure transport in Phase 1, don't bolt on a second insecure one just for video.

### 3.2 Android capture (recommended path, option 2)
- `MediaProjectionManager.createScreenCaptureIntent()` — user grants once per session (Android requires re-consent on some versions; persist gracefully, don't nag every launch if avoidable via a foreground service holding the projection).
- `VirtualDisplay` + `MediaCodec` (H.264, `COLOR_FormatSurface`) encode directly from the virtual display's surface — avoid CPU-side YUV conversion, keep it all on the GPU/codec surface path like scrcpy does.
- Target bitrate adaptive to network: start ~8Mbps on Wi-Fi, drop under congestion (watch socket buffer backpressure).
- Encode keyframe interval short enough for scrubbing/reconnect (~1-2s).
- Push `VideoFrame{sps_pps, nal_units, pts, is_keyframe}` over the Phase 1 transport.

### 3.3 Mac decode + render
- `VideoToolbox` hardware decode: `VTDecompressionSession` fed the SPS/PPS + NAL units from the stream.
- Render decoded `CVPixelBuffer` via `AVSampleBufferDisplayLayer` (simplest path, hardware-accelerated) inside an `NSView`/SwiftUI `NSViewRepresentable`.
- "Standard mirroring" = this pipeline as one window, scaled to fit.
- "Advanced mirroring" (per-app windows) = harder: requires either (a) Android-side per-app activity capture (not natively supported by MediaProjection, which only captures the whole display) or (b) client-side cropping/windowing tricks. Realistically, per-app windows on real LinkMyMac likely composite from the same full-display stream with app-bounds metadata sent alongside. Treat this as a stretch goal after full-screen mirroring is solid.

### 3.4 Input injection (Mac → Android)
- Mac captures mouse/trackpad/keyboard events on the mirror `NSView`, translates to normalized coordinates (0.0–1.0 relative to phone screen), sends `InputEvent{type: tap/swipe/key, x, y, keycode, action}`.
- Android side: **AccessibilityService** is the no-root path — `dispatchGesture()` for taps/swipes, `performGlobalAction()` for back/home/recents, and for text input either simulate key events or (more reliably) directly set text via the currently focused `AccessibilityNodeInfo` when possible.
- User must manually enable the Accessibility permission — same onboarding friction as notification access, document clearly, deep-link to the settings screen (`Settings.ACTION_ACCESSIBILITY_SETTINGS`).
- Latency budget: capture→encode→transport→decode→render should target well under 150ms end-to-end on local Wi-Fi to feel usable; profile each stage once the pipeline is up, don't guess.

### 3.5 Camera as webcam (do this after mirroring works — shares the video pipeline)
- Android: `Camera2` API captures frames, encode the same way as screen capture, push as a second `VideoFrame` stream (or a `stream_id` field distinguishing screen vs camera).
- Mac: this is the genuinely hard OS-integration part — you need a **Camera Extension** (`CoreMediaIO` DAL plugin via the modern System Extensions / Camera Extension framework, macOS 12.3+) that other apps (Zoom, Meet, FaceTime) can select as a virtual camera source. Apple's sample code "Creating a Camera Extension with Core Media I/O" is the reference to build from. This runs as a separate system-extension process from your main app — expect real packaging/entitlements pain (needs a provisioning profile with the Camera Extension entitlement).

### Deliverable / exit criteria
- Phone screen mirrors live on Mac at usable framerate (aim 30fps) with <200ms perceived latency on same Wi-Fi.
- Click/type on Mac mirror window reliably taps/types on the actual phone.
- Selecting "Bridg Camera" in Zoom/QuickTime shows the phone's camera feed.

---

## Phase 4 — Polish / parity features (optional, do after 1–3 are solid)

- Duo Mode (one phone, two Macs): requires your pairing model to support multiple simultaneous paired-Mac sessions per phone, with a simple lock so only one Mac can hold the live mirror/input session at a time — arbitrate with a `SessionLock{holder_id}` message broadcast to all connected Macs.
- Contacts browsing: read `ContactsContract` on Android (needs `READ_CONTACTS`), send over transport, cache read-only on Mac.
- Call events: `TelephonyManager`/`PhoneStateListener` (or `TelecomManager` on newer APIs) for incoming call metadata, surfaced as a special notification type.
- Menu bar control center (Mac): `NSStatusItem` with a popover — battery %, connection state, quick actions. Cosmetic, build last.
- Localization: externalize strings from day one (`strings.xml` / `.strings` files) even if you only ship English initially — retrofitting i18n later is annoying, doing it from the start is free.

---

## Cross-cutting concerns to handle throughout, not at the end

- **Battery**: Android foreground service is mandatory for anything background (clipboard, notifications, reconnect) — be upfront in-app about why, and document the "set to Unrestricted" step for OEMs (Samsung/Xiaomi/etc. aggressively kill background services).
- **Permissions onboarding**: you'll need Notification Access, Accessibility, Camera, local network, and possibly "Display over other apps." Build a single onboarding flow that requests these sequentially with plain-language explanations — this is where most similar apps get review complaints.
- **Security model**: reconfirm at each phase that a rogue device on the same LAN can't (a) pair without the QR flow, (b) replay old session tokens, (c) MITM an unencrypted frame. Write this into `docs/PROTOCOL.md` as you go, not retroactively.
- **Testing**: since a lot of this is hardware/OS-dependent, prioritize a small matrix of real devices (one Samsung, one Pixel, one older Android version) over emulator testing for Phases 2–3 — AccessibilityService and MediaProjection behavior varies meaningfully by OEM.

---

## Suggested sequencing for a solo/small team

1. Protocol + Phase 1 (pairing, transport, files) — **2–3 weeks**
2. Phase 2 (notifications, clipboard) — **1–2 weeks**
3. Phase 3.1–3.4 (mirroring + input, no camera) — **3–5 weeks**, this is the bulk of the effort
4. Phase 3.5 (camera extension) — **1–2 weeks**, isolated enough to do anytime after 3.4
5. Phase 4 — ongoing, pick features as needed

Ship Phase 1+2 as a usable open-source release before tackling mirroring — it's already a genuinely useful tool at that point (file transfer + notifications + clipboard), and you'll get real user feedback before sinking weeks into the video pipeline.
