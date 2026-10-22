import SwiftUI
import Charts

// MARK: - Спрощена модель відгуку для ілюстрацій (не заміна реальному польоту)

struct PIDSet {
    var p = 0.0, i = 0.0, d = 0.0, ff = 0.0, imax = 1.0
    var fltt = 0.0, fltd = 0.0, flte = 0.0      // Гц; 0 = без фільтра
}

struct Plant {
    let gain: Double          // кутове прискорення на одиницю керування
    let damping: Double       // власне демпфування, 1/с
    let tau: Double           // запізнення виконавчого механізму (мотор/серво), с
    let target: Double        // розмір кроку (рад/с)
    let duration: Double      // тривалість показу, с
    static let copter = Plant(gain: 150, damping: 2, tau: 0.03, target: 3, duration: 0.8)
    static let plane = Plant(gain: 9.3, damping: 3, tau: 0.06, target: 1.2, duration: 3.0)
}

struct ResponseStats {
    var overshoot = 0.0       // %
    var riseTime: Double?     // с (10 → 90 %)
    var settling: Double?     // с (до ±5 %)
    var oscillating = false
    var unstable = false

    var verdict: (String, Color) {
        if unstable { return ("Нестійко: різке наростання коливань", .red) }
        if oscillating { return ("Коливається: зменшіть P або збільште D", .orange) }
        if overshoot > 25 { return ("Сильне перерегулювання", .orange) }
        if let r = riseTime, r > 0.6 * 1.0, settling == nil { return ("Повільний відгук: збільште P або FF", .orange) }
        if settling == nil { return ("Не встигає вийти на ціль", .orange) }
        return ("Швидкий і стабільний відгук", .green)
    }
}

enum TuneSim {
    /// Крок бажаної швидкості обертання на t=0.05 с. Повертає нормалізований відгук (1 = ціль) з 240 точок.
    static func response(_ c: PIDSet, plant: Plant) -> (values: [Double], stats: ResponseStats) {
        let dt = 0.002
        let steps = Int(plant.duration / dt)
        var omega = 0.0, act = 0.0, integ = 0.0, prevErr = 0.0, dFilt = 0.0, tF = 0.0, eF = 0.0
        func alpha(_ f: Double) -> Double { f <= 0 ? 1 : (2 * Double.pi * f * dt) / (2 * Double.pi * f * dt + 1) }
        let aT = alpha(c.fltt), aD = alpha(c.fltd), aE = alpha(c.flte)
        var out: [Double] = []; out.reserveCapacity(steps)
        var blown = false
        for k in 0..<steps {
            let tgt = Double(k) * dt >= 0.05 ? plant.target : 0
            tF += aT * (tgt - tF)
            let err = tF - omega
            eF += aE * (err - eF)
            let e = c.flte > 0 ? eF : err
            let der = (e - prevErr) / dt; prevErr = e
            dFilt += aD * (der - dFilt)
            integ = max(-c.imax, min(c.imax, integ + c.i * e * dt))
            var u = c.p * e + integ + c.d * (c.fltd > 0 ? dFilt : der) + c.ff * tF
            u = max(-1, min(1, u))
            act += (u - act) * dt / max(plant.tau, dt)
            omega += (plant.gain * act - plant.damping * omega) * dt
            if abs(omega) > 50 * plant.target { blown = true; break }
            out.append(omega / plant.target)
        }
        if blown { while out.count < steps { out.append(out.last ?? 0) } }
        // Проріджуємо до 240 точок
        let n = 240
        let dec = (0..<n).map { i in out[min(out.count - 1, i * out.count / n)] }
        return (dec, stats(dec, dtPerSample: plant.duration / Double(n), start: 0.05, blown: blown))
    }

    static func stats(_ r: [Double], dtPerSample: Double, start: Double, blown: Bool) -> ResponseStats {
        var s = ResponseStats()
        s.unstable = blown
        let i0 = Int(start / dtPerSample)
        guard r.count > i0 + 5 else { return s }
        let peak = r[i0...].max() ?? 1
        s.overshoot = max(0, (peak - 1) * 100)
        if let a = r[i0...].firstIndex(where: { $0 >= 0.1 }), let b = r[i0...].firstIndex(where: { $0 >= 0.9 }), b >= a { s.riseTime = Double(b - a) * dtPerSample }
        if let last = r.indices.last(where: { abs(r[$0] - 1) > 0.05 && $0 >= i0 }), last < r.count - 8 { s.settling = Double(last - i0) * dtPerSample }
        else if r[i0...].allSatisfy({ abs($0 - 1) <= 0.05 }) { s.settling = 0 }
        // Коливання: кілька перетинів рівня цілі після піка
        var cross = 0; var above = r[i0] > 1
        for v in r[i0...] where abs(v - 1) > 0.03 { let a = v > 1; if a != above { cross += 1; above = a } }
        s.oscillating = cross >= 4
        return s
    }
}

// MARK: - Картка ілюстрації відгуку

struct ResponseCard: View {
    @Environment(Store.self) var s
    let model: TuneModel
    @State private var axisID = "RLL"
    @State private var started: Date?
    @AppStorage("tune.slowmo") private var slow = true
    var ps: ParamStore { s.ps }
    var isPlane: Bool { model.kind == .plane || model.kind == .planeLegacy }

    func set(_ axis: TuneAxis, _ value: (String) -> Double?) -> PIDSet? {
        func g(_ k: String) -> Double? { axis.rate.first { TuneTips.key($0) == "RATE_" + k }.flatMap(value) }
        guard let p = g("P") else { return nil }
        return PIDSet(p: p, i: g("I") ?? 0, d: g("D") ?? 0, ff: g("FF") ?? 0, imax: g("IMAX") ?? 1, fltt: g("FLTT") ?? 0, fltd: g("FLTD") ?? 0, flte: g("FLTE") ?? 0)
    }

    struct Pt: Identifiable { let id: Int; let t: Double; let v: Double; let series: String }

    var body: some View {
        let axes = model.axes.filter { a in a.rate.contains { TuneTips.key($0) == "RATE_P" } }
        if let axis = axes.first(where: { $0.id == axisID }) ?? axes.first, let cur = set(axis, { ps.val($0) }) {
            let base = set(axis, { s.tune.baseline[$0] ?? ps.val($0) }) ?? cur
            let plant: Plant = isPlane ? .plane : .copter
            let rc = TuneSim.response(cur, plant: plant), rb = TuneSim.response(base, plant: plant)
            let changed = abs(cur.p - base.p) + abs(cur.i - base.i) + abs(cur.d - base.d) + abs(cur.ff - base.ff) + abs(cur.fltd - base.fltd) + abs(cur.fltt - base.fltt) > 1e-9
            let n = rc.values.count
            let dt = plant.duration / Double(n)
            let pts: [Pt] = (0..<n).flatMap { i -> [Pt] in
                let t = Double(i) * dt
                var l = [Pt(id: i * 3, t: t, v: t >= 0.05 ? 1 : 0, series: "Ціль"), Pt(id: i * 3 + 1, t: t, v: rc.values[i], series: "Зараз")]
                if changed { l.append(Pt(id: i * 3 + 2, t: t, v: rb.values[i], series: "Початкові")) }
                return l
            }
            Card(title: String(localized: "Ілюстрація: як апарат реагує на зміну налаштувань"), icon: "chart.line.uptrend.xyaxis", text: String(localized: "Модельна реакція на різкий поворот стіка («крок»). Змінюйте параметри − і +, і крива оновлюється одразу. Це спрощена модель для розуміння тенденцій, а не прогноз для конкретного апарата.")) {
                HStack(spacing: 12) {
                    Picker("", selection: $axisID) { ForEach(axes) { Text(lk($0.title.components(separatedBy: " ").first ?? $0.title)).tag($0.id) } }.pickerStyle(.segmented).labelsHidden().frame(width: 260)
                    Button { started = Date() } label: { Label("Показати крок", systemImage: "play.fill") }
                    Toggle("Уповільнено", isOn: $slow).toggleStyle(.checkbox).font(.caption)
                    Spacer()
                    if changed { Label("жовта крива: початкові значення", systemImage: "circle.dotted").font(.caption).foregroundStyle(.secondary) }
                }
                HStack(alignment: .top, spacing: 14) {
                    Chart(pts) { p in
                        LineMark(x: .value("с", p.t), y: .value("відгук", p.v), series: .value("s", p.series))
                            .foregroundStyle(by: .value("Крива", p.series))
                            .lineStyle(p.series == "Ціль" ? StrokeStyle(lineWidth: 1.2, dash: [4, 3]) : StrokeStyle(lineWidth: p.series == "Зараз" ? 2.2 : 1.4))
                    }
                    .chartForegroundStyleScale(["Ціль": Color.secondary, "Зараз": Color.accentColor, "Початкові": Color.orange])
                    .chartYScale(domain: -0.1...1.8)
                    .chartYAxis { AxisMarks(values: [0, 0.5, 1, 1.5]) }
                    .chartXAxisLabel("час, с")
                    .frame(height: 170)
                    DroneTiltView(response: rc.values, duration: plant.duration, plane: isPlane, axis: axis.id, started: started, slow: slow)
                        .frame(width: 200, height: 170)
                }
                let v = rc.stats.verdict
                HStack(spacing: 16) {
                    Label(LocalizedStringKey(v.0), systemImage: v.1 == .green ? "checkmark.seal.fill" : "exclamationmark.triangle.fill").foregroundStyle(v.1).font(.callout.weight(.semibold))
                    Spacer()
                    stat("Перерегулювання", String(format: "%.0f %%", rc.stats.overshoot), base: changed ? String(format: "%.0f %%", rb.stats.overshoot) : nil)
                    stat("Час наростання", rc.stats.riseTime.map { String(format: loc("%.0f мс"), $0 * 1000) } ?? "—", base: changed ? rb.stats.riseTime.map { String(format: loc("%.0f мс"), $0 * 1000) } : nil)
                    stat("Усталення", rc.stats.settling.map { String(format: loc("%.0f мс"), $0 * 1000) } ?? "не досягнуто", base: changed ? (rb.stats.settling.map { String(format: loc("%.0f мс"), $0 * 1000) } ?? "не досягнуто") : nil)
                }
            }
            .onAppear { if !axes.contains(where: { $0.id == axisID }) { axisID = axes.first?.id ?? "RLL" } }
        }
    }

    func stat(_ title: String, _ value: String, base: String?) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(LocalizedStringKey(title)).font(.caption2).foregroundStyle(.secondary)
            Text(LocalizedStringKey(value)).font(.callout.monospacedDigit().weight(.semibold))
            if let b = base { Text("було \(b)").font(.caption2.monospacedDigit()).foregroundStyle(.orange) }
        }
    }
}

/// Анімація нахилу апарата за змодельованим відгуком (вигляд спереду).
struct DroneTiltView: View {
    let response: [Double]
    let duration: Double
    let plane: Bool
    let axis: String
    let started: Date?
    let slow: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: started == nil)) { tl in
            let factor = slow ? 0.25 : 1.0
            let el = started.map { tl.date.timeIntervalSince($0) * factor } ?? 0
            let t = min(max(el, 0), duration)
            let idx = min(response.count - 1, Int(t / duration * Double(response.count)))
            let r = started == nil ? 0 : response[max(0, idx)]
            Canvas { ctx, size in
                let c = CGPoint(x: size.width / 2, y: size.height / 2 + 6)
                // Ціль: тонка лінія на 25° (крок)
                let goal = 25.0
                func rot(_ deg: Double, _ body: (inout GraphicsContext) -> Void) {
                    var g = ctx; g.translateBy(x: c.x, y: c.y); g.rotate(by: .degrees(axis == "PIT" ? 0 : deg)); body(&g)
                }
                rot(goal) { g in
                    var p = Path(); p.move(to: CGPoint(x: -85, y: 0)); p.addLine(to: CGPoint(x: 85, y: 0))
                    g.stroke(p, with: .color(.secondary.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                }
                let angle = goal * r
                // Горизонт
                var h = Path(); h.move(to: CGPoint(x: 8, y: c.y + 40)); h.addLine(to: CGPoint(x: size.width - 8, y: c.y + 40))
                ctx.stroke(h, with: .color(.secondary.opacity(0.25)), lineWidth: 1)
                if axis == "YAW" {
                    // Вигляд зверху: обертання за курсом
                    var g = ctx; g.translateBy(x: c.x, y: c.y - 6); g.rotate(by: .degrees(goal * 1.6 * r))
                    drawTop(&g)
                } else if axis == "PIT" {
                    var g = ctx; g.translateBy(x: c.x, y: c.y - 6); g.rotate(by: .degrees(-goal * r))
                    drawSide(&g)
                } else {
                    var g = ctx; g.translateBy(x: c.x, y: c.y - 6); g.rotate(by: .degrees(angle))
                    drawFront(&g)
                }
            }
            .overlay(alignment: .bottom) { Text(lk(started == nil ? "Натисніть «Показати крок»" : String(format: loc("кут %.0f°"), 25 * r))).font(.caption2.monospacedDigit()).foregroundStyle(.secondary) }
        }
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    func drawFront(_ g: inout GraphicsContext) {
        if plane {
            g.fill(Path(roundedRect: CGRect(x: -80, y: -3, width: 160, height: 6), cornerRadius: 3), with: .color(.accentColor.opacity(0.85)))
            g.fill(Path(ellipseIn: CGRect(x: -9, y: -11, width: 18, height: 22)), with: .color(.primary.opacity(0.75)))
        } else {
            g.fill(Path(roundedRect: CGRect(x: -78, y: -3, width: 156, height: 6), cornerRadius: 3), with: .color(.primary.opacity(0.55)))
            g.fill(Path(roundedRect: CGRect(x: -16, y: -10, width: 32, height: 20), cornerRadius: 6), with: .color(.primary.opacity(0.8)))
            for sx in [-1.0, 1.0] {
                g.fill(Path(roundedRect: CGRect(x: sx * 78 - 24, y: -12, width: 48, height: 4), cornerRadius: 2), with: .color(.accentColor.opacity(0.8)))
                g.fill(Path(ellipseIn: CGRect(x: sx * 78 - 5, y: -8, width: 10, height: 12)), with: .color(.primary.opacity(0.6)))
            }
        }
    }
    func drawSide(_ g: inout GraphicsContext) {
        if plane {
            g.fill(Path(roundedRect: CGRect(x: -60, y: -6, width: 120, height: 12), cornerRadius: 6), with: .color(.primary.opacity(0.75)))
            g.fill(Path(roundedRect: CGRect(x: 40, y: -22, width: 14, height: 18), cornerRadius: 3), with: .color(.accentColor.opacity(0.85)))
            var nose = Path(); nose.move(to: CGPoint(x: -60, y: 0)); nose.addLine(to: CGPoint(x: -76, y: 0))
            g.stroke(nose, with: .color(.accentColor), lineWidth: 3)
        } else {
            g.fill(Path(roundedRect: CGRect(x: -62, y: -3, width: 124, height: 6), cornerRadius: 3), with: .color(.primary.opacity(0.55)))
            g.fill(Path(roundedRect: CGRect(x: -22, y: -10, width: 44, height: 20), cornerRadius: 6), with: .color(.primary.opacity(0.8)))
            g.fill(Path(roundedRect: CGRect(x: -86, y: -10, width: 12, height: 8), cornerRadius: 3), with: .color(.accentColor))   // ніс
        }
    }
    func drawTop(_ g: inout GraphicsContext) {
        if plane {
            g.fill(Path(roundedRect: CGRect(x: -60, y: -3, width: 120, height: 6), cornerRadius: 3), with: .color(.accentColor.opacity(0.85)))
            g.fill(Path(roundedRect: CGRect(x: -4, y: -34, width: 8, height: 68), cornerRadius: 4), with: .color(.primary.opacity(0.75)))
        } else {
            var a = Path(); a.move(to: CGPoint(x: -50, y: -50)); a.addLine(to: CGPoint(x: 50, y: 50)); a.move(to: CGPoint(x: 50, y: -50)); a.addLine(to: CGPoint(x: -50, y: 50))
            g.stroke(a, with: .color(.primary.opacity(0.5)), lineWidth: 4)
            g.fill(Path(roundedRect: CGRect(x: -16, y: -16, width: 32, height: 32), cornerRadius: 7), with: .color(.primary.opacity(0.8)))
            g.fill(Path(roundedRect: CGRect(x: -5, y: -38, width: 10, height: 24), cornerRadius: 3), with: .color(.accentColor))   // ніс
        }
    }
}

// MARK: - Ілюстрація фільтра

struct FilterCurveCard: View {
    @Environment(Store.self) var s
    struct Pt: Identifiable { let id: Int; let f: Double; let db: Double; let series: String }

    /// Амплітудна характеристика ФНЧ 2-го порядку (Баттерворт): |H| = 1/√(1+(f/fc)⁴).
    static func db(_ f: Double, _ fc: Double) -> Double { -10 * log10(1 + pow(f / fc, 4)) }
    /// Груповa затримка біля нуля: ≈ 0.225 / fc.
    static func delayMs(_ fc: Double) -> Double { 1000 * 0.225 / fc }

    var body: some View {
        let fc = s.ps.val("INS_GYRO_FILTER") ?? 0
        let base = s.tune.baseline["INS_GYRO_FILTER"] ?? fc
        if fc > 0 {
            let freqs = (0...60).map { 1.0 * pow(10, Double($0) / 60 * 2.7) }   // 1…500 Гц
            var pts: [Pt] = []
            for (i, f) in freqs.enumerated() {
                pts.append(Pt(id: i * 2, f: f, db: Self.db(f, fc), series: "Зараз"))
                if abs(base - fc) > 0.01 { pts.append(Pt(id: i * 2 + 1, f: f, db: Self.db(f, base), series: "Початкові")) }
            }
            return AnyView(VStack(alignment: .leading, spacing: 4) {
                Text("Ефект фільтра гіроскопа").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Chart(pts) { p in
                    LineMark(x: .value("Гц", p.f), y: .value("дБ", max(-40, p.db)), series: .value("s", p.series)).foregroundStyle(by: .value("Крива", p.series))
                        .lineStyle(StrokeStyle(lineWidth: p.series == "Зараз" ? 2 : 1.2))
                    RuleMark(x: .value("fc", fc)).foregroundStyle(Color.accentColor.opacity(0.25))
                }
                .chartForegroundStyleScale(["Зараз": Color.accentColor, "Початкові": Color.orange])
                .chartXScale(domain: 1...500, type: .log)
                .chartYScale(domain: -40...3)
                .chartYAxisLabel("дБ")
                .chartXAxisLabel("частота шуму, Гц")
                .frame(height: 120)
                Text(String(format: loc("Затримка ≈ %.1f мс. Шум на 100 Гц послаблюється на %.0f дБ. Нижчий поріг = менше шуму, але більша затримка."), Self.delayMs(fc), -Self.db(100, fc)))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            })
        }
        return AnyView(EmptyView())
    }
}
