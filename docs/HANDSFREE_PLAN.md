# Plan: talk on phone calls through the Mac (Bluetooth Hands-Free)

## Why this route

Bridg already answers and ends calls over Wi-Fi (`CallControl` →
`TelecomManager` in `BridgService.handleCallControl`). It cannot carry the
voice: Android excludes call audio from `AudioPlaybackCapture`, capturing it
needs the system-only `CAPTURE_AUDIO_OUTPUT`, and no app can inject audio into
the call uplink. That is an OS wall, not a Bridg bug.

Bluetooth Hands-Free Profile (HFP) goes around the wall instead of through it.
Every Android phone is already an HFP *Audio Gateway* — it is how car kits and
headsets get call audio. If the Mac plays the other role, *Hands-Free unit*,
the phone itself sends the call audio to the Mac over Bluetooth SCO and takes
the Mac's mic back. No Android permission is involved, and no phone-side code.

macOS still ships that role: `IOBluetoothHandsFreeDevice` is present in the
macOS 26.5 SDK, not deprecated (only the unused `*DriverID` helpers are). It
has `acceptCall`, `endCall`, `dialNumber:`, `transferAudioToComputer`,
`transferAudioToPhone`, `connectSCO`, and delegate callbacks for
`incomingCallFrom:`, `callSetupMode:`, `isCallActive:`,
`scoConnectionOpened:`. Phone Amego used this API years ago.

**The open question** is whether modern `bluetoothd` still honours it — that
the SDP record is advertised, the phone connects HFP to a Mac, and SCO audio
appears as a Core Audio device. Headers existing does not prove the daemon
works. So Phase 0 is a throwaway spike with a hard go/no-go before any product
code is written.

## Phase 0 — Spike (go/no-go, ~1 hour)

Standalone Swift script, not in the app target (`spikes/hfp/main.swift`):

1. Pair the phone with the Mac in System Settings → Bluetooth. On the phone,
   open the Mac's Bluetooth entry and make sure **Phone calls** is enabled.
2. Script finds the paired `IOBluetoothDevice` by name, creates
   `IOBluetoothHandsFreeDevice(device:delegate:)`, calls `connect()`, and logs
   every delegate callback.
3. Call the phone from another number. Expect `incomingCallFrom:` and
   `ringAttempt:`. Call `acceptCall()`.
4. Expect `scoConnectionOpened:`. Check `system_profiler SPAudioDataType` (or
   Audio MIDI Setup) for a new Bluetooth input/output device.
5. Talk. Confirm both directions are audible.

**Go** if steps 3–5 all work: callbacks arrive, SCO opens, both sides hear
each other. **No-go** if HFP never connects, SCO never opens, or there is no
audio device — stop here and document the result in README; the fallbacks are
multipoint earbuds or the aux-cable route, neither needs code.

Record in the PR: macOS version, Mac model, phone model / Android version,
call quality (narrowband CVSD vs wideband mSBC), latency by ear.

## Phase 1 — `HandsFreeManager` (Mac only)

New file `mac/Sources/Bridg/Calls/HandsFreeManager.swift`, one class:

- Owns one `IOBluetoothHandsFreeDevice`, conforms to
  `IOBluetoothHandsFreeDeviceDelegate`.
- Published state: `disconnected / connected / ringing(number) / active /
  audioOnMac`. Mapping from HFP indicators (`callSetupMode`, `isCallActive`,
  `scoConnectionOpened/Closed`) lives in one pure `static func` so it is
  unit-testable without Bluetooth.
- Remembers the chosen device's address in `UserDefaults`; reconnects on
  launch and on `disconnected:`.
- Methods: `answer()`, `end()`, `takeAudio()` (`transferAudioToComputer`),
  `giveAudioBack()` (`transferAudioToPhone`), `dial(_:)`.

`mac/make_app.sh` Info.plist gains `NSBluetoothAlwaysUsageDescription` (and
`NSMicrophoneUsageDescription` if the spike shows the app must open the SCO
input itself rather than the system routing it).

No proto change: HFP is a separate link, the Wi-Fi protocol stays as it is.

## Phase 2 — Wire into the existing call UI

- `AppState.sendCallControl`: for `.answer / .reject / .end`, if
  `HandsFreeManager` is connected, use HFP; otherwise fall back to today's
  `CallControl` envelope. Answering over HFP routes the audio to the Mac by
  itself.
- Call row in `ContentView` and the notification actions: add
  **Use Mac audio / Use phone audio** while a call is active.
- Menu bar: small "Calls via Bluetooth: <phone name> ✓ / not connected" line,
  with a device picker listing paired devices.
- `MUTE / UNMUTE` stay on the existing Wi-Fi `CallControl` path (it mutes the
  phone mic; with audio on the Mac, also mute the Mac input).

## Phase 3 — Audio routing polish (only if the spike needs it)

If SCO shows up as a Core Audio device but macOS does not switch to it, set
it as default input/output (`kAudioHardwarePropertyDefaultInputDevice` /
`…OutputDevice`) when `scoConnectionOpened` fires and restore the previous
defaults on `scoConnectionClosed`. Stop mirror-audio playback
(`AudioPlayer.stop()`) during a call so the two don't overlap.

## Tests

- XCTest for the pure HFP-state → call-state mapping and for the
  "HFP if connected, else Wi-Fi" routing decision in `AppState`.
- Manual checklist on a real phone: incoming answer from Mac, reject,
  end from Mac, end from far side, transfer audio both ways, Bluetooth off
  mid-call (audio must fall back to phone, not drop the call), reconnect after
  Mac sleep.

## Risks

| Risk | Effect | Mitigation |
|---|---|---|
| `bluetoothd` no longer supports the HF role | Whole feature dead | Phase 0 go/no-go before any product code |
| Phone prefers earbuds already connected | Audio goes to buds, not Mac | Document; `transferAudioToComputer` may pull it back |
| Narrowband 8 kHz audio | Sounds like a phone line | Acceptable; note mSBC if negotiated |
| Mac on 2.4 GHz Wi-Fi + Bluetooth SCO | Choppy audio / mirror lag | Recommend 5 GHz; pause mirror during call |
| Notarised hardened runtime blocks Bluetooth/mic | Works in debug, fails in release | Test the DMG from `make_dmg.sh`, not only `swift run` |

## Out of scope

Android changes, VoIP apps (WhatsApp etc. — they use their own desktop apps),
SMS over HFP, conference/hold management.
