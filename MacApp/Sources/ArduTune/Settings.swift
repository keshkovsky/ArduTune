import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Налаштування самого застосунку (не польотника). Ключі UserDefaults, які читає решта коду.
enum AppSettings {
    static let defaults = UserDefaults.standard

    // Вигляд
    static func applyTheme() {
        switch defaults.string(forKey: "app.theme") ?? "system" {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }
    static func applyFullscreen() {
        guard defaults.bool(forKey: "app.fullscreen"), let w = NSApp.windows.first(where: { $0.isVisible && !$0.styleMask.contains(.fullScreen) }) else { return }
        w.toggleFullScreen(nil)
    }

    // Підключення
    static var gcsID: Int { (defaults.object(forKey: "conn.gcsid") as? Int) ?? 255 }
    static func pushGcsID() { EngineAPI.post("/settings/gcsid?id=\(gcsID)") }
    static var autoConnectOnLaunch: Bool { (defaults.object(forKey: "conn.autoOnLaunch") as? Bool) ?? true }
    static var loadMissionOnConnect: Bool { defaults.bool(forKey: "mission.loadOnConnect") }

    // Швидкості потоків телеметрії, Гц: група → повідомлення MAVLink
    static let rateGroups: [(key: String, title: String, hint: String, ids: [Int], def: Int)] = [
        ("attitude", "Положення (Attitude)", "ATTITUDE: крен, тангаж, курс. Визначає плавність HUD.", [30], 10),
        ("position", "Позиція", "GLOBAL_POSITION_INT, GPS_RAW_INT: положення на карті, висота, швидкість.", [33, 24], 5),
        ("status", "Режим і стан", "SYS_STATUS, MISSION_CURRENT, NAV_CONTROLLER_OUTPUT: батарея, поточна точка, відстані.", [1, 42, 62], 2),
        ("rc", "Канали пульта і виходи", "RC_CHANNELS, SERVO_OUTPUT_RAW: стіки й виходи серво (Radio, Servo).", [65, 36], 2),
        ("sensor", "Датчики", "VFR_HUD, VIBRATION, RAW_IMU, SCALED_PRESSURE, BATTERY_STATUS, EKF_STATUS_REPORT.", [74, 241, 27, 29, 147, 193], 2),
    ]
    static let rateChoices = [1, 2, 4, 5, 10, 20, 25, 50]
    static func rate(_ key: String, def: Int) -> Int { (defaults.object(forKey: "tele.rate." + key) as? Int) ?? def }
    static var customRates: Bool { defaults.bool(forKey: "tele.custom") }
    /// Запитує в польотника вибрані інтервали повідомлень (SET_MESSAGE_INTERVAL через двигун).
    static func applyRates() {
        for g in rateGroups {
            let hz = rate(g.key, def: g.def)
            for id in g.ids { EngineAPI.post("/msg/interval?id=\(id)&hz=\(hz)") }
        }
    }

    // Папка логів (tlog і Dataflash .bin): власна або типова в Application Support
    static var logDir: String { defaults.string(forKey: "data.logDir") ?? "" }
    static func pushLogDir() { EngineAPI.post("/settings/logdir?path=\(EngineAPI.q(logDir))") }
    /// Де зараз лежать логи: (tlog, Dataflash).
    static var logFolders: (tlog: String, df: String) {
        logDir.isEmpty ? (supportDir + "/Logs", supportDir + "/DFLogs") : (logDir, logDir)
    }

    // Папки даних
    static let supportDir = NSHomeDirectory() + "/Library/Application Support/ArduTune"
    static let folders: [(name: String, sub: String, icon: String, text: String)] = [
        ("Записи MAVLink (tlog)", "Logs", "waveform.path.ecg", "Телеметрія, яку застосунок пише з кожного підключення."),
        ("Логи польотника (.bin)", "DFLogs", "doc.text", "Dataflash-логи, завантажені з польотника."),
        ("Прошивки", "Firmware", "square.and.arrow.down.on.square", "Завантажені файли прошивок і каталог."),
        ("Кеш карт", "MapCache", "map.fill", "Завантажені плитки карт для роботи без мережі."),
        ("Резервні копії параметрів", "Backups", "externaldrive.badge.timemachine", "Копії параметрів перед прошиванням."),
        ("Місії", "Mission", "map", "Чернетка місії."),
        ("PID: історія та знімки", "Tune", "dial.medium", "Знімки налаштувань PID і історія змін."),
    ]
}

private func fileSize(_ path: String, ext: String) -> Int64 {
    let fm = FileManager.default
    return ((try? fm.contentsOfDirectory(atPath: path)) ?? []).filter { $0.lowercased().hasSuffix("." + ext) }
        .reduce(Int64(0)) { $0 + Int64(((try? fm.attributesOfItem(atPath: path + "/" + $1))?[.size] as? Int) ?? 0) }
}

private func dirSize(_ path: String) -> Int64 {
    guard let en = FileManager.default.enumerator(at: URL(fileURLWithPath: path), includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
    var t: Int64 = 0
    for case let u as URL in en { t += Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    return t
}

struct SettingsView: View {
    @Environment(Store.self) var s
    @AppStorage("app.theme") private var theme = "system"
    @AppStorage("app.fullscreen") private var fullscreen = false
    @AppStorage("conn.gcsid") private var gcsID = 255
    @AppStorage("conn.autoOnLaunch") private var autoConnect = true
    @AppStorage("mission.loadOnConnect") private var loadMission = false
    @AppStorage("tele.custom") private var customRates = false
    @AppStorage("map.cacheOnly") private var cacheOnly = false
    @AppStorage("map.trackLen") private var trackLen = 5000
    @State private var sizes: [String: Int64] = [:]
    @State private var cacheBytes = 0
    @State private var note: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                PageTitle(title: String(localized: "Налаштування ArduTune"), subtitle: String(localized: "Вигляд, підключення, швидкості телеметрії, карти, дані й профілі налаштувань застосунку. Параметри польотника тут не змінюються."))
                appearance
                connection
                unitsCard
                HotKeysCard()
                voiceCard
                telemetry
                maps
                dataFolders
                profiles
                about
                if let n = note { Label(LocalizedStringKey(n), systemImage: "info.circle.fill").font(.callout).foregroundStyle(.secondary) }
            }
            .padding()
        }
        .task { await refreshSizes() }
    }

    // MARK: Вигляд
    var appearance: some View {
        Card(title: String(localized: "Вигляд"), icon: "paintbrush", text: String(localized: "Тема застосунку, запуск і мова інтерфейсу.")) {
            row("Тема", "Системна підлаштовується під macOS; світла й темна фіксують вигляд.") {
                Picker("", selection: $theme) {
                    Text("Системна").tag("system"); Text("Світла").tag("light"); Text("Темна").tag("dark")
                }.pickerStyle(.segmented).labelsHidden().frame(width: 280)
                    .onChange(of: theme) { _, _ in AppSettings.applyTheme() }
            }
            Divider().opacity(0.4)
            row("Запускати на весь екран", "Вікно застосунку відкривається на весь екран.") { Toggle("", isOn: $fullscreen).toggleStyle(.switch).labelsHidden() }
            Divider().opacity(0.4)
            row("Мова інтерфейсу", "Українська або English. Після зміни ArduTune перезапускається; у режимі українською всі написи лишаються як є.") {
                Picker("", selection: Binding(get: { AppLanguage.current }, set: { AppLanguage.change(to: $0) })) { Text("Українська").tag("uk"); Text("English").tag("en") }
                    .labelsHidden().frame(width: 160)
            }
        }
    }

    // MARK: Підключення
    var connection: some View {
        Card(title: String(localized: "Підключення"), icon: "cable.connector", text: String(localized: "Поведінка при запуску, ідентифікатор станції та автоматичне читання місії.")) {
            row("Підключатись автоматично при запуску", "Застосунок сам підключається до польотника, коли знаходить його на USB. Вимкнено: потрібно натиснути «Connect».") {
                Toggle("", isOn: $autoConnect).toggleStyle(.switch).labelsHidden()
            }
            Divider().opacity(0.4)
            row("Читати місію при підключенні", "Після підключення автоматично завантажується місія з польотника на сторінку Mission.") {
                Toggle("", isOn: $loadMission).toggleStyle(.switch).labelsHidden()
            }
            Divider().opacity(0.4)
            row("GCS ID (системний ID станції)", "Ідентифікатор, під яким ArduTune підписує команди (MAVLink). Стандарт 255; змінюйте, лише якщо на лінку кілька станцій. Значення 1 збігається з автопілотом.") {
                HStack(spacing: 8) {
                    Stepper(value: $gcsID, in: 1...255) { Text("\(gcsID)").font(.system(.body, design: .monospaced)).frame(width: 44, alignment: .trailing) }
                        .onChange(of: gcsID) { _, _ in AppSettings.pushGcsID() }
                    if gcsID == 1 { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help("ID 1 використовується автопілотом") }
                    if gcsID != 255 { Button("255") { gcsID = 255 }.controlSize(.small) }
                }
            }
        }
    }

    // MARK: Одиниці виміру
    @AppStorage("units.dist") private var uDist = "m"
    @AppStorage("units.alt") private var uAlt = "m"
    @AppStorage("units.speed") private var uSpeed = "ms"
    @AppStorage("units.coord") private var uCoord = "deg"
    var unitsCard: some View {
        Card(title: String(localized: "Одиниці виміру"), icon: "ruler", text: String(localized: "Як показуються відстані, висота й швидкість у HUD, Flight Data, Mission (телеметрія, симуляція, 3D), лінійці й підсумках. Параметри польотника, редактор точок місії й сторінки налаштувань лишаються в метрах і м/с, як у Mission Planner.")) {
            row("Відстань", "Відстань до точки, до дому, довжина маршруту, лінійка. Великі значення показуються в км або милях.") {
                Picker("", selection: $uDist) { Text("метри").tag("m"); Text("фути").tag("ft") }.pickerStyle(.segmented).labelsHidden().frame(width: 200)
            }
            Divider().opacity(0.4)
            row("Висота", "Висота над точкою зльоту, над рівнем моря й над рельєфом.") {
                Picker("", selection: $uAlt) { Text("метри").tag("m"); Text("фути").tag("ft") }.pickerStyle(.segmented).labelsHidden().frame(width: 200)
            }
            Divider().opacity(0.4)
            row("Швидкість", "Наземна й повітряна швидкості. Вертикальна швидкість лишається в м/с.") {
                Picker("", selection: $uSpeed) {
                    Text("м/с").tag("ms"); Text("км/год").tag("kmh"); Text("миль/год").tag("mph"); Text("вузли").tag("kn")
                }.pickerStyle(.segmented).labelsHidden().frame(width: 300)
            }
            Divider().opacity(0.4)
            row("Координати", "Формат координат у Flight Data та Mission: десяткові градуси або MGRS (військова сітка, WGS84). Редактор точок і файли місій лишаються в градусах.") {
                Picker("", selection: $uCoord) { Text("Градуси").tag("deg"); Text("Г°М'С\"").tag("dms"); Text("MGRS").tag("mgrs") }.pickerStyle(.segmented).labelsHidden().frame(width: 260)
            }
            Divider().opacity(0.4)
            HStack(spacing: 10) {
                Image(systemName: "eye").foregroundStyle(.secondary)
                Text("Приклад: 120 м відстані = \(Units.dist(120)), висота 85 м = \(Units.alt(85)), швидкість 12 м/с = \(Units.speed(12)).").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Голосові сповіщення
    @AppStorage("voice.on") private var voiceOn = false
    @AppStorage("voice.mode") private var vMode = true
    @AppStorage("voice.arm") private var vArm = true
    @AppStorage("voice.battery") private var vBattery = true
    @AppStorage("voice.gps") private var vGPS = true
    @AppStorage("voice.link") private var vLink = true
    @AppStorage("voice.messages") private var vMessages = true
    @AppStorage("voice.vario") private var vVario = false
    @AppStorage("voice.severity") private var vSeverity = 4
    @AppStorage("voice.rate") private var vRate = 0.5
    @AppStorage("voice.volume") private var vVolume = 1.0
    @AppStorage("voice.voice") private var vVoice = ""
    var voiceCard: some View {
        Card(title: String(localized: "Голосові сповіщення"), icon: "speaker.wave.2", text: String(localized: "Озвучення важливих подій польоту системним голосом macOS. За замовчуванням вимкнено. Мова озвучення відповідає мові інтерфейсу.")) {
            row("Голосові сповіщення", "Головний перемикач: без нього ніщо не озвучується.") { Toggle("", isOn: $voiceOn).toggleStyle(.switch).labelsHidden() }
            if voiceOn {
                Divider().opacity(0.4)
                HStack(spacing: 18) {
                    Toggle("Режим польоту", isOn: $vMode).toggleStyle(.checkbox)
                    Toggle("ARM / DISARM", isOn: $vArm).toggleStyle(.checkbox)
                    Toggle("Заряд батареї (30, 20, 10 %)", isOn: $vBattery).toggleStyle(.checkbox)
                }
                HStack(spacing: 18) {
                    Toggle("GPS (поява й втрата)", isOn: $vGPS).toggleStyle(.checkbox)
                    Toggle("Зв'язок з польотником", isOn: $vLink).toggleStyle(.checkbox)
                    Toggle("Повідомлення польотника", isOn: $vMessages).toggleStyle(.checkbox)
                }
                if vMessages {
                    row("Рівень повідомлень", "Озвучуються повідомлення польотника цього рівня й важливіші.") {
                        Picker("", selection: $vSeverity) {
                            Text("Аварійні (0–2)").tag(2); Text("Помилки (3)").tag(3); Text("Попередження (4)").tag(4); Text("Сповіщення (5)").tag(5); Text("Усі (6)").tag(6)
                        }.labelsHidden().frame(width: 190)
                    }
                }
                Divider().opacity(0.4)
                row("Звуковий варіометр", "Тон і частота писків змінюються від швидкості набору й зниження висоти (лише в польоті, при ARM).") { Toggle("", isOn: $vVario).toggleStyle(.switch).labelsHidden() }
                Divider().opacity(0.4)
                row("Голос", "Системні голоси macOS для вибраної мови (інші додаються в Системні налаштування → Універсальний доступ → Мовлення).") {
                    Picker("", selection: $vVoice) {
                        Text("Типовий").tag("")
                        ForEach(VoiceAlerts.voices(), id: \.identifier) { Text(lk($0.name)).tag($0.identifier) }
                    }.labelsHidden().frame(width: 220)
                }
                row("Швидкість і гучність", "Швидкість мовлення та гучність озвучення.") {
                    HStack(spacing: 12) {
                        Image(systemName: "hare").foregroundStyle(.secondary); Slider(value: $vRate, in: 0.3...0.7).frame(width: 110)
                        Image(systemName: "speaker.wave.2").foregroundStyle(.secondary); Slider(value: $vVolume, in: 0.2...1).frame(width: 90)
                        Button("Перевірити") { VoiceAlerts.shared.test() }.controlSize(.small)
                    }
                }
            }
        }
    }

    // MARK: Телеметрія
    var telemetry: some View {
        Card(title: String(localized: "Швидкості телеметрії"), icon: "dot.radiowaves.left.and.right", text: String(localized: "Скільки разів на секунду польотник надсилає кожну групу повідомлень. Менші значення розвантажують радіоканал, більші роблять HUD плавнішим.")) {
            row("Задати власні швидкості", "Вимкнено: використовуються налаштування самого польотника (SRn_*). Застосовується одразу й після кожного підключення.") {
                Toggle("", isOn: $customRates).toggleStyle(.switch).labelsHidden()
                    .onChange(of: customRates) { _, on in if on, s.connected { AppSettings.applyRates() } }
            }
            ForEach(AppSettings.rateGroups, id: \.key) { g in
                Divider().opacity(0.4)
                RateRow(group: g, enabled: customRates, connected: s.connected)
            }
            if customRates && !s.connected { Text("Польотник не підключений: швидкості буде застосовано при підключенні.").font(.caption).foregroundStyle(.secondary) }
        }
    }

    // MARK: Карти
    var maps: some View {
        Card(title: String(localized: "Карти"), icon: "map", text: String(localized: "Кеш плиток, режим без мережі та довжина сліду апарата.")) {
            row("Лише кеш (без мережі)", "Показувати тільки вже завантажені плитки: для польових умов без інтернету. Нові ділянки карти не завантажуються.") {
                Toggle("", isOn: $cacheOnly).toggleStyle(.switch).labelsHidden()
            }
            Divider().opacity(0.4)
            row("Кеш плиток", String(localized: "Зараз зайнято \(ByteCountFormatter.string(fromByteCount: Int64(cacheBytes), countStyle: .file)); ліміт 600 МБ.")) {
                Button("Очистити кеш") {
                    TileOverlay.session.configuration.urlCache?.removeAllCachedResponses(); refreshCache(); note = String(localized: "Кеш карт очищено.")
                }.controlSize(.small)
            }
            Divider().opacity(0.4)
            row("Довжина сліду", "Скільки точок траєкторії зберігається на картах Flight Data й Mission.") {
                HStack(spacing: 8) {
                    Picker("", selection: $trackLen) { ForEach([200, 500, 1000, 2000, 5000, 10000], id: \.self) { Text("\($0)").tag($0) } }.labelsHidden().frame(width: 110)
                    Button("Очистити слід") { s.track = [] }.controlSize(.small)
                }
            }
        }
        .onAppear { refreshCache() }
    }

    // MARK: Дані
    var dataFolders: some View {
        Card(title: String(localized: "Дані й папки"), icon: "folder", text: String(localized: "Де зберігаються файли застосунку. Всі папки лежать у \(AppSettings.supportDir.replacingOccurrences(of: NSHomeDirectory(), with: "~")).")) {
            logFolderRow
            Divider().opacity(0.4)
            ForEach(AppSettings.folders, id: \.sub) { f in
                HStack(spacing: 10) {
                    Image(systemName: f.icon).frame(width: 22).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(LocalizedStringKey(f.name)).font(.callout.weight(.medium))
                        Text(LocalizedStringKey(f.text)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(lk(sizes[f.sub].map { $0 == 0 ? "порожньо" : ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "…")).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Button("Показати") {
                        let p = f.sub == "Logs" ? AppSettings.logFolders.tlog : (f.sub == "DFLogs" ? AppSettings.logFolders.df : AppSettings.supportDir + "/" + f.sub)
                        try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(URL(fileURLWithPath: p))
                    }.controlSize(.small)
                }
            }
            Label("Ці файли лежать поза застосунком: оновлення, перевстановлення чи видалення ArduTune їх не зачіпає, вони лишаються на вашому Mac.", systemImage: "lock.shield").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button { NSWorkspace.shared.open(URL(fileURLWithPath: AppSettings.supportDir)) } label: { Label("Відкрити головну папку", systemImage: "folder") }.controlSize(.small)
                Button { Task { await refreshSizes() } } label: { Label("Оновити розміри", systemImage: "arrow.clockwise") }.controlSize(.small)
            }
        }
    }

    // MARK: Папка логів
    var logFolderRow: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "folder.badge.gearshape").frame(width: 22).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("Папка логів").font(.callout.weight(.medium))
                Text(lk(logDirText.isEmpty ? "Типова: записи MAVLink й логи польотника лежать у власних підпапках застосунку." : logDirText))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
            }
            Spacer(minLength: 8)
            Button("Обрати…") { chooseLogDir() }.controlSize(.small)
            Button("Типова") { setLogDir("") }.controlSize(.small).disabled(logDirText.isEmpty)
        }
    }
    @AppStorage("data.logDir") private var logDirText = ""

    func chooseLogDir() {
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true; p.allowsMultipleSelection = false
        p.message = String(localized: "Оберіть папку для логів (записи MAVLink .tlog і логи польотника .bin)")
        guard p.runModal() == .OK, let u = p.url else { return }
        setLogDir(u.path)
    }
    func setLogDir(_ new: String) {
        let old = AppSettings.logFolders
        logDirText = new
        AppSettings.pushLogDir()
        let now = AppSettings.logFolders
        // запропонувати перенести наявні файли
        if old.tlog != now.tlog || old.df != now.df {
            let a = NSAlert(); a.messageText = String(localized: "Перемістити наявні логи в нову папку?")
            a.informativeText = String(localized: "Записи .tlog і логи .bin з попередньої папки буде переміщено. Якщо відмовитесь, вони лишаться на місці й не відображатимуться в застосунку, поки ви не поверните папку.")
            a.addButton(withTitle: String(localized: "Перемістити")); a.addButton(withTitle: String(localized: "Не переміщувати"))
            if a.runModal() == .alertFirstButtonReturn {
                let n = Self.moveLogs(from: old.tlog, to: now.tlog, ext: "tlog") + Self.moveLogs(from: old.df, to: now.df, ext: "bin")
                note = String(localized: "Переміщено файлів: \(n). Нова папка логів: \(now.tlog)")
            } else { note = String(localized: "Папку логів змінено; старі файли не переміщено.") }
        }
        Task { await refreshSizes() }
    }
    /// Переміщує файли з розширенням `ext` між папками (наявні в цілі не перезаписуються).
    static func moveLogs(from: String, to: String, ext: String) -> Int {
        guard from != to else { return 0 }
        let fm = FileManager.default
        try? fm.createDirectory(atPath: to, withIntermediateDirectories: true)
        var n = 0
        for f in (try? fm.contentsOfDirectory(atPath: from)) ?? [] where f.lowercased().hasSuffix("." + ext) {
            if fm.fileExists(atPath: to + "/" + f) { continue }
            if (try? fm.moveItem(atPath: from + "/" + f, toPath: to + "/" + f)) != nil { n += 1 }
        }
        return n
    }

    // MARK: Профілі
    var profiles: some View {
        Card(title: String(localized: "Профіль налаштувань"), icon: "square.and.arrow.up.on.square", text: String(localized: "Зберегти налаштування інтерфейсу (теми, вкладки, HUD, карти, одиниці, швидкості) у файл і завантажити на іншому комп'ютері.")) {
            HStack {
                Button { exportProfile() } label: { Label("Зберегти у файл…", systemImage: "square.and.arrow.up") }
                Button { importProfile() } label: { Label("Завантажити з файлу…", systemImage: "square.and.arrow.down") }
                Spacer()
                Button(role: .destructive) { resetSettings() } label: { Label("Скинути налаштування інтерфейсу", systemImage: "arrow.counterclockwise") }
            }
            Text("Профіль не містить параметрів польотника й паролів.").font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Про програму й двигун
    var about: some View {
        Card(title: String(localized: "Програма й двигун"), icon: "info.circle", text: nil) {
            HStack(spacing: 16) {
                Text("ArduTune \(AppInfo.version)" + (AppInfo.build.isEmpty ? "" : String(localized: " (збірка \(AppInfo.build))"))).font(.callout.weight(.medium))
                Spacer()
                Label(lk(s.engineUp ? "Двигун працює (127.0.0.1:14560)" : "Двигун не відповідає"), systemImage: s.engineUp ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(s.engineUp ? Color.green : Color.orange)
                Button("Перезапустити двигун") { s.restartEngine(); note = String(localized: "Двигун перезапускається; з'єднання відновиться автоматично.") }.controlSize(.small)
            }
            Text("Застосунок не збирає й не надсилає жодних даних про використання.").font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Допоміжне
    func row<C: View>(_ title: String, _ hint: String, @ViewBuilder _ control: () -> C) -> some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(title)).font(.callout.weight(.medium))
                Text(LocalizedStringKey(hint)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            control()
        }
    }

    func refreshSizes() async {
        let base = AppSettings.supportDir
        let r = await Task.detached { () -> [String: Int64] in
            var d: [String: Int64] = [:]
            for f in AppSettings.folders {
                if f.sub == "Logs", !AppSettings.logDir.isEmpty { d[f.sub] = fileSize(AppSettings.logDir, ext: "tlog"); continue }
                if f.sub == "DFLogs", !AppSettings.logDir.isEmpty { d[f.sub] = fileSize(AppSettings.logDir, ext: "bin"); continue }
                d[f.sub] = dirSize(base + "/" + f.sub)
            }
            return d
        }.value
        sizes = r
    }
    func refreshCache() { cacheBytes = TileOverlay.session.configuration.urlCache?.currentDiskUsage ?? 0 }

    static var exportable: [String: Any] {
        let dom = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "com.keshkovsky.ardutune") ?? [:]
        return dom.filter { k, v in
            !k.hasPrefix("NS") && !k.hasPrefix("Apple") && !k.hasPrefix("com.apple") && (v is String || v is NSNumber || (v as? [String]) != nil)
        }
    }
    func exportProfile() {
        let p = NSSavePanel(); p.nameFieldStringValue = "ArduTune.profile.json"; p.allowedContentTypes = [.json]
        guard p.runModal() == .OK, let url = p.url,
              let data = try? JSONSerialization.data(withJSONObject: Self.exportable, options: [.prettyPrinted, .sortedKeys]) else { return }
        do { try data.write(to: url); note = String(localized: "Профіль збережено: \(url.lastPathComponent) (\(Self.exportable.count) налаштувань).") } catch { note = String(localized: "Не вдалося записати файл.") }
    }
    func importProfile() {
        let p = NSOpenPanel(); p.allowedContentTypes = [.json]
        guard p.runModal() == .OK, let url = p.url, let d = try? Data(contentsOf: url),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { note = String(localized: "Файл не схожий на профіль ArduTune."); return }
        var n = 0
        for (k, v) in j where v is String || v is NSNumber || (v as? [String]) != nil { UserDefaults.standard.set(v, forKey: k); n += 1 }
        AppSettings.applyTheme(); AppSettings.pushGcsID()
        note = String(localized: "Завантажено \(n) налаштувань. Деякі набудуть чинності після перезапуску застосунку.")
    }
    func resetSettings() {
        let a = NSAlert(); a.messageText = String(localized: "Скинути налаштування інтерфейсу?")
        a.informativeText = String(localized: "Теми, вкладки, HUD, карти й інші налаштування застосунку повернуться до типових. Параметри польотника, файли й логи не змінюються.")
        a.addButton(withTitle: String(localized: "Скинути")); a.addButton(withTitle: String(localized: "Скасувати"))
        guard a.runModal() == .alertFirstButtonReturn else { return }
        if let id = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: id) }
        AppSettings.applyTheme()
        note = String(localized: "Налаштування скинуто. Перезапустіть застосунок, щоб повернути все до типового вигляду.")
    }
}

/// Рядок швидкості однієї групи телеметрії.
struct RateRow: View {
    let group: (key: String, title: String, hint: String, ids: [Int], def: Int)
    let enabled: Bool
    let connected: Bool
    @State private var hz = 0

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(group.title)).font(.callout.weight(.medium))
                Text(LocalizedStringKey(group.hint)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Picker("", selection: Binding(get: { hz }, set: { v in
                hz = v
                UserDefaults.standard.set(v, forKey: "tele.rate." + group.key)
                if enabled && connected { for id in group.ids { EngineAPI.post("/msg/interval?id=\(id)&hz=\(v)") } }
            })) { ForEach(AppSettings.rateChoices, id: \.self) { Text("\($0) Гц").tag($0) } }
                .labelsHidden().frame(width: 100).disabled(!enabled)
        }
        .onAppear { hz = AppSettings.rate(group.key, def: group.def) }
    }
}
