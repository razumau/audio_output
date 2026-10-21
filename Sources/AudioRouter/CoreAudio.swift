import CoreAudio
import Foundation

struct CoreAudioError: LocalizedError {
    let operation: String
    let status: OSStatus

    var errorDescription: String? { "\(operation) failed (\(UInt32(bitPattern: status).fourCC))" }
}

func check(_ status: OSStatus, _ operation: @autoclosure () -> String) throws {
    guard status == noErr else { throw CoreAudioError(operation: operation(), status: status) }
}

extension UInt32 {
    /// Core Audio codes are usually four ASCII characters packed into an integer.
    var fourCC: String {
        let bytes = [24, 16, 8, 0].map { UInt8((self >> $0) & 0xFF) }
        guard bytes.allSatisfy({ (0x20...0x7E).contains($0) }) else { return String(Int32(bitPattern: self)) }
        return "'" + String(decoding: bytes, as: UTF8.self) + "'"
    }
}

extension AudioObjectID {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static let unknown = AudioObjectID(kAudioObjectUnknown)

    private func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    func value<T: BitwiseCopyable>(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, initial: T) throws -> T {
        var address = address(selector, scope)
        var size = UInt32(MemoryLayout<T>.size)
        var value = initial
        try check(AudioObjectGetPropertyData(self, &address, 0, nil, &size, &value), "Reading \(selector.fourCC)")
        return value
    }

    func string(_ selector: AudioObjectPropertySelector) throws -> String {
        var address = address(selector, kAudioObjectPropertyScopeGlobal)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        try check(AudioObjectGetPropertyData(self, &address, 0, nil, &size, &value), "Reading \(selector.fourCC)")
        return value?.takeRetainedValue() as String? ?? ""
    }

    func objectIDs(_ selector: AudioObjectPropertySelector) throws -> [AudioObjectID] {
        var address = address(selector, kAudioObjectPropertyScopeGlobal)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(self, &address, 0, nil, &size), "Sizing \(selector.fourCC)")
        var ids = [AudioObjectID](repeating: .unknown, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        try check(AudioObjectGetPropertyData(self, &address, 0, nil, &size, &ids), "Reading \(selector.fourCC)")
        return ids
    }

    /// Total number of channels a device has in the given scope (input or output).
    func channelCount(scope: AudioObjectPropertyScope) -> Int {
        var address = address(kAudioDevicePropertyStreamConfiguration, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(self, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(self, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let buffers = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}

struct OutputDevice: Identifiable, Hashable {
    let id: String  // the device UID, stable across reconnects
    let name: String
}

struct AudioProcess {
    let objectID: AudioObjectID
    let pid: pid_t
    let isPlaying: Bool
}

enum AudioSystem {
    static func outputDevices() -> [OutputDevice] {
        let ids = (try? AudioObjectID.system.objectIDs(kAudioHardwarePropertyDevices)) ?? []
        return ids.compactMap { id in
            guard let uid = try? id.string(kAudioDevicePropertyDeviceUID),
                  !uid.hasPrefix(AudioRoute.uidPrefix),
                  id.channelCount(scope: kAudioObjectPropertyScopeOutput) > 0
            else { return nil }
            return OutputDevice(id: uid, name: (try? id.string(kAudioObjectPropertyName)) ?? uid)
        }
    }

    static func defaultOutputDeviceUID() -> String? {
        guard let id = try? AudioObjectID.system.value(kAudioHardwarePropertyDefaultOutputDevice, initial: AudioObjectID.unknown),
              id != .unknown
        else { return nil }
        return try? id.string(kAudioDevicePropertyDeviceUID)
    }

    /// Every process that currently has an audio connection open.
    static func processes() -> [AudioProcess] {
        let ids = (try? AudioObjectID.system.objectIDs(kAudioHardwarePropertyProcessObjectList)) ?? []
        return ids.compactMap { id in
            guard let pid = try? id.value(kAudioProcessPropertyPID, initial: pid_t(-1)), pid > 0 else { return nil }
            let running = (try? id.value(kAudioProcessPropertyIsRunningOutput, initial: UInt32(0))) ?? 0
            return AudioProcess(objectID: id, pid: pid, isPlaying: running != 0)
        }
    }

    /// Calls `handler` on the main queue whenever a property of the system object changes.
    static func observe(_ selector: AudioObjectPropertySelector, handler: @escaping () -> Void) {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(.system, &address, .main) { _, _ in handler() }
    }
}
