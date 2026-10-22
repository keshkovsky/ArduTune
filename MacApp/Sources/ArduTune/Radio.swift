import SwiftUI
import Observation

@Observable
final class RadioCal {
    var running = false
    static let maxChannels = 24
    var centers = [Int](repeating: 0, count: 24)
    var mins = [Int](repeating: 0, count: 24)
    var maxs = [Int](repeating: 0, count: 24)
    var message: String?

    func start(_ rc: [Int]) {
        for i in 0..<24 { let v = i < rc.count ? rc[i] : 0; centers[i] = v; mins[i] = v; maxs[i] = v }
        running = true; message = nil
    }
    func feed(_ rc: [Int]) {
        guard running else { return }
        for i in 0..<24 where i < rc.count && rc[i] > 700 && rc[i] < 2300 {
            if mins[i] == 0 || rc[i] < mins[i] { mins[i] = rc[i] }
            if rc[i] > maxs[i] { maxs[i] = rc[i] }
        }
    }
}

/// Radio Calibration: живі канали RC1–8, запис MIN/MAX/TRIM за рухом стіків.
struct RadioView: View {
    @Environment(Store.self) var s
    @State private var io = IOStore()
    @State private var cal = RadioCal()
    var ps: ParamStore { s.ps }
    var rc: [Int] { io.io?.rc ?? [] }
    func v(_ i: Int) -> Int { i < rc.count ? rc[i] : 0 }
    @State private var mapNote: String?
    @State private var showAllChannels = false
    @State private var result: RadioResult?

    /// Кількість каналів, які підтримує прошивка (за наявними параметрами RCn_MIN), до 24.
    var channelCount: Int { (1...24).filter { ps.has("RC\($0)_MIN") }.max() ?? 8 }
    /// Максимальний номер каналу для RCMAP (за метаданими, до 24).
    var mapMax: Int { min(max(Int(ps.meta["RCMAP_ROLL"]?.max ?? 16), 4), 24) }
    var shownChannels: [Int] { Array(0..<(showAllChannels ? channelCount : min(8, channelCount))) }

    var rollCh: Int { Int(ps.val("RCMAP_ROLL") ?? 1) }
    var pitchCh: Int { Int(ps.val("RCMAP_PITCH") ?? 2) }
    var thrCh: Int { Int(ps.val("RCMAP_THROTTLE") ?? 3) }
    var yawCh: Int { Int(ps.val("RCMAP_YAW") ?? 4) }
    var mapDuplicates: Bool { Set([rollCh, pitchCh, thrCh, yawCh]).count < 4 }
    /// Назва функції стіка для каналу (1-based), якщо він призначений.
    func role(_ ch: Int) -> (String, Color)? {
        if ch == rollCh { return ("Крен", .blue) }
        if ch == pitchCh { return ("Тангаж", .purple) }
        if ch == thrCh { return ("Газ", .orange) }
        if ch == yawCh { return ("Курс", .teal) }
        return nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                OfflineBanner()
                if !s.canView {
                    ContentUnavailableView("Польотник не підключений", systemImage: "cable.connector", description: Text("Підключіть плату по USB"))
                } else if ps.params.isEmpty {
                    ProgressView("Завантаження параметрів…")
                } else {
                    if s.armedLive { Label("Апарат ARMED: калібрування заблоковано", systemImage: "lock.fill").foregroundStyle(.red) }
                    if rc.allSatisfy({ $0 == 0 }) {
                        Label("Сигнал приймача не отримано. Увімкніть передавач і перевірте підключення приймача.", systemImage: "antenna.radiowaves.left.and.right.slash").foregroundStyle(.orange)
                    }
                    mappingCard
                    sticksCard
                    channelsCard
                    actionCard
                }
            }
            .padding()
        }
        .onAppear { io.start() }
        .onDisappear { io.stop() }
        .onChange(of: io.io?.rc) { _, new in if let new { cal.feed(new) } }
        .sheet(item: $result) { r in RadioResultSheet(result: r) { result = nil } }
    }

    // MARK: Відповідність каналів стікам (RCMAP)
    var mappingCard: some View {
        Card(title: String(localized: "Відповідність каналів стікам"), icon: "arrow.left.arrow.right", text: String(localized: "Який канал приймача керує яким стіком (RCMAP). Змініть, якщо ваш пульт видає канали в іншому порядку. Після зміни перезавантажте автопілот і відкалібруйте радіо.")) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                mapRow("Крен (Aileron)", "RCMAP_ROLL", .blue)
                mapRow("Тангаж (Elevator)", "RCMAP_PITCH", .purple)
                mapRow("Газ (Throttle)", "RCMAP_THROTTLE", .orange)
                mapRow("Курс (Rudder)", "RCMAP_YAW", .teal)
            }
            HStack(spacing: 10) {
                Text("Схеми:").font(.caption).foregroundStyle(.secondary)
                Button("AETR  (1·2·3·4)") { preset(r: 1, p: 2, t: 3, y: 4) }
                Button("TAER  (2·3·1·4)") { preset(r: 2, p: 3, t: 1, y: 4) }
                Button("AERT  (1·2·4·3)") { preset(r: 1, p: 2, t: 4, y: 3) }
            }.disabled(s.armed)
            Text("Порядок у дужках: Крен · Тангаж · Газ · Курс. AETR: стандарт ArduPilot, EdgeTX/OpenTX. TAER: Futaba, Spektrum, JR.").font(.caption2).foregroundStyle(.secondary)
            if mapDuplicates { Label("Один канал призначено кільком стікам. Виправте, інакше керування працюватиме неправильно.", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout) }
            HStack {
                if let n = mapNote { Label(LocalizedStringKey(n), systemImage: "arrow.triangle.2.circlepath").font(.caption).foregroundStyle(.orange) }
                Spacer()
                Button { EngineAPI.post("/reboot") } label: { Label("Перезавантажити автопілот", systemImage: "restart") }.disabled(s.armed)
            }
        }
    }

    @ViewBuilder func mapRow(_ title: String, _ name: String, _ color: Color) -> some View {
        GridRow {
            HStack(spacing: 6) { Circle().fill(color).frame(width: 9, height: 9); Text(LocalizedStringKey(title)) }
            Picker("", selection: Binding(get: { Int(ps.val(name) ?? 1) }, set: { ps.write(name, Double($0)); mapNote = String(localized: "Зміну записано. Для застосування потрібне перезавантаження автопілота.") })) {
                ForEach(1...mapMax, id: \.self) { Text("Канал \($0)").tag($0) }
            }
            .labelsHidden().frame(width: 130).disabled(s.armed || !ps.has(name))
            Text(lk(v(Int(ps.val(name) ?? 1) - 1) == 0 ? "—" : String(v(Int(ps.val(name) ?? 1) - 1)))).font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
        }
    }

    func preset(r: Int, p: Int, t: Int, y: Int) {
        ps.write("RCMAP_ROLL", Double(r)); ps.write("RCMAP_PITCH", Double(p)); ps.write("RCMAP_THROTTLE", Double(t)); ps.write("RCMAP_YAW", Double(y))
        mapNote = String(localized: "Схему записано. Для застосування потрібне перезавантаження автопілота.")
    }

    // Стіки: Mode 2 — лівий (yaw/throttle), правий (roll/pitch)
    var sticksCard: some View {
        Card(title: String(localized: "Стіки"), icon: "gamecontroller", text: nil) {
            HStack(spacing: 40) {
                Stick(title: String(localized: "Газ / Курс"), x: norm(yawCh - 1), y: norm(thrCh - 1))
                Stick(title: String(localized: "Крен / Тангаж"), x: norm(rollCh - 1), y: norm(pitchCh - 1), invertY: true)
            }.frame(maxWidth: .infinity)
        }
    }
    func norm(_ i: Int) -> Double {
        let lo = Double(ps.val("RC\(i + 1)_MIN") ?? 1100), hi = Double(ps.val("RC\(i + 1)_MAX") ?? 1900)
        let x = Double(v(i))
        return x == 0 || hi <= lo ? 0.5 : min(max((x - lo) / (hi - lo), 0), 1)
    }

    var channelsCard: some View {
        Card(title: String(localized: "Канали приймача"), icon: "dot.radiowaves.left.and.right", text: cal.running ? "Калібрування: рухайте всі стіки та перемикачі до крайніх положень. Мінімум і максимум фіксуються." : "Поточні значення каналів і збережені межі (RCn_MIN / TRIM / MAX).") {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    ForEach(["Канал", "Значення", "", "Min", "Trim", "Max", "Реверс"], id: \.self) { Text(lk($0)).font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
                }
                Divider().gridCellColumns(7)
                ForEach(shownChannels, id: \.self) { i in
                    let lo = Double(cal.running ? cal.mins[i] : Int(ps.val("RC\(i + 1)_MIN") ?? 1100))
                    let hi = Double(cal.running ? cal.maxs[i] : Int(ps.val("RC\(i + 1)_MAX") ?? 1900))
                    GridRow {
                        HStack(spacing: 6) {
                            Text("\(i + 1)").font(.system(.body, design: .monospaced).weight(.semibold)).frame(width: 18, alignment: .trailing)
                            if let r = role(i + 1) { Pill(text: r.0, tint: r.1) }
                        }
                        Text(lk(v(i) == 0 ? "—" : String(v(i)))).font(.system(.body, design: .monospaced)).frame(width: 50, alignment: .trailing)
                        RCBar(value: Double(v(i)), lo: min(lo, 1000), hi: max(hi, 2000), markMin: cal.running ? Double(cal.mins[i]) : nil, markMax: cal.running ? Double(cal.maxs[i]) : nil)
                            .frame(width: 260, height: 18)
                        Text(lk(String(Int(lo)))).font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
                        Text(lk(String(Int(ps.val("RC\(i + 1)_TRIM") ?? 1500)))).font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
                        Text(lk(String(Int(hi)))).font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
                        Toggle("", isOn: Binding(get: { (ps.val("RC\(i + 1)_REVERSED") ?? 0) != 0 }, set: { ps.write("RC\(i + 1)_REVERSED", $0 ? 1 : 0) }))
                            .toggleStyle(.checkbox).labelsHidden().disabled(s.armed)
                    }
                }
            }
            if channelCount > 8 {
                Toggle("Показати всі канали (\(channelCount))", isOn: $showAllChannels).toggleStyle(.checkbox)
            }
            Text("Прошивка підтримує каналів: \(channelCount). Живі значення приймач передає по MAVLink для перших 18.").font(.caption2).foregroundStyle(.secondary)
        }
    }

    var actionCard: some View {
        Card(title: String(localized: "Калібрування радіо"), icon: "scope", text: String(localized: "1. Поставте всі стіки в центр, газ у мінімум. 2. Натисніть «Почати». 3. Обведіть стіками максимальні діапазони й переключіть усі перемикачі. 4. Поверніть стіки в центр і натисніть «Завершити».")) {
            HStack {
                if cal.running {
                    Button("Завершити й зберегти") { finish() }.buttonStyle(.borderedProminent)
                    Button("Скасувати") { cal.running = false; cal.message = String(localized: "Скасовано") }
                } else {
                    Button("Почати калібрування") { cal.start(rc) }.buttonStyle(.borderedProminent)
                        .disabled(s.armed || rc.allSatisfy { $0 == 0 })
                }
                if let m = cal.message { Text(LocalizedStringKey(m)).font(.callout).foregroundStyle(.secondary) }
            }
        }
    }

    func finish() {
        var rows: [RadioResult.Row] = []
        for i in 0..<channelCount {
            let lo = cal.mins[i], hi = cal.maxs[i]
            guard hi > 0 else { continue }                                  // канал без сигналу не показуємо
            let stickRole = role(i + 1)
            if lo < 800 || hi > 2200 || hi - lo < 200 {
                rows.append(.init(ch: i + 1, role: stickRole?.0, min: lo, trim: nil, max: hi, saved: false,
                                  note: hi - lo < 200 ? "майже не рухався: збереження пропущено" : "значення поза межами 800…2200: збереження пропущено", important: stickRole != nil))
                continue
            }
            // Trim: канали 1,2,4 і додаткові — центр на старті; газ (3) — мінімум.
            let trim = (i + 1 == thrCh) ? lo : min(max(cal.centers[i], lo), hi)
            ps.write("RC\(i + 1)_MIN", Double(lo)); ps.write("RC\(i + 1)_MAX", Double(hi)); ps.write("RC\(i + 1)_TRIM", Double(trim))
            var note = ""
            if hi - lo < 700 { note = String(localized: "вузький діапазон: перевірте, чи стік доходив до країв") }
            rows.append(.init(ch: i + 1, role: stickRole?.0, min: lo, trim: trim, max: hi, saved: true, note: note, important: stickRole != nil))
        }
        cal.running = false
        let skipped = rows.filter { !$0.saved && $0.important }
        cal.message = skipped.isEmpty ? "Збережено" : "Збережено частково"
        result = RadioResult(rows: rows)
    }
}

struct RCBar: View {
    let value: Double, lo: Double, hi: Double
    var markMin: Double? = nil, markMax: Double? = nil
    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            let x: (Double) -> CGFloat = { v in CGFloat(min(max((v - lo) / max(hi - lo, 1), 0), 1)) * w }
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 5).fill(.quaternary.opacity(0.7))
                RoundedRectangle(cornerRadius: 5).fill(LinearGradient(colors: [.green.opacity(0.7), .green], startPoint: .leading, endPoint: .trailing))
                    .frame(width: value > 0 ? x(value) : 0)
                if let a = markMin, a > 0 { Rectangle().fill(.red).frame(width: 2).offset(x: x(a)) }
                if let b = markMax, b > 0 { Rectangle().fill(.red).frame(width: 2).offset(x: x(b) - 2) }
                // числові значення пойманих мінімуму й максимуму на краях шкали
                if let a = markMin, let b = markMax, a > 0, b > 0 {
                    HStack {
                        Text(lk(String(Int(a)))).foregroundStyle(.white.opacity(0.9))
                        Spacer(minLength: 0)
                        Text(lk(String(Int(b)))).foregroundStyle(.white.opacity(0.9))
                    }
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .shadow(color: .black.opacity(0.6), radius: 1)
                    .padding(.horizontal, 4)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
    }
}

struct Stick: View {
    let title: String; let x: Double; let y: Double
    var invertY = false
    var body: some View {
        VStack(spacing: 6) {
            Canvas { ctx, size in
                let r = CGRect(origin: .zero, size: size).insetBy(dx: 2, dy: 2)
                ctx.fill(Path(roundedRect: r, cornerRadius: 10), with: .color(.gray.opacity(0.18)))
                ctx.stroke(Path(roundedRect: r, cornerRadius: 10), with: .color(.gray.opacity(0.5)), lineWidth: 1)
                var cross = Path()
                cross.move(to: CGPoint(x: size.width / 2, y: r.minY)); cross.addLine(to: CGPoint(x: size.width / 2, y: r.maxY))
                cross.move(to: CGPoint(x: r.minX, y: size.height / 2)); cross.addLine(to: CGPoint(x: r.maxX, y: size.height / 2))
                ctx.stroke(cross, with: .color(.gray.opacity(0.35)), lineWidth: 1)
                let px = r.minX + CGFloat(x) * r.width
                let py = r.minY + CGFloat(invertY ? 1 - y : 1 - y) * r.height
                ctx.fill(Path(ellipseIn: CGRect(x: px - 8, y: py - 8, width: 16, height: 16)), with: .color(.accentColor))
            }
            .frame(width: 130, height: 130)
            Text(LocalizedStringKey(title)).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Підсумок калібрування радіо для вікна результату.
struct RadioResult: Identifiable {
    struct Row: Identifiable { let id = UUID(); let ch: Int; let role: String?; let min: Int; let trim: Int?; let max: Int; let saved: Bool; let note: String; let important: Bool }
    let id = UUID()
    let rows: [Row]
    var savedCount: Int { rows.filter(\.saved).count }
    var problems: [Row] { rows.filter { !$0.saved || !$0.note.isEmpty } }
    var stickProblems: [Row] { rows.filter { !$0.saved && $0.important } }
}

struct RadioResultSheet: View {
    let result: RadioResult
    var close: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: result.stickProblems.isEmpty ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .font(.title).foregroundStyle(result.stickProblems.isEmpty ? Color.green : Color.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Калібрування радіо завершено").font(.title3.weight(.semibold))
                    Text(lk(result.stickProblems.isEmpty ? String(localized: "Збережено каналів: \(result.savedCount). Межі записано в RCn_MIN / TRIM / MAX.") : String(localized: "Основні стіки відкалібровані не повністю: \(result.stickProblems.map { String($0.ch) }.joined(separator: ", ")). Повторіть калібрування, рухаючи ці стіки до країв.")))
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    ForEach(["Канал", "Функція", "Min", "Trim", "Max", "Діапазон", "Результат"], id: \.self) { Text(lk($0)).font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
                }
                Divider().gridCellColumns(7)
                ForEach(result.rows) { r in
                    GridRow {
                        Text("\(r.ch)").font(.system(.body, design: .monospaced).weight(.semibold))
                        Text(lk(r.role ?? "—")).foregroundStyle(r.role == nil ? Color.secondary : Color.primary)
                        Text(lk(String(r.min))).font(.system(.body, design: .monospaced))
                        Text(lk(r.trim.map(String.init) ?? "—")).font(.system(.body, design: .monospaced))
                        Text(lk(String(r.max))).font(.system(.body, design: .monospaced))
                        Text(lk(String(r.max - r.min))).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
                        HStack(spacing: 5) {
                            Image(systemName: r.saved ? (r.note.isEmpty ? "checkmark.circle.fill" : "exclamationmark.circle.fill") : "xmark.circle.fill")
                                .foregroundStyle(r.saved ? (r.note.isEmpty ? Color.green : Color.orange) : Color.red)
                            Text(lk(r.saved ? (r.note.isEmpty ? "збережено" : r.note) : r.note)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Text("Канали без сигналу в таблиці не показано. Якщо змінювали порядок каналів (RCMAP), перезавантажте автопілот.").font(.caption2).foregroundStyle(.tertiary)
            HStack { Spacer(); Button("Готово") { close() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent) }
        }
        .padding(20)
        .frame(minWidth: 620)
    }
}
