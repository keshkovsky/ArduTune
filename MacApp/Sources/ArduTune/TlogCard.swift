import SwiftUI
import AppKit

/// Записи MAVLink, які ArduTune пише на Mac з першого heartbeat: керування, відтворення і перегляд.
struct TlogCard: View {
    @Environment(Store.self) var s
    @Environment(\.openWindow) private var openWindow
    @State private var files: [TlogFile] = []
    @State private var speed = 1.0
    @State private var note: String?
    @State private var recordOn = !FileManager.default.fileExists(atPath: TlogCard.flag)
    private static let base = NSHomeDirectory() + "/Library/Application Support/ArduTune"
    private static var dir: String { AppSettings.logFolders.tlog }
    private static let flag = base + "/norecord"

    var empties: [TlogFile] { files.filter { $0.size < 1024 && $0.name != s.t.recordFile } }

    var body: some View {
        Card(title: String(localized: "Локальні записи MAVLink"), icon: "waveform.path.ecg", text: String(localized: "Це не логи польотника. ArduTune сам записує MAVLink-телеметрію на Mac з кожного підключення (.tlog). Запис можна переглянути, проаналізувати чи відтворити у Flight Data.")) {
            Toggle("Записувати телеметрію на Mac", isOn: Binding(get: { recordOn }, set: { setRecord($0) })).toggleStyle(.switch).controlSize(.small)
            if s.t.recording, let f = s.t.recordFile {
                Label("Запис: \(f)", systemImage: "record.circle").foregroundStyle(.red).font(.caption).lineLimit(1).truncationMode(.middle)
            }
            HStack {
                Button { openFile() } label: { Label("Відкрити…", systemImage: "folder") }
                Spacer()
                Menu {
                    Button("Очистити порожні (\(empties.count))") { cleanEmpty() }.disabled(empties.isEmpty)
                    Button("Видалити всі записи…", role: .destructive) { deleteAll() }.disabled(files.isEmpty)
                    Divider()
                    Button("Показати папку") { NSWorkspace.shared.open(URL(fileURLWithPath: Self.dir)) }
                } label: { Label("Керування", systemImage: "ellipsis.circle") }.menuStyle(.borderlessButton).fixedSize()
            }
            HStack {
                Text("Швидкість відтворення").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $speed) { ForEach([0.25, 0.5, 1, 2, 4, 8], id: \.self) { Text("×\($0.formatted())").tag($0) } }.labelsHidden().frame(width: 70)
                if s.t.replaying { Button("Стоп") { EngineAPI.post("/replay/stop") }.controlSize(.small) }
            }
            if s.t.replaying {
                HStack {
                    ProgressView(value: s.t.replayProgress)
                    Text(String(format: "%.0f %%", s.t.replayProgress * 100)).font(.caption.monospacedDigit())
                }
            }
            if let n = note { Text(LocalizedStringKey(n)).font(.caption).foregroundStyle(.orange) }
            if files.isEmpty { Text("Записів поки немає").font(.caption).foregroundStyle(.secondary) }
            ForEach(files.prefix(40)) { f in
                HStack(spacing: 6) {
                    Button { openWindow(id: "tlogview", value: f.path) } label: { Image(systemName: "chart.xyaxis.line") }.buttonStyle(.borderless).tip("Переглянути й проаналізувати в окремому вікні").disabled(f.size < 1024)
                    Button { play(f.path) } label: { Image(systemName: "play.fill") }.buttonStyle(.borderless).tip("Відтворити у Flight Data").disabled(f.size < 1024)
                    Text(LocalizedStringKey(f.date)).font(.system(.caption, design: .monospaced))
                    Spacer()
                    Text(lk(ByteCountFormatter.string(fromByteCount: Int64(f.size), countStyle: .file))).font(.caption).foregroundStyle(.secondary)
                }
                .contextMenu {
                    Button("Переглянути в окремому вікні") { openWindow(id: "tlogview", value: f.path) }
                    Button("Відтворити у Flight Data") { play(f.path) }
                    Button("Показати у Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: f.path)]) }
                    Divider()
                    Button("Видалити", role: .destructive) { remove([f]) }.disabled(f.name == s.t.recordFile)
                }
            }
            if files.count > 40 { Text("Показано 40 з \(files.count). Решта в папці.").font(.caption2).foregroundStyle(.secondary) }
        }
        .task {
            while !Task.isCancelled {
                if let d = await EngineAPI.get("/logs", as: [TlogFile].self) { files = d }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    // MARK: Дії

    func setRecord(_ on: Bool) {
        recordOn = on
        let fm = FileManager.default
        if on { try? fm.removeItem(atPath: Self.flag); if s.connected { EngineAPI.post("/record/start") } }
        else { fm.createFile(atPath: Self.flag, contents: Data()); EngineAPI.post("/record/stop") }
        note = on ? loc("Запис увімкнено") + (s.connected ? "" : ": почнеться при підключенні") : "Запис вимкнено: нові tlog не створюються"
    }

    func remove(_ l: [TlogFile]) {
        for f in l where f.name != s.t.recordFile { try? FileManager.default.removeItem(atPath: f.path) }
        files.removeAll { f in l.contains { $0.path == f.path } }
    }
    func cleanEmpty() { let n = empties.count; remove(empties); note = String(localized: "Видалено порожніх записів: \(n)") }
    func deleteAll() {
        let a = NSAlert()
        a.messageText = String(localized: "Видалити всі записи MAVLink?")
        a.informativeText = String(localized: "Буде видалено \(files.count) файлів tlog з Mac. Логи з польотника (.bin) не торкаються. Дію не можна скасувати.")
        a.alertStyle = .warning
        a.addButton(withTitle: String(localized: "Видалити")); a.addButton(withTitle: String(localized: "Скасувати"))
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let n = files.filter { $0.name != s.t.recordFile }.count
        remove(files)
        try? FileManager.default.removeItem(atPath: Self.base + "/TlogView")
        note = String(localized: "Видалено записів: \(n)") + (s.t.recording ? " (поточний запис лишено)" : "")
    }

    func openFile() {
        let p = NSOpenPanel()
        p.directoryURL = URL(fileURLWithPath: Self.dir)
        p.message = String(localized: "Оберіть файл телеметрії (.tlog)")
        p.allowsOtherFileTypes = true
        guard p.runModal() == .OK, let u = p.url else { return }
        openWindow(id: "tlogview", value: u.path)
    }

    func play(_ path: String) {
        var c = URLComponents(string: EngineAPI.base + "/replay/start")!
        c.queryItems = [.init(name: "path", value: path), .init(name: "speed", value: String(speed))]
        let r = EngineAPI.request(c.url!, method: "POST")
        URLSession.shared.dataTask(with: r) { _, resp, _ in
            DispatchQueue.main.async { note = (resp as? HTTPURLResponse)?.statusCode == 200 ? "Відтворення… дані видно у Flight Data" : "Відтворення неможливе: польотник підключений" }
        }.resume()
    }
}
