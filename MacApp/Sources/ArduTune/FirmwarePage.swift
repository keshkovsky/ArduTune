import SwiftUI
import AppKit

struct FwEntry: Decodable, Identifiable, Hashable {
    let format: String?; let vehicle: String; let platform: String; let boardId: Int; let version: String; let type: String; let frame: String; let url: String; let git: String; let mav: String
    var id: String { url }
    var fmt: String { format ?? "apj" }
    /// Назва збірки з теки на сервері (відрізняє, наприклад, «speedybeef4v3» і «speedybeef4v3-heli»).
    var folder: String { url.split(separator: "/").dropLast().last.map(String.init) ?? platform }
    var semver: [Int] { version.split(separator: ".").map { Int($0.filter(\.isNumber)) ?? 0 } }
    var channelLabel: String {
        switch type { case "DEV": return loc("latest (розробка) · ") + version; case "BETA": return loc("бета · ") + version; case "OFFICIAL": return loc("стабільна · ") + version; default: return version }
    }
}
struct FwFile: Decodable { let path: String; let boardId: Int; let size: Int; let summary: String; let version: String }
struct FwStatusDTO: Decodable { let state: String; let stage: String; let progress: Double; let error: String?; let boardId: Int; let port: String?; let log: [String] }

@Observable
final class FirmwareModel {
    var entries: [FwEntry] = []
    var loading = false
    var error: String?
    var vehicle = "Copter"
    var kind = "OFFICIAL"
    var format = "apj"                // apj: через завантажувач, hex: через DFU
    var search = ""
    var selected: FwEntry?
    var versions: [FwEntry] = []
    var versionsLoading = false
    var file: FwFile?
    var fileName = ""
    var downloading = false
    var status: FwStatusDTO?
    var ports: [String] = []
    var port = ""
    var allowMismatch = false
    var flashing: Bool { status?.state == "running" }
    @ObservationIgnored private var polling = false

    static let vehicles: [(String, String)] = [("Copter", "Мультикоптер"), ("Plane", "Літак"), ("Rover", "Ровер"), ("Sub", "Підводний"), ("Blimp", "Дирижабль"), ("AntennaTracker", "Трекер антени"), ("AP_Periph", "Периферія CAN")]
    static let kinds: [(String, String)] = [("OFFICIAL", "Стабільна"), ("BETA", "Бета"), ("DEV", "Розробка")]

    var filtered: [FwEntry] {
        entries.filter { $0.vehicle == vehicle && $0.type == kind && $0.fmt == format && (search.isEmpty || $0.platform.localizedCaseInsensitiveContains(search)) }
            .sorted { $0.platform.localizedCaseInsensitiveCompare($1.platform) == .orderedAscending }
    }

    @MainActor func loadManifest(force: Bool = false) async {
        loading = true; error = nil
        defer { loading = false }
        do {
            let d = try await EngineAPI.data("/fw/manifest" + (force ? "?force=true" : ""))
            entries = try JSONDecoder().decode([FwEntry].self, from: d)
        } catch let e as EngineAPI.APIError { error = e.message } catch let e { error = e.localizedDescription }
    }

    /// Усі доступні версії для вибраної збірки: latest, бета й усі випуски (найновіші зверху).
    @MainActor func loadVersions(for e: FwEntry) async {
        versionsLoading = true; defer { versionsLoading = false }
        guard let d = try? await EngineAPI.data("/fw/versions?vehicle=\(EngineAPI.q(e.vehicle))&platform=\(EngineAPI.q(e.platform))"),
              let all = try? JSONDecoder().decode([FwEntry].self, from: d) else { versions = []; return }
        let same = all.filter { $0.folder == e.folder && $0.fmt == e.fmt }
        func rank(_ x: FwEntry) -> Int { x.type == "DEV" ? 0 : (x.type == "BETA" ? 1 : 2) }
        versions = same.sorted { a, b in
            if rank(a) != rank(b) { return rank(a) < rank(b) }
            return a.semver.lexicographicallyPrecedes(b.semver) == false && a.semver != b.semver
        }
    }

    /// Вибір збірки зі списку: завантажує версію вибраного каналу й готує список усіх версій.
    @MainActor func pick(_ e: FwEntry) async {
        versions = []
        async let v: () = loadVersions(for: e)
        await choose(e)
        await v
    }

    @MainActor func choose(_ e: FwEntry) async {
        selected = e; file = nil; fileName = e.platform + " " + e.version; downloading = true; error = nil
        defer { downloading = false }
        do {
            let d = try await EngineAPI.send("/fw/download?url=" + EngineAPI.q(e.url))
            file = try JSONDecoder().decode(FwFile.self, from: d)
        } catch let e as EngineAPI.APIError { error = e.message } catch let e { error = e.localizedDescription }
    }

    @MainActor func chooseFile(_ url: URL) async {
        selected = nil; file = nil; fileName = url.lastPathComponent; error = nil
        format = url.pathExtension.lowercased() == "hex" ? "hex" : "apj"
        do {
            let d = try await EngineAPI.data("/fw/inspect?path=" + EngineAPI.q(url.path))
            file = try JSONDecoder().decode(FwFile.self, from: d)
        } catch let e as EngineAPI.APIError { error = e.message } catch let e { error = e.localizedDescription }
    }

    @MainActor func refreshPorts() async { if let p = await EngineAPI.get("/fw/ports", as: [String].self) { ports = p } }

    @MainActor func flash() async {
        guard let f = file else { return }
        error = nil
        var path = "/fw/flash?path=" + EngineAPI.q(f.path) + "&force=\(allowMismatch)"
        if !port.isEmpty { path += "&port=" + EngineAPI.q(port) }
        do { try await EngineAPI.send(path) } catch let e as EngineAPI.APIError { error = e.message; return } catch let e { error = e.localizedDescription; return }
        polling = true
        while polling {
            if let st = await EngineAPI.get("/fw/status", as: FwStatusDTO.self) { status = st; if st.state != "running" { polling = false } }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }
    func cancel() { EngineAPI.post("/fw/cancel") }
    var backupNote = ""
}

/// Автоматична резервна копія параметрів перед прошиванням: ~/Library/Application Support/ArduTune/Backups.
enum FirmwareBackup {
    static func save(params: [Param], vehicle: String?) async -> URL? {
        let info = await ParamSaveInfo.current(vehicle: vehicle)
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/ArduTune/Backups", isDirectory: true)
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) } catch { return nil }
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        let tag = (info.board.isEmpty ? "board" : info.board) + (info.uid.isEmpty ? "" : "_" + String(info.uid.prefix(8)))
        let url = dir.appendingPathComponent("\(tag)_\(f.string(from: Date())).param")
        let text = info.header + params.sorted { $0.name < $1.name }.map { "\(loc($0.name)),\(fmt($0.value, isInt: $0.isInt))" }.joined(separator: "\n") + "\n"
        do { try text.write(to: url, atomically: true, encoding: .utf8); return url } catch { return nil }
    }
}

struct FirmwareView: View {
    @Environment(Store.self) var s
    @State private var guess = BoardGuess()
    var m: FirmwareModel { s.firmware }

    var vehicleFromBoard: String? {
        switch s.ps.metaVehicle ?? "" {
        case "FIXED_WING", "FLAPPING_WING": return "Plane"
        case "GROUND_ROVER", "SURFACE_BOAT": return "Rover"
        case "SUBMARINE": return "Sub"
        case "ANTENNA_TRACKER": return "AntennaTracker"
        case "": return nil
        default: return "Copter"
        }
    }

    var body: some View {
        @Bindable var m = s.firmware
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                PageTitle(title: String(localized: "Встановлення прошивки"), subtitle: String(localized: "Завантаження ArduPilot з офіційного сервера й прошивання плати через завантажувач (USB)."))
                warning
                Card(title: String(localized: "1. Яку прошивку встановити"), icon: "shippingbox", text: nil) {
                    Picker("", selection: $m.vehicle) { ForEach(FirmwareModel.vehicles, id: \.0) { Text(lk($0.1)).tag($0.0) } }.labelsHidden().pickerStyle(.menu).frame(width: 220)
                    Picker("", selection: $m.kind) { ForEach(FirmwareModel.kinds, id: \.0) { Text(lk($0.1)).tag($0.0) } }.pickerStyle(.segmented).labelsHidden()
                    Text(LocalizedStringKey(kindHint)).font(.caption).foregroundStyle(.secondary)
                    Picker("", selection: $m.format) { Text("APJ: через завантажувач (рекомендовано)").tag("apj"); Text("HEX: через DFU (для плат без завантажувача ArduPilot)").tag("hex") }
                        .pickerStyle(.segmented).labelsHidden()
                        .onChange(of: m.format) { _, _ in m.selected = nil; m.file = nil; m.versions = [] }
                    HStack {
                        TextField("Пошук плати (наприклад, Matek, Pixhawk, CubeOrange)", text: $m.search).textFieldStyle(.roundedBorder)
                        Button { Task { await m.loadManifest(force: true) } } label: { Image(systemName: "arrow.clockwise") }.tip("Оновити каталог").disabled(m.loading)
                    }
                    if !guess.board.isEmpty {
                        let match = m.entries.first { $0.vehicle == m.vehicle && $0.type == m.kind && BoardGuess.norm($0.folder) == guess.key } ?? m.entries.first { $0.vehicle == m.vehicle && $0.type == m.kind && BoardGuess.norm($0.platform) == guess.key && !$0.url.contains("-heli") }
                        HStack(spacing: 8) {
                            Image(systemName: "cpu")
                            Text("Підключена плата: \(guess.board)").font(.callout)
                            if let match { Button("Вибрати цю плату") { Task { await m.pick(match) } }.controlSize(.small) }
                            else { Text("для цього типу прошивки в каталозі немає").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    if m.loading { HStack { ProgressView().controlSize(.small); Text("Завантаження каталогу…").font(.caption) } }
                    let list = m.filtered
                    if list.isEmpty && !m.loading { Text(lk(m.entries.isEmpty ? "Каталог порожній. Перевірте інтернет і натисніть оновлення." : "Нічого не знайдено.")).font(.callout).foregroundStyle(.secondary) }
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(list) { e in
                                HStack {
                                    Text(LocalizedStringKey(e.folder)).font(.callout)
                                    if e.url.contains("-heli") { Text("вертоліт").font(.caption2).padding(.horizontal, 5).padding(.vertical, 1).background(Color.orange.opacity(0.2), in: Capsule()) }
                                    if !e.frame.isEmpty { Text(LocalizedStringKey(e.frame)).font(.caption).foregroundStyle(.secondary) }
                                    Spacer()
                                    Text(LocalizedStringKey(e.version)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 8).padding(.vertical, 5)
                                .background(m.selected?.folder == e.folder && m.selected?.vehicle == e.vehicle ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 6))
                                .contentShape(Rectangle())
                                .onTapGesture { Task { await m.pick(e) } }
                            }
                        }
                    }
                    .frame(height: 210).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                    if let sel = m.selected {
                        HStack(spacing: 8) {
                            Text("Версія").font(.callout)
                            Picker("", selection: Binding(get: { sel.url }, set: { url in if let e = m.versions.first(where: { $0.url == url }) { Task { await m.choose(e) } } })) {
                                if !m.versions.contains(where: { $0.url == sel.url }) { Text(LocalizedStringKey(sel.channelLabel)).tag(sel.url) }
                                ForEach(Array(m.versions.enumerated()), id: \.element.id) { i, v in
                                    Text(lk(v.channelLabel + (v.type.hasPrefix("STABLE") && i == m.versions.firstIndex(where: { $0.type.hasPrefix("STABLE") }) ? " (остання стабільна)" : ""))).tag(v.url)
                                }
                            }.labelsHidden().frame(width: 300)
                            if m.versionsLoading { ProgressView().controlSize(.small) }
                            Text("\(m.versions.count) версій у каталозі").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        Text("або").font(.caption).foregroundStyle(.secondary)
                        Button { pickFile() } label: { Label("Свій файл (.apj, .bin, .hex)…", systemImage: "doc") }.controlSize(.small)
                    }
                }
                if s.firmware.format == "hex" {
                    Card(title: String(localized: "2. Перехід у режим DFU"), icon: "checklist", text: nil) { dfuPrepare }
                    Card(title: String(localized: "3. Прошивання через DFU"), icon: "bolt.fill", text: nil) { dfuFlash }
                } else {
                    Card(title: String(localized: "2. Підготовка"), icon: "checklist", text: nil) { prepare }
                    Card(title: String(localized: "3. Прошивання"), icon: "bolt.fill", text: nil) { flashCard }
                }
            }
            .padding()
        }
        .task { await s.dfu.watch() }
        .task(id: "\(s.connected)|\(s.t.port ?? "")|\(s.t.vehicle ?? "")|\(s.t.metaSource ?? "")") {
            if let v = vehicleFromBoard { m.vehicle = v }
            if m.entries.isEmpty { await m.loadManifest() }
            await m.refreshPorts()
            guess = BoardGuess()
            guess = await guessBoard()
        }
    }

    var kindHint: String {
        switch s.firmware.kind {
        case "OFFICIAL": return "Стабільна: рекомендована для польотів."
        case "BETA": return "Бета: нові можливості, перевірені спільнотою; можливі помилки."
        default: return "Розробка (latest): найновіша збірка з гілки master; лише для експериментів і тестів."
        }
    }

    var warning: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.title3)
            VStack(alignment: .leading, spacing: 3) {
                Text("Прошивання замінює програму польотника").font(.callout.weight(.semibold))
                Text("Зніміть пропелери. Не відключайте USB і живлення під час запису. Параметри зазвичай зберігаються, але перед прошиванням збережіть їх у файл (розділ Parameters). Прошивання працює лише для плат із завантажувачем ArduPilot/PX4; плати, що вмикаються в режимі DFU, потрібно прошивати окремо.").font(.caption).foregroundStyle(.secondary)
                Button { s.navigate = "Params" } label: { Label("Відкрити Parameters", systemImage: "slider.horizontal.3") }.controlSize(.small)
            }
        }
        .padding(12).background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder var prepare: some View {
        @Bindable var m = s.firmware
        if m.downloading { HStack { ProgressView().controlSize(.small); Text("Завантаження \(m.fileName)…").font(.callout) } }
        else if let f = m.file {
            VStack(alignment: .leading, spacing: 3) {
                Label("\(m.fileName)", systemImage: "checkmark.circle.fill").font(.callout.weight(.medium)).foregroundStyle(.green)
                Text("Образ \(f.size / 1024) КБ · board_id \(f.boardId)\(f.summary.isEmpty ? "" : " · \(f.summary)")").font(.caption).foregroundStyle(.secondary)
            }
        } else { Text("Оберіть прошивку вище.").font(.callout).foregroundStyle(.secondary) }
        HStack {
            Picker("Порт", selection: $m.port) {
                Text("Автоматично (знайти завантажувач)").tag("")
                ForEach(m.ports, id: \.self) { Text(lk($0.replacingOccurrences(of: "/dev/", with: ""))).tag($0) }
            }.frame(width: 360)
            Button { Task { await m.refreshPorts() } } label: { Image(systemName: "arrow.clockwise") }.tip("Оновити список портів")
        }
        if s.connected { Label("Польотник підключений: застосунок сам перезавантажить його в режим завантажувача й відключить від нього зв'язок.", systemImage: "info.circle").font(.caption).foregroundStyle(.secondary) }
        else { Label("Польотник не підключений: підключіть плату по USB (бажано в режимі завантажувача) і натисніть «Прошити».", systemImage: "info.circle").font(.caption).foregroundStyle(.secondary) }
    }

    @ViewBuilder var flashCard: some View {
        @Bindable var m = s.firmware
        HStack(spacing: 12) {
            Button { confirmAndFlash() } label: { Label("Прошити", systemImage: "bolt.fill").frame(minWidth: 110) }
                .buttonStyle(.borderedProminent).controlSize(.large).disabled(m.file == nil || m.flashing || m.downloading || s.armed)
            if m.flashing { Button("Скасувати") { m.cancel() } }
            Toggle("Дозволити невідповідність board_id (небезпечно)", isOn: $m.allowMismatch).toggleStyle(.checkbox).font(.caption).foregroundStyle(.red)
        }
        if s.armedLive { Label("Апарат ARMED: прошивання заблоковано.", systemImage: "lock.fill").font(.caption).foregroundStyle(.red) }
        if !m.backupNote.isEmpty { Label(LocalizedStringKey(m.backupNote), systemImage: "externaldrive.badge.checkmark").font(.caption).foregroundStyle(.secondary) }
        if let e = m.error { Label(LocalizedStringKey(e), systemImage: "exclamationmark.octagon.fill").font(.callout).foregroundStyle(.red) }
        if let st = m.status {
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: st.progress).tint(st.state == "error" ? .red : (st.state == "done" ? .green : .accentColor))
                HStack {
                    Text(lk(st.state == "error" ? String(localized: "Помилка: \(st.error ?? "")") : st.stage)).font(.callout).foregroundStyle(st.state == "error" ? Color.red : Color.primary)
                    Spacer()
                    Text(String(format: "%.0f %%", st.progress * 100)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                if st.state == "done" {
                    HStack {
                        Label("Плата перезавантажується з новою прошивкою.", systemImage: "checkmark.seal.fill").foregroundStyle(.green).font(.callout)
                        Button { EngineAPI.post("/connect?type=auto") } label: { Label("Підключитися", systemImage: "cable.connector") }.controlSize(.small)
                    }
                }
                if st.state == "error" || st.state == "cancelled" {
                    Label("Плата лишилась у режимі завантажувача: її можна прошити знову (повторіть кроки 2 і 3).", systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                }
                DisclosureGroup("Журнал") {
                    Text(lk(st.log.joined(separator: "\n"))).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }.font(.caption)
            }
        }
    }

    // MARK: DFU

    @ViewBuilder var dfuPrepare: some View {
        let m = s.firmware
        if m.downloading { HStack { ProgressView().controlSize(.small); Text("Завантаження \(m.fileName)…").font(.callout) } }
        else if let f = m.file {
            VStack(alignment: .leading, spacing: 3) {
                Label("\(m.fileName)", systemImage: "checkmark.circle.fill").font(.callout.weight(.medium)).foregroundStyle(.green)
                Text("Файл \(f.size / 1024) КБ · \(loc(f.summary))").font(.caption).foregroundStyle(.secondary)
            }
        } else { Text("Оберіть HEX-прошивку вище (це файли «…_with_bl.hex», вони містять і завантажувач).").font(.callout).foregroundStyle(.secondary) }
        VStack(alignment: .leading, spacing: 5) {
            step("1", "Відключіть польотник від застосунку", s.connected ? "Він зараз підключений: натисніть кнопку нижче, щоб звільнити USB." : "Готово: зв'язку з польотником немає.")
            if s.connected {
                Button { EngineAPI.post("/disconnect") } label: { Label("Відключити польотник", systemImage: "cable.connector.slash") }.controlSize(.small)
            }
            step("2", "Увімкніть режим DFU на платі", "Відключіть USB, затисніть кнопку BOOT (або замкніть контакти BOOT), підключіть USB і відпустіть кнопку. Плата з'явиться як «STM32 BOOTLOADER» (VID 0483, PID DF11).")
        }
        HStack(spacing: 8) {
            Image(systemName: s.dfu.present ? "checkmark.circle.fill" : "circle.dotted").foregroundStyle(s.dfu.present ? Color.green : Color.secondary)
            Text(lk(s.dfu.present ? "DFU-пристрій знайдено" : "DFU-пристрій не знайдено: чекаю…")).font(.callout)
        }
        Label("Прошивання стирає всю флеш-пам'ять плати, разом із завантажувачем, і записує образ із завантажувачем з файлу.", systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
    }

    func step(_ n: String, _ t: String, _ d: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(LocalizedStringKey(n)).font(.caption.weight(.bold)).frame(width: 20, height: 20).background(Color.accentColor.opacity(0.2), in: Circle())
            VStack(alignment: .leading, spacing: 1) { Text(LocalizedStringKey(t)).font(.callout.weight(.semibold)); Text(LocalizedStringKey(d)).font(.caption).foregroundStyle(.secondary) }
        }
    }

    @ViewBuilder var dfuFlash: some View {
        let m = s.firmware, d = s.dfu
        HStack(spacing: 12) {
            Button { confirmDFU() } label: { Label("Прошити через DFU", systemImage: "bolt.fill").frame(minWidth: 150) }
                .buttonStyle(.borderedProminent).controlSize(.large).disabled(m.file == nil || !d.present || d.running || m.downloading || s.connected)
            if m.file != nil && !d.present { Text("Спершу переведіть плату в режим DFU.").font(.caption).foregroundStyle(.secondary) }
            if s.connected { Text("Спершу відключіть польотник від застосунку.").font(.caption).foregroundStyle(.orange) }
        }
        if let e = d.error { Label(LocalizedStringKey(e), systemImage: "exclamationmark.octagon.fill").font(.callout).foregroundStyle(.red) }
        if d.state != "idle" {
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: d.progress).tint(d.state == "error" ? .red : (d.state == "done" ? .green : .accentColor))
                HStack { Text(LocalizedStringKey(d.stage)).font(.callout); Spacer(); Text(String(format: "%.0f %%", d.progress * 100)).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                if d.state == "done" {
                    HStack {
                        Label("Плата перезавантажується. За кілька секунд вона з'явиться як USB-пристрій ArduPilot.", systemImage: "checkmark.seal.fill").foregroundStyle(.green).font(.callout)
                        Button { EngineAPI.post("/connect?type=auto") } label: { Label("Підключитися", systemImage: "cable.connector") }.controlSize(.small)
                    }
                }
                if d.state == "error" { Label("Плата лишилась у режимі DFU: прошивання можна повторити.", systemImage: "info.circle").font(.caption).foregroundStyle(.secondary) }
                DisclosureGroup("Журнал") { Text(lk(d.log.joined(separator: "\n"))).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }.font(.caption)
            }
        }
    }

    func confirmDFU() {
        guard let f = s.firmware.file else { return }
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = String(localized: "Прошити плату через DFU?")
        a.informativeText = String(localized: "\(s.firmware.fileName)\nФайл \(f.size / 1024) КБ.\n\nУся флеш-пам'ять плати буде стерта (разом із завантажувачем) і перезаписана образом із файлу. Не відключайте USB, поки триває прошивання. Переконайтесь, що файл призначений саме для цієї плати.")
        a.addButton(withTitle: String(localized: "Прошити")); a.addButton(withTitle: String(localized: "Скасувати"))
        guard a.runModal() == .alertFirstButtonReturn else { return }
        Task { await s.dfu.flash(hexPath: f.path) }
    }

    func pickFile() {
        let p = NSOpenPanel(); p.message = String(localized: "Оберіть файл прошивки (.apj, .bin або .hex)"); p.allowsOtherFileTypes = true
        guard p.runModal() == .OK, let u = p.url else { return }
        Task { await s.firmware.chooseFile(u) }
    }

    func confirmAndFlash() {
        guard let f = s.firmware.file else { return }
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = String(localized: "Прошити польотник?")
        a.informativeText = String(localized: "\(s.firmware.fileName)\nОбраз \(f.size / 1024) КБ, board_id \(f.boardId).\n\nПлату буде перезавантажено в завантажувач, а програму польотника замінено. Не відключайте USB і живлення, поки триває прошивання.")
        // додаткові попередження: зміна типу апарата скидає параметри; старіша версія може бути несумісна з параметрами
        var extra: [String] = []
        let curVeh = vehicleFromBoard
        if s.connected, let c = curVeh, c != s.firmware.vehicle { extra.append(String(localized: "• Змінюється тип апарата (\(c) → \(s.firmware.vehicle)): ArduPilot скине параметри. Резервну копію параметрів буде збережено автоматично.")) }
        if s.firmware.kind != "OFFICIAL" { extra.append(String(localized: "• Це \(s.firmware.kind == "BETA" ? "бета" : "розробницька (latest)") збірка: можливі помилки, не для польотів без перевірки.")) }
        if f.boardId == 0 { extra.append("• У файлі немає board_id: відповідність платі не перевіряється.") }
        a.informativeText += extra.isEmpty ? "" : "\n\n" + extra.joined(separator: "\n")
        a.addButton(withTitle: String(localized: "Прошити")); a.addButton(withTitle: String(localized: "Скасувати"))
        guard a.runModal() == .alertFirstButtonReturn else { return }
        Task {
            // автоматична резервна копія параметрів перед прошиванням (лише коли плата підключена й параметри завантажено)
            if s.connected, !s.ps.params.isEmpty {
                if let url = await FirmwareBackup.save(params: s.ps.params, vehicle: s.t.vehicle) { s.firmware.backupNote = loc("Резервну копію параметрів збережено: ") + url.lastPathComponent }
                else {
                    let e = NSAlert(); e.alertStyle = .critical; e.messageText = String(localized: "Не вдалося зберегти резервну копію параметрів")
                    e.informativeText = String(localized: "Прошивання не розпочато. Збережіть параметри вручну (Parameters → Файл) і повторіть."); e.runModal(); return
                }
            }
            await s.firmware.flash()
        }
    }
}
