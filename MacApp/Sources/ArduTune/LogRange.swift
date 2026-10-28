import SwiftUI

/// Розбір часу, введеного вручну: «1:23.4», «83», «83.5», «1:23».
func parseLogTime(_ s: String) -> Double? {
    let t = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
    if t.isEmpty { return nil }
    let parts = t.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
    switch parts.count {
    case 1: return Double(parts[0])
    case 2: if let m = Double(parts[0]), let s = Double(parts[1]) { return m * 60 + s } else { return nil }
    case 3: if let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2]) { return h * 3600 + m * 60 + s } else { return nil }
    default: return nil
    }
}

/// Поле часу «хв:с»: застосовується по Return або втраті фокуса; недійсний текст повертається до поточного значення.
struct TimeField: View {
    let title: String
    let value: Double
    var onCommit: (Double) -> Void
    @State private var text = ""
    @FocusState private var focus: Bool

    var body: some View {
        HStack(spacing: 4) {
            Text(LocalizedStringKey(title)).font(.caption).foregroundStyle(.secondary)
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder).font(.system(.caption, design: .monospaced)).multilineTextAlignment(.center)
                .frame(width: 70).focused($focus)
                .onSubmit { commit() }
        }
        .onAppear { text = fmtT(value) }
        .onChange(of: value) { _, v in text = fmtT(v) }
        .onChange(of: focus) { _, f in if !f { commit() } }
        .tip("Формат: хв:с (наприклад 1:23.5) або секунди")
    }
    private func commit() {
        if let v = parseLogTime(text) { onCommit(v) }
        text = fmtT(value)
    }
}

/// Дужка діапазону «[» або «]» на всю висоту з коротким заходом усередину.
struct BracketShape: Shape {
    let left: Bool
    func path(in r: CGRect) -> Path {
        var p = Path()
        let x = left ? r.minX + 1.5 : r.maxX - 1.5, d: CGFloat = left ? 7 : -7
        p.move(to: CGPoint(x: x + d, y: r.minY + 1)); p.addLine(to: CGPoint(x: x, y: r.minY + 1))
        p.addLine(to: CGPoint(x: x, y: r.maxY - 1)); p.addLine(to: CGPoint(x: x + d, y: r.maxY - 1))
        return p
    }
}

/// Дужки діапазону поверх графіка: тягніть ліву чи праву до потрібного моменту; по відпусканню графік звужується до вибраної ділянки.
struct RangeBrackets: View {
    let x0: Double, x1: Double
    var apply: (Double, Double) -> Void
    @State private var dl: CGFloat?
    @State private var dr: CGFloat?

    var body: some View {
        GeometryReader { geo in
            let px = ChartInsets.l, pw = max(10, geo.size.width - ChartInsets.l - ChartInsets.r)
            let top = ChartInsets.t, h = max(10, geo.size.height - ChartInsets.t - ChartInsets.b)
            let fl = dl ?? 0, fr = dr ?? 1
            let hit: CGFloat = 16
            ZStack(alignment: .topLeading) {
                if dl != nil || dr != nil {
                    Rectangle().fill(Color.black.opacity(0.28)).frame(width: pw * fl, height: h).offset(x: px, y: top)
                    Rectangle().fill(Color.black.opacity(0.28)).frame(width: pw * (1 - fr), height: h).offset(x: px + pw * fr, y: top)
                }
                handle(left: true, x: px + pw * fl, top: top, h: h, hit: hit)
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("rb")).onChanged { g in
                        dl = min(max((g.location.x - px) / pw, 0), (dr ?? 1) - 0.02)
                    }.onEnded { _ in commit() })
                handle(left: false, x: px + pw * fr, top: top, h: h, hit: hit)
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("rb")).onChanged { g in
                        dr = max(min((g.location.x - px) / pw, 1), (dl ?? 0) + 0.02)
                    }.onEnded { _ in commit() })
                if let l = dl { tag(fmtT(x0 + (x1 - x0) * Double(l))).offset(x: px + pw * l + 4, y: top + 2) }
                if let r = dr { tag(fmtT(x0 + (x1 - x0) * Double(r))).offset(x: px + pw * r - 50, y: top + 2) }
            }
            .coordinateSpace(name: "rb")
        }
    }

    private func handle(left: Bool, x: CGFloat, top: CGFloat, h: CGFloat, hit: CGFloat) -> some View {
        BracketShape(left: left).stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
            .frame(width: hit, height: h)
            .background(Color.accentColor.opacity(0.001))
            .contentShape(Rectangle())
            .offset(x: left ? x - 1 : x - hit + 1, y: top)
            .pointerStyle(.columnResize)
            .tip("Потягніть, щоб звузити діапазон графіка")
    }
    private func tag(_ s: String) -> some View {
        Text(LocalizedStringKey(s)).font(.system(size: 10, design: .monospaced).weight(.semibold)).padding(.horizontal, 5).padding(.vertical, 1)
            .background(Color.accentColor, in: Capsule()).foregroundStyle(.white)
    }
    private func commit() {
        let a = x0 + (x1 - x0) * Double(dl ?? 0), b = x0 + (x1 - x0) * Double(dr ?? 1)
        dl = nil; dr = nil
        if b - a >= 0.5 { apply(a, b) }
    }
}

/// Панель вибору діапазону аналізу в помічнику: профіль польоту, дужки, поля часу й скидання.
struct LogRangeBar: View {
    let log: DFLog
    @Binding var from: Double
    @Binding var to: Double
    var hint = "Помічник аналізує лише цю ділянку: перетягніть дужки на профілі польоту або введіть час."
    @State private var spark: [Double] = []
    @State private var dl: CGFloat?
    @State private var dr: CGFloat?

    private var full: Bool { from <= 0.05 && to >= log.duration - 0.05 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Label("Діапазон аналізу", systemImage: "scope").font(.callout.weight(.semibold))
                Text(lk(full ? "весь лог" : String(format: loc("%@ – %@ (%.0f с)"), fmtT(from), fmtT(to), to - from))).font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                TimeField(title: String(localized: "Початок"), value: from) { v in
                    from = min(max(0, v), log.duration - 0.5)
                    if to - from < 0.5 { to = min(log.duration, from + 1) }
                }
                TimeField(title: String(localized: "Кінець"), value: to) { v in
                    to = max(min(log.duration, v), 0.5)
                    if to - from < 0.5 { from = max(0, to - 1) }
                }
                Button("Весь лог") { from = 0; to = log.duration }.controlSize(.small).disabled(full)
            }
            track
            Text(LocalizedStringKey(hint)).font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        .task(id: ObjectIdentifier(log)) { spark = await Self.profile(log) }
    }

    private var track: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let dur = max(log.duration, 0.001)
            let fl = dl ?? CGFloat(from / dur), fr = dr ?? CGFloat(to / dur)
            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in
                    ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 6), with: .color(.primary.opacity(0.05)))
                    guard spark.count > 1 else { return }
                    var p = Path(); p.move(to: CGPoint(x: 0, y: size.height))
                    for (i, v) in spark.enumerated() {
                        p.addLine(to: CGPoint(x: size.width * CGFloat(i) / CGFloat(spark.count - 1), y: size.height - 4 - (size.height - 10) * CGFloat(v)))
                    }
                    p.addLine(to: CGPoint(x: size.width, y: size.height)); p.closeSubpath()
                    ctx.fill(p, with: .color(.accentColor.opacity(0.28)))
                }
                Rectangle().fill(Color.black.opacity(0.22)).frame(width: w * fl, height: h)
                Rectangle().fill(Color.black.opacity(0.22)).frame(width: w * (1 - fr), height: h).offset(x: w * fr)
                Rectangle().fill(Color.accentColor.opacity(0.10)).frame(width: max(0, w * (fr - fl)), height: h).offset(x: w * fl).allowsHitTesting(false)
                bracket(left: true).offset(x: w * fl - 1)
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("track")).onChanged { g in
                        dl = min(max(g.location.x / w, 0), (dr ?? CGFloat(to / dur)) - 0.01)
                    }.onEnded { _ in commit(dur) })
                bracket(left: false).offset(x: w * fr - 15)
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("track")).onChanged { g in
                        dr = max(min(g.location.x / w, 1), (dl ?? CGFloat(from / dur)) + 0.01)
                    }.onEnded { _ in commit(dur) })
            }
            .coordinateSpace(name: "track")
        }
        .frame(height: 54)
    }

    private func bracket(left: Bool) -> some View {
        BracketShape(left: left).stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
            .frame(width: 16, height: 54).background(Color.accentColor.opacity(0.001)).contentShape(Rectangle())
            .pointerStyle(.columnResize)
    }
    private func commit(_ dur: Double) {
        if let l = dl { from = Double(l) * dur }
        if let r = dr { to = Double(r) * dur }
        dl = nil; dr = nil
        if to - from < 0.5 { to = min(dur, from + 1) }
    }

    /// Профіль польоту: висота (чи інша типова величина), усереднена по 240 колонках і нормована.
    static func profile(_ log: DFLog) async -> [Double] {
        await Task.detached(priority: .utility) {
            for key in ["CTUN.Alt", "BARO.Alt", "GPS.Alt", "ATT.Roll", "BAT.Volt", "RCIN.C3"] {
                let p = key.split(separator: ".").map(String.init)
                let s = log.series(p[0], p[1])
                guard s.count > 20, log.duration > 1 else { continue }
                let n = 240
                var sum = [Double](repeating: 0, count: n), cnt = [Int](repeating: 0, count: n)
                for q in s where q.v.isFinite {
                    let i = min(n - 1, max(0, Int(q.t / log.duration * Double(n))))
                    sum[i] += q.v; cnt[i] += 1
                }
                var out = (0..<n).map { cnt[$0] > 0 ? sum[$0] / Double(cnt[$0]) : Double.nan }
                var last = out.first { $0.isFinite } ?? 0
                for i in 0..<n { if out[i].isFinite { last = out[i] } else { out[i] = last } }
                guard let lo = out.min(), let hi = out.max(), hi > lo else { continue }
                return out.map { ($0 - lo) / (hi - lo) }
            }
            return []
        }.value
    }
}
