import SwiftUI

// MARK: - Довідники елементів OSD

enum OSDInfo {
    /// Назва та приклад вмісту елемента (для макета на екрані).
    static let items: [String: (title: String, sample: String, group: String)] = [
        "ALTITUDE": ("Висота", "▲120m", "Навігація"), "HOME": ("Напрям і відстань до дому", "H◥ 350m", "Навігація"), "HOMEDIST": ("Відстань до дому", "350m", "Навігація"),
        "HOMEDIR": ("Стрілка до дому", "↗", "Навігація"), "DIST": ("Пройдена відстань", "4.2km", "Навігація"), "HEADING": ("Курс", "120°", "Навігація"),
        "COMPASS": ("Компасна стрічка", "─E──┼──S─", "Навігація"), "GPSLAT": ("Широта GPS", "50.45010", "Навігація"), "GPSLONG": ("Довгота GPS", "30.52340", "Навігація"),
        "SATS": ("Супутники", "14", "Навігація"), "HDOP": ("HDOP", "HDOP0.9", "Навігація"), "WAYPOINT": ("Точка маршруту", "WP3 120m", "Навігація"),
        "XTRACK": ("Відхилення від маршруту", "XT 4m", "Навігація"), "PLUSCODE": ("Plus Code", "8GWR+PF4", "Навігація"), "TER_HGT": ("Висота над рельєфом", "TER 85m", "Навігація"),
        "RNGF": ("Далекомір", "RNG 3.4m", "Навігація"),
        "BAT_VOLT": ("Напруга батареї", "15.1V", "Батарея"), "BAT2_VLT": ("Напруга батареї 2", "15.0V", "Батарея"), "CURRENT": ("Струм", "12.3A", "Батарея"), "CURRENT2": ("Струм батареї 2", "11.8A", "Батарея"),
        "BATUSED": ("Витрачено, мА·год", "850mAh", "Батарея"), "BAT2USED": ("Витрачено (батарея 2)", "790mAh", "Батарея"), "AVGCELLV": ("Середня напруга комірки", "3.78V", "Батарея"),
        "CELLVOLT": ("Напруга комірки", "3.76V", "Батарея"), "RESTVOLT": ("Напруга без навантаження", "15.8V", "Батарея"), "ACRVOLT": ("Напруга з поправкою на просідання", "3.80V", "Батарея"),
        "BATTBAR": ("Шкала батареї", "▮▮▮▮▯", "Батарея"), "POWER": ("Потужність", "186W", "Батарея"), "EFF": ("Ефективність", "7mAh/km", "Батарея"), "CLIMBEFF": ("Ефективність набору", "CE 2.1", "Батарея"),
        "FLTMODE": ("Режим польоту", "FBWA", "Політ"), "ARMING": ("Статус ARM", "ARMED", "Політ"), "HORIZON": ("Штучний горизонт", "──────◦──────", "Політ"), "CRSSHAIR": ("Приціл", "+", "Політ"),
        "ASPEED": ("Повітряна швидкість", "▸18m/s", "Політ"), "ASPD1": ("Повітряна швидкість (датчик 1)", "18m/s", "Політ"), "ASPD2": ("Повітряна швидкість (датчик 2)", "18m/s", "Політ"),
        "GSPEED": ("Наземна швидкість", "▸17m/s", "Політ"), "VSPEED": ("Вертикальна швидкість", "↑1.2m/s", "Політ"), "ROLL": ("Крен", "R 12°", "Політ"), "PITCH": ("Тангаж", "P 4°", "Політ"),
        "THROTTLE": ("Газ", "55%", "Політ"), "WIND": ("Вітер", "WND 6m/s", "Політ"), "SIDEBARS": ("Бічні шкали", "▏     ▕", "Політ"), "FENCE": ("Геозона", "FNC", "Політ"),
        "FLTIME": ("Час польоту", "⏱12:40", "Політ"), "CLK": ("Годинник", "14:25", "Політ"), "STATS": ("Статистика польоту", "STATS", "Політ"),
        "RSSI": ("Сила сигналу RSSI", "RSSI 92", "Зв'язок"), "LINK_Q": ("Якість лінку", "LQ 100", "Зв'язок"), "MESSAGE": ("Повідомлення автопілота", "Armed: ready to fly", "Зв'язок"),
        "CALLSIGN": ("Позивний", "UAV-01", "Зв'язок"), "VTX_PWR": ("Потужність VTX", "VTX 200mW", "Зв'язок"),
        "RC_PWR": ("Потужність передавача (ELRS/CRSF)", "100mW", "Зв'язок"), "RSSIDBM": ("RSSI, дБм", "-90DBM", "Зв'язок"), "RC_SNR": ("Співвідношення сигнал/шум", "SNR 12DB", "Зв'язок"),
        "RC_ANT": ("Активна антена приймача", "ANT1", "Зв'язок"), "RC_LQ": ("Якість лінку (CRSF)", "LQ 0:100", "Зв'язок"),
        "ESCAMPS": ("Струм ESC", "ESC 12A", "Двигуни"), "ESCRPM": ("Оберти ESC", "5400rpm", "Двигуни"), "ESCTEMP": ("Температура ESC", "ESC 52°", "Двигуни"), "RPM": ("Оберти", "5400rpm", "Двигуни"),
        "TEMP": ("Температура", "34°", "Температура"), "ATEMP": ("Температура повітря", "21°", "Температура"), "BTEMP": ("Температура баро", "30°", "Температура"),
    ]
    static let groupOrder = ["Політ", "Навігація", "Батарея", "Зв'язок", "Двигуни", "Температура", "Інше"]
    static func title(_ k: String) -> String { items[k]?.title ?? k.replacingOccurrences(of: "_", with: " ").capitalized }
    static func sample(_ k: String) -> String { items[k]?.sample ?? k }
    static func group(_ k: String) -> String { items[k]?.group ?? "Інше" }
}

struct OSDFormat: Identifiable, Hashable {
    let id: String; let name: String; let cols: Int; let rows: Int
    static let pal = OSDFormat(id: "pal", name: "Аналоговий PAL (30×16)", cols: 30, rows: 16)
    static let ntsc = OSDFormat(id: "ntsc", name: "Аналоговий NTSC (30×13)", cols: 30, rows: 13)
    static let hd50 = OSDFormat(id: "hd50", name: "Цифровий HD (50×18)", cols: 50, rows: 18)
    static let hd60 = OSDFormat(id: "hd60", name: "Цифровий HD (60×22)", cols: 60, rows: 22)
    static let all = [pal, ntsc, hd50, hd60]
}

// MARK: - Сторінка OSD

struct OSDView: View {
    @Environment(Store.self) var s
    @AppStorage("osd.analogStd") private var analogStd = "pal"
    @State private var screen = 1
    @State private var selected: String?
    @State private var search = ""
    @State private var overrides: [String: CGPoint] = [:]
    @State private var showNames = false
    @State private var editorW: CGFloat = 1100
    @State private var compact = false
    @State private var layoutOverride: String?            // nil: сітка за типом OSD; інакше pal/ntsc/hd50/hd60
    @State private var clipboard: [String: [Double]]?     // скопійований макет екрана: ключ → [EN, X, Y]
    @State private var snapshot: [String: Double] = [:]   // значення OSD-параметрів при відкритті сторінки (для «Скасувати зміни»)
    var ps: ParamStore { s.ps }

    var osdType: Int { Int(ps.val("OSD_TYPE") ?? 0) }
    var screens: [Int] { (1...6).filter { ps.has("OSD\($0)_ENABLE") } }
    func sp(_ n: Int) -> String { "OSD\(n)" }
    /// Елементи екрана: ключ без префікса й суфікса.
    func itemKeys(_ n: Int) -> [String] {
        let pre = sp(n) + "_"
        return ps.params.map(\.name).filter { $0.hasPrefix(pre) && $0.hasSuffix("_EN") }.map { String($0.dropFirst(pre.count).dropLast(3)) }.sorted()
    }

    /// Поточна сітка залежить від типу OSD і обраного формату.
    var format: OSDFormat {
        if let o = layoutOverride, let f = OSDFormat.all.first(where: { $0.id == o }) { return f }
        if osdType == 5 || osdType == 3 {
            switch Int(ps.val("OSD1_TXT_RES") ?? 0) { case 1: return .hd50; case 2: return .hd60; default: return .pal }
        }
        return analogStd == "ntsc" ? .ntsc : .pal
    }

    var body: some View {
        ConfigGate {
            if !ps.has("OSD_TYPE") {
                ContentUnavailableView("OSD недоступне", systemImage: "display", description: Text("Параметра OSD_TYPE немає в цій прошивці (OSD не скомпільовано або не підтримується)."))
            } else {
                PageTitle(title: String(localized: "Основні налаштування"), subtitle: String(localized: "Оберіть тип екранного меню, розташуйте елементи й налаштуйте одиниці та вигляд."))
                StepTitle(n: 1, title: String(localized: "Тип OSD і формат відео"))
                typeCard
                StepTitle(n: 2, title: String(localized: "Екран і розташування елементів"))
                editorCard
                StepTitle(n: 3, title: String(localized: "Одиниці й вигляд"))
                ParamsCard(title: String(localized: "Вигляд"), icon: "textformat.size", text: String(localized: "Одиниці виміру, шрифт, швидкість зникнення повідомлень і зсув картинки."),
                           params: ["OSD_UNITS", "OSD_FONT", "OSD_MSG_TIME", "OSD_OPTIONS"])
                offsetCard

                AdvancedSection(key: "osd.advanced", subtitle: String(localized: "Перемикання екранів, пороги попереджень, екрани за станом, другий OSD та інші параметри.")) {
                    switchCard
                    ParamsCard(title: String(localized: "Попередження (червоне миготіння)"), icon: "exclamationmark.triangle", text: String(localized: "Значення, за яких елемент починає миготіти."),
                               params: ["OSD_W_RSSI", "OSD_W_NSAT", "OSD_W_BATVOLT", "OSD_W_AVGCELLV", "OSD_W_RESTVOLT", "OSD_W_ACRVOLT", "OSD_W_TERR", "OSD_W_SNR", "OSD_W_LQ", "OSD_W_DIST", "OSD_W_FLTIME", "OSD_W_MAXCURR"])
                    ParamsCard(title: String(localized: "Екрани за станом"), icon: "rectangle.stack", text: String(localized: "Який екран показувати при ARM, DISARM і failsafe. 0 = не перемикати."), params: ["OSD_ARM_SCR", "OSD_DSARM_SCR", "OSD_FS_SCR"])
                    ParamsCard(title: String(localized: "Батарея й бічні шкали"), icon: "battery.75", params: ["OSD_CELL_COUNT", "OSD_SB_H_OFS", "OSD_SB_V_EXT"])
                    ParamsCard(title: String(localized: "Другий OSD"), icon: "display.2", text: String(localized: "Другий вивід (наприклад, аналоговий і цифровий одночасно)."), params: ["OSD_TYPE2"])
                    screenParams
                    let known: Set<String> = ["OSD_TYPE", "OSD_TYPE2", "OSD_UNITS", "OSD_FONT", "OSD_MSG_TIME", "OSD_OPTIONS", "OSD_H_OFFSET", "OSD_V_OFFSET", "OSD_CHAN", "OSD_SW_METHOD", "OSD_BTN_DELAY",
                                              "OSD_ARM_SCR", "OSD_DSARM_SCR", "OSD_FS_SCR", "OSD_CELL_COUNT", "OSD_SB_H_OFS", "OSD_SB_V_EXT"]
                    ParamsCard(title: String(localized: "Інші параметри OSD"), icon: "ellipsis.circle", params: ps.params.map(\.name).filter { $0.hasPrefix("OSD_") && !known.contains($0) && !$0.hasPrefix("OSD_W_") }.sorted())
                }
                RebootRow(text: String(localized: "Тип OSD і порт підключення застосовуються після перезавантаження автопілота."))
            }
        }
    }

    // MARK: Крок 1: тип
    struct TypeChoice: Identifiable { let id: Int; let title: String; let subtitle: String; let icon: String }
    static let types: [TypeChoice] = [
        TypeChoice(id: 0, title: String(localized: "Вимкнено"), subtitle: String(localized: "Екранне меню не використовується"), icon: "nosign"),
        TypeChoice(id: 1, title: String(localized: "Аналоговий (MAX7456)"), subtitle: String(localized: "Мікросхема OSD на платі, аналогове відео PAL/NTSC"), icon: "tv"),
        TypeChoice(id: 3, title: "MSP (DJI FPV)", subtitle: String(localized: "Через послідовний порт: окуляри DJI FPV"), icon: "visionpro"),
        TypeChoice(id: 5, title: String(localized: "MSP DisplayPort (цифровий)"), subtitle: String(localized: "HDZero, Walksnail, DJI O3 та інші цифрові системи"), icon: "display"),
        TypeChoice(id: 4, title: String(localized: "Лише телеметрія TX"), subtitle: String(localized: "Без накладання на відео, дані передаються на пульт"), icon: "antenna.radiowaves.left.and.right"),
    ]

    var typeCard: some View {
        Card(title: String(localized: "Тип OSD"), icon: "display", text: String(localized: "Спосіб виведення екранного меню залежить від відеосистеми: аналогова камера з відеопередавачем чи цифрова (DisplayPort/MSP).")) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 210, maximum: 280), spacing: 10)], spacing: 10) {
                ForEach(Self.types) { t in
                    let on = osdType == t.id
                    Button { ps.write("OSD_TYPE", Double(t.id)); note = t.id == 0 ? nil : "Тип OSD записано. Для застосування перезавантажте автопілот." } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: t.icon).font(.system(size: 16, weight: .semibold)).frame(width: 26)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(LocalizedStringKey(t.title)).font(.callout.weight(.semibold))
                                Text(LocalizedStringKey(t.subtitle)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                            if on { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor) }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(on ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(on ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.08), lineWidth: on ? 1.5 : 1))
                    }.buttonStyle(.plain).disabled(s.armed)
                }
            }
            formatSection
            if let n = note { Label(LocalizedStringKey(n), systemImage: "info.circle.fill").font(.callout).foregroundStyle(.orange) }
        }
    }
    @State private var note: String?

    @ViewBuilder var formatSection: some View {
        switch osdType {
        case 1:
            Divider()
            HStack(spacing: 14) {
                Text("Відеостандарт для макета").font(.callout)
                Picker("", selection: $analogStd) { Text("PAL 30×16").tag("pal"); Text("NTSC 30×13").tag("ntsc") }.pickerStyle(.segmented).frame(width: 220).labelsHidden()
            }
            Text("Мікросхема MAX7456 сама визначає стандарт за камерою. Вибір впливає лише на розмір сітки в макеті нижче, щоб не розмістити елементи за межами екрана.").font(.caption).foregroundStyle(.secondary)
        case 3, 5:
            Divider()
            serialSetup
            if ps.has("OSD1_TXT_RES") {
                HStack(spacing: 12) { Text("Роздільність тексту").font(.callout); OptionPicker(name: "OSD1_TXT_RES", width: 160) }
                Text("Має збігатися з можливостями цифрової системи: 30×16 для DJI FPV, 50×18 для HDZero/Walksnail, 60×22 для окремих версій.").font(.caption).foregroundStyle(.secondary)
            }
        default: EmptyView()
        }
    }

    /// Порт, до якого підключено цифрову систему: записує потрібний протокол SERIALn.
    var serialSetup: some View {
        let ports = (1...8).filter { ps.has("SERIAL\($0)_PROTOCOL") }
        let proto = osdType == 5 ? 42 : 33
        let used = ports.first { Int(ps.val("SERIAL\($0)_PROTOCOL") ?? -1) == proto }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Text("Послідовний порт").font(.callout)
                Picker("", selection: Binding(get: { used ?? 0 }, set: { n in
                    for p in ports where Int(ps.val("SERIAL\(p)_PROTOCOL") ?? -1) == proto && p != n { ps.write("SERIAL\(p)_PROTOCOL", -1) }
                    if n > 0 { ps.write("SERIAL\(n)_PROTOCOL", Double(proto)); ps.write("SERIAL\(n)_BAUD", 115); note = String(localized: "Порт SERIAL\(n) налаштовано (\(osdType == 5 ? "DisplayPort" : "DJI FPV"), 115200). Перезавантажте автопілот.") }
                })) {
                    Text("не призначено").tag(0)
                    ForEach(ports, id: \.self) { n in Text("SERIAL\(n)" + (Int(ps.val("SERIAL\(n)_PROTOCOL") ?? -1) == proto ? "" : String(localized: "  (зараз: \(ps.options("SERIAL\(n)_PROTOCOL").first { $0.0 == Int(ps.val("SERIAL\(n)_PROTOCOL") ?? -1) }?.1 ?? "?"))"))).tag(n) }
                }.labelsHidden().frame(width: 320).disabled(s.armed)
            }
            Text(lk(osdType == 5 ? "Протокол порту: DisplayPort (42). Підключіть TX автопілота до RX відеосистеми і навпаки." : "Протокол порту: DJI FPV / MSP (33). Підключіть порт до повітряного блока DJI.")).font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Крок 2: редактор макета
    var wideLayout: Bool { osdType == 3 || osdType == 5 || format.cols > 30 }

    /// Відмінності від значень на момент відкриття сторінки.
    var changedSinceOpen: [(String, Double)] {
        snapshot.compactMap { n, v in
            guard let c = ps.val(n), abs(c - v) > 1e-9 else { return nil }
            return (n, v)
        }
    }
    func takeSnapshot() {
        guard snapshot.isEmpty else { return }
        let osd = ps.params.filter { $0.name.hasPrefix("OSD") }
        if !osd.isEmpty { snapshot = Dictionary(osd.map { ($0.name, $0.value) }, uniquingKeysWith: { a, _ in a }) }
    }

    var editorCard: some View {
        Card(title: String(localized: "Макет екрана"), icon: "rectangle.dashed", text: String(localized: "Перетягніть елемент мишею або вкажіть X/Y праворуч. Усі зміни записуються в польотник одразу; кнопка «Скасувати зміни» повертає значення на момент відкриття сторінки.")) {
            if screens.isEmpty { Text("Екрани OSD недоступні.").foregroundStyle(.secondary) }
            else {
                editorBar
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { editorW = $0 }
                let keys = itemKeys(screen)
                if keys.isEmpty {
                    Label("Для цього екрана в прошивці немає налаштовуваних елементів.", systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
                } else {
                    let grid = OSDGrid(screen: screen, format: format, wide: wideLayout, msp: osdType == 3, screenOn: (ps.val(sp(screen) + "_ENABLE") ?? 0) > 0, keys: keys,
                                       names: showNames, scale: compact ? 0.78 : 1, selected: $selected, overrides: $overrides)
                    let side = VStack(alignment: .leading, spacing: 12) { screenOptions; itemOptions(keys) }
                    // у вузькому вікні панель параметрів переходить під макет; AnyLayout зберігає ті самі екземпляри
                    // (інакше зміна вибору посеред перетягування перебудовувала б макет і переривала жест)
                    let sideBySide = editorW > 600 * (compact ? 0.78 : 1) + 16 + 270
                    let layout = sideBySide ? AnyLayout(HStackLayout(alignment: .top, spacing: 16)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
                    layout {
                        grid
                        side.frame(minWidth: 260, maxWidth: sideBySide ? 340 : .infinity)
                    }
                    elementGrid(keys)
                }
            }
        }
        .onAppear { if !screens.contains(screen) { screen = screens.first ?? 1 }; takeSnapshot() }
        .onChange(of: ps.params.count) { _, _ in takeSnapshot() }
    }

    /// Рядок керування: екрани, параметри перегляду, копіювання макета, очищення й скасування.
    var editorBar: some View {
        let changed = changedSinceOpen.count
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Picker("", selection: $screen) { ForEach(screens, id: \.self) { Text("Екран \($0)").tag($0) } }.pickerStyle(.segmented).labelsHidden().frame(width: CGFloat(screens.count) * 82)
                Toggle("Екран увімкнено", isOn: Binding(get: { (ps.val(sp(screen) + "_ENABLE") ?? 0) > 0 }, set: { ps.write(sp(screen) + "_ENABLE", $0 ? 1 : 0) })).toggleStyle(.switch).disabled(s.armed)
                Spacer()
                Text(LocalizedStringKey(format.name)).font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 14) {
                Toggle("Показувати назви", isOn: $showNames).toggleStyle(.checkbox).tip("Замість прикладу значення показувати назву елемента (як у Mission Planner)")
                Toggle("Зменшити", isOn: $compact).toggleStyle(.checkbox).tip("Менший перегляд макета")
                Menu {
                    Button("За типом OSD (авто)") { layoutOverride = nil }
                    Divider()
                    ForEach(OSDFormat.all) { f in Button(lk(f.name)) { layoutOverride = f.id } }
                } label: { Label(lk(loc("Сітка: ") + (layoutOverride == nil ? "авто" : format.name)), systemImage: "grid") }
                    .menuStyle(.borderlessButton).fixedSize().tip("Розмір сітки макета. Для цифрових систем: HD-макет 50×18 або 60×22")
                Spacer()
                Button { copyLayout() } label: { Label("Копіювати макет", systemImage: "doc.on.doc") }.controlSize(.small)
                Button { pasteLayout() } label: { Label("Вставити макет", systemImage: "doc.on.clipboard") }.controlSize(.small).disabled(clipboard == nil || s.armed)
                Button { clearAll() } label: { Label("Очистити все", systemImage: "eraser") }.controlSize(.small).disabled(s.armed)
                Button { discard() } label: { Label(lk(loc("Скасувати зміни") + (changed == 0 ? "" : " (\(changed))")), systemImage: "arrow.uturn.backward") }
                    .controlSize(.small).disabled(changed == 0 || s.armed)
            }
        }
    }

    func copyLayout() {
        var c: [String: [Double]] = [:]
        for k in itemKeys(screen) { let p = sp(screen) + "_" + k; c[k] = [ps.val(p + "_EN") ?? 0, ps.val(p + "_X") ?? 0, ps.val(p + "_Y") ?? 0] }
        clipboard = c
        note = String(localized: "Макет екрана \(screen) скопійовано (\(c.count) елементів): оберіть інший екран і натисніть «Вставити макет».")
    }
    func pasteLayout() {
        guard let c = clipboard else { return }
        var n = 0
        for k in itemKeys(screen) {
            guard let v = c[k] else { continue }
            let p = sp(screen) + "_" + k
            ps.write(p + "_EN", v[0]); ps.write(p + "_X", v[1]); ps.write(p + "_Y", v[2]); n += 1
        }
        overrides = [:]
        note = String(localized: "Макет вставлено на екран \(screen): \(n) елементів.")
    }
    func clearAll() {
        for k in itemKeys(screen) { ps.write(sp(screen) + "_" + k + "_EN", 0) }
        selected = nil
    }
    func discard() {
        let list = changedSinceOpen
        for (n, v) in list { ps.write(n, v) }
        overrides = [:]
        note = String(localized: "Повернено \(list.count) параметрів до значень на момент відкриття сторінки.")
    }

    /// Параметри вибраного екрана (як «Screen Options» у Mission Planner).
    var screenOptions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("ПАРАМЕТРИ ЕКРАНА \(screen)").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            VStack(spacing: 0) {
                ForEach(["ESC_IDX", "FONT", "TXT_RES", "CHAN_MIN", "CHAN_MAX"].map { sp(screen) + "_" + $0 }.filter { ps.has($0) }, id: \.self) { n in
                    AdvParamRow(name: n, describe: false); Divider().opacity(0.4)
                }
            }
        }
        .padding(10).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// Параметри вибраного елемента: вмикання й позиція.
    func itemOptions(_ keys: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ПАРАМЕТРИ ЕЛЕМЕНТА").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            if let k = selected, keys.contains(k) {
                let p = sp(screen) + "_" + k
                VStack(alignment: .leading, spacing: 2) {
                    Text(LocalizedStringKey(k)).font(.system(.callout, design: .monospaced).weight(.semibold))
                    Text(lk(OSDInfo.title(k))).font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Показувати на екрані", isOn: Binding(get: { (ps.val(p + "_EN") ?? 0) > 0 }, set: { toggleItem(k, $0) })).toggleStyle(.switch).disabled(s.armed)
                HStack(spacing: 10) {
                    Text("X").font(.caption).foregroundStyle(.secondary); ParamField(name: p + "_X", width: 60)
                    Text("Y").font(.caption).foregroundStyle(.secondary); ParamField(name: p + "_Y", width: 60)
                    Text("клітинок").font(.caption).foregroundStyle(.tertiary)
                }
                if OSDShapes.mspOnly.contains(k) && osdType != 3 {
                    Label("Цей елемент малюють лише MSP-окуляри; на аналоговому OSD і в DisplayPort його не буде.", systemImage: "eye.slash").font(.caption).foregroundStyle(.orange)
                }
                let sh = OSDShapes.shape(k)
                Text(lk(String(localized: "Розмір: \(sh.w)×\(sh.h) клітинок") + (sh.dx != 0 || sh.dy != 0 ? " · X/Y задають центр" : " · X/Y задають лівий верхній кут"))).font(.caption).foregroundStyle(.tertiary)
            } else {
                Text("Клацніть елемент на макеті або в списку нижче.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// Плитки всіх елементів з прапорцями (як у Mission Planner), згруповані за призначенням.
    func elementGrid(_ keys: [String]) -> some View {
        let q = search.lowercased()
        let filtered = keys.filter { q.isEmpty || OSDInfo.title($0).lowercased().contains(q) || $0.lowercased().contains(q) }
        return VStack(alignment: .leading, spacing: 8) {
            Divider().padding(.top, 4)
            HStack {
                Text("Елементи екрана \(screen)").font(.callout.weight(.semibold))
                Text("увімкнено \(keys.filter { (ps.val("\(sp(screen))_\($0)_EN") ?? 0) > 0 }.count) з \(keys.count)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                TextField("Пошук елемента", text: $search).textFieldStyle(.roundedBorder).frame(width: 200)
            }
            ForEach(OSDInfo.groupOrder, id: \.self) { g in
                let list = filtered.filter { OSDInfo.group($0) == g }
                if !list.isEmpty {
                    Text(verbatim: loc(g).uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 4)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 210), spacing: 8)], spacing: 8) {
                        ForEach(list, id: \.self) { k in elementTile(k) }
                    }
                }
            }
        }
    }

    func elementTile(_ k: String) -> some View {
        let en = (ps.val("\(sp(screen))_\(k)_EN") ?? 0) > 0
        let on = selected == k
        let hiddenHere = OSDShapes.mspOnly.contains(k) && osdType != 3
        return HStack(spacing: 8) {
            Toggle("", isOn: Binding(get: { en }, set: { toggleItem(k, $0) })).toggleStyle(.checkbox).labelsHidden().disabled(s.armed)
            VStack(alignment: .leading, spacing: 0) {
                Text(LocalizedStringKey(k)).font(.system(.caption, design: .monospaced).weight(.semibold)).lineLimit(1).foregroundStyle(en ? .primary : .secondary)
                Text(lk(OSDInfo.title(k))).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if hiddenHere { Image(systemName: "eye.slash").font(.system(size: 10)).foregroundStyle(.orange).tip("Лише MSP OSD: на цьому типі не відображається") }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(on ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(on ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.08)))
        .contentShape(Rectangle())
        .onTapGesture { selected = k }
        .tip(OSDInfo.title(k))
    }

    /// Вмикає елемент; якщо його позиція 0,0 (не задана), ставить у вільне місце.
    func toggleItem(_ k: String, _ on: Bool) {
        let p = sp(screen) + "_" + k
        ps.write(p + "_EN", on ? 1 : 0)
        guard on else { return }
        if (ps.val(p + "_X") ?? 0) == 0 && (ps.val(p + "_Y") ?? 0) == 0 {
            ps.write(p + "_X", 2); ps.write(p + "_Y", Double(min(format.rows - 1, 3)))
        }
        selected = k
    }

    // MARK: Крок 3: зсув
    var offsetCard: some View {
        Card(title: String(localized: "Зсув картинки"), icon: "arrow.up.and.down.and.arrow.left.and.right", text: String(localized: "Якщо на екрані окулярів текст обрізається або зміщений, підігнайте положення по горизонталі й вертикалі (для аналогового OSD).")) {
            ForEach(["OSD_H_OFFSET", "OSD_V_OFFSET"].filter { ps.has($0) }, id: \.self) { n in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(lk(ParamTexts.info(n)?.title ?? n)).font(.callout)
                        Text(LocalizedStringKey(n)).font(.system(.caption2, design: .monospaced)).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Stepper(value: Binding(get: { Int(ps.val(n) ?? 0) }, set: { ps.write(n, Double($0)) }), in: 0...63) { Text("\(Int(ps.val(n) ?? 0))").font(.system(.body, design: .monospaced)).frame(width: 40, alignment: .trailing) }.disabled(s.armed)
                }
            }
        }
    }

    // MARK: Додатково
    var switchCard: some View {
        Card(title: String(localized: "Перемикання екранів"), icon: "switch.2", text: String(localized: "Канал пульта й метод, яким перемикаються екрани OSD. У режимі «за діапазонами» кожному екрану задаються межі PWM.")) {
            VStack(spacing: 0) {
                ForEach(["OSD_CHAN", "OSD_SW_METHOD", "OSD_BTN_DELAY"].filter { ps.has($0) }, id: \.self) { AdvParamRow(name: $0, describe: true); Divider().opacity(0.4) }
            }
            if (ps.val("OSD_SW_METHOD") ?? 0) == 1 {
                ForEach(screens, id: \.self) { n in
                    HStack(spacing: 10) {
                        Text("Екран \(n)").font(.callout).frame(width: 70, alignment: .leading)
                        Text("від").font(.caption).foregroundStyle(.secondary); ParamField(name: "\(sp(n))_CHAN_MIN", width: 70)
                        Text("до").font(.caption).foregroundStyle(.secondary); ParamField(name: "\(sp(n))_CHAN_MAX", width: 70)
                        Text("мкс").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    var screenParams: some View {
        let names = screens.flatMap { n in ["\(sp(n))_FONT", "\(sp(n))_TXT_RES", "\(sp(n))_ESC_IDX"] }
        return ParamsCard(title: String(localized: "Параметри екранів"), icon: "rectangle.stack", params: names)
    }
}

// MARK: - Форма елементів за вихідним кодом ArduPilot (AP_OSD_Screen.cpp, Copter-4.6.3)

/// Скільки клітинок займає елемент і де відносно параметрів X/Y. Символи шрифту замінено близькими знаками.
// MARK: - Макет екрана з перетягуванням

/// Макет відтворює кадр відео: аналог 4:3, цифра 16:9 (DJI 30×16 займає центральну область 4:3), символьні клітинки шириною
/// в одну клітинку сітки, як у справжньому OSD. Позиції X/Y збігаються з параметрами польотника.
struct OSDGrid: View {
    @Environment(Store.self) var s
    let screen: Int
    let format: OSDFormat
    let wide: Bool                      // цифрова система: кадр 16:9
    let msp: Bool                       // тип OSD = MSP (окуляри самі малюють MSP-елементи)
    let screenOn: Bool
    let keys: [String]
    var names = false                   // показувати назви елементів замість прикладів
    var scale: CGFloat = 1
    @Binding var selected: String?
    @Binding var overrides: [String: CGPoint]
    @State private var drag: (key: String, offset: CGSize)?
    var ps: ParamStore { s.ps }

    func pos(_ k: String) -> CGPoint {
        if let o = overrides[k] { return o }
        let p = "OSD\(screen)_\(k)"
        return CGPoint(x: ps.val(p + "_X") ?? 0, y: ps.val(p + "_Y") ?? 0)
    }

    /// Геометрія: розмір кадру, область сітки в ньому й розмір клітинки.
    /// Для HD-макета полотно завжди 60×22 (клітинка 12×18), а вибрана сітка (наприклад 50×18) позначається рамкою в його куті.
    struct Geo { let frameW: CGFloat, frameH: CGFloat, gridW: CGFloat, gridH: CGFloat, originX: CGFloat, cellW: CGFloat, cellH: CGFloat, canvasCols: Int, canvasRows: Int }
    var geo: Geo {
        let frameW: CGFloat = 600 * scale
        if wide && format.cols > 30 {
            let cw = frameW / 60, ch = cw * 1.5
            return Geo(frameW: frameW, frameH: ch * 22, gridW: frameW, gridH: ch * 22, originX: 0, cellW: cw, cellH: ch, canvasCols: 60, canvasRows: 22)
        }
        let frameH = wide ? frameW * 9 / 16 : frameW * 3 / 4
        let gridH = frameH
        let gridW = min(frameW, gridH * 4.0 / 3.0)
        return Geo(frameW: frameW, frameH: frameH, gridW: gridW, gridH: gridH, originX: (frameW - gridW) / 2, cellW: gridW / CGFloat(format.cols), cellH: gridH / CGFloat(format.rows), canvasCols: format.cols, canvasRows: format.rows)
    }

    var body: some View {
        let g = geo
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                // Імітація кадру з камери: небо, земля й горизонт
                LinearGradient(stops: [.init(color: Color(red: 0.36, green: 0.55, blue: 0.78), location: 0), .init(color: Color(red: 0.70, green: 0.80, blue: 0.88), location: 0.52),
                                       .init(color: Color(red: 0.36, green: 0.42, blue: 0.27), location: 0.53), .init(color: Color(red: 0.22, green: 0.27, blue: 0.17), location: 1)], startPoint: .top, endPoint: .bottom)
                Canvas { ctx, size in
                    // область сітки й клітинки
                    let box = CGRect(x: g.originX, y: 0, width: g.gridW, height: g.gridH)
                    if g.gridW < g.frameW - 1 { ctx.stroke(Path(box), with: .color(.white.opacity(0.35)), style: StrokeStyle(lineWidth: 1, dash: [4, 3])) }
                    if g.canvasCols > format.cols || g.canvasRows > format.rows {
                        let region = CGRect(x: g.originX, y: 0, width: CGFloat(format.cols) * g.cellW, height: CGFloat(format.rows) * g.cellH)
                        ctx.fill(Path(region), with: .color(.black.opacity(0.10)))
                        ctx.stroke(Path(region), with: .color(.white.opacity(0.7)), lineWidth: 1)
                        ctx.draw(Text("\(format.cols)x\(format.rows)").font(.system(size: 10, design: .monospaced)).foregroundColor(.white.opacity(0.9)), at: CGPoint(x: region.maxX - 4, y: region.maxY - 8), anchor: .trailing)
                    }
                    for c in stride(from: 0, through: g.canvasCols, by: 5) {
                        var p = Path(); p.move(to: CGPoint(x: g.originX + CGFloat(c) * g.cellW, y: 0)); p.addLine(to: CGPoint(x: g.originX + CGFloat(c) * g.cellW, y: g.gridH))
                        ctx.stroke(p, with: .color(.white.opacity(0.14)), lineWidth: 0.5)
                    }
                    for r in stride(from: 0, through: g.canvasRows, by: 4) {
                        var p = Path(); p.move(to: CGPoint(x: g.originX, y: CGFloat(r) * g.cellH)); p.addLine(to: CGPoint(x: g.originX + g.gridW, y: CGFloat(r) * g.cellH))
                        ctx.stroke(p, with: .color(.white.opacity(0.14)), lineWidth: 0.5)
                    }
                }
                // Усі елементи малюються одним Canvas (раніше кожен символ був окремим View із тінню: макет гальмував)
                Canvas { ctx, size in drawItems(&ctx, g) }
                    .frame(width: g.frameW, height: g.frameH)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { v in dragChanged(v, g) }
                        .onEnded { v in dragEnded(v, g) })
                if !screenOn {
                    Color.black.opacity(0.55)
                    Text("Екран \(screen) вимкнено: на відео нічого не буде").font(.callout.weight(.semibold)).foregroundStyle(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(width: g.frameW, height: g.frameH)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.25)))
            HStack(spacing: 10) {
                Text(lk(String(localized: "Кадр \(wide ? "16:9" : "4:3"), сітка \(format.cols)×\(format.rows)") + (g.canvasCols > format.cols ? String(localized: " на полотні \(g.canvasCols)×\(g.canvasRows)") : "") + String(localized: ", клітинка \(String(format: "%.1f×%.1f", g.cellW, g.cellH)) px")))
                if let k = selected { Text("· \(OSDInfo.title(k)): X \(Int(pos(k).x)), Y \(Int(pos(k).y))").foregroundStyle(.primary) }
            }
            .font(.caption).foregroundStyle(.secondary)
            let enabled = keys.filter { (ps.val("OSD\(screen)_\($0)_EN") ?? 0) > 0 }
            let hidden = enabled.filter { !msp && OSDShapes.mspOnly.contains($0) }
            let outside = enabled.filter { k in !hidden.contains(k) && isOutside(k) }
            if !hidden.isEmpty {
                Label(lk(loc("Увімкнено, але на відео не з'являться (лише MSP OSD): ") + hidden.map { OSDInfo.title($0) }.joined(separator: ", ")), systemImage: "eye.slash").font(.caption).foregroundStyle(.orange).frame(width: g.frameW, alignment: .leading)
            }
            if !outside.isEmpty {
                Label(lk(String(localized: "Виходять за межі екрана \(format.cols)×\(format.rows): ") + outside.map { OSDInfo.title($0) }.joined(separator: ", ")), systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red).frame(width: g.frameW, alignment: .leading)
            }
            Text("Форма, розмір і символи елементів відповідають вихідному коду ArduPilot і шрифту OSD_FONT, одиниці виміру беруться з OSD_UNITS. Горизонт і компас задаються центром, решта лівим верхнім кутом.").font(.caption2).foregroundStyle(.tertiary).frame(width: g.frameW, alignment: .leading)
        }
    }

    /// Габарит елемента в клітинках: (лівий верхній кут X, Y, ширина, висота).
    func box(_ k: String) -> (x: Int, y: Int, w: Int, h: Int) {
        let p = pos(k), s = realShape(k)
        return (Int(p.x) + s.dx, Int(p.y) + s.dy, s.w, s.h)
    }
    func isOutside(_ k: String) -> Bool {
        let b = box(k)
        return b.x < 0 || b.y < 0 || b.x + b.w > format.cols || b.y + b.h > format.rows
    }

    /// Елементи, що малюються на макеті (увімкнені й видимі для цього типу OSD), у порядку малювання.
    func visibleKeys() -> [String] {
        keys.filter { k in (ps.val("OSD\(screen)_\(k)_EN") ?? 0) > 0 && (msp || !OSDShapes.mspOnly.contains(k)) }
    }
    /// Те, що показується на макеті: приклад значення або назва елемента.
    func realShape(_ k: String) -> OSDShape {
        OSDShapes.units = Int(ps.val("OSD_UNITS") ?? 0); OSDShapes.sidebarVExt = Int(ps.val("OSD_SB_V_EXT") ?? 0); OSDShapes.sidebarHOffset = Int(ps.val("OSD_SB_H_OFS") ?? 0)
        return OSDShapes.shape(k)
    }
    func displayShape(_ k: String) -> OSDShape { names ? OSDShape(rows: [k], dx: 0, dy: 0) : realShape(k) }

    /// Прямокутник елемента у координатах кадру (з урахуванням перетягування).
    func rect(_ k: String, _ g: Geo) -> CGRect {
        let p = pos(k), sh = displayShape(k)
        let off = drag?.key == k ? drag!.offset : .zero
        return CGRect(x: g.originX + (p.x + CGFloat(sh.dx)) * g.cellW + off.width, y: (p.y + CGFloat(sh.dy)) * g.cellH + off.height,
                      width: CGFloat(sh.w) * g.cellW, height: CGFloat(sh.h) * g.cellH)
    }

    func drawItems(_ ctx: inout GraphicsContext, _ g: Geo) {
        let glyphs = OSDFontLib.glyphs(Int(ps.val("OSD_FONT") ?? 0))
        for k in visibleKeys() {
            let sh = displayShape(k), r = rect(k, g)
            let isSel = selected == k, out = isOutside(k)
            if isSel { ctx.fill(Path(r), with: .color(.accentColor.opacity(0.30))) }
            else if k == "HORIZON" { ctx.fill(Path(r), with: .color(.white.opacity(0.04))) }
            if isSel || out || k == "HORIZON" {
                ctx.stroke(Path(r), with: .color(out ? .red : (isSel ? .accentColor : .white.opacity(0.25))),
                           style: StrokeStyle(lineWidth: out || isSel ? 1.2 : 0.6, dash: isSel && !out ? [] : [3, 2]))
            }
            for (ri, row) in sh.cells.enumerated() {
                for (ci, c) in row.enumerated() {
                    guard let c, let img = glyphs[Int(c)] else { continue }
                    let cr = CGRect(x: r.minX + CGFloat(ci) * g.cellW, y: r.minY + CGFloat(ri) * g.cellH, width: g.cellW, height: g.cellH)
                    ctx.draw(ctx.resolve(Image(decorative: img, scale: 1).interpolation(.none)), in: cr)
                }
            }
        }
    }

    /// Елемент під точкою: останній у порядку малювання (верхній).
    func hit(_ pt: CGPoint, _ g: Geo) -> String? {
        visibleKeys().last { rect($0, g).insetBy(dx: -2, dy: -2).contains(pt) }
    }

    @State private var dragStart: String?
    func dragChanged(_ v: DragGesture.Value, _ g: Geo) {
        if dragStart == nil, drag == nil {
            dragStart = hit(v.startLocation, g) ?? ""
            if let k = dragStart, !k.isEmpty, selected != k { selected = k }
        }
        guard let k = dragStart, !k.isEmpty, !s.armed else { return }
        if abs(v.translation.width) + abs(v.translation.height) >= 2 { drag = (k, v.translation) }
    }
    func dragEnded(_ v: DragGesture.Value, _ g: Geo) {
        defer { dragStart = nil; drag = nil }
        guard let k = dragStart, !k.isEmpty else { selected = nil; return }
        selected = k
        guard drag != nil, !s.armed else { return }
        let p = pos(k)
        let nx = min(max(0, Int((p.x + v.translation.width / g.cellW).rounded())), g.canvasCols - 1)
        let ny = min(max(0, Int((p.y + v.translation.height / g.cellH).rounded())), g.canvasRows - 1)
        overrides[k] = CGPoint(x: nx, y: ny)
        ps.write("OSD\(screen)_\(k)_X", Double(nx)); ps.write("OSD\(screen)_\(k)_Y", Double(ny))
        Task { @MainActor in try? await Task.sleep(nanoseconds: 2_500_000_000); overrides[k] = nil }
    }
}
