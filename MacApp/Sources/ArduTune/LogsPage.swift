import SwiftUI
import Charts
import MapKit
import AppKit

// MARK: - Моделі даних двигуна

struct FCLogEntry: Decodable, Identifiable { let id: Int; let size: Int; let time: Int; var local: String? }
struct DFStatus: Decodable { let state: String; let id: Int; let size: Int; let received: Int; let path: String?; let error: String?; let bps: Double }
struct LocalLog: Decodable, Identifiable { let name: String; let path: String; let size: Int; let date: String; var id: String { path } }

@Observable @MainActor
final class LogsModel {
    var fcLogs: [FCLogEntry] = []
    var local: [LocalLog] = []
    var loadingList = false
    var error: String?
    var note: String?
    var status: DFStatus?
    var log: DFLog?
    var logName: String?
    var parsing = false
    var checks: [LogCheck] = []
    @ObservationIgnored private var polling = false

    var downloading: Bool { status?.state == "running" }

    func refreshLocal() async {
        if let d = try? await EngineAPI.data("/dflogs/local"), let l = try? JSONDecoder().decode([LocalLog].self, from: d) { local = l }
        relink()
    }

    /// Лог польотника вважається завантаженим, якщо на Mac є файл того ж розміру (перевага: той, що містить номер логу в імені).
    func relink() {
        for i in fcLogs.indices {
            let e = fcLogs[i]
            let same = local.filter { $0.size == e.size && e.size > 0 }
            let pick = same.first { $0.name.contains(String(format: "_%03d_", e.id)) } ?? same.first
            fcLogs[i].local = pick?.path
        }
    }

    func refreshFC() async {
        loadingList = true; error = nil
        defer { loadingList = false }
        do {
            let d = try await EngineAPI.data("/dflogs/list")
            fcLogs = try JSONDecoder().decode([FCLogEntry].self, from: d).sorted { $0.id > $1.id }
            if fcLogs.isEmpty { note = String(localized: "На польотнику немає логів") }
        } catch let e as EngineAPI.APIError { error = e.message } catch let e { error = e.localizedDescription }
        await refreshLocal()
    }

    func download(_ id: Int, openAfter: Bool = true) async {
        error = nil
        do { try await EngineAPI.send("/dflogs/download?id=\(id)") } catch let e as EngineAPI.APIError { error = e.message; return } catch let e { error = e.localizedDescription; return }
        polling = true
        while polling {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let d = try? await EngineAPI.data("/dflogs/status"), let st = try? JSONDecoder().decode(DFStatus.self, from: d) else { continue }
            status = st
            if st.state != "running" { polling = false }
        }
        await refreshLocal()
        if let st = status {
            if st.state == "error" { error = st.error }
            if st.state == "done", openAfter, let p = st.path { note = String(localized: "Лог #\(id) завантажено"); await open(URL(fileURLWithPath: p)) }
        }
    }

    func cancel() { EngineAPI.post("/dflogs/cancel") }

    func erase() async {
        do { try await EngineAPI.send("/dflogs/erase"); fcLogs = []; note = String(localized: "Логи на польотнику видалено") }
        catch let e as EngineAPI.APIError { error = e.message } catch let e { error = e.localizedDescription }
    }

    func open(_ url: URL) async {
        parsing = true; error = nil; checks = []
        let parsed = await Task.detached(priority: .userInitiated) { () -> (DFLog, [LogCheck])? in
            guard let l = DFLog(url: url) else { return nil }
            _ = l.messages; _ = l.parameters            // прогрів лінивих обчислень (потокобезпечність)
            return (l, LogAnalysis.run(l))
        }.value
        parsing = false
        if let (l, c) = parsed { log = l; checks = c; logName = url.lastPathComponent }
        else { error = String(localized: "Не вдалося розібрати лог (це не Dataflash .bin або файл пошкоджений)") }
    }
}

// MARK: - Сторінка Logs

struct LogsPage: View {
    @Environment(Store.self) var s
    @State private var m = LogsModel()
    @State private var tab = "Огляд"
    static let tabs = ["Огляд", "Помічник", "Графіки", "PID Review", "Filter Review", "Карта", "Повідомлення", "Параметри", "Навчання"]
    @State private var graphRequest: GraphRequest?
    @AppStorage("logs.sidebar") private var showSidebar = true

    /// Язичок на краю лівої колонки: показує/ховає панель файлів і польотника. Стоїть на межі панелі (а коли її сховано, біля краю вікна).
    var sidebarToggle: some View {
        Button { withAnimation(.snappy(duration: 0.22)) { showSidebar.toggle() } } label: {
            Image(systemName: showSidebar ? "chevron.left" : "chevron.right").font(.system(size: 11, weight: .bold))
                .foregroundStyle(showSidebar ? Color.secondary : Color.accentColor)
                .frame(width: 20, height: 46)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.18)))
                .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
        }
        .buttonStyle(.plain).help(lk(showSidebar ? "Сховати панель файлів і польотника" : "Показати панель файлів і польотника"))
    }

    var body: some View {
        HStack(spacing: 0) {
            if showSidebar {
                sidebar.frame(width: 300).frame(maxHeight: .infinity, alignment: .top)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                Divider()
            }
            review.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.leading, showSidebar ? 0 : 30)      // місце під язичок, коли панель сховано
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .topLeading) {
            sidebarToggle.offset(x: showSidebar ? 300 - 10 : 4, y: 14)
        }
        .task { await m.refreshLocal() }
    }

    // MARK: Ліва колонка: польотник і файли
    var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Card(title: String(localized: "На польотнику"), icon: "externaldrive", text: nil) {
                    HStack {
                        Button { Task { await m.refreshFC() } } label: { Label("Отримати список", systemImage: "arrow.clockwise") }.disabled(!s.connected || m.loadingList || m.downloading)
                        if m.loadingList { ProgressView().controlSize(.small) }
                        Spacer()
                        Button(role: .destructive) { confirmErase() } label: { Image(systemName: "trash") }.help("Видалити всі логи на польотнику").disabled(!s.connected || s.armed || m.fcLogs.isEmpty || m.downloading)
                    }
                    if !s.connected { Text("Підключіть польотник, щоб завантажити логи.").font(.caption).foregroundStyle(.secondary) }
                    if s.armed { Label("ARMED: завантаження заблоковано", systemImage: "lock.fill").font(.caption).foregroundStyle(.red) }
                    if let st = m.status, st.state == "running" {
                        VStack(alignment: .leading, spacing: 4) {
                            ProgressView(value: Double(st.received), total: Double(max(1, st.size)))
                            HStack {
                                Text("Лог #\(st.id): \(ByteCountFormatter.string(fromByteCount: Int64(st.received), countStyle: .file)) з \(ByteCountFormatter.string(fromByteCount: Int64(st.size), countStyle: .file))").font(.caption.monospacedDigit())
                                Spacer()
                                Text("\(ByteCountFormatter.string(fromByteCount: Int64(st.bps), countStyle: .file))/с").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                Button("Скасувати") { m.cancel() }.controlSize(.small)
                            }
                        }
                    }
                    ForEach(m.fcLogs) { e in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Лог #\(e.id)").font(.callout.weight(.medium))
                                Text(lk((e.time > 0 ? Date(timeIntervalSince1970: TimeInterval(e.time)).formatted(date: .abbreviated, time: .shortened) : "час невідомий") + " · " + ByteCountFormatter.string(fromByteCount: Int64(e.size), countStyle: .file)))
                                    .font(.caption).foregroundStyle(.secondary)
                                if e.local != nil { Label("Завантажено на Mac", systemImage: "checkmark.circle.fill").font(.caption2).foregroundStyle(.green) }
                            }
                            Spacer()
                            if let p = e.local {
                                Button("Відкрити") { Task { await m.open(URL(fileURLWithPath: p)) } }.controlSize(.small)
                            } else {
                                Button { Task { await m.download(e.id) } } label: { Label("Завантажити", systemImage: "arrow.down.circle") }.controlSize(.small).disabled(m.downloading || s.armed)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    if let n = m.note { Text(LocalizedStringKey(n)).font(.caption).foregroundStyle(.secondary) }
                    if let e = m.error { Label(LocalizedStringKey(e), systemImage: "exclamationmark.octagon.fill").font(.caption).foregroundStyle(.red) }
                }
                TlogCard()
                Card(title: String(localized: "Логи польотника на Mac"), icon: "internaldrive", text: String(localized: "Dataflash .bin, завантажені з польотника або відкриті вручну.")) {
                    HStack {
                        Button { openFile() } label: { Label("Відкрити файл…", systemImage: "folder") }
                        Button { NSWorkspace.shared.open(URL(fileURLWithPath: AppSettings.logFolders.df)) } label: { Image(systemName: "arrow.up.forward.app") }.help("Показати папку з логами")
                    }
                    if m.local.isEmpty { Text("Завантажених логів немає").font(.caption).foregroundStyle(.secondary) }
                    ForEach(m.local) { l in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(LocalizedStringKey(l.name)).font(.system(.caption, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                                Text("\(l.date) · \(ByteCountFormatter.string(fromByteCount: Int64(l.size), countStyle: .file))").font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button { Task { await m.open(URL(fileURLWithPath: l.path)) } } label: { Image(systemName: "chart.xyaxis.line") }.help("Переглянути й проаналізувати")
                            Button(role: .destructive) { deleteLocal(l) } label: { Image(systemName: "trash") }.help("Видалити файл з Mac")
                        }
                        .buttonStyle(.borderless)
                        .padding(.vertical, 2)
                        .background(m.logName == l.name ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
            .padding(12)
        }
    }

    // MARK: Права частина: перегляд
    @ViewBuilder var review: some View {
        if m.parsing {
            VStack(spacing: 10) { ProgressView(); Text("Розбір логу…").foregroundStyle(.secondary) }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let log = m.log {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(lk(m.logName ?? "")).font(.headline).lineLimit(1).truncationMode(.middle)
                        Text("\(log.vehicleName) · \(Int(log.duration) / 60) хв \(Int(log.duration) % 60) с").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Menu {
                        Button("Створити KML + GPX") { exportTrack(log) }
                        Button("Конвертувати в .log (текст)") { exportText(log) }
                    } label: { Label("Експорт", systemImage: "square.and.arrow.up") }.menuStyle(.borderlessButton).fixedSize()
                    Button { m.log = nil } label: { Image(systemName: "xmark.circle") }.buttonStyle(.borderless).help("Закрити лог")
                }
                .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 6)
                tabBar
                Divider()
                Group {
                    switch tab {
                    case "Помічник": LogAssistantView(log: log, openGraph: { graphRequest = $0; tab = "Графіки" }, openMessages: { tab = "Повідомлення" })
                    case "Навчання": LogLearnView(log: log, openGraph: { graphRequest = $0; tab = "Графіки" })
                    case "Графіки": LogGraphView(log: log, request: $graphRequest)
                    case "PID Review": LogPIDReviewView(log: log)
                    case "Filter Review": LogFilterReviewView(log: log)
                    case "Карта": LogMapView(log: log)
                    case "Повідомлення": LogMessagesView(log: log)
                    case "Параметри": LogParamsView(log: log)
                    default: LogOverview(log: log, checks: m.checks)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            if tab == "Навчання" {
                VStack(spacing: 0) {
                    HStack { Text("Навчання читанню логів").font(.headline); Spacer(); Button("Назад") { tab = "Огляд" } }.padding(10)
                    Divider()
                    LogLearnView(log: nil, openGraph: { _ in })
                }
            } else {
                ContentUnavailableView {
                    Label("Лог не відкрито", systemImage: "chart.xyaxis.line")
                } description: {
                    Text("Завантажте лог з польотника (Download via MAVLink) або відкрийте файл .bin. Далі доступні огляд польоту, помічник, графіки, карта, повідомлення, параметри та навчання.")
                } actions: {
                    HStack { Button("Відкрити файл…") { openFile() }; Button("Навчання читанню логів") { tab = "Навчання" } }
                }
            }
        }
    }

    /// Вкладки: прокручувана стрічка капсул, що не виходить за ширину вікна.
    var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Self.tabs, id: \.self) { name in
                    let on = tab == name
                    Button { tab = name } label: {
                        Text(LocalizedStringKey(name)).font(.system(size: 13, weight: on ? .semibold : .regular)).padding(.horizontal, 12).padding(.vertical, 5)
                            .background(on ? Color.primary.opacity(0.12) : Color.primary.opacity(0.04), in: Capsule()).contentShape(Capsule())
                    }.buttonStyle(.plain)
                }
            }.padding(.horizontal, 12).padding(.bottom, 8)
        }
    }

    // MARK: Дії
    func openFile() {
        let p = NSOpenPanel(); p.allowedFileTypes = ["bin", "BIN"]; p.allowsOtherFileTypes = true
        p.directoryURL = URL(fileURLWithPath: AppSettings.logFolders.df)
        p.message = String(localized: "Оберіть Dataflash-лог (.bin)")
        if p.runModal() == .OK, let u = p.url { Task { await m.open(u) } }
    }
    func confirmErase() {
        let a = NSAlert(); a.messageText = String(localized: "Видалити ВСІ логи на польотнику?"); a.informativeText = String(localized: "Дію не можна скасувати. Переконайтеся, що потрібні логи вже завантажено.")
        a.alertStyle = .critical; a.addButton(withTitle: String(localized: "Видалити все")); a.addButton(withTitle: String(localized: "Скасувати"))
        if a.runModal() == .alertFirstButtonReturn { Task { await m.erase() } }
    }
    func deleteLocal(_ l: LocalLog) {
        let a = NSAlert(); a.messageText = String(localized: "Видалити файл «\(loc(l.name))» з Mac?"); a.alertStyle = .warning
        a.addButton(withTitle: String(localized: "Видалити")); a.addButton(withTitle: String(localized: "Скасувати"))
        guard a.runModal() == .alertFirstButtonReturn else { return }
        try? FileManager.default.trashItem(at: URL(fileURLWithPath: l.path), resultingItemURL: nil)
        if m.logName == l.name { m.log = nil }
        Task { await m.refreshLocal() }
    }
    func exportTrack(_ log: DFLog) {
        let tr = log.track()
        guard tr.count > 1 else { m.note = String(localized: "У лозі немає GPS-траєкторії"); return }
        let p = NSSavePanel(); p.nameFieldStringValue = (m.logName ?? "track").replacingOccurrences(of: ".bin", with: "")
        p.message = String(localized: "Файли KML і GPX буде збережено з цим іменем")
        guard p.runModal() == .OK, let base = p.url?.deletingPathExtension() else { return }
        let coords = tr.map { "\($0.lon),\($0.lat),\($0.alt)" }.joined(separator: " ")
        let kml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<kml xmlns=\"http://www.opengis.net/kml/2.2\"><Document><Placemark><name>\(m.logName ?? "Flight")</name><Style><LineStyle><color>ff0000ff</color><width>3</width></LineStyle></Style><LineString><altitudeMode>absolute</altitudeMode><coordinates>\(coords)</coordinates></LineString></Placemark></Document></kml>"
        let pts = tr.map { "<trkpt lat=\"\($0.lat)\" lon=\"\($0.lon)\"><ele>\($0.alt)</ele></trkpt>" }.joined(separator: "\n")
        let gpx = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<gpx version=\"1.1\" creator=\"ArduTune\" xmlns=\"http://www.topografix.com/GPX/1/1\"><trk><name>\(m.logName ?? "Flight")</name><trkseg>\n\(pts)\n</trkseg></trk></gpx>"
        try? kml.write(to: base.appendingPathExtension("kml"), atomically: true, encoding: .utf8)
        try? gpx.write(to: base.appendingPathExtension("gpx"), atomically: true, encoding: .utf8)
        m.note = String(localized: "Збережено KML і GPX")
    }
    func exportText(_ log: DFLog) {
        let p = NSSavePanel(); p.nameFieldStringValue = (m.logName ?? "log").replacingOccurrences(of: ".bin", with: ".log")
        guard p.runModal() == .OK, let u = p.url else { return }
        m.note = String(localized: "Конвертація…")
        Task.detached {
            let ok = log.exportText(to: u)
            await MainActor.run { m.note = ok ? String(localized: "Збережено: \(u.lastPathComponent)") : "Не вдалося записати файл" }
        }
    }
}

// MARK: - Огляд і автоаналіз

struct LogOverview: View {
    let log: DFLog
    let checks: [LogCheck]
    @State private var typeFilter = ""
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Card(title: String(localized: "Огляд польоту"), icon: "timeline.selection", text: String(localized: "Наведіть курсор на будь-який графік: вертикальна лінія синхронно показує той самий момент на всіх графіках. Позначки під стрічкою режимів це події та помилки.")) {
                    FlightDashboard(log: log)
                }
                Card(title: String(localized: "Автоаналіз"), icon: "checkmark.seal", text: nil) {
                    let bad = checks.filter { $0.status == .fail }.count, warn = checks.filter { $0.status == .warn }.count
                    HStack(spacing: 10) {
                        Pill(text: bad > 0 ? String(localized: "\(bad) критичних") : "критичних немає", tint: bad > 0 ? .red : .green)
                        Pill(text: warn > 0 ? String(localized: "\(warn) зауважень") : "зауважень немає", tint: warn > 0 ? .orange : .green)
                    }
                    ForEach(checks) { c in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: c.icon).foregroundStyle(c.color).frame(width: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(LocalizedStringKey(c.title)).font(.callout.weight(.semibold))
                                Text(LocalizedStringKey(c.detail)).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
                Card(title: String(localized: "Типи повідомлень (\(log.order.count))"), icon: "list.bullet.rectangle", text: nil) {
                    TextField("Фільтр", text: $typeFilter).textFieldStyle(.roundedBorder).frame(width: 220)
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 4) {
                        GridRow { Text("Тип").bold(); Text("Кількість").bold(); Text("Поля").bold() }.font(.caption).foregroundStyle(.secondary)
                        ForEach(log.order.filter { typeFilter.isEmpty || $0.localizedCaseInsensitiveContains(typeFilter) }, id: \.self) { n in
                            GridRow {
                                Text(LocalizedStringKey(n)).font(.system(.caption, design: .monospaced).weight(.semibold))
                                Text("\(log.count(n))").font(.caption.monospacedDigit())
                                Text(lk(log.fields(of: n).joined(separator: ", "))).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                    }
                }
            }
            .padding(12)
        }
    }
}

// MARK: - Графіки

struct PlotPoint: Identifiable { let id: Int; let t: Double; let v: Double }
struct PlotSeries: Identifiable { let id: String; let points: [PlotPoint] }

struct LogGraphView: View {
    let log: DFLog
    var request: Binding<GraphRequest?>? = nil
    @State private var selected: [String] = []
    @State private var series: [PlotSeries] = []
    @State private var search = ""
    @State private var expanded: Set<String> = []
    @State private var filter = 0                 // 0 усі, 1 популярні, 2 найбільше даних

    /// Групи й поля, які найчастіше розбирають під час аналізу польоту (порядок = порядок показу).
    static let defaultPopular: [String: [String]] = [
        "ATT": ["Roll", "DesRoll", "Pitch", "DesPitch", "Yaw", "DesYaw"],
        "RATE": ["R", "RDes", "ROut", "P", "PDes", "POut", "Y", "YDes", "YOut"],
        "VIBE": ["VibeX", "VibeY", "VibeZ", "Clip0", "Clip1", "Clip2", "Clip"],
        "IMU": ["GyrX", "GyrY", "GyrZ", "AccX", "AccY", "AccZ"],
        "BAT": ["Volt", "Curr", "CurrTot", "Res"],
        "BARO": ["Alt", "Press", "Temp"],
        "CTUN": ["ThO", "ThI", "Alt", "DAlt", "CRt", "DCRt"],
        "RCIN": ["C1", "C2", "C3", "C4"],
        "RCOU": ["C1", "C2", "C3", "C4"],
        "GPS": ["Status", "NSats", "HDop", "Spd", "Alt"],
        "XKF4": ["SV", "SP", "SH", "SM", "SVT"],
        "XKF1": ["Roll", "Pitch", "Yaw", "VN", "VE", "VD", "PD"],
        "POS": ["Lat", "Lng", "Alt", "RelHomeAlt"],
        "PIDR": ["Tar", "Act", "P", "I", "D", "FF"],
        "PIDP": ["Tar", "Act", "P", "I", "D", "FF"],
        "PIDY": ["Tar", "Act", "P", "I", "D", "FF"],
        "MODE": ["Mode", "ModeNum"],
        "ERR": ["Subsys", "ECode"],
        "TECS": ["h", "dh", "hdem", "dhdem", "sp", "spdem"],
        "ARSP": ["Airspeed", "DiffPress"],
        "MAG": ["MagX", "MagY", "MagZ"],
        "POWR": ["Vcc", "VServo"],
    ]
    static let defaultOrder = ["ATT", "RATE", "VIBE", "IMU", "BAT", "BARO", "CTUN", "RCIN", "RCOU", "GPS", "XKF4", "XKF1", "POS", "PIDR", "PIDP", "PIDY", "MODE", "ERR", "TECS", "ARSP", "MAG", "POWR"]
    private var pop: LogPopular { LogPopular.shared }
    static func compact(_ n: Int) -> String { n >= 1_000_000 ? String(format: "%.1fM", Double(n) / 1e6) : n >= 10_000 ? "\(n / 1000)k" : n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)" }

    var maxCount: Int { log.order.map { log.count($0) }.max() ?? 1 }
    /// Групи для показу з урахуванням пошуку й швидкого фільтра.
    var visibleGroups: [String] {
        var g = log.order.filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) || log.fields(of: $0).contains { $0.localizedCaseInsensitiveContains(search) } }
        switch filter {
        case 1: g = pop.order.filter { g.contains($0) }
        case 2: g = Array(g.filter { log.count($0) > 0 }.sorted { log.count($0) > log.count($1) }.prefix(14))
        default: break
        }
        return g
    }
    /// У групі спершу популярні поля (із зірочкою), потім решта.
    func orderedFields(_ n: String) -> [String] {
        let all = plottable(n)
        guard let top = pop.fields[n] else { return all }
        return top.filter { all.contains($0) } + all.filter { !top.contains($0) }
    }
    @State private var normalize = false
    @State private var from = 0.0
    @State private var to = 1.0
    @State private var cur = CursorModel()
    @State private var cseries: [CSeries] = []
    static let presets: [(String, [String])] = [
        ("Attitude", ["ATT.Roll", "ATT.DesRoll", "ATT.Pitch", "ATT.DesPitch"]),
        ("Yaw", ["ATT.Yaw", "ATT.DesYaw"]),
        ("Vibration", ["VIBE.VibeX", "VIBE.VibeY", "VIBE.VibeZ"]),
        ("Battery", ["BAT.Volt", "BAT.Curr"]),
        ("RC In", ["RCIN.C1", "RCIN.C2", "RCIN.C3", "RCIN.C4"]),
        ("Motors (RC Out)", ["RCOU.C1", "RCOU.C2", "RCOU.C3", "RCOU.C4"]),
        ("Altitude", ["BARO.Alt", "CTUN.Alt", "CTUN.DAlt"]),
        ("Throttle", ["CTUN.ThO", "CTUN.ThI"]),
        ("GPS", ["GPS.NSats", "GPS.HDop"]),
        ("EKF innovations", ["XKF4.SV", "XKF4.SP", "XKF4.SH", "XKF4.SM"]),
    ]

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                TextField("Пошук повідомлення або поля", text: $search).textFieldStyle(.roundedBorder).padding([.horizontal, .top], 8)
                Picker("", selection: $filter) {
                    Text("Усі").tag(0); Text("Популярні").tag(1); Text("Найбільші").tag(2)
                }
                .pickerStyle(.segmented).labelsHidden().controlSize(.small).frame(maxWidth: .infinity)
                .padding(.horizontal, 8).padding(.vertical, 6)
                .help("Усі групи · типові для аналізу · групи з найбільшою кількістю записів у цьому логу")
                if filter == 1 {
                    HStack(spacing: 6) {
                        Text("Зірочка біля поля додає його до популярних.").font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        Button("Скинути") { pop.reset() }.controlSize(.mini).disabled(pop.isDefault)
                    }.padding(.horizontal, 8).padding(.bottom, 4)
                }
                List {
                    ForEach(visibleGroups, id: \.self) { n in
                        let open = expanded.contains(n) || (!search.isEmpty && log.fields(of: n).contains { $0.localizedCaseInsensitiveContains(search) })
                        let chosen = selected.filter { $0.hasPrefix(n + ".") }.count
                        let top = pop.fields[n] ?? []
                        DisclosureGroup(isExpanded: Binding(get: { open }, set: { on in if on { expanded.insert(n) } else { expanded.remove(n) } })) {
                            ForEach(orderedFields(n), id: \.self) { f in
                                HStack(spacing: 6) {
                                    Toggle(lk(f), isOn: Binding(get: { selected.contains("\(n).\(f)") }, set: { on in toggle("\(n).\(f)", on) }))
                                        .toggleStyle(.checkbox).font(.caption).help(lk(LogKnowledge.fieldHelp(n, f) ?? ""))
                                    Spacer(minLength: 0)
                                    Button { pop.toggle(n, f) } label: {
                                        Image(systemName: top.contains(f) ? "star.fill" : "star").font(.system(size: 9))
                                            .foregroundStyle(top.contains(f) ? Color.yellow.opacity(0.85) : Color.secondary.opacity(0.35))
                                    }.buttonStyle(.plain).help(top.contains(f) ? "Прибрати з популярних" : "Додати до популярних")
                                }
                            }
                        } label: {
                            // клік по назві групи розгортає/згортає список; у згорнутому стані мітка з числом вибраних полів
                            HStack(spacing: 6) {
                                let fields = plottable(n)
                                let on = fields.filter { selected.contains("\(n).\($0)") }.count
                                Button { toggleGroup(n) } label: {
                                    Image(systemName: on == 0 ? "square" : (on == fields.count ? "checkmark.square.fill" : "minus.square.fill"))
                                        .foregroundStyle(on == 0 ? Color.secondary : Color.accentColor)
                                }
                                .buttonStyle(.plain).help(lk(on == fields.count ? "Прибрати всі поля групи з графіка" : "Додати на графік усі поля групи"))
                                if filter == 0, pop.fields[n] != nil { Image(systemName: "star.fill").font(.system(size: 8)).foregroundStyle(.yellow.opacity(0.8)) }
                                // число біля назви = кількість полів у списку; кількість записів у логу праворуч сірим
                                Text("\(n)  ·  \(plottable(n).count)\(LogKnowledge.info(n).map { "  " + loc($0.title) } ?? "")").lineLimit(1)
                                Spacer(minLength: 4)
                                if filter == 2 {
                                    Capsule().fill(Color.accentColor.opacity(0.45))
                                        .frame(width: max(3, 44 * CGFloat(log.count(n)) / CGFloat(max(maxCount, 1))), height: 4).frame(width: 44, alignment: .trailing)
                                }
                                Text(lk(Self.compact(log.count(n)))).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                                    .help("Записів у логу: \(log.count(n))")
                                if chosen > 0 && !open {
                                    Text("\(chosen)").font(.caption2.weight(.bold)).foregroundStyle(.white)
                                        .padding(.horizontal, 6).padding(.vertical, 1).background(Color.accentColor, in: Capsule())
                                        .help("Вибрано полів: \(chosen)")
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { if open { expanded.remove(n) } else { expanded.insert(n) } }
                        }
                    }
                }
                .listStyle(.sidebar)
            }
            .frame(width: 250).frame(maxHeight: .infinity)
            Divider()
            ScrollView {
            VStack(spacing: 8) {
                HStack {
                    Menu("Пресети") {
                        ForEach(Self.presets, id: \.0) { p in
                            Button(lk(p.0)) { selected = p.1.filter { exists($0) }; refresh() }
                        }
                    }.fixedSize()
                    Toggle("Нормувати 0…1", isOn: $normalize).onChange(of: normalize) { _, _ in refresh() }
                    Spacer()
                    Button("Очистити") { selected = []; refresh() }.disabled(selected.isEmpty)
                }
                if cseries.isEmpty {
                    ContentUnavailableView("Оберіть поля ліворуч", systemImage: "chart.xyaxis.line", description: Text("Або скористайтеся пресетом, наприклад Attitude чи Vibration."))
                } else {
                    SeriesLegend(series: cseries)
                    InteractiveChart(series: cseries, x0: min(from, to - 0.5), x1: max(to, from + 0.5), height: 320, normalize: normalize, cur: cur,
                                     onRange: { a, b in from = max(0, a); to = min(log.duration, b); refresh() })
                    HStack(spacing: 12) {
                        TimeField(title: String(localized: "Початок"), value: from) { v in
                            from = min(max(0, v), max(0, log.duration - 0.5))
                            if to - from < 0.5 { to = min(log.duration, from + 1) }
                            refresh()
                        }
                        TimeField(title: String(localized: "Кінець"), value: to) { v in
                            to = max(min(log.duration, v), 0.5)
                            if to - from < 0.5 { from = max(0, to - 1) }
                            refresh()
                        }
                        Text(String(format: loc("%.0f с з %.0f с"), max(to - from, 0), log.duration)).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Весь час") { from = 0; to = log.duration; refresh() }.controlSize(.small).disabled(from <= 0.05 && to >= log.duration - 0.05)
                    }
                    Text("Потягніть дужки «[» і «]» на графіку, щоб звузити діапазон, або введіть час початку й кінця.").font(.caption2).foregroundStyle(.tertiary)
                    HStack {
                        Text("Від").font(.caption); Slider(value: $from, in: 0...max(0.001, log.duration)).onChange(of: from) { _, _ in if from >= to { to = min(log.duration, from + 1) }; refresh() }
                        Text("До").font(.caption); Slider(value: $to, in: 0...max(0.001, log.duration)).onChange(of: to) { _, _ in if to <= from { from = max(0, to - 1) }; refresh() }
                    }
                }
                if !cseries.isEmpty {
                    LogStatsPanel(log: log, keys: cseries.map { ($0.id, $0.color) }, from: min(from, to - 0.5), to: max(to, from + 0.5))
                }
            }
            }
            .padding(10)
        }
        .onAppear { if to == 1.0 { to = max(1, log.duration) }; applyRequest() }
        .onChange(of: request?.wrappedValue) { _, _ in applyRequest() }
    }

    func applyRequest() {
        guard let r = request?.wrappedValue else { return }
        selected = r.keys.filter { exists($0) }
        from = max(0, r.from); to = min(max(log.duration, 1), max(r.to, r.from + 1))
        refresh()
        request?.wrappedValue = nil
    }

    func plottable(_ n: String) -> [String] {
        guard let f = log.byName[n] else { return [] }
        return zip(f.labels, f.format).filter { !["N", "Z", "n", "a"].contains(String($0.1)) && $0.0 != "TimeUS" && $0.0 != "TimeMS" }.map(\.0)
    }
    func exists(_ key: String) -> Bool {
        let p = key.split(separator: ".").map(String.init)
        return p.count == 2 && plottable(p[0]).contains(p[1])
    }
    /// Усі поля групи: вмикає, якщо вибрано не всі, інакше вимикає.
    func toggleGroup(_ n: String) {
        let keys = plottable(n).map { "\(n).\($0)" }
        guard !keys.isEmpty else { return }
        if keys.allSatisfy({ selected.contains($0) }) { selected.removeAll { keys.contains($0) } }
        else { for k in keys where !selected.contains(k) { selected.append(k) } }
        refresh()
    }
    func toggle(_ key: String, _ on: Bool) {
        if on { if !selected.contains(key) { selected.append(key) } } else { selected.removeAll { $0 == key } }
        refresh()
    }

    func refresh() {
        let t0 = from, t1 = to > from ? to : log.duration
        series = selected.compactMap { key in
            let p = key.split(separator: ".").map(String.init)
            guard p.count == 2 else { return nil }
            var s = log.series(p[0], p[1]).filter { $0.t >= t0 && $0.t <= t1 && $0.v.isFinite }
            guard !s.isEmpty else { return nil }
            if normalize, let mn = s.map(\.v).min(), let mx = s.map(\.v).max(), mx > mn { s = s.map { ($0.t, ($0.v - mn) / (mx - mn)) } }
            return PlotSeries(id: key, points: Self.decimate(s))
        }
        cseries = series.enumerated().map { i, s in CSeries(id: s.id, name: s.id, color: ChartPalette.color(i), t: s.points.map(\.t), v: s.points.map(\.v)) }
    }

    /// Проріджування для графіка: до ~2000 точок із збереженням мінімумів і максимумів.
    static func decimate(_ s: [(t: Double, v: Double)]) -> [PlotPoint] {
        let maxPts = 2000
        if s.count <= maxPts { return s.enumerated().map { PlotPoint(id: $0.offset, t: $0.element.t, v: $0.element.v) } }
        let buckets = maxPts / 2, size = Double(s.count) / Double(buckets)
        var out: [PlotPoint] = []; var id = 0
        for b in 0..<buckets {
            let lo = Int(Double(b) * size), hi = min(s.count, Int(Double(b + 1) * size))
            guard lo < hi else { continue }
            let seg = s[lo..<hi]
            guard let mn = seg.min(by: { $0.v < $1.v }), let mx = seg.max(by: { $0.v < $1.v }) else { continue }
            for p in (mn.t <= mx.t ? [mn, mx] : [mx, mn]) { out.append(PlotPoint(id: id, t: p.t, v: p.v)); id += 1 }
        }
        return out
    }

}

// MARK: - Карта

struct LogMapView: View {
    let log: DFLog
    @State private var track: [(t: Double, lat: Double, lon: Double, alt: Double)] = []
    @State private var pos = 0.0
    @State private var camera = MapCameraPosition.automatic

    var body: some View {
        VStack(spacing: 0) {
            if track.count < 2 {
                ContentUnavailableView("Немає GPS-траєкторії", systemImage: "map", description: Text("У лозі немає повідомлень GPS із 3D-фіксацією."))
            } else {
                let coords = track.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
                let i = min(track.count - 1, Int(pos * Double(track.count - 1)))
                Map(position: $camera) {
                    MapPolyline(coordinates: coords).stroke(.purple, lineWidth: 3)
                    Annotation("Старт", coordinate: coords[0]) { Image(systemName: "flag.fill").foregroundStyle(.white).padding(5).background(.green, in: Circle()) }
                    Annotation("Кінець", coordinate: coords[coords.count - 1]) { Image(systemName: "flag.checkered").foregroundStyle(.white).padding(5).background(.red, in: Circle()) }
                    Annotation("", coordinate: coords[i]) { Image(systemName: "location.north.circle.fill").font(.title).foregroundStyle(.orange) }
                }
                .mapStyle(.hybrid)
                Divider()
                HStack {
                    Image(systemName: "timeline.selection")
                    Slider(value: $pos)
                    Text(String(format: loc("t %.1f с · висота %.1f м"), track[i].t, track[i].alt)).font(.caption.monospacedDigit()).frame(width: 190, alignment: .trailing)
                }.padding(10)
            }
        }
        .onAppear { track = log.track() }
    }
}

// MARK: - Повідомлення

struct LogMessagesView: View {
    let log: DFLog
    @State private var kind = "Усі"
    @State private var search = ""
    var shown: [DFLog.Msg] { log.messages.filter { (kind == "Усі" || $0.name == kind) && (search.isEmpty || $0.text.localizedCaseInsensitiveContains(search)) } }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $kind) { ForEach(["Усі", "MSG", "MODE", "ERR", "EV"], id: \.self) { Text(lk($0)).tag($0) } }.pickerStyle(.segmented).labelsHidden().frame(width: 300)
                TextField("Пошук", text: $search).textFieldStyle(.roundedBorder).frame(width: 220)
                Spacer()
                Text("\(shown.count) повідомлень").font(.caption).foregroundStyle(.secondary)
            }.padding(10)
            Divider()
            List(Array(shown.enumerated()), id: \.offset) { _, m in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(String(format: "%d:%04.1f", Int(m.time) / 60, m.time.truncatingRemainder(dividingBy: 60))).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
                    Text(LocalizedStringKey(m.name)).font(.system(.caption2, design: .monospaced).weight(.bold)).padding(.horizontal, 5).padding(.vertical, 1)
                        .background(color(m.name).opacity(0.2), in: RoundedRectangle(cornerRadius: 4)).foregroundStyle(color(m.name)).frame(width: 52)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(LocalizedStringKey(m.text)).font(.callout).foregroundStyle(m.name == "ERR" ? .red : .primary)
                        if !m.hint.isEmpty { Text(LocalizedStringKey(m.hint)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                    }
                }
            }
        }
    }
    func color(_ n: String) -> Color { switch n { case "ERR": .red; case "MODE": .blue; case "EV": .orange; default: .secondary } }
}

// MARK: - Параметри з логу

struct LogParamsView: View {
    let log: DFLog
    @State private var search = ""
    var shown: [(name: String, value: Double)] { log.parameters.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) } }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Пошук параметра", text: $search).textFieldStyle(.roundedBorder).frame(width: 260)
                Spacer()
                Text("\(shown.count) з \(log.parameters.count)").font(.caption).foregroundStyle(.secondary)
                Button("Зберегти .param") { save() }.disabled(log.parameters.isEmpty)
            }.padding(10)
            Divider()
            if log.parameters.isEmpty { ContentUnavailableView("У лозі немає параметрів", systemImage: "slider.horizontal.3") }
            else {
                List(shown, id: \.name) { p in
                    HStack { Text(LocalizedStringKey(p.name)).font(.system(.body, design: .monospaced)); Spacer(); Text(lk(format(p.value))).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary) }
                }
            }
        }
    }
    func format(_ v: Double) -> String { v == v.rounded() && abs(v) < 1e9 ? String(Int(v)) : String(format: "%.6g", v) }
    func save() {
        let p = NSSavePanel(); p.nameFieldStringValue = "log.param"
        guard p.runModal() == .OK, let u = p.url else { return }
        try? log.parameters.map { "\(loc($0.name)),\(format($0.value))" }.joined(separator: "\n").appending("\n").write(to: u, atomically: true, encoding: .utf8)
    }
}

// MARK: - Експорт у текстовий .log (як у Mission Planner)

extension DFLog {
    func exportText(to url: URL) -> Bool {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let fh = try? FileHandle(forWritingTo: url) else { return false }
        defer { try? fh.close() }
        var buf = String(); buf.reserveCapacity(1 << 20)
        func flush() { if !buf.isEmpty { fh.write(Data(buf.utf8)); buf.removeAll(keepingCapacity: true) } }
        let n = data.count
        var i = 0
        func num(_ f: Fmt, _ k: Int, _ body: Int) -> String {
            let v = value(f, k, at: body)
            switch f.format[k] {
            case "f", "d": return String(format: "%.9g", v)
            case "c", "C", "e", "E": return String(format: "%.2f", v)
            case "L": return String(format: "%.7f", v)
            default: return String(Int64(v))
            }
        }
        while i + 3 <= n {
            if data[i] != 0xA3 || data[i + 1] != 0x95 { i += 1; continue }
            let type = data[i + 2]
            guard let f = fmts[type] else { i += 1; continue }
            if i + f.length > n { break }
            let body = i + 3
            var cols: [String] = []
            if type == 128 {
                cols = ["FMT", String(data[body]), String(data[body + 1]), string(f, 2, at: body), string(f, 3, at: body), string(f, 4, at: body)]
            } else {
                cols = [f.name]
                for k in 0..<f.format.count {
                    switch f.format[k] {
                    case "N", "Z", "n": cols.append(string(f, k, at: body))
                    case "a": cols.append("0")
                    default: cols.append(num(f, k, body))
                    }
                }
            }
            buf += cols.joined(separator: ", ") + "\n"
            if buf.utf8.count > (1 << 20) { flush() }
            i += f.length
        }
        flush()
        return true
    }
}


/// Набір «популярних» полів логів: типовий або змінений користувачем (зберігається в UserDefaults).
@Observable
final class LogPopular {
    static let shared = LogPopular()
    private static let key = "log.popular.v1"
    var fields: [String: [String]]
    var order: [String]

    init() {
        if let d = UserDefaults.standard.data(forKey: Self.key),
           let o = try? JSONDecoder().decode(Saved.self, from: d) { fields = o.fields; order = o.order }
        else { fields = LogGraphView.defaultPopular; order = LogGraphView.defaultOrder }
    }
    private struct Saved: Codable { var fields: [String: [String]]; var order: [String] }

    var isDefault: Bool { fields == LogGraphView.defaultPopular && order == LogGraphView.defaultOrder }

    func toggle(_ group: String, _ field: String) {
        var list = fields[group] ?? []
        if let i = list.firstIndex(of: field) { list.remove(at: i) } else { list.append(field) }
        if list.isEmpty { fields[group] = nil; order.removeAll { $0 == group } }
        else { fields[group] = list; if !order.contains(group) { order.append(group) } }
        save()
    }
    func reset() { fields = LogGraphView.defaultPopular; order = LogGraphView.defaultOrder; UserDefaults.standard.removeObject(forKey: Self.key) }
    private func save() {
        if let d = try? JSONEncoder().encode(Saved(fields: fields, order: order)) { UserDefaults.standard.set(d, forKey: Self.key) }
    }
}
