// Phase 0 spike for docs/HANDSFREE_PLAN.md — can the Mac be a Bluetooth
// hands-free unit for an Android phone on this macOS? Throwaway, not part of
// the app target.
//
//   swiftc -o /tmp/hfp spikes/hfp/main.swift
//   /tmp/hfp                   list paired devices
//   /tmp/hfp <name> [--auto]   connect to the device whose name contains <name>
//
// Commands once connected (type + Enter):
//   a answer   e end   m audio→Mac   p audio→phone   s open SCO
//   d <number> dial    l call list   q quit
// --auto answers incoming calls and pulls the audio to the Mac by itself.

import Foundation
import IOBluetooth

func log(_ s: String) {
    let t = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withTime, .withColonSeparatorInTime])
    print("[\(t)] \(s)")
    fflush(stdout)
}

final class Spike: NSObject, IOBluetoothHandsFreeDeviceDelegate {
    let hf: IOBluetoothHandsFreeDevice
    let auto: Bool

    init(device: IOBluetoothDevice, auto: Bool) {
        self.auto = auto
        hf = IOBluetoothHandsFreeDevice(device: device, delegate: nil)
        super.init()
        hf.delegate = self
    }

    func handsFree(_ device: IOBluetoothHandsFree!, connected status: NSNumber!) {
        log("HFP connected, status \(status!) (0 = ok)")
    }
    func handsFree(_ device: IOBluetoothHandsFree!, disconnected status: NSNumber!) {
        log("HFP disconnected, status \(status!)")
    }
    func handsFree(_ device: IOBluetoothHandsFree!, scoConnectionOpened status: NSNumber!) {
        log("SCO audio OPENED, status \(status!) — talk now; audio devices:")
        dumpAudioDevices()
    }
    func handsFree(_ device: IOBluetoothHandsFree!, scoConnectionClosed status: NSNumber!) {
        log("SCO audio closed, status \(status!)")
    }
    func handsFree(_ device: IOBluetoothHandsFreeDevice!, isServiceAvailable v: NSNumber!) { log("service available: \(v!)") }
    func handsFree(_ device: IOBluetoothHandsFreeDevice!, isCallActive v: NSNumber!) {
        log("call active: \(v!)")
        if auto, v.boolValue { hf.transferAudioToComputer() }
    }
    func handsFree(_ device: IOBluetoothHandsFreeDevice!, callSetupMode v: NSNumber!) {
        log("call setup: \(v!) (0 none, 1 incoming, 2 outgoing, 3 alerting)")
    }
    func handsFree(_ device: IOBluetoothHandsFreeDevice!, incomingCallFrom number: String!) {
        log("incoming call from \(number ?? "?")")
    }
    func handsFree(_ device: IOBluetoothHandsFreeDevice!, ringAttempt v: NSNumber!) {
        log("RING")
        if auto { hf.acceptCall() }
    }
    func handsFree(_ device: IOBluetoothHandsFreeDevice!, currentCall call: [AnyHashable: Any]!) { log("current call: \(call ?? [:])") }
    func handsFree(_ device: IOBluetoothHandsFreeDevice!, signalStrength v: NSNumber!) { log("signal: \(v!)") }
    func handsFree(_ device: IOBluetoothHandsFreeDevice!, batteryCharge v: NSNumber!) { log("battery: \(v!)") }
    func handsFree(_ device: IOBluetoothHandsFreeDevice!, unhandledResultCode code: String!) { log("unhandled AT result: \(code ?? "")") }

    func run(_ line: String) {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        switch parts.first {
        case "a": hf.acceptCall()
        case "e": hf.endCall()
        case "m": hf.transferAudioToComputer()
        case "p": hf.transferAudioToPhone()
        case "s": hf.connectSCO()
        case "d" where parts.count == 2: hf.dialNumber(parts[1])
        case "l": hf.currentCallList()
        case "q": hf.disconnect(); exit(0)
        default: log("?  a e m p s d<num> l q")
        }
        log("sent '\(line)' — connected: \(hf.isConnected), SCO: \(hf.isSCOConnected())")
    }
}

// ponytail: shelling out beats 40 lines of CoreAudio property queries for a spike.
func dumpAudioDevices() {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
    p.arguments = ["SPAudioDataType"]
    try? p.run()
    p.waitUntilExit()
}

let args = CommandLine.arguments.dropFirst()
let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []

guard let query = args.first(where: { !$0.hasPrefix("--") }) else {
    log("Bluetooth power: \(IOBluetoothHostController.default()?.powerState.rawValue ?? 0)")
    log("paired devices (\(paired.count)):")
    for d in paired {
        print("  \(d.name ?? "?")  \(d.addressString ?? "")  connected: \(d.isConnected())  HFP gateway: \(d.handsFreeAudioGatewayServiceRecord() != nil)")
    }
    exit(0)
}

guard let device = paired.first(where: { ($0.name ?? "").localizedCaseInsensitiveContains(query) }) else {
    log("no paired device matching '\(query)' — pair the phone in System Settings → Bluetooth first")
    exit(1)
}

log("HFP gateway record on \(device.name ?? "?"): \(device.handsFreeAudioGatewayServiceRecord() != nil)")
let spike = Spike(device: device, auto: args.contains("--auto"))
spike.hf.connect()
log("connecting… call the phone from another number")

Thread.detachNewThread {
    while let line = readLine() {
        DispatchQueue.main.async { spike.run(line.trimmingCharacters(in: .whitespaces)) }
    }
}
RunLoop.main.run()
