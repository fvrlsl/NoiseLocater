import SwiftUI

/// 方位图 - 平面模式 2D Canvas
struct LocationMap2DView: View {

    let points: [(x: Double, y: Double, db: Float)]
    let source: SourceLocation?
    let multiFreqLocations: [(freq: Float, loc: SourceLocation)]
    let spacing: Double

    var body: some View {
        Canvas { context, size in
            let padding: CGFloat = 40
            let drawSize = CGSize(width: size.width - padding * 2,
                                   height: size.height - padding * 2 - 30)
            let scale = min(drawSize.width, drawSize.height) / CGFloat(spacing * 2.5)
            let offsetX = padding + drawSize.width / 2 - CGFloat(spacing / 2) * scale
            let offsetY = padding + drawSize.height / 2 - CGFloat(spacing / 2) * scale

            // 网格
            drawGrid(context, offsetX, offsetY, scale, drawSize)

            // 连线 + 置信圈
            if let src = source {
                drawConnections(context, src, offsetX, offsetY, scale)
                drawConfidenceCircle(context, src, offsetX, offsetY, scale)
                drawSourceCross(context, src, offsetX, offsetY, scale)
            }

            // 多频率方位叠加
            for (freq, loc) in multiFreqLocations {
                drawMultiFreqPoint(context, loc, offsetX, offsetY, scale, freq)
            }

            // 点位
            for (i, p) in points.enumerated() {
                drawPoint(context, p, i + 1, offsetX, offsetY, scale)
            }
        }
        .background(Color.black)
        .overlay(alignment: .topTrailing) {
            if let src = source {
                VStack(alignment: .trailing) {
                    Text("声源: (\(String(format: "%.1f", src.x)), \(String(format: "%.1f", src.y)))")
                    Text("置信半径: \(String(format: "%.2f", src.confidence))m")
                }
                .font(.caption)
                .foregroundColor(.orange)
                .padding(8)
            }
        }
    }

    private func drawGrid(_ context: GraphicsContext, _ offsetX: CGFloat,
                          _ offsetY: CGFloat, _ scale: CGFloat,
                          _ drawSize: CGSize) {
        // 网格线
        let gridSize = 0.5  // 0.5m 一格
        var gridVal: Double = 0
        while gridVal <= spacing * 2 {
            let x = offsetX + CGFloat(gridVal) * scale
            let y = offsetY + CGFloat(gridVal) * scale
            if x < offsetX + drawSize.width {
                var h = Path()
                h.move(to: CGPoint(x: x, y: offsetY))
                h.addLine(to: CGPoint(x: x, y: offsetY + drawSize.height))
                context.stroke(h, with: .color(.gray.opacity(0.2)), lineWidth: 0.5)
            }
            if y < offsetY + drawSize.height {
                var v = Path()
                v.move(to: CGPoint(x: offsetX, y: y))
                v.addLine(to: CGPoint(x: offsetX + drawSize.width, y: y))
                context.stroke(v, with: .color(.gray.opacity(0.2)), lineWidth: 0.5)
            }
            gridVal += gridSize
        }
    }

    private func drawPoint(_ context: GraphicsContext,
                           _ point: (x: Double, y: Double, db: Float),
                           _ index: Int,
                           _ offsetX: CGFloat, _ offsetY: CGFloat,
                           _ scale: CGFloat) {
        let cx = offsetX + CGFloat(point.x) * scale
        let cy = offsetY + CGFloat(point.y) * scale
        let radius: CGFloat = CGFloat(5 + (point.db + 100) / 100 * 8)

        context.fill(
            Path(ellipseIn: CGRect(x: cx - radius, y: cy - radius,
                                     width: radius * 2, height: radius * 2)),
            with: .color(.green)
        )
        context.draw(
            Text("\(index)").font(.caption.bold()).foregroundColor(.white),
            at: CGPoint(x: cx, y: cy)
        )
    }

    private func drawConnections(_ context: GraphicsContext,
                                  _ src: SourceLocation,
                                  _ offsetX: CGFloat, _ offsetY: CGFloat,
                                  _ scale: CGFloat) {
        for p in points {
            let p1 = CGPoint(x: offsetX + CGFloat(p.x) * scale,
                              y: offsetY + CGFloat(p.y) * scale)
            let p2 = CGPoint(x: offsetX + CGFloat(src.x) * scale,
                              y: offsetY + CGFloat(src.y) * scale)
            var path = Path()
            path.move(to: p1)
            path.addLine(to: p2)
            context.stroke(path, with: .color(.gray.opacity(0.3)), lineWidth: 1)
        }
    }

    private func drawConfidenceCircle(_ context: GraphicsContext,
                                       _ src: SourceLocation,
                                       _ offsetX: CGFloat, _ offsetY: CGFloat,
                                       _ scale: CGFloat) {
        let cx = offsetX + CGFloat(src.x) * scale
        let cy = offsetY + CGFloat(src.y) * scale
        let radius = CGFloat(src.confidence) * scale
        context.stroke(
            Path(ellipseIn: CGRect(x: cx - radius, y: cy - radius,
                                     width: radius * 2, height: radius * 2)),
            with: .color(.orange.opacity(0.5)), lineWidth: 2
        )
    }

    private func drawSourceCross(_ context: GraphicsContext,
                                  _ src: SourceLocation,
                                  _ offsetX: CGFloat, _ offsetY: CGFloat,
                                  _ scale: CGFloat) {
        let cx = offsetX + CGFloat(src.x) * scale
        let cy = offsetY + CGFloat(src.y) * scale
        let size: CGFloat = 10
        var path = Path()
        path.move(to: CGPoint(x: cx - size, y: cy))
        path.addLine(to: CGPoint(x: cx + size, y: cy))
        path.move(to: CGPoint(x: cx, y: cy - size))
        path.addLine(to: CGPoint(x: cx, y: cy + size))
        context.stroke(path, with: .color(.red), lineWidth: 2)
    }

    private func drawMultiFreqPoint(_ context: GraphicsContext,
                                     _ loc: SourceLocation,
                                     _ offsetX: CGFloat, _ offsetY: CGFloat,
                                     _ scale: CGFloat, _ freq: Float) {
        let cx = offsetX + CGFloat(loc.x) * scale
        let cy = offsetY + CGFloat(loc.y) * scale
        let radius: CGFloat = 4
        context.fill(
            Path(ellipseIn: CGRect(x: cx - radius, y: cy - radius,
                                     width: radius * 2, height: radius * 2)),
            with: .color(.yellow.opacity(0.6))
        )
    }
}
