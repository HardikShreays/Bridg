# Bridg

**Android ↔ Mac Bridge** — Open source, MIT-licensed screen mirroring, file transfer, clipboard sync, and notification forwarding between Android phones and Macs.

Built on proven capture approaches (inspired by scrcpy) with a custom protobuf-based transport layer and end-to-end encryption.

## Features

- **Pairing**: One-time QR code pairing with X25519 key exchange, auto-reconnect
- **File Transfer**: Drag-and-drop files between devices with resume support
- **Notifications**: Phone notifications appear natively on Mac, with reply support
- **Clipboard Sync**: Copy on one device, paste on the other
- **Screen Mirroring**: Live phone screen on your Mac with low latency
- **Input Control**: Click, type, and gesture on your phone from Mac

## Architecture

```
bridg/
├── android/        # Kotlin Android app (Gradle)
├── mac/            # Swift macOS app
├── proto/          # Shared protobuf protocol definitions
└── docs/           # Protocol docs, design notes
```

## Getting Started

### Prerequisites

- Android Studio (latest stable), building with **JDK 17 or 21** (JDK 24+ is not
  supported by this project's Gradle/AGP — see [RUNNING.md](RUNNING.md))
- Xcode 15+ with macOS 13+ deployment target
- protobuf compiler (`protoc`) or buf CLI

### Build

**Android:**
```bash
cd android
./gradlew assembleDebug                 # build the APK
./gradlew installDebug                   # build + install on a connected device (adb)
```

The APK lands at `android/app/build/outputs/apk/debug/app-debug.apk` — install
it directly with `adb install -r app/build/outputs/apk/debug/app-debug.apk`, or
send that file to the phone and open it (enable "Install unknown apps").

**Mac:**
```bash
./mac/make_app.sh
open mac/build/Bridg.app
```

`swift build` alone produces a bare binary with no bundle identifier, which
macOS refuses to grant Local Network access and which crashes on first use of
the notification centre. `make_app.sh` wraps the build into `Bridg.app`.

**Step-by-step setup, including pairing and permissions:
see [RUNNING.md](RUNNING.md).**

### Protocol

See [docs/PROTOCOL.md](docs/PROTOCOL.md) for the wire protocol specification.

## Development Phases

1. **Phase 1** — Pairing, Transport, File Transfer
2. **Phase 2** — Notifications, Clipboard Sync
3. **Phase 3** — Screen Mirroring + Input Control
4. **Phase 4** — Polish and parity features

## Security

- All communication encrypted with ChaCha20-Poly1305 (via libsodium)
- X25519 key exchange during QR pairing
- Device identity stored in Android EncryptedSharedPreferences / macOS Keychain
- No data leaves your local network

## Support

If you find Bridg useful, you can [buy me a coffee](https://buymeacoffee.com/hardikshreyas).

## License

MIT — see [LICENSE](LICENSE) for details.
