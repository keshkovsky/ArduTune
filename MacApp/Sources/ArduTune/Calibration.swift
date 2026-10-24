import SwiftUI
import Observation

struct MagDTO: Decodable { let id: Int; let pct: Int; let status: Int; let attempt: Int; let mask: [Int]; let fitness: Double; let x: Double; let y: Double; let z: Double; let done: Bool; let autosaved: Int }
struct CompassMotDTO: Decodable { let active: Bool; let seq: Int; let age: Double; let throttle: Int; let current: Double; let interference: Int; let x: Double; let y: Double; let z: Double }
struct CalDTO: Decodable {
    let compassMot: CompassMotDTO?
    let accelPos: Int; let accelSeq: Int; let accelResult: String?
    let ackCmd: Int; let ackResult: Int; let ackSeq: Int
    let mags: [MagDTO]; let magElapsed: Double; let msgSeq: Int; let msgs: [String]
}

@Observable
final class CalStore {
    var cal: CalDTO?
    var accelRunning = false
    var magRunning = false
    var note: String?
    var polling = false

    func start() {
        guard !polling else { return }
        polling = true
        Task { @MainActor in
            while polling {
                if let c = await EngineAPI.get("/cal", as: CalDTO.self) {
                    cal = c
                    if accelRunning, c.accelResult != nil { accelRunning = false }
                    if magRunning, !c.mags.isEmpty, c.mags.allSatisfy({ $0.done }) { magRunning = false }
                }
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
    }
    func stop() { polling = false }

    func run(_ path: String, _ onOK: (() -> Void)? = nil) {
        EngineAPI.post(path) { ok, err in
            if ok { self.note = nil; onOK?() }
            else { self.note = err == "armed" ? "Операція недоступна: апарат ARMED" : "Не вдалося виконати команду" }
        }
    }
}

let accelSteps: [Int: (String, String)] = [
    1: ("Покладіть апарат рівно", "square.fill"),
    2: ("Поставте на ЛІВИЙ бік", "arrow.turn.up.left"),
    3: ("Поставте на ПРАВИЙ бік", "arrow.turn.up.right"),
    4: ("Поставте носом ВНИЗ", "arrow.down.to.line"),
    5: ("Поставте носом ВГОРУ", "arrow.up.to.line"),
    6: ("Переверніть ДОГОРИ ДРИГОМ", "arrow.up.arrow.down"),
]

func magStatusText(_ s: Int) -> String {
    switch s {
    case 0: return "не запущено"
    case 1: return "очікування"
    case 2: return "крок 1"
    case 3: return "крок 2"
    case 4: return "успішно"
    case 5: return "помилка"
    case 6: return "неправильна орієнтація"
    case 7: return "поганий радіус"
    default: return "?"
    }
}

struct CalibrationView: View {
    @Environment(Store.self) var s
    @State private var cs = CalStore()
    @State private var confirmReboot = false
    @State private var rebootNote: String?
    var ps: ParamStore { s.ps }
    var frameClass: Int { Int(ps.params.first { $0.name == "FRAME_CLASS" }?.value ?? 1) }
    var compassEnable: Bool? { ps.params.first { $0.name == "COMPASS_ENABLE" }.map { $0.value != 0 } }
    var comps: [CompassInfo] { compasses(ps) }

    var armed: Bool { s.armed }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                OfflineBanner()
                if !s.canView {
                    ContentUnavailableView("Польотник не підключений", systemImage: "cable.connector", description: Text("Підключіть плату по USB"))
                } else {
                    if s.armedLive { Label("Апарат ARMED: калібрування заблоковано", systemImage: "lock.fill").foregroundStyle(.red) }
                    if let n = cs.note { Label(LocalizedStringKey(n), systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                    HStack(alignment: .top, spacing: 16) { modelCard; sensorsCard }
                    accelCard
                    levelCard
                    BoardOrientationCard()
                    SensorFiltersCard()
                    HStack(alignment: .top, spacing: 16) { gyroCard; baroCard }
                    logCard
                    HStack {
                        Spacer()
                        Button(role: .destructive) { confirmReboot = true } label: { Label("Перезавантажити автопілот", systemImage: "restart") }
                            .disabled(armed)
                    }
                    if let r = rebootNote { Text(LocalizedStringKey(r)).font(.caption).foregroundStyle(.secondary) }
                }
            }
            .padding()
        }
        .onAppear { cs.start() }
        .onDisappear { cs.stop() }
        .confirmationDialog("Перезавантажити автопілот?", isPresented: $confirmReboot) {
            Button("Перезавантажити", role: .destructive) { reboot() }
        } message: { Text("З'єднання тимчасово зникне й відновиться автоматично.") }
    }

    func reboot() {
        EngineAPI.post("/reboot") { ok, err in rebootNote = ok ? "Команду надіслано, чекаємо повернення польотника…" : (err == "armed" ? "Недоступно: ARMED" : "Помилка") }
    }

    // MARK: Акселерометр
    var accelCard: some View {
        Card(title: String(localized: "Акселерометр"), icon: "cube.transparent", text: String(localized: "Шість положень. Тримайте апарат нерухомо після кожного кроку.")) {
            if let c = cs.cal, cs.accelRunning {
                if c.accelPos != 0, let step = accelSteps[c.accelPos] {
                    HStack(spacing: 14) {
                        Image(systemName: step.1).font(.largeTitle).frame(width: 50)
                        VStack(alignment: .leading) {
                            Text("Крок \(c.accelPos) із 6").font(.caption).foregroundStyle(.secondary)
                            Text(LocalizedStringKey(step.0)).font(.headline)
                        }
                        Spacer()
                        Button("Готово, тримаю нерухомо") { cs.run("/cal/accel/pos?pos=\(c.accelPos)") }.buttonStyle(.borderedProminent)
                    }
                } else { HStack { ProgressView().controlSize(.small); Text("Обробка…") } }
                Button("Скасувати") { cs.run("/cal/cancel") { cs.accelRunning = false } }
            } else {
                if let r = cs.cal?.accelResult {
                    Label(lk(r == "success" ? "Калібрування успішне. Перезавантажте автопілот." : "Калібрування не вдалося, повторіть."), systemImage: r == "success" ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(r == "success" ? .green : .red)
                }
                Button("Почати калібрування") { cs.run("/cal/accel/start") { cs.accelRunning = true } }.disabled(armed)
            }
        }
    }

    // MARK: Горизонт
    var levelCard: some View {
        Card(title: String(localized: "Вирівнювання горизонту"), icon: "level", text: String(localized: "Покладіть апарат на рівну поверхню та натисніть кнопку. Це задає нуль горизонту (AHRS trim).")) {
            HStack {
                Button("Вирівняти горизонт") { cs.run("/cal/level") }.disabled(armed)
                Text(String(format: loc("Зараз: крен %.1f°, тангаж %.1f°"), s.t.roll, s.t.pitch)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Моделі та датчики
    var modelCard: some View {
        Card(title: String(localized: "Орієнтація апарата"), icon: "cube", text: nil) {
            VehicleModel(kind: vehicleKind(s.t.vehicle, frameClass: frameClass), roll: s.t.roll, pitch: s.t.pitch, yaw: s.t.yaw)
                .frame(height: 210)
            Text(String(format: loc("Крен %.1f°  ·  Тангаж %.1f°  ·  Курс %.0f°"), s.t.roll, s.t.pitch, s.t.heading))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .frame(maxWidth: 380)
    }

    var sensorsCard: some View {
        Card(title: String(localized: "Датчики"), icon: "cpu", text: firmwareLine) {
            SensorGroup(title: String(localized: "Акселерометр"), icon: "move.3d", rows: sensorRows(ps, .accel))
            SensorGroup(title: String(localized: "Гіроскоп"), icon: "gyroscope", rows: sensorRows(ps, .gyro))
            SensorGroup(title: String(localized: "Барометр"), icon: "barometer", rows: sensorRows(ps, .baro))
            SensorGroup(title: String(localized: "Компас"), icon: "safari", rows: comps.map { SensorRow(id: "c\($0.slot)", slot: "\($0.slot)", name: $0.name, detail: ($0.external ? "зовнішній" : "внутрішній") + ($0.used ? "" : ", вимкнено")) },
                        empty: compassEnable == false ? "Вимкнено (COMPASS_ENABLE = 0)" : "Не виявлено")
        }
    }

    var firmwareLine: String? {
        let m = cs.cal?.msgs ?? []
        let fw = m.first { $0.hasPrefix("Ardu") }
        let board = m.firstIndex { $0.hasPrefix("ChibiOS") }.flatMap { $0 + 1 < m.count ? m[$0 + 1] : nil }
        let parts = [fw, board.map { String($0.split(separator: " ").first ?? "") }].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var gyroCard: some View {
        Card(title: String(localized: "Гіроскоп"), icon: "gyroscope", text: String(localized: "Апарат має стояти нерухомо.")) {
            Button("Калібрувати гіроскоп") { cs.run("/cal/gyro") }.disabled(armed)
        }
    }
    var baroCard: some View {
        Card(title: String(localized: "Барометр"), icon: "barometer", text: String(localized: "Скидає нульову висоту до поточного тиску.")) {
            Button("Калібрувати барометр") { cs.run("/cal/baro") }.disabled(armed)
        }
    }

    var logCard: some View {
        Card(title: String(localized: "Повідомлення автопілота"), icon: "text.bubble", text: nil) {
            let msgs = Array((cs.cal?.msgs ?? []).suffix(12))
            if msgs.isEmpty { Text("Поки порожньо").font(.caption).foregroundStyle(.secondary) }
            ForEach(Array(msgs.enumerated()), id: \.offset) { _, m in Text(LocalizedStringKey(m)).font(.caption.monospaced()).textSelection(.enabled) }
        }
    }
}

struct Card<Content: View>: View {
    let title: String; let icon: String; let text: String?
    @ViewBuilder var content: Content
    init(title: String, icon: String, text: String?, @ViewBuilder content: () -> Content) { self.title = title; self.icon = icon; self.text = text; self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label { Text(LocalizedStringKey(title)) } icon: { CardIcon(name: icon) }.font(.headline)
            if let text { Text(LocalizedStringKey(text)).font(.callout).foregroundStyle(.secondary) }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}


struct SensorGroup: View {
    let title: String; let icon: String; let rows: [SensorRow]
    var empty = String(localized: "Не виявлено")
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(LocalizedStringKey(title), systemImage: icon).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if rows.isEmpty { Text(LocalizedStringKey(empty)).font(.callout).foregroundStyle(.tertiary) }
            ForEach(rows) { r in
                HStack(spacing: 6) {
                    Text("\(r.slot)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary).frame(width: 12)
                    Text(LocalizedStringKey(r.name)).font(.callout.weight(.medium))
                    Text(LocalizedStringKey(r.detail)).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}
