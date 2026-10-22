import SwiftUI
import AppKit

struct FtpItem: Decodable, Identifiable { let name: String; let dir: Bool; let size: Int; var id: String { name } }

/// Менеджер Lua-скриптів ArduPilot: файли в папці скриптів на SD-картці польотника (MAVFTP).
@Observable @MainActor
final class ScriptsModel {
    var items: [FtpItem] = []
    var busy = false
    var error: String?
    var note: String?
    var dirMissing = false
    var analysis: [String: [Int]] = [:]       // ім'я скрипта -> коди Scripting-опцій (300–307), які він використовує
    @ObservationIgnored var dir: String = "/APM/scripts"

    func path(_ name: String) -> String { dir.hasSuffix("/") ? dir + name : dir + "/" + name }

    func refresh() async {
        busy = true; error = nil; dirMissing = false
        defer { busy = false }
        do {
            let d = try await EngineAPI.data("/ftp/list?path=\(EngineAPI.q(dir))")
            items = (try JSONDecoder().decode([FtpItem].self, from: d)).sorted { $0.name.lowercased() < $1.name.lowercased() }
        } catch let e as EngineAPI.APIError {
            items = []
            if e.message.contains("не знайдено") { dirMissing = true } else { error = e.message }
        } catch let e { self.error = e.localizedDescription }
    }

    func run(_ ok: String?, _ f: () async throws -> Void) async {
        busy = true; error = nil
        do { try await f(); if let ok { note = ok } }
        catch let e as EngineAPI.APIError { error = e.message }
        catch { self.error = error.localizedDescription }
        busy = false
    }

    func makeDir() async { await run("Папку створено") { try await EngineAPI.send("/ftp/mkdir?path=\(EngineAPI.q(dir))") }; await refresh() }

    func upload(_ urls: [URL]) async {
        await run(nil) {
            for u in urls {
                let data = try Data(contentsOf: u)
                try await EngineAPI.send("/ftp/write?path=\(EngineAPI.q(path(u.lastPathComponent)))", body: data)
                analysis[u.lastPathComponent] = Self.scriptingOptions(in: String(decoding: data, as: UTF8.self))
            }
            note = String(localized: "Завантажено на польотник: \(urls.map(\.lastPathComponent).joined(separator: ", ")). Перезапустіть скрипти.")
        }
        await refresh()
    }

    func write(_ name: String, text: String) async {
        await run(String(localized: "Збережено на польотник: \(loc(name))")) { try await EngineAPI.send("/ftp/write?path=\(EngineAPI.q(path(name)))", body: Data(text.utf8)) }
        analysis[name] = Self.scriptingOptions(in: text)
        await refresh()
    }

    func delete(_ name: String) async {
        await run(String(localized: "Видалено: \(loc(name))")) { try await EngineAPI.send("/ftp/delete?path=\(EngineAPI.q(path(name)))") }
        analysis[name] = nil
        await refresh()
    }

    func setEnabled(_ name: String, _ on: Bool) async {
        let new = on ? String(name.dropLast(".disabled".count)) : name + ".disabled"
        await run(on ? String(localized: "Увімкнено: \(new)") : String(localized: "Вимкнено: \(loc(name))")) { try await EngineAPI.send("/ftp/rename?from=\(EngineAPI.q(path(name)))&to=\(EngineAPI.q(path(new)))") }
        await refresh()
    }

    func read(_ name: String) async -> String? {
        busy = true; defer { busy = false }
        do {
            let d = try await EngineAPI.data("/ftp/read?path=\(EngineAPI.q(path(name)))")
            let text = String(decoding: d, as: UTF8.self)
            analysis[name] = Self.scriptingOptions(in: text, param: paramValue)
            return text
        } catch let e as EngineAPI.APIError { self.error = e.message } catch let e { self.error = e.localizedDescription }
        return nil
    }

    func analyzeAll() async {
        for it in items where !it.dir && (it.name.hasSuffix(".lua") || it.name.hasSuffix(".lua.disabled")) && it.size < 200_000 { _ = await read(it.name) }
        note = String(localized: "Скрипти проаналізовано")
    }

    func restartScripting() { EngineAPI.post("/scripting/restart") { _, _ in }; note = String(localized: "Команду перезапуску скриптів надіслано") }

    /// Поточне значення параметра на польотнику (задає сторінка), щоб розкрити опції, які скрипт бере з власних параметрів.
    @ObservationIgnored var paramValue: (String) -> Double? = { _ in nil }

    /// Які канали-опції Scripting (RCx_OPTION 300–307) використовує скрипт.
    /// Розуміє числа в виклику, локальні константи (`local OPT = 300`) і параметри скрипта
    /// (`local F = bind_add_param('RC_FUNC', 12, 300)` з `PARAM_TABLE_PREFIX`; береться значення з плати або типове).
    static func scriptingOptions(in text: String, param: (String) -> Double? = { _ in nil }) -> [Int] {
        let ns = text as NSString
        let all = NSRange(location: 0, length: ns.length)
        func matches(_ pattern: String) -> [NSTextCheckingResult] {
            guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
            return re.matches(in: text, range: all)
        }
        func str(_ m: NSTextCheckingResult, _ g: Int) -> String? { m.range(at: g).location == NSNotFound ? nil : ns.substring(with: m.range(at: g)) }

        var prefix = ""
        if let m = matches(#"PARAM_TABLE_PREFIX\s*=\s*["']([A-Za-z0-9_]+)["']"#).first, let p = str(m, 1) { prefix = p }
        var consts: [String: Double] = [:]
        for m in matches(#"local\s+(\w+)\s*=\s*(-?\d+)\s*(?:--.*)?$"#.replacingOccurrences(of: "$", with: "(?:\\n|\\z)")) {
            if let n = str(m, 1), let v = str(m, 2), let d = Double(v) { consts[n] = d }
        }
        var bound: [String: (name: String, def: Double)] = [:]
        for m in matches(#"local\s+(\w+)\s*=\s*bind_add_param\(\s*["'](\w+)["']\s*,\s*\d+\s*,\s*(-?[\d.]+)"#) {
            if let n = str(m, 1), let pn = str(m, 2), let d = str(m, 3).flatMap(Double.init) { bound[n] = (prefix + pn, d) }
        }
        for m in matches(#"local\s+(\w+)\s*=\s*bind_param\(\s*["']([A-Za-z0-9_]+)["']"#) {
            if let n = str(m, 1), let pn = str(m, 2) { bound[n] = (pn, 0) }
        }

        var res = Set<Int>()
        func add(_ v: Double) { let i = Int(v); if (300...307).contains(i) { res.insert(i) } }
        for m in matches(#"(?:find_channel_for_option|get_aux_cached|run_aux_function|get_pwm_input|get_pwm)\(\s*([A-Za-z_]\w*|\d+)\s*(?::get\(\s*\))?"#) {
            guard let arg = str(m, 1) else { continue }
            if let v = Double(arg) { add(v) }
            else if let b = bound[arg] { add(param(b.name) ?? b.def) }
            else if let c = consts[arg] { add(c) }
        }
        return res.sorted()
    }
}

struct ScriptsTab: View {
    @Environment(Store.self) var s
    @State private var m = ScriptsModel()
    @State private var io = IOStore()
    @AppStorage("scripts.dir") private var dir = "/APM/scripts"
    @State private var editing: String?
    @State private var editText = ""
    @State private var selected: String?
    var ps: ParamStore { s.ps }

    func isLua(_ n: String) -> Bool { n.hasSuffix(".lua") || n.hasSuffix(".lua.disabled") || n.hasSuffix(".luac") }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if !s.connected {
                    ContentUnavailableView("Польотник не підключений", systemImage: "cable.connector", description: Text("Підключіть плату, щоб керувати Lua-скриптами"))
                } else {
                    statusCard
                    listCard
                    slotsCard
                }
            }
            .padding(12)
        }
        .onAppear { m.dir = dir; m.paramValue = { [ps] in ps.val($0) }; io.start(); if s.connected { Task { await m.refresh() } } }
        .onDisappear { io.stop() }
        .onChange(of: s.connected) { _, c in if c { Task { await m.refresh() } } }
        .sheet(isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) { editor }
    }

    // MARK: Статус скриптингу
    var statusCard: some View {
        Card(title: String(localized: "Lua-скриптинг"), icon: "curlybraces", text: nil) {
            if !ps.has("SCR_ENABLE") {
                Label("Ця прошивка не підтримує скриптинг (параметра SCR_ENABLE немає).", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            } else {
                HStack(spacing: 16) {
                    Toggle("Увімкнено (SCR_ENABLE)", isOn: Binding(get: { (ps.val("SCR_ENABLE") ?? 0) > 0 }, set: { ps.write("SCR_ENABLE", $0 ? 1 : 0); m.note = String(localized: "Для застосування SCR_ENABLE потрібне перезавантаження автопілота") })).disabled(s.armed)
                    if ps.has("SCR_HEAP_SIZE") { ParamField(name: "SCR_HEAP_SIZE", width: 90) ; Text("пам'ять, байт").font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Button { m.restartScripting() } label: { Label("Перезапустити скрипти", systemImage: "arrow.clockwise") }.disabled(s.armed || (ps.val("SCR_ENABLE") ?? 0) == 0)
                    Button { EngineAPI.post("/reboot") } label: { Label("Перезавантажити", systemImage: "restart") }.disabled(s.armed)
                }
            }
            HStack {
                Text("Папка на SD:").font(.caption).foregroundStyle(.secondary)
                TextField("/APM/scripts", text: $dir).textFieldStyle(.roundedBorder).frame(width: 220).onSubmit { m.dir = dir; Task { await m.refresh() } }
                Text("(SCR_DIR за замовчуванням)").font(.caption).foregroundStyle(.secondary)
            }
            if let e = m.error { Label(LocalizedStringKey(e), systemImage: "exclamationmark.octagon.fill").foregroundStyle(.red).font(.callout) }
            if let n = m.note { Text(LocalizedStringKey(n)).font(.caption).foregroundStyle(.secondary) }
        }
    }

    // MARK: Список скриптів
    var listCard: some View {
        Card(title: String(localized: "Скрипти на польотнику"), icon: "doc.text", text: nil) {
            HStack(spacing: 8) {
                Button { pickAndUpload() } label: { Label("Завантажити скрипт…", systemImage: "square.and.arrow.up") }.disabled(s.armed || m.busy)
                Button { newScript() } label: { Label("Новий", systemImage: "plus") }.disabled(s.armed || m.busy)
                Button { Task { await m.refresh() } } label: { Label("Оновити", systemImage: "arrow.clockwise") }.disabled(m.busy)
                Button { Task { await m.analyzeAll() } } label: { Label("Проаналізувати канали", systemImage: "magnifyingglass") }.disabled(m.busy)
                if m.busy { ProgressView().controlSize(.small) }
                Spacer()
            }
            if m.dirMissing {
                HStack {
                    Label("Папки \(dir) не існує на SD-картці (або картки немає).", systemImage: "folder.badge.questionmark")
                    Button("Створити папку") { Task { await m.makeDir() } }.disabled(s.armed)
                }.font(.callout)
            } else if m.items.isEmpty && !m.busy && m.error == nil {
                Text("Скриптів немає. Завантажте .lua файл.").foregroundStyle(.secondary)
            }
            ForEach(m.items) { it in row(it) }
        }
    }

    func row(_ it: FtpItem) -> some View {
        let disabled = it.name.hasSuffix(".disabled")
        let used = (m.analysis[it.name] ?? []).map { "Scripting\($0 - 299)" }
        return HStack(spacing: 10) {
            if isLua(it.name) && !it.name.hasSuffix(".luac") {
                Toggle("", isOn: Binding(get: { !disabled }, set: { on in Task { await m.setEnabled(it.name, on) } })).labelsHidden().toggleStyle(.switch).controlSize(.small).disabled(s.armed || m.busy)
                    .help(lk(disabled ? "Вимкнений: польотник не запускає цей скрипт" : "Увімкнений: запускається при старті скриптингу"))
            } else { Color.clear.frame(width: 38, height: 1) }
            Image(systemName: it.dir ? "folder" : (isLua(it.name) ? "curlybraces" : "doc")).foregroundStyle(it.dir ? .blue : (disabled ? Color.secondary : Color.accentColor)).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(LocalizedStringKey(it.name)).font(.system(.body, design: .monospaced)).foregroundStyle(disabled ? .secondary : .primary)
                if !used.isEmpty { Text(lk(loc("Канал пульта: ") + used.joined(separator: ", "))).font(.caption).foregroundStyle(.teal) }
            }
            Spacer()
            if !it.dir { Text(lk(ByteCountFormatter.string(fromByteCount: Int64(it.size), countStyle: .file))).font(.caption).foregroundStyle(.secondary) }
            if !it.dir && isLua(it.name) {
                Button { open(it.name) } label: { Image(systemName: "pencil") }.help("Переглянути / редагувати").disabled(m.busy)
                Button { download(it.name) } label: { Image(systemName: "arrow.down.circle") }.help("Зберегти копію на Mac").disabled(m.busy)
            }
            if !it.dir {
                Button(role: .destructive) { confirmDelete(it.name) } label: { Image(systemName: "trash") }.help("Видалити з польотника").disabled(s.armed || m.busy)
            }
        }
        .buttonStyle(.borderless)
        .padding(.vertical, 4).padding(.horizontal, 8)
        .background(selected == it.name ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
        .onTapGesture { selected = it.name }
    }

    // MARK: Активація каналом пульта
    var slotsCard: some View {
        let chans = (1...16).filter { ps.has("RC\($0)_OPTION") }
        return Card(title: String(localized: "Активація скриптів каналом пульта"), icon: "slider.horizontal.3",
                    text: String(localized: "У ArduPilot скрипт реагує на канал через опції RCx_OPTION = 300…307 (Scripting 1–8). Призначте канал пульта слоту, який використовує ваш скрипт (див. «Канал пульта» біля скрипта). Як саме слот діє на скрипт, визначає сам скрипт.")) {
            if chans.isEmpty { Text("Параметри RCx_OPTION ще не завантажені.").foregroundStyle(.secondary) }
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                ForEach(0..<8, id: \.self) { k in
                    let code = 300 + k
                    let cur = chans.first { Int(ps.val("RC\($0)_OPTION") ?? 0) == code }
                    let scripts = m.analysis.filter { $0.value.contains(code) && !$0.key.hasSuffix(".disabled") }.keys.sorted()
                    GridRow {
                        Text("Scripting \(k + 1)").font(.callout.weight(.medium)).frame(width: 90, alignment: .leading)
                        Picker("", selection: Binding(get: { cur ?? 0 }, set: { assign(code, to: $0, chans: chans) })) {
                            Text("не призначено").tag(0)
                            ForEach(chans, id: \.self) { Text("Канал \($0)").tag($0) }
                        }.labelsHidden().frame(width: 140).disabled(s.armed)
                        if let c = cur, let pwm = io.io?.rc[safe: c - 1] {
                            PWMBar(pwm: pwm).frame(width: 160, height: 14)
                            Text("\(pwm) мкс · \(pwm < 1300 ? "LOW" : (pwm > 1700 ? "HIGH" : "MID"))").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
                        } else { Color.clear.frame(width: 260, height: 14) }
                        Text(lk(scripts.isEmpty ? "" : loc("використовує: ") + scripts.joined(separator: ", "))).font(.caption).foregroundStyle(.teal)
                    }
                }
            }
        }
    }

    func assign(_ code: Int, to ch: Int, chans: [Int]) {
        for c in chans where Int(ps.val("RC\(c)_OPTION") ?? 0) == code && c != ch { ps.write("RC\(c)_OPTION", 0) }
        if ch > 0 { ps.write("RC\(ch)_OPTION", Double(code)) }
        m.note = ch > 0 ? "RC\(ch)_OPTION = \(code) (Scripting \(code - 299))" : String(localized: "Слот Scripting \(code - 299) звільнено")
    }

    // MARK: Дії
    func pickAndUpload() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true; p.allowsOtherFileTypes = true
        p.allowedFileTypes = ["lua", "luac", "txt"]
        p.message = String(localized: "Оберіть Lua-скрипти для завантаження в \(dir)")
        guard p.runModal() == .OK else { return }
        let urls = p.urls
        let exists = urls.filter { u in m.items.contains { $0.name == u.lastPathComponent || $0.name == u.lastPathComponent + ".disabled" } }
        if !exists.isEmpty {
            let a = NSAlert(); a.messageText = String(localized: "Замінити існуючі скрипти?"); a.informativeText = exists.map(\.lastPathComponent).joined(separator: ", ")
            a.addButton(withTitle: String(localized: "Замінити")); a.addButton(withTitle: String(localized: "Скасувати"))
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        Task { await m.upload(urls) }
    }

    func newScript() {
        guard let r = Prompt.ask("Новий скрипт", message: String(localized: "Ім'я файлу (.lua)"), fields: [("Ім'я", "my_script.lua")]), !r[0].isEmpty else { return }
        var name = r[0].trimmingCharacters(in: .whitespaces); if !name.hasSuffix(".lua") { name += ".lua" }
        editText = String(localized: """
        -- \(loc(name))
        -- Скрипт ArduPilot Lua. Виконується щосекунди.
        local RC_OPTION = 300   -- Scripting 1: призначте канал пульта слоту Scripting 1

        function update()
          local ch = rc:find_channel_for_option(RC_OPTION)
          if ch then
            local pos = ch:get_aux_switch_pos()   -- 0 = LOW, 1 = MID, 2 = HIGH
            gcs:send_text(6, "Switch position: " .. tostring(pos))
          end
          return update, 1000
        end

        return update, 1000
        """)
        editing = name
    }

    func open(_ name: String) { Task { if let t = await m.read(name) { editText = t; editing = name } } }

    func download(_ name: String) {
        Task {
            guard let t = await m.read(name) else { return }
            let p = NSSavePanel(); p.nameFieldStringValue = name.replacingOccurrences(of: ".disabled", with: "")
            if p.runModal() == .OK, let u = p.url { try? t.write(to: u, atomically: true, encoding: .utf8); m.note = String(localized: "Збережено: \(u.lastPathComponent)") }
        }
    }

    func confirmDelete(_ name: String) {
        let a = NSAlert(); a.messageText = String(localized: "Видалити «\(loc(name))» з польотника?"); a.informativeText = String(localized: "Файл буде видалено з SD-картки. Збережіть копію, якщо вона потрібна.")
        a.alertStyle = .warning; a.addButton(withTitle: String(localized: "Видалити")); a.addButton(withTitle: String(localized: "Скасувати"))
        if a.runModal() == .alertFirstButtonReturn { Task { await m.delete(name) } }
    }

    var editor: some View {
        VStack(spacing: 0) {
            HStack {
                Label(lk(editing ?? ""), systemImage: "curlybraces").font(.headline)
                Spacer()
                Text("\(editText.split(separator: "\n", omittingEmptySubsequences: false).count) рядків").font(.caption).foregroundStyle(.secondary)
            }.padding(10)
            Divider()
            TextEditor(text: $editText).font(.system(size: 13, design: .monospaced)).autocorrectionDisabled()
            Divider()
            HStack {
                let opts = ScriptsModel.scriptingOptions(in: editText)
                if !opts.isEmpty { Label(lk(loc("Використовує Scripting ") + opts.map { String($0 - 299) }.joined(separator: ", ")), systemImage: "slider.horizontal.3").font(.caption).foregroundStyle(.teal) }
                Spacer()
                Button("Закрити") { editing = nil }
                Button("Зберегти на польотник") { if let n = editing { let t = editText; editing = nil; Task { await m.write(n, text: t) } } }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(s.armed)
            }.padding(10)
        }
        .frame(width: 720, height: 520)
    }
}

struct PWMBar: View {
    let pwm: Int
    var body: some View {
        GeometryReader { g in
            let f = max(0, min(1, Double(pwm - 1000) / 1000))
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(Color.accentColor.opacity(0.85)).frame(width: max(4, g.size.width * f))
            }
        }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
