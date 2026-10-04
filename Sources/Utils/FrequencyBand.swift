import Foundation

struct FrequencyBand: Equatable, Sendable {
    let name: String
    let minHz: Float
    let maxHz: Float
    let octaveFraction: Int
    let fftSize: Int
    let description: String

    static let low = FrequencyBand(
        name: "low", minHz: 20, maxHz: 250,
        octaveFraction: 12, fftSize: 16384,
        description: "电源谐波/共振/嗡鸣"
    )

    static let midLow = FrequencyBand(
        name: "midLow", minHz: 20, maxHz: 500,
        octaveFraction: 6, fftSize: 8192,
        description: "风扇/人声基频"
    )

    static let mid = FrequencyBand(
        name: "mid", minHz: 200, maxHz: 2000,
        octaveFraction: 3, fftSize: 4096,
        description: "人声/语音/异响"
    )

    static let high = FrequencyBand(
        name: "high", minHz: 2000, maxHz: 20000,
        octaveFraction: 3, fftSize: 4096,
        description: "啸叫/轴承/电感"
    )

    static let full = FrequencyBand(
        name: "full", minHz: 20, maxHz: 20000,
        octaveFraction: 3, fftSize: 4096,
        description: "通用排查"
    )

    static let all: [FrequencyBand] = [low, midLow, mid, high, full]

    var title: String {
        switch name {
        case "low": return "低频"
        case "midLow": return "中低频"
        case "mid": return "中频"
        case "high": return "高频"
        case "full": return "全频"
        default: return name
        }
    }

    var isLinear: Bool { name == "low" || name == "midLow" }

    static func named(_ name: String) -> FrequencyBand {
        all.first { $0.name == name } ?? .low
    }

    var binWidth: Float {
        48000.0 / Float(fftSize)
    }

    var frequencyResolution: Float {
        binWidth
    }
}
