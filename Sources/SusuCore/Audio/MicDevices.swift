#if os(macOS)
import AVFoundation
import CoreAudio
import Foundation
import IOKit

/// CoreAudio input-device lookup and selection (macOS only).
enum MicDevices {
    struct Entry { var id: AudioDeviceID; var device: MicInputDevice }

    static func all() -> [MicInputDevice] { entries().map(\.device) }

    static func entries() -> [Entry] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr
        else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids.compactMap { id in
            guard inputChannelCount(id) > 0, let uid = stringProperty(id, kAudioDevicePropertyDeviceUID)
            else { return nil }
            let name = stringProperty(id, kAudioObjectPropertyName) ?? uid
            return Entry(id: id, device: MicInputDevice(uid: uid, name: name, isBuiltIn: transportType(id) == kAudioDeviceTransportTypeBuiltIn))
        }
    }

    /// Pure choice logic (tested): first priority entry that is present, matched by UID or by name
    /// (case-insensitive, substring). Built-in devices are skipped while the lid is closed.
    /// With no match: the default device unless it must be skipped, then the first external one.
    static func pick(priority: [String], available: [MicInputDevice], defaultUID: String?, lidClosed: Bool) -> MicInputDevice? {
        let usable = available.filter { !(lidClosed && $0.isBuiltIn) }
        for p in priority {
            let q = p.lowercased()
            if let d = usable.first(where: { $0.uid == p }) ?? usable.first(where: { $0.name.lowercased().contains(q) }) {
                return d
            }
        }
        if let u = defaultUID, let d = usable.first(where: { $0.uid == u }) { return d }
        return usable.first
    }

    /// Points the engine's input at the chosen device. No match -> leaves the system default.
    static func select(priority: [String], on engine: AVAudioEngine) {
        let list = entries()
        let defaultUID = defaultInputID().flatMap { id in list.first(where: { $0.id == id })?.device.uid }
        guard let chosen = pick(priority: priority, available: list.map(\.device),
                                defaultUID: defaultUID, lidClosed: isLidClosed()),
              let entry = list.first(where: { $0.device.uid == chosen.uid }),
              let unit = engine.inputNode.audioUnit
        else { return }
        var id = entry.id
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                             &id, UInt32(MemoryLayout<AudioDeviceID>.size))
    }

    /// Clamshell state from IOPMrootDomain; false on desktops (no such key).
    static func isLidClosed() -> Bool {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard svc != 0 else { return false }
        defer { IOObjectRelease(svc) }
        let v = IORegistryEntryCreateCFProperty(svc, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)
        return (v?.takeRetainedValue() as? Bool) ?? false
    }

    private static func defaultInputID() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr, id != 0
        else { return nil }
        return id
    }

    private static func inputChannelCount(_ id: AudioDeviceID) -> Int {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func transportType(_ id: AudioDeviceID) -> UInt32 {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var t: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &t)
        return t
    }

    private static func stringProperty(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var cf: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &cf) == noErr, let cf else { return nil }
        return cf.takeRetainedValue() as String
    }
}
#endif
