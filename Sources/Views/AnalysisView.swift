import SwiftUI
import SwiftData

@MainActor
struct AnalysisView: View {
    let task: TaskModel

    @AppStorage("anomalyThreshold") private var anomalyThreshold = 6.0
    @AppStorage("showHarmonics") private var showHarmonics = true
    @State private var result: InspectionResult?
    @State private var isLoading = true
    @State private var displayBand = FrequencyBand.low.name
    @State private var selectedFrequency: Float?
    @State private var generation = UUID()
    @State private var refreshID = UUID()

    private let colors: [Color] = [.blue, .orange, .purple, .green, .pink, .teal, .indigo, .red]

    private var analysisID: String {
        let points = task.activePoints.map { point in
            let records = point.recordings.map {
                "\($0.id)|\($0.timestamp.timeIntervalSince1970)|\($0.spectrumURL?.absoluteString ?? "")"
            }.sorted().joined(separator: ",")
            return "\(point.id)|\(point.name)|\(point.order)|\(records)"
        }.joined(separator: ";")
        return "\(task.id)|\(task.bandModeRaw)|\(task.selectedBands.joined(separator: ","))|\(anomalyThreshold)|\(refreshID)|\(points)"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("排查辅助，不是声源定位")
                    .font(.headline)
                Text("各点依次采集，差异可能来自噪声随时间变化。请保持手机朝向、高度和输入设备一致；仅凭频谱强弱不能推断方向，也不能确认同一声源或具体设备。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if isLoading {
                    ProgressView("读取频谱并筛选可比记录…")
                        .frame(maxWidth: .infinity, minHeight: 200)
                } else if let result {
                    resultContent(result)
                }
            }
            .padding()
        }
        .navigationTitle("排查结果")
        .toolbar {
            Button("重新分析") { refreshID = UUID() }
                .disabled(isLoading)
        }
        .task(id: analysisID) { await runAnalysis() }
        .onDisappear { generation = UUID() }
    }

    @ViewBuilder
    private func resultContent(_ result: InspectionResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("可比点位 \(result.points.count) / \(result.totalPoints)").font(.title3.bold())
            Text("参与分析：\(result.bandTitles.isEmpty ? "未选择有效频段" : result.bandTitles.joined(separator: "、")) · 阈值 \(String(format: "%.1f dB", result.threshold))")
                .font(.caption)
            Text("按相同算法、采样率、FFT 和输入路由选择覆盖点位最多的一组；同分选择较新组，每点采用该组内最新有效记录。")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(result.notices, id: \.self) { notice in
                Text(notice).font(.caption).foregroundStyle(.orange)
            }
        }
        if result.points.count >= 3 {
            VStack(alignment: .leading, spacing: 10) {
                Text("可比点位频谱叠加").font(.headline)
                Text("显示范围只缩放图表，不改变参与分析的频段。")
                    .font(.caption).foregroundStyle(.secondary)
                FrequencyBandPicker(selection: $displayBand)
                SpectrumChartView(
                    series: result.points.enumerated().map { index, point in
                        .init(name: point.label, color: colors[index % colors.count], values: Array(point.spectrum.averageSpectrum.prefix(result.commonCount)))
                    },
                    frequencies: Array((result.points.first?.spectrum.frequencies ?? []).prefix(result.commonCount)),
                    highlightedFreqs: selectedFrequency.map { [$0] } ?? result.candidates.map(\.frequency),
                    band: .named(displayBand)
                )
                .frame(height: 410)
                Text("所有曲线共用 −100…0 dBFS 量程，dBFS 不是校准声压级。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if result.candidates.isEmpty {
                ContentUnavailableView("当前条件下未发现候选频率", systemImage: "waveform.path", description: Text("所选频段内未发现超过阈值的跨点差异。这不代表没有噪声，也不能据此判断方向。"))
            } else {
                Text("候选频率（\(result.candidates.count)）").font(.headline)
                ForEach(result.candidates) { candidate in
                    candidateCard(candidate, points: result.points)
                }
            }
        } else {
            ContentUnavailableView("不足 3 个有效可比点位", systemImage: "exclamationmark.triangle", description: Text("未执行多点差异检测。可查看下面的单点频谱及历史记录，当前证据不足，不能推断方向。"))
            if !result.points.isEmpty {
                FrequencyBandPicker(selection: $displayBand)
                ForEach(result.points) { point in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(point.label).font(.headline)
                        SpectrumChartView(
                            series: [.init(name: point.label, color: .blue, values: point.spectrum.averageSpectrum)],
                            frequencies: point.spectrum.frequencies,
                            band: .named(displayBand)
                        )
                        .frame(height: 350)
                    }
                }
            }
        }
        if !result.points.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("本次采用的记录").font(.headline)
                ForEach(result.points) { point in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(point.label).font(.subheadline.bold())
                        Text(point.timestamp.formatted(date: .abbreviated, time: .standard))
                        Text("\(String(format: "%.0f Hz", point.spectrum.sampleRate)) · FFT \(point.spectrum.fftSize) · \(point.spectrum.inputRoute ?? "未知路由")")
                        if !point.note.isEmpty { Text(point.note).foregroundStyle(.orange) }
                        if let model = task.activePoints.first(where: { $0.id == point.id }),
                           let recording = model.recordings.first(where: { $0.id == point.recordingID }) {
                            NavigationLink("查看这次记录", destination: RecordingDetailView(recording: recording))
                        }
                    }
                    .font(.caption)
                }
            }
        }
        if !result.excluded.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("未纳入比较的点位").font(.headline)
                ForEach(result.excluded) { point in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(point.name).font(.subheadline.bold())
                        Text(point.reason).font(.caption).foregroundStyle(.secondary)
                        if let model = task.activePoints.first(where: { $0.id == point.id }) {
                            NavigationLink("查看点位历史", destination: RecordingHistoryView(point: model))
                                .font(.caption)
                        }
                    }
                }
            }
        }
    }

    private func candidateCard(_ candidate: InspectionCandidate, points: [InspectionPoint]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                selectedFrequency = candidate.frequency
                if !FrequencyBand.named(displayBand).contains(candidate.frequency) {
                    displayBand = candidate.band
                }
            } label: {
                HStack {
                    Text(String(format: "%.0f Hz", candidate.frequency)).font(.headline)
                    Text(FrequencyBand.named(candidate.band).title).font(.caption)
                    Spacer()
                    Text(String(format: "跨点差 %.1f dB", candidate.range)).font(.caption)
                }
                .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
            if let strongest = candidate.values.max() {
                let names = points.indices.filter {
                    candidate.values.indices.contains($0) && candidate.values[$0] == strongest
                }.map { points[$0].label }.joined(separator: "、")
                Text("该频率在 \(names) 更强；这不表示其更靠近声源。")
                    .font(.callout)
            }
            ForEach(Array(points.enumerated()), id: \.element.id) { index, point in
                if candidate.values.indices.contains(index), let minimum = candidate.values.min() {
                    HStack(alignment: .firstTextBaseline) {
                        Text(point.label)
                            .foregroundStyle(colors[index % colors.count])
                        Spacer()
                        VStack(alignment: .trailing) {
                            Text(String(format: "%.1f dBFS", candidate.values[index]))
                            Text(String(format: "相对最弱 +%.1f dB", candidate.values[index] - minimum))
                                .foregroundStyle(.secondary)
                        }
                        .monospacedDigit()
                    }
                    .font(.caption)
                }
            }
            if showHarmonics && !candidate.harmonics.isEmpty {
                Text("存在近似整数倍频率：\(candidate.harmonics.map { String(format: "%.0f Hz", $0) }.joined(separator: "、"))；仅是频谱关系，不代表已确认同一设备。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(selectedFrequency == candidate.frequency ? Color.accentColor : Color.clear, lineWidth: 2)
        }
    }

    private func runAnalysis() async {
        let token = UUID()
        generation = token
        isLoading = true
        let snapshot = InspectionSnapshot(
            points: task.activePoints.map { point in
                InspectionPointInput(
                    id: point.id,
                    name: point.name,
                    order: point.order,
                    recordings: point.recordings.map {
                        InspectionRecordingInput(id: $0.id, timestamp: $0.timestamp, spectrumURL: $0.spectrumURL)
                    }.sorted {
                        $0.timestamp == $1.timestamp ? $0.id.uuidString < $1.id.uuidString : $0.timestamp > $1.timestamp
                    }
                )
            },
            bandNames: task.selectedBands,
            singleBand: task.bandMode == .single,
            threshold: anomalyThreshold
        )
        let worker = Task.detached(priority: .userInitiated) { InspectionEngine.run(snapshot) }
        let output = await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
        guard !Task.isCancelled, generation == token else { return }
        result = output
        selectedFrequency = output.candidates.first?.frequency
        isLoading = false
    }
}

private extension FrequencyBand {
    func contains(_ frequency: Float) -> Bool { frequency >= minHz && frequency <= maxHz }
}

private struct InspectionRecordingInput: Sendable {
    let id: UUID
    let timestamp: Date
    let spectrumURL: URL?
}

private struct InspectionPointInput: Sendable {
    let id: UUID
    let name: String
    let order: Int
    let recordings: [InspectionRecordingInput]
}

private struct InspectionSnapshot: Sendable {
    let points: [InspectionPointInput]
    let bandNames: [String]
    let singleBand: Bool
    let threshold: Double
}

private struct InspectionPoint: Identifiable, Sendable {
    let id: UUID
    let name: String
    let recordingID: UUID
    let timestamp: Date
    let spectrum: SpectrumData
    var note: String = ""
    var label: String { "\(name) · \(id.uuidString.prefix(4))" }
}

private struct InspectionExclusion: Identifiable, Sendable {
    let id: UUID
    let name: String
    let reason: String
}

private struct InspectionCandidate: Identifiable, Sendable {
    var id: Float { frequency }
    let frequency: Float
    let band: String
    let range: Float
    let values: [Float]
    let harmonics: [Float]
}

private struct InspectionResult: Sendable {
    var points: [InspectionPoint] = []
    var excluded: [InspectionExclusion] = []
    var candidates: [InspectionCandidate] = []
    var commonCount = 0
    var totalPoints = 0
    var threshold: Float = 6
    var bandTitles: [String] = []
    var notices: [String] = []
}

private enum InspectionEngine {
    static func run(_ snapshot: InspectionSnapshot) -> InspectionResult {
        var output = InspectionResult()
        output.totalPoints = snapshot.points.count
        let threshold = Float(snapshot.threshold)
        output.threshold = threshold.isFinite && threshold >= 0 ? threshold : 6
        if output.threshold != threshold { output.notices.append("设置中的阈值无效，本次采用 6 dB。") }
        var names: [String] = []
        for name in snapshot.bandNames where FrequencyBand.all.contains(where: { $0.name == name }) && !names.contains(name) {
            names.append(name)
        }
        if snapshot.singleBand { names = Array(names.prefix(1)) }
        let bands = names.map { FrequencyBand.named($0) }
        output.bandTitles = bands.map(\.title)
        if names.isEmpty { output.notices.append("任务没有选择有效分析频段，未进行候选检测。") }
        if snapshot.bandNames.contains(where: { name in !FrequencyBand.all.contains(where: { $0.name == name }) }) {
            output.notices.append("任务中无法识别的频段已排除，未自动替换。")
        }

        var groups: [String: [UUID: InspectionPoint]] = [:]
        var issues: [UUID: [UUID: String]] = [:]
        var recordKeys: [UUID: String] = [:]
        for point in snapshot.points {
            if Task.isCancelled { return output }
            for recording in point.recordings {
                if Task.isCancelled { return output }
                do {
                    guard let url = recording.spectrumURL else { throw RecordingError.missingSpectrum }
                    let spectrum = try SpectrumFiles.read(url)
                    guard spectrum.isComparable else {
                        issues[point.id, default: [:]][recording.id] = exclusionReason(spectrum)
                        continue
                    }
                    let key = spectrum.compatibilityKey
                    recordKeys[recording.id] = key
                    if groups[key]?[point.id] == nil {
                        groups[key, default: [:]][point.id] = InspectionPoint(
                            id: point.id, name: point.name, recordingID: recording.id,
                            timestamp: recording.timestamp, spectrum: spectrum
                        )
                    }
                } catch {
                    issues[point.id, default: [:]][recording.id] = "频谱缺失或不可读：\(error.localizedDescription)"
                }
            }
        }

        let rankedKeys = groups.keys.sorted { lhs, rhs in
            let left = Array(groups[lhs, default: [:]].values)
            let right = Array(groups[rhs, default: [:]].values)
            if left.count != right.count { return left.count > right.count }
            let leftDates = left.map(\.timestamp).sorted(by: >)
            let rightDates = right.map(\.timestamp).sorted(by: >)
            for (a, b) in zip(leftDates, rightDates) where a != b { return a > b }
            return lhs < rhs
        }
        let chosenKey = rankedKeys.first
        let chosen = chosenKey.flatMap { groups[$0] } ?? [:]
        for point in snapshot.points {
            if var selection = chosen[point.id] {
                let newer = point.recordings.prefix { $0.id != selection.recordingID }
                if !newer.isEmpty {
                    let reasons = Set(newer.map { recording in
                        issues[point.id]?[recording.id] ?? "采样率、FFT、路由或算法口径不属于本组"
                    }).sorted()
                    selection.note = "已跳过 \(newer.count) 条更新记录：\(reasons.joined(separator: "；"))。"
                }
                output.points.append(selection)
            } else {
                var reasons = Set(issues[point.id, default: [:]].values)
                if point.recordings.contains(where: { recordKeys[$0.id] != nil }) {
                    reasons.insert("有效记录的采样率、FFT、输入路由或算法口径与所选最大可比组不同")
                }
                let reason = point.recordings.isEmpty ? "尚无采集记录" : reasons.sorted().joined(separator: "；")
                output.excluded.append(InspectionExclusion(id: point.id, name: point.name, reason: reason))
            }
        }
        output.commonCount = output.points.map { $0.spectrum.averageSpectrum.count }.min() ?? 0
        if Set(output.points.map { $0.spectrum.averageSpectrum.count }).count > 1 {
            output.notices.append("同组记录的 Nyquist 端点长度不同，仅比较共同频率格点；不插值、不补缺测值。")
        }
        if let first = output.points.first, output.commonCount > 0 {
            let upper = Float(output.commonCount - 1) * first.spectrum.binWidth
            for band in bands where band.maxHz > upper {
                output.notices.append(band.minHz > upper
                    ? "\(band.title)超出本组记录的实际频率范围，未检测此频段。"
                    : "\(band.title)仅检测至 \(String(format: "%.0f Hz", upper))，不超过实际 Nyquist 范围。")
            }
        }
        guard output.points.count >= 3, let first = output.points.first, !bands.isEmpty, !Task.isCancelled else { return output }
        let spectra = output.points.map { Array($0.spectrum.averageSpectrum.prefix(output.commonCount)) }
        let detector = AnomalyDetector()
        detector.threshold = output.threshold
        var bandResults: [String: [SuspiciousFrequency]] = [:]
        for band in bands {
            if Task.isCancelled { return output }
            bandResults[band.name] = detector.detectBand(pointSpectra: spectra, band: band, binWidth: first.spectrum.binWidth)
        }
        let harmonics = detector.detectHarmonics(frequencies: bands.flatMap { bandResults[$0.name] ?? [] })
        for band in bands {
            bandResults[band.name] = (bandResults[band.name] ?? []).map { candidate in
                var updated = candidate
                updated.harmonics = harmonics[candidate.freq] ?? []
                return updated
            }
        }
        output.candidates = detector.globalRanking(bandResults: bandResults, binWidth: first.spectrum.binWidth).map {
            InspectionCandidate(frequency: $0.freq, band: $0.band, range: $0.range, values: $0.dbValues, harmonics: $0.harmonics)
        }
        return output
    }

    private static func exclusionReason(_ spectrum: SpectrumData) -> String {
        if spectrum.isLegacy { return "旧版算法频谱，仅供单点查看" }
        if spectrum.isComplete == false { return "采集不完整，不参与比较" }
        if spectrum.formatVersion != 2 { return "频谱格式版本不支持比较" }
        if spectrum.isComplete != true { return "未记录完整采集状态" }
        if (spectrum.inputRoute ?? "").isEmpty { return "缺少输入路由参数" }
        if (spectrum.sampleCount ?? 0) < spectrum.fftSize { return "有效样本信息不足" }
        return "频谱数据不满足可比性要求"
    }
}
