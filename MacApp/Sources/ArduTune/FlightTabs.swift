import SwiftUI
import AppKit

private func distance(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
    let r = 6371000.0, p = Double.pi / 180
    let a = sin((lat2 - lat1) * p / 2), b = sin((lon2 - lon1) * p / 2)
    let h = a * a + cos(lat1 * p) * cos(lat2 * p) * b * b
    return 2 * r * asin(min(1, sqrt(h)))
}

// MARK: - Dashboard

struct DashTile: View {
    let title: String, value: String, icon: String
    var unit: String = ""
    var color: Color = .accentColor
    var rotation: Double = 0
    var body: some View {
        HStack(spacing: 8) {
            // Іконка в стилі системних налаштувань macOS: градієнтний «squircle» з білим символом
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .rotationEffect(.degrees(rotation))
                .frame(width: 26, height: 26)
                .background(
                    LinearGradient(colors: [color.opacity(0.75), color], startPoint: .top, endPoint: .bottom),
                    in: RoundedRectangle(cornerRadius: 6.5, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6.5, style: .continuous).strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
                .shadow(color: color.opacity(0.35), radius: 2, y: 1)
            VStack(alignment: .leading, spacing: 0) {
                Text(LocalizedStringKey(title)).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(LocalizedStringKey(value)).font(.system(size: 17, weight: .semibold, design: .rounded).monospacedDigit()).minimumScaleFactor(0.6).lineLimit(1)
                    if !unit.isEmpty { Text(LocalizedStringKey(unit)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1) }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

struct DashSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    private let cols = [GridItem(.adaptive(minimum: 150, maximum: 230), spacing: 6)]
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(verbatim: loc(title).uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).padding(.leading, 4)
            LazyVGrid(columns: cols, spacing: 6) { content }
        }
    }
}

struct DashboardTab: View {
    @Environment(Store.self) var s
    var body: some View {
        let t = s.t
        let home = t.homeSet ? distance(t.lat, t.lon, t.homeLat, t.homeLon) : 0
        let eff = t.distTraveled > 50 ? t.mahUsed / (t.distTraveled / 1000) : 0
        let secs = Int(t.timeInAir)
        let fix = ["Немає GPS", "Немає фіксації", "2D", "3D", "DGPS", "RTK float", "RTK fixed"]
        ScrollView {
            VStack(spacing: 10) {
                DashSection(title: String(localized: "Батарея")) {
                    Group {
                        DashTile(title: String(localized: "Напруга"), value: String(format: "%.2f", t.batteryV), icon: "bolt.fill", unit: "V", color: .purple)
                        DashTile(title: String(localized: "Струм"), value: String(format: "%.2f", t.batteryA), icon: "bolt.horizontal.fill", unit: "A", color: .orange)
                        DashTile(title: String(localized: "Потужність"), value: String(format: "%.1f", t.batteryV * t.batteryA), icon: "flame.fill", unit: "W", color: .pink)
                        DashTile(title: String(localized: "Витрачено"), value: String(format: "%.0f", t.mahUsed), icon: "battery.50", unit: "mAh", color: .mint)
                        DashTile(title: String(localized: "Ефективність"), value: String(format: "%.1f", eff), icon: "leaf.fill", unit: "mAh/km", color: .yellow)
                        DashTile(title: String(localized: "Заряд"), value: t.batteryPct >= 0 ? "\(t.batteryPct)" : "—", icon: "percent", unit: "%", color: t.batteryPct >= 0 && t.batteryPct < 25 ? .red : .green)
                    }
                }
                DashSection(title: String(localized: "Рух")) {
                    Group {
                        DashTile(title: String(localized: "Повітряна швидкість"), value: Units.speedNum(t.airSpeed), icon: "wind", unit: Units.speedLabel(en: true), color: .cyan)
                        DashTile(title: String(localized: "Наземна швидкість"), value: Units.speedNum(t.groundSpeed), icon: "speedometer", unit: Units.speedLabel(en: true), color: .green)
                        DashTile(title: String(localized: "Вертикальна швидкість"), value: String(format: "%.1f", t.climb), icon: t.climb < 0 ? "arrow.down" : "arrow.up", unit: "m/s", color: t.climb < 0 ? .orange : .green)
                        DashTile(title: String(localized: "Висота"), value: Units.altNum(t.altRel, digits: 1), icon: "arrow.up.to.line", unit: Units.altLabel(en: true), color: .blue)
                        DashTile(title: String(localized: "Курс"), value: String(format: "%.0f", t.heading), icon: "location.north.fill", unit: "°", color: .indigo, rotation: t.heading)
                        DashTile(title: String(localized: "Газ"), value: String(format: "%.0f", t.throttle), icon: "dial.medium.fill", unit: "%", color: .teal)
                    }
                }
                DashSection(title: String(localized: "Політ і навігація")) {
                    Group {
                        DashTile(title: String(localized: "Час у повітрі"), value: String(format: "%d:%02d", secs / 60, secs % 60), icon: "timer", unit: "хв:с", color: .green)
                        DashTile(title: String(localized: "Пройдено"), value: String(format: "%.1f", t.distTraveled), icon: "point.topleft.down.to.point.bottomright.curvepath", unit: "m", color: .green)
                        DashTile(title: String(localized: "До Home"), value: String(format: "%.1f", home), icon: "house.fill", unit: "m", color: .orange)
                        DashTile(title: String(localized: "До WP"), value: String(format: "%.1f", t.wpDist), icon: "mappin.and.ellipse", unit: "m", color: .red)
                    }
                }
                DashSection(title: String(localized: "GPS і зв'язок")) {
                    Group {
                        DashTile(title: String(localized: "Фіксація GPS"), value: fix[min(max(t.gpsFix, 0), fix.count - 1)], icon: "location.fill", color: t.gpsFix >= 3 ? .green : .orange)
                        DashTile(title: String(localized: "Супутники"), value: "\(t.sats)", icon: "globe", color: t.sats >= 8 ? .green : .orange)
                        DashTile(title: "HDOP", value: t.hdop > 99 ? "—" : String(format: "%.2f", t.hdop), icon: "scope", color: .cyan)
                        DashTile(title: "RX RSSI", value: String(format: "%.0f", t.rssi), icon: "dot.radiowaves.left.and.right", color: t.rssi > 0 ? .green : .red)
                    }
                }
            }
            .padding(10)
        }
    }
}

// MARK: - Actions

struct ActionsTab: View {
    @Environment(Store.self) var s
    @State private var action = "Arm"
    @State private var mode = 4
    @State private var speed = "5"
    @State private var alt = "10"
    @State private var radius = "80"
    @State private var note: String?
    @Environment(\.openWindow) private var openWindow
    var ps: ParamStore { s.ps }

    static let actions = ["Arm", "Disarm", "Force Arm", "Force Disarm", "Takeoff", "Land", "RTL", "Restart Mission", "Resume Mission"]
    var modes: [(Int, String)] {
        let o = ps.options("FLTMODE1")
        return o.isEmpty ? [(0, "Stabilize"), (2, "AltHold"), (3, "Auto"), (4, "Guided"), (5, "Loiter"), (6, "RTL"), (9, "Land")] : o
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 360, maximum: 520), spacing: 14, alignment: .top)], alignment: .leading, spacing: 14) {
                controlCard
                setpointsCard
                toolsCard
            }
            .padding(12)
            if let n = note { Text(LocalizedStringKey(n)).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.bottom, 8) }
        }
    }

    var controlCard: some View {
        Card(title: "Control", icon: "dpad", text: nil) {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Picker("", selection: $action) { ForEach(Self.actions, id: \.self) { Text(lk($0)).tag($0) } }.labelsHidden().frame(width: 200)
                    Button("Do Action") { doAction() }.buttonStyle(.borderedProminent).frame(width: 130)
                }
                GridRow {
                    Picker("", selection: $mode) { ForEach(modes, id: \.0) { Text(lk($0.1)).tag($0.0) } }.labelsHidden().frame(width: 200)
                    Button("Set Mode") { post("/cmd/mode?m=\(mode)", String(localized: "Режим: \(modes.first { $0.0 == mode }?.1 ?? "")")) }.buttonStyle(.borderedProminent).frame(width: 130)
                }
                GridRow {
                    Button("Restart Mission") { restartMission() }.frame(width: 200)
                    Button("Resume Mission") { post("/cmd/mode?m=3", "Режим Auto") }.frame(width: 130)
                }
            }
        }
    }

    var setpointsCard: some View {
        Card(title: "Setpoints", icon: "slider.horizontal.3", text: nil) {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("Home Alt (m):").frame(width: 110, alignment: .leading)
                    Button("Set Home Alt") { post("/cmd/home", "Home встановлено у поточній точці") }.buttonStyle(.borderedProminent).gridCellColumns(2)
                }
                GridRow {
                    Text("Speed (m/s):").frame(width: 110, alignment: .leading)
                    TextField("", text: $speed).textFieldStyle(.roundedBorder).frame(width: 80)
                    Button("Apply") { if let v = Double(speed) { post("/cmd/speed?v=\(v)", String(localized: "Швидкість \(v) м/с")) } }.frame(width: 80)
                }
                GridRow {
                    Text("Altitude (m):").frame(width: 110, alignment: .leading)
                    TextField("", text: $alt).textFieldStyle(.roundedBorder).frame(width: 80)
                    Button("Apply") { if let v = Double(alt) { post("/cmd/alt?v=\(v)", String(localized: "Висота \(v) м")) } }.frame(width: 80)
                }
                GridRow {
                    Text("Loiter Rad (m):").frame(width: 110, alignment: .leading)
                    TextField("", text: $radius).textFieldStyle(.roundedBorder).frame(width: 80)
                    Button("Apply") {
                        if let v = Double(radius), ps.has("WP_LOITER_RAD") { ps.write("WP_LOITER_RAD", v); note = "WP_LOITER_RAD = \(v)" }
                        else { note = String(localized: "Параметра WP_LOITER_RAD немає (лише літак)") }
                    }.frame(width: 80)
                }
            }
        }
    }

    var toolsCard: some View {
        Card(title: "Tools", icon: "wrench.and.screwdriver", text: nil) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                Button { openWindow(id: "joystick") } label: { Label(lk(s.joy.enabled ? "Joystick (активний)" : "Joystick"), systemImage: "gamecontroller").frame(maxWidth: .infinity) }
                Button { s.track.removeAll(); note = String(localized: "Трек очищено") } label: { Label("Clear Track", systemImage: "scribble").frame(maxWidth: .infinity) }
                Button { post("/reboot", "Перезавантаження автопілота") } label: { Label("Reboot", systemImage: "restart").frame(maxWidth: .infinity) }.disabled(s.armed)
                Button { post("/cmd/mode?m=5", "Режим Loiter (скасування посадки)") } label: { Label("Abort Land", systemImage: "arrow.up.to.line").frame(maxWidth: .infinity) }
            }
            .controlSize(.large)
        }
    }

    func post(_ path: String, _ msg: String) {
        EngineAPI.post(path) { ok, e in note = ok ? msg : (e == "armed" ? "Недоступно: ARMED" : "Помилка команди") }
    }

    func doAction() {
        switch action {
        case "Arm": post("/cmd/arm", "Команда ARM надіслана")
        case "Disarm": post("/cmd/disarm", "Команда DISARM надіслана")
        case "Force Arm": post("/cmd/arm?force=true", "Примусовий ARM надіслано")
        case "Force Disarm": post("/cmd/disarm?force=true", "Примусовий DISARM надіслано")
        case "Takeoff": post("/cmd/takeoff?alt=\(Double(alt) ?? 10)", String(localized: "Зліт на \(alt) м"))
        case "Land": post("/cmd/land", "Посадка")
        case "RTL": post("/cmd/rtl", "Повернення додому")
        case "Restart Mission": restartMission()
        case "Resume Mission": post("/cmd/mode?m=3", "Режим Auto")
        default: break
        }
    }

    func restartMission() { post("/cmd/mode?m=3", "Режим Auto (місія з поточної точки)") }
}

// MARK: - Messages

struct MessagesTab: View {
    @Environment(FlightStore.self) var fs
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(fs.log.enumerated()), id: \.offset) { _, m in
                        HStack(spacing: 10) {
                            Text(LocalizedStringKey(m.t)).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
                            Text(lk(sevName(m.sev))).font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                                .frame(width: 52).padding(.vertical, 3).background(sevColor(m.sev), in: RoundedRectangle(cornerRadius: 4))
                            Text(LocalizedStringKey(m.text)).font(.callout).foregroundStyle(m.sev <= 4 ? sevColor(m.sev) : .primary).textSelection(.enabled)
                            Spacer()
                        }
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(sevColor(m.sev).opacity(m.sev <= 4 ? 0.12 : 0), in: RoundedRectangle(cornerRadius: 6))
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(8)
            }
            .onChange(of: fs.log.count) { _, _ in proxy.scrollTo("end") }
            .onAppear { proxy.scrollTo("end") }
        }
    }
    func sevName(_ s: Int) -> String { ["EMERG", "ALERT", "CRIT", "ERROR", "WARN", "NOTICE", "INFO", "DEBUG"][max(0, min(s, 7))] }
    func sevColor(_ s: Int) -> Color { s <= 2 ? .red : (s == 3 ? Color(red: 0.85, green: 0.25, blue: 0.2) : (s == 4 ? .orange : (s <= 6 ? .blue : .gray))) }
}

// MARK: - PreFlight

struct PreFlightTab: View {
    @Environment(Store.self) var s
    struct Check: Identifiable { let id = UUID(); let title: String; let ok: Bool?; let detail: String }
    var ps: ParamStore { s.ps }

    var checks: [Check] {
        let t = s.t
        let vib = max(t.vibeX, t.vibeY, t.vibeZ)
        let low = ps.val("BATT_LOW_VOLT") ?? 0
        let battOK = t.batteryV > 0 && (low <= 0 || t.batteryV > low)
        let pre = (t.lastText ?? "").contains("PreArm") ? t.lastText : nil
        return [
            Check(title: String(localized: "Зв'язок із польотником"), ok: s.connected, detail: s.connected ? String(localized: "\(t.vehicle ?? "")  ·  \(Int(t.msgRate)) пак/с") : "немає"),
            Check(title: "GPS", ok: t.gpsFix >= 3 && t.sats >= 6, detail: t.gpsFix >= 3 ? String(localized: "fix \(t.gpsFix), \(t.sats) супутн.") : String(localized: "немає фіксу (\(t.sats) супутн.)")),
            Check(title: "HDOP", ok: t.hdop > 0 && t.hdop < 99 ? t.hdop < 2 : nil, detail: t.hdop > 0 && t.hdop < 99 ? String(format: "%.1f", t.hdop) : "невідомо"),
            Check(title: "EKF", ok: (t.ekfFlags & 7) == 7, detail: "flags 0x\(String(t.ekfFlags, radix: 16))"),
            Check(title: String(localized: "Home встановлено"), ok: t.homeSet, detail: t.homeSet ? String(format: "%.5f, %.5f", t.homeLat, t.homeLon) : "очікує GPS"),
            Check(title: String(localized: "Батарея"), ok: battOK, detail: String(format: "%.2f V, %d%%", t.batteryV, t.batteryPct)),
            Check(title: String(localized: "Вібрації"), ok: vib < 30, detail: String(format: "x %.1f  y %.1f  z %.1f", t.vibeX, t.vibeY, t.vibeZ)),
            Check(title: String(localized: "Сигнал приймача (RSSI)"), ok: t.rssi > 0, detail: t.rssi > 0 ? String(format: "%.0f", t.rssi) : "немає сигналу"),
            Check(title: String(localized: "Pre-arm перевірки"), ok: pre == nil, detail: pre ?? "зауважень немає"),
        ]
    }

    var body: some View {
        let c = checks
        let bad = c.filter { $0.ok == false }.count
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: bad == 0 ? "checkmark.seal.fill" : "exclamationmark.triangle.fill").foregroundStyle(bad == 0 ? Color.green : Color.red)
                    Text(lk(bad == 0 ? "Готовий до польоту" : String(localized: "Не готовий: проблем \(bad)"))).font(.headline)
                }
                ForEach(c) { ch in
                    HStack(spacing: 10) {
                        Image(systemName: ch.ok == true ? "checkmark.circle.fill" : (ch.ok == false ? "xmark.circle.fill" : "questionmark.circle")).foregroundStyle(ch.ok == true ? Color.green : (ch.ok == false ? Color.red : Color.secondary))
                        Text(LocalizedStringKey(ch.title)).frame(width: 220, alignment: .leading)
                        Text(LocalizedStringKey(ch.detail)).foregroundStyle(.secondary).font(.callout)
                        Spacer()
                    }
                    Divider().opacity(0.4)
                }
            }.padding(12)
        }
    }
}

// MARK: - Status

struct StatusTab: View {
    @Environment(FlightStore.self) var fs
    @State private var q = ""
    var shown: [FieldDTO] { let l = q.lowercased(); return l.isEmpty ? fs.fields : fs.fields.filter { $0.k.lowercased().contains(l) } }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Пошук (наприклад ATTITUDE, RAW_IMU, voltage)", text: $q).textFieldStyle(.plain)
                Text("\(shown.count) полів").font(.caption).foregroundStyle(.secondary)
            }.padding(8).background(.quaternary.opacity(0.4))
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 12)], alignment: .leading, spacing: 2) {
                    ForEach(shown, id: \.k) { f in
                        HStack {
                            Text(LocalizedStringKey(f.k)).font(.system(.caption, design: .monospaced)).foregroundStyle(.orange).lineLimit(1)
                            Spacer(minLength: 6)
                            Text(LocalizedStringKey(f.v)).font(.system(.caption, design: .monospaced)).lineLimit(1)
                        }
                    }
                }.padding(10)
            }
        }
        .onAppear { fs.startFields() }
        .onDisappear { fs.stop("fields") }
    }
}

// MARK: - Servo/Relay

struct ServoRelayTab: View {
    @Environment(Store.self) var s
    @State private var io = IOStore()
    @State private var servoCh = ["9", "10", "11", "12"]
    @State private var servoPWM = ["1500", "1500", "1500", "1500"]
    var body: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 14) {
                GroupBox("Виходи серво") {
                    VStack(spacing: 4) {
                        ForEach(0..<16, id: \.self) { i in
                            let v = io.io?.servo[i] ?? 0
                            HStack {
                                Text("\(i + 1)").font(.system(.caption, design: .monospaced)).frame(width: 20, alignment: .trailing)
                                ProgressView(value: v == 0 ? 0 : min(max(Double(v) - 800, 0), 1400), total: 1400).tint(.orange).frame(width: 220)
                                Text(lk(v == 0 ? "—" : String(v))).font(.system(.caption, design: .monospaced)).frame(width: 40, alignment: .trailing)
                            }
                        }
                    }.padding(8)
                }
                VStack(alignment: .leading, spacing: 14) {
                    GroupBox("Реле") {
                        HStack(spacing: 14) {
                            ForEach(1...6, id: \.self) { n in
                                VStack(spacing: 4) {
                                    Text("Relay \(n)").font(.caption)
                                    HStack(spacing: 4) {
                                        Button("ON") { EngineAPI.post("/cmd/relay?n=\(n - 1)&state=1") }
                                        Button("OFF") { EngineAPI.post("/cmd/relay?n=\(n - 1)&state=0") }
                                    }.controlSize(.small)
                                }
                            }
                        }.padding(8)
                    }
                    GroupBox("Серво вручну") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(0..<4, id: \.self) { i in
                                HStack {
                                    Text("Слот \(i + 1)").font(.caption).foregroundStyle(.secondary).frame(width: 50, alignment: .leading)
                                    Text("Канал"); TextField("", text: Binding(get: { servoCh[i] }, set: { servoCh[i] = $0 })).frame(width: 50).textFieldStyle(.roundedBorder)
                                    Text("PWM"); TextField("", text: Binding(get: { servoPWM[i] }, set: { servoPWM[i] = $0 })).frame(width: 70).textFieldStyle(.roundedBorder)
                                    Button("Надіслати") { EngineAPI.post("/servo/test?channel=\(Int(servoCh[i]) ?? (9 + i))&pwm=\(Int(servoPWM[i]) ?? 1500)") }
                                }
                            }
                        }.padding(8)
                    }
                    Text("Ручне керування працює лише для виходів із функцією Disabled.").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(10)
        }
        .onAppear { io.start() }
        .onDisappear { io.stop() }
    }
}

// MARK: - Aux Function

struct AuxTab: View {
    @Environment(Store.self) var s
    @State private var fn = 0
    @State private var note: String?
    var opts: [(Int, String)] { s.ps.options("RC7_OPTION") }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Виклик допоміжної функції так, ніби перемикач приймача став у положення Low / Middle / High.").font(.callout).foregroundStyle(.secondary)
            HStack {
                Picker("Функція", selection: $fn) {
                    ForEach(opts, id: \.0) { Text("\($0.1)  (\($0.0))").tag($0.0) }
                }.frame(width: 360)
                Button("Low") { send(0) }
                Button("Middle") { send(1) }
                Button("High") { send(2) }
            }
            if opts.isEmpty { Text("Список функцій з'явиться після завантаження параметрів.").font(.caption).foregroundStyle(.secondary) }
            if let n = note { Text(LocalizedStringKey(n)).font(.caption).foregroundStyle(.secondary) }
            Spacer()
        }
        .padding(14)
    }
    func send(_ pos: Int) { EngineAPI.post("/cmd/aux?fn=\(fn)&pos=\(pos)") { ok, _ in note = ok ? String(localized: "Функція \(fn), положення \(["Low", "Middle", "High"][pos])") : "Помилка" } }
}
