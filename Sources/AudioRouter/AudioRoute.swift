import CoreAudio
import Foundation

/// Sends the audio of a set of processes to one output device.
///
/// A process tap captures the processes' audio and mutes their normal output.
/// A private aggregate device combines the tap (as input) with the chosen
/// device (as output), and an IO proc copies one into the other.
final class AudioRoute {
    static let uidPrefix = "net.razumau.AudioRouter."

    struct Key: Equatable {
        let processes: Set<AudioObjectID>
        let deviceUID: String
    }

    let key: Key
    private var tapID = AudioObjectID.unknown
    private var aggregateID = AudioObjectID.unknown
    private var ioProcID: AudioDeviceIOProcID?

    init(_ key: Key, name: String) throws {
        self.key = key
        do {
            try start(name: name)
        } catch {
            stop()
            throw error
        }
    }

    deinit { stop() }

    private func start(name: String) throws {
        let tap = CATapDescription(stereoMixdownOfProcesses: key.processes.sorted())
        tap.name = "Audio Router: \(name)"
        tap.isPrivate = true
        tap.muteBehavior = .mutedWhenTapped
        try check(AudioHardwareCreateProcessTap(tap, &tapID), "Creating the audio tap")

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Audio Router: \(name)",
            kAudioAggregateDeviceUIDKey: Self.uidPrefix + UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: key.deviceUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: key.deviceUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tap.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), "Creating the aggregate device")

        // The tap's streams come after any input streams of the output device itself.
        let format = try tapID.value(kAudioTapPropertyFormat, initial: AudioStreamBasicDescription())
        let tapBuffers = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 ? Int(format.mChannelsPerFrame) : 1

        try check(AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil) { _, input, _, output, _ in
            AudioRoute.render(from: input, to: output, tapBuffers: tapBuffers)
        }, "Creating the IO proc")
        try check(AudioDeviceStart(aggregateID, ioProcID), "Starting playback")
    }

    func stop() {
        if aggregateID != .unknown {
            if let ioProcID {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != .unknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        ioProcID = nil
        aggregateID = .unknown
        tapID = .unknown
    }

    // MARK: - Real-time rendering (no allocations or locks below this line)

    private static func render(from input: UnsafePointer<AudioBufferList>, to output: UnsafeMutablePointer<AudioBufferList>, tapBuffers: Int) {
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outputs = UnsafeMutableAudioBufferListPointer(output)
        let firstTapBuffer = max(0, inputs.count - tapBuffers)

        var outputChannels = 0
        for buffer in outputs { outputChannels += Int(buffer.mNumberChannels) }

        var outputChannel = 0
        for buffer in outputs {
            let stride = Int(buffer.mNumberChannels)
            defer { outputChannel += stride }
            guard let data = buffer.mData, stride > 0 else { continue }
            memset(data, 0, Int(buffer.mDataByteSize))
            let destination = data.assumingMemoryBound(to: Float32.self)
            let frames = Int(buffer.mDataByteSize) / (stride * MemoryLayout<Float32>.size)

            for channel in 0..<stride {
                // A mono device gets the left channel; extra channels stay silent.
                let wanted = outputChannels == 1 ? 0 : outputChannel + channel
                guard let (source, sourceStride, sourceFrames) = Self.channel(wanted, in: inputs, from: firstTapBuffer) else { continue }
                for frame in 0..<min(frames, sourceFrames) {
                    destination[frame * stride + channel] = source[frame * sourceStride]
                }
            }
        }
    }

    /// Finds input channel `index` among the tap's buffers: its first sample, the sample stride and the frame count.
    private static func channel(_ index: Int, in buffers: UnsafeMutableAudioBufferListPointer, from first: Int) -> (UnsafePointer<Float32>, Int, Int)? {
        var remaining = index
        for i in first..<buffers.count {
            let buffer = buffers[i]
            let stride = Int(buffer.mNumberChannels)
            if remaining < stride {
                guard let data = buffer.mData else { return nil }
                let samples = UnsafePointer(data.assumingMemoryBound(to: Float32.self))
                return (samples + remaining, stride, Int(buffer.mDataByteSize) / (stride * MemoryLayout<Float32>.size))
            }
            remaining -= stride
        }
        return nil
    }
}
