import Foundation
import AVFoundation

enum AudioError: LocalizedError {
    case sessionFailed
    case engineStartFailed
    case formatMismatch
    case permissionDenied

    var errorDescription: String? {
        switch self {
        case .sessionFailed: return "无法启动音频会话。"
        case .engineStartFailed: return "无法启动麦克风采集。"
        case .formatMismatch: return "当前音频输入格式不可用，请检查麦克风或更换输入设备。"
        case .permissionDenied: return "未获得麦克风权限。请在系统设置中允许麦克风访问后重试。"
        }
    }
}

final class AudioSessionManager {
    static let shared = AudioSessionManager()
    private init() {}

    func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    func configureForCapture() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement,
                                options: [.allowBluetoothHFP, .defaultToSpeaker])
        try session.setPreferredSampleRate(48000)
        try session.setPreferredIOBufferDuration(0.02)
        try session.setActive(true)
    }

    func configureForPlayback() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default)
        try session.setActive(true)
    }

    var actualSampleRate: Double { AVAudioSession.sharedInstance().sampleRate }

    var inputRouteID: String {
        AVAudioSession.sharedInstance().currentRoute.inputs.map { port in
            "\(port.portType.rawValue):\(port.uid):\(port.selectedDataSource?.dataSourceID.stringValue ?? "default")"
        }.joined(separator: "|")
    }
}

extension Notification.Name {
    static let audioInterruptionBegan = Notification.Name("audioInterruptionBegan")
    static let audioInterruptionEnded = Notification.Name("audioInterruptionEnded")
}
