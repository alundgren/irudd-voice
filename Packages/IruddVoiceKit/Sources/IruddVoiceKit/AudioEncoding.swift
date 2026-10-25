import AVFoundation
import Foundation

/// Audio as stored in the database.
public struct EncodedAudio: Sendable {
    public let data: Data
    /// "flac", or "pcm_f32le" (raw little-endian floats) if FLAC encoding failed.
    public let format: String
    public let sampleRate: Int
}

public enum AudioEncoding {
    /// Speech is stored at 16 kHz: what speech engines use, and a third of
    /// the size of the mic's 48 kHz.
    public static let storedSampleRate = 16_000.0

    /// Resamples to 16 kHz and encodes as a 16-bit FLAC file. If anything
    /// fails, falls back to raw floats so the audio is never lost.
    public static func encode(samples: [Float], sampleRate: Double) -> EncodedAudio {
        do {
            let resampled = try resample(samples, from: sampleRate, to: storedSampleRate)
            return EncodedAudio(data: try flac(resampled, sampleRate: storedSampleRate),
                                format: "flac", sampleRate: Int(storedSampleRate))
        } catch {
            let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
            return EncodedAudio(data: data, format: "pcm_f32le", sampleRate: Int(sampleRate))
        }
    }

    public static func resample(_ samples: [Float], from inputRate: Double, to outputRate: Double) throws -> [Float] {
        if inputRate == outputRate || samples.isEmpty { return samples }
        let inputFormat = AVAudioFormat(standardFormatWithSampleRate: inputRate, channels: 1)!
        let outputFormat = AVAudioFormat(standardFormatWithSampleRate: outputRate, channels: 1)!
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw DatabaseError(message: "Can't convert \(inputRate) Hz to \(outputRate) Hz")
        }
        converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue

        let input = buffer(samples, format: inputFormat)
        let capacity = AVAudioFrameCount(Double(samples.count) * outputRate / inputRate) + 1024
        let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity)!
        nonisolated(unsafe) var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .endOfStream
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }
        if status == .error { throw error ?? DatabaseError(message: "Resampling failed") }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }

    public static func flac(_ samples: [Float], sampleRate: Double) throws -> Data {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("irudd-voice-\(UUID().uuidString).flac")
        defer { try? FileManager.default.removeItem(at: url) }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatFLAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitDepthHintKey: 16,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer(samples, format: file.processingFormat))
        file.close()
        return try Data(contentsOf: url)
    }

    /// Decodes stored audio back to mono floats.
    public static func decode(_ data: Data, format: String, sampleRate: Int) throws -> [Float] {
        if format == "pcm_f32le" {
            return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("irudd-voice-\(UUID().uuidString).flac")
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url)
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let output = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: output)
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }

    static func buffer(_ samples: [Float], format: AVAudioFormat) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(1, samples.count)))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if !samples.isEmpty {
            samples.withUnsafeBufferPointer { source in
                buffer.floatChannelData![0].update(from: source.baseAddress!, count: samples.count)
            }
        }
        return buffer
    }
}
