import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct FtpGetDTO: Decodable { let state: String; let path: String; let dest: String; let size: Int; let received: Int; let bps: Double; let error: String? }

/// MAVFtp: огляд файлової системи польотника (SD-картка, @SYS, @ROMFS…) як у Mission Planner:
/// навігація по папках, завантаження файлів на Mac і відправлення з Mac, створення, перейменування й видалення.
@Observable @MainActor
final class MavFtpModel {
    var path = "/"
    var items: [FtpItem] = []
    var selected: String?
    var busy = false
    var error: String?
    var note: String?
    var get: FtpGetDTO?
    var history: [String] = []

    func full(_ name: String) -> String { path == "/" ? "/" + name : path + "/" + name }
    var parent: String? {
        guard path != "/" else { return nil }
        let p = (path as NSString).deletingLastPathComponent
        return p.isEmpty ? "/" : p
    }
    var selectedItem: FtpItem? { items.first { $0.name == selected } }

    func open(_ p: String, push: Bool = true) async {
        if push, p != path { history.append(path) }
        path = p; selected = nil
        await refresh()
    }
    func back() async { guard let p = history.popLast() else { return }; await open(p, push: false) }

    func refresh() async {
        busy = true; error = nil
        defer { busy = false }
        do {
            let d = try await EngineAPI.data("/ftp/list?path=\(EngineAPI.q(path))")
            let list = try JSONDecoder().decode([FtpItem].self, from: d)
            items = list.sorted { a, b in a.dir != b.dir ? a.dir : a.name.lowercased() < b.name.lowercased() }
        } catch let e as EngineAPI.APIError { items = []; error = e.message }
        catch let e { items = []; error = e.localizedDescription }
    }

    private func run(_ ok: String?, _ f: () async throws -> Void) async {
        busy = true; error = nil
        do { try await f(); if let ok { note = ok } }
        catch let e as EngineAPI.APIError { error = e.message } catch let e { error = e.localizedDescription }
        busy = false
    }

    func makeDir(_ name: String) async {
        await run(String(localized: "Папку створено: \(loc(name))")) { try await EngineAPI.send("/ftp/mkdir?path=\(EngineAPI.q(full(name)))") }
        await refresh()
    }
    func delete(_ name: String) async {
        await run(String(localized: "Видалено: \(loc(name))")) { try await EngineAPI.send("/ftp/delete?path=\(EngineAPI.q(full(name)))") }
        selected = nil
        await refresh()
    }
    func rename(_ name: String, to new: String) async {
        await run(String(localized: "Перейменовано: \(loc(name)) → \(new)")) { try await EngineAPI.send("/ftp/rename?from=\(EngineAPI.q(full(name)))&to=\(EngineAPI.q(full(new)))") }
        selected = new
        await refresh()
    }
    func upload(_ url: URL) async {
        await run(String(localized: "Відправлено на польотник: \(url.lastPathComponent)")) {
            let data = try Data(contentsOf: url)
            try await EngineAPI.send("/ftp/write?path=\(EngineAPI.q(full(url.lastPathComponent)))", body: data)
        }
        await refresh()
    }
    func preview(_ name: String) async -> String? {
        busy = true; defer { busy = false }
        do {
            let d = try await EngineAPI.data("/ftp/read?path=\(EngineAPI.q(full(name)))")
            return String(decoding: d, as: UTF8.self)
        } catch let e as EngineAPI.APIError { error = e.message } catch let e { error = e.localizedDescription }
        return nil
    }

    /// Завантаження файлу на диск у фоні: прогрес із двигуна.
    func download(_ name: String, to dest: URL) async {
        error = nil
        do { try await EngineAPI.send("/ftp/get?path=\(EngineAPI.q(full(name)))&dest=\(EngineAPI.q(dest.path))") }
        catch let e as EngineAPI.APIError { error = e.message; return } catch let e { error = e.localizedDescription; return }
        while true {
            if let st = await EngineAPI.get("/ftp/get/status", as: FtpGetDTO.self) {
                get = st
                if st.state != "running" {
                    if st.state == "done" { note = String(localized: "Збережено: \(dest.lastPathComponent)") }
                    else if st.state == "error" { error = st.error ?? "Помилка завантаження" }
                    else { note = String(localized: "Завантаження скасовано") }
                    break
                }
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        get = nil
    }
    func cancelDownload() { EngineAPI.post("/ftp/get/cancel") }
}

struct MavFtpView: View {
    @Environment(Store.self) var s
    @State private var m = MavFtpModel()
    @State private var pathText = "/"
    @State private var previewText: String?
    @State private var previewName = ""

    static func size(_ n: Int) -> String {
        n >= 1_048_576 ? String(format: loc("%.1f МБ"), Double(n) / 1_048_576) : n >= 1024 ? String(format: loc("%.1f КБ"), Double(n) / 1024) : String(localized: "\(n) Б")
    }

    var body: some View {
        ConfigGate {
            PageTitle(title: "MAVFtp", subtitle: String(localized: "Файлова система польотника: SD-картка (/APM), системні розділи (@SYS, @ROMFS) та інше. Можна переглядати, завантажувати на Mac, відправляти з Mac, створювати, перейменовувати й видаляти."))
            toolbar
            Card(title: String(localized: "Вміст: \(m.path)"), icon: "externaldrive", text: nil) {
                list
                statusLine
            }
            quickPaths
        }
        .task { if s.connected { await m.open("/") ; pathText = m.path } }
        .onChange(of: s.connected) { _, c in if c { Task { await m.open("/"); pathText = m.path } } }
        .onChange(of: m.path) { _, p in pathText = p }
        .sheet(isPresented: Binding(get: { previewText != nil }, set: { if !$0 { previewText = nil } })) { previewSheet }
    }

    // MARK: Панель
    var toolbar: some View {
        HStack(spacing: 8) {
            Button { Task { await m.back() } } label: { Image(systemName: "chevron.left") }.disabled(m.history.isEmpty).tip("Назад")
            Button { if let p = m.parent { Task { await m.open(p) } } } label: { Image(systemName: "arrow.up") }.disabled(m.parent == nil).tip("На рівень вище")
            Button { Task { await m.refresh() } } label: { Image(systemName: "arrow.clockwise") }.tip("Оновити")
            TextField("Шлях", text: $pathText).textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
                .onSubmit { Task { await m.open(pathText.isEmpty ? "/" : pathText) } }
            Divider().frame(height: 18)
            Button { download() } label: { Label("Завантажити", systemImage: "arrow.down.to.line") }
                .disabled(m.selectedItem == nil || m.selectedItem?.dir == true || m.get != nil)
            Button { upload() } label: { Label("Відправити…", systemImage: "arrow.up.to.line") }.disabled(m.get != nil)
            Button { newFolder() } label: { Label("Нова папка", systemImage: "folder.badge.plus") }
            Button { rename() } label: { Label("Перейменувати", systemImage: "pencil") }.disabled(m.selectedItem == nil)
            Button(role: .destructive) { delete() } label: { Label("Видалити", systemImage: "trash") }.disabled(m.selectedItem == nil)
        }
        .disabled(!s.connected || m.busy && m.get == nil)
        .controlSize(.small)
    }

    var list: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Назва").frame(maxWidth: .infinity, alignment: .leading)
                Text("Розмір").frame(width: 100, alignment: .trailing)
            }
            .font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.vertical, 5)
            Divider()
            if m.items.isEmpty && !m.busy {
                Text(lk(m.error == nil ? "Папка порожня" : "")).font(.callout).foregroundStyle(.secondary).padding(20).frame(maxWidth: .infinity)
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(m.items) { it in
                        HStack(spacing: 8) {
                            Image(systemName: it.dir ? "folder.fill" : icon(it.name)).foregroundStyle(it.dir ? Color.accentColor : .secondary).frame(width: 20)
                            Text(LocalizedStringKey(it.name)).font(.system(.callout, design: .monospaced)).lineLimit(1)
                            Spacer()
                            Text(lk(it.dir ? "—" : Self.size(it.size))).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).frame(width: 100, alignment: .trailing)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(m.selected == it.name ? Color.accentColor.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { activate(it) }
                        .onTapGesture { m.selected = it.name }
                        .contextMenu {
                            if it.dir { Button("Відкрити") { activate(it) } }
                            else {
                                Button("Завантажити…") { m.selected = it.name; download() }
                                if it.size < 512_000 { Button("Переглянути") { Task { await showPreview(it.name) } } }
                            }
                            Button("Копіювати шлях") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(m.full(it.name), forType: .string) }
                            Divider()
                            Button("Перейменувати…") { m.selected = it.name; rename() }
                            Button("Видалити…", role: .destructive) { m.selected = it.name; delete() }
                        }
                    }
                }
            }
            .frame(minHeight: 260, maxHeight: 420)
        }
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    func icon(_ n: String) -> String {
        let l = n.lowercased()
        if l.hasSuffix(".lua") || l.hasSuffix(".txt") || l.hasSuffix(".param") || l.hasSuffix(".parm") || l.hasSuffix(".cfg") { return "doc.text" }
        if l.hasSuffix(".bin") || l.hasSuffix(".log") || l.hasSuffix(".tlog") { return "chart.xyaxis.line" }
        if l.hasSuffix(".dat") || l.hasSuffix(".hgt") { return "mountain.2" }
        return "doc"
    }

    @ViewBuilder var statusLine: some View {
        if let g = m.get {
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: Double(g.received), total: Double(max(g.size, 1)))
                HStack {
                    Text(lk(String(localized: "\((g.path as NSString).lastPathComponent): \(Self.size(g.received)) з \(Self.size(g.size))") + (g.bps > 0 ? String(format: loc(" · %.0f КБ/с"), g.bps / 1024) : "")))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Spacer()
                    Button("Скасувати") { m.cancelDownload() }.controlSize(.mini)
                }
            }.padding(.top, 6)
        } else if m.busy { HStack { ProgressView().controlSize(.small); Text("Виконується…").font(.caption).foregroundStyle(.secondary) }.padding(.top, 6) }
        if let e = m.error { Label(LocalizedStringKey(e), systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange).padding(.top, 4) }
        if let n = m.note { Label(LocalizedStringKey(n), systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary).padding(.top, 2) }
    }

    var quickPaths: some View {
        HStack(spacing: 8) {
            Text("Швидкий перехід:").font(.caption).foregroundStyle(.secondary)
            ForEach(["/", "/APM", "/APM/LOGS", "/APM/scripts", "/@SYS", "/@ROMFS", "/@MISSION"], id: \.self) { p in
                Button(lk(p)) { Task { await m.open(p) } }.controlSize(.small).font(.system(.caption, design: .monospaced))
            }
            Spacer()
        }.disabled(!s.connected)
    }

    var previewSheet: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text(LocalizedStringKey(previewName)).font(.headline); Spacer(); Button("Закрити") { previewText = nil } }
            ScrollView { Text(lk(previewText ?? "")).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                .frame(minWidth: 640, minHeight: 380)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        }.padding(16)
    }

    // MARK: Дії
    func activate(_ it: FtpItem) {
        if it.dir { Task { await m.open(m.full(it.name)) } }
        else { m.selected = it.name; if it.size < 512_000 { Task { await showPreview(it.name) } } }
    }
    func showPreview(_ name: String) async {
        if let t = await m.preview(name) { previewName = m.full(name); previewText = t }
    }
    func download() {
        guard let it = m.selectedItem, !it.dir else { return }
        let p = NSSavePanel(); p.nameFieldStringValue = it.name; p.message = String(localized: "Зберегти файл із польотника")
        guard p.runModal() == .OK, let url = p.url else { return }
        Task { await m.download(it.name, to: url) }
    }
    func upload() {
        let p = NSOpenPanel(); p.canChooseFiles = true; p.canChooseDirectories = false; p.message = String(localized: "Оберіть файл для відправки в \(m.path)")
        guard p.runModal() == .OK, let url = p.url else { return }
        let a = NSAlert(); a.alertStyle = .warning; a.messageText = String(localized: "Відправити файл на польотник?")
        a.informativeText = String(localized: "\(url.lastPathComponent) буде записано в \(m.path). Файл із такою назвою буде замінено.")
        a.addButton(withTitle: String(localized: "Відправити")); a.addButton(withTitle: String(localized: "Скасувати"))
        guard a.runModal() == .alertFirstButtonReturn else { return }
        Task { await m.upload(url) }
    }
    func newFolder() {
        guard let r = Prompt.ask("Нова папка", message: String(localized: "Створюється в \(m.path)"), fields: [("Назва", "")]), !r[0].isEmpty else { return }
        Task { await m.makeDir(r[0]) }
    }
    func rename() {
        guard let it = m.selectedItem, let r = Prompt.ask("Перейменувати", message: it.name, fields: [("Нова назва", it.name)]), !r[0].isEmpty, r[0] != it.name else { return }
        Task { await m.rename(it.name, to: r[0]) }
    }
    func delete() {
        guard let it = m.selectedItem else { return }
        let a = NSAlert(); a.alertStyle = .critical; a.messageText = String(localized: "Видалити \(it.dir ? "папку" : "файл") «\(loc(it.name))»?")
        a.informativeText = String(localized: "Видалення на польотнику незворотне. Шлях: \(m.full(it.name))")
        a.addButton(withTitle: String(localized: "Видалити")); a.addButton(withTitle: String(localized: "Скасувати"))
        guard a.runModal() == .alertFirstButtonReturn else { return }
        Task { await m.delete(it.name) }
    }
}
