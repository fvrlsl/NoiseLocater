import Foundation
import Accelerate

final class FFTProcessor {

    let fftSize: Int
    let sampleRate: Float
    let binWidth: Float
    let halfSize: Int

    private let log2n: vDSP_Length
    private let fftSetup: FFTSetup
    private let hannWindow: [Float]
    private let windowPower: Double

    init(fftSize: Int = 16384, sampleRate: Float = 48000) {
        precondition(fftSize >= 2 && fftSize <= 262144 && fftSize.nonzeroBitCount == 1)
        precondition(sampleRate.isFinite && sampleRate > 0 && sampleRate / Float(fftSize) > 0)
        self.fftSize = fftSize
        self.sampleRate = sampleRate
        self.binWidth = sampleRate / Float(fftSize)
        self.halfSize = fftSize / 2
        self.log2n = vDSP_Length(fftSize.trailingZeroBitCount)

        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            fatalError("Failed to create FFT setup")
        }
        self.fftSetup = setup
        self.hannWindow = Self.makeWindow(count: fftSize)
        self.windowPower = hannWindow.reduce(0) { $0 + Double($1) * Double($1) }
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    func computeSpectrum(samples: [Float]) -> [Float] {
        computePower(samples: samples).map(Self.powerToDB)
    }

    func computePower(samples: [Float]) -> [Float] {
        let input = samples.suffix(fftSize)
        guard !input.isEmpty, input.allSatisfy(\.isFinite) else { return [] }
        let window = input.count == fftSize ? hannWindow : Self.makeWindow(count: input.count)
        let energy = input.count == fftSize ? windowPower :
            window.reduce(0) { $0 + Double($1) * Double($1) }

        var windowed = [Float](repeating: 0, count: fftSize)
        for (index, sample) in input.enumerated() {
            windowed[index] = sample * window[index]
        }

        var real = [Float](repeating: 0, count: halfSize)
        var imaginary = [Float](repeating: 0, count: halfSize)
        for index in 0..<halfSize {
            real[index] = windowed[index * 2]
            imaginary[index] = windowed[index * 2 + 1]
        }

        var power = [Float](repeating: 0, count: halfSize + 1)
        let scale = 1 / (4 * Double(fftSize) * energy)
        real.withUnsafeMutableBufferPointer { realBuffer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryBuffer in
                var split = DSPSplitComplex(realp: realBuffer.baseAddress!,
                                           imagp: imaginaryBuffer.baseAddress!)
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, Int32(FFT_FORWARD))
                let dc = Double(split.realp[0])
                let nyquist = Double(split.imagp[0])
                power[0] = Float(dc * dc * scale)
                power[halfSize] = Float(nyquist * nyquist * scale)
                for index in 1..<halfSize {
                    let re = Double(split.realp[index])
                    let im = Double(split.imagp[index])
                    power[index] = Float(2 * (re * re + im * im) * scale)
                }
            }
        }
        return power
    }

    static func powerToDB(_ power: Float) -> Float {
        10 * log10(max(power, 1e-20))
    }

    func aggregateByBand(spectrum: [Float]) -> [String: [(freq: Float, db: Float)]] {
        guard spectrum.allSatisfy(\.isFinite) else { return [:] }
        return aggregatePowerByBand(power: spectrum.map { pow(10, $0 / 10) })
    }

    func aggregatePowerByBand(power: [Float]) -> [String: [(freq: Float, db: Float)]] {
        guard power.count == halfSize + 1,
              power.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return [:] }
        var result: [String: [(freq: Float, db: Float)]] = [:]
        let nyquist = sampleRate / 2

        for band in [FrequencyBand.low, FrequencyBand.mid, FrequencyBand.high] {
            let centers = OctaveBands.centerFreqs(
                fraction: band.octaveFraction,
                minHz: band.minHz,
                maxHz: min(band.maxHz, nyquist)
            )
            result[band.name] = centers.map { center in
                let (lo, hi) = OctaveBands.bandEdges(centerFreq: center, fraction: band.octaveFraction)
                let firstBin = Int(min(Double(halfSize + 1), ceil(Double(lo) / Double(binWidth))))
                let endBin = Int(min(Double(halfSize + 1), ceil(Double(hi) / Double(binWidth))))
                let total = power[firstBin..<endBin].reduce(0.0) { $0 + Double($1) }
                return (freq: center, db: Self.powerToDB(Float(total)))
            }
        }
        return result
    }

    private static func makeWindow(count: Int) -> [Float] {
        guard count > 1 else { return [1] }
        var window = [Float](repeating: 0, count: count)
        vDSP_hann_window(&window, vDSP_Length(count), Int32(vDSP_HANN_DENORM))
        return window
    }

    static let logScaleLabels: [Float] = [
        20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000
    ]
}
