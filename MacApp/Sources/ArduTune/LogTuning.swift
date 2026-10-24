import Foundation

/// Запропонована зміна параметра (PID чи фільтра) з поясненням: застосовується до польотника кнопкою в помічнику.
struct ParamChange: Identifiable {
    enum Op { case scale(Double), set(Double) }
    let id = UUID()
    let name: String
    let op: Op
    let why: String
    /// Нове значення від поточного.
    func proposed(from cur: Double) -> Double {
        switch op { case .scale(let k): return cur * k; case .set(let v): return v }
    }
}

/// Обробка сигналів для аналізу налаштування: спектр (Welch), кореляція, нормалізовані оцінки.
enum TuneDSP {
    static func rms(_ x: [Double]) -> Double { x.isEmpty ? 0 : (x.reduce(0) { $0 + $1 * $1 } / Double(x.count)).squareRoot() }
    static func mean(_ x: [Double]) -> Double { x.isEmpty ? 0 : x.reduce(0, +) / Double(x.count) }

    /// Швидке перетворення Фур'є (радикс-2, на місці). `n` має бути степенем двійки; inverse масштабує на 1/n.
    static func fft(_ re: inout [Double], _ im: inout [Double], inverse: Bool = false) {
        let n = re.count
        guard n > 1, n & (n - 1) == 0 else { return }
        var j = 0
        for i in 1..<n {
            var bit = n >> 1
            while j & bit != 0 { j ^= bit; bit >>= 1 }
            j ^= bit
            if i < j { re.swapAt(i, j); im.swapAt(i, j) }
        }
        var len = 2
        while len <= n {
            let ang = 2 * Double.pi / Double(len) * (inverse ? 1 : -1)
            let wr = cos(ang), wi = sin(ang)
            var i = 0
            while i < n {
                var cr = 1.0, ci = 0.0
                for k in 0..<(len / 2) {
                    let a = i + k, b = i + k + len / 2
                    let tr = re[b] * cr - im[b] * ci, ti = re[b] * ci + im[b] * cr
                    re[b] = re[a] - tr; im[b] = im[a] - ti
                    re[a] += tr; im[a] += ti
                    let nr = cr * wr - ci * wi
                    ci = cr * wi + ci * wr; cr = nr
                }
                i += len
            }
            len <<= 1
        }
        if inverse { for i in 0..<n { re[i] /= Double(n); im[i] /= Double(n) } }
    }

    /// Спектральна щільність за Велчем (FFT): сегменти по `seg` відліків (степінь двійки) з перекриттям 50 % і вікном Ганна. Повертає (частоти, потужність).
    static func welch(_ x: [Double], fs: Double, seg: Int = 1024) -> (f: [Double], p: [Double]) {
        guard x.count >= seg, fs > 0, seg & (seg - 1) == 0 else { return ([], []) }
        let half = seg / 2
        let win = (0..<seg).map { 0.5 - 0.5 * cos(2 * .pi * Double($0) / Double(seg - 1)) }
        let wn = win.reduce(0) { $0 + $1 * $1 }
        var psd = [Double](repeating: 0, count: half)
        var cnt = 0
        let step = half
        let stride = max(step, (x.count - seg) / 200)
        var start = 0
        var re = [Double](repeating: 0, count: seg), im = [Double](repeating: 0, count: seg)
        while start + seg <= x.count {
            var m = 0.0
            for i in 0..<seg { m += x[start + i] }
            m /= Double(seg)
            for i in 0..<seg { re[i] = (x[start + i] - m) * win[i]; im[i] = 0 }
            fft(&re, &im)
            for k in 1..<half { psd[k] += (re[k] * re[k] + im[k] * im[k]) / (fs * wn) }
            cnt += 1; start += stride
        }
        guard cnt > 0 else { return ([], []) }
        return ((0..<half).map { Double($0) * fs / Double(seg) }, psd.map { $0 / Double(cnt) })
    }

    /// Найвищий пік у діапазоні частот: (частота, відношення до медіани спектра, частка потужності в смузі ±15 % від піка від повної потужності діапазону).
    static func peak(_ sp: (f: [Double], p: [Double]), from lo: Double, to hi: Double) -> (f: Double, prom: Double, share: Double, bandPower: Double)? {
        let idx = sp.f.indices.filter { sp.f[$0] >= lo && sp.f[$0] <= hi }
        guard idx.count > 4 else { return nil }
        let vals = idx.map { sp.p[$0] }.sorted()
        let med = max(vals[vals.count / 2], 1e-18)
        guard let best = idx.max(by: { sp.p[$0] < sp.p[$1] }) else { return nil }
        let f0 = sp.f[best], df = sp.f[1] - sp.f[0]
        let total = idx.reduce(0) { $0 + sp.p[$1] }
        let band = idx.filter { abs(sp.f[$0] - f0) <= max(f0 * 0.15, 2 * df) }.reduce(0) { $0 + sp.p[$1] }
        return (f0, sp.p[best] / med, total > 0 ? band / total : 0, band * df)
    }

    /// Частка потужності вище `cut` Гц від загальної (шум проти корисного сигналу).
    static func highShare(_ sp: (f: [Double], p: [Double]), above cut: Double) -> Double {
        let tot = sp.p.reduce(0, +)
        guard tot > 0 else { return 0 }
        return zip(sp.f, sp.p).filter { $0.0 >= cut }.reduce(0) { $0 + $1.1 } / tot
    }

    /// Затримка (с) і коефіцієнт підсилення відгуку `y` відносно завдання `x` на лагах 0…maxLag (за максимумом кореляції).
    static func lagGain(_ x: [Double], _ y: [Double], fs: Double, maxLag: Double) -> (lag: Double, gain: Double, corr: Double)? {
        let n = min(x.count, y.count)
        guard n > 200, fs > 0 else { return nil }
        let mx = mean(Array(x.prefix(n))), my = mean(Array(y.prefix(n)))
        let L = max(1, Int(maxLag * fs))
        var best = (lag: 0, c: -2.0, g: 0.0)
        let xs = (0..<n).map { x[$0] - mx }, ys = (0..<n).map { y[$0] - my }
        let sxx = xs.reduce(0) { $0 + $1 * $1 }
        for l in 0...L {
            var sxy = 0.0, syy = 0.0
            for i in 0..<(n - l) { sxy += xs[i] * ys[i + l]; syy += ys[i + l] * ys[i + l] }
            let c = sxy / max((sxx * syy).squareRoot(), 1e-18)
            if c > best.c { best = (l, c, sxx > 0 ? sxy / sxx : 0) }
        }
        return (Double(best.lag) / fs, best.g, best.c)
    }
}

// MARK: - Поради з налаштування PID і фільтрів за логом

/// Аналіз реакції контурів керування та шуму гіроскопа за логом. Правила спираються на офіційні керівництва ArduPilot:
/// «Manual tuning of Roll and Pitch», «Initial tuning flight», «Dynamic Harmonic Notch Filter», «Plane: roll/pitch tuning, AUTOTUNE».
enum TuneAdvisor {
    struct Axis {
        let key: String                 // R / P / Y
        let nameGen: String             // «крену»
        let pid: String                 // PIDR / PIDP / PIDY
        let copterRate: String          // ATC_RAT_RLL
        let planeRate: String           // RLL_RATE
        let angP: String?               // ATC_ANG_RLL_P
        let tconst: String?             // RLL2SRV_TCONST
        let attDes: String?, att: String?
        let rollPitch: Bool
    }
    static let axes: [Axis] = [
        Axis(key: "R", nameGen: "крену", pid: "PIDR", copterRate: "ATC_RAT_RLL", planeRate: "RLL_RATE", angP: "ATC_ANG_RLL_P", tconst: "RLL2SRV_TCONST", attDes: "DesRoll", att: "Roll", rollPitch: true),
        Axis(key: "P", nameGen: "тангажа", pid: "PIDP", copterRate: "ATC_RAT_PIT", planeRate: "PTCH_RATE", angP: "ATC_ANG_PIT_P", tconst: "PTCH2SRV_TCONST", attDes: "DesPitch", att: "Pitch", rollPitch: true),
        Axis(key: "Y", nameGen: "рискання", pid: "PIDY", copterRate: "ATC_RAT_YAW", planeRate: "YAW_RATE", angP: "ATC_ANG_YAW_P", tconst: nil, attDes: nil, att: nil, rollPitch: false),
    ]
    static let radToDeg = 57.29578

    static func run(_ log: DFLog) -> [LogFinding] {
        guard log.kind == "copter" || log.kind == "plane" else {
            return [LogFinding(level: .info, title: String(localized: "Налаштування PID для цього типу апарата не реалізовано"), detail: String(localized: "Поради з PID і фільтрів зараз доступні для коптерів і літаків."))]
        }
        let plane = log.kind == "plane"
        let params = Dictionary(log.parameters.map { ($0.name, $0.value) }, uniquingKeysWith: { a, _ in a })
        var out: [LogFinding] = []

        // політ: за вихідним газом (CTUN.ThO) або за вікном ARM
        let thr = log.series("CTUN", "ThO")
        let hover = params["MOT_THST_HOVER"] ?? 0.3
        let (a0, a1) = LogAssistant.armedWindow(log)
        func airborne(_ t: Double) -> Bool {
            guard t >= a0, t <= a1 else { return false }
            guard thr.count > 3 else { return true }
            var lo = 0, hi = thr.count - 1
            while lo < hi { let m = (lo + hi) / 2; if thr[m].t < t { lo = m + 1 } else { hi = m } }
            return thr[lo].v > (plane ? 0.15 : hover * 0.6)
        }

        var analysed = 0
        var lowRate = false
        for ax in axes {
            let tarS = log.series(ax.pid, "Tar"), actS = log.series(ax.pid, "Act")
            guard tarS.count > 400, tarS.count == actS.count else { continue }
            let dur = (tarS.last!.t - tarS.first!.t)
            let fs = Double(tarS.count - 1) / max(dur, 0.1)
            if fs < 80 { lowRate = true; continue }
            let idx = tarS.indices.filter { airborne(tarS[$0].t) }
            guard idx.count > 1500 else { continue }
            analysed += 1
            let T = idx.map { tarS[$0].v }, A = idx.map { actS[$0].v }
            let E = zip(T, A).map { $1 - $0 }
            let times = idx.map { tarS[$0].t }
            let pre = plane ? ax.planeRate : ax.copterRate
            func has(_ n: String) -> Bool { params[n] != nil }
            func chg(_ suffix: String, _ k: Double, _ why: String) -> ParamChange? {
                let n = pre + suffix
                return has(n) ? ParamChange(name: n, op: .scale(k), why: why) : nil
            }
            let keys = ["\(ax.pid).Tar", "\(ax.pid).Act"]
            // вікно найбільшого відхилення (ковзне середньоквадратичне 1 с)
            let rolled = LogMath.rollingRMS(zip(times, E).map { (t: $0, v: $1) }, window: 1.0)
            let worst = rolled.max { $0.v < $1.v }
            let window = worst.map { (max(0, $0.t - 4), $0.t + 2) }

            let rmsT = TuneDSP.rms(T), rmsE = TuneDSP.rms(E)
            let spE = TuneDSP.welch(E, fs: fs)
            let pk = TuneDSP.peak(spE, from: 0.8, to: min(80, fs / 2.5))
            let amp = pk.map { $0.bandPower.squareRoot() } ?? 0                     // рад/с (середньоквадратичне в смузі піка)
            let ampDeg = amp * radToDeg
            var oscillating = false

            // 1. Коливання (контур сам розгойдується)
            if let p = pk, p.prom > 15, p.share > 0.4, ampDeg > 5 {
                oscillating = true
                let severe = ampDeg > 20 || p.share > 0.8
                let k = severe ? 0.5 : 0.75
                let pct = severe ? "50 %" : "25 %"
                var ch: [ParamChange] = []
                var cause = "", tipList: [String] = []
                if p.f < 4 {
                    cause = String(localized: "Це повільні коливання. Найчастіше їх дають завелике підсилення інтегральної складової (I) або кутового контуру, а також слабке кріплення вантажу чи гнучка рама.")
                    if let c = chg("_I", plane ? 0.5 : k, loc("інтегральна складова розгойдує апарат на низькій частоті") + (plane ? " (за керівництвом ArduPlane: при повільних коливаннях 1–2 Гц зменшити I удвічі)" : "")) { ch.append(c) }
                    if !plane, let ap = ax.angP, has(ap) { ch.append(ParamChange(name: ap, op: .scale(severe ? 0.7 : 0.8), why: String(localized: "кутовий контур завеликий: апарат перегойдується навколо заданого кута"))) }
                    if plane, let tc = ax.tconst, has(tc) { ch.append(ParamChange(name: tc, op: .scale(1.3), why: String(localized: "довша постійна часу робить кутовий контур спокійнішим"))) }
                    tipList = ["Перевірте кріплення польотного контролера, АКБ і вантажу: люфт теж дає повільні коливання.", "Змінюйте по одному параметру й перевіряйте на безпечній висоті; польоти починайте у Stabilize."]
                } else if p.f < 30 {
                    cause = String(localized: "Контур перерегульований: підсилення P і D завелике для цієї частоти реакції апарата.")
                    if let c = chg("_P", k, "зменшити підсилення, щоб прибрати розгойдування") { ch.append(c) }
                    if let c = chg("_D", k, "демпфування (D) на цій частоті підсилює шум і розгойдування") { ch.append(c) }
                    if ax.rollPitch && !plane, let c = chg("_I", k, "за керівництвом: після зміни P значення I має дорівнювати P") { ch.append(c) }
                    tipList = ["Офіційний порядок налаштування: спершу D, потім P; у разі коливань зменшуйте P, I і D кроками по 50 % до стабільності, далі підніміть на 10 % крок.", "Перед налаштуванням усуньте вібрацію: балансування гвинтів і кріплення моторів."]
                } else {
                    cause = String(localized: "Це швидке «дзижчання» (\(String(format: "%.0f", p.f)) Гц): зазвичай завелике D або шум, який не відфільтровано.")
                    if let c = chg("_D", k, "зменшити D, щоб прибрати дзижчання") { ch.append(c) }
                    if let c = chg("_FLTD", 0.75, "нижча частота фільтра D зменшує шум") { ch.append(c) }
                    tipList = ["Перевірте гвинти, кріплення моторів і рами; потім налаштуйте гармонійний нотч-фільтр (див. нижче)."]
                }
                out.append(LogFinding(level: severe ? .bad : .warn,
                    title: String(localized: "Контур \(loc(ax.nameGen)) коливається"),
                    detail: String(format: loc("Графік реальної швидкості обертання (Act) відрізняється від очікуваної (Tar): з'являється стійке коливання %.1f Гц з амплітудою близько %.0f °/с. "), p.f, ampDeg) + cause,
                    tips: tipList + [String(localized: "Рекомендується зменшити значення на \(pct), як показано нижче. Застосовуйте, коли польотник підключено; перевіряйте на коротких польотах.")],
                    time: worst?.t, keys: keys, window: window, changes: ch))
            }

            // 2. Недостатня реакція чи перерегулювання (лише коли були збудження й немає коливань)
            if !oscillating, rmsT > 0.087, let lg = TuneDSP.lagGain(T, A, fs: fs, maxLag: 0.25), lg.corr > 0.6 {
                let ms = lg.lag * 1000
                if lg.lag > (ax.rollPitch ? 0.08 : 0.18) || lg.gain < (ax.rollPitch ? 0.75 : 0.55) {
                    let ch = [chg("_P", 1.25, "збільшити підсилення, щоб швидше доганяти бажане значення"), (ax.rollPitch && !plane) ? chg("_I", 1.25, "I має дорівнювати P") : nil].compactMap { $0 }
                    out.append(LogFinding(level: .warn, title: String(localized: "Реакція по \(loc(ax.nameGen)) млява"),
                        detail: String(format: loc("Графік реальної швидкості обертання (Act) відстає від очікуваної (Tar) приблизно на %.0f мс і досягає лише %.0f %% бажаного значення. Причина: підсилення P замале (чи занадто сильний фільтр додає запізнення)."), ms, lg.gain * 100),
                        tips: ["Збільшуйте P кроками (за керівництвом: у кроків по 50 % до появи коливань, потім відступити на 10 %, далі ще на 25 %); тут запропоновано обережний крок +25 %.", "Якщо коливання з'являться, поверніть попереднє значення."],
                        time: worst?.t, keys: keys, window: window, changes: ch))
                } else if lg.gain > 1.25 {
                    let ch = [chg("_P", 0.85, "зменшити підсилення, щоб прибрати перерегулювання")].compactMap { $0 }
                    out.append(LogFinding(level: .warn, title: String(localized: "Перерегулювання по \(loc(ax.nameGen))"),
                        detail: String(format: loc("Реальна швидкість обертання (Act) перевищує очікувану (Tar) у %.1f раза. Причина: надто агресивне підсилення P або слабке демпфування (D)."), lg.gain),
                        tips: ["Збільшіть демпфування D на 10–20 % або зменшіть P; перевіряйте після кожної зміни."],
                        time: worst?.t, keys: keys, window: window, changes: ch))
                }
            }

            // 3. Шум у сигналі гіроскопа, який використовує регулятор
            let spA = TuneDSP.welch(A, fs: fs)
            let hf = TuneDSP.highShare(spA, above: 40)
            if hf > 0.06 {
                var ch = [chg("_FLTD", 0.75, "нижча частота зрізу фільтра D")].compactMap { $0 }
                if let g = params["INS_GYRO_FILTER"] { ch.append(ParamChange(name: "INS_GYRO_FILTER", op: .set(max(10, (g * 0.75).rounded())), why: String(localized: "нижчий зріз фільтра гіроскопа прибирає шум (за ціну запізнення)"))) }
                out.append(LogFinding(level: .warn, title: String(localized: "Шум у сигналі швидкості по \(loc(ax.nameGen))"),
                    detail: String(format: loc("У реальній швидкості обертання (Act) є помітний високочастотний шум (%.0f %% потужності вище 40 Гц). Причина: вібрація, яку не прибрано фільтрами; шум через D-складову гріє мотори й додає хитання."), hf * 100),
                    tips: ["Спершу усуньте вібрацію (гвинти, кріплення), потім налаштуйте гармонійний нотч-фільтр: він дозволяє залишити вищий зріз гіро-фільтра й менше запізнення.", "Фільтри додають запізнення: не зменшуйте зрізи без потреби."],
                    time: nil, keys: ["\(ax.pid).D"], window: window, changes: ch))
            }

            // 4. Кутовий контур (лише коптер/літак із ATT)
            if ax.rollPitch, let dn = ax.attDes, let an = ax.att {
                let ad = log.series("ATT", dn), aa = log.series("ATT", an)
                if ad.count > 300, ad.count == aa.count {
                    let ids = ad.indices.filter { airborne(ad[$0].t) }
                    if ids.count > 300 {
                        let fa = Double(ad.count - 1) / max(ad.last!.t - ad.first!.t, 0.1)
                        let D = ids.map { ad[$0].v }, Ac = ids.map { aa[$0].v }
                        if TuneDSP.rms(D) > 3, let lg = TuneDSP.lagGain(D, Ac, fs: fa, maxLag: 0.6), lg.corr > 0.7, !oscillating {
                            if lg.lag > 0.3 && lg.gain > 0.8 {
                                let ch = [ax.angP.flatMap { has($0) ? ParamChange(name: $0, op: .scale(1.2), why: String(localized: "швидший вихід на заданий кут")) : nil },
                                          plane ? ax.tconst.flatMap { has($0) ? ParamChange(name: $0, op: .scale(0.8), why: String(localized: "менша постійна часу: швидший вихід на заданий кут")) : nil } : nil].compactMap { $0 }
                                out.append(LogFinding(level: .info, title: String(localized: "Кут \(loc(ax.nameGen)) досягає заданого повільно"),
                                    detail: String(format: loc("Графік реального кута (%@) відстає від очікуваного (%@) приблизно на %.0f мс. Причина: підсилення кутового контуру замале (апарат «ледачий» на команди)."), an, dn, lg.lag * 1000),
                                    tips: ["Збільшуйте на 10–20 % і перевіряйте на коливання; завелике значення дає коливання по куту (за керівництвом)."],
                                    time: nil, keys: ["ATT.\(dn)", "ATT.\(an)"], window: window, changes: ch))
                            } else if lg.gain > 1.25 {
                                let ch = [ax.angP.flatMap { has($0) ? ParamChange(name: $0, op: .scale(0.8), why: String(localized: "перегойдування по куту")) : nil }].compactMap { $0 }
                                out.append(LogFinding(level: .warn, title: String(localized: "Перерегулювання по куту \(loc(ax.nameGen))"),
                                    detail: String(format: loc("Реальний кут (%@) перевищує очікуваний (%@) у %.1f раза. Причина: кутовий контур занадто різкий."), an, dn, lg.gain),
                                    tips: ["Зменшіть ATC_ANG_*_P на 20 %; завелике значення дає коливання по крену й тангажу."],
                                    time: nil, keys: ["ATT.\(dn)", "ATT.\(an)"], window: window, changes: ch))
                            }
                        }
                    }
                }
            }
            _ = rmsE
        }

        if analysed == 0 {
            out.append(LogFinding(level: .info, title: lowRate ? "Лог записано занадто рідко для аналізу PID" : "Недостатньо польотних даних для аналізу PID",
                detail: lowRate ? "Повідомлення PIDR/PIDP/PIDY записуються рідше за 80 Гц, а для оцінки реакції й коливань потрібні 100+ Гц. Ввімкніть швидке логування атитюду (параметр LOG_BITMASK, прапорець Fast Attitude/швидкий атитюд) і виконайте тестовий політ." : "У логу немає польоту з достатньою кількістю даних PID (потрібні PIDR/PIDP/PIDY, політ у повітрі з різкими командами).",
                tips: ["Тестовий політ: підвис, кілька різких нахилів по крену й тангажу, утримання кожного ~2 с (офіційна процедура оцінки налаштування)."]))
        } else {
            // вистачало збуджень?
            if !out.contains(where: { $0.level == .warn || $0.level == .bad }) {
                out.append(LogFinding(level: .ok, title: String(localized: "Явних проблем у реакції контурів не знайдено"), detail: String(localized: "Графіки очікуваної (Tar) і реальної (Act) швидкості обертання узгоджені, помітних коливань і шуму немає. Якщо апарат у польоті гойдається, зробіть новий лог із різкими нахилами (підвіс, швидкі нахили по крену й тангажу), щоб аналіз бачив реакцію."), keys: ["PIDR.Tar", "PIDR.Act"]))
            }
        }

        out.append(contentsOf: notchFindings(log, params: params, hover: hover, airborne: airborne))
        return out
    }

    /// Гармонійний нотч-фільтр і шум гіроскопа за сирими даними IMU.
    static func notchFindings(_ log: DFLog, params: [String: Double], hover: Double, airborne: (Double) -> Bool) -> [LogFinding] {
        var out: [LogFinding] = []
        let g = log.series("IMU", "GyrX")
        guard g.count > 3000 else {
            if log.count("IMU") == 0 || g.count <= 3000 {
                out.append(LogFinding(level: .info, title: String(localized: "Для налаштування нотч-фільтра немає швидких даних гіроскопа"),
                    detail: String(localized: "У лозі немає записів IMU з високою частотою. Для вибору частоти нотч-фільтра потрібне сире логування гіроскопа (на H7-платах: INS_LOG_BAT_OPT / швидкий IMU-лог) або аналіз FFT."),
                    tips: ["За офіційним керівництвом: ввімкніть INS_LOG_BAT_MASK = 1, повисіть 30 с без команд і завантажте новий лог.", "Альтернатива: режим ESC-телеметрії (INS_HNTCH_MODE = 3) для нотч-фільтра дає найточніше відстеження частоти."]))
            }
            return out
        }
        let fs = Double(g.count - 1) / max(g.last!.t - g.first!.t, 0.1)
        guard fs > 150 else { return out }
        let x = g.filter { airborne($0.t) }.map { $0.v * radToDeg }
        guard x.count > 3000 else { return out }
        let sp = TuneDSP.welch(x, fs: fs)
        let pkOpt = TuneDSP.peak(sp, from: 30, to: min(250, fs / 2.2))
        let enabled = (params["INS_HNTCH_ENABLE"] ?? 0) > 0
        let freq = params["INS_HNTCH_FREQ"] ?? 0, bw = params["INS_HNTCH_BW"] ?? 0
        let mode = Int(params["INS_HNTCH_MODE"] ?? 1), ref = params["INS_HNTCH_REF"] ?? 0
        let harm = Int(params["INS_HNTCH_HMNCS"] ?? 1)
        // опорний газ режиму за газом: помилка конфігурації незалежно від піка
        if enabled && mode == 1 && ref <= 0 {
            out.append(LogFinding(level: .warn, title: String(localized: "У нотч-фільтра за газом не задано опорний газ"),
                detail: String(localized: "Режим за газом (INS_HNTCH_MODE = 1) вимагає INS_HNTCH_REF, що відповідає газу висіння. Зараз 0: частота фільтра не масштабується з газом, тож на інших обертах він шумові піки не накриває."),
                tips: ["Встановіть INS_HNTCH_REF = MOT_THST_HOVER (газ висіння) і перевірте частоту INS_HNTCH_FREQ у висінні."], time: nil, keys: [],
                window: nil, changes: [ParamChange(name: "INS_HNTCH_REF", op: .set((hover * 1000).rounded() / 1000), why: String(localized: "опорний газ = MOT_THST_HOVER"))]))
        }
        guard let pk = pkOpt, pk.prom > 25, pk.bandPower.squareRoot() > 1.0 else { return out }
        let ampDeg = pk.bandPower.squareRoot()
        let f0 = pk.f
        var covered = false
        if enabled && freq > 0 {
            for h in 0..<8 where harm & (1 << h) != 0 { if abs(freq * Double(h + 1) - f0) <= max(bw / 2, 5) { covered = true } }
        }
        let peakTxt = String(format: loc("%.0f Гц (близько %.1f °/с)"), f0, ampDeg)
        if !enabled {
            out.append(LogFinding(level: ampDeg > 2 ? .warn : .info, title: String(localized: "Нотч-фільтр вимкнений, а в гіроскопі є шумовий пік"),
                detail: String(localized: "У сирому сигналі гіроскопа під час польоту є виражений пік шуму на \(peakTxt). Це типова вібрація моторів і гвинтів. Причина проблем: цей шум доходить до регулятора, гріє мотори й змушує знижувати підсилення."),
                tips: ["Рекомендується ввімкнути гармонійний нотч-фільтр: INS_HNTCH_ENABLE = 1, перезавантажити автопілот, INS_HNTCH_MODE = 1 (за газом), INS_HNTCH_REF = MOT_THST_HOVER, INS_HNTCH_FREQ = частота піка, INS_HNTCH_BW = половина частоти, INS_HNTCH_HMNCS = 3.", "Після ввімкнення зробіть новий лог і подивіться, чи пік зник; тоді можна підняти INS_GYRO_FILTER."],
                time: nil, keys: ["IMU.GyrX", "IMU.GyrY"], window: nil,
                changes: [ParamChange(name: "INS_HNTCH_ENABLE", op: .set(1), why: String(localized: "увімкнути гармонійний нотч-фільтр (потрібне перезавантаження автопілота)")),
                          ParamChange(name: "INS_HNTCH_FREQ", op: .set(f0.rounded()), why: String(localized: "центр першого фільтра на піку шуму")),
                          ParamChange(name: "INS_HNTCH_BW", op: .set((f0 / 2).rounded()), why: String(localized: "ширина смуги: половина частоти")),
                          ParamChange(name: "INS_HNTCH_REF", op: .set((hover * 1000).rounded() / 1000), why: String(localized: "опорний газ для режиму за газом дорівнює MOT_THST_HOVER"))].filter { params[$0.name] != nil || $0.name.hasPrefix("INS_HNTCH") }))
        } else if !covered {
            var ch: [ParamChange] = []
            if mode == 1 || mode == 0 { ch.append(ParamChange(name: "INS_HNTCH_FREQ", op: .set(f0.rounded()), why: String(localized: "частота шумового піка"))); ch.append(ParamChange(name: "INS_HNTCH_BW", op: .set((f0 / 2).rounded()), why: String(localized: "ширина смуги: половина частоти"))) }
            out.append(LogFinding(level: .warn, title: String(localized: "Нотч-фільтр не накриває пік шуму гіроскопа"),
                detail: String(format: loc("Фільтр увімкнено (центр %.0f Гц, смуга %.0f Гц), але пік шуму в сирому гіроскопі припадає на %@, поза смугою фільтра. Причина: частота нотча задана неточно або опорний газ не відповідає польоту."), freq, bw, peakTxt),
                tips: ["Для режиму за газом (INS_HNTCH_MODE = 1) частоту INS_HNTCH_FREQ вимірюють у висінні, а INS_HNTCH_REF має дорівнювати MOT_THST_HOVER.", "Якщо пік зсувається з обертами, надійніше режими за ESC-телеметрією (INS_HNTCH_MODE = 3) чи RPM."],
                time: nil, keys: ["IMU.GyrX", "IMU.GyrY"], window: nil, changes: ch))
        } else {
            out.append(LogFinding(level: .ok, title: String(localized: "Нотч-фільтр відповідає шумовому піку"), detail: String(localized: "Основний пік шуму гіроскопа (\(peakTxt)) потрапляє в смугу гармонійного нотч-фільтра."), keys: []))
        }
        return out
    }
}
