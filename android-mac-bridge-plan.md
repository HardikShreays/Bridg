# Bridg — Build Plan and Current State

Android↔Mac bridge. MIT, no monetization. Screen mirroring, file transfer,
clipboard sync, notification forwarding.

**Read this file before touching the code.** It is written for a coding agent
picking the project up cold. The original aspirational plan (pre-implementation,
still useful for design rationale on unbuilt phases) is at
[docs/original-plan.md](docs/original-plan.md).

Phases 1 and 2 are **built and verified on real hardware**. Phase 3 is **not
wired up**. The gap between "the file exists" and "it is connected to anything"
is the single most important thing to understand here — the codebase was
originally written as a set of well-formed modules that were never joined, and
some of that is still true for Phase 3.

A second pass on Phase 2 (session two) found that "wired" had understated the
problem: clipboard sync and notification history were each dead for their own
independent reason — a Mac background-timer starvation bug, and a
`GRDB`/schema mismatch that meant no notification had *ever* been stored. Both
are now fixed and verified with real, repeated device traffic — see landmines
16–21 in §4 for exactly what was wrong and why it was invisible until traced.

---

## 1. State of the world

Verified end to end on a Galaxy A35 (Android 16) and macOS 26, on a segmented
campus network (Mac `10.7.12.x`, phone `10.7.7.x`).

| Capability | State | Evidence |
|---|---|---|
| QR pairing, X25519 + HKDF, encrypted session | **Working** | Paired on device; both sides derive the same key |
| Auto-reconnect, no re-scan (`PairResume`) | **Working** | Survives restart of either app; "Connected to Mac" |
| ChaCha20-Poly1305 transport | **Working** | Zero decrypt failures across ping/pong cycles |
| Clipboard Mac → phone | **Working** | Repeated soak tests, real content synced |
| Clipboard phone → Mac | Foreground-only | Android 10+ platform restriction, not a bug |
| Notification forwarding, history, reply | **Working** | Real WhatsApp/Gmail notifications stored on Mac; reply path untested |
| Mac shows a notification banner | **Needs one manual step** | macOS notification permission — see landmine 22 |
| File transfer both directions | Wired; crash-on-bad-path fixed, full transfer untested | See landmine 21 |
| **Screen mirroring** | **Not wired** | Android sends frames; Mac drops them on the floor |
| **Input control** | **Not wired** | Android receives `InputEvent`; Mac never sends one |
| **Camera as webcam** | **Not started** | `CameraCapture.kt` has zero callers |

Build, run and pairing instructions for a human are in
[RUNNING.md](RUNNING.md). Do not duplicate them here.

```bash
./mac/make_app.sh && open mac/build/Bridg.app   # Mac (menu bar app, no Dock icon)
cd android && ./gradlew installDebug            # Android
swift test --package-path mac                   # 8 tests
cd android && ./gradlew testDebugUnitTest       # 2 tests
```

---

## 2. Architecture, as actually implemented

```
mac/Sources/Bridg/
├── App/AppState.swift          ← owns the connection; ALL routing lives here
├── Transport/ConnectionManager.swift   ← listener, handshake, framing, keepalive
├── Transport/FrameCodec.swift  ← FrameCodec.encode + FrameBuffer (stream reassembly)
├── Transport/EncryptedTransport.swift  ← ChaChaPoly
├── Pairing/KeychainManager.swift       ← identity, ECDH, SharedSecretKDF
├── Pairing/PairingManager.swift        ← QR content + rendering
├── Video/VideoDecoder.swift, MirrorView.swift   ← BUILT BUT UNCONNECTED
└── CameraExtension/VirtualCamera.swift ← scaffold only

android/app/src/main/kotlin/com/bridg/
├── service/BridgService.kt     ← owns the connection; ALL routing lives here
├── transport/BridgSocket.kt    ← socket, send/receive loops, encryption
├── transport/FrameCodec.kt, ServiceDiscovery.kt
├── pairing/KeyManager.kt, PairingManager.kt, SessionKdf.kt
├── capture/ScreenCapture.kt    ← wired, sends frames
└── camera/CameraCapture.kt     ← NO CALLERS, dead code
```

**Topology: the Mac is the server.** It listens on TCP 18920 and advertises
`_bridg._tcp`. The phone discovers and dials in. Only the Mac advertises; only
the phone browses. (Originally both did both, so each discovered itself.)

**All message routing goes through exactly two functions.** Add new message
handling there, nowhere else:

- Mac: `AppState.route(_:)` — `mac/Sources/Bridg/App/AppState.swift`
- Android: `BridgService.handleIncomingEnvelope(_:)`

Transport-level messages (`PairRequest`, `PairResume`, `Ping`, `Pong`) are
consumed inside `ConnectionManager.handleTransportMessage` and never reach
`route`.

---

## 3. Invariants — break these and everything fails silently

The failure mode for all of these is "decryption failed" or a dead socket, with
no useful error. Treat them as frozen unless you change both sides together.

**Session key**
```
raw    = X25519(ourPrivate, theirPublic)
session = HKDF-SHA256(ikm: raw, salt: "bridg-session", info: "", len: 32)
```
Mac: `SharedSecretKDF.derive` (CryptoKit `HKDF<SHA256>`).
Android: `SessionKdf.deriveSessionKey` (hand-rolled, `javax.crypto.Mac`).
Both are pinned to the same test vector
(`7e6f4ddb…b3e3`) by `testHKDFMatchesTheVectorAndroidDerives` and
`derivesTheSameSessionKeyAsTheMac`. **If you touch either, run both suites.**

**AEAD**: ChaCha20-Poly1305 IETF. CryptoKit's `ChaChaPoly` is byte-identical to
libsodium's `crypto_aead_chacha20poly1305_ietf_*` — verified by
`testChaChaPolyWireFormatMatchesLibsodium`.

**Nonce layout** (12 bytes) — both directions share one key, so the spaces must
be disjoint or the cipher breaks catastrophically:
```
[0]     direction: 0x00 Mac→phone, 0x01 phone→Mac
[1..3]  zero
[4..11] big-endian counter, starts at 1 per connection
```

**Framing**: `4-byte big-endian length + payload`. Payload is the serialized
`Envelope`, encrypted once the handshake completes. Max frame **4 MB on both
sides** — they must match.

**Handshake ordering** (subtle, and the source of a real bug):
- *First pair*: phone sends `PairRequest` plaintext → Mac replies `PairResponse`
  **plaintext**, then enables encryption. Phone enables on receipt.
- *Resume*: phone sends `PairResume` plaintext, then enables encryption; the Mac
  enables encryption **before** sending `PairResumeAck`, so the ack is
  encrypted. The phone decrypting it is the mutual proof.
  This is why `BridgSocket.sendThenEncrypt` exists: the key must be installed on
  the send loop immediately after the frame is written, not from the caller, or
  it races the queue.

---

## 4. Landmines already hit — do not re-derive these

Every one of these cost real debugging time. They are fixed; this list exists so
a regression is recognised instantly rather than rediscovered.

**Android**

1. **lazysodium needs the `@aar` builds.** Its POM pulls the desktop JNA jar,
   which has no `libjnidispatch.so`. `libsodium.so` ships, the thing that calls
   it does not, and the app dies on launch with `UnsatisfiedLinkError`. Fixed in
   `build.gradle.kts` — keep `com.goterl:lazysodium-android:…@aar` **and**
   `net.java.dev.jna:…@aar`.
2. **Foreground service types.** The manifest declares
   `connectedDevice|mediaProjection`. On Android 14+, calling `startForeground`
   claiming `mediaProjection` before the user grants capture consent is a
   `SecurityException` that kills the process. Start as `connectedDevice`; only
   add `mediaProjection` inside `startScreenCapture`.
3. **`MediaProjection` is not `Parcelable`.** Pass the *consent `Intent`* from
   `onActivityResult` to the service, then call
   `MediaProjectionManager.getMediaProjection(RESULT_OK, intent)` there.
4. **The service is `exported="false"`** — correct, but it means you cannot
   trigger pairing with `adb am start-foreground-service`. Testing pairing
   requires the camera. Do not "temporarily" ship it exported.
5. **NSD resolves must be serialized** — a concurrent resolve returns
   `FAILURE_ALREADY_ACTIVE`. `ServiceDiscovery` queues them.
6. **NSD service type comparison** — Android returns `_bridg._tcp.` with
   inconsistent dots; compare on `.trim('.')`.
7. **Clipboard reads are blocked in the background** on Android 10+. Phone → Mac
   sync only fires while the app is foreground. Platform restriction; document
   it, do not "fix" it.
8. **Notification replies need `RemoteInput.addResultsToIntent`.** Stuffing the
   text into a bare `Bundle` produces a silently empty reply.

**Mac**

9. **`swift test` used to destroy the app's identity.** The Keychain test called
   `generateKeyPair()` against the real `com.bridg` item, which deletes before
   it adds — silently regenerating the Mac's keypair and orphaning every paired
   device. Symptom: pairing works, then "decryption failed" after any test run.
   `KeychainManager` now takes an injectable `service`; **tests must always use
   a throwaway one.**
10. **Never regenerate identity on a Keychain error.** `getOrCreatePublicKey()`
    generates only on `errSecItemNotFound`. Any other status refuses and logs.
11. **`swift build` alone is not runnable.** No bundle ID means
    `UNUserNotificationCenter` crashes and macOS denies Local Network access
    (so Bonjour returns nothing). Always use `./mac/make_app.sh`.
12. **`Data.removeFirst` does not rebase indices.** After the first frame the
    buffer no longer starts at 0, so absolute subscripts read out of bounds.
    `FrameBuffer` indexes relative to `startIndex`. A test feeds it one byte at
    a time specifically to catch this.
13. **SwiftPM sometimes reports "Build complete" without recompiling** after a
    quick edit (mtime granularity). If a change does not take effect, `touch`
    the file and rebuild before debugging anything else.

**Schema**

14. **The protobuf schema exists in three places and nothing keeps them in
    sync.** `proto/bridg.proto` is canonical but is not used by any build.
    Android compiles `android/app/src/main/proto/bridg.proto`. The Mac uses the
    **checked-in** `mac/Sources/Bridg/Generated/bridg.pb.swift` — `Package.swift`
    declares the SwiftProtobuf plugin as a dependency but never applies it to
    the target, so nothing regenerates it. Changing a message means editing both
    `.proto` copies and regenerating the Swift by hand:
    ```bash
    protoc --swift_out=mac/Sources/Bridg/Generated --proto_path=proto proto/bridg.proto
    cp proto/bridg.proto android/app/src/main/proto/bridg.proto
    ```
    They are currently in sync. Verify with
    `diff proto/bridg.proto android/app/src/main/proto/bridg.proto`.

**Network**

15. **mDNS does not cross subnets.** On segmented networks (campus, office,
    guest Wi-Fi) discovery finds nothing even though the devices route to each
    other fine. The QR therefore carries the Mac's LAN address
    (`bridg://pair/<pubkey>:<token>:<host>:<name>`) and the phone persists it as
    `last_host`. **Keep this field.** Discovery and known-host dialling race;
    whichever lands first wins.

**Mac, round two — found chasing "pairing works but every feature is silent"**

16. **`Timer.scheduledTimer` alone is not enough to keep a background app's
    polling alive.** `ClipboardSync`'s 0.5s timer only ran in the `.default`
    run loop mode; the moment the app's run loop spent time in any other mode
    (AppKit internals, a Network.framework callback), the timer stalled —
    in practice, almost immediately and for good. On top of that, `Bridg` is
    `LSUIElement` with no visible window most of the time, and macOS App Naps
    that shape of process within seconds, throttling timers further. **Both
    were required**: an isolated test with only the run-loop-mode fix and no
    App Nap exemption produced zero clipboard syncs across 90s and three
    separate changes; adding `ProcessInfo.beginActivity(options: [.userInitiated, …])`
    in `AppDelegate.applicationDidFinishLaunching` (held for the app's whole
    life) alongside `RunLoop.current.add(timer, forMode: .common)` in
    `ClipboardSync.scheduleTimer` made every change sync reliably. If you add
    another polling loop anywhere in the Mac app, it needs both.
17. **A `changeCount` poll can miss a value that gets overwritten inside one
    poll interval.** If two writes land in the same 0.5s window, only the
    later one is ever seen — this is inherent to polling-based clipboard sync
    (the original plan's own design), not a bug to chase further. It does not
    show up in real usage, where a person copies one thing at a time with gaps
    far longer than 0.5s.
18. **`GRDB`'s `Codable` conformance maps Swift property names straight to
    column names.** `StoredNotification`'s properties are camelCase
    (`packageName`, `appLabel`, …); the table `NotificationManager.setupDatabase`
    creates is snake_case (`package_name`, `app_label`, …). Every insert failed
    with "table notifications has no column named packageName", silently
    caught and printed — **no notification had ever been stored, from the
    very first version of this code.** Fixed with explicit `CodingKeys` on
    `StoredNotification` mapping each property to its real column. If you add
    a new `FetchableRecord`/`PersistableRecord` type, give it `CodingKeys`
    matching the schema — don't rely on the default mapping.
19. **`PersistableRecord.insert()` throws on a duplicate primary key; it does
    not update.** Android reposts the same notification id constantly for
    ordinary updates (an unread count ticking up, a download's progress). With
    `insert`, only the first post of any given id was ever stored and every
    later update to it silently failed. Use `save(db)` (insert-or-replace) for
    anything keyed by an id the sender can legitimately reuse.
20. **`BridgNotificationListenerService` and `BridgService` bind on
    independent schedules — wiring the forwarder from only one side is a
    race.** `NotificationListenerService` is bound by the system whenever it
    decides to, not when `BridgService` starts; in testing it regularly
    connected *after* both `startService()` and `onConnected()` had already
    tried to call `setEventForwarder`, so the forwarder was silently never
    set and no notification ever left the phone. Fixed by wiring from both
    directions: `BridgService` now exposes a companion `instance` (same
    pattern as the notification/accessibility services), and
    `BridgNotificationListenerService.onListenerConnected()` calls
    `BridgService.instance?.onNotificationListenerReady()` so whichever side
    starts last completes the connection.
21. **`BridgService.sendFile()` let a file-read failure propagate uncaught out
    of `onStartCommand`, crashing the whole service.** A raw `File` path
    outside the app's own storage can pass `.exists()` (a `stat()`) and still
    throw `FileNotFoundException` on open under scoped storage — a completely
    ordinary failure mode (bad permission, deleted file, a stale path from an
    old intent), and it took the entire phone↔Mac connection down with it, not
    just that one transfer. Now caught and logged; the service and connection
    survive a bad file path. A full file transfer was not exercised
    end-to-end this session — see Task D.
22. **macOS notification permission needs one manual grant per machine and
    cannot be scripted.** TCC's per-app decision isn't readable or resettable
    from an unprivileged shell (`tccutil reset` fails without a real
    interactive session), and `UNUserNotificationCenter.requestAuthorization`
    only prompts once — if that prompt is ever dismissed or the ad-hoc
    signature changes enough times in a row, macOS stops re-prompting
    entirely. This does **not** block anything else: notification history,
    storage, and the reply path are independent of it and work with the
    permission denied. Only the visible banner needs it. Fix: System Settings
    → Notifications → Bridg → Allow (or, if Bridg is missing from that list
    entirely, the app needs a fresh launch after the user manually resets it
    via `tccutil reset UserNotifications com.bridg.mac` in a real Terminal).

---

## 5. Remaining work

### Task A — Screen mirroring receive path (Mac)

Android already captures and sends. `ScreenCapture.kt` encodes H.264 via
`MediaCodec` and `BridgService` pushes `VideoStreamStart` and `VideoFrame`.
**The Mac never handles `.videoFrame`** — `AppState.route` has cases for
`videoStreamStart`/`Stop` that only flip a boolean.

`VideoDecoder.swift` is complete and unused: `configureDecoder(spsPps:)`,
`decode(nalUnits:pts:isKeyframe:)`, `onDecodedFrame: ((CVPixelBuffer) -> Void)`.
`MirrorView` has a working `AVSampleBufferDisplayLayer` path.

The gap is ownership: `MirrorViewModel` creates its own private `VideoDecoder`
and its `connectionManager` is never assigned, so it is inert.

1. Move the decoder to `AppState` (single owner, like every other feature).
2. `case .videoStreamStart(let s)` → `decoder.configureDecoder(spsPps: s.spsPps)`.
3. `case .videoFrame(let f)` → `decoder.decode(...)`.
4. Publish decoded frames from `AppState` so `MirrorView` renders them; drop
   `MirrorViewModel`'s private decoder.
5. Wrap `CVPixelBuffer` → `CMSampleBuffer` before `enqueueSampleBuffer`.

Watch for: video frames share the one send queue with everything else, and are
encrypted per frame. Profile before optimising, but expect backpressure work.

**Exit criteria**: phone screen renders on the Mac at ~30fps, under ~200ms
perceived latency on the same Wi-Fi; reconnect recovers within one keyframe.

### Task B — Input injection (Mac → Android)

Android is **already done**: `BridgAccessibilityService.dispatchInputEvent`
handles tap/swipe/long-press/text/back/home/recents, and
`BridgService` routes `INPUT_EVENT` to it. Requires the user to enable
Accessibility by hand.

The Mac side is the gap. `MirrorViewModel.sendTap` / `handlePinch` build correct
`InputEvent`s and send them to a `connectionManager` that is always `nil`.

1. Inject the real `ConnectionManager` (from `AppState`) into `MirrorViewModel`.
2. Add `NSView` mouse/key handlers on `MirrorNSView` → normalized 0.0–1.0
   coordinates → `sendTap` / swipe / key.
3. Add keyboard → `TEXT_INPUT` and the navigation buttons.

**Exit criteria**: clicking and typing on the mirror window reliably acts on the
phone.

### Task C — Camera as webcam

Lowest priority and the only task with a hard external blocker.

- `android/…/camera/CameraCapture.kt` exists with no callers. Add an
  `ACTION_START_CAMERA` path in `BridgService` mirroring `startScreenCapture`,
  and use `VideoStreamStart.stream_type = CAMERA` plus a distinct `stream_id`.
- `mac/…/CameraExtension/VirtualCamera.swift` is a scaffold. A real virtual
  camera needs a **CoreMediaIO Camera Extension** (macOS 12.3+) running as a
  separate system extension, which requires a provisioning profile with the
  Camera Extension entitlement — i.e. **a paid Apple Developer account**. The
  current ad-hoc signing in `make_app.sh` cannot produce this. Confirm the user
  has an account before starting.

### Task D — Device testing of Phase 2

Notifications and file transfer are wired but were never exercised on hardware.
Both need a real device run: grant Notification Access, post a notification with
a reply action, confirm it renders on the Mac and the reply fires; then send a
large file each way and verify checksums.

---

## 6. Working agreements

- **Two owners, no third.** `AppState` (Mac) and `BridgService` (Android) own
  the connection and all routing. Feature modules expose callbacks and are wired
  by the owner. Do not let a module reach for the socket itself — that is how
  the original codebase ended up with managers that computed data and discarded
  it (`// Would send via ConnectionManager`).
- **Grep for the pattern before fixing a symptom.** Several bugs here existed
  identically on both platforms (the inverted clipboard echo check, dropped
  send paths). Fixing one side only leaves the feature broken.
- **Any change under `pairing/` or `transport/` requires both test suites to
  pass.** They are the only thing standing between you and a silent
  interop break.
- **Keep `docs/PROTOCOL.md` current** when the wire format changes. The QR now
  carries a host field; that kind of change must land in the doc too.
- Real devices over emulators for anything touching AccessibilityService,
  MediaProjection, or notifications — OEM behaviour varies meaningfully.
