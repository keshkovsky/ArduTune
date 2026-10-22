import SwiftUI

/// Автоаналіз Dataflash-логу (набір перевірок за мотивами Auto Analysis у Mission Planner).
struct LogCheck: Identifiable {
    enum Status { case ok, warn, fail, info, na }
    let id = UUID()
    let title: String
    let status: Status
    let detail: String

    var color: Color { switch status { case .ok: .green; case .warn: .orange; case .fail: .red; case .info: .blue; case .na: .secondary } }
    var icon: String { switch status { case .ok: "checkmark.circle.fill"; case .warn: "exclamationmark.triangle.fill"; case .fail: "xmark.octagon.fill"; case .info: "info.circle.fill"; case .na: "minus.circle" } }
}

enum LogAnalysis {
    static func run(_ log: DFLog) -> [LogCheck] {
        var out: [LogCheck] = []
        func f1(_ v: Double) -> String { String(format: "%.1f", v) }
        func f2(_ v: Double) -> String { String(format: "%.2f", v) }
        func stats(_ s: [(t: Double, v: Double)]) -> (min: Double, max: Double, mean: Double)? {
            let v = s.map(\.v).filter { $0.isFinite }
            guard !v.isEmpty else { return nil }
            return (v.min()!, v.max()!, v.reduce(0, +) / Double(v.count))
        }

        // --- Загальне ---
        let size = ByteCountFormatter.string(fromByteCount: Int64(log.data.count), countStyle: .file)
        let dur = log.duration
        out.append(LogCheck(title: String(localized: "Лог"), status: log.count("ATT") > 0 ? .info : .warn,
                            detail: String(localized: "\(log.vehicleName). Тривалість \(Int(dur) / 60) хв \(Int(dur) % 60) с, \(size), повідомлень: \(log.messageCount).") + (log.count("ATT") == 0 ? " Немає ATT: лог порожній або обрізаний." : "")))

        // --- Вібрація ---
        let vx = log.series("VIBE", "VibeX"), vy = log.series("VIBE", "VibeY"), vz = log.series("VIBE", "VibeZ")
        if let sx = stats(vx), let sy = stats(vy), let sz = stats(vz) {
            let mx = max(sx.max, sy.max, sz.max)
            let st: LogCheck.Status = mx > 60 ? .fail : (mx > 30 ? .warn : .ok)
            out.append(LogCheck(title: String(localized: "Вібрація"), status: st, detail: String(localized: "Макс. X \(f1(sx.max)), Y \(f1(sy.max)), Z \(f1(sz.max)) м/с². Середня Z \(f1(sz.mean)). Норма < 30, понад 60 небезпечно для EKF.")))
            var clip = 0.0
            for n in ["Clip", "Clip0", "Clip1", "Clip2"] { if let l = log.series("VIBE", n).last?.v { clip += l } }
            out.append(LogCheck(title: String(localized: "Кліппінг акселерометра"), status: clip > 100 ? .fail : (clip > 0 ? .warn : .ok), detail: clip == 0 ? "Кліппінгу немає." : String(localized: "Зафіксовано \(Int(clip)) подій кліппінгу.")))
        } else { out.append(LogCheck(title: String(localized: "Вібрація"), status: .na, detail: String(localized: "Повідомлень VIBE немає."))) }

        // --- GPS ---
        let sats = log.series("GPS", "NSats"), hd = log.series("GPS", "HDop"), gs = log.series("GPS", "Status")
        if !sats.isEmpty {
            let minS = sats.map(\.v).min() ?? 0, maxHD = hd.map(\.v).max() ?? 0
            var lost = 0; var had = false
            for g in gs { if g.v >= 3 { had = true } else if had { lost += 1 } }
            let st: LogCheck.Status = (lost > 5 || minS < 6) ? .warn : .ok
            out.append(LogCheck(title: "GPS", status: had ? st : .fail, detail: had ? String(localized: "Супутників мін. \(Int(minS)), HDOP макс. \(f2(maxHD)), втрат фіксації: \(lost).") : "3D-фіксацію не було отримано."))
        } else { out.append(LogCheck(title: "GPS", status: .na, detail: String(localized: "Повідомлень GPS немає."))) }

        // --- Батарея ---
        let volt = log.series("BAT", "Volt"), cur = log.series("BAT", "Curr")
        if let sv = stats(volt.filter { $0.v > 1 }) {
            let used = log.series("BAT", "CurrTot").last?.v ?? 0
            let mc = cur.map(\.v).max() ?? 0
            let sag = sv.max > 0 ? (sv.max - sv.min) / sv.max : 0
            out.append(LogCheck(title: String(localized: "Батарея"), status: sag > 0.35 ? .warn : .ok, detail: String(localized: "Напруга \(f2(sv.max)) → мін. \(f2(sv.min)) В (просідання \(Int(sag * 100))%), макс. струм \(f1(mc)) А, витрачено \(Int(used)) мАг.")))
        } else { out.append(LogCheck(title: String(localized: "Батарея"), status: .na, detail: String(localized: "Повідомлень BAT немає."))) }

        // --- Живлення ---
        if let sv = stats(log.series("POWR", "Vcc")), sv.max > 0 {
            out.append(LogCheck(title: String(localized: "Живлення плати (Vcc)"), status: (sv.min < 4.5 || sv.max > 5.5) ? .warn : .ok, detail: String(localized: "Vcc \(f2(sv.min))…\(f2(sv.max)) В (норма 4.5–5.5).")))
        }

        // --- Слідкування за кутами ---
        let dr = log.series("ATT", "DesRoll"), r = log.series("ATT", "Roll"), dp = log.series("ATT", "DesPitch"), p = log.series("ATT", "Pitch")
        if !r.isEmpty, dr.count == r.count, dp.count == p.count {
            var er = 0.0, ep = 0.0, mr = 0.0, mp = 0.0
            for i in 0..<r.count { let a = abs(dr[i].v - r[i].v); er += a; mr = max(mr, a) }
            for i in 0..<p.count { let a = abs(dp[i].v - p[i].v); ep += a; mp = max(mp, a) }
            er /= Double(r.count); ep /= Double(p.count)
            let st: LogCheck.Status = (mr > 40 || mp > 40) ? .fail : ((er > 5 || ep > 5 || mr > 25 || mp > 25) ? .warn : .ok)
            out.append(LogCheck(title: String(localized: "Відпрацювання кутів"), status: st, detail: String(localized: "Помилка крену: сер. \(f1(er))°, макс. \(f1(mr))°; тангажу: сер. \(f1(ep))°, макс. \(f1(mp))°. Велика помилка вказує на вібрацію, слабкі мотори або невдалий тюнінг.")))
        }

        // --- Компас ---
        if log.count("MAG") > 0 {
            var mags: [Double] = []
            if let f = log.byName["MAG"], let ix = f.labels.firstIndex(of: "MagX"), let iy = f.labels.firstIndex(of: "MagY"), let iz = f.labels.firstIndex(of: "MagZ") {
                for o in log.index[f.type] ?? [] {
                    let x = log.value(f, ix, at: o), y = log.value(f, iy, at: o), z = log.value(f, iz, at: o)
                    mags.append(sqrt(x * x + y * y + z * z))
                }
            }
            if let mean = Optional(mags.reduce(0, +) / Double(max(1, mags.count))), mean > 0 {
                let spread = ((mags.max() ?? 0) - (mags.min() ?? 0)) / mean
                out.append(LogCheck(title: String(localized: "Компас"), status: spread > 1 ? .fail : (spread > 0.5 ? .warn : .ok), detail: String(localized: "Сер. довжина поля \(Int(mean)) мГс, розкид \(Int(spread * 100))% від середнього. Великий розкид означає наведення від струмів або погане калібрування.")))
            }
        } else { out.append(LogCheck(title: String(localized: "Компас"), status: .na, detail: String(localized: "Повідомлень MAG немає (компаса немає або вимкнено)."))) }

        // --- EKF ---
        let ekfName = log.byName["XKF4"] != nil ? "XKF4" : (log.byName["NKF4"] != nil ? "NKF4" : nil)
        if let en = ekfName {
            var mx = 0.0; var worst = ""
            for fld in ["SV", "SP", "SH", "SM"] { if let s = stats(log.series(en, fld)), s.max > mx { mx = s.max; worst = fld } }
            out.append(LogCheck(title: String(localized: "EKF (інновації)"), status: mx > 1 ? .fail : (mx > 0.8 ? .warn : .ok), detail: String(localized: "Макс. відношення тесту \(f2(mx))") + (mx > 0.5 ? " (\(worst))" : "") + loc(". Значення понад 1 означає відхилення сенсорів.")))
        } else { out.append(LogCheck(title: String(localized: "EKF (інновації)"), status: .na, detail: String(localized: "Повідомлень XKF4/NKF4 немає."))) }

        // --- Помилки і failsafe ---
        let errs = log.messages.filter { $0.name == "ERR" }
        if errs.isEmpty { out.append(LogCheck(title: String(localized: "Помилки і failsafe"), status: .ok, detail: String(localized: "Повідомлень ERR немає."))) }
        else {
            let crash = errs.contains { $0.text.contains("Crash check") }
            let uniq = Dictionary(grouping: errs, by: \.text).map { "\($0.key) ×\($0.value.count)" }.sorted()
            out.append(LogCheck(title: String(localized: "Помилки і failsafe"), status: crash ? .fail : .warn, detail: uniq.joined(separator: "; ")))
        }

        // --- Режими ---
        let tl = log.modeTimeline()
        if !tl.isEmpty {
            var per: [Int: Double] = [:]
            for i in 0..<tl.count { let end = i + 1 < tl.count ? tl[i + 1].t : dur; per[tl[i].mode, default: 0] += max(0, end - tl[i].t) }
            let s = per.sorted { $0.value > $1.value }.map { String(localized: "\(log.modeName($0.key)) \(Int($0.value)) с") }.joined(separator: ", ")
            out.append(LogCheck(title: String(localized: "Режими польоту"), status: .info, detail: s + String(localized: ". Перемикань: \(tl.count - 1).")))
        }

        // --- Параметри ---
        let pm = Dictionary(log.parameters.map { ($0.name, $0.value) }, uniquingKeysWith: { a, _ in a })
        var pw: [String] = []
        if let v = pm["ARMING_CHECK"], v == 0 { pw.append("ARMING_CHECK = 0 (передпольотні перевірки вимкнено)") }
        if let v = pm["FS_THR_ENABLE"], v == 0 { pw.append("FS_THR_ENABLE = 0 (failsafe втрати радіо вимкнено)") }
        if let v = pm["BATT_FS_LOW_ACT"], v == 0, (pm["BATT_LOW_VOLT"] ?? 0) > 0 || (pm["BATT_LOW_MAH"] ?? 0) > 0 { pw.append("BATT_FS_LOW_ACT = 0 (дія при низькому заряді не задана)") }
        if let v = pm["FENCE_ENABLE"], v == 0 { pw.append("Геозона вимкнена") }
        if log.parameters.isEmpty { out.append(LogCheck(title: String(localized: "Параметри"), status: .na, detail: String(localized: "Параметрів у лозі немає."))) }
        else { out.append(LogCheck(title: String(localized: "Параметри"), status: pw.isEmpty ? .ok : .warn, detail: pw.isEmpty ? String(localized: "Ключових зауважень немає (\(log.parameters.count) параметрів).") : pw.joined(separator: "; "))) }

        return out
    }
}
