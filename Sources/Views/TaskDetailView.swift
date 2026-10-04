import SwiftUI
import SwiftData
import AVFoundation

@MainActor
struct TaskDetailView: View {
    @Environment(\.modelContext) private var modelContext
    let task: TaskModel

    @State private var editingPoint: MeasurePoint?
    @State private var capturePoint: MeasurePoint?
    @State private var historyPoint: MeasurePoint?
    @State private var addingPoint = false
    @State private var pointPendingRemoval: MeasurePoint?
    @State private var confirmingRemoval = false
    @State private var errorMessage = ""
    @State private var showError = false

    private var pointLimit: Int { task.layoutMode == .planar ? 6 : 8 }
    private var removedPoints: [MeasurePoint] {
        task.points.filter { $0.deletedAt != nil }.sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }
    }

    var body: some View {
        Form {
            Section("任务信息") {
                LabeledContent("名称", value: task.name)
                LabeledContent("布局", value: task.layoutMode == .planar ? "平面" : "立体")
                LabeledContent("初始布局间距", value: String(format: "%.1f m", task.spacing))
                LabeledContent("当前点位", value: "\(task.activePoints.count) / \(pointLimit)")
            }
            Section("点位列表") {
                ForEach(task.activePoints) { point in
                    VStack(alignment: .leading, spacing: 12) {
                        NavigationLink(destination: CaptureView(point: point)) {
                            PointRowView(point: point)
                        }
                        .buttonStyle(.plain)
                        HStack(spacing: 18) {
                            Button("编辑点位") { editingPoint = point }
                                .buttonStyle(.borderless)
                            NavigationLink(destination: RecordingHistoryView(point: point)) {
                                Label("历史记录", systemImage: "clock")
                            }
                            .buttonStyle(.borderless)
                            Spacer(minLength: 0)
                            Button(role: .destructive) {
                                pointPendingRemoval = point
                                confirmingRemoval = true
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("删除点位 \(point.name)")
                        }
                        .font(.subheadline)
                    }
                    .padding(.vertical, 4)
                }
                if task.activePoints.isEmpty {
                    Text("暂无点位，可添加或恢复已删除点位。")
                        .foregroundStyle(.secondary)
                }
                Button("添加点位") { addingPoint = true }
                    .disabled(task.activePoints.count >= pointLimit)
            }
            if !removedPoints.isEmpty {
                Section {
                    ForEach(removedPoints) { point in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(point.name).font(.headline)
                            Text("记录和原始文件已保留")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            HStack {
                                NavigationLink("查看历史", destination: RecordingHistoryView(point: point))
                                    .buttonStyle(.borderless)
                                Spacer()
                                Button("恢复点位") { restore(point) }
                                    .buttonStyle(.borderless)
                                    .disabled(task.activePoints.count >= pointLimit)
                            }
                        }
                    }
                } header: {
                    Text("已删除点位")
                } footer: {
                    Text("恢复后计入当前点位；\(task.layoutMode == .planar ? "平面" : "立体")任务最多 \(pointLimit) 个点位。")
                }
            }
            Section("排查") {
                NavigationLink(destination: AnalysisView(task: task)) {
                    Label("查看排查结果", systemImage: "chart.xyaxis.line")
                }
                Text("多点比较需要至少 3 个有效可比点位；不足时仍可查看历史频谱和排除原因。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(task.name)
        .sheet(item: $editingPoint) { point in
            PointCoordinateEditor(task: task, point: point)
        }
        .sheet(isPresented: $addingPoint) {
            PointCoordinateEditor(task: task, point: nil)
        }
        .confirmationDialog("删除点位“\(pointPendingRemoval?.name ?? "")”？", isPresented: $confirmingRemoval, titleVisibility: .visible) {
            Button("删除点位（可恢复）", role: .destructive) {
                if let point = pointPendingRemoval { remove(point) }
                pointPendingRemoval = nil
            }
            Button("取消", role: .cancel) { pointPendingRemoval = nil }
        } message: {
            Text("该点及其记录将退出当前任务列表和分析。历史记录与原始文件不会永久删除，可在已删除点位中恢复。")
        }
        .alert("保存失败", isPresented: $showError) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }

    private func remove(_ point: MeasurePoint) {
        let oldValue = point.deletedAt
        point.deletedAt = Date()
        do {
            try modelContext.save()
        } catch {
            point.deletedAt = oldValue
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private func restore(_ point: MeasurePoint) {
        guard task.activePoints.count < pointLimit else {
            errorMessage = "当前点位已达 \(pointLimit) 个，请先移除其他点位。"
            showError = true
            return
        }
        let oldValue = point.deletedAt
        point.deletedAt = nil
        do {
            try modelContext.save()
        } catch {
            point.deletedAt = oldValue
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}

@MainActor
private struct PointCoordinateEditor: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    let task: TaskModel
    let point: MeasurePoint?

    @State private var name: String
    @State private var x: String
    @State private var y: String
    @State private var z: String
    @State private var showError = false
    @State private var errorMessage = ""

    init(task: TaskModel, point: MeasurePoint?) {
        self.task = task
        self.point = point
        _name = State(initialValue: point?.name ?? "")
        _x = State(initialValue: point.map { String($0.x) } ?? "")
        _y = State(initialValue: point.map { String($0.y) } ?? "")
        _z = State(initialValue: point.map { String($0.z) } ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("点位名称") {
                    TextField("名称", text: $name)
                }
                Section {
                    coordinateField("X（米）", text: $x)
                    coordinateField("Y（米）", text: $y)
                    if task.layoutMode == .volumetric {
                        coordinateField("Z（米）", text: $z)
                    }
                } header: {
                    Text("相对坐标")
                } footer: {
                    Text("支持负数和小数。修改仅调整位置标记，不改变已采集数据。")
                }
            }
            .navigationTitle(point == nil ? "添加点位" : "编辑点位")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                }
            }
            .alert("无法保存", isPresented: $showError) {
                Button("确定", role: .cancel) {}
            } message: {
                Text(errorMessage)
            }
        }
    }

    private func coordinateField(_ title: String, text: Binding<String>) -> some View {
        HStack {
            Text(title)
            TextField("请输入坐标", text: text)
                .keyboardType(.numbersAndPunctuation)
                .multilineTextAlignment(.trailing)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
        }
    }

    private func coordinate(_ text: String) -> Double? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "−", with: "-")
        guard let result = Double(value), result.isFinite else { return nil }
        return result
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, let newX = coordinate(x), let newY = coordinate(y),
              let newZ = task.layoutMode == .volumetric ? coordinate(z) : (point?.z ?? 0) else {
            errorMessage = "名称不能为空；每个坐标须为有效有限数字，可输入负数和小数。"
            showError = true
            return
        }
        if let point {
            let oldFields = (point.name, point.x, point.y, point.z)
            point.name = trimmedName
            point.x = newX
            point.y = newY
            point.z = newZ
            do {
                try modelContext.save()
                dismiss()
            } catch {
                (point.name, point.x, point.y, point.z) = oldFields
                errorMessage = error.localizedDescription
                showError = true
            }
        } else {
            let limit = task.layoutMode == .planar ? 6 : 8
            guard task.activePoints.count < limit else {
                errorMessage = "点位已达上限 \(limit) 个。"
                showError = true
                return
            }
            let draftContext = ModelContext(modelContext.container)
            draftContext.autosaveEnabled = false
            do {
                let taskID = task.id
                let descriptor = FetchDescriptor<TaskModel>(predicate: #Predicate { $0.id == taskID })
                guard let storedTask = try draftContext.fetch(descriptor).first else {
                    throw NSError(domain: "PointEditor", code: 1, userInfo: [NSLocalizedDescriptionKey: "任务尚未保存，请返回后重试。"])
                }
                guard storedTask.activePoints.count < limit else {
                    throw NSError(domain: "PointEditor", code: 2, userInfo: [NSLocalizedDescriptionKey: "点位已达上限 \(limit) 个。"])
                }
                let order = (storedTask.points.map(\.order).max() ?? 0) + 1
                let newPoint = MeasurePoint(order: order, name: trimmedName, x: newX, y: newY, z: newZ)
                draftContext.insert(newPoint)
                newPoint.task = storedTask
                try draftContext.save()
                if let savedPoint = modelContext.model(for: newPoint.persistentModelID) as? MeasurePoint,
                   !task.points.contains(where: { $0.id == savedPoint.id }) {
                    task.points.append(savedPoint)
                }
                dismiss()
            } catch {
                draftContext.rollback()
                errorMessage = error.localizedDescription
                showError = true
            }
        }
    }
}

@MainActor
struct PointRowView: View {
    let point: MeasurePoint
    @State private var validCount: Int?

    private var recordSignature: String {
        point.recordings.map { "\($0.id)|\($0.spectrumURL?.absoluteString ?? "")" }.sorted().joined(separator: ";")
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(point.name).font(.headline)
                Text(point.task?.layoutMode == .volumetric
                     ? String(format: "X %g · Y %g · Z %g m", point.x, point.y, point.z)
                     : String(format: "X %g · Y %g m", point.x, point.y))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("点击采集").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            if let validCount {
                VStack(alignment: .trailing, spacing: 4) {
                    Image(systemName: validCount > 0 ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(validCount > 0 ? Color.green : Color.secondary)
                    Text("已采集 \(validCount) 次").font(.caption2).foregroundStyle(.secondary)
                }
            } else {
                ProgressView().accessibilityLabel("检查已保存频谱")
            }
        }
        .task(id: recordSignature) {
            let urls = point.recordings.map(\.spectrumURL)
            let count = await Task.detached(priority: .utility) {
                urls.reduce(0) { result, url in
                    let spectrum = SavedSpectrumRead.load(url).spectrum
                    return result + (spectrum != nil && spectrum?.isComplete != false ? 1 : 0)
                }
            }.value
            guard !Task.isCancelled else { return }
            validCount = count
        }
    }
}

@MainActor
struct RecordingHistoryView: View {
    let point: MeasurePoint

    var body: some View {
        List {
            if point.deletedAt != nil {
                Text("此点位已删除，以下历史和文件仍保留，不参与当前任务分析。")
                    .font(.callout)
            }
            if point.recordings.isEmpty {
                ContentUnavailableView("暂无采集记录", systemImage: "waveform", description: Text("成功保存后可在此查看频谱和录音。"))
            } else {
                ForEach(point.recordings.sorted {
                    $0.timestamp == $1.timestamp ? $0.id.uuidString < $1.id.uuidString : $0.timestamp > $1.timestamp
                }) { recording in
                    NavigationLink(destination: RecordingDetailView(recording: recording)) {
                        RecordingHistoryRow(recording: recording)
                    }
                }
            }
        }
        .navigationTitle("\(point.name) · 历史")
    }
}

@MainActor
private struct RecordingHistoryRow: View {
    let recording: Recording
    @State private var summary: SavedSpectrumRead?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(recording.timestamp.formatted(date: .abbreviated, time: .standard)).font(.headline)
            Text(String(format: "%.2f 秒", summary?.spectrum.flatMap { data in
                data.sampleCount.map { Double($0) / Double(data.sampleRate) }
            } ?? Double(recording.durationMs) / 1000))
                .font(.caption)
            if let spectrum = summary?.spectrum {
                Text("\(String(format: "%.0f Hz", spectrum.sampleRate)) · \(spectrum.inputRoute ?? "输入路由未记录")")
                    .font(.caption).foregroundStyle(.secondary)
                if spectrum.isLegacy {
                    Text("旧版频谱 · 不参与比较").font(.caption).foregroundStyle(.orange)
                }
                if spectrum.isComplete == false {
                    Text("采集不完整 · 不参与比较").font(.caption).foregroundStyle(.orange)
                } else if spectrum.isComplete == nil {
                    Text("完成状态未记录").font(.caption).foregroundStyle(.secondary)
                }
            } else if let error = summary?.error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            Text(recording.resolvedAudioURL != nil ? "可播放已保存录音" : (recording.audioURL == nil ? "本次未保存录音" : "录音文件缺失"))
                .font(.caption).foregroundStyle(.secondary)
        }
        .task(id: recording.spectrumURL) {
            let url = recording.spectrumURL
            let loaded = await Task.detached(priority: .utility) { SavedSpectrumRead.load(url) }.value
            guard !Task.isCancelled else { return }
            summary = loaded
        }
    }
}

private struct SavedSpectrumRead: Sendable {
    let spectrum: SpectrumData?
    let error: String?

    static func load(_ url: URL?) -> SavedSpectrumRead {
        guard let url else { return SavedSpectrumRead(spectrum: nil, error: "未关联频谱文件") }
        do {
            return SavedSpectrumRead(spectrum: try SpectrumFiles.read(url), error: nil)
        } catch {
            return SavedSpectrumRead(spectrum: nil, error: "频谱读取失败：\(error.localizedDescription)")
        }
    }
}

@MainActor
struct RecordingDetailView: View {
    let recording: Recording
    @State private var spectrum: SpectrumData?
    @State private var loading = true
    @State private var loadError: String?
    @State private var displayBand = FrequencyBand.low.name
    @State private var player: AVAudioPlayer?
    @State private var playerDelegate = RecordingPlaybackDelegate()
    @State private var isPlaying = false
    @State private var position: TimeInterval = 0
    @State private var audioDuration: TimeInterval = 0
    @State private var seeking = false
    @State private var ownsAudioSession = false
    @State private var showError = false
    @State private var errorMessage = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(recording.timestamp.formatted(date: .abbreviated, time: .standard))
                    .font(.headline)
                if loading {
                    ProgressView("读取已保存频谱…").frame(maxWidth: .infinity, minHeight: 240)
                } else if let spectrum {
                    metadata(spectrum)
                    Text("本次平均频谱").font(.headline)
                    FrequencyBandPicker(selection: $displayBand)
                    SpectrumChartView(
                        series: [.init(name: "平均频谱", color: .blue, values: spectrum.averageSpectrum)],
                        frequencies: spectrum.frequencies,
                        band: .named(displayBand)
                    )
                    .frame(height: 390)
                    Text("电平为数字参考值 dBFS，不是校准声压级。低频仍受 FFT 分辨能力及手机麦克风限制。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ContentUnavailableView("无法读取频谱", systemImage: "exclamationmark.triangle", description: Text(loadError ?? "文件不可用"))
                    Text(String(format: "记录时长 %.2f 秒", Double(recording.durationMs) / 1000))
                }
                audioControls
            }
            .padding()
        }
        .navigationTitle("采集记录")
        .task(id: recording.id) {
            loading = true
            let url = recording.spectrumURL
            let loaded = await Task.detached(priority: .utility) { SavedSpectrumRead.load(url) }.value
            guard !Task.isCancelled else { return }
            spectrum = loaded.spectrum
            loadError = loaded.error
            loading = false
        }
        .task(id: isPlaying) {
            guard isPlaying else { return }
            while !Task.isCancelled && isPlaying {
                if !seeking { position = player?.currentTime ?? position }
                do { try await Task.sleep(nanoseconds: 150_000_000) } catch { return }
            }
        }
        .onAppear {
            playerDelegate.onFinish = { success in
                isPlaying = false
                position = audioDuration
                releaseAudioSession()
                if !success { playbackError("录音未能完整播放。") }
            }
            playerDelegate.onFailure = { message in
                stopPlayback()
                playbackError(message)
            }
        }
        .onDisappear {
            stopPlayback()
            playerDelegate.onFinish = nil
            playerDelegate.onFailure = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { notification in
            let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            if raw == AVAudioSession.InterruptionType.began.rawValue && isPlaying {
                pausePlayback()
                playbackError("播放被系统中断，可稍后手动继续。")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { notification in
            let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            if reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue && isPlaying {
                pausePlayback()
                playbackError("音频输出设备已断开，播放已暂停。")
            }
        }
        .alert("录音播放", isPresented: $showError) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }

    private func metadata(_ data: SpectrumData) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("有效时长", value: String(format: "%.2f 秒", data.sampleCount.map { Double($0) / Double(data.sampleRate) } ?? Double(recording.durationMs) / 1000))
            LabeledContent("采样率", value: String(format: "%.0f Hz", data.sampleRate))
            LabeledContent("FFT / 分辨率", value: "\(data.fftSize) / \(String(format: "%.2f Hz", data.binWidth))")
            LabeledContent("输入路由", value: data.inputRoute ?? "未记录")
            LabeledContent("算法版本", value: data.algorithmVersion ?? "旧版，未记录")
            if data.isLegacy {
                Text("旧版频谱：原计算口径保留，仅供查看，不与新版混合比较。")
                    .foregroundStyle(.orange)
            }
            if data.isComplete == false {
                Text("采集不完整：\(data.endReason ?? "提前中断")，不参与多点比较。")
                    .foregroundStyle(.orange)
            } else if !data.isComparable {
                Text("采集参数或完成状态不足，不参与多点比较。")
                    .foregroundStyle(.orange)
            }
            if recording.isClipped { Text("检测到削波，电平可能失真。") .foregroundStyle(.orange) }
            if recording.isLowSNR { Text("信号电平偏低；此标记不代表已测量信噪比。") .foregroundStyle(.orange) }
        }
        .font(.callout)
    }

    @ViewBuilder
    private var audioControls: some View {
        if recording.resolvedAudioURL != nil {
            VStack(alignment: .leading, spacing: 10) {
                Text("已保存录音").font(.headline)
                Button {
                    isPlaying ? pausePlayback() : startPlayback()
                } label: {
                    Label(isPlaying ? "暂停" : "播放", systemImage: isPlaying ? "pause.fill" : "play.fill")
                }
                .buttonStyle(.borderedProminent)
                Slider(value: $position, in: 0...max(audioDuration, 0.01)) { editing in
                    seeking = editing
                    if !editing { player?.currentTime = position }
                }
                .disabled(player == nil)
                .accessibilityLabel("播放进度")
                Text(String(format: "%.1f / %.1f 秒", position, audioDuration))
                    .font(.caption).monospacedDigit()
            }
        } else {
            Text(recording.audioURL == nil ? "本次未保存录音；频谱仍可独立查看。" : "录音文件缺失或不可访问；频谱仍可独立查看。")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private func startPlayback() {
        do {
            guard let url = recording.resolvedAudioURL else {
                throw NSError(domain: "RecordingPlayback", code: 1, userInfo: [NSLocalizedDescriptionKey: "录音文件不存在。"])
            }
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
            ownsAudioSession = true
            if player == nil {
                let newPlayer = try AVAudioPlayer(contentsOf: url)
                newPlayer.delegate = playerDelegate
                guard newPlayer.prepareToPlay(), newPlayer.duration.isFinite, newPlayer.duration > 0 else {
                    throw NSError(domain: "RecordingPlayback", code: 2, userInfo: [NSLocalizedDescriptionKey: "录音格式不可播放或时长无效。"])
                }
                player = newPlayer
                audioDuration = newPlayer.duration
            }
            if position >= audioDuration { position = 0 }
            player?.currentTime = position
            guard player?.play() == true else {
                throw NSError(domain: "RecordingPlayback", code: 3, userInfo: [NSLocalizedDescriptionKey: "无法开始播放录音。"])
            }
            isPlaying = true
        } catch {
            stopPlayback()
            playbackError(error.localizedDescription)
        }
    }

    private func pausePlayback() {
        player?.pause()
        position = player?.currentTime ?? position
        isPlaying = false
        releaseAudioSession()
    }

    private func stopPlayback() {
        player?.stop()
        player = nil
        isPlaying = false
        position = 0
        releaseAudioSession()
    }

    private func releaseAudioSession() {
        guard ownsAudioSession else { return }
        ownsAudioSession = false
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            playbackError("释放音频会话失败：\(error.localizedDescription)")
        }
    }

    private func playbackError(_ message: String) {
        errorMessage = message
        showError = true
    }
}

@MainActor
private final class RecordingPlaybackDelegate: NSObject, AVAudioPlayerDelegate {
    var onFinish: ((Bool) -> Void)?
    var onFailure: ((String) -> Void)?

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in self?.onFinish?(flag) }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let message = error?.localizedDescription ?? "录音解码失败。"
        Task { @MainActor [weak self] in self?.onFailure?(message) }
    }
}
