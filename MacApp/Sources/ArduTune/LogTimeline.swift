import SwiftUI

/// Синхронна панель польоту: стрічка режимів і подій та кілька графіків зі спільним курсором.
/// Дані будуються у фоні; графіки малюються на Canvas і не перемальовуються при русі курсора.
struct FlightDashboard: View {
    let log: DFLog
    @State private var data: DashData?
    @State private var cur = CursorModel()
    @State private var selectedEvent: DashEvent?

    struct Panel: Identifiable { let id: String; let title: String; let unit: String; let series: [CSeries] }
    struct DashEvent: Identifiable { let id = UUID(); let t: Double; let kind: String; let text: String }
    struct DashData { var panels: [Panel]; var modes: [(Double, Double, Int)]; var events: [DashEvent]; var duration: Double; var kind = "copter" }

    static let candidates: [(String, String, [[String]])] = [
        ("Висота", "м", [["CTUN.Alt"], ["BARO.Alt"], ["POS.RelHomeAlt"], ["GPS.Alt"]]),
        ("Швидкість", "м/с", [["GPS.Spd"], ["ARSP.Airspeed"]]),
        ("Нахил", "°", [["ATT.Roll", "ATT.Pitch"]]),
        ("Батарея", "В / А", [["BAT.Volt", "BAT.Curr"]]),
        ("Вібрація", "м/с²", [["VIBE.VibeX", "VIBE.VibeY", "VIBE.VibeZ"]]),
        ("Мотори", "мкс", [["RCOU.C1", "RCOU.C2", "RCOU.C3", "RCOU.C4"], ["RCIN.C3"]]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let d = data {
                strip(d)
                if let e = selectedEvent { Label("\(fmtT(e.t))  \(loc(e.kind)): \(loc(e.text))", systemImage: "mappin.circle.fill").font(.callout).padding(8).frame(maxWidth: .infinity, alignment: .leading).background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8)) }
                if d.panels.isEmpty { Text("У цьому лозі немає стандартних даних для огляду (висота, швидкість, нахил, батарея, вібрація).").font(.callout).foregroundStyle(.secondary) }
                ForEach(d.panels) { p in
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 8) { Text(LocalizedStringKey(p.title)).font(.callout.weight(.semibold)); Text(LocalizedStringKey(p.unit)).font(.caption).foregroundStyle(.secondary); if p.series.count > 1 { SeriesLegend(series: p.series) } ; Spacer() }
                        InteractiveChart(series: p.series, x0: 0, x1: max(d.duration, 1), height: 96, cur: cur)
                    }
                }
            } else { ProgressView("Побудова огляду польоту…").frame(maxWidth: .infinity, minHeight: 120) }
        }
        .task { if data == nil { data = await Task.detached(priority: .userInitiated) { Self.build(log) }.value } }
    }

    // MARK: Дані
    static func build(_ log: DFLog) -> DashData {
        var panels: [Panel] = []
        for (title, unit, opts) in candidates {
            for keys in opts {
                var ss: [CSeries] = []
                for (i, k) in keys.enumerated() {
                    let p = k.split(separator: ".").map(String.init)
                    guard p.count == 2, log.fields(of: p[0]).contains(p[1]) else { continue }
                    let s = log.series(p[0], p[1]).filter { $0.v.isFinite && abs($0.v) < 1e7 }
                    guard s.count > 3 else { continue }
                    let dec = LogGraphView.decimate(s.map { (t: $0.t, v: $0.v) })
                    ss.append(CSeries(id: k, name: k, color: ChartPalette.color(i), t: dec.map(\.t), v: dec.map(\.v)))
                }
                if !ss.isEmpty { panels.append(Panel(id: title, title: title, unit: unit, series: ss)); break }
            }
        }
        let mt = log.modeTimeline()
        var modes: [(Double, Double, Int)] = []
        for (i, m) in mt.enumerated() { modes.append((m.t, i + 1 < mt.count ? mt[i + 1].t : log.duration, m.mode)) }
        var events: [DashEvent] = []
        for m in log.messages where m.name == "EV" { if m.text.contains("Arm") || m.text.contains("Take off") || m.text.contains("Land") { events.append(DashEvent(t: m.time, kind: "Подія", text: m.text)) } }
        for m in log.messages where m.name == "ERR" { events.append(DashEvent(t: m.time, kind: "Помилка", text: m.text + (m.hint.isEmpty ? "" : ": " + m.hint))) }
        for m in log.messages where m.name == "MSG" && (m.text.localizedCaseInsensitiveContains("failsafe") || m.text.localizedCaseInsensitiveContains("crash") || m.text.localizedCaseInsensitiveContains("glitch")) { events.append(DashEvent(t: m.time, kind: "Повідомлення", text: m.text)) }
        events.sort { $0.t < $1.t }
        return DashData(panels: panels, modes: modes, events: events, duration: max(log.duration, 1), kind: log.kind)
    }

    // MARK: Стрічка режимів і подій
    static func modeColor(_ m: Int) -> Color { [Color.blue, .teal, .indigo, .purple, .pink, .orange, .brown, .mint, .cyan][abs(m) % 9] }
    static let left: CGFloat = 54, right: CGFloat = 8

    func strip(_ d: DashData) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Canvas { ctx, size in
                let w = size.width - Self.left - Self.right
                func X(_ t: Double) -> CGFloat { Self.left + CGFloat(t / d.duration) * w }
                ctx.draw(Text("Режим").font(.system(size: 10)).foregroundColor(.secondary), at: CGPoint(x: 4, y: 15), anchor: .leading)
                for m in d.modes {
                    let r = CGRect(x: X(m.0), y: 4, width: max(2, X(m.1) - X(m.0) - 1), height: 22)
                    ctx.fill(Path(roundedRect: r, cornerRadius: 4), with: .color(Self.modeColor(m.2).opacity(0.5)))
                    if r.width > 52 { ctx.draw(Text(lk(DFLog.modeName(m.2, kind: d.kind))).font(.system(size: 10, weight: .medium)).foregroundColor(.primary), at: CGPoint(x: r.midX, y: r.midY)) }
                }
                ctx.draw(Text("Події").font(.system(size: 10)).foregroundColor(.secondary), at: CGPoint(x: 4, y: 41), anchor: .leading)
                for e in d.events {
                    let col: Color = e.kind == "Помилка" ? .red : (e.kind == "Повідомлення" ? .orange : .green)
                    var tri = Path(); let x = X(e.t); tri.move(to: CGPoint(x: x, y: 32)); tri.addLine(to: CGPoint(x: x - 5, y: 46)); tri.addLine(to: CGPoint(x: x + 5, y: 46)); tri.closeSubpath()
                    ctx.fill(tri, with: .color(col.opacity(0.85)))
                }
            }
            .frame(height: 50)
            .overlay { CursorLayer(cur: cur, x0: 0, x1: d.duration, left: Self.left, right: Self.right, top: 0, bottom: 0) }
            .overlay {
                GeometryReader { geo in Color.clear.contentShape(Rectangle()).onTapGesture { l in
                    let t = Double((l.x - Self.left) / max(geo.size.width - Self.left - Self.right, 1)) * d.duration
                    selectedEvent = d.events.min(by: { abs($0.t - t) < abs($1.t - t) }).flatMap { abs($0.t - t) < d.duration * 0.03 ? $0 : nil }
                } }
            }
            HStack(spacing: 14) {
                legend(.green, "подія (ARM, зліт, посадка)"); legend(.orange, "повідомлення"); legend(.red, "помилка")
                Spacer(); Text("Клікніть позначку, щоб прочитати подію").font(.caption).foregroundStyle(.secondary)
            }.font(.caption)
        }
    }
    func legend(_ c: Color, _ t: String) -> some View { HStack(spacing: 4) { Circle().fill(c).frame(width: 7, height: 7); Text(LocalizedStringKey(t)).foregroundStyle(.secondary) } }
}
