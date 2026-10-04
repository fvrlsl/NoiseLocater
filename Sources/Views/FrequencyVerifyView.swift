import SwiftUI

/// 音频生成验证页
struct FrequencyVerifyView: View {
    let frequencies: [SuspiciousFrequency]

    @State private var generator = AudioGenerator()
    @State private var selectedFreq: Float = 0
    @State private var isConfigured = false
    @State private var sweepStart: Float = 20
    @State private var sweepEnd: Float = 250
    @State private var isPlaying = false
    @State private var results: [VerificationResult] = []
    @AppStorage("genVolume") private var genVolume = -20.0
    @AppStorage("genDuration") private var genDuration = 3.0

    var body: some View {
        Form {
            Section("批量验证") {
                ForEach(frequencies.prefix(5)) { freq in
                    HStack {
                        Button {
                            selectedFreq = freq.freq
                            playTone(freq.freq)
                        } label: {
                            Text(freq.freqLabel)
                                .foregroundColor(.blue)
                        }

                        Spacer()

                        // 确认按钮
                        HStack(spacing: 8) {
                            verifyButton(.yes, for: freq)
                            verifyButton(.no, for: freq)
                            verifyButton(.close, for: freq)
                        }
                    }
                }
            }

            Section("当前播放") {
                if selectedFreq > 0 {
                    Text("正在播放: \(String(format: "%.1f", selectedFreq)) Hz")
                } else {
                    Text("未播放")
                        .foregroundColor(.secondary)
                }
                Button(isPlaying ? "停止" : "播放") {
                    if isPlaying {
                        generator.stop()
                    } else {
                        try? generator.play()
                    }
                    isPlaying.toggle()
                }
            }

            Section("扫频") {
                HStack {
                    Text("起始")
                    TextField("F1", value: $sweepStart, format: .number)
                        .keyboardType(.decimalPad)
                    Text("Hz")
                }
                HStack {
                    Text("终止")
                    TextField("F2", value: $sweepEnd, format: .number)
                        .keyboardType(.decimalPad)
                    Text("Hz")
                }
                Button("播放扫频") {
                    playSweep()
                }
            }

            Section("验证记录") {
                if results.isEmpty {
                    Text("暂无")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(results) { r in
                        HStack {
                            Text(String(format: "%.1f Hz", r.frequency))
                            Spacer()
                            Text(r.status.label)
                                .foregroundColor(r.status.color)
                        }
                    }
                }
            }
        }
        .navigationTitle("音频验证")
        .onAppear { configureGenerator() }
    }

    private func verifyButton(_ status: VerificationStatus, for freq: SuspiciousFrequency) -> some View {
        Button(status.label) {
            results.append(VerificationResult(
                frequency: freq.freq,
                status: status,
                timestamp: Date()
            ))
        }
        .buttonStyle(.bordered)
        .tint(status.tint)
    }

    private func configureGenerator() {
        do {
            try generator.configure()
            isConfigured = true
        } catch {
            print("Generator config failed: \(error)")
        }
    }

    private func playTone(_ freq: Float) {
        guard isConfigured else { return }
        generator.stop()
        generator.generateTone(frequency: freq, duration: genDuration, volumeDB: Float(genVolume))
        try? generator.play()
        isPlaying = true
    }

    private func playSweep() {
        guard isConfigured else { return }
        generator.stop()
        generator.generateSweep(
            startFreq: sweepStart,
            endFreq: sweepEnd,
            duration: 5,
            volumeDB: Float(genVolume)
        )
        try? generator.play()
        isPlaying = true
    }
}

// MARK: - 验证结果模型

enum VerificationStatus: String {
    case yes = "就是"
    case no = "不是"
    case close = "接近"

    var label: String {
        switch self {
        case .yes: return "✅ 就是"
        case .no: return "❌ 不是"
        case .close: return "🟡 接近"
        }
    }

    var color: Color {
        switch self {
        case .yes: return .green
        case .no: return .red
        case .close: return .yellow
        }
    }

    var tint: Color {
        switch self {
        case .yes: return .green
        case .no: return .red
        case .close: return .yellow
        }
    }
}

struct VerificationResult: Identifiable {
    let id = UUID()
    let frequency: Float
    let status: VerificationStatus
    let timestamp: Date
}
