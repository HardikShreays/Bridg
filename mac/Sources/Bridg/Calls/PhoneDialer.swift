import Foundation
import IOBluetooth

/// Click-to-call: the phone places a call when the Mac asks over Bluetooth
/// Hands-Free (HFP) — the same link a car kit dials through.
///
/// Independent of Bridg's Wi-Fi connection; the phone only has to be paired
/// with the Mac in System Settings → Bluetooth. The conversation itself stays on
/// the phone or its earbuds: macOS refuses to carry call audio as a hands-free
/// unit (see docs/HANDSFREE_PLAN.md).
///
/// The HFP link is held only long enough to dial. Android sends call audio to
/// the most recently connected hands-free device, so a lingering link would pull
/// calls away from the user's earbuds to a Mac that cannot play them.
///
/// IOBluetooth delivers delegate callbacks on the main run loop; call from main.
final class PhoneDialer: NSObject, IOBluetoothHandsFreeDeviceDelegate {
    var onStatus: ((String) -> Void)?

    private var link: IOBluetoothHandsFreeDevice?
    private var pendingNumber: String?
    private var timeout: DispatchWorkItem?

    func dial(_ raw: String) {
        let number = Self.dialable(raw)
        guard !number.isEmpty else { return }
        guard let phone = Self.pairedPhone() else {
            onStatus?("Pair your phone with this Mac in System Settings → Bluetooth")
            return
        }

        finish(nil)
        pendingNumber = number
        let link: IOBluetoothHandsFreeDevice? = IOBluetoothHandsFreeDevice(device: phone, delegate: self)
        self.link = link
        onStatus?("Calling \(number)…")

        // With the phone already linked to the Mac, connect() silently does
        // nothing — no RFCOMM open, no callback. Drop the link, then connect.
        if phone.isConnected() {
            phone.closeConnection()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak link] in link?.connect() }
        } else {
            link?.connect()
        }

        let timeout = DispatchWorkItem { [weak self] in
            self?.finish("Couldn't reach \(phone.name ?? "your phone") over Bluetooth")
        }
        self.timeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: timeout)
    }

    // MARK: - IOBluetoothHandsFreeDeviceDelegate
    //
    // Every callback checks `device === link`: a superseded link still reports
    // its own disconnect, which must not end the dial that replaced it.

    func handsFree(_ device: IOBluetoothHandsFree!, connected status: NSNumber!) {
        guard device === link, let number = pendingNumber else { return }
        guard status.intValue == 0 else {
            return finish("Bluetooth connection to your phone failed (\(status.intValue))")
        }
        link?.dialNumber(number)
    }

    func handsFree(_ device: IOBluetoothHandsFreeDevice!, callSetupMode mode: NSNumber!) {
        // 2 = dialling, 3 = ringing at the other end: the phone has the call.
        guard device === link, let number = pendingNumber, mode.intValue >= 2 else { return }
        finish("Calling \(number) on your phone")
    }

    func handsFree(_ device: IOBluetoothHandsFreeDevice!, unhandledResultCode code: String!) {
        guard device === link, pendingNumber != nil, code?.contains("ERROR") == true else { return }
        finish("Your phone refused to dial")
    }

    func handsFree(_ device: IOBluetoothHandsFree!, disconnected status: NSNumber!) {
        guard device === link, pendingNumber != nil else { return }
        finish("Bluetooth connection to your phone dropped")
    }

    /// End the current attempt and let the link go. A nil status ends it silently.
    private func finish(_ status: String?) {
        timeout?.cancel()
        timeout = nil
        pendingNumber = nil
        link?.disconnect()
        if let status { onStatus?(status) }
    }

    // MARK: - Helpers

    /// Keep only what a dialler accepts. The number reaches the phone as an
    /// `ATD` command, so anything else — a `;`, a line break — could append a
    /// second AT command to it.
    static func dialable(_ raw: String) -> String {
        String(raw.filter { $0.isASCII && ($0.isNumber || "+*#".contains($0)) })
    }

    /// First paired phone offering the HFP audio-gateway service. Other Macs
    /// advertise that service too, hence the device-class check.
    ///
    /// ponytail: first match wins; add a picker if someone pairs two phones.
    private static func pairedPhone() -> IOBluetoothDevice? {
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        return paired.first {
            $0.deviceClassMajor == BluetoothDeviceClassMajor(kBluetoothDeviceClassMajorPhone)
                && $0.handsFreeAudioGatewayServiceRecord() != nil
        }
    }
}
