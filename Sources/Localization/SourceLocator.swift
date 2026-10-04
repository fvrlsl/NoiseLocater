import Foundation
import Accelerate

/// 声源定位结果
struct SourceLocation {
    var x: Double = 0
    var y: Double = 0
    var z: Double = 0
    var confidence: Double = 0   // 置信半径（米）
    var isValid: Bool = false

    var coordinate: (Double, Double, Double) { (x, y, z) }
}

/// 多频率方位汇总
struct LocationSummary {
    struct Entry {
        let freq: Float
        let location: SourceLocation
    }
    var entries: [Entry] = []
    var consistency: Consistency = .low

    enum Consistency: String {
        case high    // 多频率方位距离 < 0.5m
        case medium  // 0.5–1.5m
        case low     // > 1.5m

        var label: String {
            switch self {
            case .high: return "多频率一致指向该区域，可信度高"
            case .medium: return "指向接近，声源可能在该区域"
            case .low: return "指向分散，可能存在多个声源"
            }
        }
    }
}

/// 加权最小二乘（WLS）声源定位
final class SourceLocator {

    /// 平面模式 2D 定位
    /// - Parameters:
    ///   - points: 各点位坐标
    ///   - dbValues: 各点位 dB 值
    /// - Returns: 声源估算位置 + 置信度
    func locate2D(
        points: [(x: Double, y: Double)],
        dbValues: [Double]
    ) -> SourceLocation {
        guard points.count >= 3, points.count == dbValues.count else {
            return SourceLocation()
        }

        // 选 dB 最大点位为参考（离声源最近）
        let refIdx = dbValues.firstIndex(of: dbValues.max() ?? dbValues[0]) ?? 0
        let refPoint = points[refIdx]
        let refDb = dbValues[refIdx]

        // 线性化方程: A * [xs, ys, r_ref^2]^T = b
        // 对每个非参考点 i:
        //   2(x_ref - x_i) * xs + 2(y_ref - y_i) * ys + (1 - ratio_i^2) * r_ref^2
        //   = x_i^2 - x_ref^2 + y_i^2 - y_ref^2
        //   ratio_i = 10^((refDb - db_i) / 20)
        let n = points.count - 1
        var A = [[Double]](repeating: [Double](repeating: 0, count: 3), count: n)
        var b = [Double](repeating: 0, count: n)

        var row = 0
        for i in 0..<points.count {
            if i == refIdx { continue }
            let distRatio = pow(10.0, (refDb - dbValues[i]) / 20.0)
            A[row][0] = 2 * (refPoint.x - points[i].x)
            A[row][1] = 2 * (refPoint.y - points[i].y)
            A[row][2] = 1 - distRatio * distRatio
            b[row] = points[i].x * points[i].x - refPoint.x * refPoint.x +
                     points[i].y * points[i].y - refPoint.y * refPoint.y
            row += 1
        }

        let solution = solveWLS(A: A, b: b)

        let result = SourceLocation(
            x: solution[0],
            y: solution[1],
            z: 0,
            confidence: computeConfidence(
                source: (solution[0], solution[1]),
                points: points.map { ($0.x, $0.y) },
                dbValues: dbValues
            ),
            isValid: solution[0].isFinite && solution[1].isFinite
        )
        return result
    }

    /// 立体模式 3D 定位
    func locate3D(
        points: [(x: Double, y: Double, z: Double)],
        dbValues: [Double]
    ) -> SourceLocation {
        guard points.count >= 4, points.count == dbValues.count else {
            return SourceLocation()
        }

        let refIdx = dbValues.firstIndex(of: dbValues.max() ?? dbValues[0]) ?? 0
        let refPoint = points[refIdx]
        let refDb = dbValues[refIdx]

        // 线性化: A * [xs, ys, zs, r_ref^2]^T = b (4 unknowns)
        let n = points.count - 1
        var A = [[Double]](repeating: [Double](repeating: 0, count: 4), count: n)
        var b = [Double](repeating: 0, count: n)

        var row = 0
        for i in 0..<points.count {
            if i == refIdx { continue }
            let distRatio = pow(10.0, (refDb - dbValues[i]) / 20.0)
            A[row][0] = 2 * (refPoint.x - points[i].x)
            A[row][1] = 2 * (refPoint.y - points[i].y)
            A[row][2] = 2 * (refPoint.z - points[i].z)
            A[row][3] = 1 - distRatio * distRatio
            b[row] = points[i].x * points[i].x - refPoint.x * refPoint.x +
                     points[i].y * points[i].y - refPoint.y * refPoint.y +
                     points[i].z * points[i].z - refPoint.z * refPoint.z
            row += 1
        }

        let solution = solveWLS(A: A, b: b)

        return SourceLocation(
            x: solution[0],
            y: solution[1],
            z: solution[2],
            confidence: computeConfidence(
                source: (solution[0], solution[1]),
                points: points.map { ($0.x, $0.y) },
                dbValues: dbValues
            ),
            isValid: solution[0].isFinite && solution[1].isFinite
        )
    }

    /// 多频率方位汇总
    func multiFreqLocation(
        freqs: [SuspiciousFrequency],
        points: [(x: Double, y: Double, z: Double)]
    ) -> LocationSummary {
        var summary = LocationSummary()
        var locations2D: [(Float, Double, Double)] = []

        for f in freqs {
            let dbDoubles = f.dbValues.map { Double($0) }
            let loc: SourceLocation
            if points.allSatisfy({ $0.z == 0 }) {
                let pts2D = points.map { ($0.x, $0.y) }
                loc = locate2D(points: pts2D, dbValues: dbDoubles)
            } else {
                loc = locate3D(points: points, dbValues: dbDoubles)
            }
            summary.entries.append(LocationSummary.Entry(freq: f.freq, location: loc))
            locations2D.append((f.freq, loc.x, loc.y))
        }

        // 一致性判断
        if !locations2D.isEmpty {
            let maxDist = maxPairwiseDistance(locations2D)
            if maxDist < 0.5 { summary.consistency = .high }
            else if maxDist < 1.5 { summary.consistency = .medium }
            else { summary.consistency = .low }
        }

        return summary
    }

    // MARK: - Private

    /// 解 WLS: x = (A^T A)^-1 A^T b
    private func solveWLS(A: [[Double]], b: [Double]) -> [Double] {
        let m = A.count
        let n = A[0].count

        // 展开为一维
        var aFlat = [Double](repeating: 0, count: m * n)
        for i in 0..<m {
            for j in 0..<n {
                aFlat[i * n + j] = A[i][j]
            }
        }
        var bMut = b

        // ATA = A^T * A (n x n), ATb = A^T * b (n)
        var ata = [Double](repeating: 0, count: n * n)
        var atb = [Double](repeating: 0, count: n)
        var aTrans = [Double](repeating: 0, count: m * n)

        // A^T (n x m)
        aFlat.withUnsafeMutableBufferPointer { aMutPtr in
            aTrans.withUnsafeMutableBufferPointer { atMutPtr in
                guard let aBase = aMutPtr.baseAddress, let atBase = atMutPtr.baseAddress else { return }
                vDSP_mtransD(aBase, 1, atBase, 1,
                             vDSP_Length(n), vDSP_Length(m))

                // ATA = A^T * A (n x n)
                ata.withUnsafeMutableBufferPointer { ataMutPtr in
                    guard let ataBase = ataMutPtr.baseAddress else { return }
                    vDSP_mmulD(
                        atBase, 1,
                        aBase, 1,
                        ataBase, 1,
                        vDSP_Length(n), vDSP_Length(n), vDSP_Length(m)
                    )
                }

                // ATb = A^T * b (n)
                atb.withUnsafeMutableBufferPointer { atbMutPtr in
                    guard let atbBase = atbMutPtr.baseAddress else { return }
                    bMut.withUnsafeMutableBufferPointer { bMutPtr in
                        guard let bBase = bMutPtr.baseAddress else { return }
                        vDSP_mmulD(
                            atBase, 1,
                            bBase, 1,
                            atbBase, 1,
                            vDSP_Length(n), vDSP_Length(1), vDSP_Length(m)
                        )
                    }
                }
            }
        }

        // 解 ATA * x = ATb（ATA 是对称正定，用 Cholesky 分解 + 前向/后向替换）
        // 如果 spsolve 不可用，回退到手动 Gaussian elimination
        var solution = [Double](repeating: 0, count: n)
        gaussianElimination(A: &ata, b: &atb, x: &solution, n: n)
        return solution
    }

    /// 高斯消元法解线性方程组（通用回退方案）
    private func gaussianElimination(A: inout [Double], b: inout [Double],
                                       x: inout [Double], n: Int) {
        // 前向消元 + 部分主元选择
        for k in 0..<n {
            // 找主元
            var maxRow = k
            for i in (k+1)..<n {
                if abs(A[i * n + k]) > abs(A[maxRow * n + k]) {
                    maxRow = i
                }
            }
            // 交换行
            if maxRow != k {
                for j in 0..<n {
                    let tmp = A[k * n + j]
                    A[k * n + j] = A[maxRow * n + j]
                    A[maxRow * n + j] = tmp
                }
                let tmp = b[k]; b[k] = b[maxRow]; b[maxRow] = tmp
            }
            // 消元
            for i in (k+1)..<n {
                let factor = A[i * n + k] / A[k * n + k]
                for j in k..<n {
                    A[i * n + j] -= factor * A[k * n + j]
                }
                b[i] -= factor * b[k]
            }
        }
        // 后向替换
        for i in (0..<n).reversed() {
            var sum = b[i]
            for j in (i+1)..<n {
                sum -= A[i * n + j] * x[j]
            }
            x[i] = sum / A[i * n + i]
        }
    }

    /// 置信度：基于各点位 dB 拋差
    private func computeConfidence(
        source: (Double, Double),
        points: [(Double, Double)],
        dbValues: [Double]
    ) -> Double {
        // 计算各点位到声源距离
        let distances = points.map { p in
            sqrt(pow(p.0 - source.0, 2) + pow(p.1 - source.1, 2))
        }
        // 计算距离与 dB 差的拟合残差
        let refDist = distances.max() ?? 1
        let refDb = dbValues.min() ?? 0

        var residuals: [Double] = []
        for i in 0..<points.count {
            let expectedDb = refDb + 20 * log10(distances[i] / refDist)
            residuals.append(abs(expectedDb - dbValues[i]))
        }
        let avgResidual = residuals.reduce(0, +) / Double(residuals.count)
        // 置信半径 ≈ 平均残差 * 间距
        return avgResidual * 0.5
    }

    /// 计算多个声源位置间的最大距离
    private func maxPairwiseDistance(_ locations: [(Float, Double, Double)]) -> Double {
        var maxDist: Double = 0
        for i in 0..<locations.count {
            for j in (i+1)..<locations.count {
                let dx = locations[i].1 - locations[j].1
                let dy = locations[i].2 - locations[j].2
                let dist = sqrt(dx * dx + dy * dy)
                maxDist = max(maxDist, dist)
            }
        }
        return maxDist
    }
}
