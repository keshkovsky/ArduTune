import Foundation

/// Розрахунки для «PID Review» і «Filter Review» (за мотивами PID-Analyzer / PID Toolbox): крокова відповідь деконволюцією Вінера,
/// спектри шуму гіроскопа до й після фільтрів, спектрограма за газом. Усі швидкості в °/с.
enum ReviewEngine {
    static let radToDeg = 57.29578

    struct AxisData {
        var t: [Double] = [], tar: [Double] = [], act: [Double] = []
        var p: [Double] = [], i: [Double] = [], d: [Double] = [], ff: [Double] = []
        var fs = 0.0
        var count: Int { t.count }
    }

    /// Політ: вихідний газ вище частки газу висіння (коптер) або вище 15 % (літак), у вікні ARM.
    static func airborne(_ log: DFLog) -> (Double) -> Bool {
        let thr = log.series("CTUN", "ThO")
        let hover = log.parameters.first { $0.name == "MOT_THST_HOVER" }?.value ?? 0.3
        let (a0, a1) = LogAssistant.armedWindow(log)
        let plane = log.kind == "plane"
        return { t in
            guard t >= a0, t <= a1 else { return false }
            guard thr.count > 3 else { return true }
            var lo = 0, hi = thr.count - 1
            while lo < hi { let m = (lo + hi) / 2; if thr[m].t < t { lo = m + 1 } else { hi = m } }
            return thr[lo].v > (plane ? 0.15 : hover * 0.6)
        }
    }

    static func loadAxis(_ log: DFLog, pid: String, from: Double, to: Double, airOnly: Bool) -> AxisData? {
        let tar = log.series(pid, "Tar"), act = log.series(pid, "Act")
        guard tar.count > 400, tar.count == act.count else { return nil }
        let air = airOnly ? airborne(log) : { _ in true }
        let pS = log.series(pid, "P"), iS = log.series(pid, "I"), dS = log.series(pid, "D"), fS = log.series(pid, "FF")
        var a = AxisData()
        a.fs = Double(tar.count - 1) / max(tar.last!.t - tar.first!.t, 0.1)
        for k in tar.indices where tar[k].t >= from && tar[k].t <= to && air(tar[k].t) {
            a.t.append(tar[k].t); a.tar.append(tar[k].v * radToDeg); a.act.append(act[k].v * radToDeg)
            if pS.count == tar.count { a.p.append(pS[k].v) }
            if iS.count == tar.count { a.i.append(iS[k].v) }
            if dS.count == tar.count { a.d.append(dS[k].v) }
            if fS.count == tar.count { a.ff.append(fS[k].v) }
        }
        return a.count > 300 ? a : nil
    }

    // MARK: Крокова відповідь

    struct StepCurve: Identifiable {
        var id: String { name }
        var name: String
        var y: [Double]
        var windows: Int
        var final = 0.0, peak = 0.0, peakMs = 0.0, overshootPct = 0.0, riseMs: Double?, settleMs: Double?
    }
    struct StepResult { var tMs: [Double] = []; var curves: [StepCurve] = []; var windows = 0 }

    /// Оцінка кроковоїовідповіді «завдання → реальна швидкість»: вікна ~2 с, деконволюція Вінера, накопичення імпульсної характеристики.
    static func stepResponse(_ ax: AxisData, maxMs: Double = 500, minMove: Double = 30) -> StepResult {
        let fs = ax.fs
        var N = 64
        while Double(N * 2) <= 2.0 * fs { N *= 2 }
        let M = Int(maxMs / 1000 * fs)
        guard ax.count > N * 2, M > 8, M < N else { return StepResult() }
        let win = (0..<N).map { 0.5 - 0.5 * cos(2 * .pi * Double($0) / Double(N - 1)) }
        var low: [(y: [Double], w: Double)] = [], high: [(y: [Double], w: Double)] = []
        var start = 0
        var re = [Double](repeating: 0, count: N), im = [Double](repeating: 0, count: N)
        var yr = [Double](repeating: 0, count: N), yi = [Double](repeating: 0, count: N)
        while start + N <= ax.count {
            defer { start += N / 2 }
            // суцільність: без розривів у часі
            guard ax.t[start + N - 1] - ax.t[start] < Double(N) / fs * 1.15 else { continue }
            let xs = Array(ax.tar[start..<start + N]), ys = Array(ax.act[start..<start + N])
            let peak = xs.map(abs).max() ?? 0
            guard peak >= minMove, TuneDSP.rms(xs) > minMove * 0.3 else { continue }
            let mx = TuneDSP.mean(xs), my = TuneDSP.mean(ys)
            for i in 0..<N { re[i] = (xs[i] - mx) * win[i]; im[i] = 0; yr[i] = (ys[i] - my) * win[i]; yi[i] = 0 }
            TuneDSP.fft(&re, &im); TuneDSP.fft(&yr, &yi)
            var pw = 0.0
            for k in 0..<N { pw += re[k] * re[k] + im[k] * im[k] }
            let lam = 0.02 * pw / Double(N)
            var hr = [Double](repeating: 0, count: N), hi = [Double](repeating: 0, count: N)
            for k in 0..<N {
                let den = re[k] * re[k] + im[k] * im[k] + lam
                // H = Y · conj(X) / (|X|² + λ)
                hr[k] = (yr[k] * re[k] + yi[k] * im[k]) / den
                hi[k] = (yi[k] * re[k] - yr[k] * im[k]) / den
            }
            TuneDSP.fft(&hr, &hi, inverse: true)
            var step = [Double](repeating: 0, count: M), acc = 0.0
            for i in 0..<M { acc += hr[i]; step[i] = acc }
            let w = pw
            if peak >= 150 { high.append((step, w)) } else { low.append((step, w)) }
        }
        func avg(_ a: [(y: [Double], w: Double)]) -> [Double] {
            let sw = a.reduce(0) { $0 + $1.w }
            var o = [Double](repeating: 0, count: M)
            for e in a { for i in 0..<M { o[i] += e.y[i] * e.w / sw } }
            return o
        }
        var res = StepResult()
        res.tMs = (0..<M).map { Double($0) / fs * 1000 }
        res.windows = low.count + high.count
        func make(_ name: String, _ y: [Double], _ n: Int) -> StepCurve {
            var c = StepCurve(name: name, y: y, windows: n)
            let i0 = Int(0.30 * fs), i1 = min(M, Int(0.50 * fs))
            c.final = i1 > i0 ? TuneDSP.mean(Array(y[i0..<i1])) : (y.last ?? 0)
            if let pk = y.indices.max(by: { y[$0] < y[$1] }) { c.peak = y[pk]; c.peakMs = res.tMs[pk] }
            if c.final > 0.2 {
                c.overshootPct = max(0, (c.peak / c.final - 1) * 100)
                c.riseMs = y.indices.first { y[$0] >= 0.9 * c.final }.map { res.tMs[$0] }
                if let last = y.indices.last(where: { abs(y[$0] - c.final) > 0.1 * c.final }) { c.settleMs = res.tMs[min(last + 1, M - 1)] } else { c.settleMs = 0 }
            }
            return c
        }
        if low.count >= 3 && high.count >= 3 {
            res.curves = [make("малі команди (<150 °/с)", avg(low), low.count), make("великі команди (≥150 °/с)", avg(high), high.count)]
        } else if !(low + high).isEmpty {
            let all = low + high
            res.curves = [make("усі команди", avg(all), all.count)]
        }
        return res
    }

    // MARK: Спектри гіроскопа

    struct Spectrum { var f: [Double]; var db: [Double] }
    static func toDB(_ sp: (f: [Double], p: [Double]), maxF: Double) -> Spectrum {
        var f: [Double] = [], d: [Double] = []
        for (a, b) in zip(sp.f, sp.p) where a <= maxF && a > 0 { f.append(a); d.append(10 * log10(max(b, 1e-12))) }
        return Spectrum(f: f, db: d)
    }

    /// Спектри сирого гіроскопа (IMU.Gyr*) і сигналу після фільтрів (PIDx.Act) для осі; лише політ.
    static func gyroSpectra(_ log: DFLog, axisIndex: Int, pid: String, from: Double, to: Double, airOnly: Bool) -> (raw: Spectrum?, filtered: Spectrum?, rawFs: Double) {
        let air = airOnly ? airborne(log) : { _ in true }
        let name = ["GyrX", "GyrY", "GyrZ"][axisIndex]
        var raw: Spectrum?, fs = 0.0
        let g = log.series("IMU", name)
        if g.count > 4000 {
            fs = Double(g.count - 1) / max(g.last!.t - g.first!.t, 0.1)
            let x = g.filter { $0.t >= from && $0.t <= to && air($0.t) }.map { $0.v * radToDeg }
            var seg = 1024; while Double(seg) > fs * 4 { seg /= 2 }
            if x.count > seg * 3 { raw = toDB(TuneDSP.welch(x, fs: fs, seg: seg), maxF: min(fs / 2, 500)) }
        }
        var filt: Spectrum?
        if let ax = loadAxis(log, pid: pid, from: from, to: to, airOnly: airOnly) {
            var seg = 512; while Double(seg) > ax.fs * 4 { seg /= 2 }
            if ax.count > seg * 3 { filt = toDB(TuneDSP.welch(ax.act, fs: ax.fs, seg: seg), maxF: ax.fs / 2) }
        }
        return (raw, filt, fs)
    }

    // MARK: Спектрограма за газом

    struct Heat { var freqs: [Double] = []; var thr: [Double] = []; var db: [[Double]] = []; var maxDB = 0.0 }   // db[thrBin][freqBin], NaN = немає даних

    static func spectrogram(_ log: DFLog, axisIndex: Int, from: Double, to: Double, airOnly: Bool, thrBins: Int = 20, maxF: Double = 300) -> Heat? {
        let thr = log.series("CTUN", "ThO")
        let g = log.series("IMU", ["GyrX", "GyrY", "GyrZ"][axisIndex])
        guard thr.count > 20, g.count > 4000 else { return nil }
        let fs = Double(g.count - 1) / max(g.last!.t - g.first!.t, 0.1)
        var seg = 512; while Double(seg) > fs * 1.2 { seg /= 2 }
        guard seg >= 128 else { return nil }
        let air = airOnly ? airborne(log) : { _ in true }
        let win = (0..<seg).map { 0.5 - 0.5 * cos(2 * .pi * Double($0) / Double(seg - 1)) }
        let wn = win.reduce(0) { $0 + $1 * $1 }
        let half = seg / 2
        let nF = min(half, Int(maxF / (fs / Double(seg))))
        var sum = [[Double]](repeating: [Double](repeating: 0, count: nF), count: thrBins), cnt = [Int](repeating: 0, count: thrBins)
        var re = [Double](repeating: 0, count: seg), im = [Double](repeating: 0, count: seg)
        func thrAt(_ t: Double) -> Double {
            var lo = 0, hi = thr.count - 1
            while lo < hi { let m = (lo + hi) / 2; if thr[m].t < t { lo = m + 1 } else { hi = m } }
            return thr[lo].v
        }
        var s = 0
        while s + seg <= g.count {
            defer { s += seg / 2 }
            let tc = g[s + seg / 2].t
            guard tc >= from, tc <= to, air(tc) else { continue }
            var m = 0.0; for i in 0..<seg { m += g[s + i].v }; m /= Double(seg)
            for i in 0..<seg { re[i] = (g[s + i].v - m) * radToDeg * win[i]; im[i] = 0 }
            TuneDSP.fft(&re, &im)
            let b = min(thrBins - 1, max(0, Int(thrAt(tc) * Double(thrBins))))
            for k in 1..<nF { sum[b][k] += (re[k] * re[k] + im[k] * im[k]) / (fs * wn) }
            cnt[b] += 1
        }
        var h = Heat()
        h.freqs = (0..<nF).map { Double($0) * fs / Double(seg) }
        h.thr = (0..<thrBins).map { (Double($0) + 0.5) / Double(thrBins) }
        var mx = -1e9
        for b in 0..<thrBins {
            if cnt[b] < 2 { h.db.append([Double](repeating: .nan, count: nF)); continue }
            let row = sum[b].map { 10 * log10(max($0 / Double(cnt[b]), 1e-12)) }
            mx = max(mx, row.max() ?? mx)
            h.db.append(row)
        }
        h.maxDB = mx
        return h.db.contains { !$0[0].isNaN } ? h : nil
    }
}
