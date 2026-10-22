import Foundation

/// Параметри віртуального регулятора в тренажері (не пов'язані з реальним апаратом).
struct GameGains: Equatable {
    var p = 0.0, i = 0.0, d = 0.0, ff = 0.0
    var fltd = 150.0           // Гц
}

/// Тип цілі: різкий крок кута або плавне гойдання.
enum GameTarget { case step(deg: Double, at: Double), sine(amp: Double, hz: Double) }

struct GameLevel: Identifiable {
    let id: Int
    let title: String
    let teaches: String
    let mission: String
    let hint: String
    let learned: String
    let duration: Double
    let target: GameTarget
    let gain: Double, damping: Double, tau: Double
    let wind: Double               // постійний збурювальний момент після windAt, град/с²
    let windAt: Double
    let noise: Double              // шум гіроскопа, град/с
    let gusts: Bool
    let fixed: GameGains           // фіксовані значення
    let edit: Set<String>          // які регулятори можна міняти: P I D FF FLT
    let start: GameGains           // початкові значення
    static func make() -> [GameLevel] { levels }

    static let levels: [GameLevel] = [
        GameLevel(id: 1, title: "P: сила реакції", teaches: "Пропорційна складова",
                  mission: "Дрон нахилений, ціль 20°. Підберіть P так, щоб він швидко вийшов на ціль і майже не перескочив її.",
                  hint: "Малий P: дрон ліниво повзе до цілі. Великий P: різкий ривок з «перельотом» і гойданням. Шукайте золоту середину.",
                  learned: "P визначає, наскільки сильно реагує апарат на помилку. Більше P означає швидше, але понад межу дає перельоти й коливання.",
                  duration: 3.0, target: .step(deg: 20, at: 0.4), gain: 14, damping: 7, tau: 0.04, wind: 0, windAt: 0, noise: 0, gusts: false,
                  fixed: GameGains(p: 0, i: 0, d: 0, ff: 0), edit: ["P"], start: GameGains(p: 1.0)),
        GameLevel(id: 2, title: "D: гасіння коливань", teaches: "Диференціальна складова",
                  mission: "Сильний P змушує дрон розгойдуватися. Додайте D, щоб заспокоїти коливання, не втративши швидкість.",
                  hint: "D реагує на швидкість обертання й діє як амортизатор. Додавайте поступово: замало лишає гойдання, забагато робить реакцію в'язкою.",
                  learned: "D гасить коливання, бо протидіє швидкому руху. Але підсилює шум, тому в реальності його поєднують із фільтром.",
                  duration: 3.0, target: .step(deg: 20, at: 0.4), gain: 3, damping: 0.5, tau: 0.04, wind: 0, windAt: 0, noise: 0, gusts: false,
                  fixed: GameGains(p: 6, i: 0, d: 0, ff: 0), edit: ["D"], start: GameGains(p: 6, d: 0)),
        GameLevel(id: 3, title: "I: боротьба з вітром", teaches: "Інтегральна складова",
                  mission: "Подув вітру зсуває дрон і він не повертається точно в ціль. Використайте I, щоб усунути залишкову помилку.",
                  hint: "Без I помилка від вітру лишається назавжди. I накопичує помилку й поступово «дотискає» до цілі. Забагато I дає повільні хитання.",
                  learned: "I усуває стале відхилення (вітер, дисбаланс). Надто великий I викликає повільні розгойдування.",
                  duration: 6.0, target: .step(deg: 20, at: 0.4), gain: 3, damping: 1, tau: 0.04, wind: -45, windAt: 1.5, noise: 0, gusts: false,
                  fixed: GameGains(p: 4, i: 0, d: 1.2, ff: 0), edit: ["I"], start: GameGains(p: 4, i: 0, d: 1.2)),
        GameLevel(id: 4, title: "FF: випередження", teaches: "Feedforward",
                  mission: "Ціль плавно гойдається. Підберіть FF, щоб дрон не відставав від неї.",
                  hint: "FF дає керування одразу за рухом цілі, не чекаючи помилки. Замало: дрон відстає. Забагато: він випереджає ціль.",
                  learned: "FF прискорює відгук на команди пілота без ризику коливань, бо діє на ціль, а не на помилку.",
                  duration: 6.0, target: .sine(amp: 15, hz: 0.5), gain: 30, damping: 30, tau: 0.015, wind: 0, windAt: 0, noise: 0, gusts: false,
                  fixed: GameGains(p: 3, i: 0.3, d: 0.1, ff: 0), edit: ["FF"], start: GameGains(p: 3, i: 0.3, d: 0.1)),
        GameLevel(id: 5, title: "Шум і фільтр", teaches: "Фільтр D-складової",
                  mission: "Датчик «шумить», а D підсилює шум, моторам стає гаряче. Підберіть D і фільтр так, щоб було тихо, але дрон лишався стійким.",
                  hint: "Нижча частота фільтра прибирає шум, але додає затримку, і D гірше гасить коливання. Знизьте фільтр помірно, не забуваючи про D.",
                  learned: "Фільтр обмінює шум на затримку. Підбирайте мінімальну фільтрацію, за якої мотори залишаються холодними.",
                  duration: 3.5, target: .step(deg: 20, at: 0.4), gain: 3, damping: 0.5, tau: 0.04, wind: 0, windAt: 0, noise: 18, gusts: false,
                  fixed: GameGains(p: 5, i: 0, d: 0, ff: 0), edit: ["D", "FLT"], start: GameGains(p: 5, d: 1.5, fltd: 150)),
        GameLevel(id: 6, title: "Вільний політ", teaches: "Усе разом",
                  mission: "Вітер, пориви й шум одночасно. Налаштуйте P, I, D, FF і фільтр на максимальну оцінку.",
                  hint: "Почніть із P, додайте D, потім I для вітру, FF для плавності й фільтр, щоб мотори лишалися холодними.",
                  learned: "Хороше налаштування це баланс: швидкість, стійкість, точність і шум.",
                  duration: 8.0, target: .sine(amp: 15, hz: 0.5), gain: 30, damping: 24, tau: 0.015, wind: -90, windAt: 2.0, noise: 8, gusts: true,
                  fixed: GameGains(), edit: ["P", "I", "D", "FF", "FLT"], start: GameGains(p: 2, i: 0, d: 0, ff: 0, fltd: 80)),
    ]
}

struct GameRun {
    var t: [Double] = [], target: [Double] = [], angle: [Double] = [], wind: [Double] = [], heatNow: [Double] = []
    var overshoot = 0.0               // %
    var riseTime: Double?
    var settling: Double?             // с після кроку
    var steadyError = 0.0             // град
    var rms = 0.0                     // град
    var heat = 0.0                    // 0…100
    var oscillating = false
    var unstable = false
    var score = 0.0                   // для вільного політу, 0…100
}

enum GameSim {
    /// Детермінований генератор шуму, щоб однакові налаштування давали однаковий результат.
    struct RNG { var s: UInt64
        mutating func next() -> Double { s ^= s << 13; s ^= s >> 7; s ^= s << 17; return Double(s % 10_000_000) / 10_000_000 }
        mutating func gauss() -> Double { let a = max(next(), 1e-9), b = next(); return sqrt(-2 * log(a)) * cos(2 * Double.pi * b) }
    }

    static func run(_ lv: GameLevel, _ g: GameGains) -> GameRun {
        let dt = 0.002
        let n = Int(lv.duration / dt)
        var r = GameRun()
        var th = 0.0, om = 0.0, act = 0.0, integ = 0.0, dF = 0.0, tgtPrev = 0.0, tgtVelF = 0.0, hf = 0.0
        var rng = RNG(s: 88172645463325252)
        let aD = lv.noise > 0 || g.fltd < 400 ? (2 * Double.pi * g.fltd * dt) / (2 * Double.pi * g.fltd * dt + 1) : 1
        let aH = (2 * Double.pi * 5 * dt) / (2 * Double.pi * 5 * dt + 1)
        var gustTimes: [Double] = []
        if lv.gusts { var rr = RNG(s: 424242); for k in 1...4 { gustTimes.append(1.0 + Double(k) * 1.4 + rr.next() * 0.6) } }
        var heatAcc = 0.0, heatN = 0.0
        var blown = false
        r.t.reserveCapacity(n / 5); r.target.reserveCapacity(n / 5); r.angle.reserveCapacity(n / 5)
        for k in 0..<n {
            let t = Double(k) * dt
            var tgt = 0.0
            switch lv.target {
            case .step(let a, let at): tgt = t < at ? 0 : a * min(1, (t - at) / 0.08)       // коротка рампа
            case .sine(let a, let hz): tgt = t < 0.4 ? 0 : a * sin(2 * Double.pi * hz * (t - 0.4))
            }
            let tVel = (tgt - tgtPrev) / dt; tgtPrev = tgt
            tgtVelF += 0.05 * (tVel - tgtVelF)
            var w = t >= lv.windAt ? lv.wind : 0
            for gt in gustTimes where t >= gt && t < gt + 0.35 { w += (gt.truncatingRemainder(dividingBy: 2) < 1 ? 1 : -1) * (lv.damping > 10 ? 250 : 35) }
            let rateMeas = om + (lv.noise > 0 ? rng.gauss() * lv.noise : 0)
            dF += aD * (rateMeas - dF)
            let e = tgt - th
            integ = max(-80, min(80, integ + g.i * e * dt))
            var u = g.p * e + integ - g.d * dF + g.ff * tgtVelF
            u = max(-100, min(100, u))
            act += (u - act) * dt / lv.tau
            let acc = lv.gain * act - lv.damping * om + w
            om += acc * dt; th += om * dt
            if abs(th) > 1500 { blown = true; th = th > 0 ? 1500 : -1500; om = 0 }
            hf += aH * (u - hf)
            if t > 0.5 { heatAcc += (u - hf) * (u - hf); heatN += 1 }
            if k % 5 == 0 { r.t.append(t); r.target.append(tgt); r.angle.append(th); r.wind.append(w) }
        }
        r.unstable = blown || abs(th) > 200
        r.heat = heatN > 0 ? min(100, sqrt(heatAcc / heatN) * 2.2) : 0
        analyze(&r, lv)
        return r
    }

    static func analyze(_ r: inout GameRun, _ lv: GameLevel) {
        guard r.t.count > 10 else { return }
        switch lv.target {
        case .step(let a, let at):
            let stepEnd = at + 0.08
            let idx0 = r.t.firstIndex { $0 >= stepEnd } ?? 0
            let peak = r.angle[idx0...].max() ?? a
            r.overshoot = max(0, (peak - a) / a * 100)
            if let i1 = r.angle.indices.first(where: { $0 >= idx0 && r.angle[$0] >= 0.1 * a }), let i2 = r.angle.indices.first(where: { $0 >= idx0 && r.angle[$0] >= 0.9 * a }), i2 >= i1 { r.riseTime = r.t[i2] - r.t[i1] }
            let band = 0.05 * a
            let windEnd = lv.wind != 0 ? lv.windAt : at
            if let last = r.angle.indices.last(where: { r.t[$0] > windEnd && abs(r.angle[$0] - a) > band }) { r.settling = last < r.t.count - 20 ? r.t[last] - windEnd : nil } else { r.settling = 0 }
            let tailStart = r.t.count - Int(0.8 / (r.t[1] - r.t[0]))
            let tail = r.angle[max(0, tailStart)...]
            r.steadyError = tail.map { abs($0 - a) }.reduce(0, +) / Double(max(tail.count, 1))
            var cross = 0; var above = false; var first = true
            for i in idx0..<r.angle.count {
                let d = r.angle[i] - a
                if abs(d) < 0.04 * a { continue }
                let b = d > 0
                if first { above = b; first = false } else if b != above { cross += 1; above = b }
            }
            r.oscillating = cross >= 3
        case .sine:
            let from = r.t.firstIndex { $0 >= 1.5 } ?? 0
            let errs = (from..<r.angle.count).map { r.angle[$0] - r.target[$0] }
            r.rms = sqrt(errs.map { $0 * $0 }.reduce(0, +) / Double(max(errs.count, 1)))
            r.steadyError = errs.map { abs($0) }.reduce(0, +) / Double(max(errs.count, 1))
        }
        // Оцінка для вільного польоту
        let rmsPart = max(0, 1 - r.rms / 8), heatPart = max(0, 1 - r.heat / 60)
        r.score = r.unstable ? 0 : max(0, min(100, 100 * (0.65 * rmsPart + 0.35 * heatPart) - (r.oscillating ? 10 : 0)))
    }

    /// Підсумок рівня: кількість зірок (0 = не пройдено) та пояснення, що вдосконалити.
    static func evaluate(_ lv: GameLevel, _ r: GameRun) -> (stars: Int, notes: [(Bool, String)]) {
        var notes: [(Bool, String)] = []
        func note(_ ok: Bool, _ text: String) { notes.append((ok, text)) }
        if r.unstable { return (0, [(false, "Система розгойдалася й втратила стійкість. Зменшіть P або додайте демпфування (D).")]) }
        switch lv.id {
        case 1:
            note(r.overshoot <= 15, String(format: loc("Перерегулювання %.0f %% (потрібно ≤ 15 %%)"), r.overshoot))
            note((r.settling ?? 99) <= 1.3, loc("Усталення ") + (r.settling.map { String(format: loc("%.2f с"), $0) } ?? "не досягнуто") + loc(" (потрібно ≤ 1.3 с)"))
            let ok = r.overshoot <= 15 && (r.settling ?? 99) <= 1.3
            let s3 = r.overshoot <= 8 && (r.settling ?? 99) <= 1.15, s2 = r.overshoot <= 12 && (r.settling ?? 99) <= 1.2
            return (ok ? (s3 ? 3 : (s2 ? 2 : 1)) : 0, notes)
        case 2:
            note(!r.oscillating, loc("Коливання ") + (r.oscillating ? "лишилися" : "погашено"))
            note(r.overshoot <= 20, String(format: loc("Перерегулювання %.0f %% (потрібно ≤ 20 %%)"), r.overshoot))
            note((r.settling ?? 99) <= 1.3, loc("Усталення ") + (r.settling.map { String(format: loc("%.2f с"), $0) } ?? "не досягнуто") + loc(" (потрібно ≤ 1.3 с)"))
            let ok = !r.oscillating && r.overshoot <= 20 && (r.settling ?? 99) <= 1.3
            let s3 = r.overshoot <= 8 && (r.settling ?? 99) <= 0.8, s2 = r.overshoot <= 14 && (r.settling ?? 99) <= 1.0
            return (ok ? (s3 ? 3 : (s2 ? 2 : 1)) : 0, notes)
        case 3:
            note(r.steadyError <= 1.0, String(format: loc("Залишкова помилка %.1f° (потрібно ≤ 1°)"), r.steadyError))
            note(!r.oscillating, loc("Хитання ") + (r.oscillating ? "помітні: зменшіть I" : "відсутні"))
            let ok = r.steadyError <= 1.0 && !r.oscillating
            return (ok ? (r.steadyError <= 0.3 && (r.settling ?? 99) <= 2.5 ? 3 : (r.steadyError <= 0.6 ? 2 : 1)) : 0, notes)
        case 4:
            note(r.rms <= 4.0, String(format: loc("Помилка стеження (середньоквадратична) %.1f° (потрібно ≤ 4°)"), r.rms))
            let ok = r.rms <= 4.0
            return (ok ? (r.rms <= 2.4 ? 3 : (r.rms <= 3.2 ? 2 : 1)) : 0, notes)
        case 5:
            note(r.heat <= 22, String(format: loc("Нагрів моторів %.0f з 100 (потрібно ≤ 22)"), r.heat))
            note(r.overshoot <= 25, String(format: loc("Перерегулювання %.0f %% (потрібно ≤ 25 %%)"), r.overshoot))
            note((r.settling ?? 99) <= 1.5, loc("Усталення ") + (r.settling.map { String(format: loc("%.2f с"), $0) } ?? "не досягнуто") + loc(" (потрібно ≤ 1.5 с)"))
            let ok = r.heat <= 22 && r.overshoot <= 25 && (r.settling ?? 99) <= 1.5
            let s3 = r.heat <= 12 && r.overshoot <= 12 && (r.settling ?? 99) <= 1.0, s2 = r.heat <= 17 && r.overshoot <= 18
            return (ok ? (s3 ? 3 : (s2 ? 2 : 1)) : 0, notes)
        default:
            note(true, String(format: loc("Оцінка %.0f з 100 (стеження %.1f°, нагрів %.0f)"), r.score, r.rms, r.heat))
            return (r.score >= 82 ? 3 : (r.score >= 68 ? 2 : (r.score >= 50 ? 1 : 0)), notes)
        }
    }

    /// Підказка за результатом: що саме спробувати змінити.
    static func advice(_ lv: GameLevel, _ g: GameGains, _ r: GameRun) -> String {
        if r.unstable { return "Система нестійка: зменште P або збільшіть D." }
        switch lv.id {
        case 1: return r.overshoot > 15 ? "Є переліт: зменшіть P." : ((r.settling ?? 99) > 1.0 ? "Дрон надто повільний: збільшіть P." : "Добре! Спробуйте домогтися ще меншого перельоту.")
        case 2: return r.oscillating ? "Гойдання лишилося: збільшіть D." : ((r.settling ?? 99) > 1.0 ? "Занадто в'язко або повільно: трохи зменшіть D." : "Гойдання погашено.")
        case 3: return r.steadyError > 1.0 ? "Помилка від вітру лишилася: збільшіть I." : (r.oscillating ? "Помітні повільні хитання: зменшіть I." : "Вітер подолано.")
        case 4: return r.rms > 4.0 ? "Дрон відстає від цілі: збільшіть FF." : "Стеження добре."
        case 5: return r.heat > 22 ? "Моторам гаряче: знизьте частоту фільтра або зменшіть D." : (r.overshoot > 25 ? "Занадто багато фільтрації: гасіння погіршилося, підніміть фільтр або D." : "Шум приборкано.")
        default: return r.heat > 40 ? "Забагато шуму в моторах: знизьте фільтр або D." : (r.rms > 6 ? "Стеження слабке: додайте FF, P чи I." : "Добре налаштовано.")
        }
    }
}
