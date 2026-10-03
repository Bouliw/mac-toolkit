// HeadsetGuard
// 1) Keeps the Bluetooth headset's audio stream awake (digital silence) so the start of short sounds
//    (Discord notifications…) is no longer cut off. Released after 5 minutes of inactivity.
// 2) Stops macOS from switching the audio input to the headset's microphone on its own when the
//    headset connects: the input goes back to whatever it was before. Picking the headset's mic by
//    hand still works, and other microphones are left alone.
// Headset: name (or part of it) in HEADSET_NAME; empty = any Bluetooth headset.
import Foundation
import AVFoundation
import CoreAudio
import IOKit

let idleLimit: Double = 300
let autoSwitchWindow: Double = 10
let headsetName = (ProcessInfo.processInfo.environment["HEADSET_NAME"] ?? "").uppercased()

let logFile = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/mac-toolkit/headset-guard.log")
func log(_ message: String) {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    let line = "\(f.string(from: Date())) \(message)\n"
    try? FileManager.default.createDirectory(at: logFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    if let h = try? FileHandle(forWritingTo: logFile) {
        h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
    } else { try? line.write(to: logFile, atomically: true, encoding: .utf8) }
}

let system = AudioObjectID(kAudioObjectSystemObject)
func address(_ s: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: s, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}
func readDevice(_ s: AudioObjectPropertySelector) -> AudioObjectID {
    var a = address(s); var v = AudioObjectID(0); var size = UInt32(MemoryLayout<AudioObjectID>.size)
    return AudioObjectGetPropertyData(system, &a, 0, nil, &size, &v) == noErr ? v : 0
}
func transport(_ d: AudioObjectID) -> UInt32 {
    var a = address(kAudioDevicePropertyTransportType); var t: UInt32 = 0; var size: UInt32 = 4
    return AudioObjectGetPropertyData(d, &a, 0, nil, &size, &t) == noErr ? t : 0
}
func isBluetooth(_ d: AudioObjectID) -> Bool {
    let t = transport(d); return t == kAudioDeviceTransportTypeBluetooth || t == kAudioDeviceTransportTypeBluetoothLE
}
func name(_ d: AudioObjectID) -> String {
    var a = address(kAudioObjectPropertyName); var v: Unmanaged<CFString>? = nil
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(d, &a, 0, nil, &size, &v) == noErr, let r = v else { return "?" }
    return r.takeRetainedValue() as String
}
func isHeadset(_ d: AudioObjectID) -> Bool {
    headsetName.isEmpty ? isBluetooth(d) : name(d).uppercased().contains(headsetName)
}
func devices() -> [AudioObjectID] {
    var a = address(kAudioHardwarePropertyDevices); var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(system, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
    var list = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    AudioObjectGetPropertyData(system, &a, 0, nil, &size, &list); return list
}
func hasInputs(_ d: AudioObjectID) -> Bool {
    var a = address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput); var size: UInt32 = 0
    return AudioObjectGetPropertyDataSize(d, &a, 0, nil, &size) == noErr && size > 0
}
func setInput(_ d: AudioObjectID) {
    var a = address(kAudioHardwarePropertyDefaultInputDevice); var v = d
    AudioObjectSetPropertyData(system, &a, 0, nil, UInt32(MemoryLayout<AudioObjectID>.size), &v)
}
func idleSeconds() -> Double {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
    guard service != 0 else { return 0 }
    defer { IOObjectRelease(service) }
    guard let v = IORegistryEntryCreateCFProperty(service, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)?
        .takeRetainedValue() as? NSNumber else { return 0 }
    return v.doubleValue / 1_000_000_000
}

// ---------- 1) keep the stream awake ----------
final class StreamKeeper {
    var engine: AVAudioEngine?
    func start() {
        guard engine == nil else { return }
        let e = AVAudioEngine()
        let rate = e.outputNode.outputFormat(forBus: 0).sampleRate
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate > 0 ? rate : 44100, channels: 2) else { return }
        let silence = AVAudioSourceNode(format: format) { _, _, _, buffers in
            for b in UnsafeMutableAudioBufferListPointer(buffers) {
                if let p = b.mData { memset(p, 0, Int(b.mDataByteSize)) }
            }
            return noErr
        }
        e.attach(silence)
        e.connect(silence, to: e.mainMixerNode, format: format)
        do { try e.start(); engine = e; log("Bluetooth headset: stream kept awake") }
        catch { log("could not start: \(error)") }
    }
    func stop(_ reason: String) {
        guard let e = engine else { return }
        e.stop(); engine = nil
        log("stream released (\(reason))")
    }
}

// ---------- 2) microphone input ----------
var known = Set(devices())
var appearedAt: [AudioObjectID: Date] = [:]
var lastInput: AudioObjectID = 0

func fallbackInput() -> AudioObjectID {
    let list = devices()
    if lastInput != 0, list.contains(lastInput), hasInputs(lastInput) { return lastInput }
    return list.first { transport($0) == kAudioDeviceTransportTypeBuiltIn && hasInputs($0) } ?? 0
}

func checkInput(atLaunch: Bool = false) {
    let current = readDevice(kAudioHardwarePropertyDefaultInputDevice)
    guard current != 0 else { return }
    if !isHeadset(current) { lastInput = current; return }
    if !known.contains(current) && appearedAt[current] == nil { appearedAt[current] = Date() }
    let recent = Date().timeIntervalSince(appearedAt[current] ?? .distantPast) < autoSwitchWindow
    if atLaunch || recent {
        let target = fallbackInput()
        guard target != 0, target != current else { return }
        setInput(target)
        appearedAt[current] = nil
        log("mic: macOS picked \"\(name(current))\" on its own, back to \"\(name(target))\"")
    }
}

var devicesAddress = address(kAudioHardwarePropertyDevices)
AudioObjectAddPropertyListenerBlock(system, &devicesAddress, DispatchQueue.main) { _, _ in
    let now = Set(devices())
    for d in now.subtracting(known) where isHeadset(d) { appearedAt[d] = Date() }
    known = now
    checkInput()
}
var inputAddress = address(kAudioHardwarePropertyDefaultInputDevice)
AudioObjectAddPropertyListenerBlock(system, &inputAddress, DispatchQueue.main) { _, _ in checkInput() }

// ---------- main loop ----------
let keeper = StreamKeeper()
NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { _ in
    keeper.stop("audio output changed")
}
let outputIsBluetooth = { isBluetooth(readDevice(kAudioHardwarePropertyDefaultOutputDevice)) }

checkInput(atLaunch: true)
Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
    if !outputIsBluetooth() { keeper.stop("output is not Bluetooth") }
    else if idleSeconds() > idleLimit { keeper.stop("Mac idle") }
    else { keeper.start() }
}
RunLoop.main.run()
