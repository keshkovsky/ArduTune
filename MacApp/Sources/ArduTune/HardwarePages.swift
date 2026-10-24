import SwiftUI
import MapKit
import AppKit

// MARK: - Дані з двигуна

struct RangeLive: Decodable, Identifiable { let id: Int; let orient: Int; let type: Int; let dist: Double; let min: Double; let max: Double; let src: String; let age: Double; var key: String { "\(src)\(id)\(orient)" } }
struct AdsbLive: Decodable, Identifiable { let icao: String; let callsign: String; let lat: Double; let lon: Double; let alt: Double; let heading: Double; let speed: Double; let climb: Double; let emitter: Int; let squawk: Int; let age: Double; var id: String { icao } }
struct DcMsg: Decodable { let type: Int; let count: Int }
struct DcBattery: Decodable { let voltage: Double; let current: Double; let tempC: Double; let soc: Double; let age: Double }
struct DcParamItem: Decodable, Identifiable { let index: Int; let name: String; let value: String; let type: String; var id: Int { index } }
struct DcParamsDTO: Decodable { let busy: Bool; let error: String; let items: [DcParamItem] }
struct DcNodeLive: Decodable, Identifiable { var battery: DcBattery? = nil; var paramCount: Int? = nil; var paramBusy: Bool? = nil; let id: Int; let uptime: Int; let health: Int; let mode: Int; let vendor: Int; let age: Double; let name: String; let hw: String; let sw: String; let uid: String; let hasInfo: Bool; let vcs: String; let messages: [DcMsg] }
struct DcState: Decodable { let bus: Int; let frames: Int; let transfers: Int; let lastFrameAge: Double; let nodes: [DcNodeLive] }
struct ApInfo: Decodable { let uid: String; let uid2: String; let flight: String; let os: String; let boardVersion: Int; let vendorId: Int; let productId: Int; let flightGit: String; let middleware: Int; let capabilities: Int }

@Observable @MainActor
final class LivePoller {
    var ranges: [RangeLive] = []
    var adsb: [AdsbLive] = []
    var dc: DcState?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var kind = ""
    func start(_ k: String, every ns: UInt64 = 700_000_000, bus: Int = 1) {
        stop()
        kind = k
        task = Task { @MainActor in
            switch k {
            case "rng": EngineAPI.post("/msg/interval?id=132&hz=5"); EngineAPI.post("/msg/interval?id=173&hz=5")
            case "adsb": EngineAPI.post("/msg/interval?id=246&hz=2")
            case "dc": EngineAPI.post("/dronecan/start?bus=\(bus)")
            default: break
            }
            while !Task.isCancelled {
                switch k {
                case "rng": if let l = await EngineAPI.get("/rangefinders", as: [RangeLive].self) { ranges = l }
                case "adsb": if let l = await EngineAPI.get("/adsb", as: [AdsbLive].self) { adsb = l }
                case "dc": if let d = await EngineAPI.get("/dronecan", as: DcState.self) { dc = d }
                default: break
                }
                try? await Task.sleep(nanoseconds: ns)
            }
        }
    }
    func stop() { task?.cancel(); if kind == "dc" { EngineAPI.post("/dronecan/stop") }; kind = "" }
}

// MARK: - Додаткове обладнання

struct OptionalHardwareView: View {
    @Environment(Store.self) var s
    @AppStorage("optional.tab") private var tab = "rng"
    @State private var live = LivePoller()
    @State private var note: String?
    @State private var pitch = 0.0
    @State private var roll = 0.0
    @State private var yaw = 0.0
    @State private var lastSend = Date.distantPast
    var ps: ParamStore { s.ps }

    static let rng1 = ["RNGFND1_TYPE", "RNGFND1_ORIENT", "RNGFND1_MIN_CM", "RNGFND1_MAX_CM", "RNGFND1_MIN", "RNGFND1_MAX", "RNGFND1_GNDCLEAR", "RNGFND1_ADDR", "RNGFND1_PIN",
                       "RNGFND1_SCALING", "RNGFND1_OFFSET", "RNGFND1_FUNCTION", "RNGFND1_RMETRIC", "RNGFND1_SETTLE", "RNGFND1_STOP_PIN", "RNGFND1_POS_X", "RNGFND1_POS_Y", "RNGFND1_POS_Z", "RNGFND1_RECV_ID", "RNGFND1_SNR_MIN"]
    static let cam = ["CAM1_TYPE", "CAM_TRIGG_TYPE", "CAM1_TRIGG_DIST", "CAM_TRIGG_DIST", "CAM1_DURATION", "CAM_DURATION", "CAM1_SERVO_ON", "CAM_SERVO_ON", "CAM1_SERVO_OFF", "CAM_SERVO_OFF",
                      "CAM1_RELAY_ON", "CAM_RELAY_ON", "CAM1_INTRVAL_MIN", "CAM_MIN_INTERVAL", "CAM1_AUTO_ONLY", "CAM_AUTO_ONLY", "CAM1_MAX_ROLL", "CAM_MAX_ROLL", "CAM1_FEEDBACK_PIN", "CAM_FEEDBACK_PIN", "CAM1_FEEDBACK_POL", "CAM_FEEDBACK_POL"]
    static let mnt = ["MNT1_TYPE", "MNT_TYPE", "MNT1_DEFLT_MODE", "MNT_DEFLT_MODE", "MNT1_RC_RATE", "MNT1_PITCH_MIN", "MNT1_PITCH_MAX", "MNT1_ROLL_MIN", "MNT1_ROLL_MAX", "MNT1_YAW_MIN", "MNT1_YAW_MAX"]
    static let mntExtra = ["MNT1_NEUTRAL_X", "MNT1_NEUTRAL_Y", "MNT1_NEUTRAL_Z", "MNT1_RETRACT_X", "MNT1_RETRACT_Y", "MNT1_RETRACT_Z", "MNT1_SYSID_DFLT", "MNT1_OPTIONS"]

    /// Виходи серво з заданою функцією (SERVOn_FUNCTION).
    func outputs(_ fn: [Int]) -> [Int] { (1...32).filter { n in ps.val("SERVO\(n)_FUNCTION").map { fn.contains(Int($0)) } ?? false } }

    var body: some View {
        ConfigGate {
            PageTitle(title: String(localized: "Додаткове обладнання"), subtitle: String(localized: "Далекомір, камера, підвіс, оптичний потік і датчики перешкод. Показано лише те, що є в прошивці вашого польотника."))
            Picker("", selection: $tab) {
                Text("Далекомір").tag("rng"); Text("Камера").tag("cam"); Text("Підвіс").tag("mnt"); Text("VTX").tag("vtx"); Text("Оптичний потік").tag("flow"); Text("Перешкоди").tag("prx"); Text("Парашут").tag("chute"); Text("Захват").tag("grip")
            }.pickerStyle(.segmented).labelsHidden()
            switch tab {
            case "cam": camera
            case "mnt": gimbal
            case "chute": parachute
            case "grip": gripper
            case "vtx": vtx
            case "flow":
                ParamsCard(title: String(localized: "Оптичний потік"), icon: "viewfinder", text: String(localized: "Датчик руху відносно землі для утримання позиції без GPS. Потрібен також далекомір, спрямований вниз."), params: ["FLOW_TYPE", "FLOW_ORIENT_YAW", "FLOW_POS_X", "FLOW_POS_Y", "FLOW_POS_Z", "FLOW_FXSCALER", "FLOW_FYSCALER", "FLOW_HGT_OVR"])
                if !ps.has("FLOW_TYPE") { Text("У цій прошивці немає параметрів оптичного потоку.").font(.callout).foregroundStyle(.secondary) }
            case "prx":
                ParamsCard(title: String(localized: "Датчик перешкод"), icon: "dot.radiowaves.up.forward", text: String(localized: "Лідар чи радар для обходу перешкод."), params: ["PRX1_TYPE", "PRX1_ORIENT", "PRX1_YAW_CORR", "PRX1_IGN_ANG1", "PRX1_MIN", "PRX1_MAX", "PRX_LOG_RAW", "PRX_FILT"])
                ParamsCard(title: String(localized: "Уникання перешкод"), icon: "arrow.triangle.swap", params: ["AVOID_ENABLE", "AVOID_MARGIN", "AVOID_BEHAVE", "AVOID_ALT_MIN", "AVOID_ACCEL_MAX", "AVOID_BACKUP_SPD", "AVOID_DIST_MAX"])
                if !ps.has("PRX1_TYPE") { Text("У цій прошивці немає параметрів датчиків перешкод.").font(.callout).foregroundStyle(.secondary) }
            default: rangefinder
            }
            RebootRow(text: String(localized: "Тип датчика застосовується після перезавантаження автопілота."))
        }
        .onAppear { if tab == "rng" { live.start("rng") } }
        .onChange(of: tab) { _, t in note = nil; if t == "rng" { live.start("rng") } else { live.stop() } }
        .onDisappear { live.stop() }
    }

    // MARK: Далекомір

    static func orientName(_ o: Int) -> String {
        [0: "вперед", 1: "вперед-праворуч", 2: "праворуч", 3: "назад-праворуч", 4: "назад", 5: "назад-ліворуч", 6: "ліворуч", 7: "вперед-ліворуч", 24: "вниз", 25: "вгору"][o] ?? String(localized: "кут \(o)")
    }

    var rangefinder: some View {
        VStack(alignment: .leading, spacing: 14) {
            Card(title: String(localized: "Показання зараз"), icon: "ruler", text: String(localized: "Живі дані з датчиків відстані польотника. Піднесіть руку під датчик і перевірте, що значення змінюється.")) {
                if live.ranges.isEmpty {
                    Label(lk(ps.val("RNGFND1_TYPE").map { $0 == 0 } ?? true ? "Далекомір вимкнено (RNGFND1_TYPE = 0). Оберіть тип нижче й перезавантажте автопілот." : "Даних поки немає. Перевірте підключення датчика й тип."), systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(live.ranges.filter { $0.age < 5 }, id: \.key) { r in
                    HStack(spacing: 14) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(String(format: loc("%.2f м"), r.dist)).font(.title2.monospacedDigit().weight(.semibold))
                            Text("\(Self.orientName(r.orient)) · \(r.src == "RANGEFINDER" ? "RANGEFINDER" : "датчик \(r.id)")").font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(width: 200, alignment: .leading)
                        if r.max > r.min {
                            ProgressView(value: min(max((r.dist - r.min) / (r.max - r.min), 0), 1)).tint(r.dist < r.min || r.dist > r.max ? .orange : .accentColor)
                            Text(String(format: loc("%.1f…%.0f м"), r.min, r.max)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            ParamsCard(title: String(localized: "Датчик 1"), icon: "ruler", text: String(localized: "Тип, напрямок і межі вимірювання."), params: Self.rng1)
            AdvancedSection(key: "rng.advanced", subtitle: String(localized: "Другий і наступні далекоміри.")) {
                ForEach(2...4, id: \.self) { n in
                    ParamsCard(title: String(localized: "Датчик \(n)"), icon: "ruler", params: Self.rng1.map { $0.replacingOccurrences(of: "RNGFND1_", with: "RNGFND\(n)_") })
                }
                ParamsCard(title: String(localized: "Загальне"), icon: "gearshape", params: ["RNGFND_LANDING", "RNGFND_FILT", "RNGFND_TIMEOUT"])
            }
        }
    }

    // MARK: Камера

    var camera: some View {
        let camOut = outputs([10])
        return VStack(alignment: .leading, spacing: 14) {
            Card(title: String(localized: "Перевірка спуску"), icon: "camera.shutter.button", text: String(localized: "Надсилає команду «зробити кадр». Камера має зробити знімок (колеса й гвинти не обертаються).")) {
                HStack {
                    Button { EngineAPI.post("/cmd/camtrigger") { ok, _ in note = ok ? "Команду надіслано" : "Не вдалося надіслати" } } label: { Label("Зробити кадр", systemImage: "camera.fill") }.disabled(!s.connected)
                    if let n = note { Text(LocalizedStringKey(n)).font(.caption).foregroundStyle(.secondary) }
                }
                if camOut.isEmpty { Label("Жоден вихід серво не має функції «Camera trigger» (SERVOn_FUNCTION = 10). Якщо камера керується по PWM, призначте її у вкладці Servo Output.", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
                else { Label(lk(loc("Спуск камери виведено на: ") + camOut.map { "SERVO\($0)" }.joined(separator: ", ")), systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary) }
            }
            ParamsCard(title: String(localized: "Керування камерою"), icon: "camera", text: String(localized: "Як апарат спускає затвор і як часто."), params: Self.cam)
            if !Self.cam.contains(where: { ps.has($0) }) { Text("У цій прошивці немає параметрів керування камерою.").font(.callout).foregroundStyle(.secondary) }
            Label("Камера також спускається командами місії (Mission): «Фото кожні N м» і «Керування камерою».", systemImage: "map").font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Парашут

    static let chute = ["CHUTE_ENABLED", "CHUTE_TYPE", "CHUTE_SERVO_ON", "CHUTE_SERVO_OFF", "CHUTE_ALT_MIN", "CHUTE_DELAY_MS", "CHUTE_CRT_SINK", "CHUTE_OPTIONS"]

    var parachute: some View {
        let out = outputs([27])
        return VStack(alignment: .leading, spacing: 14) {
            if !ps.has("CHUTE_ENABLED") {
                ContentUnavailableView { Label { Text("Парашут недоступний") } icon: { CardIcon(name: "custom:parachute").scaleEffect(2.4) } } description: { Text("У цій прошивці немає параметрів парашута (CHUTE_*). Парашут підтримують Copter і Plane.") }
            } else {
                Card(title: String(localized: "Парашут"), icon: "custom:parachute", text: String(localized: "Аварійний випуск за каналом пульта, командою або автоматично при критичній швидкості падіння. Перед польотом перевірте механізм без гвинтів і зі знятим парашутом.")) {
                    if (ps.val("CHUTE_ENABLED") ?? 0) == 0 {
                        Label("Парашут вимкнено (CHUTE_ENABLED = 0). Увімкніть його й перезавантажте автопілот.", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                    }
                    if out.isEmpty { Label("Жоден вихід серво не має функції «Parachute» (SERVOn_FUNCTION = 27). Призначте її у вкладці Servo Output (для типу «Servo»), або використайте реле.", systemImage: "info.circle").font(.caption).foregroundStyle(.secondary) }
                    else { Label(lk(loc("Випуск парашута виведено на: ") + out.map { "SERVO\($0)" }.joined(separator: ", ")), systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary) }
                    Label("Для випуску за каналом пульта призначте йому функцію «Parachute Release» (RCx_OPTION = 22), «Parachute Enable» (21) або «Parachute 3pos» (23).", systemImage: "dot.radiowaves.left.and.right").font(.caption).foregroundStyle(.secondary)
                }
                ParamsCard(title: String(localized: "Механізм і умови випуску"), icon: "custom:parachute", text: String(localized: "Тип пристрою, положення серво, мінімальна висота, затримка й критична швидкість падіння."), params: Self.chute)
            }
        }
    }

    // MARK: Захват (gripper)

    static let grip = ["GRIP_ENABLE", "GRIP_TYPE", "GRIP_GRAB", "GRIP_RELEASE", "GRIP_NEUTRAL", "GRIP_REGRAB", "GRIP_AUTOCLOSE", "GRIP_CAN_ID"]

    var gripper: some View {
        let out = outputs([28])
        return VStack(alignment: .leading, spacing: 14) {
            if !ps.has("GRIP_ENABLE") {
                ContentUnavailableView { Label { Text("Захват недоступний") } icon: { CardIcon(name: "custom:gripper").scaleEffect(2.4) } } description: { Text("У цій прошивці немає параметрів захвату (GRIP_*).") }
            } else {
                Card(title: String(localized: "Захват (Gripper)"), icon: "custom:gripper", text: String(localized: "Серво- або електромагнітний захват для вантажу. Керується каналом пульта, командою або з місії.")) {
                    if (ps.val("GRIP_ENABLE") ?? 0) == 0 {
                        Label("Захват вимкнено (GRIP_ENABLE = 0). Увімкніть його й перезавантажте автопілот.", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                    }
                    HStack {
                        Button { EngineAPI.post("/cmd/gripper?action=1") { ok, _ in note = ok ? "Команду «захопити» надіслано" : "Не вдалося надіслати" } } label: { Label { Text("Захопити") } icon: { CardIcon(name: "custom:gripper.closed") } }.disabled(!s.connected)
                        Button { EngineAPI.post("/cmd/gripper?action=0") { ok, _ in note = ok ? "Команду «відпустити» надіслано" : "Не вдалося надіслати" } } label: { Label { Text("Відпустити") } icon: { CardIcon(name: "custom:gripper") } }.disabled(!s.connected)
                        if let n = note { Text(LocalizedStringKey(n)).font(.caption).foregroundStyle(.secondary) }
                    }
                    if out.isEmpty { Label("Жоден вихід серво не має функції «Gripper» (SERVOn_FUNCTION = 28). Призначте її у вкладці Servo Output (для типу «Servo»).", systemImage: "info.circle").font(.caption).foregroundStyle(.secondary) }
                    else { Label(lk(loc("Захват виведено на: ") + out.map { "SERVO\($0)" }.joined(separator: ", ")), systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary) }
                    Label("Для керування каналом пульта призначте йому функцію «Gripper» (RCx_OPTION = 19). У місії є команда «Захват» (DO_GRIPPER).", systemImage: "dot.radiowaves.left.and.right").font(.caption).foregroundStyle(.secondary)
                }
                ParamsCard(title: String(localized: "Тип і положення серво"), icon: "custom:gripper", text: String(localized: "Тип захвату та значення PWM для «захопити», «відпустити» й нейтралі."), params: Self.grip)
            }
        }
    }

    // MARK: Відеопередавач (VTX)

    /// Стандартні 5,8 ГГц таблиці: індекс = значення VTX_BAND, у рядку 8 каналів (MHz).
    static let vtxBands: [(code: Int, name: String, freqs: [Int])] = [
        (0, "A", [5865, 5845, 5825, 5805, 5785, 5765, 5745, 5725]),
        (1, "B", [5733, 5752, 5771, 5790, 5809, 5828, 5847, 5866]),
        (2, "E", [5705, 5685, 5665, 5645, 5885, 5905, 5925, 5945]),
        (3, "F (Airwave)", [5740, 5760, 5780, 5800, 5820, 5840, 5860, 5880]),
        (4, "Race", [5658, 5695, 5732, 5769, 5806, 5843, 5880, 5917]),
        (5, "Low Race", [5362, 5399, 5436, 5473, 5510, 5547, 5584, 5621]),
    ]
    static let vtxProtocols: [(Int, String)] = [(37, "SmartAudio"), (44, "IRC Tramp")]
    static let vtxPowerSteps = [25, 100, 200, 400, 600, 800, 1000]

    var vtxPorts: [Int] { (1...8).filter { ps.has("SERIAL\($0)_PROTOCOL") } }
    /// Порт, на якому вже призначено протокол VTX (SmartAudio чи Tramp).
    var vtxAssigned: (port: Int, proto: Int)? {
        for n in vtxPorts { let p = Int(ps.val("SERIAL\(n)_PROTOCOL") ?? -1); if p == 37 || p == 44 { return (n, p) } }
        return nil
    }
    func setVTXProtocol(_ proto: Int, port: Int?) {
        if let a = vtxAssigned, a.port != port || proto == 0 { ps.write("SERIAL\(a.port)_PROTOCOL", -1) }
        guard proto != 0, let n = port ?? vtxAssigned?.port ?? vtxPorts.first(where: { Int(ps.val("SERIAL\($0)_PROTOCOL") ?? -1) == -1 }) else { return }
        ps.write("SERIAL\(n)_PROTOCOL", Double(proto))
        note = String(localized: "Порт SERIAL\(n) налаштовано: \(proto == 37 ? "SmartAudio" : "IRC Tramp"). Перезавантажте автопілот і вмикніть VTX_ENABLE.")
    }

    var vtx: some View {
        let vband = Int(ps.val("VTX_BAND") ?? 0), vch = Int(ps.val("VTX_CHANNEL") ?? 0), vfreq = Int(ps.val("VTX_FREQ") ?? 0)
        let vpow = Int(ps.val("VTX_POWER") ?? 0), vmax = Int(ps.val("VTX_MAX_POWER") ?? 0)
        let enabled = (ps.val("VTX_ENABLE") ?? 0) > 0
        let optBits = Int(ps.val("VTX_OPTIONS") ?? 0)
        let tableFreq = Self.vtxBands.first { $0.code == vband }.flatMap { $0.freqs.indices.contains(vch) ? $0.freqs[vch] : nil }
        let aux = (1...16).filter { Int(ps.val("RC\($0)_OPTION") ?? 0) == 94 }
        return VStack(alignment: .leading, spacing: 14) {
            if !ps.has("VTX_ENABLE") {
                Label("У цій прошивці немає параметрів VTX (AP_VideoTX). Відеопередавач, керований з автопілота, доступний у збірках із підтримкою SmartAudio/Tramp.", systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
            }
            Card(title: String(localized: "Відеопередавач (VTX)"), icon: "video.badge.waveform", text: String(localized: "Автопілот може керувати каналом, частотою й потужністю передавача через SmartAudio чи IRC Tramp (дротовий порт) або через приймач CRSF/ELRS.")) {
                Toggle("Керування VTX з автопілота увімкнено", isOn: Binding(get: { enabled }, set: { ps.write("VTX_ENABLE", $0 ? 1 : 0); note = String(localized: "VTX_ENABLE записано. Для застосування перезавантажте автопілот.") }))
                    .toggleStyle(.switch).disabled(s.armed || !ps.has("VTX_ENABLE"))
                Divider()
                HStack(spacing: 12) {
                    Text("Протокол").font(.callout).frame(width: 90, alignment: .leading)
                    Picker("", selection: Binding(get: { vtxAssigned?.proto ?? 0 }, set: { setVTXProtocol($0, port: vtxAssigned?.port) })) {
                        Text("не використовується").tag(0)
                        ForEach(Self.vtxProtocols, id: \.0) { Text(lk($0.1)).tag($0.0) }
                    }.labelsHidden().frame(width: 220).disabled(s.armed)
                    Text("Порт").font(.callout)
                    Picker("", selection: Binding(get: { vtxAssigned?.port ?? 0 }, set: { n in setVTXProtocol(vtxAssigned?.proto ?? 37, port: n) })) {
                        Text("—").tag(0)
                        ForEach(vtxPorts, id: \.self) { n in
                            let cur = Int(ps.val("SERIAL\(n)_PROTOCOL") ?? -1)
                            Text("SERIAL\(n)" + (cur == -1 || cur == 37 || cur == 44 ? "" : String(localized: "  (зараз: \(ps.options("SERIAL\(n)_PROTOCOL").first { $0.0 == cur }?.1 ?? "?"))"))).tag(n)
                        }
                    }.labelsHidden().frame(width: 280).disabled(s.armed || vtxAssigned == nil)
                }
                Text("SmartAudio і Tramp підключаються до TX вибраного порту й керуються автопілотом. Якщо VTX керується через приймач CRSF/ELRS, протокол порту лишається RCIN, а в «Параметрах VTX» нижче вмикається «Ignore status updates in CRSF».")
                    .font(.caption).foregroundStyle(.secondary)
                if let n = note { Label(LocalizedStringKey(n), systemImage: "info.circle.fill").font(.callout).foregroundStyle(.orange) }
            }
            if ps.has("VTX_ENABLE") {
                // перевірка конфігурації
                VStack(alignment: .leading, spacing: 4) {
                    if !enabled { check("VTX_ENABLE = 0: автопілот не керуватиме передавачем.", .orange) }
                    if enabled && vtxAssigned == nil { check("Жоден послідовний порт не має протоколу SmartAudio/Tramp. Це нормально лише для керування через CRSF/ELRS.", .orange) }
                    if vmax > 0 && vpow > vmax { check(String(localized: "VTX_POWER (\(vpow) мВт) перевищує VTX_MAX_POWER (\(vmax) мВт): значення буде обмежено."), .orange) }
                    if let t = tableFreq, vfreq != 0, vfreq != t { check(String(localized: "VTX_FREQ (\(vfreq) МГц) не збігається з частотою вибраних діапазону й каналу (\(t) МГц)."), .orange) }
                    if enabled && vtxAssigned != nil && vfreq != 0 { check("Конфігурація виглядає узгодженою.", .green) }
                }
                Card(title: String(localized: "Канал і частота"), icon: "dot.radiowaves.left.and.right", text: String(localized: "Клацніть клітинку таблиці, щоб вибрати діапазон і канал. Частота обчислюється за стандартною таблицею 5,8 ГГц; у польотник пишуться VTX_BAND і VTX_CHANNEL.")) {
                    Grid(alignment: .center, horizontalSpacing: 6, verticalSpacing: 6) {
                        GridRow {
                            Text("").frame(width: 100)
                            ForEach(1...8, id: \.self) { Text("К\($0)").font(.caption.weight(.semibold)).foregroundStyle(.secondary).frame(width: 62) }
                        }
                        ForEach(Self.vtxBands, id: \.code) { b in
                            GridRow {
                                Text(LocalizedStringKey(b.name)).font(.callout.weight(.semibold)).frame(width: 100, alignment: .leading)
                                ForEach(b.freqs.indices, id: \.self) { c in
                                    let on = vband == b.code && vch == c
                                    Button {
                                        ps.write("VTX_BAND", Double(b.code)); ps.write("VTX_CHANNEL", Double(c)); ps.write("VTX_FREQ", Double(b.freqs[c]))
                                    } label: {
                                        Text(lk(String(b.freqs[c]))).font(.system(.caption, design: .monospaced).weight(on ? .bold : .regular)).frame(width: 62, height: 28)
                                            .background(on ? Color.accentColor : Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                            .foregroundStyle(on ? Color.white : Color.primary)
                                    }.buttonStyle(.plain).disabled(s.armed)
                                }
                            }
                        }
                    }
                    HStack(spacing: 14) {
                        Text("Частота, МГц").font(.callout); VTXRawField(name: "VTX_FREQ", width: 90, lo: 700, hi: 10000)
                        Text("Діапазон").font(.callout); OptionPicker(name: "VTX_BAND", width: 170)
                        Text("Канал").font(.callout); ParamField(name: "VTX_CHANNEL", width: 60)
                    }
                    Text("Частоту можна ввести будь-яку (наприклад 6000–8000 МГц): прошивка не обмежує VTX_FREQ, обмеження задає сам передавач. Значення поза діапазоном метаданих (1000–6000) позначаються оранжевим, але записуються.").font(.caption).foregroundStyle(.secondary)
                }
                Card(title: String(localized: "Потужність"), icon: "bolt.horizontal", text: String(localized: "Вихідна потужність у мВт. Не вмикайте більшу потужність без антени й охолодження, а також дотримуйтесь місцевих обмежень.")) {
                    HStack(spacing: 8) {
                        ForEach(Self.vtxPowerSteps.filter { vmax <= 0 || $0 <= vmax }, id: \.self) { mw in
                            Button { ps.write("VTX_POWER", Double(mw)) } label: {
                                Text(lk(String(mw))).font(.system(.callout, design: .monospaced).weight(vpow == mw ? .bold : .regular)).frame(minWidth: 52).padding(.vertical, 5)
                                    .background(vpow == mw ? Color.accentColor : Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                                    .foregroundStyle(vpow == mw ? Color.white : Color.primary)
                            }.buttonStyle(.plain).disabled(s.armed)
                        }
                        Text("мВт").font(.caption).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 14) {
                        Text("Потужність").font(.callout); VTXRawField(name: "VTX_POWER", width: 80, lo: 1, hi: 10000)
                        Text("Максимум").font(.callout); VTXRawField(name: "VTX_MAX_POWER", width: 80, lo: 1, hi: 10000)
                        Text("мВт").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Card(title: String(localized: "Режими й керування з пульта"), icon: "switch.2", text: String(localized: "Pitmode знижує потужність до мінімуму (для роботи на столі й перед стартом).")) {
                    Toggle("Pitmode (мінімальна потужність)", isOn: Binding(get: { optBits & 1 != 0 }, set: { ps.write("VTX_OPTIONS", Double($0 ? optBits | 1 : optBits & ~1)) })).toggleStyle(.checkbox).disabled(s.armed)
                    Toggle("Pitmode до ARM", isOn: Binding(get: { optBits & 2 != 0 }, set: { ps.write("VTX_OPTIONS", Double($0 ? optBits | 2 : optBits & ~2)) })).toggleStyle(.checkbox).disabled(s.armed)
                    Toggle("Pitmode після DISARM", isOn: Binding(get: { optBits & 4 != 0 }, set: { ps.write("VTX_OPTIONS", Double($0 ? optBits | 4 : optBits & ~4)) })).toggleStyle(.checkbox).disabled(s.armed)
                    Divider()
                    if aux.isEmpty {
                        Label("Жоден канал пульта не має функції «VTX Power» (RCn_OPTION = 94). Призначте її на перемикач, щоб міняти потужність у польоті.", systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Label(lk(loc("Потужність з пульта: ") + aux.map { String(localized: "канал \($0)") }.joined(separator: ", ") + " (RCn_OPTION = 94)"), systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Призначити на канал").font(.callout)
                        Picker("", selection: Binding(get: { aux.first ?? 0 }, set: { n in
                            for c in aux where c != n { ps.write("RC\(c)_OPTION", 0) }
                            if n > 0 { ps.write("RC\(n)_OPTION", 94) }
                        })) { Text("не призначено").tag(0); ForEach(5...16, id: \.self) { Text("Канал \($0)").tag($0) } }.labelsHidden().frame(width: 180).disabled(s.armed)
                    }
                }
                ParamsCard(title: String(localized: "Параметри VTX"), icon: "slider.horizontal.3", text: String(localized: "Усі прапорці параметра VTX_OPTIONS (SmartAudio, Tramp, CRSF)."), params: ["VTX_OPTIONS"])
            }
        }
    }

    func check(_ t: String, _ c: Color) -> some View {
        Label(LocalizedStringKey(t), systemImage: c == .green ? "checkmark.circle.fill" : "exclamationmark.triangle.fill").font(.callout).foregroundStyle(c)
    }

    // MARK: Підвіс

    func sendMount() {
        guard Date().timeIntervalSince(lastSend) > 0.12 else { return }
        lastSend = Date()
        EngineAPI.post("/cmd/mount?pitch=\(pitch)&roll=\(roll)&yaw=\(yaw)")
    }

    var gimbal: some View {
        let outs = outputs([6, 7, 8])
        return VStack(alignment: .leading, spacing: 14) {
            Card(title: String(localized: "Керування підвісом"), icon: "camera.aperture", text: String(localized: "Пряме керування кутами з комп'ютера (режим MAVLink). Для перевірки напрямків і меж ходу.")) {
                HStack(spacing: 8) {
                    mode("Нейтраль", 1, "arrow.up.left.and.arrow.down.right"); mode("Втягнути", 0, "arrow.down.to.line"); mode("З пульта", 3, "dot.radiowaves.left.and.right"); mode("На GPS-точку", 4, "scope")
                }
                slider("Тангаж", $pitch, -90...45)
                slider("Поворот", $yaw, -180...180)
                slider("Крен", $roll, -45...45)
                HStack {
                    Button("Центр") { pitch = 0; roll = 0; yaw = 0; sendMount() }.controlSize(.small)
                    Text("Рух повзунків одразу надсилає кути (режим MAVLink).").font(.caption).foregroundStyle(.secondary)
                }
                if outs.isEmpty { Label("Жоден вихід серво не призначено підвісу (SERVOn_FUNCTION = 6 крен, 7 тангаж, 8 поворот). Для підвісів із власним контролером (Storm32, SIYI тощо) це нормально.", systemImage: "info.circle").font(.caption).foregroundStyle(.secondary) }
                else { Label(lk(loc("Виходи підвісу: ") + outs.map { "SERVO\($0)" }.joined(separator: ", ")), systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary) }
            }
            .disabled(!s.connected)
            ParamsCard(title: String(localized: "Підвіс"), icon: "camera.aperture", text: String(localized: "Тип підвісу, режим за замовчуванням і межі ходу."), params: Self.mnt)
            ParamsCard(title: String(localized: "Нейтральне й втягнуте положення"), icon: "arrow.up.left.and.arrow.down.right", params: Self.mntExtra)
            if !Self.mnt.contains(where: { ps.has($0) }) { Text("У цій прошивці немає параметрів підвісу.").font(.callout).foregroundStyle(.secondary) }
        }
    }

    func mode(_ t: String, _ m: Int, _ icon: String) -> some View {
        Button { EngineAPI.post("/cmd/mountmode?mode=\(m)") } label: { Label(LocalizedStringKey(t), systemImage: icon).font(.caption) }.controlSize(.small)
    }
    func slider(_ title: String, _ v: Binding<Double>, _ r: ClosedRange<Double>) -> some View {
        HStack {
            Text(LocalizedStringKey(title)).frame(width: 70, alignment: .leading)
            Slider(value: Binding(get: { v.wrappedValue }, set: { v.wrappedValue = $0; sendMount() }), in: r)
            Text(String(format: "%.0f°", v.wrappedValue)).font(.caption.monospacedDigit()).frame(width: 46, alignment: .trailing)
        }
    }
}

/// Поле параметра VTX без обмеження діапазоном із метаданих (там 1000–6000 МГц і 1–1000 мВт): вводиться будь-яке значення в розумних межах `lo…hi`.
/// Поза діапазоном метаданих значення підсвічується оранжевим: прошивка його не обмежує, але передавач має сам підтримувати частоту й потужність.
struct VTXRawField: View {
    @Environment(Store.self) var s
    let name: String
    var width: CGFloat = 80
    let lo: Double, hi: Double
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        let cur = s.ps.val(name)
        let meta = s.ps.meta[name]
        let v = Double(text.replacingOccurrences(of: ",", with: "."))
        let outMeta = v.map { x in (meta?.min.map { x < $0 } ?? false) || (meta?.max.map { x > $0 } ?? false) } ?? false
        TextField("", text: $text)
            .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
            .font(.system(.body, design: .monospaced)).frame(width: width)
            .focused($focused)
            .disabled(s.armed || cur == nil)
            .foregroundStyle(v == nil || v! < lo || v! > hi ? Color.red : (outMeta ? Color.orange : .primary))
            .onSubmit { commit(v) }
            .onAppear { sync() }
            .onChange(of: cur) { _, _ in if !focused { sync() } }
            .help(lk(outMeta ? String(localized: "Поза діапазоном метаданих ArduPilot (\(meta?.min.map { fmt($0, isInt: true) } ?? "")…\(meta?.max.map { fmt($0, isInt: true) } ?? "")): прошивка не обмежує, але передавач має це підтримувати") : "\(loc(name)): \(Int(lo))…\(Int(hi))"))
    }
    func sync() { if let c = s.ps.val(name) { text = fmt(c, isInt: true) } }
    func commit(_ v: Double?) {
        guard let v, v >= lo, v <= hi else { sync(); return }
        if v != s.ps.val(name) { s.ps.write(name, v.rounded()) }
    }
}

// MARK: - HW ID

struct HWRow: Identifiable {
    let id: String; let group: String; let slot: String; let name: String; let bus: String; let detail: String; let raw: Int; let devType: Int; let dronecanNode: Int?
}

let airspeedTypes: [Int: String] = [0x01: "SITL", 0x02: "MS4525", 0x03: "MS5525", 0x04: "DLVR", 0x05: "MSP", 0x06: "SDP3X", 0x07: "DroneCAN", 0x08: "аналоговий", 0x09: "NMEA", 0x0A: "ASP5033"]

func hwRows(_ ps: ParamStore) -> [HWRow] {
    let defs: [(String, String, String, [Int: String]?)] = [
        (#"^INS_ACC([0-9]?)_ID$"#, "Акселерометр", "move.3d", imuTypes), (#"^INS_GYR([0-9]?)_ID$"#, "Гіроскоп", "gyroscope", imuTypes),
        (#"^BARO([0-9]?)_DEVID$"#, "Барометр", "barometer", baroTypes), (#"^COMPASS_DEV_ID([0-9]?)$"#, "Компас", "safari", compassTypes),
        (#"^ARSPD([0-9]?)_DEVID$"#, "Датчик швидкості", "wind", airspeedTypes), (#"^RNGFND([0-9])_DEVID$"#, "Далекомір", "ruler", nil),
        (#"^FLOW_DEVID$"#, "Оптичний потік", "viewfinder", nil), (#"^GPS([0-9]?)_DEVID$"#, "GPS", "location", nil),
    ]
    var rows: [HWRow] = []
    for (pattern, group, _, table) in defs {
        guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
        for p in ps.params where Int(p.value) != 0 {
            let r = NSRange(p.name.startIndex..., in: p.name)
            guard let m = re.firstMatch(in: p.name, range: r) else { continue }
            var slot = "1"
            if m.numberOfRanges > 1, let sr = Range(m.range(at: 1), in: p.name), !p.name[sr].isEmpty { slot = String(p.name[sr]) }
            let d = DevID(raw: Int(p.value))
            let nm = table?[d.devType] ?? String(format: loc("тип 0x%02X"), d.devType)
            rows.append(HWRow(id: p.name, group: group, slot: slot, name: nm, bus: d.busName, detail: d.detail, raw: Int(p.value), devType: d.devType, dronecanNode: d.busType == 3 ? d.address : nil))
        }
    }
    return rows
}

/// Назва плати: з USB-дескриптора (надійно) і повідомлень запуску польотника (прошивка, ID мікроконтролера).
struct BoardGuess {
    var board = ""; var mcuID = ""; var firmware = ""; var usbSerial = ""
    /// Для порівняння з платформами каталогу: без регістру, суфікса завантажувача й розділювачів
    /// (USB-назва плати може бути «MatekH743_bdshot», а тека каталогу «MatekH743-bdshot»).
    static func norm(_ s: String) -> String {
        var t = s.lowercased()
        for suf in ["-bl", "_bl"] where t.hasSuffix(suf) { t = String(t.dropLast(suf.count)) }
        return t.filter { $0.isLetter || $0.isNumber }
    }
    var key: String { Self.norm(board) }
}
struct UsbDev: Decodable { let product: String; let vendor: String; let serial: String; let vid: Int; let pid: Int; let ports: [String] }
struct UsbBoards: Decodable { let current: String?; let devices: [UsbDev] }

func guessBoard() async -> BoardGuess {
    var g = BoardGuess()
    if let u = await EngineAPI.get("/board", as: UsbBoards.self) {
        let dev = u.devices.first { d in u.current.map { d.ports.contains($0) } ?? false }
            ?? u.devices.first { $0.vendor.localizedCaseInsensitiveContains("ardupilot") || $0.vendor.localizedCaseInsensitiveContains("px4") }
        if let dev { g.board = dev.product; g.usbSerial = dev.serial }
    }
    if let l = await EngineAPI.get("/log", as: LogDTO.self) {
        for it in l.items {
            let t = it.text.trimmingCharacters(in: .whitespaces)
            if g.firmware.isEmpty, t.hasPrefix("Ardu") || t.hasPrefix("Rover") { g.firmware = t }
            if g.mcuID.isEmpty, let re = try? NSRegularExpression(pattern: #"^(\S+) ([0-9A-F]{8}) ([0-9A-F]{8}) ([0-9A-F]{8})$"#), let m = re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)),
               let br = Range(m.range(at: 1), in: t) {
                if g.board.isEmpty { g.board = String(t[br]) }
                g.mcuID = t.split(separator: " ").dropFirst().joined(separator: " ")
            }
        }
    }
    return g
}

struct HWIDView: View {
    @Environment(Store.self) var s
    @State private var info: ApInfo?
    @State private var infoError: String?
    @State private var guess = BoardGuess()
    @State private var loading = false
    @State private var copied = false

    var body: some View {
        ConfigGate {
            PageTitle(title: String(localized: "Апаратне забезпечення (HW ID)"), subtitle: String(localized: "Що це за плата і які датчики (чипи) підключені: шина, адреса й тип кожного пристрою."))
            boardCard
            let rows = hwRows(s.ps)
            Card(title: String(localized: "Датчики"), icon: "cpu", text: String(localized: "Список заповнюється з параметрів *_ID / *_DEVID. Тип чипа визначається за таблицями ArduPilot; невідомі типи показано кодом.")) {
                if rows.isEmpty { Text("Немає даних про датчики.").foregroundStyle(.secondary) }
                VStack(spacing: 0) {
                    ForEach(rows) { r in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 0) {
                                Text(lk(r.group + (rows.filter { $0.group == r.group }.count > 1 ? " \(r.slot)" : ""))).font(.callout.weight(.medium))
                                Text(LocalizedStringKey(r.id)).font(.system(.caption2, design: .monospaced)).foregroundStyle(.tertiary)
                            }
                            .frame(width: 190, alignment: .leading)
                            Text(LocalizedStringKey(r.name)).font(.callout).frame(width: 130, alignment: .leading)
                            Text(LocalizedStringKey(r.detail)).font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                            Text(String(format: "0x%06X", r.raw)).font(.system(.caption, design: .monospaced)).foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 5)
                        Divider().opacity(0.5)
                    }
                }
            }
        }
        .task(id: "\(s.connected)|\(s.t.port ?? "")|\(s.t.vehicle ?? "")|\(s.t.metaSource ?? "")") { await load() }
    }

    func load() async {
        loading = true; defer { loading = false }
        info = nil; infoError = nil; guess = BoardGuess()
        guess = await guessBoard()
        if let d = try? await EngineAPI.data("/autopilot") { info = try? JSONDecoder().decode(ApInfo.self, from: d); infoError = info == nil ? "Не вдалося розібрати відповідь" : nil }
        else { infoError = String(localized: "Автопілот не відповів на запит версії") }
    }

    var boardCard: some View {
        Card(title: String(localized: "Плата й прошивка"), icon: "cpu", text: nil) {
            if loading && info == nil { ProgressView().controlSize(.small) }
            VStack(alignment: .leading, spacing: 6) {
                if !guess.board.isEmpty { row("Плата", guess.board) }
                if !guess.firmware.isEmpty { row("Прошивка", guess.firmware) }
                if let i = info {
                    row("Версія", i.flight + (i.flightGit.isEmpty ? "" : " (\(i.flightGit))"))
                    row("ОС (ChibiOS)", i.os)
                    row("Vendor / Product ID", String(format: "0x%04X / 0x%04X", i.vendorId, i.productId))
                    row("Версія плати", "\(i.boardVersion)")
                    if i.uid != "0000000000000000" { row("UID", i.uid) }
                    if i.uid2.contains(where: { $0 != "0" }) { row("UID (довгий)", i.uid2) }
                }
                if !guess.mcuID.isEmpty { row("ID мікроконтролера", guess.mcuID) }
                if !guess.usbSerial.isEmpty { row("USB-серійний номер", guess.usbSerial) }
                if let e = infoError, info == nil { Label(LocalizedStringKey(e), systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
            }
            HStack {
                Button { copyAll(); copied = true } label: { Label(lk(copied ? "Скопійовано" : "Копіювати для звіту"), systemImage: "doc.on.doc") }.controlSize(.small)
                Button { Task { await load() } } label: { Label("Оновити", systemImage: "arrow.clockwise") }.controlSize(.small)
            }
        }
    }

    func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(LocalizedStringKey(k)).font(.callout).foregroundStyle(.secondary).frame(width: 170, alignment: .leading)
            Text(LocalizedStringKey(v)).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
            Spacer()
        }
    }

    func copyAll() {
        var t = "ArduTune: звіт про апаратне забезпечення\n"
        if !guess.board.isEmpty { t += String(localized: "Плата: \(guess.board)\n") }
        if !guess.firmware.isEmpty { t += String(localized: "Прошивка: \(guess.firmware)\n") }
        if let i = info { t += String(localized: "Версія: \(i.flight) \(i.flightGit)\nОС: \(i.os)\nVendor/Product: \(String(format: "0x%04X/0x%04X", i.vendorId, i.productId))\nUID: \(i.uid) \(i.uid2)\n") }
        for r in hwRows(s.ps) { t += "\(r.group) \(r.slot): \(loc(r.name)), \(loc(r.detail)) [\(String(format: "0x%06X", r.raw))]\n" }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(t, forType: .string)
    }
}

// MARK: - ADS-B

struct ADSBView: View {
    @Environment(Store.self) var s
    @State private var live = LivePoller()
    var ps: ParamStore { s.ps }

    static let main = ["ADSB_TYPE", "ADSB_LIST_MAX", "ADSB_LIST_RADIUS", "ADSB_ICAO_ID", "ADSB_EMIT_TYPE", "ADSB_LEN_WIDTH", "ADSB_OFFSET_LAT", "ADSB_OFFSET_LON", "ADSB_RF_SELECT", "ADSB_SQUAWK", "ADSB_RF_CAPABLE", "ADSB_ICAO_SPECL", "ADSB_OPTIONS", "ADSB_LOG"]
    static let avoid = ["AVD_ENABLE", "AVD_F_ACTION", "AVD_W_ACTION", "AVD_F_RCVRY", "AVD_OBS_MAX", "AVD_W_TIME", "AVD_F_TIME", "AVD_W_DIST_XY", "AVD_F_DIST_XY", "AVD_W_DIST_Z", "AVD_F_DIST_Z", "AVD_F_ALT_MIN"]

    var enabled: Bool { (ps.val("ADSB_TYPE") ?? 0) != 0 }

    var body: some View {
        ConfigGate {
            PageTitle(title: "ADS-B", subtitle: String(localized: "Приймач повітряного руху навколо апарата й уникнення зіткнень з літаками."))
            trafficCard
            StepTitle(n: 1, title: String(localized: "Приймач"))
            ParamsCard(title: String(localized: "Приймач ADS-B"), icon: "airplane.circle", text: String(localized: "Оберіть тип приймача (потрібен вільний SERIAL-порт з протоколом ADS-B). Після зміни типу перезавантажте автопілот."), params: Self.main)
            if !ps.has("ADSB_TYPE") { Text("У цій прошивці немає підтримки ADS-B (перевірте збірку).").font(.callout).foregroundStyle(.secondary) }
            StepTitle(n: 2, title: String(localized: "Уникнення зіткнень"))
            ParamsCard(title: String(localized: "Уникнення зіткнень"), icon: "exclamationmark.triangle", text: String(localized: "Що робити, коли літак наближається. Працює лише з увімкненим приймачем."), params: Self.avoid)
            RebootRow(text: String(localized: "Тип приймача й увімкнення уникнення застосовуються після перезавантаження."))
        }
        .onAppear { live.start("adsb", every: 1_000_000_000) }
        .onDisappear { live.stop() }
    }

    func dist(_ a: AdsbLive) -> Double? {
        guard s.t.gpsFix >= 3 else { return nil }
        return CLLocation(latitude: s.t.lat, longitude: s.t.lon).distance(from: CLLocation(latitude: a.lat, longitude: a.lon))
    }

    var trafficCard: some View {
        let list = live.adsb.sorted { (dist($0) ?? 1e9) < (dist($1) ?? 1e9) }
        return Card(title: String(localized: "Літаки навколо"), icon: "airplane", text: enabled ? "Дані ADS-B від приймача. Список оновлюється раз на секунду." : "Приймач ADS-B вимкнено (ADSB_TYPE = 0): літаків не буде. Увімкніть його нижче.") {
            if enabled || !list.isEmpty {
                Map {
                    if s.t.gpsFix >= 3 {
                        Annotation("", coordinate: .init(latitude: s.t.lat, longitude: s.t.lon)) { Image(systemName: "location.north.fill").foregroundStyle(.blue).rotationEffect(.degrees(s.t.heading)) }
                    }
                    ForEach(list) { a in
                        Annotation(a.callsign.isEmpty ? a.icao : a.callsign, coordinate: .init(latitude: a.lat, longitude: a.lon)) {
                            Image(systemName: "airplane").font(.title3).foregroundStyle((dist(a) ?? 1e9) < 3000 ? Color.red : Color.orange)
                                .rotationEffect(.degrees(a.heading - 90))
                        }
                    }
                }
                .mapStyle(.hybrid)
                .frame(height: 240).clipShape(RoundedRectangle(cornerRadius: 10))
                if list.isEmpty { Label("Літаків зараз не видно.", systemImage: "info.circle").font(.callout).foregroundStyle(.secondary) }
                VStack(spacing: 0) {
                    ForEach(list) { a in
                        HStack(spacing: 10) {
                            Text(lk(a.callsign.isEmpty ? "—" : a.callsign)).font(.callout.weight(.medium)).frame(width: 90, alignment: .leading)
                            Text(LocalizedStringKey(a.icao)).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
                            Text(String(format: loc("%.0f м"), a.alt)).font(.callout.monospacedDigit()).frame(width: 70, alignment: .trailing)
                            Text(String(format: loc("%.0f м/с"), a.speed)).font(.callout.monospacedDigit()).frame(width: 70, alignment: .trailing)
                            Text(String(format: "%.0f°", a.heading)).font(.callout.monospacedDigit()).frame(width: 50, alignment: .trailing)
                            Text(lk(dist(a).map { String(format: loc("%.1f км"), $0 / 1000) } ?? "—")).font(.callout.monospacedDigit()).frame(width: 70, alignment: .trailing)
                            Spacer()
                            Text(String(format: loc("%.0f с"), a.age)).font(.caption).foregroundStyle(.tertiary)
                        }.padding(.vertical, 3)
                        Divider().opacity(0.4)
                    }
                }
            }
        }
    }
}

// MARK: - DroneCAN

enum DroneCANNames {
    static let health = [0: "норма", 1: "увага", 2: "помилка", 3: "критично"]
    static let mode = [0: "працює", 1: "ініціалізація", 2: "обслуговування", 3: "оновлення ПЗ", 7: "офлайн"]
    static let types: [Int: String] = [341: "NodeStatus", 1001: "Магнітне поле", 1002: "Магнітне поле 2", 1027: "RawAirData", 1028: "Статичний тиск", 1029: "Температура",
                                       1030: "ESC команди", 1034: "ESC статус", 1050: "Далекомір", 1063: "GNSS Fix2", 1091: "CircuitStatus", 1092: "BatteryInfo"]
}

struct DroneCANView: View {
    @Environment(Store.self) var s
    @State private var live = LivePoller()
    @AppStorage("dronecan.bus") private var bus = 1
    @State private var listening = false
    @State private var openNode: Int?
    @State private var nodeParams: DcParamsDTO?
    var ps: ParamStore { s.ps }

    static let cfg = ["CAN_P1_DRIVER", "CAN_P1_BITRATE", "CAN_P1_FDBITRATE", "CAN_D1_PROTOCOL", "CAN_D1_UC_NODE", "CAN_D1_UC_ESC_BM", "CAN_D1_UC_SRV_BM", "CAN_D1_UC_ESC_OF", "CAN_D1_UC_OPTION", "CAN_D1_UC_POOL", "CAN_D1_UC_SER_EN"]
    static let cfg2 = ["CAN_P2_DRIVER", "CAN_P2_BITRATE", "CAN_P2_FDBITRATE", "CAN_D2_PROTOCOL", "CAN_D2_UC_NODE", "CAN_D2_UC_ESC_BM", "CAN_D2_UC_SRV_BM", "CAN_D2_UC_OPTION"]

    var body: some View {
        ConfigGate {
            PageTitle(title: "DroneCAN", subtitle: String(localized: "Периферія на шині CAN: GPS, компаси, батареї, ESC та інші вузли. Налаштування польотника й перегляд вузлів у мережі."))
            StepTitle(n: 1, title: String(localized: "CAN на польотнику"))
            ParamsCard(title: String(localized: "Порт CAN 1"), icon: "point.3.filled.connected.trianglepath.dotted", text: String(localized: "Щоб вузли з'явились, увімкніть драйвер (CAN_P1_DRIVER = 1) і протокол DroneCAN, потім перезавантажте автопілот."), params: Self.cfg)
            if !ps.has("CAN_P1_DRIVER") { Text("У цій прошивці немає параметрів CAN (плата без порту CAN чи прошивка без підтримки).").font(.callout).foregroundStyle(.secondary) }
            AdvancedSection(key: "dc.advanced", subtitle: String(localized: "Другий порт CAN.")) { ParamsCard(title: String(localized: "Порт CAN 2"), icon: "point.3.filled.connected.trianglepath.dotted", params: Self.cfg2) }
            RebootRow(text: String(localized: "Зміни CAN застосовуються після перезавантаження автопілота."))
            StepTitle(n: 2, title: String(localized: "Вузли в мережі"))
            nodesCard
            StepTitle(n: 3, title: String(localized: "Датчики польотника на CAN"))
            devicesCard
        }
        .onDisappear { live.stop(); listening = false }
    }

    var nodesCard: some View {
        Card(title: String(localized: "Вузли"), icon: "cpu", text: String(localized: "Польотник пересилає кадри CAN у застосунок (MAV_CMD_CAN_FORWARD): видно вузли, їхній стан і версії. Для вузла можна переглянути його параметри (лише читання) і живі дані батареї; зміна параметрів і прошивка вузлів поки недоступні (для цього є DroneCAN GUI Tool).")) {
            HStack {
                Picker("Шина", selection: $bus) { Text("CAN 1").tag(1); Text("CAN 2").tag(2) }.pickerStyle(.segmented).frame(width: 190).disabled(listening)
                Spacer()
                Button {
                    if listening { live.stop(); listening = false } else { live.start("dc", every: 1_000_000_000, bus: bus); listening = true }
                } label: { Label(lk(listening ? "Зупинити" : "Слухати мережу"), systemImage: listening ? "stop.circle" : "waveform") }
                    .buttonStyle(.borderedProminent).disabled(!s.connected)
            }
            if listening, let d = live.dc {
                HStack(spacing: 14) {
                    Text("Кадрів: \(d.frames)").font(.caption.monospacedDigit()); Text("Передач: \(d.transfers)").font(.caption.monospacedDigit())
                    Text("Вузлів: \(d.nodes.count)").font(.caption.monospacedDigit())
                }.foregroundStyle(.secondary)
                if d.nodes.isEmpty {
                    Label(lk(d.frames == 0 ? String(localized: "Кадрів немає. Перевірте CAN_P\(bus)_DRIVER, проводку, живлення периферії та швидкість шини.") : "Кадри йдуть, але вузлів ще не видно (потрібен NodeStatus)."), systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(d.nodes) { n in nodeRow(n) }
            } else if !listening {
                Text("Натисніть «Слухати мережу». Застосунок попросить польотник пересилати кадри й опитає знайдені вузли.").font(.callout).foregroundStyle(.secondary)
            } else { ProgressView().controlSize(.small) }
        }
    }

    func nodeRow(_ n: DcNodeLive) -> some View {
        let ok = n.health == 0 && n.age < 5
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle().fill(n.age > 5 ? Color.gray : (n.health == 0 ? Color.green : (n.health == 1 ? Color.orange : Color.red))).frame(width: 9, height: 9)
                Text("Вузол \(n.id)").font(.callout.weight(.semibold))
                if n.hasInfo { Text(LocalizedStringKey(n.name)).font(.callout) }
                Spacer()
                Text(lk(DroneCANNames.mode[n.mode] ?? String(localized: "режим \(n.mode)"))).font(.caption).padding(.horizontal, 6).padding(.vertical, 1).background(Color.primary.opacity(0.08), in: Capsule())
                Text(lk(n.age > 5 ? "не відповідає" : (DroneCANNames.health[n.health] ?? "?"))).font(.caption).foregroundStyle(ok ? Color.green : Color.orange)
            }
            HStack(spacing: 16) {
                Text(String(format: loc("аптайм %d хв %d с"), n.uptime / 60, n.uptime % 60)).font(.caption).foregroundStyle(.secondary)
                if n.hasInfo {
                    Text("ПЗ \(n.sw) (\(n.vcs.prefix(7)))").font(.caption).foregroundStyle(.secondary)
                    Text("плата \(n.hw)").font(.caption).foregroundStyle(.secondary)
                    Text("UID " + n.uid.prefix(12)).font(.system(.caption, design: .monospaced)).foregroundStyle(.tertiary)
                } else { Text("запит інформації…").font(.caption).foregroundStyle(.tertiary) }
            }
            if let b = n.battery, b.age < 5 {
                HStack(spacing: 14) {
                    Label(lk(String(format: loc("%.2f В"), b.voltage)), systemImage: "bolt.fill")
                    Label(lk(String(format: loc("%.2f А"), b.current)), systemImage: "gauge.with.dots.needle.33percent")
                    if b.tempC > -200 { Label(lk(String(format: "%.0f °C", b.tempC)), systemImage: "thermometer.medium") }
                    if b.soc >= 0, b.soc <= 100 { Label(lk(String(format: "%.0f %%", b.soc)), systemImage: "battery.75") }
                }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Button(lk(openNode == n.id ? "Сховати параметри" : "Параметри вузла")) { toggleParams(n) }.controlSize(.small)
                if n.paramBusy == true { ProgressView().controlSize(.mini); Text("читання…").font(.caption).foregroundStyle(.secondary) }
                else if let c = n.paramCount, c > 0 { Text("\(c) параметрів").font(.caption).foregroundStyle(.secondary) }
            }
            if openNode == n.id, let p = nodeParams {
                VStack(alignment: .leading, spacing: 2) {
                    if !p.error.isEmpty { Label(LocalizedStringKey(p.error), systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
                    ForEach(p.items) { it in
                        HStack(spacing: 10) {
                            Text(LocalizedStringKey(it.name)).font(.system(.caption, design: .monospaced)).frame(width: 190, alignment: .leading)
                            Text(LocalizedStringKey(it.value)).font(.system(.caption, design: .monospaced)).frame(width: 110, alignment: .trailing)
                            Text(LocalizedStringKey(it.type)).font(.caption2).foregroundStyle(.tertiary)
                            Spacer()
                        }
                    }
                    Text("Лише читання. Зміна параметрів вузла поки недоступна.").font(.caption2).foregroundStyle(.tertiary).padding(.top, 2)
                }.padding(8).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
            }
            if !n.messages.isEmpty {
                Text(lk(n.messages.map { String(localized: "\(DroneCANNames.types[$0.type] ?? String(localized: "тип \($0.type)")) ×\($0.count)") }.joined(separator: " · "))).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(8).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    func toggleParams(_ n: DcNodeLive) {
        if openNode == n.id { openNode = nil; return }
        openNode = n.id; nodeParams = nil
        EngineAPI.post("/dronecan/params/read?node=\(n.id)")
        Task { @MainActor in
            while openNode == n.id, !Task.isCancelled {
                if let d = await EngineAPI.get("/dronecan/params?node=\(n.id)", as: DcParamsDTO.self) { nodeParams = d; if !d.busy, !d.items.isEmpty || !d.error.isEmpty { break } }
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
        }
    }

    var devicesCard: some View {
        let rows = hwRows(ps).filter { $0.dronecanNode != nil }
        return Card(title: String(localized: "Датчики з CAN"), icon: "sensor.fill", text: String(localized: "Датчики, які польотник бачить на шині DroneCAN (за параметрами *_DEVID).")) {
            if rows.isEmpty { Text("Жодного датчика на CAN польотник не використовує.").font(.callout).foregroundStyle(.secondary) }
            ForEach(rows) { r in
                HStack { Text(lk(r.group + " \(r.slot)")).font(.callout); Spacer(); Text("вузол \(r.dronecanNode ?? 0)").font(.callout).foregroundStyle(.secondary) }
            }
        }
    }
}
