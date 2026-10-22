import SwiftUI

/// Спільний курсор графіків: окремий спостережуваний об'єкт, щоб рух миші не перемальовував самі графіки.
@Observable final class CursorModel { var t: Double? }

struct CSeries: Identifiable {
    let id: String
    let name: String
    let color: Color
    let t: [Double]
    let v: [Double]

    func value(at time: Double) -> Double? {
        guard !t.isEmpty else { return nil }
        var lo = 0, hi = t.count - 1
        while lo < hi { let m = (lo + hi) / 2; if t[m] < time { lo = m + 1 } else { hi = m } }
        if lo > 0, abs(t[lo - 1] - time) < abs(t[lo] - time) { lo -= 1 }
        return v[lo]
    }
}

enum ChartPalette {
    static let colors: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .yellow, .red, .mint, .indigo]
    static func color(_ i: Int) -> Color { colors[i % colors.count] }
}

enum ChartInsets { static let l: CGFloat = 46, r: CGFloat = 8, t: CGFloat = 6, b: CGFloat = 18 }

/// Швидкий графік на Canvas: лінії, сітка й підписи осей. Не залежить від курсора, тому не перемальовується при русі миші.
struct CanvasChart: View, Equatable {
    let series: [CSeries]
    let x0: Double, x1: Double
    var normalize = false

    static func == (a: CanvasChart, b: CanvasChart) -> Bool {
        a.x0 == b.x0 && a.x1 == b.x1 && a.normalize == b.normalize && a.series.count == b.series.count
            && zip(a.series, b.series).allSatisfy { $0.id == $1.id && $0.t.count == $1.t.count }
    }

    var body: some View {
        Canvas { ctx, size in
            let plot = CGRect(x: ChartInsets.l, y: ChartInsets.t, width: max(10, size.width - ChartInsets.l - ChartInsets.r), height: max(10, size.height - ChartInsets.t - ChartInsets.b))
            var lo = Double.infinity, hi = -Double.infinity
            for s in series { for v in s.v where v.isFinite { lo = min(lo, v); hi = max(hi, v) } }
            if !(lo.isFinite && hi.isFinite) { return }
            if hi - lo < 1e-9 { lo -= 1; hi += 1 }
            let pad = (hi - lo) * 0.06; lo -= pad; hi += pad
            func X(_ t: Double) -> CGFloat { plot.minX + CGFloat((t - x0) / max(x1 - x0, 1e-9)) * plot.width }
            func Y(_ v: Double) -> CGFloat { plot.maxY - CGFloat((v - lo) / (hi - lo)) * plot.height }
            ctx.fill(Path(roundedRect: plot, cornerRadius: 4), with: .color(.primary.opacity(0.035)))
            // Горизонтальні мітки: 4 рівні
            for k in 0...3 {
                let v = lo + (hi - lo) * Double(k) / 3, y = Y(v)
                var g = Path(); g.move(to: CGPoint(x: plot.minX, y: y)); g.addLine(to: CGPoint(x: plot.maxX, y: y))
                ctx.stroke(g, with: .color(.secondary.opacity(0.18)), lineWidth: 0.5)
                ctx.draw(Text(lk(Self.label(v))).font(.system(size: 9, design: .monospaced)).foregroundColor(.secondary), at: CGPoint(x: plot.minX - 4, y: y), anchor: .trailing)
            }
            // Вертикальні мітки часу
            let n = max(2, min(8, Int(plot.width / 90)))
            for k in 0...n {
                let t = x0 + (x1 - x0) * Double(k) / Double(n), x = X(t)
                var g = Path(); g.move(to: CGPoint(x: x, y: plot.minY)); g.addLine(to: CGPoint(x: x, y: plot.maxY))
                ctx.stroke(g, with: .color(.secondary.opacity(0.12)), lineWidth: 0.5)
                ctx.draw(Text(lk(fmtT(t))).font(.system(size: 9, design: .monospaced)).foregroundColor(.secondary), at: CGPoint(x: x, y: plot.maxY + 9))
            }
            ctx.clip(to: Path(plot))
            for s in series where s.t.count > 1 {
                var p = Path(); var started = false
                for i in 0..<s.t.count {
                    let pt = CGPoint(x: X(s.t[i]), y: Y(s.v[i]))
                    if !started { p.move(to: pt); started = true } else { p.addLine(to: pt) }
                }
                ctx.stroke(p, with: .color(s.color), style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
            }
        }
    }

    static func label(_ v: Double) -> String {
        let a = abs(v)
        if a >= 10000 { return String(format: "%.0fk", v / 1000) }
        if a >= 100 { return String(format: "%.0f", v) }
        if a >= 10 { return String(format: "%.1f", v) }
        return String(format: "%.2f", v)
    }
}

/// Шар курсора поверх графіка: вертикальна лінія й приймання наведення миші. Єдиний компонент, що читає курсор.
struct CursorLayer: View {
    let cur: CursorModel
    let x0: Double, x1: Double
    var left: CGFloat = ChartInsets.l, right: CGFloat = ChartInsets.r
    var top: CGFloat = ChartInsets.t, bottom: CGFloat = ChartInsets.b
    var body: some View {
        GeometryReader { geo in
            let plotW = max(10, geo.size.width - left - right)
            ZStack(alignment: .topLeading) {
                Color.clear.contentShape(Rectangle())
                    .onContinuousHover { ph in
                        switch ph {
                        case .active(let l):
                            let f = (l.x - left) / plotW
                            cur.t = f >= 0 && f <= 1 ? x0 + (x1 - x0) * Double(f) : nil
                        case .ended: cur.t = nil
                        }
                    }
                if let t = cur.t {
                    Rectangle().fill(Color.secondary.opacity(0.8)).frame(width: 1, height: geo.size.height - top - bottom)
                        .offset(x: left + CGFloat((t - x0) / max(x1 - x0, 1e-9)) * plotW, y: top)
                }
            }
        }
    }
}

/// Значення серій під курсором.
struct CursorReadout: View {
    let cur: CursorModel
    let series: [CSeries]
    var body: some View {
        if let t = cur.t {
            HStack(spacing: 10) {
                Text(lk(fmtT(t))).font(.caption.monospacedDigit().weight(.semibold))
                ForEach(series) { s in
                    HStack(spacing: 3) {
                        Circle().fill(s.color).frame(width: 6, height: 6)
                        Text("\(s.name.split(separator: ".").last.map(String.init) ?? s.name) \(s.value(at: t).map { CanvasChart.label($0) } ?? "—")").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
        } else { Text(" ").font(.caption) }
    }
}

struct SeriesLegend: View {
    let series: [CSeries]
    var body: some View {
        HStack(spacing: 10) {
            ForEach(series) { s in HStack(spacing: 4) { Circle().fill(s.color).frame(width: 7, height: 7); Text(LocalizedStringKey(s.name)).font(.caption).foregroundStyle(.secondary) } }
        }
    }
}

/// Готовий компонент: графік + курсор + підписи значень.
struct InteractiveChart: View {
    let series: [CSeries]
    let x0: Double, x1: Double
    var height: CGFloat = 120
    var normalize = false
    let cur: CursorModel
    var showReadout = true
    var onRange: ((Double, Double) -> Void)? = nil     // якщо задано, на графіку з'являються дужки звуження діапазону

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if showReadout { CursorReadout(cur: cur, series: series).frame(height: 14) }
            CanvasChart(series: series, x0: x0, x1: x1, normalize: normalize).equatable()
                .frame(height: height)
                .overlay { CursorLayer(cur: cur, x0: x0, x1: x1) }
                .overlay { if let onRange { RangeBrackets(x0: x0, x1: x1, apply: onRange) } }
        }
    }
}
