import SwiftUI

// MARK: - Модель параметрів налаштування (PID і фільтри) залежно від типу апарата

struct TuneAxis: Identifiable {
    let id: String            // RLL / PIT / YAW
    let title: String
    let icon: String
    let rate: [String]        // параметри швидкісного контролера
    let outer: [String]       // кутовий контур, прискорення, постійні часу
}

struct TuneModel {
    enum Kind { case copter, quadplane, plane, planeLegacy }
    let kind: Kind
    let axes: [TuneAxis]
    let filters: [String]
    let notch: [String]
    let global: [String]      // загальні (вхідний фільтр, експонента тяги тощо)
    let position: [String]    // висота, позиція, навігація

    var allNames: [String] { axes.flatMap { $0.rate + $0.outer } + filters + notch + global + position }
    var title: String {
        switch kind { case .copter: "Мультикоптер"; case .quadplane: "QuadPlane (VTOL)"; case .plane, .planeLegacy: "Літак" }
    }

    static let rateSuffix = ["P", "I", "D", "FF", "IMAX", "FLTT", "FLTD", "FLTE", "SMAX"]

    /// Визначає набір параметрів за наявністю їх у прошивці.
    init?(_ ps: ParamStore) {
        let ax = [("RLL", "Крен (Roll)", "arrow.left.and.right.circle"), ("PIT", "Тангаж (Pitch)", "arrow.up.and.down.circle"), ("YAW", "Рискання (Yaw)", "arrow.triangle.2.circlepath.circle")]
        func filtered(_ l: [String]) -> [String] { l.filter { ps.has($0) } }
        let inFilters = filtered(["INS_GYRO_FILTER", "INS_ACCEL_FILTER", "INS_GYRO_RATE", "INS_FAST_SAMPLE"])
        let notch = filtered(["INS_HNTCH_ENABLE", "INS_HNTCH_MODE", "INS_HNTCH_REF", "INS_HNTCH_FREQ", "INS_HNTCH_BW", "INS_HNTCH_ATT", "INS_HNTCH_HMNCS", "INS_HNTCH_OPTS", "INS_HNTCH_FM_RAT"])
        if ps.has("ATC_RAT_RLL_P") {
            kind = .copter
            axes = ax.map { a in
                let g = a.0 == "RLL" ? "R" : (a.0 == "PIT" ? "P" : "Y")
                return TuneAxis(id: a.0, title: a.1, icon: a.2, rate: filtered(Self.rateSuffix.map { "ATC_RAT_\(a.0)_\($0)" }),
                                outer: filtered(["ATC_ANG_\(a.0)_P", "ATC_ACCEL_\(g)_MAX"]))
            }
            filters = inFilters; self.notch = notch
            global = filtered(["ATC_INPUT_TC", "ATC_THR_MIX_MAN", "MOT_THST_EXPO", "MOT_THST_HOVER"])
            position = filtered(["PSC_POSXY_P", "PSC_NE_POS_P", "PSC_VELXY_P", "PSC_NE_VEL_P", "PSC_VELXY_I", "PSC_NE_VEL_I", "PSC_VELXY_D", "PSC_NE_VEL_D", "PSC_POSZ_P", "PSC_D_POS_P", "PSC_VELZ_P", "PSC_D_VEL_P", "PSC_ACCZ_P", "PSC_D_ACC_P", "PSC_ACCZ_I", "PSC_D_ACC_I"])
        } else if ps.has("RLL_RATE_P") {
            kind = .plane
            axes = [
                TuneAxis(id: "RLL", title: ax[0].1, icon: ax[0].2, rate: filtered(Self.rateSuffix.map { "RLL_RATE_\($0)" } + ["RLL_RATE_D_FF", "RLL_RATE_PDMX"]), outer: filtered(["RLL2SRV_TCONST", "RLL2SRV_RMAX", "NAVL1_LIM_BANK"])),
                TuneAxis(id: "PIT", title: ax[1].1, icon: ax[1].2, rate: filtered(Self.rateSuffix.map { "PTCH_RATE_\($0)" } + ["PTCH_RATE_D_FF", "PTCH_RATE_PDMX"]), outer: filtered(["PTCH2SRV_TCONST", "PTCH2SRV_RMAX_UP", "PTCH2SRV_RMAX_DN", "PTCH2SRV_RLL", "PTCH_LIM_MAX_DEG", "PTCH_LIM_MIN_DEG", "PTCH_TRIM_DEG"])),
                TuneAxis(id: "YAW", title: ax[2].1, icon: ax[2].2, rate: filtered(Self.rateSuffix.map { "YAW_RATE_\($0)" }), outer: filtered(["YAW2SRV_SLIP", "YAW2SRV_INT", "YAW2SRV_DAMP", "YAW2SRV_RLL", "YAW2SRV_IMAX"])),
            ]
            filters = inFilters; self.notch = notch
            global = filtered(["STAB_PITCH_DOWN", "KFF_RDDRMIX", "KFF_THR2PTCH", "MIXING_GAIN"])
            position = filtered(["TECS_TIME_CONST", "TECS_THR_DAMP", "TECS_PTCH_DAMP", "TECS_INTEG_GAIN", "TECS_SPDWEIGHT", "TECS_CLMB_MAX", "TECS_SINK_MIN", "TECS_SINK_MAX", "TECS_PITCH_MAX", "TECS_PITCH_MIN", "TECS_VERT_ACC", "NAVL1_PERIOD", "NAVL1_DAMPING", "NAVL1_XTRACK_I"])
        } else if ps.has("RLL2SRV_P") {
            kind = .planeLegacy
            func lg(_ p: String) -> [String] { filtered(["P", "I", "D", "FF", "IMAX"].map { "\(p)2SRV_\($0)" }) }
            axes = [
                TuneAxis(id: "RLL", title: ax[0].1, icon: ax[0].2, rate: lg("RLL"), outer: filtered(["RLL2SRV_TCONST", "RLL2SRV_RMAX"])),
                TuneAxis(id: "PIT", title: ax[1].1, icon: ax[1].2, rate: lg("PTCH"), outer: filtered(["PTCH2SRV_TCONST", "PTCH2SRV_RMAX_UP", "PTCH2SRV_RMAX_DN", "PTCH2SRV_RLL"])),
                TuneAxis(id: "YAW", title: ax[2].1, icon: ax[2].2, rate: [], outer: filtered(["YAW2SRV_SLIP", "YAW2SRV_INT", "YAW2SRV_DAMP", "YAW2SRV_RLL", "YAW2SRV_IMAX"])),
            ]
            filters = inFilters; self.notch = notch
            global = filtered(["STAB_PITCH_DOWN", "KFF_RDDRMIX", "KFF_THR2PTCH"])
            position = filtered(["TECS_TIME_CONST", "TECS_THR_DAMP", "TECS_PTCH_DAMP", "TECS_INTEG_GAIN", "TECS_SPDWEIGHT", "NAVL1_PERIOD", "NAVL1_DAMPING"])
        } else { return nil }
    }
}

// MARK: - Підказки та поради

struct TuneTip { let title: String; let what: String; let howTo: String; let warning: String }

enum TuneTips {
    /// Канонічний ключ параметра: RATE_P, RATE_FLTD, ANGLE_P…
    static func key(_ name: String) -> String {
        if let r = name.range(of: #"(ATC_RAT_(RLL|PIT|YAW)_|Q_A_RAT_(RLL|PIT|YAW)_|RLL_RATE_|PTCH_RATE_|YAW_RATE_|RLL2SRV_|PTCH2SRV_)(P|I|D|FF|IMAX|FLTT|FLTD|FLTE|SMAX)$"#, options: .regularExpression),
           let last = name[r].split(separator: "_").last { return "RATE_" + last }
        if name.range(of: #"^(Q_A_)?ATC_ANG_(RLL|PIT|YAW)_P$"#, options: .regularExpression) != nil || name.hasPrefix("ATC_ANG_") { return "ANGLE_P" }
        if name.contains("ACCEL_") && name.hasSuffix("_MAX") && name.contains("ATC") { return "ACCEL_MAX" }
        if name.hasSuffix("2SRV_TCONST") { return "TCONST" }
        if name.hasSuffix("2SRV_RMAX") || name.contains("_RMAX_") { return "RMAX" }
        return name
    }

    static let table: [String: TuneTip] = [
        "RATE_P": TuneTip(title: String(localized: "P: пропорційний коефіцієнт"), what: String(localized: "Реакція на помилку обертання: чим більша різниця між бажаною й фактичною швидкістю, тим сильніша корекція."),
                          howTo: String(localized: "Збільшуйте кроками по 10–20 %, перевіряючи кожен крок коротким висінням. Зупиніться за 20–30 % до появи швидкого дрижання."),
                          warning: String(localized: "Завеликий P дає швидкі коливання й гул моторів; замалий робить апарат млявим і «плаваючим».")),
        "RATE_I": TuneTip(title: String(localized: "I: інтегральний коефіцієнт"), what: String(localized: "Накопичує тривалу помилку й тримає кут при вітрі, дисбалансі та зсуві центру ваги."),
                          howTo: String(localized: "Для крену й тангажа типово задають I приблизно рівним P. Збільшуйте, якщо апарат повільно «сповзає» від бажаного положення."),
                          warning: String(localized: "Завеликий I дає повільні хитання й відскоки після маневрів.")),
        "RATE_D": TuneTip(title: String(localized: "D: диференціальний коефіцієнт"), what: String(localized: "Гасить різкі зміни швидкості обертання й коливання від P."),
                          howTo: String(localized: "Налаштовуйте після P: підвищуйте D, поки коливання не зникнуть. Контролюйте температуру моторів після 1–2 хв польоту."),
                          warning: String(localized: "Завеликий D підсилює шум, гріє мотори й може викликати дрижання; для рискання D зазвичай 0.")),
        "RATE_FF": TuneTip(title: String(localized: "FF: пряма подача (feedforward)"), what: String(localized: "Миттєво додає керування за командою пілота без очікування помилки. Прискорює відгук без ризику коливань."),
                           howTo: String(localized: "Збільшуйте, якщо апарат запізнюється за стіками. Помірні значення зазвичай безпечні."),
                           warning: String(localized: "Завеликий FF дає перерегулювання на різкому русі стіків.")),
        "RATE_IMAX": TuneTip(title: String(localized: "IMAX: ліміт інтегралу"), what: String(localized: "Обмежує внесок I-складової."), howTo: String(localized: "Залишайте типове значення; збільшуйте лише при постійно великому зсуві (вітер, нерівний баланс)."), warning: String(localized: "Завеликий IMAX дає довге «розкачування» після рівнів.")),
        "RATE_FLTT": TuneTip(title: String(localized: "FLTT: фільтр цілі, Гц"), what: String(localized: "Згладжує бажану швидкість обертання."), howTo: String(localized: "Тримайте близько до FLTD або трохи нижче; зменшуйте для плавнішого відгуку."), warning: String(localized: "Занадто низьке значення додає затримку керування.")),
        "RATE_FLTD": TuneTip(title: String(localized: "FLTD: фільтр D-складової, Гц"), what: String(localized: "Прибирає шум із D. Нижче значення = менше шуму й тепла, але повільніше гасіння."),
                             howTo: String(localized: "Орієнтир: приблизно половина INS_GYRO_FILTER (не менше 10 Гц)."), warning: String(localized: "Занадто високе значення пропускає шум у D й гріє мотори.")),
        "RATE_FLTE": TuneTip(title: String(localized: "FLTE: фільтр помилки, Гц"), what: String(localized: "Фільтрує помилку перед P та I."), howTo: String(localized: "Для крену й тангажа зазвичай 0 (вимкнено), для рискання близько 2 Гц."), warning: String(localized: "Завеликий вплив додає затримку.")),
        "RATE_SMAX": TuneTip(title: String(localized: "SMAX: ліміт швидкості наростання"), what: String(localized: "Обмежує, як швидко може змінюватися вихід (slew limiter) для захисту від резонансу."), howTo: String(localized: "Залишайте типове, змінюйте при незрозумілих високочастотних коливаннях."), warning: String(localized: "Занадто низьке значення сповільнює відгук.")),
        "ANGLE_P": TuneTip(title: String(localized: "Кутовий P"), what: String(localized: "Наскільки швидко апарат повертається до бажаного кута."), howTo: String(localized: "Збільшуйте для різкішого утримання кута, зменшуйте для плавності."), warning: String(localized: "Завеликий кутовий P разом із високим швидкісним P дає коливання.")),
        "ACCEL_MAX": TuneTip(title: String(localized: "Макс. кутове прискорення"), what: String(localized: "Обмежує, як швидко апарат може почати чи зупинити обертання."), howTo: String(localized: "Підбирається за розміром пропелера (див. «Initial Parameters»). Менше значення = плавніше."), warning: String(localized: "Завелике значення перевантажує двигуни й дає різкі маневри.")),
        "TCONST": TuneTip(title: String(localized: "Постійна часу, с"), what: String(localized: "Час, за який літак виходить на бажаний кут. Менше = різкіше."), howTo: String(localized: "Типово 0.4–0.8 с. Збільшуйте, якщо літак коливається по крену чи тангажу."), warning: String(localized: "Замале значення дає різкість і коливання.")),
        "RMAX": TuneTip(title: String(localized: "Макс. швидкість обертання"), what: String(localized: "Обмеження швидкості обертання в °/с."), howTo: String(localized: "Знижуйте для тренувального літака, підвищуйте для акробатичного."), warning: String(localized: "Завеликий ліміт може перевантажити конструкцію.")),
        "INS_GYRO_FILTER": TuneTip(title: String(localized: "Фільтр гіроскопа, Гц"), what: String(localized: "Низькочастотний фільтр гіроскопа: прибирає вібраційний шум до PID."),
                                   howTo: String(localized: "Типово 20 Гц. Для великих пропелерів знижуйте (10–15), для малих і чистих платформ збільшуйте (40+). Підганяйте FLTD під половину цього значення."),
                                   warning: String(localized: "Завеликий поріг пропускає шум і гріє мотори, замалий додає затримку й коливання.")),
        "INS_ACCEL_FILTER": TuneTip(title: String(localized: "Фільтр акселерометра, Гц"), what: String(localized: "Фільтр акселерометра для навігації й оцінки висоти."), howTo: String(localized: "Залишайте 10–20 Гц, не вище порога гіроскопа."), warning: String(localized: "Завеликий поріг додає шум у висоту й позицію.")),
        "ATC_INPUT_TC": TuneTip(title: String(localized: "Постійна часу вхідного сигналу, с"), what: String(localized: "Згладжує команди пілота: менше = різкіше, більше = плавніше."), howTo: String(localized: "Зменшуйте для спортивного відчуття, збільшуйте для плавної кінозйомки."), warning: String(localized: "Замале значення дає ривки.")),
        "MOT_THST_EXPO": TuneTip(title: String(localized: "Крива тяги (expo)"), what: String(localized: "Нелінійність залежності тяги від газу."), howTo: String(localized: "Типово 0.15 для малих і 0.65 для великих пропелерів. Підбирається за розміром пропелера."), warning: String(localized: "Неправильне значення робить керування нерівномірним на різних рівнях газу.")),
    ]

    static func tip(_ name: String) -> TuneTip? { table[key(name)] ?? table[name] }

    /// Загальний покроковий порядок безпечного налаштування.
    static let workflow: [(String, String)] = [
        ("Підготуйте апарат", "Перевірте кріплення пропелерів і балансування, калібрування акселерометра й компаса, заряджену батарею. Налаштовуйте при слабкому вітрі над відкритим місцем."),
        ("Спершу фільтри", "Подивіться вібрацію (X, Y, Z нижче 30 м/с²). Ввімкніть режекторний фільтр лише за наявності шуму на частоті моторів. Не налаштовуйте PID, поки вібрації високі."),
        ("Потім швидкісні PID", "Крен і тангаж: P → D → I → FF. Змінюйте по одному параметру на 10–20 % і робіть короткий політ у режимі Stabilize/FBWA."),
        ("Рискання окремо", "Yaw зазвичай потребує менше змін: P і I, D лишається 0, фільтр помилки близько 2 Гц."),
        ("Кутова чутливість", "Лише після швидкісних PID: кутові P/постійні часу задають, наскільки різко апарат займає кут."),
        ("Фіксуйте результат", "Робіть знімок налаштувань перед кожною серією змін, щоб у разі проблем повернутися за один клік. Автонастройка AutoTune дає хорошу відправну точку."),
    ]
}

// MARK: - Зміни, знімки й порівняння

struct TuneChange: Codable, Hashable { let name: String; let old: Double; let new: Double }
struct TuneEntry: Codable, Identifiable { var id = UUID(); var date: Date; var label: String; var changes: [TuneChange] }
struct TuneSnapshot: Codable, Identifiable { var id = UUID(); var name: String; var date: Date; var values: [String: Double] }

@Observable
final class TuneStore {
    var history: [TuneEntry] = []
    var snapshots: [TuneSnapshot] = []
    var baseline: [String: Double] = [:]
    var lastApplied: UUID?

    private static var dir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ArduTune/Tune", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    init() { load() }

    func load() {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        if let d = try? Data(contentsOf: Self.dir.appendingPathComponent("history.json")), let h = try? dec.decode([TuneEntry].self, from: d) { history = h }
        if let d = try? Data(contentsOf: Self.dir.appendingPathComponent("snapshots.json")), let s = try? dec.decode([TuneSnapshot].self, from: d) { snapshots = s }
    }
    func save() {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        if let d = try? enc.encode(Array(history.suffix(300))) { try? d.write(to: Self.dir.appendingPathComponent("history.json")) }
        if let d = try? enc.encode(snapshots) { try? d.write(to: Self.dir.appendingPathComponent("snapshots.json")) }
    }

    /// Початкові значення (на момент відкриття сторінки), до яких можна повернутися.
    func captureBaseline(_ ps: ParamStore, names: [String]) {
        guard baseline.isEmpty else { return }
        for n in names { if let v = ps.val(n) { baseline[n] = v } }
    }

    /// Записує зміни на польотник і фіксує їх в історії. Послідовні ручні зміни з однаковою позначкою зливаються в один запис.
    func apply(_ ps: ParamStore, _ changes: [String: Double], label: String, merge: Bool = false) {
        var recs: [TuneChange] = []
        for (n, v) in changes {
            guard let old = ps.val(n), abs(old - v) > 1e-9 else { continue }
            recs.append(TuneChange(name: n, old: old, new: v))
            ps.write(n, v)
        }
        guard !recs.isEmpty else { return }
        recs.sort { $0.name < $1.name }
        if merge, var last = history.last, last.label == label, Date().timeIntervalSince(last.date) < 120 {
            for r in recs {
                if let i = last.changes.firstIndex(where: { $0.name == r.name }) { last.changes[i] = TuneChange(name: r.name, old: last.changes[i].old, new: r.new) }
                else { last.changes.append(r) }
            }
            last.changes.removeAll { abs($0.old - $0.new) < 1e-9 }
            last.date = Date()
            history[history.count - 1] = last
            if last.changes.isEmpty { history.removeLast() }
        } else {
            let e = TuneEntry(date: Date(), label: label, changes: recs)
            history.append(e); lastApplied = e.id
        }
        save()
    }

    func revert(_ ps: ParamStore, _ e: TuneEntry) {
        var m: [String: Double] = [:]
        for c in e.changes { m[c.name] = c.old }
        apply(ps, m, label: loc("Відкат: ") + e.label)
    }

    func addSnapshot(_ ps: ParamStore, name: String, names: [String]) {
        var v: [String: Double] = [:]
        for n in names { if let x = ps.val(n) { v[n] = x } }
        snapshots.insert(TuneSnapshot(name: name, date: Date(), values: v), at: 0)
        save()
    }
    func deleteSnapshot(_ id: UUID) { snapshots.removeAll { $0.id == id }; save() }
    func deleteEntry(_ id: UUID) { history.removeAll { $0.id == id }; save() }
}

// MARK: - Пресети

struct TunePreset: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let icon: String
    let values: (ParamStore, TuneModel) -> [String: Double]
}

enum TunePresets {
    static func clamp(_ ps: ParamStore, _ name: String, _ v: Double) -> Double {
        var x = v
        if let m = ps.meta[name] {
            if let lo = m.min { x = max(lo, x) }
            if let hi = m.max { x = min(hi, x) }
            if let inc = m.inc, inc > 0 { x = (x / inc).rounded() * inc }
        }
        return (x * 100000).rounded() / 100000
    }

    /// Множить значення вказаних параметрів на коефіцієнт.
    static func scale(_ ps: ParamStore, _ names: [String], _ k: Double) -> [String: Double] {
        var out: [String: Double] = [:]
        for n in names { if let v = ps.val(n), v != 0 { out[n] = clamp(ps, n, v * k) } }
        return out
    }

    static func presets(for m: TuneModel) -> [TunePreset] {
        var list: [TunePreset] = []
        switch m.kind {
        case .copter, .quadplane:
            for (size, title, sub, icon) in [(5.0, "Квадрокоптер 5″", "Малий швидкий апарат", "airplane.circle"), (7.0, "Дальній політ 7″", "Економний, плавний", "airplane.circle.fill"),
                                              (10.0, "Мультикоптер 10″", "Середній, вантажі, зйомка", "square.grid.3x3"), (15.0, "Великий мультикоптер 15″+", "Повільні й важкі платформи", "square.grid.3x3.fill")] {
                list.append(TunePreset(id: "size\(Int(size))", title: title, subtitle: sub, icon: icon) { ps, model in
                    // Формули з майстра початкових параметрів Mission Planner (фільтри, прискорення, крива тяги)
                    let accelY = max(8000, InitialParamsView.roundTo(-900 * size + 36000, -2))
                    let accelP = max(10000, InitialParamsView.roundTo(-2.613267 * pow(size, 3) + 343.39216 * pow(size, 2) - 15083.7121 * size + 235771, -2))
                    let gyro = max(20, (289.22 * pow(size, -0.838)).rounded())
                    let fltd = max(10, gyro / 2)
                    var v: [String: Double] = ["INS_GYRO_FILTER": gyro, "INS_ACCEL_FILTER": 10, "MOT_THST_EXPO": min((100 * (0.15686 * log(size) + 0.23693)).rounded() / 100, 0.8)]
                    for a in model.axes {
                        let g = a.id == "RLL" ? "R" : (a.id == "PIT" ? "P" : "Y")
                        v["ATC_ACCEL_\(g)_MAX"] = a.id == "YAW" ? accelY : accelP
                        if a.id != "YAW" { v["ATC_RAT_\(a.id)_FLTD"] = fltd; v["ATC_RAT_\(a.id)_FLTT"] = fltd; v["ATC_RAT_\(a.id)_FLTE"] = 0 }
                        else { v["ATC_RAT_YAW_FLTD"] = 0; v["ATC_RAT_YAW_FLTE"] = 2; v["ATC_RAT_YAW_FLTT"] = fltd }
                    }
                    return v.filter { ps.has($0.key) }.mapValues { $0 }.reduce(into: [:]) { $0[$1.key] = clamp(ps, $1.key, $1.value) }
                })
            }
            let rateNames: (TuneModel) -> [String] = { mm in mm.axes.flatMap { $0.rate }.filter { ["_P", "_I", "_D"].contains(where: $0.hasSuffix) && !$0.hasSuffix("_IMAX") } }
            list.append(TunePreset(id: "smooth", title: String(localized: "Плавний (кінозйомка)"), subtitle: String(localized: "М'якші PID, повільніша реакція на стіки"), icon: "film") { ps, mm in
                var v = scale(ps, rateNames(mm) + mm.axes.flatMap { $0.rate }.filter { $0.hasSuffix("_FF") }, 0.8)
                if let tc = ps.val("ATC_INPUT_TC") { v["ATC_INPUT_TC"] = clamp(ps, "ATC_INPUT_TC", tc * 1.5) }
                return v
            })
            list.append(TunePreset(id: "sport", title: String(localized: "Жвавий (спорт)"), subtitle: String(localized: "Різкіший відгук, більше FF"), icon: "bolt") { ps, mm in
                var v = scale(ps, rateNames(mm), 1.15)
                v.merge(scale(ps, mm.axes.flatMap { $0.rate }.filter { $0.hasSuffix("_FF") }, 1.25)) { $1 }
                if let tc = ps.val("ATC_INPUT_TC") { v["ATC_INPUT_TC"] = clamp(ps, "ATC_INPUT_TC", tc * 0.7) }
                return v
            })
        case .plane, .planeLegacy:
            list.append(TunePreset(id: "pstable", title: String(localized: "Стабільний (тренувальний)"), subtitle: String(localized: "Повільніший, спокійний відгук"), icon: "airplane.arrival") { ps, mm in
                var v = scale(ps, mm.axes.flatMap { $0.rate }.filter { ["_P", "_I", "_D", "_FF"].contains(where: $0.hasSuffix) }, 0.85)
                v.merge(scale(ps, mm.axes.flatMap { $0.outer }.filter { $0.hasSuffix("TCONST") }, 1.25)) { $1 }
                return v
            })
            list.append(TunePreset(id: "psport", title: String(localized: "Жвавий (спортивний)"), subtitle: String(localized: "Швидший відгук і кутова чутливість"), icon: "airplane.departure") { ps, mm in
                var v = scale(ps, mm.axes.flatMap { $0.rate }.filter { ["_P", "_I", "_D", "_FF"].contains(where: $0.hasSuffix) }, 1.15)
                v.merge(scale(ps, mm.axes.flatMap { $0.outer }.filter { $0.hasSuffix("TCONST") }, 0.8)) { $1 }
                return v
            })
        }
        list.append(TunePreset(id: "baseline", title: String(localized: "Початкові значення"), subtitle: String(localized: "Як було на момент відкриття цієї сторінки"), icon: "arrow.uturn.backward.circle") { _, _ in [:] })
        return list
    }
}

// MARK: - Перевірка конфігурації (поради)

struct TuneAdvice: Identifiable {
    enum Level { case ok, info, warn }
    let id = UUID(); let level: Level; let title: String; let detail: String
    var icon: String { switch level { case .ok: "checkmark.circle.fill"; case .info: "lightbulb.fill"; case .warn: "exclamationmark.triangle.fill" } }
    var color: Color { switch level { case .ok: .green; case .info: .secondary; case .warn: .orange } }
}

enum TuneLint {
    static func run(_ ps: ParamStore, _ m: TuneModel, vibe: Double) -> [TuneAdvice] {
        var out: [TuneAdvice] = []
        func v(_ n: String) -> Double? { ps.val(n) }
        let gyro = v("INS_GYRO_FILTER")
        let pre: String = m.kind == .copter ? "ATC_RAT_" : "Q_A_RAT_"
        // Фільтри швидкісного контролера
        if m.kind == .copter || m.kind == .quadplane, let gyro {
            for a in ["RLL", "PIT"] {
                if let fd = v("\(pre)\(a)_FLTD"), fd > gyro {
                    out.append(TuneAdvice(level: .warn, title: String(localized: "Фільтр D (\(a)) вищий за фільтр гіроскопа"), detail: String(localized: "FLTD \(fmt(fd, isInt: false)) Гц > INS_GYRO_FILTER \(fmt(gyro, isInt: false)) Гц. Орієнтир: FLTD ≈ половина фільтра гіроскопа (не менше 10).")))
                }
            }
        }
        if let g = gyro, let a = v("INS_ACCEL_FILTER"), a > g {
            out.append(TuneAdvice(level: .warn, title: String(localized: "Фільтр акселерометра вищий за фільтр гіроскопа"), detail: String(localized: "INS_ACCEL_FILTER \(fmt(a, isInt: false)) Гц > INS_GYRO_FILTER \(fmt(g, isInt: false)) Гц. Зазвичай акселерометр фільтрують сильніше.")))
        }
        // I відносно P для крену й тангажа
        for a in m.axes where a.id != "YAW" {
            let pn = a.rate.first { $0.hasSuffix("_P") || $0.hasSuffix("2SRV_P") }, inn = a.rate.first { $0.hasSuffix("_I") || $0.hasSuffix("2SRV_I") }
            if let pn, let inn, let p = v(pn), let i = v(inn), p > 0 {
                let r = i / p
                if r < 0.4 || r > 2.5 { out.append(TuneAdvice(level: .info, title: String(localized: "\(loc(a.title)): I і P сильно відрізняються"), detail: String(localized: "I/P = \(String(format: "%.2f", r)). Для крену й тангажа I зазвичай близький до P (орієнтовно 0.5–2×)."))) }
            }
        }
        // Рискання: D
        if m.kind == .copter, let d = v("ATC_RAT_YAW_D"), d > 0 {
            out.append(TuneAdvice(level: .info, title: String(localized: "Рискання: D не нульовий"), detail: String(localized: "Для рискання D зазвичай 0, а фільтр помилки FLTE близько 2 Гц.")))
        }
        // Режекторний фільтр
        if vibe > 30, let en = v("INS_HNTCH_ENABLE"), en == 0 {
            out.append(TuneAdvice(level: .warn, title: String(localized: "Висока вібрація без режекторного фільтра"), detail: String(localized: "Вібрація \(String(format: "%.0f", vibe)) м/с² (норма < 30). Покращте кріплення плати або ввімкніть гармонічний режекторний фільтр.")))
        } else if vibe > 30 {
            out.append(TuneAdvice(level: .warn, title: String(localized: "Висока вібрація"), detail: String(localized: "Вібрація \(String(format: "%.0f", vibe)) м/с². Перевірте баланс пропелерів і кріплення, потім налаштовуйте PID.")))
        }
        // Літаки: постійні часу
        if m.kind == .plane || m.kind == .planeLegacy {
            for n in ["RLL2SRV_TCONST", "PTCH2SRV_TCONST"] {
                if let t = v(n), t < 0.3 || t > 1.0 { out.append(TuneAdvice(level: .info, title: String(localized: "\(n) поза типовим діапазоном"), detail: String(localized: "Значення \(fmt(t, isInt: false)) с. Типово 0.4–0.8 с."))) }
            }
        }
        if out.isEmpty { out.append(TuneAdvice(level: .ok, title: String(localized: "Зауважень немає"), detail: String(localized: "Явних проблем у фільтрах і співвідношеннях параметрів не знайдено. Це не замінює пробний політ."))) }
        return out
    }
}
