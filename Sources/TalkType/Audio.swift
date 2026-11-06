import AVFoundation
import CoreAudio
import Foundation
import TalkTypeCore

struct Microphone: Identifiable, Hashable {
    let id: String
    let name: String
    let device: AudioDeviceID

    static func all() -> [Microphone] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else {
            return []
        }

        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &devices) == noErr else {
            return []
        }

        return devices.compactMap { device in
            guard hasInput(device), let uid = text(of: device, kAudioDevicePropertyDeviceUID), let name = text(of: device, kAudioObjectPropertyName) else {
                return nil
            }

            return Microphone(id: uid, name: name, device: device)
        }
    }

    private static func hasInput(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func text(of device: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }

        return value?.takeRetainedValue() as String?
    }
}

enum AudioError: Error {
    case noFormat
}

/// Produces 16 kHz mono samples while it runs, which is what Whisper takes.
final class MicRecorder {
    // Keeps recording briefly after the stop, because people let go on their last word.
    private static let tail: UInt64 = 150_000_000

    private let engine = AVAudioEngine()

    func start(microphone: String?, onSamples: @escaping ([Float]) -> Void) throws {
        let input = engine.inputNode
        if let microphone, let chosen = Microphone.all().first(where: { $0.id == microphone }), let unit = input.audioUnit {
            var device = chosen.device
            let status = AudioUnitSetProperty(
                unit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &device,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )

            if status != noErr {
                Log.write("Chosen microphone could not be set, using the default.")
            }
        }

        let format = input.outputFormat(forBus: 0)
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(SpeechAudio.sampleRate), channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: format, to: target) else {
            throw AudioError.noFormat
        }

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            let samples = Convert.samples(from: buffer, with: converter, into: target)
            if !samples.isEmpty {
                onSamples(samples)
            }
        }

        engine.prepare()
        try engine.start()
    }

    func stop() async {
        try? await Task.sleep(nanoseconds: MicRecorder.tail)
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}

enum Convert {
    static func samples(from buffer: AVAudioPCMBuffer, with converter: AVAudioConverter, into target: AVAudioFormat) -> [Float] {
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            return []
        }

        var fed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }

            fed = true
            status.pointee = .haveData
            return buffer
        }

        guard error == nil, let channel = output.floatChannelData?[0] else {
            return []
        }

        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }

    /// Reads a sound file as 16 kHz mono samples.
    static func samples(ofFile path: String) throws -> [Float] {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(SpeechAudio.sampleRate), channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: file.processingFormat, to: target),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw AudioError.noFormat
        }

        try file.read(into: buffer)
        return samples(from: buffer, with: converter, into: target)
    }
}
