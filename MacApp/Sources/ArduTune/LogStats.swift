import SwiftUI

/// Розширена статистика однієї серії на вибраному діапазоні.
struct SeriesStat: Identifiable {
    var id: String
    var color: Color
    var n = 0
    var rate = 0.0                       // Гц
    var min = 0.0, tMin = 0.0, max = 0.0, tMax = 0.0
    var mean = 0.0, median = 0.0, std = 0.0, rms = 0.0
    var first = 0.0, last = 0.0
    var slope = 0.0                      // одиниць за секунду (лінійна регресія)
    var span = 0.0                       // тривалість, с
    var outliers = 0, worstT = 0.0       // викиди понад 4σ
    var atMax = 0.0, atMin = 0.0         // частка часу біля максимуму / мінімуму
    var domFreq: Double?                 // домінантна частота коливань, Гц
    var domShare = 0.0                   // частка потужності в домінантній частоті
    var p2p: Double { max - min }
}

enum LogStatsMath {
    /// Лінійна інтерполяція серії на рівномірну сітку з n точок у [t0, t1].
    static func resample(_ s: [(t: Double, v: Double)], t0: Double, t1: Double, n: Int) -> [Double] {
        guard s.count > 1, n > 1, t1 > t0 else { return [] }
        var out = [Double](repeating: 0, count: n)
        var j = 0
        for i in 0..<n {
            let t = t0 + (t1 - t0) * Double(i) / Double(n - 1)
            while j + 1 < s.count - 1 && s[j + 1].t < t { j += 1 }
            let a = s[j], b = s[min(j + 1, s.count - 1)]
            let f = b.t > a.t ? min(max((t - a.t) / (b.t - a.t), 0), 1) : 0
            out[i] = a.v + (b.v - a.v) * f
        }
        return out
    }

    static func stat(_ id: String, _ raw: [(t: Double, v: Double)], color: Color) -> SeriesStat? {
        let s = raw.filter { $0.v.isFinite }
        guard s.count >= 2, let f = s.first, let l = s.last, l.t > f.t else { return nil }
        var r = SeriesStat(id: id, color: color)
        r.n = s.count; r.span = l.t - f.t; r.rate = Double(s.count - 1) / r.span
        r.first = f.v; r.last = l.v
        var mn = s[0], mx = s[0], sum = 0.0, sq = 0.0
        for p in s { if p.v < mn.v { mn = p }; if p.v > mx.v { mx = p }; sum += p.v; sq += p.v * p.v }
        let n = Double(s.count)
        r.min = mn.v; r.tMin = mn.t; r.max = mx.v; r.tMax = mx.t
        r.mean = sum / n; r.rms = (sq / n).squareRoot()
        r.std = max(0, sq / n - r.mean * r.mean).squareRoot()
        let sorted = s.map(\.v).sorted()
        r.median = sorted.count % 2 == 1 ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
        // тренд: регресія v(t)
        let tm = s.reduce(0) { $0 + $1.t } / n
        var sxy = 0.0, sxx = 0.0
        for p in s { sxy += (p.t - tm) * (p.v - r.mean); sxx += (p.t - tm) * (p.t - tm) }
        r.slope = sxx > 0 ? sxy / sxx : 0
        if r.std > 1e-12 {
            var worst = 0.0
            for p in s { let d = abs(p.v - r.mean); if d > 4 * r.std { r.outliers += 1; if d > worst { worst = d; r.worstT = p.t } } }
        }
        let rng = r.max - r.min
        if rng > 1e-12 {
            r.atMax = Double(s.filter { $0.v >= r.max - 0.01 * rng }.count) / n
            r.atMin = Double(s.filter { $0.v <= r.min + 0.01 * rng }.count) / n
        }
        // спектр: ресемплінг на 1024 точки, лінійний тренд і середнє віднімаються, вікно Ганна
        if r.std > 1e-9, s.count >= 32 {
            let N = 1024
            var x = resample(s, t0: f.t, t1: l.t, n: N)
            let xm = x.reduce(0, +) / Double(N)
            for i in 0..<N {
                let u = Double(i) / Double(N - 1)
                x[i] = (x[i] - xm - r.slope * r.span * (u - 0.5)) * (0.5 - 0.5 * cos(2 * .pi * Double(i) / Double(N - 1)))
            }
            let cs = (0..<N).map { cos(2 * .pi * Double($0) / Double(N)) }, sn = (0..<N).map { sin(2 * .pi * Double($0) / Double(N)) }
            let fmax = min(r.rate / 2, Double(N) / (2 * r.span))
            var best = 0, bestP = 0.0, total = 0.0
            let kmin = max(2, Int((1.5 / r.span).rounded(.up) * r.span))   // відкидаємо найповільніші складові
            for k in max(1, kmin)..<(N / 2) {
                let fr = Double(k) / r.span
                if fr > fmax { break }
                var re = 0.0, im = 0.0
                for i in 0..<N { let idx = (k * i) % N; re += x[i] * cs[idx]; im -= x[i] * sn[idx] }
                let p = re * re + im * im
                total += p
                if p > bestP { bestP = p; best = k }
            }
            if best > 0, total > 0 { r.domFreq = Double(best) / r.span; r.domShare = bestP / total }
        }
        return r
    }

    /// Кореляція Пірсона двох серій на спільній сітці.
    static func correlation(_ a: [(t: Double, v: Double)], _ b: [(t: Double, v: Double)], t0: Double, t1: Double) -> Double? {
        let x = resample(a.filter { $0.v.isFinite }, t0: t0, t1: t1, n: 400), y = resample(b.filter { $0.v.isFinite }, t0: t0, t1: t1, n: 400)
        guard x.count == y.count, !x.isEmpty else { return nil }
        let n = Double(x.count), mx = x.reduce(0, +) / n, my = y.reduce(0, +) / n
        var sxy = 0.0, sxx = 0.0, syy = 0.0
        for i in 0..<x.count { sxy += (x[i] - mx) * (y[i] - my); sxx += (x[i] - mx) * (x[i] - mx); syy += (y[i] - my) * (y[i] - my) }
        guard sxx > 1e-12, syy > 1e-12 else { return nil }
        return sxy / (sxx * syy).squareRoot()
    }
}

/// Розширений аналіз вибраних серій під графіком: статистика, спостереження, спектр і кореляції на поточному діапазоні.
struct LogStatsPanel: View {
    let log: DFLog
    let keys: [(id: String, color: Color)]
    let from: Double, to: Double
    @State private var stats: [SeriesStat] = []
    @State private var corr: [[Double?]] = []
    @State private var busy = false
    @AppStorage("log.stats.open") private var open = true

    static func v(_ x: Double) -> String {
        let a = abs(x)
        if a >= 10000 { return String(format: "%.0f", x) }
        if a >= 1000 { return String(format: "%.1f", x) }
        if a >= 10 { return String(format: "%.2f", x) }
        if a >= 0.01 || a == 0 { return String(format: "%.3f", x) }
        return String(format: "%.2e", x)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { withAnimation(.snappy(duration: 0.2)) { open.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold)).rotationEffect(.degrees(open ? 0 : -90)).frame(width: 14)
                    Label("Розширений аналіз", systemImage: "function").font(.callout.weight(.semibold))
                    Text(String(format: loc("%@ – %@ · %.0f с"), fmtT(from), fmtT(to), max(0, to - from))).font(.caption).foregroundStyle(.secondary)
                    if busy { ProgressView().controlSize(.mini) }
                    Spacer()
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            if open {
                if stats.isEmpty && !busy { Text("У вибраному діапазоні немає даних.").font(.caption).foregroundStyle(.secondary) }
                if !stats.isEmpty {
                    ScrollView(.horizontal, showsIndicators: true) { table }
                    observations
                    if corr.count >= 2 { correlationGrid }
                }
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        .task(id: keys.map(\.id).joined(separator: ",") + "|\(from)|\(to)") { await compute() }
    }

    // MARK: Таблиця
    private var table: some View {
        Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 5) {
            GridRow {
                ForEach(["Серія", "Мін", "Макс", "Середнє", "Медіана", "σ", "RMS", "Розмах", "Початок → кінець", "Тренд, /с", "Вибірок · Гц", "Домін. частота"], id: \.self) { h in
                    Text(LocalizedStringKey(h)).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).gridColumnAlignment(h == "Серія" ? .leading : .trailing)
                }
            }
            Divider().gridCellColumns(12)
            ForEach(stats) { s in
                GridRow {
                    HStack(spacing: 5) { Circle().fill(s.color).frame(width: 7, height: 7); Text(LocalizedStringKey(s.id)).lineLimit(1) }.frame(maxWidth: .infinity, alignment: .leading)
                    valueTime(s.min, s.tMin); valueTime(s.max, s.tMax)
                    Text(lk(Self.v(s.mean))); Text(lk(Self.v(s.median))); Text(lk(Self.v(s.std))); Text(lk(Self.v(s.rms))); Text(lk(Self.v(s.p2p)))
                    Text("\(Self.v(s.first)) → \(Self.v(s.last))")
                    Text(String(format: "%+@", Self.v(s.slope))).foregroundStyle(abs(s.slope * s.span) > 1.5 * max(s.std, 1e-12) ? Color.orange : .primary)
                    Text("\(s.n) · \(String(format: "%.1f", s.rate))")
                    if let f = s.domFreq { Text(String(format: loc("%.2f Гц"), f)).foregroundStyle(s.domShare > 0.25 ? Color.orange : .primary).tip(String(format: loc("Частка потужності спектра: %.0f %%"), s.domShare * 100)) }
                    else { Text("—").foregroundStyle(.tertiary) }
                }
                .font(.system(.caption, design: .monospaced))
            }
        }
        .padding(.bottom, 4)
    }
    private func valueTime(_ v: Double, _ t: Double) -> some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(lk(Self.v(v)))
            Text(lk(fmtT(t))).font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary)
        }
    }

    // MARK: Спостереження
    private func notes(_ s: SeriesStat) -> [(String, String, Color)] {
        var o: [(String, String, Color)] = []
        let rng = s.p2p
        if rng < 1e-9 { return [("equal.circle", String(localized: "значення не змінювалось (\(Self.v(s.mean)))"), .secondary)] }
        if s.atMax > 0.15 { o.append(("arrow.up.to.line", String(format: loc("%.0f %% часу біля максимуму %@: можливе насичення або обмеження"), s.atMax * 100, Self.v(s.max)), .orange)) }
        if s.atMin > 0.15 { o.append(("arrow.down.to.line", String(format: loc("%.0f %% часу біля мінімуму %@"), s.atMin * 100, Self.v(s.min)), .secondary)) }
        if s.outliers > 0 { o.append(("exclamationmark.triangle", String(localized: "\(s.outliers) викидів понад 4σ, найбільший о \(fmtT(s.worstT))"), .orange)) }
        if abs(s.slope * s.span) > 1.5 * s.std && s.std > 0 { o.append(("chart.line.uptrend.xyaxis", String(localized: "виражений тренд: \(String(format: "%+@", Self.v(s.slope * s.span))) за діапазон"), .secondary)) }
        if let f = s.domFreq, s.domShare > 0.25 { o.append(("waveform", String(format: loc("виражене коливання біля %.2f Гц (%.0f %% потужності спектра)"), f, s.domShare * 100), .orange)) }
        if s.std > 0, s.rate < 2 { o.append(("clock", String(format: loc("рідкісні вибірки (%.1f Гц): спектр недостовірний"), s.rate), .secondary)) }
        return o
    }
    @ViewBuilder private var observations: some View {
        let rows = stats.map { ($0, notes($0)) }.filter { !$0.1.isEmpty }
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Спостереження").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(rows, id: \.0.id) { s, list in
                    ForEach(list.indices, id: \.self) { i in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Circle().fill(s.color).frame(width: 6, height: 6)
                            Image(systemName: list[i].0).foregroundStyle(list[i].2).frame(width: 14)
                            Text("\(s.id): \(list[i].1)").font(.caption).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    // MARK: Кореляції
    private var correlationGrid: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Кореляція між серіями").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Grid(horizontalSpacing: 3, verticalSpacing: 3) {
                GridRow {
                    Color.clear.frame(width: 1, height: 1)
                    ForEach(stats.indices, id: \.self) { j in Text(lk(short(stats[j].id))).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary).frame(width: 56) }
                }
                ForEach(stats.indices, id: \.self) { i in
                    GridRow {
                        Text(lk(short(stats[i].id))).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary).frame(width: 56, alignment: .trailing)
                        ForEach(stats.indices, id: \.self) { j in
                            let c = i < corr.count && j < corr[i].count ? corr[i][j] : nil
                            Text(lk(c.map { String(format: "%+.2f", $0) } ?? "—")).font(.system(size: 10, design: .monospaced))
                                .frame(width: 56, height: 20)
                                .background(color(c), in: RoundedRectangle(cornerRadius: 4))
                        }
                    }
                }
            }
            Text("Близько +1: ростуть разом; близько −1: одна росте, інша падає; біля 0: зв'язку немає.").font(.caption2).foregroundStyle(.tertiary)
        }
    }
    private func short(_ id: String) -> String { id.count > 9 ? String(id.suffix(9)) : id }
    private func color(_ c: Double?) -> Color {
        guard let c else { return .clear }
        return (c >= 0 ? Color.green : Color.red).opacity(min(0.55, abs(c) * 0.55))
    }

    // MARK: Обчислення
    private func compute() async {
        busy = true
        try? await Task.sleep(nanoseconds: 250_000_000)
        guard !Task.isCancelled else { return }
        let ks = keys, a = from, b = to, log = self.log
        let (st, cr) = await Task.detached(priority: .userInitiated) { () -> ([SeriesStat], [[Double?]]) in
            var out: [SeriesStat] = []
            var raws: [[(t: Double, v: Double)]] = []
            for k in ks {
                let p = k.id.split(separator: ".").map(String.init)
                guard p.count == 2 else { continue }
                let s = log.series(p[0], p[1]).filter { $0.t >= a && $0.t <= b }
                if let st = LogStatsMath.stat(k.id, s, color: k.color) { out.append(st); raws.append(s) }
            }
            var m: [[Double?]] = []
            if out.count >= 2 && out.count <= 10 {
                for i in 0..<out.count {
                    m.append((0..<out.count).map { j in i == j ? 1.0 : LogStatsMath.correlation(raws[i], raws[j], t0: a, t1: b) })
                }
            }
            return (out, m)
        }.value
        guard !Task.isCancelled else { return }
        stats = st; corr = cr; busy = false
    }
}
