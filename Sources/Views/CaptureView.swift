import SwiftUI
import SwiftData
import AVFoundation

@MainActor
struct CaptureView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var captureManager = AudioCaptureManager()
    @AppStorage("captureDuration") private var captureDuration = 8.0
    @AppStorage("refreshInterval") private var refreshInterval = 1.0
    @AppStorage("saveAudio") private var saveAudio = true
    let point: MeasurePoint

    @State private var displayBand = FrequencyBand.low.name
    @State private var isSaving = false
    @State private var savedRecording: Recording?
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var confirmExit = false
    @State private var leaveAfterSave = false
    @State private var audioFailed = false
    @State private var confirmSpectrumOnly = false

    private var shownValues: [Float] {
        captureManager.result?.spectrum.averageSpectrum ?? captureManager.snapshot?.fullSpectrum ?? []
    }
    private var frequencies: [Float] {
        if let data = captureManager.result?.spectrum { return data.frequencies }
        guard let snapshot = captureManager.snapshot else { return [] }
        return snapshot.fullSpectrum.indices.map { Float($0) * snapshot.binWidth }
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("点位：\(point.name)").font(.headline)
                        Spacer()
                        Text(captureManager.isCapturing
                             ? String(format: "剩余 %.0f 秒", max(0, captureManager.targetDuration - captureManager.elapsed))
                             : String(format: "有效 %.2f 秒", captureManager.elapsed))
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                    FrequencyBandPicker(selection: $displayBand)
                    HStack {
                        Text(captureManager.result == nil ? "实时频谱" : "本次平均频谱").font(.headline)
                        Spacer()
                        if isSaving || captureManager.phase == .processing { ProgressView() }
                        Text(statusText).font(.subheadline).foregroundStyle(.secondary)
                    }
                    SpectrumChartView(
                        series: shownValues.isEmpty ? [] : [.init(name: "当前点位", color: .green, values: shownValues)],
                        frequencies: frequencies, band: .named(displayBand)
                    )
                    .frame(height: max(320, min(440, geometry.size.height * 0.62)))
                    if captureManager.result == nil {
                        HStack {
                            Text("输入峰值")
                            Text(String(format: "%.1f dBFS", captureManager.currentLevel)).monospacedDigit()
                            if captureManager.isClipped {
                                Label("电平过强", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                            }
                        }.font(.callout)
                    }
                    if let result = captureManager.result, result.spectrum.isComplete == false {
                        Text("采集不完整：\(result.spectrum.endReason ?? "被中断")。记录可查看，不参与多点比较。")
                            .font(.callout).foregroundStyle(.orange)
                    }
                    if let savedRecording {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("已保存 · \(String(format: "%.2f 秒", captureManager.elapsed))", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            NavigationLink("查看平均频谱", destination: RecordingDetailView(recording: savedRecording))
                            if savedRecording.resolvedAudioURL != nil {
                                NavigationLink("播放录音 / 查看记录", destination: RecordingDetailView(recording: savedRecording))
                            } else {
                                Text("本次未保存录音").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Text("固定手机朝向与高度，保持输入设备一致。频段切换只改变显示，完整频谱仍会保存。")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("dBFS 是数字参考电平，不是校准声压级；手机低频测量能力有限。")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding()
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                if captureManager.phase == .pending && !isSaving {
                    Button("重试保存") { Task { await saveResult() } }
                        .buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
                    if audioFailed { Button("仅保存频谱") { confirmSpectrumOnly = true } }
                } else {
                    Button {
                        if captureManager.isCapturing { captureManager.stopCapture() }
                        else { Task { await startCapture() } }
                    } label: {
                        Text(captureManager.isCapturing ? "停止并保存" : (savedRecording == nil ? "开始采集" : "再次采集"))
                            .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(captureManager.isCapturing ? .red : .blue)
                    .disabled(isSaving || captureManager.phase == .requesting || captureManager.phase == .processing)
                }
            }
            .padding(.horizontal).padding(.vertical, 10).background(.regularMaterial)
        }
        .navigationTitle("采集")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden()
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { requestExit() } label: { Label("返回", systemImage: "chevron.left") }
                    .disabled(isSaving || captureManager.phase == .processing)
            }
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink("历史", destination: RecordingHistoryView(point: point))
                    .disabled(captureManager.isBusy || isSaving || captureManager.phase == .pending)
            }
        }
        .confirmationDialog("停止采集并保存后返回？", isPresented: $confirmExit, titleVisibility: .visible) {
            Button("停止并保存") { leaveAfterSave = true; captureManager.stopCapture() }
            Button("继续采集", role: .cancel) {}
        }
        .confirmationDialog("本次录音保存失败，仅保留频谱？", isPresented: $confirmSpectrumOnly, titleVisibility: .visible) {
            Button("确认仅保存频谱") { Task { await saveResult(omitAudio: true) } }
            Button("取消", role: .cancel) {}
        }
        .alert("采集提示", isPresented: $showError) {
            Button("确定", role: .cancel) {}
            if AVAudioApplication.shared.recordPermission == .denied {
                Button("打开系统设置") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
            }
        } message: { Text(errorMessage) }
        .onChange(of: captureManager.errorMessage) { _, message in
            if let message {
                leaveAfterSave = false
                reportError(message)
                captureManager.errorMessage = nil
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                captureManager.cancelPermissionRequest()
                captureManager.stopCapture(reason: "应用进入后台", complete: false)
            }
        }
        .onDisappear {
            captureManager.cancelPermissionRequest()
            captureManager.stopCapture(reason: "离开采集页", complete: false)
        }
    }

    private var statusText: String {
        if isSaving { return "保存中…" }
        switch captureManager.phase {
        case .idle: return "准备采集"
        case .requesting: return "等待麦克风授权"
        case .capturing: return "采集中"
        case .processing: return "生成平均频谱…"
        case .pending: return "等待保存"
        case .saved: return "已保存"
        }
    }

    private func startCapture() async {
        savedRecording = nil
        audioFailed = false
        leaveAfterSave = false
        captureManager.onFinished = { result in
            Task { await saveResult(completed: result) }
        }
        do {
            try await captureManager.startCapture(duration: captureDuration, saveAudio: saveAudio,
                                                  refreshInterval: refreshInterval)
        } catch { reportError(error.localizedDescription) }
    }

    private func saveResult(completed: CaptureResult? = nil, omitAudio: Bool = false) async {
        guard !isSaving, let result = completed ?? captureManager.result, savedRecording?.id != result.id else { return }
        isSaving = true
        audioFailed = false
        defer { isSaving = false }
        do {
            let files = try await Task.detached(priority: .userInitiated) {
                let spectrumURL = try SpectrumFiles.write(result.spectrum, id: result.id)
                var audioURL: URL?
                if let samples = result.samples, !omitAudio {
                    do {
                        audioURL = try AudioRecorder.save(samples: samples, sampleRate: Double(result.spectrum.sampleRate), id: result.id)
                    } catch { throw RecordingError.audioWrite(error.localizedDescription) }
                }
                return (spectrumURL, audioURL)
            }.value
            let context = ModelContext(modelContext.container)
            context.autosaveEnabled = false
            let id = result.id
            let existing = try context.fetch(FetchDescriptor<Recording>(predicate: #Predicate { $0.id == id })).first
            let record: Recording
            if let existing { record = existing }
            else {
                let pointID = point.id
                guard let storedPoint = try context.fetch(FetchDescriptor<MeasurePoint>(predicate: #Predicate { $0.id == pointID })).first else {
                    throw RecordingError.missingSpectrum
                }
                record = Recording(timestamp: result.timestamp, audioURL: files.1,
                                   durationMs: Int((result.duration * 1000).rounded()),
                                   spectrumURL: files.0, isClipped: result.isClipped)
                record.id = result.id
                context.insert(record)
                record.point = storedPoint
                try context.save()
            }
            guard let visibleRecord = modelContext.model(for: record.persistentModelID) as? Recording else {
                throw RecordingError.missingSpectrum
            }
            if !point.recordings.contains(where: { $0.id == visibleRecord.id }) {
                point.recordings.append(visibleRecord)
            }
            savedRecording = visibleRecord
            captureManager.markSaved()
            if leaveAfterSave { dismiss() }
        } catch {
            if case RecordingError.audioWrite = error { audioFailed = true }
            leaveAfterSave = false
            reportError("\(error.localizedDescription) 数据仍保留，可重试保存。")
        }
    }

    private func requestExit() {
        if captureManager.isCapturing { confirmExit = true }
        else if captureManager.phase == .pending { reportError("本次数据尚未保存，请先重试保存，避免丢失。") }
        else { captureManager.cancelPermissionRequest(); dismiss() }
    }

    private func reportError(_ message: String) {
        errorMessage = message
        showError = true
    }
}
