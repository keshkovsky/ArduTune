import SwiftUI

struct BatteryLive: Decodable, Identifiable { let id: Int; let volt: Double; let amps: Double; let mah: Double; let temp: Double?; let pct: Int; let age: Double }

/// Живі дані по екземплярах батарей (BATTERY_STATUS).
@Observable @MainActor
final class BatteriesModel {
    var list: [BatteryLive] = []
    @ObservationIgnored private var polling = false
    func start() {
        guard !polling else { return }
        polling = true
        Task { @MainActor in
            while polling {
                if let l = await EngineAPI.get("/batteries", as: [BatteryLive].self) { list = l }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }
    func stop() { polling = false }
}

/// Шини I²C плати з hwdef.dat прошивки (читається з автопілота через MAVFTP, @ROMFS/hwdef.dat).
struct I2CBus: Identifiable { let id: Int; let name: String; let pins: String }
struct I2CUsed: Identifiable { let id = UUID(); let bus: Int; let addr: Int; let device: String }

@Observable @MainActor
final class HwdefI2C {
    var buses: [I2CBus] = []
    var used: [I2CUsed] = []
    var status = String(localized: "завантаження…")
    @ObservationIgnored private var loaded = false

    func load() async {
        guard !loaded else { return }
        do {
            let d = try await EngineAPI.data("/ftp/read?path=@ROMFS/hwdef.dat")
            parse(String(decoding: d, as: UTF8.self)); loaded = true
        } catch { status = String(localized: "hwdef недоступний (немає зв'язку з автопілотом)") }
    }

    func parse(_ text: String) {
        var order: [String] = []; var scl: [String: String] = [:]; var sda: [String: String] = [:]; var us: [I2CUsed] = []
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let w = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            if w.first == "I2C_ORDER" { order = Array(w.dropFirst()) }
            if w.count >= 3, w[1].hasSuffix("_SCL") { scl[w[2]] = w[0] }
            if w.count >= 3, w[1].hasSuffix("_SDA") { sda[w[2]] = w[0] }
            // Внутрішні пристрої: "BARO MS5611 I2C:0:0x77"
            if w.count >= 3, ["BARO", "COMPASS", "IMU", "AIRSPEED", "BATTERY"].contains(w[0]), let spec = w.first(where: { $0.hasPrefix("I2C:") }) {
                let p = spec.split(separator: ":")
                if p.count >= 3, let b = Int(p[1]), let a = Int(String(p[2]).replacingOccurrences(of: "0x", with: ""), radix: 16) { us.append(I2CUsed(bus: b, addr: a, device: "\(w[0]) \(w[1])")) }
            }
        }
        buses = order.enumerated().map { i, n in I2CBus(id: i, name: n, pins: "SCL \(scl[n] ?? "?"), SDA \(sda[n] ?? "?")") }
        used = us
        status = buses.isEmpty ? "I2C_ORDER у hwdef не знайдено" : "hwdef плати"
    }
}

struct ExtPreset: Identifiable {
    let id: String; let name: String; let monitor: Int; let defaultAddr: Int?; let note: String
}

struct ExternalSensorCard: View {
    @Environment(Store.self) var s
    let inst: Int
    @State private var iface = "can"
    @State private var presetID = "ina2xx"
    @State private var bus = 0
    @State private var addrText = "0x40"
    @State private var serial = "-1"
    @State private var hw = HwdefI2C()
    @State private var bats = BatteriesModel()
    @State private var note: String?
    var ps: ParamStore { s.ps }

    func pfx(_ n: Int) -> String { n == 1 ? "BATT" : "BATT\(n)" }
    var p: String { pfx(inst) }

    static let i2cPresets: [ExtPreset] = [
        ExtPreset(id: "ina2xx", name: "INA226 / INA228 / INA231 / INA238 / INA260 (шунт-монітор)", monitor: 21, defaultAddr: 0x40, note: "Адреса 0x40…0x4F залежить від перемичок A0/A1 модуля. Опір шунта задається параметром BATT_SHUNT, якщо він є в прошивці."),
        ExtPreset(id: "ina3221", name: "INA3221 (3 канали)", monitor: 30, defaultAddr: 0x40, note: "Адреса 0x40…0x43."),
        ExtPreset(id: "ltc2946", name: "LTC2946", monitor: 22, defaultAddr: nil, note: "Адресу перевірте за схемою модуля."),
        ExtPreset(id: "ad7091", name: "AD7091R5", monitor: 28, defaultAddr: nil, note: "Адресу перевірте за схемою модуля."),
        ExtPreset(id: "smbus", name: "SMBus: розумна батарея (generic)", monitor: 7, defaultAddr: 0x0B, note: "Стандартна адреса розумної батареї 0x0B."),
        ExtPreset(id: "sui3", name: "SMBus: SUI3", monitor: 13, defaultAddr: 0x0B, note: "Батарея з SMBus, 3 комірки."),
        ExtPreset(id: "sui6", name: "SMBus: SUI6", monitor: 14, defaultAddr: 0x0B, note: "Батарея з SMBus, 6 комірок."),
        ExtPreset(id: "maxell", name: "SMBus: Maxell", monitor: 16, defaultAddr: 0x0B, note: "Батарея Maxell."),
        ExtPreset(id: "neo", name: "SMBus: NeoDesign", monitor: 15, defaultAddr: 0x0B, note: "Батарея NeoDesign."),
    ]
    var preset: ExtPreset { Self.i2cPresets.first { $0.id == presetID } ?? Self.i2cPresets[0] }
    var addr: Int? { Int(addrText.lowercased().replacingOccurrences(of: "0x", with: ""), radix: 16) }

    var canDriver: Int { Int(ps.val("CAN_P1_DRIVER") ?? 0) }
    var canProtocol: Int { Int(ps.val("CAN_D1_PROTOCOL") ?? 0) }
    var canOK: Bool { canDriver == 1 && canProtocol == 1 }

    var body: some View {
        Card(title: String(localized: "Зовнішній датчик напруги й струму: DroneCAN / I²C"), icon: "cable.connector.horizontal", text: String(localized: "Підключіть датчик по CAN (вузол AP_Periph, модуль живлення DroneCAN) або по I²C (INA2xx, SMBus). Майстер задасть тип монітора й параметри підключення для вибраної батареї (\(inst == 1 ? "1" : "\(inst)")).")) {
            Picker("Підключення", selection: $iface) {
                Label("DroneCAN (AP_Periph)", systemImage: "point.3.connected.trianglepath.dotted").tag("can")
                Label("I²C", systemImage: "cpu").tag("i2c")
            }.pickerStyle(.segmented).frame(width: 360)
            if iface == "can" { canBody } else { i2cBody }
            if let n = note {
                VStack(alignment: .leading, spacing: 6) {
                    Label(LocalizedStringKey(n), systemImage: "info.circle.fill").font(.callout).foregroundStyle(.orange)
                    Button { EngineAPI.post("/reboot") } label: { Label("Перезавантажити автопілот", systemImage: "restart") }.disabled(s.armed)
                }
            }
            liveTable
        }
        .task { await hw.load() }
        .onAppear { bats.start(); addrText = String(format: "0x%02X", Int(ps.val(p + "_I2C_ADDR") ?? Double(preset.defaultAddr ?? 0x40))); bus = Int(ps.val(p + "_I2C_BUS") ?? 0) }
        .onDisappear { bats.stop() }
    }

    // MARK: DroneCAN
    var canBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Тип монітора: DroneCAN-BatteryInfo (BATT_MONITOR = 8)", systemImage: "battery.100.bolt").font(.callout.weight(.medium))
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow { check(canDriver == 1, "CAN_P1_DRIVER = \(canDriver)", canDriver == 1 ? "порт CAN1 призначено драйверу 1" : "потрібно 1"); Color.clear.frame(width: 1, height: 1) }
                GridRow { check(canProtocol == 1, "CAN_D1_PROTOCOL = \(canProtocol)", canProtocol == 1 ? "драйвер 1 працює як DroneCAN" : "потрібно 1 (DroneCAN)"); Color.clear.frame(width: 1, height: 1) }
                if ps.has("CAN_D1_UC_NODE") { GridRow { check(true, "CAN_D1_UC_NODE = \(Int(ps.val("CAN_D1_UC_NODE") ?? 0))", "номер вузла автопілота в мережі"); Color.clear.frame(width: 1, height: 1) } }
            }
            HStack(spacing: 10) {
                Text("ID батареї на вузлі (\(p)_SERIAL_NUM):").font(.callout)
                TextField("-1", text: $serial).textFieldStyle(.roundedBorder).frame(width: 90)
                Text("-1 приймати будь-яку; при кількох датчиках вкажіть battery_id вузла.").font(.caption).foregroundStyle(.secondary)
            }
            Text("Сам вузол AP_Periph налаштовується окремо (його параметри BATT_*, шунт, адреса датчика): через DroneCAN GUI Tool або Mission Planner. Тут налаштовується лише приймач на польотнику.").font(.caption).foregroundStyle(.secondary)
            Button { applyCAN() } label: { Label("Налаштувати DroneCAN-датчик", systemImage: "wand.and.stars") }.buttonStyle(.borderedProminent).disabled(s.armed || !ps.has(p + "_MONITOR"))
        }
    }

    func check(_ ok: Bool, _ title: String, _ detail: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill").foregroundStyle(ok ? .green : .orange)
            Text(LocalizedStringKey(title)).font(.system(.callout, design: .monospaced))
            Text(LocalizedStringKey(detail)).font(.callout).foregroundStyle(.secondary)
        }
    }

    func applyCAN() {
        var changes: [String] = []
        func put(_ n: String, _ v: Double) { if ps.has(n) { ps.write(n, v); changes.append("\(n) = \(fmt(v, isInt: true))") } }
        put("CAN_P1_DRIVER", 1); put("CAN_D1_PROTOCOL", 1)
        put(p + "_MONITOR", 8)
        put(p + "_SERIAL_NUM", Double(Int(serial) ?? -1))
        note = loc("Записано: ") + changes.joined(separator: ", ") + loc(". Для застосування потрібне перезавантаження автопілота.")
    }

    // MARK: I²C
    var i2cBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Text("Датчик").font(.callout).frame(width: 90, alignment: .leading)
                Picker("", selection: $presetID) { ForEach(Self.i2cPresets) { Text(lk($0.name)).tag($0.id) } }.labelsHidden().frame(width: 460)
                    .onChange(of: presetID) { _, _ in if let a = preset.defaultAddr { addrText = String(format: "0x%02X", a) } }
            }
            Text(LocalizedStringKey(preset.note)).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Text("Шина I²C").font(.callout).frame(width: 90, alignment: .leading)
                Picker("", selection: $bus) {
                    if hw.buses.isEmpty { ForEach(0..<4, id: \.self) { Text("Шина \($0)").tag($0) } }
                    else { ForEach(hw.buses) { Text("Шина \($0.id): \(loc($0.name)) (\($0.pins))").tag($0.id) } }
                }.labelsHidden().frame(width: 460)
            }
            HStack(spacing: 12) {
                Text("Адреса").font(.callout).frame(width: 90, alignment: .leading)
                TextField("0x40", text: $addrText).textFieldStyle(.roundedBorder).frame(width: 90)
                if let a = addr, let clash = hw.used.first(where: { $0.bus == bus && $0.addr == a }) {
                    Label("Збіг з внутрішнім пристроєм плати: \(clash.device)", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.red)
                } else if addr == nil { Label("Введіть адресу у вигляді 0x40", systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange) }
            }
            let onBus = hw.used.filter { $0.bus == bus }
            if !onBus.isEmpty { Text(lk(loc("Зайняті адреси на цій шині: ") + onBus.map { String(format: "0x%02X %@", $0.addr, $0.device) }.joined(separator: ", "))).font(.caption).foregroundStyle(.secondary) }
            Text("Джерело інформації про шини: \(loc(hw.status)).").font(.caption2).foregroundStyle(.secondary)
            Button { applyI2C() } label: { Label("Налаштувати I²C-датчик", systemImage: "wand.and.stars") }.buttonStyle(.borderedProminent).disabled(s.armed || addr == nil || !ps.has(p + "_MONITOR"))
        }
    }

    func applyI2C() {
        guard let a = addr else { return }
        var changes: [String] = []
        func put(_ n: String, _ v: Double, hex: Bool = false) { if ps.has(n) { ps.write(n, v); changes.append(hex ? "\(n) = 0x\(String(Int(v), radix: 16, uppercase: true))" : "\(n) = \(fmt(v, isInt: true))") } }
        put(p + "_MONITOR", Double(preset.monitor))
        put(p + "_I2C_BUS", Double(bus))
        put(p + "_I2C_ADDR", Double(a), hex: true)
        note = loc("Записано: ") + changes.joined(separator: ", ") + loc(". Для застосування потрібне перезавантаження автопілота.")
    }

    // MARK: Живі дані екземплярів
    var liveTable: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            Text("ДАНІ ПО ЕКЗЕМПЛЯРАХ БАТАРЕЙ (BATTERY_STATUS)").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            if bats.list.isEmpty { Text("Даних немає: ввімкніть монітор і перезавантажте автопілот.").font(.caption).foregroundStyle(.secondary) }
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 3) {
                ForEach(bats.list) { b in
                    GridRow {
                        Text("Батарея \(b.id + 1)").font(.callout.weight(b.id + 1 == inst ? .semibold : .regular))
                        Text(String(format: loc("%.2f В"), b.volt)).font(.callout.monospacedDigit())
                        Text(String(format: loc("%.1f А"), b.amps)).font(.callout.monospacedDigit())
                        Text(String(format: loc("%.0f мАг"), b.mah)).font(.callout.monospacedDigit())
                        Text(lk(b.pct >= 0 ? "\(b.pct) %" : "—")).font(.callout.monospacedDigit())
                        Text(lk(b.age < 3 ? "активна" : String(localized: "немає даних \(Int(b.age)) с"))).font(.caption).foregroundStyle(b.age < 3 ? .green : .orange)
                    }
                }
            }
        }
    }
}
