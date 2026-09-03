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

1. During pairing, both sides perform X25519 ECDH to derive a shared secret
2. The raw X25519 output is **not** used directly. It is run through
   HKDF-SHA256 with salt `"bridg-session"`, empty info, 32-byte output. Both
   sides must derive identically or every frame fails to open.
3. Each frame is encrypted with a unique 12-byte nonce, laid out as:
   ```
   [0]     direction tag: 0x00 Mac->phone, 0x01 phone->Mac
   [1..3]  zero
   [4..11] big-endian counter, starting at 1 for each connection
   ```
   Both directions share one key, so the direction tag is what keeps their nonce
   spaces disjoint. A repeated (key, nonce) pair breaks ChaCha20-Poly1305
   catastrophically.
4. The 16-byte Poly1305 auth tag is appended to each frame

CryptoKit's `ChaChaPoly` (Mac) and libsodium's
`crypto_aead_chacha20poly1305_ietf_*` (Android) are byte-identical; both
implementations are pinned to a shared test vector.

Pre-pairing frames (the initial `PairRequest`) are sent in plaintext over TCP, then immediately upgraded to encrypted transport once the shared key is derived.

## Message Types

All message types are defined in `proto/bridg.proto`. See that file for the canonical schema.

### Pairing Flow

```
Android (Initiator)                 Mac (Responder, shows the QR)
      │                                   │
      │  [scans QR: pubkey, token, host]  │
      │──── PairRequest ─────────────────>│
      │     {pubkey, name, token}         │
      │                                   │  [verifies token matches the QR]
      │<──── PairResponse ────────────────│  (plaintext — the last one)
      │      {pubkey, name, accepted}     │
      │                                   │  [enables encryption]
      │  [checks responder pubkey ==      │
      │   the key it scanned]             │
      │  [derives key, enables encryption]│
```

Authentication rests on the QR being an out-of-band channel: the token proves to
the Mac that the phone saw its screen, and comparing the responder's key against
the scanned one proves to the phone it is talking to that same Mac. The
`signature` field in `PairResponse` is unused — an earlier design signed with
Ed25519 using an X25519 secret key, which can never verify.

### Reconnect Flow

```
Android                             Mac
  │                                    │
  │──── PairResume ───────────────────>│  (plaintext)
  │     {pubkey_hash, timestamp}       │
  │  [enables encryption immediately]  │
  │                                    │  [finds device by SHA-256(pubkey),
  │                                    │   derives key, enables encryption]
  │<──── PairResumeAck ────────────────│  (ENCRYPTED)
  │       {accepted}                   │
  │  [decrypting it is the proof]      │
```

No signed nonce is needed: the ack is encrypted under the resumed session key,
so decrypting it proves both sides hold the same key. Ordering matters — the
phone must install its key immediately after writing `PairResume`, on the send
path itself, or it races the Mac's already-encrypted reply.

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
  │ [On resume: resend from last acked offset]
```

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

## Security Model

### Trust Model

- **Pairing**: Trust established via QR code exchange. Only devices that have scanned each other's QR codes can communicate.
- **Reconnect**: Trust re-established via signed nonce challenge using the stored keypair. No QR re-scan needed.
- **Revocation**: Delete a paired device from either side to revoke access.

### Threat Mitigations

| Threat | Mitigation |
|--------|-----------|
| Unauthorized pairing | QR code required; no programmatic pairing path |
| Replay attacks | Timestamped nonces with monotonic counter |
| MITM on LAN | ECDH key exchange; no plaintext after pairing |
| Eavesdropping | ChaCha20-Poly1305 encryption on all frames |
| Identity leakage | Pubkey advertised as SHA-256 hash, not raw key |
| Rogue reconnect | Resume ack is encrypted under the stored session key |

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
