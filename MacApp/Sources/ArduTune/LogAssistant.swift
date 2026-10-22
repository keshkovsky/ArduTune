import SwiftUI

struct GraphRequest: Equatable { var keys: [String]; var from: Double; var to: Double }

// MARK: - Результати аналізу

struct LogFinding: Identifiable {
    enum Level { case ok, info, warn, bad }
    let id = UUID()
    let level: Level
    let title: String
    let detail: String
    var tips: [String] = []
    var time: Double? = nil
    var keys: [String] = []
    var window: (Double, Double)? = nil
    var changes: [ParamChange] = []

    var icon: String { switch level { case .ok: "checkmark.circle.fill"; case .info: "info.circle.fill"; case .warn: "exclamationmark.triangle.fill"; case .bad: "xmark.octagon.fill" } }
    var color: Color { switch level { case .ok: .green; case .info: .secondary; case .warn: .orange; case .bad: .red } }
}

struct Symptom: Identifiable {
    let id: String; let title: String; let subtitle: String; let icon: String
    let run: (DFLog) -> [LogFinding]
}

func fmtT(_ t: Double) -> String { String(format: "%d:%04.1f", Int(t) / 60, t.truncatingRemainder(dividingBy: 60)) }

// MARK: - Допоміжні функції аналізу

enum LogMath {
    /// Інтервали, де умова істинна не менше minDur секунд. Повертає (початок, кінець, пікове значення).
    static func intervals(_ s: [(t: Double, v: Double)], minDur: Double, _ pred: (Double) -> Bool) -> [(Double, Double, Double)] {
        var out: [(Double, Double, Double)] = []
        var start: Double?; var peak = 0.0
        for p in s {
            if pred(p.v) { if start == nil { start = p.t; peak = p.v } ; if abs(p.v) > abs(peak) { peak = p.v } }
            else if let st = start { if p.t - st >= minDur { out.append((st, p.t, peak)) }; start = nil }
        }
        if let st = start, let last = s.last, last.t - st >= minDur { out.append((st, last.t, peak)) }
        return out
    }
    static func stats(_ s: [(t: Double, v: Double)]) -> (min: Double, max: Double, mean: Double)? {
        let v = s.map(\.v).filter { $0.isFinite }
        guard !v.isEmpty else { return nil }
        return (v.min()!, v.max()!, v.reduce(0, +) / Double(v.count))
    }
    /// Різниця двох серій з однаковою кількістю точок (фактичне мінус бажане).
    static func diff(_ a: [(t: Double, v: Double)], _ b: [(t: Double, v: Double)]) -> [(t: Double, v: Double)] {
        guard a.count == b.count else { return [] }
        return zip(a, b).map { (t: $0.t, v: $0.v - $1.v) }
    }
    /// Ковзне середньоквадратичне значення за вікном (с).
    static func rollingRMS(_ s: [(t: Double, v: Double)], window: Double) -> [(t: Double, v: Double)] {
        guard s.count > 2 else { return [] }
        var out: [(t: Double, v: Double)] = []; var lo = 0; var acc = 0.0
        for hi in 0..<s.count {
            acc += s[hi].v * s[hi].v
            while s[hi].t - s[lo].t > window { acc -= s[lo].v * s[lo].v; lo += 1 }
            out.append((t: s[hi].t, v: sqrt(max(0, acc) / Double(hi - lo + 1))))
        }
        return out
    }
    static func zeroCrossRate(_ s: [(t: Double, v: Double)], from: Double, to: Double, deadband: Double) -> Double {
        var c = 0; var last = 0
        for p in s where p.t >= from && p.t <= to { let sg = p.v > deadband ? 1 : (p.v < -deadband ? -1 : 0); if sg != 0 { if last != 0 && sg != last { c += 1 }; last = sg } }
        return Double(c) / 2 / max(to - from, 0.1)       // повних коливань за секунду (Гц)
    }
}

// MARK: - Сценарії діагностики

enum LogAssistant {
    static func armedWindow(_ log: DFLog) -> (Double, Double) {
        // Наближено: від першого до останнього повідомлення EV «Armed/Disarmed»; інакше увесь лог
        let evs = log.messages.filter { $0.name == "EV" }
        let arm = evs.first { $0.text.contains("Armed") && !$0.text.contains("Disarmed") }?.time
        let dis = evs.last { $0.text.contains("Disarmed") }?.time
        return (max(arm ?? 0, log.clip?.from ?? 0), dis ?? log.duration)
    }

    static let symptoms: [Symptom] = [
        Symptom(id: "osc", title: String(localized: "Апарат гойдається або нестабільний"), subtitle: String(localized: "Коливання, «качання», тремтіння"), icon: "waveform.path.ecg") { log in
            var f: [LogFinding] = []
            let (a0, a1) = armedWindow(log)
            let er = LogMath.diff(log.series("ATT", "Roll"), log.series("ATT", "DesRoll")), ep = LogMath.diff(log.series("ATT", "Pitch"), log.series("ATT", "DesPitch"))
            for (name, e, keys) in [("крену", er, ["ATT.Roll", "ATT.DesRoll"]), ("тангажа", ep, ["ATT.Pitch", "ATT.DesPitch"])] where !e.isEmpty {
                let inflight = e.filter { $0.t >= a0 && $0.t <= a1 }
                let big = LogMath.intervals(LogMath.rollingRMS(inflight, window: 1.0), minDur: 1.0) { $0 > 5 }
                if let worst = big.max(by: { abs($0.2) < abs($1.2) }) {
                    let hz = LogMath.zeroCrossRate(inflight, from: worst.0, to: min(worst.1, worst.0 + 4), deadband: 2)
                    f.append(LogFinding(level: .warn, title: String(localized: "Великі відхилення \(loc(name))"), detail: String(format: loc("Середньоквадратична помилка кута перевищувала 5° у %d проміжках, найгірше %.0f° о %@."), big.count, abs(worst.2), fmtT(worst.0)) + (hz > 0.8 ? String(format: loc(" Помітні коливання близько %.1f Гц."), hz) : ""),
                                        tips: hz > 6 ? ["Швидкі коливання (понад 6 Гц): зменшіть P і D або FLTD, перевірте вібрацію й кріплення моторів.", "Переконайтеся, що пропелери збалансовані."] :
                                              (hz > 0.8 ? ["Повільніші коливання (1–6 Гц): зменшіть P або I, перевірте обмеження прискорення ATC_ACCEL_*_MAX.", "Подивіться, чи не збігаються вони з різким газом чи вітром."] :
                                                          ["Велика різниця без коливань означає млявість або обмеження: збільшіть P/FF чи перевірте потужність моторів."]),
                                        time: worst.0, keys: keys, window: (max(0, worst.0 - 2), worst.1 + 2)))
                }
            }
            if let vx = LogMath.stats(log.series("VIBE", "VibeX")), let vy = LogMath.stats(log.series("VIBE", "VibeY")), let vz = LogMath.stats(log.series("VIBE", "VibeZ")) {
                let mx = max(vx.max, vy.max, vz.max)
                if mx > 30 { f.append(LogFinding(level: .bad, title: String(localized: "Висока вібрація"), detail: String(format: loc("Максимум %.0f м/с² (норма до 30). Вібрація часто є прямою причиною гойдання."), mx), tips: ["Збалансуйте пропелери й перевірте кріплення мотора й плати.", "Перед налаштуванням PID усуньте джерело вібрації."], keys: ["VIBE.VibeX", "VIBE.VibeY", "VIBE.VibeZ"])) }
            }
            let sat = (1...4).compactMap { i -> Double? in
                let s = log.series("RCOU", "C\(i)").filter { $0.t >= a0 && $0.t <= a1 }
                guard s.count > 20 else { return nil }
                return Double(s.filter { $0.v > 1950 }.count) / Double(s.count)
            }
            if let m = sat.max(), m > 0.05 { f.append(LogFinding(level: .warn, title: String(localized: "Мотори на межі потужності"), detail: String(format: loc("Один із моторів %.0f %% польоту працював біля максимуму: регулятор не має запасу."), m * 100), tips: ["Перевірте масу апарата, пропелери, напругу батареї та несиметрію моторів.", "Висока частка насичення дає «качання» у маневрах."], keys: ["RCOU.C1", "RCOU.C2", "RCOU.C3", "RCOU.C4"])) }
            if f.isEmpty { f.append(LogFinding(level: .ok, title: String(localized: "Явних ознак нестабільності не знайдено"), detail: String(localized: "Кути слідують за бажаними, вібрація й насичення моторів у нормі. Якщо ви бачили гойдання, дивіться на потрібну ділянку вручну."), keys: ["ATT.Roll", "ATT.DesRoll"])) }
            return f
        },
        Symptom(id: "gps", title: String(localized: "Проблеми з GPS або дрейф"), subtitle: String(localized: "Втрата фіксації, стрибки позиції"), icon: "location.slash") { log in
            var f: [LogFinding] = []
            let status = log.series("GPS", "Status"), sats = log.series("GPS", "NSats"), hd = log.series("GPS", "HDop")
            if status.isEmpty { return [LogFinding(level: .info, title: String(localized: "У лозі немає даних GPS"), detail: String(localized: "Повідомлень GPS немає (приймач вимкнено, інший тип навігації чи лог занадто короткий)."))] }
            let firstFix = status.first { $0.v >= 3 }?.t
            if firstFix == nil { f.append(LogFinding(level: .bad, title: String(localized: "3D-фіксація не була отримана"), detail: String(localized: "За весь лог приймач не вийшов на 3D. Автоматичні режими будуть недоступні."), tips: ["Перевірте антену та небо над нею, час розігріву, завади від силових дротів і VTX.", "Зачекайте щонайменше 1–2 хв після включення."], keys: ["GPS.NSats", "GPS.HDop"])) }
            else if let ff = firstFix {
                let lost = LogMath.intervals(status.filter { $0.t > ff }, minDur: 0.5) { $0 < 3 }
                for l in lost.prefix(3) { f.append(LogFinding(level: .bad, title: String(localized: "Втрата 3D-фіксації"), detail: String(localized: "З \(fmtT(l.0)) до \(fmtT(l.1)) (\(String(format: "%.1f", l.1 - l.0)) с) статус нижчий за 3D."), tips: ["Шукайте збіг у часі з увімкненням передавача чи ривками струму.", "Екранування антени корпусом або карбоном теж дає такі провали."], time: l.0, keys: ["GPS.Status", "GPS.NSats", "GPS.HDop"], window: (max(0, l.0 - 5), l.1 + 5))) }
                if let first = lost.first { _ = first }
            }
            let lowSats = LogMath.intervals(sats, minDur: 1) { $0 < 6 }
            if let l = lowSats.first { f.append(LogFinding(level: .warn, title: String(localized: "Мало супутників"), detail: String(localized: "Менше 6 супутників з \(fmtT(l.0)) до \(fmtT(l.1))."), tips: ["Для надійної навігації потрібно щонайменше 8–10 супутників."], time: l.0, keys: ["GPS.NSats"], window: (max(0, l.0 - 5), l.1 + 5))) }
            let badH = LogMath.intervals(hd, minDur: 1) { $0 > 2 }
            if let l = badH.first { f.append(LogFinding(level: .warn, title: String(localized: "Погана геометрія супутників (HDOP)"), detail: String(format: loc("HDOP понад 2 з %@ до %@, пік %.1f."), fmtT(l.0), fmtT(l.1), l.2), tips: ["Відкрийте небо, відсуньте антену від джерел завад."], time: l.0, keys: ["GPS.HDop"], window: (max(0, l.0 - 5), l.1 + 5))) }
            let glitch = log.messages.filter { $0.name == "ERR" && $0.text.contains("GPS") }
            if let g = glitch.first { f.append(LogFinding(level: .warn, title: String(localized: "GPS повідомляв про помилки"), detail: String(localized: "\(glitch.count) подій, перша о \(fmtT(g.time)): \(loc(g.text))."), tips: ["Перевірте, чи є збіг з іншими подіями (режим, газ, вмикання VTX)."], time: g.time)) }
            let ekf = ["SV", "SP"].compactMap { n -> (String, Double)? in LogMath.stats(log.series("XKF4", n)).map { (n, $0.max) } }
            if let w = ekf.max(by: { $0.1 < $1.1 }), w.1 > 1 { f.append(LogFinding(level: .warn, title: String(localized: "EKF не довіряв положенню"), detail: String(format: loc("Інновація %@ сягала %.1f (норма < 1). Це ознака розбіжності GPS і інших датчиків."), w.0, w.1), keys: ["XKF4.SV", "XKF4.SP"])) }
            if f.isEmpty { f.append(LogFinding(level: .ok, title: String(localized: "GPS працював стабільно"), detail: String(localized: "3D-фіксація без провалів, достатньо супутників, HDOP у нормі."), keys: ["GPS.NSats", "GPS.HDop"])) }
            return f
        },
        Symptom(id: "battery", title: String(localized: "Батарея й живлення"), subtitle: String(localized: "Просідання, ємність, low battery"), icon: "battery.25") { log in
            var f: [LogFinding] = []
            let v = log.series("BAT", "Volt").filter { $0.v > 1 }, c = log.series("BAT", "Curr")
            guard let sv = LogMath.stats(v), !v.isEmpty else { return [LogFinding(level: .info, title: String(localized: "У лозі немає даних батареї"), detail: String(localized: "Монітор батареї вимкнено або не налаштовано."))] }
            f.append(LogFinding(level: .info, title: String(localized: "Загальні показники"), detail: String(format: loc("Напруга від %.2f до %.2f В."), sv.max, sv.min) + (LogMath.stats(c).map { String(format: loc(" Максимальний струм %.1f А."), $0.max) } ?? "") + (log.series("BAT", "CurrTot").last.map { String(format: loc(" Витрачено %.0f мА·год."), $0.v) } ?? ""), keys: ["BAT.Volt", "BAT.Curr"]))
            // Оцінка опору: різниця напруги між високим і низьким струмом
            if v.count == c.count, let sc = LogMath.stats(c), sc.max > 5 {
                let hi = zip(v, c).filter { $0.1.v > sc.max * 0.7 }.map { ($0.0.v, $0.1.v) }, lo = zip(v, c).filter { $0.1.v < sc.max * 0.2 && $0.1.v >= 0 }.map { ($0.0.v, $0.1.v) }
                if hi.count > 5, lo.count > 5 {
                    let dv = lo.map(\.0).reduce(0, +) / Double(lo.count) - hi.map(\.0).reduce(0, +) / Double(hi.count)
                    let di = hi.map(\.1).reduce(0, +) / Double(hi.count) - lo.map(\.1).reduce(0, +) / Double(lo.count)
                    if di > 1 { let r = dv / di * 1000
                        f.append(LogFinding(level: r > 40 ? .warn : .info, title: String(format: loc("Оцінка опору батареї ≈ %.0f мОм"), max(0, r)), detail: String(format: loc("Просідання %.2f В при зміні струму на %.0f А. Росте від польоту до польоту означає старіння батареї."), dv, di), tips: r > 40 ? ["Великий опір: батарея зношена або перегріта, розгляньте заміну."] : [], keys: ["BAT.Volt", "BAT.Curr"]))
                    }
                }
            }
            let warnV = LogMath.intervals(v, minDur: 0.5) { $0 < (sv.max * 0.8) }
            if let w = warnV.first { f.append(LogFinding(level: .warn, title: String(localized: "Глибоке просідання напруги"), detail: String(format: loc("Напруга впала нижче 80 %% від максимальної о %@ (до %.2f В)."), fmtT(w.0), sv.min), tips: ["Порівняйте з піком струму: різке падіння при великому струмі це опір батареї, плавне це розряд."], time: w.0, keys: ["BAT.Volt", "BAT.Curr"], window: (max(0, w.0 - 8), w.1 + 8)))}
            if let vc = LogMath.stats(log.series("POWR", "Vcc")), vc.min < 4.5 || vc.max > 5.5 { f.append(LogFinding(level: .warn, title: String(localized: "Живлення плати поза нормою"), detail: String(format: loc("Vcc від %.2f до %.2f В (норма 4.5–5.5)."), vc.min, vc.max), tips: ["Перевірте силовий модуль, стабілізатор і пайку живлення."], keys: ["POWR.Vcc"])) }
            let msgs = log.messages.filter { $0.name == "MSG" && ($0.text.localizedCaseInsensitiveContains("battery") || $0.text.localizedCaseInsensitiveContains("low batt")) }
            if let m = msgs.first { f.append(LogFinding(level: .warn, title: String(localized: "Повідомлення про батарею"), detail: String(localized: "О \(fmtT(m.time)): \(loc(m.text))"), time: m.time)) }
            return f
        },
        Symptom(id: "pid", title: String(localized: "Налаштування PID і фільтрів"), subtitle: String(localized: "Коливання, млявість, шум, нотч"), icon: "dial.medium") { log in TuneAdvisor.run(log) },
        Symptom(id: "vibe", title: String(localized: "Вібрація й кліппінг"), subtitle: String(localized: "Шум, що псує навігацію"), icon: "waveform") { log in
            var f: [LogFinding] = []
            let axes = ["VibeX", "VibeY", "VibeZ"].compactMap { n -> (String, (min: Double, max: Double, mean: Double))? in LogMath.stats(log.series("VIBE", n)).map { (n, $0) } }
            guard !axes.isEmpty else { return [LogFinding(level: .info, title: String(localized: "У лозі немає даних вібрації"), detail: String(localized: "Повідомлення VIBE не записувалися."))] }
            for a in axes {
                let lvl: LogFinding.Level = a.1.max > 60 ? .bad : (a.1.max > 30 ? .warn : .ok)
                f.append(LogFinding(level: lvl, title: String(localized: "\(a.0): макс. \(Int(a.1.max)) м/с², сер. \(Int(a.1.mean))"), detail: lvl == .ok ? "У нормі." : "Перевищує допустимі значення (30 м/с²).", tips: lvl == .ok ? [] : ["Збалансуйте пропелери, перевірте кріплення, використайте віброгасіння."], keys: ["VIBE.\(a.0)"]))
            }
            let clip = ["Clip", "Clip0", "Clip1", "Clip2"].compactMap { n -> (String, [(t: Double, v: Double)])? in let s = log.series("VIBE", n); return s.isEmpty ? nil : (n, s) }
            for c in clip {
                if let last = c.1.last?.v, last > 0 {
                    let first = c.1.first { $0.v > 0 }?.t ?? 0
                    f.append(LogFinding(level: last > 100 ? .bad : .warn, title: String(localized: "Кліппінг (\(c.0)): \(Int(last)) подій"), detail: String(localized: "Перша подія о \(fmtT(first)). Кліппінг означає, що акселерометр був «обрізаний» вібрацією."), tips: ["Якщо лічильник швидко росте в польоті, усуньте джерело вібрації негайно."], time: first, keys: ["VIBE.\(c.0)"], window: (max(0, first - 3), first + 10)))
                }
            }
            return f
        },
        Symptom(id: "failsafe", title: String(localized: "Failsafe та помилки"), subtitle: String(localized: "Що і коли спрацювало"), icon: "exclamationmark.shield") { log in
            var f: [LogFinding] = []
            let errs = log.messages.filter { $0.name == "ERR" }
            if let er = log.byName["ERR"], let si = er.labels.firstIndex(of: "Subsys"), let ci = er.labels.firstIndex(of: "ECode") {
                for o in (log.index[er.type] ?? []) {
                    let sub = Int(log.value(er, si, at: o)), code = Int(log.value(er, ci, at: o)), t = log.time(er, at: o)
                    if let c = log.clip, t < c.from || t > c.to { continue }
                    let meaning = LogKnowledge.errMeaning(subsys: sub, code: code)
                    let bad = (sub == 12 || sub == 30 || (code != 0 && [5, 6, 7, 8, 9, 17].contains(sub)))
                    f.append(LogFinding(level: bad ? .bad : .warn, title: String(localized: "\(fmtT(t)): \(DFLog.errSubsys(sub)) (код \(code))"), detail: meaning, time: t, keys: []))
                }
            }
            for m in log.messages where m.name == "MSG" && (m.text.localizedCaseInsensitiveContains("failsafe") || m.text.localizedCaseInsensitiveContains("EKF") || m.text.localizedCaseInsensitiveContains("glitch")) {
                f.append(LogFinding(level: .warn, title: String(localized: "\(fmtT(m.time)): повідомлення"), detail: m.text, time: m.time))
            }
            if errs.isEmpty && f.isEmpty { f.append(LogFinding(level: .ok, title: String(localized: "Помилок і failsafe не зафіксовано"), detail: String(localized: "Повідомлень ERR немає, у текстових повідомленнях не знайдено слів failsafe, EKF чи glitch."))) }
            return Array(f.prefix(40))
        },
        Symptom(id: "crash", title: String(localized: "Падіння або втрата керування"), subtitle: String(localized: "Що було перед аварією"), icon: "bolt.trianglebadge.exclamationmark") { log in
            var f: [LogFinding] = []
            let crash = log.messages.first { $0.name == "ERR" && $0.text.contains("Crash check") }
            let end = crash?.time ?? log.duration
            f.append(LogFinding(level: crash == nil ? .info : .bad, title: crash == nil ? "Падіння за логом не зафіксовано" : String(localized: "Виявлено падіння о \(fmtT(end))"), detail: crash == nil ? "Підсистема Crash check не спрацьовувала. Розгляд останніх секунд логу нижче." : crash!.text, time: end, keys: ["ATT.Roll", "ATT.Pitch"], window: (max(0, end - 15), end + 2)))
            if let md = log.modeTimeline().last(where: { $0.t <= end }) { f.append(LogFinding(level: .info, title: String(localized: "Режим перед подією: \(log.modeName(md.mode))"), detail: String(localized: "Останнє перемикання режиму було о \(fmtT(md.t))."), time: md.t)) }
            let er = LogMath.diff(log.series("ATT", "Roll"), log.series("ATT", "DesRoll")).filter { $0.t > end - 6 && $0.t <= end }
            if let m = LogMath.stats(er.map { (t: $0.t, v: abs($0.v)) }), m.max > 20 { f.append(LogFinding(level: .bad, title: String(localized: "Втрата контролю перед подією"), detail: String(format: loc("За 6 с до події кут відхилявся від бажаного до %.0f°."), m.max), tips: ["Шукайте мотор чи пропелер, що відмовив: порівняйте виходи RCOU.", "Один вихід на максимумі, а решта на мінімумі вказує на відмову одного мотора."], keys: ["RCOU.C1", "RCOU.C2", "RCOU.C3", "RCOU.C4"], window: (max(0, end - 10), end + 1))) }
            if let b = LogMath.stats(log.series("VIBE", "VibeZ").filter { $0.t > end - 10 && $0.t <= end }), b.max > 40 { f.append(LogFinding(level: .warn, title: String(localized: "Висока вібрація перед подією"), detail: String(format: loc("Vibe Z до %.0f м/с²."), b.max), keys: ["VIBE.VibeZ"])) }
            return f
        },
        Symptom(id: "prearm", title: String(localized: "Не вмикається (PreArm)"), subtitle: String(localized: "Чому відмовляє ARM"), icon: "lock.trianglebadge.exclamationmark") { log in
            let pre = log.messages.filter { $0.name == "MSG" && $0.text.contains("PreArm") }
            if pre.isEmpty { return [LogFinding(level: .ok, title: String(localized: "Повідомлень PreArm у лозі немає"), detail: String(localized: "Запису відмов арму не знайдено. Якщо апарат не вмикався, перевірте логування до першого ARM або повідомлення на наземній станції."))] }
            var uniq: [String: Double] = [:]
            for m in pre { uniq[m.text] = uniq[m.text] ?? m.time }
            return uniq.sorted { $0.value < $1.value }.map { text, t in
                var tip = String(localized: "Перегляньте текст повідомлення й відповідну сторінку налаштувань.")
                let l = text.lowercased()
                if l.contains("gps") { tip = String(localized: "Зачекайте на 3D-фіксацію, перевірте антену й параметр GPS_*; для польоту без GPS змініть перевірки (ARMING_CHECK).") }
                else if l.contains("compass") || l.contains("mag") { tip = String(localized: "Відкрийте розділ Compass: калібрування, орієнтація, наявність завад.") }
                else if l.contains("accel") || l.contains("gyro") || l.contains("ins") { tip = String(localized: "Калібрування акселерометра/гіроскопа: Accel Calibration.") }
                else if l.contains("rc") || l.contains("radio") || l.contains("throttle") { tip = String(localized: "Радіокалібрування (Radio Calibration), положення стіків і канал газу.") }
                else if l.contains("battery") || l.contains("volt") { tip = String(localized: "Battery Monitor: пороги й мінімальна напруга для арму.") }
                else if l.contains("airspeed") { tip = String(localized: "Airspeed: калібрування нуля датчика.") }
                else if l.contains("ekf") || l.contains("ahrs") { tip = String(localized: "Зачекайте ініціалізації EKF, перевірте GPS, компас і вібрацію.") }
                else if l.contains("logging") { tip = String(localized: "Перевірте SD-картку.") }
                return LogFinding(level: .warn, title: "\(fmtT(t)): \(loc(text))", detail: tip, time: t)
            }
        },
        Symptom(id: "radio", title: String(localized: "Втрата радіозв'язку"), subtitle: String(localized: "Обриви каналів керування"), icon: "dot.radiowaves.left.and.right") { log in
            var f: [LogFinding] = []
            let thr = log.series("RCIN", "C3")
            if thr.isEmpty { return [LogFinding(level: .info, title: String(localized: "У лозі немає даних пульта"), detail: String(localized: "Повідомлення RCIN не записувалися."))] }
            let lost = LogMath.intervals(thr, minDur: 0.3) { $0 < 900 && $0 >= 0 }
            for l in lost.prefix(5) { f.append(LogFinding(level: .bad, title: String(localized: "Сигнал пульта зник"), detail: String(localized: "З \(fmtT(l.0)) до \(fmtT(l.1)) значення каналу газу нижче 900 мкс (втрата сигналу чи failsafe приймача)."), tips: ["Перевірте антени приймача, його живлення й дальність.", "Налаштуйте failsafe приймача й FS_THR_ENABLE."], time: l.0, keys: ["RCIN.C3"], window: (max(0, l.0 - 5), l.1 + 5))) }
            let msgs = log.messages.filter { $0.name == "MSG" && $0.text.localizedCaseInsensitiveContains("radio") }
            if let m = msgs.first { f.append(LogFinding(level: .warn, title: String(localized: "Повідомлення про радіо"), detail: String(localized: "О \(fmtT(m.time)): \(loc(m.text))"), time: m.time)) }
            if f.isEmpty { f.append(LogFinding(level: .ok, title: String(localized: "Втрат сигналу пульта не знайдено"), detail: String(localized: "Канал газу не опускався нижче 900 мкс; повідомлень про радіо немає."), keys: ["RCIN.C3"])) }
            return f
        },
    ]
}

// MARK: - Інтерфейс помічника

struct LogAssistantView: View {
    let log: DFLog
    let openGraph: (GraphRequest) -> Void
    let openMessages: () -> Void
    @State private var selected = "all"
    @State private var results: [String: [LogFinding]] = [:]
    @State private var busy = false
    @State private var rFrom = 0.0
    @State private var rTo = -1.0          // < 0: ще не ініціалізовано (весь лог)

    private var rangeTo: Double { rTo < 0 ? log.duration : min(rTo, log.duration) }
    private func rk(_ id: String) -> String { "\(id)|\(String(format: "%.2f", rFrom))|\(String(format: "%.2f", rangeTo))" }
    private var isFull: Bool { rFrom <= 0.05 && rangeTo >= log.duration - 0.05 }
    /// Лог для аналізу: увесь або обмежений вибраною ділянкою.
    private var activeLog: DFLog { isFull ? log : log.clipped(from: rFrom, to: rangeTo) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Помічник з читання логу").font(.title3.weight(.semibold))
                    Text("Оберіть, що вас турбує, і помічник пройде по відповідних даних, покаже докази на графіках і підкаже, що перевірити.").font(.caption).foregroundStyle(.secondary)
                }
                LogRangeBar(log: log, from: $rFrom, to: Binding(get: { rangeTo }, set: { rTo = $0 }))
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190, maximum: 260), spacing: 10)], spacing: 10) {
                    card(id: "all", title: String(localized: "Швидка перевірка всього логу"), subtitle: String(localized: "Усі сценарії одразу"), icon: "sparkles")
                    ForEach(LogAssistant.symptoms) { s in card(id: s.id, title: s.title, subtitle: s.subtitle, icon: s.icon) }
                }
                let list = findings()
                if busy { HStack(spacing: 8) { ProgressView().controlSize(.small); Text(lk(isFull ? "Аналіз логу…" : String(localized: "Аналіз ділянки \(fmtT(rFrom)) – \(fmtT(rangeTo))…"))).font(.callout).foregroundStyle(.secondary) } }
                ForEach(list, id: \.0) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        if selected == "all" { Text(verbatim: loc(group.0).uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 6) }
                        ForEach(group.1) { fi in findingCard(fi) }
                    }
                }
            }
            .padding(14)
        }
        .task(id: "\(selected)|\(rFrom)|\(rTo)") { await compute() }
    }

    func findings() -> [(String, [LogFinding])] {
        if selected == "all" {
            return LogAssistant.symptoms.compactMap { s -> (String, [LogFinding])? in
                guard let r = results[rk(s.id)]?.filter({ $0.level == .warn || $0.level == .bad }), !r.isEmpty else { return nil }
                return (s.title, r)
            }
        }
        guard let s = LogAssistant.symptoms.first(where: { $0.id == selected }), let r = results[rk(s.id)] else { return [] }
        return [(s.title, r)]
    }

    /// Обчислення у фоні, по одному сценарію; результати кешуються.
    func compute() async {
        let todo = (selected == "all" ? LogAssistant.symptoms : LogAssistant.symptoms.filter { $0.id == selected }).filter { results[rk($0.id)] == nil }
        guard !todo.isEmpty else { return }
        busy = true
        let target = activeLog
        for s in todo {
            let r = await Task.detached(priority: .userInitiated) { s.run(target) }.value
            results[rk(s.id)] = r
        }
        busy = false
    }

    func card(id: String, title: String, subtitle: String, icon: String) -> some View {
        let on = selected == id
        return Button { selected = id } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon).font(.system(size: 15, weight: .semibold)).frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(LocalizedStringKey(title)).font(.callout.weight(.semibold)).multilineTextAlignment(.leading)
                    Text(LocalizedStringKey(subtitle)).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(on ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(on ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.08), lineWidth: on ? 1.5 : 1))
        }.buttonStyle(.plain)
    }

    func findingCard(_ f: LogFinding) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: f.icon).foregroundStyle(f.color).frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(LocalizedStringKey(f.title)).font(.callout.weight(.semibold))
                    Text(LocalizedStringKey(f.detail)).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            if !f.keys.isEmpty { FindingChart(log: log, keys: f.keys, window: f.window) }
            if !f.changes.isEmpty { ChangesBlock(log: log, changes: f.changes) }
            if !f.tips.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("ЩО ПЕРЕВІРИТИ").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(f.tips, id: \.self) { t in Label(LocalizedStringKey(t), systemImage: "arrow.turn.down.right").font(.callout).fixedSize(horizontal: false, vertical: true) }
                }
            }
            HStack(spacing: 8) {
                if !f.keys.isEmpty {
                    Button { openGraph(GraphRequest(keys: f.keys, from: f.window?.0 ?? 0, to: f.window?.1 ?? log.duration)) } label: { Label("Відкрити на графіку", systemImage: "chart.xyaxis.line") }
                }
                if f.time != nil { Button { openMessages() } label: { Label("Повідомлення", systemImage: "text.bubble") } }
                if let t = f.time { Text("час \(fmtT(t))").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
            }.controlSize(.small)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// Міні-графік доказів: дані будуються у фоні один раз.
struct FindingChart: View {
    let log: DFLog
    let keys: [String]
    let window: (Double, Double)?
    @State private var data: [CSeries] = []
    @State private var cur = CursorModel()

    var from: Double { window?.0 ?? 0 }
    var to: Double { max(window?.1 ?? log.duration, from + 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if data.count > 1 { SeriesLegend(series: data) }
            InteractiveChart(series: data, x0: from, x1: to, height: 96, cur: cur)
        }
        .task(id: keys.joined(separator: ",") + "\(from)-\(to)") {
            let (f, tt, ks) = (from, to, keys)
            data = await Task.detached(priority: .userInitiated) { () -> [CSeries] in
                var out: [CSeries] = []
                for (i, k) in ks.enumerated() {
                    let p = k.split(separator: ".").map(String.init)
                    guard p.count == 2 else { continue }
                    let s = log.series(p[0], p[1]).filter { $0.t >= f && $0.t <= tt && $0.v.isFinite }
                    guard s.count > 1 else { continue }
                    let dec = LogGraphView.decimate(s.map { (t: $0.t, v: $0.v) })
                    out.append(CSeries(id: k, name: k, color: ChartPalette.color(i), t: dec.map(\.t), v: dec.map(\.v)))
                }
                return out
            }.value
        }
    }
}
