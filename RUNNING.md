# Running Bridg

Written for someone who has never built a Mac or Android app. Run every command
from the `Bridg` folder (`cd ~/Downloads/Bridg`).

## 0. One-time setup

**Mac side** needs the Xcode command line tools:

```bash
xcode-select --install     # skip if it says they are already installed
swift --version            # should print a version, not an error
```

**Android side** needs a Java runtime and the Android SDK. You already have both
(`android/local.properties` points at `~/Library/Android/sdk`). Check with:

```bash
java -version
adb version
```

If `adb` is missing, install Android Studio once and it comes with it.

## 1. Build and start the Mac app

```bash
./mac/make_app.sh
open mac/build/Bridg.app
```

Bridg is a **menu bar app** — it has no Dock icon. Look for the phone-with-waves
icon in the top-right of your screen.

macOS will ask for two permissions. Both are required:

- **Local Network** — without it the phone can never find the Mac.
- **Notifications** — without it phone notifications cannot appear.

If you dismissed either prompt by accident:
System Settings → Privacy & Security → Local Network / Notifications → enable Bridg.

Check it is actually listening:

```bash
lsof -nP -iTCP:18920 -sTCP:LISTEN     # should show one "Bridg" line
```

## 2. Build and install the Android app

Plug the phone into the Mac with a USB cable. On the phone, enable **Developer
options** (Settings → About phone → tap "Build number" seven times), then turn on
**USB debugging** inside Developer options. Accept the "Allow USB debugging?"
prompt that appears on the phone.

```bash
adb devices        # your phone must be listed as "device", not "unauthorized"
cd android
./gradlew installDebug
cd ..
```

The first build downloads dependencies and takes a few minutes. Later builds
take seconds.

## 3. Pair the two

**The Mac and the phone must be on the same Wi-Fi network**, and not on mobile
data.

They do not have to be on the same subnet. The QR code carries the Mac's
address, and the phone remembers it, so pairing and reconnecting still work on
segmented networks (campus, office, guest Wi-Fi) where Bonjour discovery cannot
see across subnets. Verified working on exactly such a network, with the Mac on
10.7.12.x and the phone on 10.7.7.x.

1. On the Mac, click the Bridg menu bar icon and open the main window. If
   nothing is paired yet, the QR code is already on screen — there is no button
   to hunt for.
2. On the phone, open **Bridg** → tap **Pair New Device** → point the camera at
   the Mac's QR code.
3. The phone's status line changes to "Connected to Mac".

Pairing is one-time. After that the phone finds the Mac and reconnects on its
own whenever both are on the network.

## 4. Grant the phone's permissions

To forward notifications, Android requires a permission that can only be granted
by hand:

- Phone → Settings → **Notifications** → **Device & app notifications**
  (sometimes "Notification access") → enable **Bridg**.

The app prompts you for this on launch; "Open Settings" takes you there.

## What works today

| Feature | State |
|---|---|
| Pairing over QR, encrypted link, auto-reconnect | Working |
| Phone notifications on the Mac, including replies | Working |
| File transfer, both directions | Working |
| Clipboard: Mac → phone | Working |
| Clipboard: phone → Mac | Limited by Android, see below |
| Auto-reconnect after either app restarts | Working |
| Screen mirroring | Not wired up |
| Controlling the phone from the Mac | Not wired up |
| Phone camera as a Mac webcam | Not implemented |

Android 10 and later block apps from reading the clipboard unless they are in
the foreground. Phone → Mac clipboard sync therefore only fires while the Bridg
app is open on screen. This is a platform restriction, not a bug in Bridg.

## Rebuilding after a change

```bash
./mac/make_app.sh && open mac/build/Bridg.app     # Mac
(cd android && ./gradlew installDebug)            # Android
```

## Running the tests

```bash
swift test --package-path mac                     # Mac
(cd android && ./gradlew testDebugUnitTest)       # Android
```

Both sides contain a test that pins the session-key derivation to the same
vector. If those two ever disagree, the phone and Mac silently fail to decrypt
each other, so run them after touching anything under `pairing/` or `transport/`.

The Mac tests use a throwaway Keychain entry. Never point them at the real
`com.bridg` item: regenerating it changes the Mac's identity and unpairs every
device, with the only symptom being "decryption failed" on the phone.

## When it does not connect

```bash
# Is the Mac advertising itself on the network?
dns-sd -B _bridg._tcp local        # should list "Bridg-<your mac name>"; Ctrl-C to stop

# What does the phone think is happening?
adb logcat -s BridgService BridgSocket ServiceDiscovery PairingManager
```

Common causes, in order of likelihood:

1. Phone and Mac on different networks, or the phone is on mobile data.
2. Local Network permission not granted to Bridg on the Mac.
3. A VPN on either device routing local traffic away.
4. The Mac's identity was reset (its Keychain entry was deleted, or something
   regenerated it). The phone then logs "Decryption failed — wrong key". Unpair
   on the Mac and scan the QR again.
