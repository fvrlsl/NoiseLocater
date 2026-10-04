import Foundation

enum OctaveBands {

    /// 1/3 倍频程中心频率
    static let thirdOctaveCenterFreqs: [Float] = [
        20, 25, 31.5, 40, 50, 63, 80, 100, 125, 160,
        200, 250, 315, 400, 500, 630, 800, 1000, 1250, 1600,
        2000, 2500, 3150, 4000, 5000, 6300, 8000, 10000, 12500, 16000, 20000
    ]

    /// 1/6 倍频程中心频率（20-500Hz）
    static let sixthOctaveCenterFreqs: [Float] = {
        var freqs: [Float] = []
        let factor = pow(2.0, 1.0/6.0)
        var f: Float = 20
        while f <= 500 {
            freqs.append(f)
            f *= Float(factor)
        }
        return freqs.rounded(to: 1)
    }()

    /// 1/12 倍频程中心频率（20-250Hz）
    static let twelfthOctaveCenterFreqs: [Float] = {
        var freqs: [Float] = []
        let factor = pow(2.0, 1.0/12.0)
        var f: Float = 20
        while f <= 250 {
            freqs.append(f)
            f *= Float(factor)
        }
        return freqs.rounded(to: 1)
    }()

    /// 获取指定分数倍频程的中心频率列表
    static func centerFreqs(fraction: Int, minHz: Float, maxHz: Float) -> [Float] {
        switch fraction {
        case 12: return twelfthOctaveCenterFreqs.filter { $0 >= minHz && $0 <= maxHz }
        case 6:  return sixthOctaveCenterFreqs.filter { $0 >= minHz && $0 <= maxHz }
        case 3:  return thirdOctaveCenterFreqs.filter { $0 >= minHz && $0 <= maxHz }
        default:
            var freqs: [Float] = []
            let factor = pow(2.0, 1.0/Double(fraction))
            var f = minHz
            while f <= maxHz {
                freqs.append(f)
                f *= Float(factor)
            }
            return freqs.rounded(to: 1)
        }
    }

    /// 倍频程频段上下边界
    static func bandEdges(centerFreq: Float, fraction: Int) -> (lo: Float, hi: Float) {
        let factor = pow(2.0, 1.0/Double(2 * fraction))
        let lo = centerFreq / Float(factor)
        let hi = centerFreq * Float(factor)
        return (lo, hi)
    }
}

extension Array where Element == Float {
    func rounded(to decimalPlaces: Int) -> [Float] {
        let multiplier = pow(10.0, Float(decimalPlaces))
        return self.map { ($0 * multiplier).rounded() / multiplier }
    }
}
