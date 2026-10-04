import Foundation
import SwiftData

@Model
final class Recording {
    var id: UUID = UUID()
    var timestamp: Date = Date()
    var audioURL: URL?
    var durationMs: Int = 0
    var spectrumURL: URL?
    var isClipped: Bool = false
    var isLowSNR: Bool = false
    var point: MeasurePoint?

    init(timestamp: Date = Date(), audioURL: URL? = nil,
         durationMs: Int = 0, spectrumURL: URL? = nil,
         isClipped: Bool = false, isLowSNR: Bool = false) {
        self.id = UUID()
        self.timestamp = timestamp
        self.audioURL = audioURL
        self.durationMs = durationMs
        self.spectrumURL = spectrumURL
        self.isClipped = isClipped
        self.isLowSNR = isLowSNR
    }

    func loadSpectrum() throws -> SpectrumData {
        guard let url = spectrumURL else { throw RecordingError.missingSpectrum }
        return try SpectrumFiles.read(url)
    }

    var hasValidSpectrum: Bool {
        guard let data = try? loadSpectrum() else { return false }
        return data.isComplete != false
    }

    var resolvedAudioURL: URL? {
        guard let audioURL else { return nil }
        let url = SpectrumFiles.resolve(audioURL)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

struct SpectrumData: Codable, Sendable {
    static let currentAlgorithm = "power-v2"
    var bands: [String: BandSpectrum]
    var averageSpectrum: [Float]
    var sampleRate: Float
    var fftSize: Int
    var binWidth: Float
    var formatVersion: Int? = nil
    var algorithmVersion: String? = nil
    var sampleCount: Int? = nil
    var inputRoute: String? = nil
    var isComplete: Bool? = nil
    var endReason: String? = nil

    struct BandSpectrum: Codable, Sendable {
        var frequencies: [Float]
        var dbValues: [Float]
    }

    var isLegacy: Bool { algorithmVersion != Self.currentAlgorithm }

    var isValid: Bool {
        guard sampleRate.isFinite, sampleRate > 0, fftSize >= 2,
              fftSize.nonzeroBitCount == 1, fftSize <= 262144,
              binWidth.isFinite, binWidth > 0,
              abs(binWidth - sampleRate / Float(fftSize)) < 0.001,
              averageSpectrum.count == fftSize / 2 || averageSpectrum.count == fftSize / 2 + 1,
              averageSpectrum.allSatisfy(\.isFinite) else { return false }
        if let count = sampleCount, count < fftSize { return false }
        return bands.values.allSatisfy {
            $0.frequencies.count == $0.dbValues.count &&
            $0.frequencies.allSatisfy { $0.isFinite && $0 >= 0 } &&
            $0.dbValues.allSatisfy(\.isFinite)
        }
    }

    var isComparable: Bool {
        isValid && !isLegacy && formatVersion == 2 && isComplete == true &&
        (sampleCount ?? 0) >= fftSize && !(inputRoute ?? "").isEmpty
    }

    var compatibilityKey: String {
        "\(algorithmVersion ?? "legacy")|\(sampleRate)|\(fftSize)|\(inputRoute ?? "unknown")"
    }

    var frequencies: [Float] {
        averageSpectrum.indices.map { Float($0) * binWidth }
    }
}

enum RecordingError: LocalizedError {
    case missingSpectrum
    case invalidSpectrum
    case tooShort
    case audioWrite(String)

    var errorDescription: String? {
        switch self {
        case .missingSpectrum: return "找不到频谱文件。"
        case .invalidSpectrum: return "频谱数据为空、损坏或格式不匹配。"
        case .tooShort: return "有效采集时长不足，请重新采集。"
        case .audioWrite(let detail): return "录音保存失败：\(detail)"
        }
    }
}

enum SpectrumFiles {
    static var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static func resolve(_ url: URL) -> URL {
        if FileManager.default.fileExists(atPath: url.path) { return url }
        return directory.appendingPathComponent(url.lastPathComponent)
    }

    static func read(_ url: URL) throws -> SpectrumData {
        let data = try JSONDecoder().decode(SpectrumData.self, from: Data(contentsOf: resolve(url)))
        guard data.isValid else { throw RecordingError.invalidSpectrum }
        return data
    }

    static func write(_ spectrum: SpectrumData, id: UUID) throws -> URL {
        guard spectrum.isValid else { throw RecordingError.invalidSpectrum }
        let url = directory.appendingPathComponent("spectrum_\(id.uuidString).json")
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try read(url)
            return url
        }
        let staging = directory.appendingPathComponent("pending_\(UUID().uuidString).json")
        try JSONEncoder().encode(spectrum).write(to: staging, options: .atomic)
        _ = try read(staging)
        try FileManager.default.moveItem(at: staging, to: url)
        return url
    }
}
