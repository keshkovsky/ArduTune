import SwiftUI
import Charts

// MARK: - Типи моніторів і шини підключення

enum BattBus: String {
    case none = "вимкнено", analog = "аналоговий вхід (ADC)", i2c = "шина I²C / SMBus", spi = "шина SPI", can = "шина CAN (DroneCAN)"
    case esc = "телеметрія ESC", sum = "сума моніторів", fuel = "паливо", generator = "генератор", serial = "послідовний порт", builtin = "вбудований", scripting = "Lua-скрипт", other = "інше"
    var icon: String {
        switch self {
        case .analog: "waveform.path"; case .i2c, .spi: "cpu"; case .can: "point.3.connected.trianglepath.dotted"; case .esc: "bolt.horizontal"
        case .sum: "sum"; case .serial: "cable.connector"; case .none: "nosign"; default: "battery.100"
        }
    }
}

func battBus(_ monitor: Int) -> BattBus {
    switch monitor {
    case 0: return .none
    case 3, 4, 24, 25, 31: return .analog
    case 5, 6: return .builtin
    case 7, 13, 14, 15, 16, 21, 22, 28, 30, 32: return .i2c
    case 26: return .spi
    case 8: return .can
    case 9: return .esc
    case 10: return .sum
    case 11, 12: return .fuel
    case 17, 18, 20: return .generator
    case 19, 23: return .serial
    case 29: return .scripting
    default: return .other
    }
}

struct SensorPreset: Identifiable { let id: Int; let name: String; let voltMult: Double; let ampPerVolt: Double }
let sensorPresets: [SensorPreset] = [
    SensorPreset(id: 1, name: "AttoPilot 45A", voltMult: 1000 / 242.3, ampPerVolt: 1000 / 73.20),
    SensorPreset(id: 2, name: "AttoPilot 90A", voltMult: 1000 / 63.69, ampPerVolt: 1000 / 36.60),
    SensorPreset(id: 3, name: "AttoPilot 180A", voltMult: 1000 / 63.69, ampPerVolt: 1000 / 18.30),
    SensorPreset(id: 4, name: "3DR Power Module (IV)", voltMult: 1000 / 99, ampPerVolt: 1000 / 55.55),
    SensorPreset(id: 5, name: "3DR 4-in-1 ESC", voltMult: 12.02, ampPerVolt: 17),
    SensorPreset(id: 6, name: "3DR HV (APM)", voltMult: 12.02, ampPerVolt: 24),
    SensorPreset(id: 7, name: "3DR HV (PX4/Cube)", voltMult: 12.02, ampPerVolt: 39.877),
    SensorPreset(id: 8, name: "Pixhack", voltMult: 18, ampPerVolt: 24),
    SensorPreset(id: 9, name: "Holybro Pixhawk 4 PM", voltMult: 18.182, ampPerVolt: 36.364),
]

struct BoardPins: Identifiable { let id: Int; let name: String; let volt: Int; let curr: Int }
let boardPins: [BoardPins] = [
    BoardPins(id: 1, name: "Pixhawk / Pixhawk 2", volt: 2, curr: 3),
    BoardPins(id: 2, name: "Matek H743 / VRBrain 5", volt: 10, curr: 11),
    BoardPins(id: 3, name: "Cube Orange / Orange+", volt: 14, curr: 15),
    BoardPins(id: 4, name: "Durandal", volt: 16, curr: 17),
    BoardPins(id: 5, name: "Pixhawk 6C / Pix32 v6", volt: 8, curr: 4),
    BoardPins(id: 6, name: "VRBrain 4", volt: 6, curr: 7),
    BoardPins(id: 7, name: "APM 2.5", volt: 13, curr: 12),
]

struct CellChem: Identifiable { let id: String; let name: String; let max: Double; let min: Double }
let cellChems: [CellChem] = [
    CellChem(id: "lipo", name: "LiPo (4.2 / 3.3 В)", max: 4.2, min: 3.3),
    CellChem(id: "lihv", name: "LiPo HV (4.35 / 3.3 В)", max: 4.35, min: 3.3),
    CellChem(id: "liion", name: "Li-Ion (4.1 / 2.8 В)", max: 4.1, min: 2.8),
]

// MARK: - Сторінка Battery Monitor

struct BatteryView: View {
    @Environment(Store.self) var s
    @State private var inst = 1
    @State private var measuredV = ""
    @State private var measuredA = ""
    @State private var cells = 4
    @State private var chem = "lipo"
    @State private var note: String?
    var ps: ParamStore { s.ps }

    func pfx(_ n: Int) -> String { n == 1 ? "BATT" : "BATT\(n)" }
    var p: String { pfx(inst) }
    func name(_ suffix: String) -> String { p + "_" + suffix }
    var instances: [Int] { (1...9).filter { ps.has(pfx($0) + "_MONITOR") } }
    var monitor: Int { Int(ps.val(name("MONITOR")) ?? 0) }
    var bus: BattBus { battBus(monitor) }
    var chemInfo: CellChem { cellChems.first { $0.id == chem } ?? cellChems[0] }
    var monitorLabel: String { ps.options(name("MONITOR")).first { $0.0 == monitor }?.1 ?? String(localized: "тип \(monitor)") }

    @AppStorage("batt.advanced") private var advancedOpen = true

    var body: some View {
        ConfigGate {
            if !ps.has("BATT_MONITOR") {
                ContentUnavailableView("Монітор батареї недоступний", systemImage: "battery.0", description: Text("Параметра BATT_MONITOR немає в цій прошивці."))
            } else {
                header
                liveCard
                sectionTitle("Основні налаштування", "Достатньо, щоб автопілот правильно бачив батарею та реагував на розряд.")
                stepLabel(1, "Датчик батареї")
                typeCard
                if bus == .analog { analogCard }
                stepLabel(2, "Ємність")
                capacityCard
                stepLabel(3, "Пороги заряду й дії")
                thresholdsCard

                Button { withAnimation(.snappy(duration: 0.2)) { advancedOpen.toggle() } } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.right").rotationEffect(.degrees(advancedOpen ? 90 : 0)).font(.system(size: 11, weight: .bold)).frame(width: 12)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Додаткові налаштування").font(.title3.weight(.semibold))
                            Text("Калібрування, зовнішні датчики CAN/I²C, умови арму, компенсація тяги та рідкісні параметри.").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).padding(.top, 10)
                if advancedOpen {
                    if bus == .analog { calibrationCard }
                    ExternalSensorCard(inst: inst)
                    advancedCard
                    thrustCard
                    otherParamsCard
                }
                RebootRow(text: String(localized: "Тип монітора, піни й шина застосовуються після перезавантаження автопілота."))
            }
        }
        .onAppear { if !instances.contains(inst) { inst = instances.first ?? 1 }; cells = max(1, Int((s.t.batteryV / 3.8).rounded())) }
    }

    func sectionTitle(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(LocalizedStringKey(title)).font(.title3.weight(.semibold))
            Text(LocalizedStringKey(subtitle)).font(.caption).foregroundStyle(.secondary)
        }.padding(.top, 6)
    }
    func stepLabel(_ n: Int, _ title: String) -> some View {
        HStack(spacing: 8) {
            Text("\(n)").font(.caption.weight(.bold)).foregroundStyle(.white).frame(width: 20, height: 20).background(Color.accentColor, in: Circle())
            Text(LocalizedStringKey(title)).font(.headline)
        }.padding(.top, 4)
    }

    // MARK: Вибір батареї
    var header: some View {
        HStack(spacing: 12) {
            if instances.count > 1 {
                Picker("Батарея", selection: $inst) {
                    ForEach(instances, id: \.self) { n in Text(lk(n == 1 ? "Батарея 1" : String(localized: "Батарея \(n)"))).tag(n) }
                }.pickerStyle(.segmented).frame(width: 90 * CGFloat(instances.count))
            }
            Spacer()
            Pill(text: monitor == 0 ? "Вимкнено" : monitorLabel, tint: monitor == 0 ? .gray : .blue)
            if monitor != 0 { Label(LocalizedStringKey(bus.rawValue), systemImage: bus.icon).font(.callout).foregroundStyle(.secondary) }
        }
    }

    var liveCard: some View {
        let t = s.t
        return Card(title: String(localized: "Поточні показники"), icon: "gauge.with.dots.needle.67percent", text: inst == 1 ? nil : "Живі дані телеметрії показують батарею 1.") {
            HStack(spacing: 28) {
                stat("Напруга", String(format: loc("%.2f В"), t.batteryV), .purple)
                stat("Струм", String(format: loc("%.1f А"), t.batteryA), .orange)
                stat("Потужність", String(format: loc("%.0f Вт"), t.batteryV * t.batteryA), .pink)
                stat("Витрачено", String(format: loc("%.0f мАг"), t.mahUsed), .mint)
                stat("Заряд", t.batteryPct >= 0 ? "\(t.batteryPct) %" : "—", t.batteryPct >= 0 && t.batteryPct < 25 ? .red : .green)
                Spacer()
            }
        }
    }
    func stat(_ title: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(LocalizedStringKey(title)).font(.caption).foregroundStyle(.secondary)
            Text(LocalizedStringKey(value)).font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(color)
        }
    }

    // MARK: Тип монітора
    var typeCard: some View {
        Card(title: String(localized: "Тип монітора й підключення"), icon: "battery.100.bolt", text: String(localized: "Монітор визначає, звідки автопілот бере напругу й струм. Від типу залежить шина підключення та набір параметрів нижче.")) {
            HStack(spacing: 12) {
                Text(lk(name("MONITOR"))).font(.system(.callout, design: .monospaced))
                OptionPicker(name: name("MONITOR"), width: 340)
            }
            switch bus {
            case .i2c, .spi:
                paramGroup("Підключення", [name("I2C_BUS"), name("I2C_ADDR"), name("SHUNT"), name("SERIAL_NUM")])
                Text("Датчик на шині \(bus == .spi ? "SPI" : "I²C"): вкажіть номер шини й адресу пристрою.").font(.caption).foregroundStyle(.secondary)
            case .can:
                paramGroup("DroneCAN", [name("SERIAL_NUM")])
                Text("Батарея передає дані по CAN. Переконайтеся, що CAN-порт (CAN_Pn_DRIVER) увімкнено в налаштуваннях CAN.").font(.caption).foregroundStyle(.secondary)
            case .esc:
                paramGroup("Телеметрія ESC", [name("ESC_INDEX"), name("ESC_MASK")])
                Text("Напруга й струм беруться з телеметрії регуляторів (потрібна двостороння телеметрія DShot або серійна).").font(.caption).foregroundStyle(.secondary)
            case .sum:
                paramGroup("Сума моніторів", [name("SUM_MASK")])
            case .serial, .generator, .fuel, .builtin, .scripting, .other:
                paramGroup("Параметри монітора", ps.params.map(\.name).filter { $0.hasPrefix(p + "_") && !Self.commonSuffixes.contains(String($0.dropFirst(p.count + 1))) && !$0.contains("_FS_") }.sorted().prefix(12).map { $0 })
            default: EmptyView()
            }
        }
    }
    static let commonSuffixes: Set<String> = ["MONITOR", "CAPACITY", "LOW_VOLT", "CRT_VOLT", "LOW_MAH", "CRT_MAH", "ARM_VOLT", "ARM_MAH", "LOW_TIMER", "OPTIONS", "WATT_MAX", "THR_OFF", "VOLT_PIN", "CURR_PIN", "VOLT_MULT", "AMP_PERVLT", "AMP_OFFSET", "VLT_OFFSET", "SERIAL_NUM"]

    func paramGroup(_ title: String, _ names: [String]) -> some View {
        let present = names.filter { ps.has($0) }
        return VStack(alignment: .leading, spacing: 0) {
            if !present.isEmpty && !title.isEmpty { Text(verbatim: loc(title).uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).padding(.bottom, 2) }
            ForEach(present, id: \.self) { AdvParamRow(name: $0, describe: true); Divider().opacity(0.4) }
        }
    }

    // MARK: Аналоговий датчик
    var analogCard: some View {
        Card(title: String(localized: "Аналоговий датчик напруги й струму"), icon: "waveform.path", text: String(localized: "Піни АЦП на платі та коефіцієнти силового модуля. Оберіть плату й модуль, щоб підставити типові значення, або введіть свої.")) {
            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Плата (піни)").font(.caption).foregroundStyle(.secondary)
                    Picker("", selection: Binding(get: { boardPins.first { $0.volt == Int(ps.val(name("VOLT_PIN")) ?? -9) && $0.curr == Int(ps.val(name("CURR_PIN")) ?? -9) }?.id ?? 0 }, set: { id in
                        if let b = boardPins.first(where: { $0.id == id }) { ps.write(name("VOLT_PIN"), Double(b.volt)); ps.write(name("CURR_PIN"), Double(b.curr)) }
                    })) {
                        Text("Свої значення").tag(0)
                        ForEach(boardPins) { Text("\(loc($0.name)) (\($0.volt)/\($0.curr))").tag($0.id) }
                    }.labelsHidden().frame(width: 280).disabled(s.armed)
                }
                if monitor != 3 {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Силовий модуль (коефіцієнти)").font(.caption).foregroundStyle(.secondary)
                        Picker("", selection: Binding(get: { currentPreset?.id ?? 0 }, set: { id in
                            if let pr = sensorPresets.first(where: { $0.id == id }) { ps.write(name("VOLT_MULT"), pr.voltMult); ps.write(name("AMP_PERVLT"), pr.ampPerVolt) }
                        })) {
                            Text("Свої значення").tag(0)
                            ForEach(sensorPresets) { Text(lk($0.name)).tag($0.id) }
                        }.labelsHidden().frame(width: 260).disabled(s.armed)
                    }
                }
            }
            paramGroup("Параметри", [name("VOLT_PIN"), name("CURR_PIN"), name("VOLT_MULT"), name("AMP_PERVLT"), name("AMP_OFFSET"), name("VLT_OFFSET")].filter { monitor != 3 || !$0.hasSuffix("CURR_PIN") && !$0.hasSuffix("AMP_PERVLT") && !$0.hasSuffix("AMP_OFFSET") })
        }
    }

    var currentPreset: SensorPreset? {
        let m = ps.val(name("VOLT_MULT")) ?? 0, a = ps.val(name("AMP_PERVLT")) ?? 0
        return sensorPresets.first { abs($0.voltMult - m) < 0.01 && abs($0.ampPerVolt - a) < 0.01 }
    }

    // MARK: Калібрування за вимірюваннями
    var calibrationCard: some View {
        Card(title: String(localized: "Калібрування за вимірюваннями"), icon: "scope", text: String(localized: "Виміряйте реальну напругу мультиметром (і струм токовими кліщами), введіть значення: коефіцієнти перерахуються пропорційно до показів автопілота.")) {
            let reportedV = s.t.batteryV, reportedA = s.t.batteryA
            let mult = ps.val(name("VOLT_MULT")) ?? 0
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                GridRow {
                    Text("Напруга").font(.callout.weight(.medium))
                    Text(String(format: loc("автопілот: %.2f В"), reportedV)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    TextField("виміряно, В", text: $measuredV).textFieldStyle(.roundedBorder).frame(width: 120)
                    Button("Калібрувати") {
                        if let m = Double(measuredV.replacingOccurrences(of: ",", with: ".")), reportedV > 0.5, mult > 0 {
                            let nv = m * mult / reportedV
                            ps.write(name("VOLT_MULT"), nv); note = String(format: loc("%@ = %.4f (було %.4f)"), name("VOLT_MULT"), nv, mult)
                        } else { note = String(localized: "Введіть виміряну напругу; автопілот має показувати напругу > 0.5 В") }
                    }.disabled(s.armed)
                }
                if monitor == 4 || monitor == 31 {
                    let apv = ps.val(name("AMP_PERVLT")) ?? 0
                    GridRow {
                        Text("Струм").font(.callout.weight(.medium))
                        Text(String(format: loc("автопілот: %.1f А"), reportedA)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        TextField("виміряно, А", text: $measuredA).textFieldStyle(.roundedBorder).frame(width: 120)
                        Button("Калібрувати") {
                            if let m = Double(measuredA.replacingOccurrences(of: ",", with: ".")), reportedA > 0.5, apv > 0 {
                                let na = m * apv / reportedA
                                ps.write(name("AMP_PERVLT"), na); note = String(format: loc("%@ = %.4f (було %.4f)"), name("AMP_PERVLT"), na, apv)
                            } else { note = String(localized: "Потрібен струм навантаження > 0.5 А та виміряне значення") }
                        }.disabled(s.armed)
                    }
                    GridRow {
                        Text("Нуль струму").font(.callout.weight(.medium))
                        Text("без навантаження (мотори вимкнені)").font(.caption).foregroundStyle(.secondary)
                        Color.clear.frame(width: 1, height: 1)
                        Button("Обнулити зміщення") {
                            let off = ps.val(name("AMP_OFFSET")) ?? 0
                            if apv > 0 { let no = off + reportedA / apv; ps.write(name("AMP_OFFSET"), no); note = String(format: loc("%@ = %.4f В (було %.4f)"), name("AMP_OFFSET"), no, off) }
                        }.disabled(s.armed || apv <= 0)
                    }
                }
            }
            if let n = note { Text(LocalizedStringKey(n)).font(.caption).foregroundStyle(.secondary) }
        }
    }

    // MARK: Ємність
    var capacityCard: some View {
        Card(title: String(localized: "Ємність батареї"), icon: "battery.75", text: String(localized: "Вкажіть номінальну ємність з маркування акумулятора. Від неї залежить відсоток заряду на HUD.")) {
            paramGroup("", [name("CAPACITY")])
        }
    }

    // MARK: Пороги й дії
    var thresholdsCard: some View {
        Card(title: String(localized: "Пороги заряду й реакція автопілота"), icon: "exclamationmark.shield", text: String(localized: "Спершу задайте пороги (за напругою або залишком ємності), потім оберіть, що робити при їх досягненні. Швидкий розрахунок порогів: за кількістю комірок і хімією батареї.")) {
            HStack(spacing: 16) {
                Stepper(String(localized: "Комірок: \(cells)S"), value: $cells, in: 1...24).frame(width: 160)
                Picker("", selection: $chem) { ForEach(cellChems) { Text(lk($0.name)).tag($0.id) } }.labelsHidden().frame(width: 220)
                Spacer()
                Button("Розрахувати й записати пороги") { applyThresholds() }.disabled(s.armed)
            }
            let c = chemInfo
            Text(String(format: loc("Буде записано: низька %.1f В, критична %.1f В, мінімум для арму %.1f В. Формула: низька = (мін. комірки + 0.3 В)·S, критична = (мін. + 0.2 В)·S."), lowVolt(c), crtVolt(c), armVolt(c)))
                .font(.caption).foregroundStyle(.secondary)
            paramGroup("Пороги", [name("LOW_VOLT"), name("CRT_VOLT"), name("LOW_MAH"), name("CRT_MAH")])
            paramGroup("Дії", [name("FS_LOW_ACT"), name("FS_CRT_ACT")])
            if let n = note { Text(LocalizedStringKey(n)).font(.caption).foregroundStyle(.secondary) }
        }
    }
    func lowVolt(_ c: CellChem) -> Double { (c.min + 0.3) * Double(cells) }
    func crtVolt(_ c: CellChem) -> Double { (c.min + 0.2) * Double(cells) }
    func armVolt(_ c: CellChem) -> Double { Double(cells - 1) * 0.1 + (c.min + 0.3) * Double(cells) }
    func applyThresholds() {
        let c = chemInfo
        let vals = [(name("ARM_VOLT"), armVolt(c)), (name("LOW_VOLT"), lowVolt(c)), (name("CRT_VOLT"), crtVolt(c))]
        for (n, v) in vals where ps.has(n) { ps.write(n, (v * 100).rounded() / 100) }
        note = String(localized: "Пороги записано для \(cells)S")
    }

    // MARK: Додатково
    var advancedCard: some View {
        Card(title: String(localized: "Умови арму та тонкі налаштування"), icon: "slider.horizontal.3", text: nil) {
            paramGroup("Перед армом", [name("ARM_VOLT"), name("ARM_MAH")])
            paramGroup("Спрацювання", [name("LOW_TIMER"), name("FS_VOLTSRC")])
            paramGroup("Обмеження й поведінка", [name("WATT_MAX"), name("OPTIONS"), name("THR_OFF")])
        }
    }

    /// Інші параметри цього монітора, що не потрапили в картки вище.
    var otherParamsCard: some View {
        let shown: Set<String> = ["MONITOR", "CAPACITY", "LOW_VOLT", "CRT_VOLT", "LOW_MAH", "CRT_MAH", "FS_LOW_ACT", "FS_CRT_ACT", "ARM_VOLT", "ARM_MAH", "LOW_TIMER", "FS_VOLTSRC", "WATT_MAX", "OPTIONS", "THR_OFF",
                                  "VOLT_PIN", "CURR_PIN", "VOLT_MULT", "AMP_PERVLT", "AMP_OFFSET", "VLT_OFFSET", "I2C_BUS", "I2C_ADDR", "SERIAL_NUM", "SHUNT", "ESC_INDEX", "ESC_MASK", "SUM_MASK"]
        let rest = ps.params.map(\.name).filter { $0.hasPrefix(p + "_") && !shown.contains(String($0.dropFirst(p.count + 1))) }.sorted()
        return Group {
            if !rest.isEmpty {
                Card(title: String(localized: "Інші параметри монітора"), icon: "ellipsis.circle", text: nil) { paramGroup("", rest) }
            }
        }
    }

    // MARK: Компенсація тяги
    var thrustCard: some View { ThrustCompensationCard(cells: $cells, chem: $chem) }
}

/// Компенсація тяги в залежності від заряду акумулятора (MOT_BAT_VOLT_MAX/MIN для мультикоптерів, Q_M_BAT_* для QuadPlane).
struct ThrustCompensationCard: View {
    @Environment(Store.self) var s
    @Binding var cells: Int
    @Binding var chem: String
    var ps: ParamStore { s.ps }
    var mp: String? { ps.has("MOT_BAT_VOLT_MAX") ? "MOT" : (ps.has("Q_M_BAT_VOLT_MAX") ? "Q_M" : nil) }
    var info: CellChem { cellChems.first { $0.id == chem } ?? cellChems[0] }

    struct Pt: Identifiable { let id: Int; let v: Double; let gain: Double }

    var body: some View {
        if let mp {
            let vmax = ps.val("\(mp)_BAT_VOLT_MAX") ?? 0, vmin = ps.val("\(mp)_BAT_VOLT_MIN") ?? 0
            let on = vmax > 0 && vmin > 0
            Card(title: String(localized: "Компенсація тяги за зарядом батареї"), icon: "bolt.batteryblock", text: String(localized: "По мірі розряду напруга падає, а тяга моторів слабшає. Компенсація збільшує газ, щоб підйомна сила не залежала від заряду. Діапазон задають максимальна й мінімальна напруга повної батареї.")) {
                HStack(spacing: 16) {
                    Toggle(isOn: Binding(get: { on }, set: { $0 ? enable(mp) : disable(mp) })) { Text(lk(on ? "Увімкнено" : "Вимкнено")).font(.headline) }
                        .toggleStyle(.switch).disabled(s.armed)
                    Stepper(String(localized: "Комірок: \(cells)S"), value: $cells, in: 1...24).frame(width: 150)
                    Picker("", selection: $chem) { ForEach(cellChems) { Text(lk($0.name)).tag($0.id) } }.labelsHidden().frame(width: 210)
                    Spacer()
                    Button("Підставити за S і хімією") { enable(mp) }.disabled(s.armed)
                }
                if on { curve(mp, vmax: vmax, vmin: vmin) }
                VStack(spacing: 0) {
                    ForEach(["_BAT_VOLT_MAX", "_BAT_VOLT_MIN", "_BAT_IDX", "_BAT_CURR_MAX", "_BAT_CURR_TC", "_THST_EXPO", "_THST_HOVER", "_HOVER_LEARN", "_SPIN_ARM", "_SPIN_MIN", "_SPIN_MAX"].map { mp + $0 }.filter { ps.has($0) }, id: \.self) { AdvParamRow(name: $0, describe: true); Divider().opacity(0.4) }
                }
                Text("Рекомендація: MAX = макс. напруга комірки × S, MIN = мін. робоча напруга комірки × S. Для вимкнення обидва значення = 0. Параметр MIN не може бути нижчим за 60% від MAX.").font(.caption).foregroundStyle(.secondary)
            }
        } else {
            Card(title: String(localized: "Компенсація тяги за зарядом батареї"), icon: "bolt.batteryblock", text: nil) {
                Label("У цій прошивці немає параметрів MOT_BAT_VOLT_* (потрібен мультикоптер або QuadPlane).", systemImage: "info.circle").foregroundStyle(.secondary)
            }
        }
    }

    func enable(_ mp: String) {
        ps.write("\(mp)_BAT_VOLT_MAX", ((info.max * Double(cells)) * 100).rounded() / 100)
        ps.write("\(mp)_BAT_VOLT_MIN", ((info.min * Double(cells)) * 100).rounded() / 100)
    }
    func disable(_ mp: String) { ps.write("\(mp)_BAT_VOLT_MAX", 0); ps.write("\(mp)_BAT_VOLT_MIN", 0) }

    /// Коефіцієнт підсилення газу = 1 / lift_max, де lift_max = v·(1−e) + e·v², v = U / U_max.
    func curve(_ mp: String, vmax: Double, vmin: Double) -> some View {
        let expo = ps.val("\(mp)_THST_EXPO") ?? 0.65
        let lo = max(vmin, vmax * 0.6)
        func gain(_ u: Double) -> Double {
            let v = max(lo / vmax, min(1, u / vmax))
            let lift = v * (1 - expo) + expo * v * v
            return 1 / lift
        }
        let pts: [Pt] = (0...40).map { i in let u = lo + (vmax - lo) * Double(i) / 40; return Pt(id: i, v: u, gain: gain(u)) }
        let cur = s.t.batteryV
        return VStack(alignment: .leading, spacing: 4) {
            Text("Підсилення газу залежно від напруги батареї").font(.caption).foregroundStyle(.secondary)
            Chart {
                ForEach(pts) { p in LineMark(x: .value("В", p.v), y: .value("Підсилення", p.gain)).foregroundStyle(.blue) }
                if cur >= lo * 0.9 && cur <= vmax * 1.05 {
                    PointMark(x: .value("В", cur), y: .value("Підсилення", gain(cur))).foregroundStyle(.orange).symbolSize(80)
                        .annotation(position: .top) { Text(String(format: "×%.2f", gain(cur))).font(.caption2.monospacedDigit()) }
                }
            }
            .chartXScale(domain: (lo * 0.98)...(vmax * 1.02))
            .chartYAxisLabel("× газ")
            .chartXAxisLabel("напруга, В")
            .frame(height: 150)
        }
    }
}

// MARK: - Майстер початкових параметрів (Initial Parameters, як у Mission Planner)

struct InitialParamsView: View {
    @Environment(Store.self) var s
    @State private var prop = "9"
    @State private var cells = 4
    @State private var chem = "lipo"
    @State private var tmotor = false
    @State private var suggested = false
    @State private var skip: Set<String> = []
    @State private var done = false
    var ps: ParamStore { s.ps }

    struct Row: Identifiable { let name: String; let value: Double; let note: String; var id: String { name } }

    var atc: String { ps.has("ATC_ACCEL_P_MAX") || !ps.has("Q_A_ACCEL_P_MAX") ? "ATC" : "Q_A" }
    var mot: String { ps.has("MOT_THST_EXPO") || !ps.has("Q_M_THST_EXPO") ? "MOT" : "Q_M" }
    var propSize: Double { Double(prop.replacingOccurrences(of: ",", with: ".")) ?? 0 }
    var info: CellChem { cellChems.first { $0.id == chem } ?? cellChems[0] }

    static func roundTo(_ v: Double, _ precision: Int) -> Double {
        if precision >= 0 { let k = pow(10.0, Double(precision)); return (v * k).rounded() / k }
        let p = pow(10.0, Double(-precision))
        let w = v + 5 * p / 10
        return (w - w.truncatingRemainder(dividingBy: p)).rounded()
    }

    /// Формули з майстра початкових параметрів Mission Planner (ConfigInitialParams).
    var rows: [Row] {
        let ps_ = propSize
        guard ps_ > 0, cells >= 1 else { return [] }
        let c = Double(cells), bmax = info.max, bmin = info.min
        let accelY = max(8000, Self.roundTo(-900 * ps_ + 36000, -2))
        let acroYaw = 0.5 * accelY / 4500
        let accelP = max(10000, Self.roundTo(-2.613267 * pow(ps_, 3) + 343.39216 * pow(ps_, 2) - 15083.7121 * ps_ + 235771, -2))
        let gyro = max(20, (289.22 * pow(ps_, -0.838)).rounded())
        let fltd = max(10, gyro / 2)
        var expo = min((100 * (0.15686 * log(ps_) + 0.23693)).rounded() / 100, 0.80)
        if tmotor { expo = 0.2 }
        var r: [Row] = [
            Row(name: "ACRO_YAW_P", value: acroYaw, note: "швидкість рискання в Acro"),
            Row(name: atc + "_ACCEL_P_MAX", value: accelP, note: "макс. прискорення тангажа"),
            Row(name: atc + "_ACCEL_R_MAX", value: accelP, note: "макс. прискорення крену"),
            Row(name: atc + "_ACCEL_Y_MAX", value: accelY, note: "макс. прискорення рискання"),
            Row(name: atc + "_RAT_PIT_FLTD", value: fltd, note: "фільтр D, тангаж"),
            Row(name: atc + "_RAT_PIT_FLTE", value: 0, note: "фільтр помилки, тангаж"),
            Row(name: atc + "_RAT_PIT_FLTT", value: fltd, note: "фільтр цілі, тангаж"),
            Row(name: atc + "_RAT_RLL_FLTD", value: fltd, note: "фільтр D, крен"),
            Row(name: atc + "_RAT_RLL_FLTE", value: 0, note: "фільтр помилки, крен"),
            Row(name: atc + "_RAT_RLL_FLTT", value: fltd, note: "фільтр цілі, крен"),
            Row(name: atc + "_RAT_YAW_FLTD", value: 0, note: "фільтр D, рискання"),
            Row(name: atc + "_RAT_YAW_FLTE", value: 2, note: "фільтр помилки, рискання"),
            Row(name: atc + "_RAT_YAW_FLTT", value: fltd, note: "фільтр цілі, рискання"),
            Row(name: atc + "_THR_MIX_MAN", value: 0.1, note: "пріоритет газу при ручному керуванні"),
            Row(name: "INS_ACCEL_FILTER", value: 10, note: "фільтр акселерометра, Гц"),
            Row(name: "INS_GYRO_FILTER", value: gyro, note: "фільтр гіроскопа, Гц"),
            Row(name: mot + "_THST_EXPO", value: expo, note: "крива тяги"),
            Row(name: mot + "_THST_HOVER", value: 0.2, note: "початкова тяга висіння"),
            Row(name: "BATT_ARM_VOLT", value: (c - 1) * 0.1 + (bmin + 0.3) * c, note: "мін. напруга для арму"),
            Row(name: "BATT_CRT_VOLT", value: (bmin + 0.2) * c, note: "критична напруга"),
            Row(name: "BATT_LOW_VOLT", value: (bmin + 0.3) * c, note: "низька напруга"),
            Row(name: mot + "_BAT_VOLT_MAX", value: bmax * c, note: "компенсація тяги: макс. напруга"),
            Row(name: mot + "_BAT_VOLT_MIN", value: bmin * c, note: "компенсація тяги: мін. напруга"),
        ]
        if tmotor {
            r.append(Row(name: mot + "_PWM_MIN", value: 1100, note: "T-Motor: мін. PWM"))
            r.append(Row(name: mot + "_PWM_MAX", value: 1940, note: "T-Motor: макс. PWM"))
        }
        if suggested {
            r += [Row(name: "BATT_FS_CRT_ACT", value: 1, note: "критичний заряд: Land"), Row(name: "BATT_FS_LOW_ACT", value: 2, note: "низький заряд: RTL"),
                  Row(name: "FENCE_ACTION", value: 3, note: "геозона: SmartRTL або RTL"), Row(name: "FENCE_ALT_MAX", value: 120, note: "макс. висота, м"),
                  Row(name: "FENCE_ENABLE", value: 1, note: "геозона увімкнена"), Row(name: "FENCE_RADIUS", value: 150, note: "радіус, м"), Row(name: "FENCE_TYPE", value: 7, note: "тип геозони (висота+коло+полігон)")]
        }
        return r.map { Row(name: $0.name, value: ($0.value * 10000).rounded() / 10000, note: $0.note) }
    }

    var body: some View {
        ConfigGate {
            Card(title: "Initial Parameters", icon: "wand.and.stars", text: String(localized: "Майстер початкових параметрів, як у Mission Planner: за розміром пропелера й батареєю розраховує стартові значення фільтрів, прискорень, кривої тяги та порогів батареї. Перегляньте таблицю й запишіть потрібні параметри.")) {
                HStack(spacing: 22) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Діаметр пропелера, дюйми").font(.caption).foregroundStyle(.secondary)
                        TextField("9", text: $prop).textFieldStyle(.roundedBorder).frame(width: 90)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Кількість комірок (S)").font(.caption).foregroundStyle(.secondary)
                        Stepper("\(cells)S", value: $cells, in: 1...24).frame(width: 110)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Тип батареї").font(.caption).foregroundStyle(.secondary)
                        Picker("", selection: $chem) { ForEach(cellChems) { Text(lk($0.name)).tag($0.id) } }.labelsHidden().frame(width: 220)
                    }
                    Spacer()
                }
                HStack(spacing: 22) {
                    Toggle("Мотори T-Motor (PWM 1100…1940, expo 0.2)", isOn: $tmotor)
                    Toggle("Додати рекомендовані (failsafe батареї й геозона)", isOn: $suggested)
                }
            }
            tableCard
        }
    }

    var tableCard: some View {
        let list = rows
        let present = list.filter { ps.has($0.name) }
        let absent = list.filter { !ps.has($0.name) }
        let chosen = present.filter { !skip.contains($0.name) }
        return Card(title: String(localized: "Розраховані параметри"), icon: "tablecells", text: propSize <= 0 ? "Вкажіть діаметр пропелера більше нуля." : nil) {
            if !present.isEmpty {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 5) {
                    GridRow { Text("").frame(width: 20); Text("Параметр").bold(); Text("Зараз").bold(); Text("Нове").bold(); Text("Опис").bold() }.font(.caption).foregroundStyle(.secondary)
                    Divider().gridCellColumns(5)
                    ForEach(present) { r in
                        let cur = ps.val(r.name) ?? 0
                        let diff = abs(cur - r.value) > 1e-6
                        GridRow {
                            Toggle("", isOn: Binding(get: { !skip.contains(r.name) }, set: { on in if on { skip.remove(r.name) } else { skip.insert(r.name) } })).labelsHidden().toggleStyle(.checkbox)
                            Text(LocalizedStringKey(r.name)).font(.system(.callout, design: .monospaced))
                            Text(lk(fmt(cur, isInt: false))).font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
                            Text(lk(fmt(r.value, isInt: false))).font(.system(.callout, design: .monospaced).weight(diff ? .semibold : .regular)).foregroundStyle(diff ? .blue : .secondary)
                            Text(LocalizedStringKey(r.note)).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
            } else if propSize > 0 {
                Text("У цій прошивці немає відповідних параметрів.").foregroundStyle(.secondary)
            }
            if !absent.isEmpty { Text(lk(loc("Немає в прошивці (пропущено): ") + absent.map(\.name).joined(separator: ", "))).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Button { write(chosen) } label: { Label("Записати на польотник (\(chosen.count))", systemImage: "square.and.arrow.down") }
                    .buttonStyle(.borderedProminent).disabled(chosen.isEmpty || s.armed)
                Button("Вибрати все") { skip = [] }
                Button("Прибрати все") { skip = Set(present.map(\.name)) }
                Spacer()
            }
            if done {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Початкові параметри записано. Перевірте їх перед польотом.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Після пробного польоту:").font(.callout.weight(.semibold))
                    Text("• \(atc)_THR_MIX_MAN → 0.5\n• PSC_ACCZ_P → значення \(mot)_THST_HOVER\n• PSC_ACCZ_I → 2 × \(mot)_THST_HOVER").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    func write(_ list: [Row]) {
        for r in list { ps.write(r.name, r.value) }
        done = true
    }
}
