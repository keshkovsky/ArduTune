import SwiftUI
import AppKit

// MARK: - Довідник: що містить tlog

enum TlogKnowledge {
    static let desc: [String: (String, String)] = [
        "HEARTBEAT": ("Пульс і стан", "Раз на секунду: тип апарата, режим польоту, ARMED/DISARMED. За ним видно перемикання режимів."),
        "SYS_STATUS": ("Система", "Напруга й струм батареї, залишок заряду, навантаження процесора, які датчики є й працюють."),
        "ATTITUDE": ("Орієнтація", "Крен, тангаж, рискання (у градусах) і кутові швидкості. Основа для графіка «як літав»."),
        "GLOBAL_POSITION_INT": ("Позиція", "Широта, довгота, висота над морем і над Home, швидкості за осями, курс."),
        "GPS_RAW_INT": ("GPS (сирі)", "Тип фіксації, кількість супутників, HDOP/VDOP, швидкість. Показує якість GPS."),
        "GPS": ("GPS (трек)", "Похідний запис із GPS_RAW_INT для карти: фіксація, координати, висота, швидкість."),
        "VFR_HUD": ("Дані для HUD", "Повітряна й шляхова швидкість, висота, швидкість набору, курс, газ."),
        "AHRS": ("Оцінка AHRS", "Внутрішня оцінка орієнтації (діагностична)."),
        "BATTERY_STATUS": ("Батарея", "Спожита ємність, температура, напруги комірок (до 8) по кожній батареї."),
        "POWER_STATUS": ("Живлення плати", "Напруга 5 В (Vcc) і сервошини; флаги проблем живлення."),
        "MEMINFO": ("Пам'ять", "Вільна пам'ять польотника (діагностика)."),
        "MCU_STATUS": ("Процесор", "Температура й напруга МК."),
        "MISSION_CURRENT": ("Місія", "Номер поточної точки місії та її стан."),
        "SERVO_OUTPUT_RAW": ("Виходи серво/моторів", "Значення PWM на виходах (1000–2000 мкс): видно, що польотник подає на мотори."),
        "RC_CHANNELS": ("Канали пульта", "Сирі значення каналів приймача, рівень сигналу RSSI."),
        "RAW_IMU": ("Сирий IMU", "Акселерометр, гіроскоп, магнітометр у сирому вигляді (низька частота: для вібрацій не годиться)."),
        "SCALED_IMU2": ("IMU 2", "Дані другого IMU."),
        "SCALED_IMU3": ("IMU 3", "Дані третього IMU."),
        "SCALED_PRESSURE": ("Барометр", "Тиск і температура барометра."),
        "SYSTEM_TIME": ("Час системи", "Час UNIX і час від старту польотника."),
        "WIND": ("Вітер", "Оцінка напрямку й швидкості вітру."),
        "TERRAIN_REPORT": ("Рельєф", "Висота рельєфу під апаратом (якщо є дані терену)."),
        "RPM": ("Оберти", "Датчики обертів (якщо підключені)."),
        "AOA_SSA": ("Кути атаки й ковзання", "Оцінки кута атаки та ковзання (літак)."),
        "AIRSPEED": ("Датчик швидкості", "Повітряна швидкість, диф. тиск, температура."),
        "VIBRATION": ("Вібрація", "Рівні вібрації X/Y/Z та лічильники кліппінгу акселерометрів. Понад 30 м/с² це погано."),
        "COMMAND_ACK": ("Відповіді на команди", "Результат команд, надісланих польотнику (ARM, зміна режиму, калібрування)."),
        "STATUSTEXT": ("Текстові повідомлення", "Журнал попереджень і подій польотника. Текст видно у вкладці «Повідомлення»."),
        "MSG": ("Повідомлення", "Текст із STATUSTEXT і зміни режиму/ARM у зручному вигляді."),
        "PARAM_VALUE": ("Параметри", "Значення параметрів, отримані при завантаженні."),
        "PARM": ("Параметри (список)", "Те саме у вигляді списку для вкладки «Параметри»."),
        "TIMESYNC": ("Синхронізація часу", "Службове: вирівнювання годинників."),
        "EKF_STATUS_REPORT": ("Стан EKF", "Дисперсії фільтра навігації: швидкості, позиції, компаса. Високі значення це проблема."),
        "NAV_CONTROLLER_OUTPUT": ("Навігація", "Бажані крен/тангаж/курс, відхилення від траєкторії."),
        "HOME_POSITION": ("Home", "Координати точки Home."),
        "RANGEFINDER": ("Далекомір", "Відстань до землі."),
        "DISTANCE_SENSOR": ("Датчик відстані", "Лідар/сонар."),
        "OPTICAL_FLOW": ("Оптичний потік", "Сенсор оптичного потоку."),
        "LOCAL_POSITION_NED": ("Локальна позиція", "Позиція й швидкість у локальній системі North-East-Down."),
        "ESC_TELEMETRY_1_TO_4": ("Телеметрія ESC", "Обертання, струм, температура регуляторів (якщо ESC передає)."),
        "RADIO_STATUS": ("Радіомодем", "Якість радіоканалу телеметрії."),
        "AUTOPILOT_VERSION": ("Версія прошивки", "Версія й можливості польотника."),
        "EXTENDED_SYS_STATE": ("Розширений стан", "Стан VTOL і посадки."),
        "FENCE_STATUS": ("Геозона", "Порушення геозони."),
        "VISION_POSITION_ESTIMATE": ("Візуальна одометрія", "Позиція від зовнішньої системи (камера/T265)."),
        "ODOMETRY": ("Одометрія", "Оцінка руху від зовнішньої системи."),
    ]
    static func info(_ name: String) -> (String, String) {
        desc[name] ?? (name.replacingOccurrences(of: "_", with: " ").capitalized, "Службове повідомлення MAVLink. Усі його числові поля доступні у вкладці «Графіки».")
    }
    /// Швидкі набори для графіків: (назва, іконка, ключі).
    static let presets: [(String, String, [String])] = [
        ("Висота й швидкість", "arrow.up.right", ["GLOBAL_POSITION_INT.relative_alt", "VFR_HUD.groundspeed"]),
        ("Кути (крен/тангаж)", "airplane", ["ATTITUDE.roll", "ATTITUDE.pitch"]),
        ("Батарея", "battery.75", ["SYS_STATUS.voltage_battery", "SYS_STATUS.current_battery"]),
        ("GPS", "location.fill", ["GPS_RAW_INT.satellites_visible", "GPS_RAW_INT.eph"]),
        ("Вібрація", "waveform", ["VIBRATION.vibration_x", "VIBRATION.vibration_y", "VIBRATION.vibration_z"]),
        ("Канали пульта", "dot.radiowaves.left.and.right", ["RC_CHANNELS.chan1_raw", "RC_CHANNELS.chan2_raw", "RC_CHANNELS.chan3_raw", "RC_CHANNELS.chan4_raw"]),
    ]
}

// MARK: - Модель

@Observable @MainActor
final class TlogViewModel {
    struct Summary {
        var duration = 0.0, armed = 0.0, maxAlt = 0.0, maxSpeed = 0.0, distance = 0.0
        var minV: Double?, maxA: Double?, maxSats = 0.0, bestFix = 0.0, maxVib = 0.0
        var warnings = 0, vehicle = "", types = 0, messages = 0
        var hints: [(String, String)] = []         // (іконка, текст)
    }
    var log: DFLog?
    var summary = Summary()
    var loading = true
    var error: String?
    var rows: [(name: String, count: Int, hz: Double)] = []

    func load(_ path: String) async {
        loading = true; error = nil
        var c = URLComponents(string: EngineAPI.base + "/tlog/convert")!
        c.queryItems = [.init(name: "path", value: path)]
        do {
            let (d, resp) = try await URLSession.shared.data(for: EngineAPI.request(c.url!))
            guard (resp as? HTTPURLResponse)?.statusCode == 200, let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let bin = j["path"] as? String else {
                error = String(localized: "Не вдалося перетворити запис (двигун відповів помилкою). Файл порожній чи пошкоджений?"); loading = false; return
            }
            let r = await Task.detached(priority: .userInitiated) { () -> (DFLog, Summary, [(String, Int, Double)])? in
                guard let l = DFLog(url: URL(fileURLWithPath: bin)) else { return nil }
                _ = l.messages; _ = l.parameters
                return (l, Self.summarize(l), Self.table(l))
            }.value
            if let (l, s, t) = r { log = l; summary = s; rows = t.map { (name: $0.0, count: $0.1, hz: $0.2) } } else { error = String(localized: "Запис не містить жодного повідомлення.") }
        } catch let e { self.error = String(localized: "Двигун недоступний: \(e.localizedDescription)") }
        loading = false
    }

    nonisolated static func table(_ l: DFLog) -> [(String, Int, Double)] {
        let dur = max(l.duration, 1)
        return l.order.map { ($0, l.count($0), Double(l.count($0)) / dur) }.sorted { $0.1 > $1.1 }
    }

    nonisolated static func summarize(_ l: DFLog) -> Summary {
        var s = Summary()
        s.duration = l.duration; s.types = l.order.count; s.messages = l.messageCount
        s.vehicle = l.vehicleName
        func vals(_ m: String, _ f: String) -> [Double] { l.series(m, f).map(\.v) }
        s.maxAlt = vals("GLOBAL_POSITION_INT", "relative_alt").max() ?? 0
        s.maxSpeed = vals("VFR_HUD", "groundspeed").max() ?? 0
        let v = vals("SYS_STATUS", "voltage_battery").filter { $0 > 1 }
        s.minV = v.min()
        s.maxA = vals("SYS_STATUS", "current_battery").max()
        s.maxSats = vals("GPS_RAW_INT", "satellites_visible").max() ?? 0
        s.bestFix = vals("GPS_RAW_INT", "fix_type").max() ?? 0
        s.maxVib = max(vals("VIBRATION", "vibration_x").max() ?? 0, vals("VIBRATION", "vibration_y").max() ?? 0, vals("VIBRATION", "vibration_z").max() ?? 0)
        s.warnings = vals("STATUSTEXT", "severity").filter { $0 <= 4 }.count
        // Час у ARMED
        var armedAt: Double?
        for m in l.messages where m.name == "MSG" {
            if m.text == "ARMED" { armedAt = m.time }
            else if m.text == "DISARMED", let a = armedAt { s.armed += m.time - a; armedAt = nil }
        }
        if let a = armedAt { s.armed += l.duration - a }
        let tr = l.track()
        if tr.count > 1 {
            for i in 1..<tr.count {
                let dy = (tr[i].lat - tr[i - 1].lat) * 111_320, dx = (tr[i].lon - tr[i - 1].lon) * 111_320 * cos(tr[i].lat * .pi / 180)
                let d = hypot(dx, dy); if d < 500 { s.distance += d }
            }
        }
        // Висновки
        if s.bestFix >= 3 { s.hints.append(("checkmark.circle", String(format: loc("GPS мав 3D-фіксацію, до %.0f супутників."), s.maxSats))) }
        else if l.count("GPS_RAW_INT") > 0 { s.hints.append(("exclamationmark.triangle", "GPS не отримав 3D-фіксації за весь запис: карти й траєкторії не буде. Це нормально для стенду в приміщенні.")) }
        if s.armed < 1 { s.hints.append(("info.circle", "Апарат не був ARMED: запис зроблено на стенді або в налаштуваннях.")) }
        else { s.hints.append(("clock", String(format: loc("У ARMED був %d хв %d с."), Int(s.armed) / 60, Int(s.armed) % 60))) }
        if let mv = s.minV { s.hints.append((mv < 10 ? "battery.25" : "battery.75", String(format: loc("Мінімальна напруга батареї %.2f В%@."), mv, s.maxA.map { String(format: loc(", максимальний струм %.1f А"), $0) } ?? ""))) }
        if s.maxVib > 30 { s.hints.append(("waveform.badge.exclamationmark", String(format: loc("Вібрація досягала %.0f м/с²: це вище норми (30). Перевірте пропелери й кріплення; для точного аналізу потрібен Dataflash-лог."), s.maxVib))) }
        if s.warnings > 0 { s.hints.append(("exclamationmark.bubble", String(localized: "Польотник видав \(s.warnings) попереджень або помилок: відкрийте вкладку «Повідомлення»."))) }
        return s
    }
}

// MARK: - Вікно

struct TlogWindow: View {
    let path: String
    @State private var m = TlogViewModel()
    @State private var tab = "Що записано"
    @State private var request: GraphRequest?
    static let tabs = ["Що записано", "Графіки", "Карта", "Повідомлення", "Параметри"]
    var name: String { (path as NSString).lastPathComponent }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "waveform.path.ecg").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(LocalizedStringKey(name)).font(.headline).lineLimit(1).truncationMode(.middle)
                    Text(lk(m.loading ? "Розбір запису…" : String(localized: "Локальний запис MAVLink · \(Int(m.summary.duration) / 60) хв \(Int(m.summary.duration) % 60) с · \(m.summary.messages) повідомлень"))).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) } label: { Label("Показати у Finder", systemImage: "folder") }.controlSize(.small)
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 8)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Self.tabs, id: \.self) { t in
                        Button { tab = t } label: {
                            Text(LocalizedStringKey(t)).font(.callout.weight(tab == t ? .semibold : .regular)).padding(.horizontal, 12).padding(.vertical, 5)
                                .background(tab == t ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06), in: Capsule())
                        }.buttonStyle(.plain)
                    }
                }.padding(.horizontal, 14)
            }
            .padding(.bottom, 8)
            Divider()
            if m.loading { VStack { Spacer(); ProgressView("Перетворення й розбір…"); Spacer() }.frame(maxWidth: .infinity) }
            else if let e = m.error { ContentUnavailableView("Не вдалося відкрити запис", systemImage: "exclamationmark.triangle", description: Text(LocalizedStringKey(e))) }
            else if let log = m.log {
                Group {
                    switch tab {
                    case "Графіки": LogGraphView(log: log, request: $request)
                    case "Карта": LogMapView(log: log)
                    case "Повідомлення": LogMessagesView(log: log)
                    case "Параметри": LogParamsView(log: log)
                    default: TlogOverview(m: m, openGraph: { request = $0; tab = "Графіки" }, openTab: { tab = $0 })
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 820, minHeight: 560)
        .navigationTitle("Запис: " + name)
        .task(id: path) { await m.load(path) }
    }
}

// MARK: - Огляд: що записано і як це читати

struct TlogOverview: View {
    let m: TlogViewModel
    var openGraph: (GraphRequest) -> Void
    var openTab: (String) -> Void
    @State private var showAll = false

    var body: some View {
        let s = m.summary
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Card(title: String(localized: "Що це за запис"), icon: "questionmark.circle", text: nil) {
                    Text("ArduTune записує все, що польотник надсилає по MAVLink у реальному часі: положення, GPS, батарею, режими, канали пульта і текстові повідомлення. Частота невелика, зазвичай 1–10 разів на секунду.")
                    Text("Це не те саме, що лог на SD-картці польотника (Dataflash). Там пишуться тисячі значень на секунду: PID, вібрація, сирі дані гіроскопа. Тому запис підходить, щоб подивитись, як пройшов політ, а для тонкого налаштування PID чи фільтрів потрібен Dataflash-лог.")
                        .foregroundStyle(.secondary)
                }
                Card(title: String(localized: "Підсумок"), icon: "list.bullet.clipboard", text: nil) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
                        Tile("Тривалість", String(format: loc("%d хв %d с"), Int(s.duration) / 60, Int(s.duration) % 60))
                        Tile("У ARMED", String(format: loc("%d хв %d с"), Int(s.armed) / 60, Int(s.armed) % 60))
                        Tile("Макс. висота", String(format: loc("%.0f м"), s.maxAlt))
                        Tile("Макс. швидкість", String(format: loc("%.0f м/с"), s.maxSpeed))
                        Tile("Пройдено", s.distance > 0 ? String(format: loc("%.0f м"), s.distance) : "—")
                        Tile("Мін. напруга", s.minV.map { String(format: loc("%.2f В"), $0) } ?? "—")
                        Tile("Супутників", s.maxSats > 0 ? String(format: "%.0f", s.maxSats) : "—")
                        Tile("Попереджень", "\(s.warnings)")
                    }
                    ForEach(Array(s.hints.enumerated()), id: \.offset) { _, h in
                        Label(LocalizedStringKey(h.1), systemImage: h.0).font(.callout)
                    }
                    if s.vehicle != "ArduPilot" { Text(LocalizedStringKey(s.vehicle)).font(.caption).foregroundStyle(.secondary) }
                }
                Card(title: String(localized: "Як аналізувати"), icon: "lightbulb", text: nil) {
                    VStack(alignment: .leading, spacing: 6) {
                        step("1", "Почніть з повідомлень", "У вкладці «Повідомлення» читайте тексти польотника, перемикання режимів і ARM/DISARM. Помилки й попередження пояснюють більшість проблем.")
                        step("2", "Подивіться графіки", "Оберіть швидкий набір нижче, а далі додайте будь-які поля у вкладці «Графіки». Курсор на графіку показує значення в одну мить.")
                        step("3", "Звіряйте час", "Знайдіть момент події в повідомленнях і подивіться, що в цей час робили висота, кути, напруга.")
                        step("4", "Перевірте параметри", "У вкладці «Параметри» видно значення, які були на польотнику під час запису.")
                    }
                    FlowRow(spacing: 8) {
                        ForEach(TlogKnowledge.presets, id: \.0) { p in
                            Button { openGraph(GraphRequest(keys: p.2, from: 0, to: max(1, s.duration))) } label: { Label(LocalizedStringKey(p.0), systemImage: p.1) }.controlSize(.small)
                        }
                    }
                }
                Card(title: String(localized: "Які повідомлення записано"), icon: "tablecells", text: String(localized: "Кожен тип містить поля, які можна вивести на графік. Це повний перелік того, що надсилав польотник.")) {
                    let rows = showAll ? m.rows : Array(m.rows.prefix(14))
                    VStack(spacing: 0) {
                        ForEach(rows, id: \.name) { r in
                            let i = TlogKnowledge.info(r.name)
                            HStack(alignment: .top, spacing: 10) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(LocalizedStringKey(i.0)).font(.callout.weight(.medium))
                                    Text(LocalizedStringKey(r.name)).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                                }.frame(width: 190, alignment: .leading)
                                Text(LocalizedStringKey(i.1)).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                                VStack(alignment: .trailing, spacing: 1) {
                                    Text("\(r.count)").font(.caption.monospacedDigit())
                                    Text(String(format: loc("%.1f Гц"), r.hz)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                                }.frame(width: 64, alignment: .trailing)
                            }
                            .padding(.vertical, 5)
                            Divider()
                        }
                    }
                    if m.rows.count > 14 { Button(lk(showAll ? "Згорнути" : String(localized: "Показати всі \(m.rows.count)"))) { showAll.toggle() }.controlSize(.small) }
                }
            }
            .padding(14)
        }
    }

    func step(_ n: String, _ t: String, _ d: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(LocalizedStringKey(n)).font(.caption.weight(.bold)).frame(width: 20, height: 20).background(Color.accentColor.opacity(0.2), in: Circle())
            VStack(alignment: .leading, spacing: 1) { Text(LocalizedStringKey(t)).font(.callout.weight(.semibold)); Text(LocalizedStringKey(d)).font(.callout).foregroundStyle(.secondary) }
        }
    }
}

/// Рядки з переносом: прості кнопки в потоці.
struct FlowRow<Content: View>: View {
    var spacing: CGFloat = 8
    @ViewBuilder var content: Content
    var body: some View { WrapLayout(spacing: spacing) { content } }
}

struct WrapLayout: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? 600
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > w, x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            x += sz.width + spacing; rowH = max(rowH, sz.height)
        }
        return CGSize(width: w, height: y + rowH)
    }
    func placeSubviews(in b: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = b.minX, y = b.minY, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > b.maxX, x > b.minX { x = b.minX; y += rowH + spacing; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += sz.width + spacing; rowH = max(rowH, sz.height)
        }
    }
}
