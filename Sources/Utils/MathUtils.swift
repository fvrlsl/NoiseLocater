import Foundation
import Accelerate

/// 数学工具：dB 转换、距离比计算等
enum MathUtils {

    /// 幅度转 dB
    static func amplitudeToDB(_ amplitude: Float) -> Float {
        20 * log10(max(amplitude, 1e-10))
    }

    /// 功率转 dB
    static func powerToDB(_ power: Float) -> Float {
        10 * log10(max(power, 1e-10))
    }

    /// dB 差转距离比（球面波衰减模型）
    /// dB_diff = 20 * log10(r_j / r_i) => r_i / r_j = 10^(-dB_diff / 20)
    static func distanceRatio(dBDiff: Float) -> Float {
        pow(10, -dBDiff / 20)
    }

    /// 极差
    static func range(_ values: [Float]) -> Float {
        guard let max = values.max(), let min = values.min() else { return 0 }
        return max - min
    }

    /// 标准差
    static func standardDeviation(_ values: [Float]) -> Float {
        guard values.count > 1 else { return 0 }
        let mean = values.reduce(0, +) / Float(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(values.count)
        return sqrt(variance)
    }

    /// 线性插值
    static func interpolate(_ x: Float, in table: [(freq: Float, gain: Float)]) -> Float {
        guard !table.isEmpty else { return 0 }
        if x <= table.first!.freq { return table.first!.gain }
        if x >= table.last!.freq { return table.last!.gain }

        for i in 0..<table.count - 1 {
            let (f0, g0) = table[i]
            let (f1, g1) = table[i + 1]
            if x >= f0 && x <= f1 {
                let t = (x - f0) / (f1 - f0)
                return g0 + t * (g1 - g0)
            }
        }
        return 0
    }
}
