import Foundation
import AVFoundation

final class AudioRecorder {
    static func save(samples: [Float], sampleRate: Double, id: UUID) throws -> URL {
        guard !samples.isEmpty, samples.allSatisfy(\.isFinite),
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: sampleRate, channels: 1, interleaved: false) else {
            throw AudioError.formatMismatch
        }
        let destination = SpectrumFiles.directory.appendingPathComponent("recording_\(id.uuidString).caf")
        if FileManager.default.fileExists(atPath: destination.path) {
            try validate(url: destination, count: samples.count, sampleRate: sampleRate)
            return destination
        }
        let staging = SpectrumFiles.directory.appendingPathComponent("pending_\(UUID().uuidString).caf")
        try write(samples: samples, format: format, to: staging)
        try validate(url: staging, count: samples.count, sampleRate: sampleRate)
        try FileManager.default.moveItem(at: staging, to: destination)
        return destination
    }

    private static func write(samples: [Float], format: AVAudioFormat, to url: URL) throws {
        let file = try AVAudioFile(forWriting: url, settings: format.settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        var offset = 0
        while offset < samples.count {
            let count = min(16384, samples.count - offset)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
                  let output = buffer.floatChannelData?[0] else { throw AudioError.formatMismatch }
            buffer.frameLength = AVAudioFrameCount(count)
            samples.withUnsafeBufferPointer { pointer in
                output.update(from: pointer.baseAddress!.advanced(by: offset), count: count)
            }
            try file.write(from: buffer)
            offset += count
        }
    }

    private static func validate(url: URL, count: Int, sampleRate: Double) throws {
        let file = try AVAudioFile(forReading: url)
        guard file.length == AVAudioFramePosition(count),
              abs(file.processingFormat.sampleRate - sampleRate) < 0.01 else {
            throw AudioError.formatMismatch
        }
    }
}
