import Foundation

final class SpectrumAnalyzer {

    private let fft: FFTProcessor
    private let sampleRate: Float
    private var pendingSamples: [Float] = []
    private var weightedPower: [Double]
    private var accumulatedWeight: Double = 0
    private var sampleCount = 0
    private var finalizedData: SpectrumData?

    var refreshInterval: TimeInterval = 1.0

    init(fftSize: Int = 16384, sampleRate: Float = 48000) {
        self.fft = FFTProcessor(fftSize: fftSize, sampleRate: sampleRate)
        self.sampleRate = sampleRate
        self.weightedPower = [Double](repeating: 0, count: fftSize / 2 + 1)
        pendingSamples.reserveCapacity(fftSize)
    }

    func append(samples: [Float]) -> SpectrumSnapshot? {
        guard finalizedData == nil else { return nil }
        var latestPower: [Float]?
        for sample in samples where sample.isFinite {
            pendingSamples.append(sample)
            sampleCount += 1
            if pendingSamples.count == fft.fftSize {
                latestPower = accumulate(samples: pendingSamples)
                pendingSamples.removeAll(keepingCapacity: true)
            }
        }
        guard let power = latestPower else { return nil }
        return SpectrumSnapshot(
            fullSpectrum: power.map(FFTProcessor.powerToDB),
            bandData: fft.aggregatePowerByBand(power: power),
            sampleRate: sampleRate,
            fftSize: fft.fftSize
        )
    }

    func processFrame(samples: [Float]) -> SpectrumSnapshot? {
        append(samples: samples)
    }

    func finalize() -> SpectrumData {
        if let finalizedData { return finalizedData }
        if accumulatedWeight > 0 && !pendingSamples.isEmpty {
            _ = accumulate(samples: pendingSamples)
        }
        pendingSamples.removeAll(keepingCapacity: true)

        var average: [Float] = []
        var bands: [String: SpectrumData.BandSpectrum] = [:]
        if accumulatedWeight > 0 {
            let power = weightedPower.map { Float($0 / accumulatedWeight) }
            average = power.map(FFTProcessor.powerToDB)
            bands = fft.aggregatePowerByBand(power: power).mapValues { data in
                SpectrumData.BandSpectrum(
                    frequencies: data.map { $0.freq },
                    dbValues: data.map { $0.db }
                )
            }
        }
        let data = SpectrumData(
            bands: bands,
            averageSpectrum: average,
            sampleRate: sampleRate,
            fftSize: fft.fftSize,
            binWidth: fft.binWidth,
            formatVersion: 2,
            algorithmVersion: SpectrumData.currentAlgorithm,
            sampleCount: sampleCount
        )
        finalizedData = data
        return data
    }

    func reset() {
        pendingSamples.removeAll(keepingCapacity: true)
        weightedPower = [Double](repeating: 0, count: fft.halfSize + 1)
        accumulatedWeight = 0
        sampleCount = 0
        finalizedData = nil
    }

    private func accumulate(samples: [Float]) -> [Float] {
        let power = fft.computePower(samples: samples)
        let weight = Double(samples.count)
        for index in power.indices {
            weightedPower[index] += Double(power[index]) * weight
        }
        accumulatedWeight += weight
        return power
    }
}

struct SpectrumSnapshot: Sendable {
    let fullSpectrum: [Float]
    let bandData: [String: [(freq: Float, db: Float)]]
    let sampleRate: Float
    let fftSize: Int

    var binWidth: Float { sampleRate / Float(fftSize) }
    var bindWidth: Float { binWidth }
    var maxFreq: Float { sampleRate / 2 }
}
