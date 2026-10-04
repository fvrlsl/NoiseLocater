import Foundation
import AVFoundation

/// 音频生成器：正弦波 / 扫频 / 批量验证
final class AudioGenerator {

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let sampleRate: Double = 48000
    private let session = AudioSessionManager.shared

    private var phase: Float = 0
    private var isConfigured = false

    init() {}

    func configure() throws {
        guard !isConfigured else { return }

        engine.attach(playerNode)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        engine.connect(playerNode, to: engine.mainMixerNode, format: format)

        try session.configureForPlayback()
        engine.prepare()
        isConfigured = true
    }

    /// 生成指定频率纯音
    /// - Parameters:
    ///   - frequency: 频率 Hz
    ///   - duration: 时长 秒
    ///   - volumeDB: 音量 dB FS（-40 ~ 0）
    func generateTone(frequency: Float, duration: Double, volumeDB: Float = -20) {
        guard isConfigured else { return }

        let numSamples = Int(sampleRate * duration)
        let format = playerNode.outputFormat(forBus: 0)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                             frameCapacity: AVAudioFrameCount(numSamples)) else { return }
        buffer.frameLength = AVAudioFrameCount(numSamples)

        guard let channelData = buffer.floatChannelData?[0] else { return }
        let volume = pow(10, volumeDB / 20)  // dB -> amplitude
        let phaseIncrement: Float = 2 * .pi * frequency / Float(sampleRate)

        for i in 0..<numSamples {
            channelData[i] = sin(phase) * volume
            phase += phaseIncrement
            if phase > 2 * .pi { phase -= 2 * .pi }
        }

        playerNode.scheduleBuffer(buffer, completionHandler: nil)
    }

    /// 生成线性扫频
    /// - Parameters:
    ///   - startFreq: 起始频率
    ///   - endFreq: 终止频率
    ///   - duration: 时长
    ///   - volumeDB: 音量
    func generateSweep(startFreq: Float, endFreq: Float,
                       duration: Double, volumeDB: Float = -20) {
        guard isConfigured else { return }

        let numSamples = Int(sampleRate * duration)
        let format = playerNode.outputFormat(forBus: 0)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                             frameCapacity: AVAudioFrameCount(numSamples)) else { return }
        buffer.frameLength = AVAudioFrameCount(numSamples)

        guard let channelData = buffer.floatChannelData?[0] else { return }
        let volume = pow(10, volumeDB / 20)
        let k: Float = (endFreq - startFreq) / Float(duration)  // 频率变化率

        var localPhase: Float = 0
        let sr = Float(sampleRate)
        for i in 0..<numSamples {
            let t = Float(i) / sr
            let freq = startFreq + k * t
            let phaseInc = 2 * .pi * freq / sr
            channelData[i] = sin(localPhase) * volume
            localPhase += phaseInc
        }

        playerNode.scheduleBuffer(buffer, completionHandler: nil)
    }

    func play() throws {
        if !engine.isRunning {
            try engine.start()
        }
        playerNode.play()
    }

    func stop() {
        playerNode.stop()
    }

    var isPlaying: Bool { playerNode.isPlaying }
}
