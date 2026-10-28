import SwiftUI

// MARK: - Загальні графіки XY і теплова карта

struct XYSeries: Identifiable {
    var id: String { name }
    let name: String
    let color: Color
    let x: [Double], y: [Double]
    var dash = false
}
struct XYLine { let value: Double; let label: String; let color: Color; var vertical = true; var dash = true }

private func niceTicks(_ lo: Double, _ hi: Double, _ n: Int = 5) -> [Double] {
    guard hi > lo else { return [lo] }
    let raw = (hi - lo) / Double(n)
    let mag = pow(10, floor(log10(raw)))
    let step = [1.0, 2.0, 5.0, 10.0].map { $0 * mag }.first { $0 >= raw } ?? raw
    var t: [Double] = [], v = (lo / step).rounded(.up) * step
    while v <= hi + step * 1e-6 { t.append(v); v += step }
    return t
}
private func tickText(_ v: Double) -> String { abs(v) < 1e-9 ? "0" : (abs(v) >= 100 || v == v.rounded() ? String(format: "%.0f", v) : String(format: "%.1f", v)) }

/// Простий лінійний графік XY на Canvas з осями, сіткою, мітками-лініями (вертикальними й горизонтальними) і значеннями під курсором.
struct XYChart: View {
    let series: [XYSeries]
    var xTitle = "", yTitle = ""
    var xRange: ClosedRange<Double>?
    var yRange: ClosedRange<Double>?
    var lines: [XYLine] = []
    var height: CGFloat = 220
    var yFormat: (Double) -> String = tickText
    @State private var hover: Double?

    private var xr: ClosedRange<Double> {
        if let r = xRange { return r }
        let xs = series.flatMap(\.x)
        return (xs.min() ?? 0)...max((xs.max() ?? 1), (xs.min() ?? 0) + 1e-6)
    }
    private var yr: ClosedRange<Double> {
        if let r = yRange { return r }
        let ys = series.flatMap { $0.y.filter(\.isFinite) }
        guard let lo = ys.min(), let hi = ys.max() else { return 0...1 }
        let pad = max((hi - lo) * 0.06, 1e-9)
        return (lo - pad)...(hi + pad)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 10) {
                ForEach(series) { s in HStack(spacing: 4) { Circle().fill(s.color).frame(width: 7, height: 7); Text(LocalizedStringKey(s.name)).font(.caption).foregroundStyle(.secondary) } }
                Spacer(minLength: 0)
                if let h = hover {
                    Text("\(xTitle.isEmpty ? "x" : xTitle) \(tickText(h))").font(.caption.monospacedDigit().weight(.semibold))
                    ForEach(series) { s in
                        if let v = value(s, at: h) { Text(lk(yFormat(v))).font(.caption.monospacedDigit()).foregroundStyle(s.color) }
                    }
                }
            }.frame(height: 16)
            Canvas { ctx, size in draw(&ctx, size) }
                .frame(height: height)
                .overlay {
                    GeometryReader { geo in
                        Color.clear.contentShape(Rectangle()).onContinuousHover { ph in
                            switch ph {
                            case .active(let l):
                                let f = (l.x - 46) / max(geo.size.width - 46 - 10, 1)
                                hover = f >= 0 && f <= 1 ? xr.lowerBound + (xr.upperBound - xr.lowerBound) * Double(f) : nil
                            case .ended: hover = nil
                            }
                        }
                    }
                }
            HStack { Text(LocalizedStringKey(yTitle)).font(.caption2).foregroundStyle(.tertiary); Spacer(); Text(LocalizedStringKey(xTitle)).font(.caption2).foregroundStyle(.tertiary) }
        }
    }

    private func value(_ s: XYSeries, at x: Double) -> Double? {
        guard s.x.count > 1, x >= (s.x.first ?? 0), x <= (s.x.last ?? 0) else { return nil }
        var lo = 0, hi = s.x.count - 1
        while lo < hi { let m = (lo + hi) / 2; if s.x[m] < x { lo = m + 1 } else { hi = m } }
        return s.y[lo]
    }

    private func draw(_ ctx: inout GraphicsContext, _ size: CGSize) {
        let plot = CGRect(x: 46, y: 6, width: max(10, size.width - 46 - 10), height: max(10, size.height - 6 - 20))
        let xr = self.xr, yr = self.yr
        func X(_ v: Double) -> CGFloat { plot.minX + CGFloat((v - xr.lowerBound) / (xr.upperBound - xr.lowerBound)) * plot.width }
        func Y(_ v: Double) -> CGFloat { plot.maxY - CGFloat((v - yr.lowerBound) / (yr.upperBound - yr.lowerBound)) * plot.height }
        ctx.fill(Path(roundedRect: plot, cornerRadius: 4), with: .color(.primary.opacity(0.035)))
        for v in niceTicks(yr.lowerBound, yr.upperBound, 5) {
            var g = Path(); g.move(to: CGPoint(x: plot.minX, y: Y(v))); g.addLine(to: CGPoint(x: plot.maxX, y: Y(v)))
            ctx.stroke(g, with: .color(.secondary.opacity(v == 0 ? 0.4 : 0.15)), lineWidth: v == 0 ? 0.8 : 0.5)
            ctx.draw(Text(lk(yFormat(v))).font(.system(size: 9, design: .monospaced)).foregroundColor(.secondary), at: CGPoint(x: plot.minX - 4, y: Y(v)), anchor: .trailing)
        }
        for v in niceTicks(xr.lowerBound, xr.upperBound, max(3, Int(plot.width / 90))) {
            var g = Path(); g.move(to: CGPoint(x: X(v), y: plot.minY)); g.addLine(to: CGPoint(x: X(v), y: plot.maxY))
            ctx.stroke(g, with: .color(.secondary.opacity(0.12)), lineWidth: 0.5)
            ctx.draw(Text(lk(tickText(v))).font(.system(size: 9, design: .monospaced)).foregroundColor(.secondary), at: CGPoint(x: X(v), y: plot.maxY + 10))
        }
        var clipped = ctx
        clipped.clip(to: Path(plot))
        for l in lines {
            var p = Path()
            if l.vertical { guard l.value >= xr.lowerBound, l.value <= xr.upperBound else { continue }; p.move(to: CGPoint(x: X(l.value), y: plot.minY)); p.addLine(to: CGPoint(x: X(l.value), y: plot.maxY)) }
            else { guard l.value >= yr.lowerBound, l.value <= yr.upperBound else { continue }; p.move(to: CGPoint(x: plot.minX, y: Y(l.value))); p.addLine(to: CGPoint(x: plot.maxX, y: Y(l.value))) }
            clipped.stroke(p, with: .color(l.color.opacity(0.85)), style: StrokeStyle(lineWidth: 1, dash: l.dash ? [4, 3] : []))
            if !l.label.isEmpty {
                let pt = l.vertical ? CGPoint(x: X(l.value) + 3, y: plot.minY + 7) : CGPoint(x: plot.maxX - 3, y: Y(l.value) - 7)
                clipped.draw(Text(LocalizedStringKey(l.label)).font(.system(size: 9, weight: .semibold)).foregroundColor(l.color), at: pt, anchor: l.vertical ? .leading : .trailing)
            }
        }
        for s in series where s.x.count > 1 {
            var p = Path(); var started = false
            for i in s.x.indices where s.y[i].isFinite {
                let pt = CGPoint(x: X(s.x[i]), y: Y(s.y[i]))
                if !started { p.move(to: pt); started = true } else { p.addLine(to: pt) }
            }
            clipped.stroke(p, with: .color(s.color), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round, dash: s.dash ? [5, 3] : []))
        }
        if let h = hover, h >= xr.lowerBound, h <= xr.upperBound {
            var p = Path(); p.move(to: CGPoint(x: X(h), y: plot.minY)); p.addLine(to: CGPoint(x: X(h), y: plot.maxY))
            ctx.stroke(p, with: .color(.secondary.opacity(0.8)), lineWidth: 1)
        }
    }
}

/// Теплова карта потужності: частота (по X) проти газу (по Y).
struct HeatmapChart: View {
    let heat: ReviewEngine.Heat
    var range = 45.0                         // динамічний діапазон, дБ
    var curves: [[(thr: Double, f: Double)]] = []   // накладені лінії нотч-фільтра: (газ, частота)
    var height: CGFloat = 260

    static func color(_ t: Double) -> Color {
        let stops: [(Double, (Double, Double, Double))] = [(0, (0.05, 0.05, 0.25)), (0.35, (0.1, 0.35, 0.85)), (0.6, (0.1, 0.8, 0.8)), (0.8, (0.98, 0.85, 0.2)), (1, (0.95, 0.15, 0.1))]
        let x = min(max(t, 0), 1)
        for i in 1..<stops.count where x <= stops[i].0 {
            let (a, b) = (stops[i - 1], stops[i]), f = (x - a.0) / (b.0 - a.0)
            return Color(red: a.1.0 + (b.1.0 - a.1.0) * f, green: a.1.1 + (b.1.1 - a.1.1) * f, blue: a.1.2 + (b.1.2 - a.1.2) * f)
        }
        return Color(red: 0.95, green: 0.15, blue: 0.1)
    }

    var body: some View {
        Canvas { ctx, size in
            let plot = CGRect(x: 46, y: 6, width: max(10, size.width - 46 - 10), height: max(10, size.height - 6 - 22))
            let nF = heat.freqs.count, nT = heat.thr.count
            guard nF > 1, nT > 0 else { return }
            let maxF = heat.freqs.last ?? 1
            let cw = plot.width / CGFloat(nF), ch = plot.height / CGFloat(nT)
            ctx.fill(Path(roundedRect: plot, cornerRadius: 4), with: .color(.black.opacity(0.25)))
            for b in 0..<nT {
                for k in 0..<nF {
                    let v = heat.db[b][k]
                    guard v.isFinite else { continue }
                    let r = CGRect(x: plot.minX + CGFloat(k) * cw, y: plot.maxY - CGFloat(b + 1) * ch, width: cw + 0.5, height: ch + 0.5)
                    ctx.fill(Path(r), with: .color(Self.color((v - (heat.maxDB - range)) / range)))
                }
            }
            for v in niceTicks(0, maxF, max(3, Int(plot.width / 80))) {
                ctx.draw(Text(lk(tickText(v))).font(.system(size: 9, design: .monospaced)).foregroundColor(.secondary), at: CGPoint(x: plot.minX + CGFloat(v / maxF) * plot.width, y: plot.maxY + 11))
            }
            for v in [0.0, 0.25, 0.5, 0.75, 1.0] {
                ctx.draw(Text("\(Int(v * 100))%").font(.system(size: 9, design: .monospaced)).foregroundColor(.secondary), at: CGPoint(x: plot.minX - 4, y: plot.maxY - CGFloat(v) * plot.height), anchor: .trailing)
            }
            for c in curves {
                var p = Path(); var st = false
                for pt in c where pt.f <= maxF {
                    let q = CGPoint(x: plot.minX + CGFloat(pt.f / maxF) * plot.width, y: plot.maxY - CGFloat(pt.thr) * plot.height)
                    if !st { p.move(to: q); st = true } else { p.addLine(to: q) }
                }
                ctx.stroke(p, with: .color(.white.opacity(0.9)), style: StrokeStyle(lineWidth: 1.2, dash: [5, 3]))
            }
        }
        .frame(height: height)
    }
}

// MARK: - Спільне оформлення

private struct ExplainBox: View {
    let title: String
    let lines: [String]
    @State private var open = true
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { withAnimation(.snappy(duration: 0.2)) { open.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).rotationEffect(.degrees(open ? 0 : -90)).frame(width: 12)
                    Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
                    Text(LocalizedStringKey(title)).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            if open {
                ForEach(lines.indices, id: \.self) { i in
                    Text("•  " + loc(lines[i])).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private func axisPicker(_ sel: Binding<Int>) -> some View {
    Picker("", selection: sel) { Text("Крен").tag(0); Text("Тангаж").tag(1); Text("Рискання").tag(2) }
        .pickerStyle(.segmented).labelsHidden().frame(width: 260)
}

// MARK: - PID Review

struct LogPIDReviewView: View {
    let log: DFLog
    @State private var axis = 0
    @State private var airOnly = true
    @State private var from = 0.0
    @State private var to = -1.0
    @State private var data: Result?
    @State private var busy = false
    @State private var showTerms: Set<String> = ["P", "D", "FF"]
    @State private var cur = CursorModel()

    struct Result {
        var ax: ReviewEngine.AxisData
        var tarAct: [CSeries]
        var terms: [String: CSeries]
        var step: ReviewEngine.StepResult
        var specTar: ReviewEngine.Spectrum, specAct: ReviewEngine.Spectrum, specErr: ReviewEngine.Spectrum
    }
    static let pids = ["PIDR", "PIDP", "PIDY"]
    private var rangeTo: Double { to < 0 ? log.duration : min(to, log.duration) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("PID Review").font(.title3.weight(.semibold))
                    Text("Як регулятор швидкості обертання виконує команди: очікуване й реальне значення, внески P/I/D/FF, крокова відповідь і спектри. За мотивами PID-Analyzer і PID Toolbox.").font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 14) {
                    axisPicker($axis)
                    Toggle("Лише політ", isOn: $airOnly).toggleStyle(.checkbox).tip("Використовувати лише ділянки в повітрі (за газом)")
                    if busy { ProgressView().controlSize(.small) }
                    Spacer()
                }
                LogRangeBar(log: log, from: $from, to: Binding(get: { rangeTo }, set: { to = $0 }), hint: String(localized: "Графіки й розрахунки нижче використовують лише цю ділянку: оберіть дужками ділянку з різкими нахилами (PID) чи стабільного польоту (фільтри)."))
                if let d = data {
                    timeCard(d)
                    termsCard(d)
                    stepCard(d)
                    spectrumCard(d)
                } else if !busy {
                    ContentUnavailableView("Недостатньо даних PID", systemImage: "chart.xyaxis.line", description: Text("Для PID Review потрібні повідомлення PIDR/PIDP/PIDY (швидкий лог атитюду, 100+ Гц) і ділянка польоту в обраному діапазоні."))
                }
            }.padding(14)
        }
        .task(id: "\(axis)|\(airOnly)|\(String(format: "%.2f", from))|\(String(format: "%.2f", rangeTo))") { await load() }
    }

    func load() async {
        busy = true; defer { busy = false }
        let (a, f, t, air, log) = (axis, from, rangeTo, airOnly, self.log)
        data = await Task.detached(priority: .userInitiated) { () -> Result? in
            let pid = Self.pids[a]
            guard let ax = ReviewEngine.loadAxis(log, pid: pid, from: f, to: t, airOnly: air) else { return nil }
            func decimated(_ y: [Double]) -> ([Double], [Double]) {
                let pts = LogGraphView.decimate(zip(ax.t, y).map { (t: $0, v: $1) })
                return (pts.map(\.t), pts.map(\.v))
            }
            var tarAct: [CSeries] = []
            for (i, (name, y)) in [("Очікувана (Tar)", ax.tar), ("Реальна (Act)", ax.act)].enumerated() {
                let (tt, vv) = decimated(y); tarAct.append(CSeries(id: name, name: name, color: ChartPalette.color(i), t: tt, v: vv))
            }
            var terms: [String: CSeries] = [:]
            for (i, (k, y)) in [("P", ax.p), ("I", ax.i), ("D", ax.d), ("FF", ax.ff)].enumerated() where y.count == ax.count {
                let (tt, vv) = decimated(y); terms[k] = CSeries(id: k, name: k, color: ChartPalette.color(i + 2), t: tt, v: vv)
            }
            let step = ReviewEngine.stepResponse(ax)
            var seg = 512; while Double(seg) > ax.fs * 4 { seg /= 2 }
            let err = zip(ax.tar, ax.act).map { $1 - $0 }
            func spec(_ x: [Double]) -> ReviewEngine.Spectrum { ReviewEngine.toDB(TuneDSP.welch(x, fs: ax.fs, seg: seg), maxF: min(ax.fs / 2, 125)) }
            return Result(ax: ax, tarAct: tarAct, terms: terms, step: step, specTar: spec(ax.tar), specAct: spec(ax.act), specErr: spec(err))
        }.value
    }

    func card<C: View>(_ title: String, _ icon: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(LocalizedStringKey(title), systemImage: icon).font(.headline)
            content()
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    func timeCard(_ d: Result) -> some View {
        card("Очікувана і реальна швидкість обертання", "waveform.path.ecg") {
            SeriesLegend(series: d.tarAct)
            InteractiveChart(series: d.tarAct, x0: d.ax.t.first ?? from, x1: max(d.ax.t.last ?? rangeTo, (d.ax.t.first ?? from) + 1), height: 200, cur: cur)
            ExplainBox(title: String(localized: "Як читати графік"), lines: [
                "Tar: швидкість обертання, яку просить пілот/навігація (°/с). Act: реальна швидкість із гіроскопа після фільтрів.",
                "У добре налаштованого апарата лінії майже збігаються, Act трохи відстає від Tar (затримка до 20–40 мс на малих коптерах).",
                "Act стабільно менший за Tar: підсилення P (чи FF) замале; Act перевищує Tar і гойдається навколо нього: P чи D завеликі або мало демпфування.",
                "Дрібне «пилоподібне» тремтіння Act при рівному Tar: шум чи вібрація (див. Filter Review)."])
        }
    }

    func termsCard(_ d: Result) -> some View {
        card("Внески регулятора (P, I, D, FF)", "slider.horizontal.3") {
            if d.terms.isEmpty { Text("У лозі немає складових PID (поля P, I, D, FF).").font(.callout).foregroundStyle(.secondary) }
            else {
                HStack(spacing: 14) { ForEach(["P", "I", "D", "FF"], id: \.self) { k in if d.terms[k] != nil { Toggle(lk(k), isOn: Binding(get: { showTerms.contains(k) }, set: { on in if on { showTerms.insert(k) } else { showTerms.remove(k) } })).toggleStyle(.checkbox) } } }
                let shown = ["P", "I", "D", "FF"].compactMap { d.terms[$0] }.filter { showTerms.contains($0.id) }
                if shown.isEmpty { Text("Виберіть складові для показу.").font(.callout).foregroundStyle(.secondary) }
                else {
                    SeriesLegend(series: shown)
                    InteractiveChart(series: shown, x0: d.ax.t.first ?? from, x1: max(d.ax.t.last ?? rangeTo, (d.ax.t.first ?? from) + 1), height: 170, cur: cur)
                }
            }
            ExplainBox(title: String(localized: "Що означають складові"), lines: [
                "P (пропорційна): реакція на поточну різницю Tar−Act; основна «сила» регулятора. Завелика P дає розгойдування.",
                "I (інтегральна): накопичує похибку й прибирає постійний зсув (вітер, баланс). Завелика I дає повільні коливання (1–3 Гц) і перерегулювання.",
                "D (диференційна): гасить швидкі зміни, демпфує перерегулювання. Рваний D на графіку означає шум: потрібна фільтрація або менше D.",
                "FF (прямий зв'язок): рухає мотори одразу за зміною команди, не чекаючи похибки; робить відгук швидшим без коливань."])
        }
    }

    func stepCard(_ d: Result) -> some View {
        let colors: [Color] = [.blue, .orange, .green]
        return card("Крокова відповідь (Step response)", "chart.line.uptrend.xyaxis") {
            if d.step.curves.isEmpty {
                Label("У вибраному діапазоні немає достатньо різких команд (потрібні різкі нахили понад ~30 °/с, не менше кількох секунд). Зробіть тестовий політ із різкими нахилами по осі й вибраний діапазон на ньому.", systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
            } else {
                let ser = d.step.curves.enumerated().map { XYSeries(name: String(localized: "\(loc($1.name)) · вікон: \($1.windows)"), color: colors[$0 % 3], x: d.step.tMs, y: $1.y) }
                XYChart(series: ser, xTitle: "мс після кроку", yTitle: "відносна відповідь (1.0 = збіг із командою)", xRange: 0...(d.step.tMs.last ?? 500),
                        yRange: -0.2...max(1.6, (d.step.curves.map(\.peak).max() ?? 1.4) * 1.1), lines: [XYLine(value: 1, label: "ідеал 1.0", color: .green, vertical: false)], height: 240)
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 4) {
                    GridRow { ForEach(["Крива", "Перерегулювання", "Час до 90 %", "Час стабілізації", "Піковe", "Усталене"], id: \.self) { Text(lk($0)).font(.caption2.weight(.semibold)).foregroundStyle(.secondary) } }
                    ForEach(d.step.curves) { c in
                        GridRow {
                            Text(LocalizedStringKey(c.name)).font(.caption)
                            Text(String(format: "%.0f %%", c.overshootPct)).foregroundStyle(c.overshootPct > 25 ? Color.red : (c.overshootPct > 12 ? Color.orange : Color.green))
                            Text(lk(c.riseMs.map { String(format: loc("%.0f мс"), $0) } ?? "—"))
                            Text(lk(c.settleMs.map { String(format: loc("%.0f мс"), $0) } ?? "—"))
                            Text(String(format: "%.2f", c.peak)); Text(String(format: "%.2f", c.final))
                        }.font(.system(.caption, design: .monospaced))
                    }
                }
                ForEach(verdicts(d.step.curves), id: \.self) { v in Label(LocalizedStringKey(v), systemImage: "lightbulb").font(.callout).fixedSize(horizontal: false, vertical: true) }
            }
            ExplainBox(title: String(localized: "Як читати крокову відповідь"), lines: [
                "Крива показує, як апарат відповів би на миттєвий «крок» команди: 1.0 означає, що реальна швидкість дорівнює команді. Розрахована зі всіх різких рухів у діапазоні (метод Вінера, як у PID-Analyzer), тому це усереднена картина.",
                "Добре: крива швидко (за 30–80 мс) доходить до 1.0, перерегулювання не більше 10–15 %, далі рівно тримається.",
                "Повільне наростання (лінія нижче ідеалу довго): P/FF замалі. Піднімайте P (або FF) невеликими кроками.",
                "Високий пік і хвиля після нього (перерегулювання): замало демпфування (D) чи завелике P. Підвищте D або зменшіть P.",
                "Усталене значення помітно нижче 1.0: недостатнє підсилення на низьких частотах (замала I або обмеження виходів); вище 1.0: перегрів контуру чи шум у розрахунку (мало даних)."])
        }
    }

    func verdicts(_ c: [ReviewEngine.StepCurve]) -> [String] {
        var out: [String] = []
        for k in c {
            guard k.final > 0.2 else { continue }
            if k.overshootPct > 25 { out.append(String(localized: "\(loc(k.name)): велике перерегулювання (\(Int(k.overshootPct)) %) — збільште демпфування D чи зменшіть P (див. вкладку «Помічник»).")) }
            else if let r = k.riseMs, r > 120 { out.append(String(localized: "\(loc(k.name)): повільний відгук (90 % за \(Int(r)) мс) — підсилення P/FF замале.")) }
            if k.final < 0.7 { out.append(String(localized: "\(loc(k.name)): усталене значення лише \(String(format: "%.2f", k.final)) від команди — підсилення замале чи регулятор насичується.")) }
            if k.final > 1.4 { out.append(String(localized: "\(loc(k.name)): усталене значення \(String(format: "%.2f", k.final)) — відповідь перевищує команду; контур, імовірно, коливається.")) }
        }
        if out.isEmpty && !c.isEmpty { out.append("Крокова відповідь у нормі: швидка, без значного перерегулювання.") }
        return out
    }

    func spectrumCard(_ d: Result) -> some View {
        card("Спектри швидкості обертання", "waveform") {
            XYChart(series: [XYSeries(name: "Tar", color: ChartPalette.color(0), x: d.specTar.f, y: d.specTar.db),
                             XYSeries(name: "Act", color: ChartPalette.color(1), x: d.specAct.f, y: d.specAct.db),
                             XYSeries(name: "Tar−Act", color: .red.opacity(0.8), x: d.specErr.f, y: d.specErr.db)],
                    xTitle: "Гц", yTitle: "дБ (°/с)²/Гц", height: 220)
            ExplainBox(title: String(localized: "Як читати спектр"), lines: [
                "Показує, на яких частотах «живуть» сигнали. Tar зазвичай лише в низьких частотах (рухи пілота до ~10 Гц).",
                "Виразний пік у Tar−Act (червона лінія) на одній частоті означає коливання контуру саме на ній: до 4 Гц зазвичай I/кутовий контур, 5–30 Гц це P/D, вище це шум і D.",
                "Підйом Act на високих частотах (понад 40 Гц) при плоскому Tar означає шум, який проходить крізь фільтри: перегляньте Filter Review."])
        }
    }
}

// MARK: - Filter Review

struct LogFilterReviewView: View {
    let log: DFLog
    @State private var axis = 0
    @State private var airOnly = true
    @State private var from = 0.0
    @State private var to = -1.0
    @State private var spec: (raw: ReviewEngine.Spectrum?, filtered: ReviewEngine.Spectrum?, rawFs: Double)?
    @State private var heat: ReviewEngine.Heat?
    @State private var busy = false
    private var rangeTo: Double { to < 0 ? log.duration : min(to, log.duration) }
    private var params: [String: Double] { Dictionary(log.parameters.map { ($0.name, $0.value) }, uniquingKeysWith: { a, _ in a }) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Filter Review").font(.title3.weight(.semibold))
                    Text("Шум гіроскопа до й після фільтрів, положення нотч-фільтра та спектрограма за газом. За мотивами ArduPilot Filter Review Tool.").font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 14) {
                    axisPicker($axis)
                    Toggle("Лише політ", isOn: $airOnly).toggleStyle(.checkbox)
                    if busy { ProgressView().controlSize(.small) }
                    Spacer()
                }
                LogRangeBar(log: log, from: $from, to: Binding(get: { rangeTo }, set: { to = $0 }), hint: String(localized: "Графіки й розрахунки нижче використовують лише цю ділянку: оберіть дужками ділянку з різкими нахилами (PID) чи стабільного польоту (фільтри)."))
                if let s = spec, s.raw != nil || s.filtered != nil {
                    spectrumCard(s)
                    if let h = heat { heatCard(h) }
                    paramsCard()
                } else if !busy {
                    ContentUnavailableView("Немає швидких даних гіроскопа", systemImage: "waveform", description: Text("Потрібен лог із сирими даними IMU високої частоти (на H7-платах: INS_LOG_BAT_OPT / швидке логування) та політ у вибраному діапазоні."))
                }
            }.padding(14)
        }
        .task(id: "\(axis)|\(airOnly)|\(String(format: "%.2f", from))|\(String(format: "%.2f", rangeTo))") { await load() }
    }

    func load() async {
        busy = true; defer { busy = false }
        let (a, f, t, air, log) = (axis, from, rangeTo, airOnly, self.log)
        let r = await Task.detached(priority: .userInitiated) { () -> ((raw: ReviewEngine.Spectrum?, filtered: ReviewEngine.Spectrum?, rawFs: Double), ReviewEngine.Heat?) in
            (ReviewEngine.gyroSpectra(log, axisIndex: a, pid: LogPIDReviewView.pids[a], from: f, to: t, airOnly: air),
             ReviewEngine.spectrogram(log, axisIndex: a, from: f, to: t, airOnly: air))
        }.value
        spec = r.0; heat = r.1
    }

    func card<C: View>(_ title: String, _ icon: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(LocalizedStringKey(title), systemImage: icon).font(.headline)
            content()
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    /// Центральні частоти нотч-фільтра у висінні: перша гармоніка й наступні за маскою INS_HNTCH_HMNCS.
    var notchLines: [XYLine] {
        let p = params
        guard (p["INS_HNTCH_ENABLE"] ?? 0) > 0, let f = p["INS_HNTCH_FREQ"], f > 0 else { return [] }
        let mode = Int(p["INS_HNTCH_MODE"] ?? 1), ref = p["INS_HNTCH_REF"] ?? 0
        let hover = p["MOT_THST_HOVER"] ?? 0.3
        let base = (mode == 1 && ref > 0) ? f * (hover / ref).squareRoot() : f
        let h = Int(p["INS_HNTCH_HMNCS"] ?? 1)
        return (0..<8).filter { h & (1 << $0) != 0 }.map { XYLine(value: base * Double($0 + 1), label: $0 == 0 ? "нотч" : "×\($0 + 1)", color: .green) }
    }

    func spectrumCard(_ s: (raw: ReviewEngine.Spectrum?, filtered: ReviewEngine.Spectrum?, rawFs: Double)) -> some View {
        var ser: [XYSeries] = []
        if let r = s.raw { ser.append(XYSeries(name: "Сирий гіроскоп (IMU)", color: .orange, x: r.f, y: r.db)) }
        if let f = s.filtered { ser.append(XYSeries(name: "Після фільтрів (Act)", color: .blue, x: f.f, y: f.db)) }
        var lines = notchLines
        if let g = params["INS_GYRO_FILTER"], g > 0 { lines.append(XYLine(value: g, label: String(localized: "LPF \(Int(g)) Гц"), color: .purple)) }
        var peakText = ""
        if let r = s.raw, let i = r.f.indices.filter({ r.f[$0] >= 25 && r.f[$0] <= s.rawFs * 0.45 }).max(by: { r.db[$0] < r.db[$1] }) {
            lines.append(XYLine(value: r.f[i], label: String(format: loc("пік %.0f Гц"), r.f[i]), color: .red))
            var att = ""
            if let f = s.filtered, let j = f.f.indices.min(by: { abs(f.f[$0] - r.f[i]) < abs(f.f[$1] - r.f[i]) }), abs(f.f[j] - r.f[i]) < 5 {
                att = String(format: loc(" Фільтри послаблюють цей пік приблизно на %.0f дБ."), r.db[i] - f.db[j])
            }
            peakText = String(format: loc("Найвищий пік шуму в сирому гіроскопі: %.0f Гц (%.0f дБ)."), r.f[i], r.db[i]) + att
        }
        let findings = TuneAdvisor.notchFindings(log, params: params, hover: params["MOT_THST_HOVER"] ?? 0.3, airborne: ReviewEngine.airborne(log))
        return card("Спектр шуму гіроскопа", "waveform") {
            XYChart(series: ser, xTitle: "Гц", yTitle: "дБ (°/с)²/Гц", xRange: 0...(min(250, (s.rawFs / 2).rounded()) == 0 ? 250 : min(250, (s.rawFs / 2).rounded())), lines: lines, height: 260)
            if !peakText.isEmpty { Label(LocalizedStringKey(peakText), systemImage: "scope").font(.callout).fixedSize(horizontal: false, vertical: true) }
            ForEach(findings) { f in Label("\(loc(f.title)): \(loc(f.detail))", systemImage: f.level == .ok ? "checkmark.circle" : "exclamationmark.triangle").font(.callout).foregroundStyle(f.level == .ok ? Color.green : Color.orange).fixedSize(horizontal: false, vertical: true) }
            ExplainBox(title: String(localized: "Як читати спектр і фільтри"), lines: [
                "Помаранчева лінія: шум у сирому гіроскопі (вібрація моторів і гвинтів). Синя: сигнал, який бачить регулятор після фільтрів. Чим нижче синя за помаранчеву на шумових частотах, тим краще працюють фільтри.",
                "Пік помаранчевої лінії (зазвичай 50–250 Гц) це частота обертання моторів та її гармоніки. Зелені вертикальні лінії: де стоїть гармонійний нотч-фільтр; пік має потрапляти в нього. Фіолетова: зріз НЧ-фільтра гіроскопа (INS_GYRO_FILTER).",
                "Пік не накритий нотчем: змініть INS_HNTCH_FREQ (і INS_HNTCH_REF = MOT_THST_HOVER для режиму за газом) або скористайтеся режимами за ESC-телеметрією.",
                "Загальний шум високий скрізь і піків немає: перевірте механіку (гвинти, кріплення), потім зменшуйте INS_GYRO_FILTER та ATC_RAT_*_FLTD. Фільтри додають запізнення, тому не занижуйте зрізи без потреби."])
        }
    }

    func heatCard(_ h: ReviewEngine.Heat) -> some View {
        let p = params
        var curves: [[(thr: Double, f: Double)]] = []
        if (p["INS_HNTCH_ENABLE"] ?? 0) > 0, Int(p["INS_HNTCH_MODE"] ?? 1) == 1, let f = p["INS_HNTCH_FREQ"], let ref = p["INS_HNTCH_REF"], ref > 0 {
            let hm = Int(p["INS_HNTCH_HMNCS"] ?? 1)
            for k in 0..<8 where hm & (1 << k) != 0 { curves.append(stride(from: 0.05, through: 1.0, by: 0.05).map { (thr: $0, f: f * ($0 / ref).squareRoot() * Double(k + 1)) }) }
        } else if (p["INS_HNTCH_ENABLE"] ?? 0) > 0, let f = p["INS_HNTCH_FREQ"], f > 0 {
            let hm = Int(p["INS_HNTCH_HMNCS"] ?? 1)
            for k in 0..<8 where hm & (1 << k) != 0 { curves.append([(thr: 0, f: f * Double(k + 1)), (thr: 1, f: f * Double(k + 1))]) }
        }
        return card("Спектрограма: частота шуму залежно від газу", "square.grid.3x3.fill.square") {
            HeatmapChart(heat: h, curves: curves, height: 280)
            HStack(spacing: 6) {
                Text("слабко").font(.caption2).foregroundStyle(.secondary)
                LinearGradient(colors: stride(from: 0.0, through: 1.0, by: 0.2).map { HeatmapChart.color($0) }, startPoint: .leading, endPoint: .trailing).frame(width: 140, height: 8).clipShape(Capsule())
                Text("сильно (до \(Int(h.maxDB)) дБ)").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text("білі пунктири: положення нотч-фільтра").font(.caption2).foregroundStyle(.tertiary)
            }
            ExplainBox(title: String(localized: "Як читати спектрограму"), lines: [
                "По горизонталі частота (Гц), по вертикалі газ (0–100 %). Яскраві смуги це шум: звичайно вони нахилені вправо вгору, бо оберти моторів ростуть із газом.",
                "Білі пунктири показують, де за налаштуваннями стоїть нотч-фільтр при кожному газі. Яскрава смуга має йти вздовж пунктиру: тоді фільтр її гасить. Якщо смуга відходить убік, фільтр треба підлаштувати (частота, опорний газ, ширина смуги).",
                "Кілька паралельних смуг це гармоніки (2×, 3× основної частоти); їх накриває параметр INS_HNTCH_HMNCS.",
                "Порожні рядки (сірі) означають, що на такому газі в лозі не було польоту."])
        }
    }

    func paramsCard() -> some View {
        let p = params
        let names = ["INS_GYRO_FILTER", "INS_ACCEL_FILTER", "INS_HNTCH_ENABLE", "INS_HNTCH_MODE", "INS_HNTCH_FREQ", "INS_HNTCH_BW", "INS_HNTCH_ATT", "INS_HNTCH_REF", "INS_HNTCH_HMNCS", "INS_HNTCH_OPTS",
                     "ATC_RAT_RLL_FLTD", "ATC_RAT_RLL_FLTT", "ATC_RAT_RLL_FLTE", "ATC_RAT_PIT_FLTD", "ATC_RAT_PIT_FLTT", "ATC_RAT_YAW_FLTD", "ATC_RAT_YAW_FLTE", "MOT_THST_HOVER"].filter { p[$0] != nil }
        return card("Налаштування фільтрів у лозі", "gearshape") {
            if names.isEmpty { Text("У лозі немає параметрів фільтрів.").font(.callout).foregroundStyle(.secondary) }
            else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 10)], alignment: .leading, spacing: 6) {
                    ForEach(names, id: \.self) { n in
                        HStack { Text(LocalizedStringKey(n)).font(.system(.caption, design: .monospaced)); Spacer(); Text(String(format: "%.4g", p[n]!)).font(.system(.caption, design: .monospaced).weight(.semibold)) }
                            .padding(.horizontal, 8).padding(.vertical, 4).background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
        }
    }
}
