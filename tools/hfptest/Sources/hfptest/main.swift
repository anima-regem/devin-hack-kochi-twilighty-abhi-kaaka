// hfptest — can this Mac act as a Bluetooth HFP hands-free unit (car kit) for a phone?
//
// Roles: the Mac is the Hands-Free unit (HF), the phone is the Audio Gateway (AG).
// In IOBluetooth that is IOBluetoothHandsFreeDevice ("act as a hands free device").
// IOBluetoothHandsFreeAudioGateway is the opposite role (Mac = gateway for a headset).
//
// Usage:
//   hfptest list [--sdp]        list paired devices (--sdp: fresh SDP query per device)
//   hfptest connect <address>   connect as HF, then type commands on stdin (type 'help')

import Foundation
import IOBluetooth
import CoreAudio
import AVFoundation

setvbuf(stdout, nil, _IOLBF, 0)

func log(_ s: String) {
    let ts = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withTime, .withColonSeparatorInTime])
    print("[\(ts)] \(s)")
}
func pass(_ what: String) { print("PASS: \(what)") }
func fail(_ what: String, _ why: String) { print("FAIL: \(what) — \(why)") }

// MARK: - Device listing / SDP

func hasHFPGateway(_ d: IOBluetoothDevice) -> Bool {
    d.handsFreeAudioGatewayServiceRecord() != nil
}

func listPaired(refreshSDP: Bool) {
    guard let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice], !devices.isEmpty else {
        print("No paired devices (or Bluetooth permission denied — see README notes in output of 'hfptest').")
        return
    }
    if refreshSDP {
        for d in devices {
            print("SDP query \(d.name ?? "?") (\(d.addressString ?? "?"))…", terminator: "")
            let r = d.performSDPQuery(nil) // async; poll for completion
            let start = Date()
            let before = d.getLastServicesUpdate()
            while Date().timeIntervalSince(start) < 10 && d.getLastServicesUpdate() == before {
                RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            }
            print(r == kIOReturnSuccess ? " done" : " error 0x\(String(UInt32(bitPattern: r), radix: 16))")
        }
    }
    func pad(_ s: String, _ n: Int) -> String { s.padding(toLength: max(n, s.count + 1), withPad: " ", startingAt: 0) }
    print(pad("NAME", 28) + pad("ADDRESS", 19) + pad("CONNECTED", 10) + "HFP AG SERVICE")
    for d in devices {
        print(pad(d.name ?? "?", 28) + pad(d.addressString ?? "?", 19) + pad(d.isConnected() ? "yes" : "no", 10)
              + (hasHFPGateway(d) ? "YES" : "no"))
    }
}

// MARK: - CoreAudio

struct AudioDev { let id: AudioDeviceID; let name: String; let transport: UInt32; let inCh: Int; let outCh: Int }

func caGet<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector,
              _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, _ value: inout T) -> Bool {
    var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<T>.size)
    return AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &value) == noErr
}

func channelCount(_ id: AudioDeviceID, _ scope: AudioObjectPropertyScope) -> Int {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: scope,
                                          mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
    let abl = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
    return abl.reduce(0) { $0 + Int($1.mNumberChannels) }
}

func audioDevices() -> [AudioDev] {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size)
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids)
    return ids.map { id in
        var name: Unmanaged<CFString>? = nil
        _ = caGet(id, kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal, &name)
        var transport: UInt32 = 0
        _ = caGet(id, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal, &transport)
        return AudioDev(id: id, name: (name?.takeRetainedValue() as String?) ?? "?", transport: transport,
                        inCh: channelCount(id, kAudioObjectPropertyScopeInput),
                        outCh: channelCount(id, kAudioObjectPropertyScopeOutput))
    }
}

func isBluetooth(_ d: AudioDev) -> Bool {
    d.transport == kAudioDeviceTransportTypeBluetooth || d.transport == kAudioDeviceTransportTypeBluetoothLE
}

func fourCC(_ v: UInt32) -> String {
    let b = [24, 16, 8, 0].map { UInt8((v >> $0) & 0xff) }
    return b.allSatisfy { $0 >= 32 && $0 < 127 } ? String(bytes: b, encoding: .ascii)! : String(v)
}

@discardableResult
func printAudioDevices() -> [AudioDev] {
    let devs = audioDevices()
    print("CoreAudio devices:")
    for d in devs {
        print("  [\(d.id)] \(d.name)  transport=\(fourCC(d.transport))  in=\(d.inCh) out=\(d.outCh)\(isBluetooth(d) ? "  <-- BLUETOOTH" : "")")
    }
    return devs
}

// MARK: - Recording

final class Recorder {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var peak: Float = 0
    private var frames: AVAudioFramePosition = 0

    func record(device: AudioDev, seconds: Double, to url: URL, done: @escaping (Bool) -> Void) {
        guard let au = engine.inputNode.audioUnit else { fail("Audio recording", "no input audio unit"); return done(false) }
        var id = device.id
        let st = AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                      &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard st == noErr else { fail("Audio recording", "cannot select device \(device.name) (OSStatus \(st))"); return done(false) }
        let fmt = engine.inputNode.inputFormat(forBus: 0)
        log("Recording \(seconds)s from '\(device.name)' format=\(fmt) -> \(url.path)")
        guard fmt.sampleRate > 0, fmt.channelCount > 0 else { fail("Audio recording", "device reports empty format"); return done(false) }
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forWriting: url, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: fmt.sampleRate,
                AVNumberOfChannelsKey: fmt.channelCount, AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            ], commonFormat: fmt.commonFormat, interleaved: fmt.isInterleaved)
        } catch { fail("Audio recording", "cannot create wav: \(error)"); return done(false) }

        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: fmt) { [self] buf, _ in
            try? file.write(from: buf)
            var p: Float = 0
            if let ch = buf.floatChannelData {
                for c in 0..<Int(buf.format.channelCount) {
                    for i in 0..<Int(buf.frameLength) { p = max(p, abs(ch[c][i])) }
                }
            }
            lock.lock(); peak = max(peak, p); frames += AVAudioFramePosition(buf.frameLength); lock.unlock()
        }
        do { try engine.start() } catch { fail("Audio recording", "engine start failed: \(error)"); return done(false) }

        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [self] in
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            lock.lock(); let p = peak, n = frames; lock.unlock()
            let db = p > 0 ? 20 * log10(p) : -Float.infinity
            log(String(format: "Recorded %lld frames, peak %.1f dBFS", n, db))
            done(n > 0 && db > -60)
        }
    }
}

// MARK: - HFP session

final class Session: NSObject, IOBluetoothHandsFreeDeviceDelegate {
    let device: IOBluetoothDevice
    var hf: IOBluetoothHandsFreeDevice!
    var recorder: Recorder?
    var auto = false  // --auto: answer incoming calls and request SCO without typed commands
    var result = ["HFP connection established": false, "Incoming call detected": false,
                  "SCO audio connected": false, "Audio device visible and recording non-silent": false]

    init(device: IOBluetoothDevice) {
        self.device = device
        super.init()
        guard let hf = IOBluetoothHandsFreeDevice(device: device, delegate: self) else {
            fail("HFP connection established", "IOBluetoothHandsFreeDevice init returned nil (API unavailable?)")
            exit(1)
        }
        self.hf = hf
    }

    func start() {
        // Without an open baseband link + fresh SDP, connect() silently does nothing (observed on macOS 27).
        let oc = device.openConnection()
        log("openConnection -> 0x\(String(UInt32(bitPattern: oc), radix: 16)) baseband=\(device.isConnected())")
        device.performSDPQuery(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(5))
        log("Device: \(device.name ?? "?") \(device.addressString ?? "") paired=\(device.isPaired()) connected=\(device.isConnected()) HFP-AG-record=\(hasHFPGateway(device))")
        if !hasHFPGateway(device) { log("WARNING: no cached HFP Audio Gateway SDP record; try 'hfptest list --sdp'") }
        // Local HF features (HFP spec bitmask): EC/NR 0x1, 3-way 0x2, CLI 0x4, voice rec 0x8, remote vol 0x10, enhanced status 0x20
        hf.supportedFeatures = 0x1 | 0x4 | 0x10 | 0x20
        log("Connecting HFP (Mac=HF, phone=AG)…")
        hf.connect()
        DispatchQueue.main.asyncAfter(deadline: .now() + 25) { [self] in
            if !result["HFP connection established"]! {
                fail("HFP connection established", "no successful connected callback within 25s (isConnected=\(hf.isConnected))")
            }
        }
    }

    // ---- IOBluetoothHandsFreeDelegate
    func handsFree(_ device: IOBluetoothHandsFree!, connected status: NSNumber!) {
        log("callback connected status=\(status!)")
        if status.int32Value == kIOReturnSuccess {
            result["HFP connection established"] = true
            pass("HFP connection established")
            log("AG features=0x\(String(hf.deviceSupportedFeatures, radix: 16)) holdModes=0x\(String(hf.deviceCallHoldModes, radix: 16))")
            for k in [IOBluetoothHandsFreeIndicatorService, IOBluetoothHandsFreeIndicatorCall, IOBluetoothHandsFreeIndicatorCallSetup,
                      IOBluetoothHandsFreeIndicatorSignal, IOBluetoothHandsFreeIndicatorBattChg, IOBluetoothHandsFreeIndicatorRoam] {
                log("  indicator \(k) = \(hf.indicator(k))")
            }
        } else {
            fail("HFP connection established", "connected callback status \(status!) (0x\(String(UInt32(bitPattern: status.int32Value), radix: 16)))")
        }
    }
    func handsFree(_ device: IOBluetoothHandsFree!, disconnected status: NSNumber!) { log("callback disconnected status=\(status!)") }

    func handsFree(_ device: IOBluetoothHandsFree!, scoConnectionOpened status: NSNumber!) {
        log("callback scoConnectionOpened status=\(status!)")
        guard status.int32Value == kIOReturnSuccess else {
            fail("SCO audio connected", "scoConnectionOpened status \(status!)"); return
        }
        result["SCO audio connected"] = true
        pass("SCO audio connected")
        // Give coreaudiod a moment to publish any new device.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [self] in checkAudioAndRecord() }
    }
    func handsFree(_ device: IOBluetoothHandsFree!, scoConnectionClosed status: NSNumber!) {
        log("callback scoConnectionClosed status=\(status!)")
    }

    // ---- IOBluetoothHandsFreeDeviceDelegate
    func handsFree(_ device: IOBluetoothHandsFreeDevice!, isServiceAvailable v: NSNumber!) { log("indicator service=\(v!)") }
    func handsFree(_ device: IOBluetoothHandsFreeDevice!, isCallActive v: NSNumber!) { log("indicator callActive=\(v!)") }
    func handsFree(_ device: IOBluetoothHandsFreeDevice!, callSetupMode v: NSNumber!) {
        log("indicator callSetup=\(v!) (0 none, 1 incoming, 2 outgoing, 3 alerting)")
        if v.intValue == 1 { incoming("callsetup=1") }
    }
    func handsFree(_ device: IOBluetoothHandsFreeDevice!, callHoldState v: NSNumber!) { log("indicator callHeld=\(v!)") }
    func handsFree(_ device: IOBluetoothHandsFreeDevice!, signalStrength v: NSNumber!) { log("indicator signal=\(v!)/5") }
    func handsFree(_ device: IOBluetoothHandsFreeDevice!, isRoaming v: NSNumber!) { log("indicator roaming=\(v!)") }
    func handsFree(_ device: IOBluetoothHandsFreeDevice!, batteryCharge v: NSNumber!) { log("indicator battery=\(v!)/5") }
    func handsFree(_ device: IOBluetoothHandsFreeDevice!, incomingCallFrom number: String!) {
        log("incomingCallFrom \(number ?? "<unknown>")"); incoming("CLIP \(number ?? "")")
    }
    func handsFree(_ device: IOBluetoothHandsFreeDevice!, ringAttempt v: NSNumber!) { log("RING attempt=\(v!)"); incoming("RING") }
    func handsFree(_ device: IOBluetoothHandsFreeDevice!, currentCall: [AnyHashable: Any]!) { log("currentCall \(currentCall ?? [:])") }
    func handsFree(_ device: IOBluetoothHandsFreeDevice!, subscriberNumber: String!) { log("subscriberNumber \(subscriberNumber ?? "")") }
    func handsFree(_ device: IOBluetoothHandsFreeDevice!, incomingSMS sms: [AnyHashable: Any]!) { log("incomingSMS \(sms ?? [:])") }
    func handsFree(_ device: IOBluetoothHandsFreeDevice!, unhandledResultCode code: String!) { log("unhandledResultCode \(code ?? "")") }

    func incoming(_ via: String) {
        if !result["Incoming call detected"]! {
            result["Incoming call detected"] = true
            pass("Incoming call detected (\(via)) — type 'answer' to accept")
            if auto {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [self] in
                    log("[auto] acceptCall"); hf.acceptCall()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [self] in
                        if !hf.isSCOConnected() { log("[auto] connectSCO"); hf.connectSCO() }
                    }
                }
            }
        }
    }

    // ---- Audio
    func checkAudioAndRecord() {
        let devs = printAudioDevices()
        let name = (device.name ?? "").lowercased()
        let bt = devs.filter { isBluetooth($0) && $0.inCh > 0 }
        guard let target = bt.first(where: { $0.name.lowercased().contains(name) }) ?? bt.first else {
            fail("Audio device visible and recording non-silent", "no Bluetooth input device in CoreAudio while SCO is up")
            return
        }
        log("Using Bluetooth input device '\(target.name)'")
        let url = URL(fileURLWithPath: "hfp-\(Int(Date().timeIntervalSince1970)).wav")
        recorder = Recorder()
        recorder!.record(device: target, seconds: 10, to: url) { [self] ok in
            if ok {
                result["Audio device visible and recording non-silent"] = true
                pass("Audio device visible and recording non-silent (\(url.path))")
            } else {
                fail("Audio device visible and recording non-silent", "recording silent or empty (\(url.path))")
            }
            recorder = nil
        }
    }

    func summary() {
        print("\n==== SUMMARY ====")
        for k in ["HFP connection established", "Incoming call detected", "SCO audio connected",
                  "Audio device visible and recording non-silent"] {
            print(result[k]! ? "PASS: \(k)" : "FAIL: \(k)")
        }
    }

    func command(_ line: String) {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        switch parts.first ?? "" {
        case "": break
        case "answer", "a": log("acceptCall"); hf.acceptCall()
        case "hangup", "h": log("endCall"); hf.endCall()
        case "sco": log("connectSCO"); hf.connectSCO()
        case "nosco": log("disconnectSCO"); hf.disconnectSCO()
        case "toPC": log("transferAudioToComputer"); hf.transferAudioToComputer()
        case "dial" where parts.count == 2: log("dialNumber \(parts[1])"); hf.dialNumber(parts[1])
        case "at" where parts.count == 2: log("sendATCommand \(parts[1])"); hf.send(atCommand: parts[1])
        case "calls": hf.currentCallList()
        case "devices": printAudioDevices()
        case "rec": checkAudioAndRecord()
        case "status": log("connected=\(hf.isConnected) sco=\(hf.isSCOConnected()) baseband=\(device.isConnected())")
        case "quit", "q": hf.disconnect(); summary(); exit(0)
        default:
            print("""
            commands: answer|a  hangup|h  sco  nosco  toPC (transferAudioToComputer)  dial <num>  at <AT cmd>
                      calls  devices  rec  status  quit|q
            """)
        }
    }
}

// MARK: - main

let args = CommandLine.arguments
switch args.dropFirst().first {
case "list":
    listPaired(refreshSDP: args.contains("--sdp"))
case "connect" where args.count >= 3:
    let addr = args[2].replacingOccurrences(of: ":", with: "-")
    // Prefer the paired-device object (has name/SDP cache); a bare addressString object may not.
    let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
    guard let dev = paired.first(where: { $0.addressString?.lowercased() == addr.lowercased() })
            ?? IOBluetoothDevice(addressString: addr) else { print("Bad address \(args[2])"); exit(2) }
    let session = Session(device: dev)
    session.auto = args.contains("--auto")
    session.start()
    signal(SIGINT, SIG_IGN)
    let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    sigint.setEventHandler { session.command("quit") }
    sigint.resume()
    Thread.detachNewThread {
        while let line = readLine() {
            DispatchQueue.main.async { session.command(line.trimmingCharacters(in: .whitespaces)) }
        }
        DispatchQueue.main.async { session.command("quit") }
    }
    print("Type 'help' for commands. Ctrl-C to quit with summary.")
    RunLoop.main.run()
default:
    print("""
    usage: hfptest list [--sdp]
           hfptest connect <bluetooth-address> [--auto]   e.g. aa-bb-cc-dd-ee-ff
    """)
}
