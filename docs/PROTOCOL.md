# Bridg Wire Protocol

## Overview

Bridg uses a single persistent TCP connection per session, with all messages serialized as Protocol Buffers (protobuf). Every message is wrapped in an `Envelope` with a length-prefix framing.

## Transport

### Framing

```
┌──────────────┬──────────────────────┐
│ 4-byte BE len│  serialized Envelope │
│  (uint32)    │     (N bytes)        │
└──────────────┴──────────────────────┘
```

- **4-byte big-endian length prefix** followed by the serialized protobuf `Envelope` bytes
- **Maximum frame size**: 4 MB. Both implementations must use the same cap — video
  keyframes exceed 64 KB, and a smaller cap on either side silently drops them.
- TCP provides no message boundaries: a single read may carry a partial frame or
  several. Receivers must buffer and reassemble (`FrameBuffer` on the Mac).
- Connection is persistent; no per-request connection setup

### Connection Lifecycle

1. **Discovery**: The **Mac is the server** — it listens on TCP 18920 and advertises
   `_bridg._tcp.local.`. The phone browses and dials in. Only one side advertises;
   if both advertise and browse, each discovers itself.

   mDNS is link-local multicast and does not cross subnets, so discovery finds
   nothing on segmented networks even when the devices route to each other. The QR
   payload therefore carries the Mac's address and the phone persists it:
   ```
   bridg://pair/<base64 x25519 pubkey>:<base64 token>:<host>:<device name>
   ```
   Fields split on `:`; the device name is last and may contain colons, so parsers
   must limit the split to 4 parts. The Mac strips colons from its own name.
2. **Pairing**: One-time QR code exchange (Phase 1)
3. **Resume**: On reconnect, the phone sends `PairResume` and the Mac answers with an encrypted ack (no re-pairing, no QR re-scan)
4. **Session**: Encrypted bidirectional message stream
5. **Teardown**: Graceful close or ping/pong timeout (30s)

### Encryption

All frames after pairing are encrypted with **ChaCha20-Poly1305** (libsodium):

1. During pairing, both sides perform X25519 ECDH to derive a shared secret.
   Both identity keys are long-term, so this raw secret is **the same on every
   connection between a given pair of devices**.
2. Each side also generates 16 fresh random bytes per connection — its
   `session_salt` — and sends them in the clear in its last unencrypted frame.
3. The raw X25519 output is **not** used directly. It is run through
   HKDF-SHA256 with salt `"bridg-session"`, info `initiator_salt ||
   responder_salt`, 32-byte output. The phone always dials in, so the phone is
   always the initiator and its salt always comes first. Both sides must derive
   identically — same order included — or every frame fails to open.
4. Each frame is encrypted with a unique 12-byte nonce, laid out as:
   ```
   [0]     direction tag: 0x00 Mac->phone, 0x01 phone->Mac
   [1..3]  zero
   [4..11] big-endian counter, starting at 1 for each connection
   ```
   Both directions share one key, so the direction tag is what keeps their nonce
   spaces disjoint. A repeated (key, nonce) pair breaks ChaCha20-Poly1305
   catastrophically.
5. The 16-byte Poly1305 auth tag is appended to each frame

**Why the salts matter.** The counter in step 4 restarts at 1 on every
connection. If the key never changed, connection #2 would encrypt with exactly
the (key, nonce) pairs connection #1 already used: XOR the two ciphertexts and
the keystream cancels, leaking the plaintexts, and the repeated nonce also leaks
the Poly1305 one-time key, which allows forgery. The per-connection salts are
what make the key fresh, so the restarting counter is harmless. They are not
secret — they only have to be unpredictable and unrepeated.

**On receive**, a frame is rejected unless its nonce carries the *peer's*
direction tag (otherwise one of our own frames could be reflected back at us and
would open perfectly) and its counter is strictly greater than the highest one
already accepted (the transport rides on ordered TCP, so a counter that does not
advance is a replay). The counter is only advanced *after* the Poly1305 tag
verifies — advancing on an unauthenticated nonce would let anyone who can write
to the socket send one forged frame with a huge counter and wedge every real
frame after it.

CryptoKit's `ChaChaPoly` (Mac) and libsodium's
`crypto_aead_chacha20poly1305_ietf_*` (Android) are byte-identical; both
implementations are pinned to a shared test vector.

Handshake frames are sent in plaintext over TCP — `PairRequest`/`PairResponse`
when pairing, `PairResume`/`PairResumeAck` when resuming. Both sides upgrade to
the encrypted transport immediately after the responder's reply, which is always
the last plaintext frame in either direction.

## Message Types

All message types are defined in `proto/bridg.proto`. See that file for the canonical schema.

### Pairing Flow

```
Android (Initiator)                 Mac (Responder, shows the QR)
      │                                   │
      │  [scans QR: pubkey, token, host]  │
      │──── PairRequest ─────────────────>│
      │     {pubkey, name, token, salt}   │
      │                                   │  [verifies token matches the QR]
      │<──── PairResponse ────────────────│  (plaintext — the last one)
      │      {pubkey, name, accepted,     │
      │       salt}                       │
      │                                   │  [derives key, enables encryption]
      │  [checks responder pubkey ==      │
      │   the key it scanned]             │
      │  [derives key, enables encryption]│
```

Authentication rests on the QR being an out-of-band channel: the token proves to
the Mac that the phone saw its screen, and comparing the responder's key against
the scanned one proves to the phone it is talking to that same Mac.

`PairResponse.session_salt` occupies field 3, which used to hold an unused
Ed25519 `signature` — an earlier design signed with an X25519 secret key, which
can never verify. Nothing ever populated it, so the number was free to reuse.

### Reconnect Flow

```
Android                             Mac
  │                                    │
  │──── PairResume ───────────────────>│  (plaintext)
  │     {pubkey_hash, salt, timestamp} │
  │                                    │  [finds device by SHA-256(pubkey)]
  │<──── PairResumeAck ────────────────│  (plaintext — the last one)
  │       {accepted, salt}             │
  │                                    │  [derives key, enables encryption]
  │  [derives key, enables encryption] │
```

The ack must go out in the clear, because it carries the salt half the phone
needs to derive this connection's key — it could not open a sealed one. It is
the last plaintext frame in either direction; both sides switch to encrypted
immediately after it. Key confirmation is implicit: if the two ends disagreed,
the very next frame would fail to open and the link would be dropped.

No signed nonce is involved. Possession of the stored identity key is what
authenticates a resume: an attacker who knows the (public) key hash still cannot
derive the session key, so it cannot read or produce a single valid frame.

### File Transfer

```
Sender                              Receiver
  │                                    │
  │──── FileTransferStart ────────────>│
  │     {filename, size, checksum,     │
  │      transfer_id, mime_type}       │
  │                                    │
  │──── FileChunk ────────────────────>│ (× N, 64KB each)
  │     {transfer_id, offset, data}    │
  │                                    │
  │<──── FileTransferAck ─────────────│
  │      {transfer_id, bytes_received, │
  │       complete}                    │
  │                                    │
```

Chunks are streamed strictly in order and both receivers enforce that: a chunk
whose offset is not exactly where the last one ended fails the transfer rather
than seeking past the gap and writing a file that is corrupt but reports
success. `FileTransferStart.checksum` is a SHA-256 hex digest, verified by the
receiver against the bytes it actually wrote whenever it is non-empty. The Mac
populates it; the phone does not yet, so phone→Mac transfers are covered only by
the per-frame Poly1305 tag and the offset check.

Despite `offset` being on the wire, **there is no resume today**: either side
failing a transfer discards it, and a reconnect starts over.

### Notification Flow

```
Android                            Mac
  │                                    │
  │──── NotificationEvent ────────────>│
  │     {id, package, title, text,     │
  │      actions, has_reply_action}    │
  │                                    │
  │  [User replies from Mac]           │
  │                                    │
  │<──── NotificationAction ──────────│
  │       {action_id, reply_text}      │
  │                                    │
  │  [Android fires PendingIntent]     │
```

### Clipboard Sync

```
Device A                            Device B
  │                                    │
  │──── ClipboardUpdate ──────────────>│
  │     {content, image_data,          │
  │      mime_type, timestamp,         │
  │      origin_id}                    │
  │                                    │
  │  [B ignores if origin_id matches   │
  │   own device ID — prevents echo]   │
```

### Video Stream

```
Android (capture)                   Mac (display)
  │                                    │
  │──── VideoStreamStart ─────────────>│
  │     {stream_type, width, height,   │
  │      fps, sps_pps}                 │
  │                                    │
  │──── VideoFrame ───────────────────>│ (× continuous)
  │     {stream_id, nal_units, pts,    │
  │      is_keyframe}                  │
  │                                    │
  │──── VideoStreamStop ──────────────>│
  │     {stream_id}                    │
```

### Input Injection

```
Mac (mirror window)                 Android (AccessibilityService)
  │                                    │
  │──── InputEvent ───────────────────>│
  │     {type, x, y, keycode, text,    │
  │      timestamp}                    │
  │                                    │
  │  [Android dispatches gesture/key   │
  │   via AccessibilityService]        │
```

### Device Status

```
Android                             Mac
  │                                    │
  │──── DeviceStatus ─────────────────>│  (on connect, then on change)
  │     {battery_percent, charging,    │
  │      battery_low}                  │
```

Android broadcasts `ACTION_BATTERY_CHANGED` on every voltage and temperature
tick — far more often than the percentage moves — so the phone forwards a
`DeviceStatus` only when a field the Mac actually renders has changed. It also
re-sends unconditionally right after each handshake: a reconnect leaves the Mac
knowing nothing, and the battery may not change again for minutes.

### Remote Actions

```
Mac                                 Android
  │                                    │
  │──── RemoteAction ─────────────────>│
  │     {action, url}                  │
```

- `RING` / `STOP_RING` — find-my-phone. Plays the alarm tone on the alarm
  stream, which still sounds when the phone is silenced, at full volume (the
  previous volume is restored when it stops). Stops on `STOP_RING` or after 30
  seconds, whichever comes first.
- `OPEN_URL` — offers a link as a high-priority notification the user taps.
  It does not open the browser directly: Android 10+ blocks background activity
  starts and does so *silently*, so a direct `startActivity` would work on some
  devices and quietly do nothing on others.

`url` is a trust boundary — the phone hands it to the system to launch — so both
ends independently accept only `http` and `https` with a non-empty host.
`intent://` can start arbitrary components and `file://` can expose local
storage. The two validators are pinned by tests on each side.

## Security Model

### Trust Model

- **Pairing**: Trust established via QR code exchange. Only devices that have scanned each other's QR codes can communicate.
- **Reconnect**: Trust re-established by possession of the stored keypair — only a device holding the paired private key can derive the session key. No QR re-scan needed.
- **Revocation**: Delete a paired device from either side to revoke access.

### Threat Mitigations

| Threat | Mitigation |
|--------|-----------|
| Unauthorized pairing | QR code required; no programmatic pairing path |
| Replay attacks | Nonce counter must strictly advance; per-connection salts mean a frame captured in an earlier session cannot open in this one |
| Reflection | Nonce direction tag must be the peer's, not ours |
| Nonce reuse across reconnects | Session key is re-derived per connection from both sides' fresh salts |
| MITM on LAN | ECDH key exchange; no plaintext after pairing |
| Eavesdropping | ChaCha20-Poly1305 encryption on all frames |
| Identity leakage | Pubkey advertised as SHA-256 hash, not raw key |
| Rogue reconnect | Only a holder of the paired private key can derive the session key |
| Hostile URL push | `OPEN_URL` accepts only http/https with a host, checked on both ends |
| Connection hijack by a LAN stranger | An unauthenticated newcomer cannot evict an established connection; a silently dead one is retired by the 30s pong timeout |

### Data at Rest

- **Android**: Paired device keys stored in `EncryptedSharedPreferences` (AES-256-GCM)
- **Mac**: The X25519 private key lives in the macOS Keychain with
  `kSecAttrAccessibleAfterFirstUnlock`; paired peer keys are in `UserDefaults`.
  The identity is only ever generated on `errSecItemNotFound` — regenerating it
  on any other error silently invalidates every paired device.
- **File chunks**: Written directly to Downloads directory; no intermediate encryption needed (full-disk encryption covers this)

## Error Handling

- **Connection lost**: Both sides detect via TCP keepalive or ping/pong timeout (30s)
- **Partial file transfer**: Receiver tracks last acked offset; sender can resume from that point
- **Notification echo**: Origin ID tagging prevents ping-pong clipboard/notification loops
- **Video stream corruption**: Keyframe request on decode error; stream restart if persistent

## Versioning

Protocol version is negotiated during the pairing handshake. A `protocol_version` field will be added to the `PairRequest`/`PairResponse` messages for forward compatibility. Breaking protocol changes require a version bump and graceful degradation for older clients.
