import SwiftUI

struct FrequencyBandPicker: View {
    @Binding var selection: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(FrequencyBand.all, id: \.name) { band in
                    Button {
                        selection = band.name
                    } label: {
                        VStack(spacing: 3) {
                            Text(band.title).font(.subheadline.weight(.semibold))
                            Text("\(Int(band.minHz))–\(Int(band.maxHz)) Hz").font(.caption2)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .foregroundStyle(selection == band.name ? Color.white : Color.primary)
                        .background(selection == band.name ? Color.accentColor : Color(uiColor: .secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(band.title)，\(Int(band.minHz)) 至 \(Int(band.maxHz)) 赫兹，\(band.isLinear ? "线性" : "对数")坐标")
                    .accessibilityAddTraits(selection == band.name ? .isSelected : [])
                }
            }
        }
    }
}

struct SpectrumChartView: View {
    struct Series: Identifiable {
        var id: String { name }
        let name: String
        let color: Color
        let values: [Float]
    }

    let series: [Series]
    let frequencies: [Float]
    var highlightedFreqs: [Float] = []
    var band: FrequencyBand = .low

    @Environment(\.displayScale) private var displayScale
    @AppStorage("showRefLines") private var showRefLines = true
    @State private var selectedFrequency: Float?

    init(series: [Series], frequencies: [Float], highlightedFreqs: [Float] = [], band: FrequencyBand = .low) {
        self.series = series
        self.frequencies = frequencies
        self.highlightedFreqs = highlightedFreqs
        self.band = band
    }

    private var axisIsValid: Bool {
        !frequencies.isEmpty && frequencies.allSatisfy { $0.isFinite && $0 >= 0 } &&
        zip(frequencies, frequencies.dropFirst()).allSatisfy { $0.0 < $0.1 }
    }

    private var validSeries: [Series] {
        guard axisIsValid else { return [] }
        return series.filter {
            $0.values.count == frequencies.count && $0.values.allSatisfy(\.isFinite)
        }
    }

    private var displayedRange: ClosedRange<Float>? {
        guard axisIsValid, let last = frequencies.last else { return nil }
        let upper = min(band.maxHz, last)
        guard upper > band.minHz else { return nil }
        return band.minHz...upper
    }

    private var visibleIndices: [Int] {
        guard let range = displayedRange else { return [] }
        return frequencies.indices.filter { range.contains(frequencies[$0]) }
    }

    private var selectedIndex: Int? {
        guard let frequency = selectedFrequency else { return nil }
        return visibleIndices.min { abs(frequencies[$0] - frequency) < abs(frequencies[$1] - frequency) }
    }

    var body: some View {
        let curves = validSeries
        let indices = visibleIndices
        VStack(alignment: .leading, spacing: 8) {
            if !curves.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(curves) { curve in
                            Label {
                                Text(curve.name)
                            } icon: {
                                Capsule().fill(curve.color).frame(width: 16, height: 4)
                            }
                            .font(.caption)
                        }
                    }
                }
            }
            GeometryReader { geometry in
                let plot = CGRect(x: 43, y: 24, width: max(1, geometry.size.width - 57), height: max(1, geometry.size.height - 56))
                ZStack {
                    Color(uiColor: .secondarySystemBackground)
                    if let range = displayedRange, !curves.isEmpty, !indices.isEmpty {
                        Canvas { context, _ in
                            drawGrid(context, plot: plot, range: range)
                            drawHighlights(context, plot: plot, range: range)
                            for curve in curves {
                                drawCurve(curve, context: context, plot: plot, range: range, indices: indices)
                                drawPeak(curve, context: context, plot: plot, range: range, indices: indices, showLabel: curves.count == 1)
                            }
                            if let index = selectedIndex {
                                drawSelection(index, curves: curves, context: context, plot: plot, range: range)
                            }
                        }
                        .contentShape(Rectangle())
                        .gesture(SpatialTapGesture().onEnded { event in
                            select(at: event.location, plot: plot, range: range)
                        })
                        .simultaneousGesture(DragGesture(minimumDistance: 12).onChanged { event in
                            guard abs(event.translation.width) > abs(event.translation.height) else { return }
                            select(at: event.location, plot: plot, range: range)
                        })
                    } else {
                        VStack(spacing: 10) {
                            Image(systemName: "waveform.path").font(.largeTitle)
                            Text("此范围暂无可显示频谱").font(.headline)
                            Text("等待采集，或选择其他显示范围。\n频率上限不超过数据实际覆盖范围。")
                                .font(.caption)
                                .multilineTextAlignment(.center)
                        }
                        .foregroundStyle(Color.primary)
                        .padding()
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .frame(minHeight: 160)
            .accessibilityLabel("\(band.title)频谱，\(band.isLinear ? "线性" : "对数")频率轴，电平范围负一百至零 dBFS")
            if let index = selectedIndex, !curves.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        Text("选点 \(frequencyLabel(frequencies[index]))").fontWeight(.semibold)
                        ForEach(curves) { curve in
                            Text("\(curve.name) \(String(format: "%.1f dBFS", curve.values[index]))")
                                .foregroundStyle(curve.color)
                        }
                    }
                    .font(.caption)
                    .monospacedDigit()
                }
            } else if !indices.isEmpty, !curves.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(curves) { curve in
                            if let index = indices.max(by: { curve.values[$0] < curve.values[$1] }) {
                                Text("\(curve.name) 主峰 \(frequencyLabel(frequencies[index])) · \(String(format: "%.1f dBFS", curve.values[index]))")
                                    .foregroundStyle(curve.color)
                            }
                        }
                    }
                    .font(.caption)
                }
            }
            Text("\(band.isLinear ? "线性" : "对数")横轴 · 点击/横向拖动读数 · 超量程仅裁剪显示")
                .font(.caption2)
                .foregroundStyle(.secondary)
            if curves.count < series.count {
                Text("部分曲线的频率轴或数据不完整，未绘制。")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .onChange(of: band.name) { _, _ in selectedFrequency = nil }
        .onChange(of: frequencies.count) { _, _ in selectedFrequency = nil }
    }

    private func x(_ frequency: Float, plot: CGRect, range: ClosedRange<Float>) -> CGFloat {
        let value: Float
        if band.isLinear {
            value = (frequency - range.lowerBound) / (range.upperBound - range.lowerBound)
        } else {
            value = log10(max(frequency, range.lowerBound) / range.lowerBound) / log10(range.upperBound / range.lowerBound)
        }
        return plot.minX + CGFloat(value) * plot.width
    }

    private func y(_ db: Float, plot: CGRect) -> CGFloat {
        plot.minY + CGFloat(-min(0, max(-100, db)) / 100) * plot.height
    }

    private func select(at location: CGPoint, plot: CGRect, range: ClosedRange<Float>) {
        guard plot.contains(location) else { return }
        let fraction = Float((location.x - plot.minX) / plot.width)
        selectedFrequency = band.isLinear
            ? range.lowerBound + fraction * (range.upperBound - range.lowerBound)
            : range.lowerBound * pow(range.upperBound / range.lowerBound, fraction)
    }

    private func ticks(range: ClosedRange<Float>, width: CGFloat) -> [Float] {
        let candidates: [Float] = band.isLinear
            ? [20, 50, 100, 150, 200, 250, 300, 400, 500]
            : [20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000]
        let plot = CGRect(x: 0, y: 0, width: width, height: 1)
        var result = [range.lowerBound]
        for tick in candidates where tick > range.lowerBound && tick < range.upperBound {
            if let previous = result.last,
               x(tick, plot: plot, range: range) - x(previous, plot: plot, range: range) >= 43,
               width - x(tick, plot: plot, range: range) >= 43 {
                result.append(tick)
            }
        }
        if width > 55 { result.append(range.upperBound) }
        return result
    }

    private func drawGrid(_ context: GraphicsContext, plot: CGRect, range: ClosedRange<Float>) {
        context.draw(Text("dBFS").font(.caption2).foregroundColor(.primary), at: CGPoint(x: plot.minX, y: 9), anchor: .leading)
        for db in stride(from: -100, through: 0, by: 20) {
            let position = y(Float(db), plot: plot)
            var line = Path()
            line.move(to: CGPoint(x: plot.minX, y: position))
            line.addLine(to: CGPoint(x: plot.maxX, y: position))
            context.stroke(line, with: .color(.primary.opacity(0.14)), lineWidth: 0.5)
            context.draw(Text("\(db)").font(.caption2).foregroundColor(.primary), at: CGPoint(x: plot.minX - 6, y: position), anchor: .trailing)
        }
        for frequency in ticks(range: range, width: plot.width) {
            let position = x(frequency, plot: plot, range: range)
            var line = Path()
            line.move(to: CGPoint(x: position, y: plot.minY))
            line.addLine(to: CGPoint(x: position, y: plot.maxY))
            context.stroke(line, with: .color(.primary.opacity(0.12)), lineWidth: 0.5)
            let anchor: UnitPoint = frequency == range.lowerBound ? .topLeading : (frequency == range.upperBound ? .topTrailing : .top)
            context.draw(Text(frequencyLabel(frequency)).font(.caption2).foregroundColor(.primary), at: CGPoint(x: position, y: plot.maxY + 7), anchor: anchor)
        }
    }

    private func drawCurve(_ curve: Series, context: GraphicsContext, plot: CGRect, range: ClosedRange<Float>, indices: [Int]) {
        var peaks: [Int] = []
        var bucket = -1
        for index in indices {
            let pixel = Int(((x(frequencies[index], plot: plot, range: range) - plot.minX) * displayScale).rounded(.down))
            if pixel == bucket, let previous = peaks.last {
                if curve.values[index] > curve.values[previous] { peaks[peaks.count - 1] = index }
            } else {
                peaks.append(index)
                bucket = pixel
            }
        }
        var path = Path()
        for (position, index) in peaks.enumerated() {
            let point = CGPoint(x: x(frequencies[index], plot: plot, range: range), y: y(curve.values[index], plot: plot))
            if position == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        var clipped = context
        clipped.clip(to: Path(plot.insetBy(dx: -1, dy: -1)))
        clipped.stroke(path, with: .color(curve.color), lineWidth: 1.6)
    }

    private func drawHighlights(_ context: GraphicsContext, plot: CGRect, range: ClosedRange<Float>) {
        if showRefLines && band.isLinear {
            for frequency in [Float(50), 60, 100, 150, 200] where range.contains(frequency) {
                let position = x(frequency, plot: plot, range: range)
                var reference = Path()
                reference.move(to: CGPoint(x: position, y: plot.minY))
                reference.addLine(to: CGPoint(x: position, y: plot.maxY))
                context.stroke(reference, with: .color(.secondary.opacity(0.35)),
                               style: StrokeStyle(lineWidth: 0.8, dash: [2, 4]))
            }
        }
        for frequency in highlightedFreqs where frequency.isFinite && range.contains(frequency) {
            let position = x(frequency, plot: plot, range: range)
            var line = Path()
            line.move(to: CGPoint(x: position, y: plot.minY))
            line.addLine(to: CGPoint(x: position, y: plot.maxY))
            context.stroke(line, with: .color(.orange.opacity(0.8)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
    }

    private func drawPeak(_ curve: Series, context: GraphicsContext, plot: CGRect, range: ClosedRange<Float>, indices: [Int], showLabel: Bool) {
        guard let index = indices.max(by: { curve.values[$0] < curve.values[$1] }) else { return }
        let point = CGPoint(x: x(frequencies[index], plot: plot, range: range), y: y(curve.values[index], plot: plot))
        context.fill(Path(ellipseIn: CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)), with: .color(curve.color))
        if showLabel {
            let labelX = min(plot.maxX - 34, max(plot.minX + 34, point.x))
            let labelY = point.y < plot.minY + 24 ? point.y + 15 : point.y - 13
            context.draw(Text(frequencyLabel(frequencies[index])).font(.caption2.weight(.semibold)).foregroundColor(.primary), at: CGPoint(x: labelX, y: labelY))
        }
    }

    private func drawSelection(_ index: Int, curves: [Series], context: GraphicsContext, plot: CGRect, range: ClosedRange<Float>) {
        let position = x(frequencies[index], plot: plot, range: range)
        var line = Path()
        line.move(to: CGPoint(x: position, y: plot.minY))
        line.addLine(to: CGPoint(x: position, y: plot.maxY))
        context.stroke(line, with: .color(.primary.opacity(0.75)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        for curve in curves {
            let point = CGPoint(x: position, y: y(curve.values[index], plot: plot))
            context.fill(Path(ellipseIn: CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)), with: .color(curve.color))
        }
    }

    private func frequencyLabel(_ frequency: Float) -> String {
        frequency < 1000 ? String(format: "%.0f Hz", frequency) : String(format: "%.1fk Hz", frequency / 1000)
    }
}
