import Foundation
import AVFoundation
import Combine

struct CaptureResult: Identifiable, Sendable {
    let id: UUID
    let timestamp: Date
    let spectrum: SpectrumData
    let samples: [Float]?
    let isClipped: Bool

    var duration: Double {
        Double(spectrum.sampleCount ?? 0) / Double(spectrum.sampleRate)
    }
}

private struct CaptureUpdate: Sendable {
    let sampleCount: Int
    let level: Float
    let clipped: Bool
    let snapshot: SpectrumSnapshot?
}

private final class CapturePipeline: @unchecked Sendable {
    private let queue = DispatchQueue(label: "noise.capture.analysis", qos: .userInitiated)
    private let gate = NSLock()
    private var accepting = true
    private let analyzer: SpectrumAnalyzer
    private let targetSamples: Int
    private let saveAudio: Bool
    private let refreshSamples: Int
    private var sampleCount = 0
    private var samples: [Float] = []
    private var clipped = false
    private var lastPublish = 0
    private var lastSnapshot: SpectrumSnapshot?
    private let onUpdate: @Sendable (CaptureUpdate) -> Void
    private let onTarget: @Sendable () -> Void

    init(sampleRate: Float, duration: Double, saveAudio: Bool, refreshInterval: Double,
         onUpdate: @escaping @Sendable (CaptureUpdate) -> Void,
         onTarget: @escaping @Sendable () -> Void) {
        analyzer = SpectrumAnalyzer(sampleRate: sampleRate)
        targetSamples = Int(Double(sampleRate) * duration)
        self.saveAudio = saveAudio
        refreshSamples = max(1, Int(Double(sampleRate) * refreshInterval))
        self.onUpdate = onUpdate
        self.onTarget = onTarget
        if saveAudio { samples.reserveCapacity(targetSamples) }
    }

    func submit(_ buffer: [Float]) {
        gate.lock()
        defer { gate.unlock() }
        guard accepting else { return }
        queue.async { [self] in
            guard sampleCount < targetSamples else { return }
            let values = Array(buffer.prefix(targetSamples - sampleCount))
            sampleCount += values.count
            if saveAudio { samples.append(contentsOf: values) }
            let peak = values.reduce(Float.zero) { max($0, abs($1)) }
            clipped = clipped || peak >= pow(10, -3.0 / 20.0)
            if let snapshot = analyzer.append(samples: values) { lastSnapshot = snapshot }
            if sampleCount - lastPublish >= refreshSamples || sampleCount >= targetSamples {
                lastPublish = sampleCount
                onUpdate(CaptureUpdate(sampleCount: sampleCount,
                                       level: 20 * log10(max(peak, 1e-6)),
                                       clipped: clipped, snapshot: lastSnapshot))
            }
            if sampleCount >= targetSamples { onTarget() }
        }
    }

    func finish(id: UUID, timestamp: Date, route: String, complete: Bool, reason: String,
                completion: @escaping @Sendable (CaptureResult) -> Void) {
        gate.lock()
        accepting = false
        queue.async { [self] in
            var data = analyzer.finalize()
            data.inputRoute = route
            data.isComplete = complete
            data.endReason = reason
            completion(CaptureResult(id: id, timestamp: timestamp, spectrum: data,
                                     samples: saveAudio ? samples : nil, isClipped: clipped))
        }
        gate.unlock()
    }
}

@MainActor
final class AudioCaptureManager: ObservableObject {
    enum Phase: Equatable {
        case idle, requesting, capturing, processing, pending, saved
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var currentLevel: Float = -120
    @Published private(set) var isClipped = false
    @Published private(set) var sampleRate: Double = 48000
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var targetDuration: Double = 8
    @Published private(set) var snapshot: SpectrumSnapshot?
    @Published private(set) var result: CaptureResult?
    @Published var errorMessage: String?
    var onFinished: ((CaptureResult) -> Void)?

    private let engine = AVAudioEngine()
    private var pipeline: CapturePipeline?
    private var captureID = UUID()
    private var timestamp = Date()
    private var inputRoute = ""
    private var observers: [NSObjectProtocol] = []
    private var watchdog: Timer?
    private var lastProgressTime = Date()
    private var hasTap = false

    var isCapturing: Bool { phase == .capturing }
    var isBusy: Bool { phase == .requesting || phase == .capturing || phase == .processing }

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification,
                                             object: nil, queue: .main) { [weak self] notification in
            let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard type == AVAudioSession.InterruptionType.began.rawValue else { return }
            Task { @MainActor in self?.stopCapture(reason: "录音被系统中断", complete: false) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification,
                                             object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isCapturing,
                      AudioSessionManager.shared.inputRouteID != self.inputRoute else { return }
                self.stopCapture(reason: "音频输入设备发生变化", complete: false)
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                                             object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.stopCapture(reason: "音频服务被重置", complete: false) }
        })
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        watchdog?.invalidate()
    }

    func startCapture(duration: Double, saveAudio: Bool, refreshInterval: Double) async throws {
        guard phase == .idle || phase == .saved else { return }
        phase = .requesting
        let id = UUID()
        captureID = id
        let allowed = await AudioSessionManager.shared.requestPermission()
        guard captureID == id, phase == .requesting else { return }
        guard allowed else {
            phase = .idle
            onFinished = nil
            throw AudioError.permissionDenied
        }
        do {
            try AudioSessionManager.shared.configureForCapture()
            let format = engine.inputNode.outputFormat(forBus: 0)
            guard format.sampleRate.isFinite, format.sampleRate > 0,
                  format.channelCount > 0, format.commonFormat == .pcmFormatFloat32 else {
                throw AudioError.formatMismatch
            }
            sampleRate = format.sampleRate
            targetDuration = min(30, max(5, duration.isFinite ? duration : 8))
            inputRoute = AudioSessionManager.shared.inputRouteID
            timestamp = Date()
            result = nil
            snapshot = nil
            elapsed = 0
            currentLevel = -120
            isClipped = false
            let interval = min(5, max(0.1, refreshInterval.isFinite ? refreshInterval : 1))
            let processor = CapturePipeline(sampleRate: Float(sampleRate), duration: targetDuration,
                                            saveAudio: saveAudio, refreshInterval: interval,
                                            onUpdate: { [weak self] update in
                Task { @MainActor in
                    guard let self, self.captureID == id, self.isCapturing else { return }
                    self.elapsed = Double(update.sampleCount) / self.sampleRate
                    self.currentLevel = update.level
                    self.isClipped = update.clipped
                    self.snapshot = update.snapshot
                    self.lastProgressTime = Date()
                }
            }, onTarget: { [weak self] in
                Task { @MainActor in
                    guard let self, self.captureID == id else { return }
                    self.stopCapture(reason: "到时完成")
                }
            })
            pipeline = processor
            engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
                guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
                processor.submit(Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength))))
            }
            hasTap = true
            engine.prepare()
            try engine.start()
            phase = .capturing
            lastProgressTime = Date()
            watchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.isCapturing else { return }
                    if Date().timeIntervalSince(self.lastProgressTime) > max(7, interval * 2) {
                        self.stopCapture(reason: "未持续收到麦克风数据", complete: false)
                    }
                }
            }
        } catch {
            teardown()
            pipeline = nil
            phase = .idle
            onFinished = nil
            throw error
        }
    }

    func stopCapture(reason: String = "手动停止", complete: Bool = true) {
        guard phase == .capturing, let pipeline else { return }
        phase = .processing
        teardown()
        let id = captureID
        pipeline.finish(id: id, timestamp: timestamp, route: inputRoute,
                        complete: complete, reason: reason) { [self] result in
            Task { @MainActor in
                guard self.captureID == id else { return }
                self.pipeline = nil
                self.elapsed = result.duration
                self.isClipped = result.isClipped
                let completion = self.onFinished
                self.onFinished = nil
                guard result.spectrum.isValid else {
                    self.phase = .idle
                    self.errorMessage = "\(reason)：没有足够的有效样本，未标记为已采集。"
                    return
                }
                self.result = result
                self.phase = .pending
                completion?(result)
            }
        }
    }

    func cancelPermissionRequest() {
        guard phase == .requesting else { return }
        captureID = UUID()
        phase = .idle
        onFinished = nil
    }

    func markSaved() { phase = .saved }

    private func teardown() {
        watchdog?.invalidate()
        watchdog = nil
        if hasTap {
            engine.inputNode.removeTap(onBus: 0)
            hasTap = false
        }
        engine.stop()
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            errorMessage = "采集已停止，但音频会话释放失败：\(error.localizedDescription)"
        }
    }
}
