import Foundation

struct SuspiciousFrequency: Identifiable, Sendable {
    var id = UUID()
    let freq: Float
    let band: String
    let dbValues: [Float]
    let maxPoint: Int
    let minPoint: Int
    let range: Float
    let distanceRatio: Float
    var score: Float
    var harmonics: [Float]

    var freqLabel: String {
        freq < 1000 ? String(format: "%.1f Hz", freq) :
                       String(format: "%.1f kHz", freq / 1000)
    }
}

final class AnomalyDetector {

    var threshold: Float = 6.0
    private let mergeBinDistance = 3

    func detectBand(
        pointSpectra: [[Float]],
        band: FrequencyBand,
        binWidth: Float
    ) -> [SuspiciousFrequency] {
        guard threshold.isFinite, threshold >= 0,
              binWidth.isFinite, binWidth > 0,
              band.minHz.isFinite, band.maxHz.isFinite,
              band.minHz >= 0, band.maxHz > band.minHz,
              pointSpectra.count >= 3,
              let numBins = pointSpectra.first?.count, numBins > 0,
              pointSpectra.allSatisfy({ $0.count == numBins && $0.allSatisfy(\.isFinite) }) else {
            return []
        }
        let lastFrequency = Double(numBins - 1) * Double(binWidth)
        guard lastFrequency <= Double(Float.greatestFiniteMagnitude),
              Double(band.minHz) <= lastFrequency else { return [] }
        let firstBin = Int(ceil(Double(band.minHz) / Double(binWidth)))
        let lastBin = Int(floor(min(Double(band.maxHz), lastFrequency) / Double(binWidth)))
        guard firstBin <= lastBin else { return [] }

        var candidates: [(bin: Int, range: Float, dbs: [Float])] = []
        for bin in firstBin...lastBin {
            let dbs = pointSpectra.map { $0[bin] }
            let range = dbs.max()! - dbs.min()!
            if range.isFinite && range > threshold {
                candidates.append((bin, range, dbs))
            }
        }
        candidates.sort {
            $0.range == $1.range ? $0.bin < $1.bin : $0.range > $1.range
        }

        var selectedBins: [Int] = []
        var merged: [SuspiciousFrequency] = []
        for candidate in candidates {
            guard selectedBins.allSatisfy({ abs(candidate.bin - $0) > mergeBinDistance }) else {
                continue
            }
            let maxIndex = candidate.dbs.firstIndex(of: candidate.dbs.max()!)!
            let minIndex = candidate.dbs.firstIndex(of: candidate.dbs.min()!)!
            merged.append(SuspiciousFrequency(
                freq: Float(candidate.bin) * binWidth,
                band: band.name,
                dbValues: candidate.dbs,
                maxPoint: maxIndex,
                minPoint: minIndex,
                range: candidate.range,
                distanceRatio: pow(10, -candidate.range / 20),
                score: candidate.range,
                harmonics: []
            ))
            selectedBins.append(candidate.bin)
            if merged.count == 3 { break }
        }
        return merged
    }

    func globalRanking(
        bandResults: [String: [SuspiciousFrequency]],
        binWidth: Float = 48000.0 / 16384.0
    ) -> [SuspiciousFrequency] {
        guard threshold.isFinite, threshold >= 0, binWidth.isFinite, binWidth > 0 else { return [] }
        var all = bandResults.values.flatMap { $0 }.filter {
            $0.freq.isFinite && $0.freq >= 0 && $0.range.isFinite && $0.range > threshold &&
            $0.dbValues.count >= 3 && $0.dbValues.allSatisfy(\.isFinite) &&
            $0.dbValues.indices.contains($0.maxPoint) && $0.dbValues.indices.contains($0.minPoint)
        }
        let groups = detectHarmonics(frequencies: all)
        for index in all.indices {
            all[index].harmonics = groups[all[index].freq] ?? []
            let bandWeight: Float = all[index].band == "low" ? 1.5 :
                                    all[index].band == "high" ? 0.8 : 1.0
            let harmonicWeight: Float = all[index].harmonics.isEmpty ? 1.0 : 1.3
            all[index].score = all[index].range * bandWeight * harmonicWeight
        }
        all = all.filter { $0.score.isFinite }.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.range != $1.range { return $0.range > $1.range }
            if $0.freq != $1.freq { return $0.freq < $1.freq }
            return $0.band < $1.band
        }

        var selected: [SuspiciousFrequency] = []
        for candidate in all {
            guard selected.allSatisfy({
                abs(Double(candidate.freq) - Double($0.freq)) / Double(binWidth) > Double(mergeBinDistance)
            }) else { continue }
            selected.append(candidate)
            if selected.count == 10 { break }
        }
        return selected
    }

    func detectHarmonics(frequencies: [SuspiciousFrequency]) -> [Float: [Float]] {
        let values = Set(frequencies.map(\.freq).filter { $0.isFinite && $0 > 0 }).sorted()
        var groups: [Float: [Float]] = [:]
        for base in values where base < 300 {
            let harmonics = values.filter { frequency in
                let ratio = Double(frequency) / Double(base)
                let nearest = ratio.rounded()
                return nearest >= 2 && nearest <= 6 && abs(ratio - nearest) < 0.05
            }
            if !harmonics.isEmpty {
                groups[base] = harmonics
            }
        }
        return groups
    }
}
