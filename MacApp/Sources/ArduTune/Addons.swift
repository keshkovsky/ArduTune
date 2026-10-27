import Foundation
import JavaScriptCore
import Observation
import CoreLocation
import AppKit

// MARK: - Розширення (Add-ons)
// Розширення — тека `~/Library/Application Support/ArduTune/Addons/<тека>/` з `addon.json` і скриптом (`main.js`).
// ArduTune сканує теку при запуску, виконує скрипт у ізольованому JavaScriptCore і дає йому API `ardutune` за заявленими дозволами.

struct AddonManifest: Decodable {
    var id: String
    var name: String
    var version: String?
    var author: String?
    var description: String?
    var main: String?
    var permissions: [String]?
    var icon: String?
}

/// Усі дозволи, які може просити розширення (опис для користувача).
enum AddonPermission {
    static let all: [(id: String, title: String, detail: String)] = [
        ("telemetry", "Телеметрія", "Читати стан апарата (позиція, режим, батарея, ARM тощо)."),
        ("params.read", "Читання параметрів", "Читати параметри польотника."),
        ("params.write", "Запис параметрів", "Змінювати параметри польотника (заборонено при ARMED)."),
        ("commands", "Команди польотнику", "Надсилати MAVLink-команди (COMMAND_LONG)."),
        ("serial", "Послідовні порти", "Відкривати USB-UART порти й обмінюватись даними з пристроями."),
        ("net", "Локальна мережа", "Відкривати TCP/UDP-з'єднання з пристроями в локальній мережі (RNDIS/Ethernet; лише приватні адреси)."),
        ("mavlink", "Сирі MAVLink-повідомлення", "Читати останні отримані MAVLink-повідомлення за іменем і надсилати довільні (крім команд, параметрів, режимів, місій і файлів)."),
        ("http", "HTTP у локальній мережі", "Робити HTTP/HTTPS-запити до пристроїв у локальній мережі (приватні адреси)."),
        ("internet", "Інтернет", "Робити HTTPS-запити до сайтів в інтернеті (дані можуть залишати ваш Mac)."),
        ("ui", "Сторінки в інтерфейсі", "Показувати власні сторінки й вкладки."),
        ("hud", "Рядки в HUD", "Додавати текстові рядки в HUD."),
        ("map", "Позначки на мапі", "Малювати маркери й лінії на мапі Flight Data та додавати пункти в її меню."),
    ]
    static func title(_ id: String) -> String { all.first { $0.id == id }?.title ?? id }
}

struct AddonPage: Identifiable {
    var id: String               // "<addonId>/<pageId>"
    var pageID: String
    var title: String
    var icon: String
    var location: String         // addons | optional | flight
    var render: JSValue
}
struct AddonMarker: Identifiable, Equatable { var id: String; var lat: Double; var lon: Double; var title: String; var symbol: String; var color: String }
struct AddonLine: Identifiable, Equatable { var id: String; var points: [[Double]]; var color: String; var dashed: Bool }
struct AddonMenuItem { var addon: String; var title: String; var handler: JSValue }

@Observable @MainActor
final class Addon: Identifiable {
    let id: String
    let manifest: AddonManifest
    let dir: URL
    var enabled = false
    var granted: Set<String> = []
    var status = ""
    var log: [String] = []
    var pages: [AddonPage] = []
    var hudLines: [String] = []
    var markers: [AddonMarker] = []
    var lines: [AddonLine] = []
    var menu: [AddonMenuItem] = []
    @ObservationIgnored var runtime: AddonRuntime?

    init(manifest: AddonManifest, dir: URL) { id = manifest.id; self.manifest = manifest; self.dir = dir }
    var declared: [String] { manifest.permissions ?? [] }
    var name: String { manifest.name }
    func addLog(_ s: String) {
        log.append(s); if log.count > 200 { log.removeFirst(log.count - 200) }
        // журнал також у файлі `addon.log` у теці розширення (корисно авторам)
        let url = dir.appendingPathComponent("addon.log")
        let line = Data((ISO8601DateFormatter().string(from: Date()) + " " + s + "\n").utf8)
        if let h = try? FileHandle(forWritingTo: url) {
            if (try? h.seekToEnd()).map({ $0 > 200_000 }) == true { try? h.truncate(atOffset: 0) }
            try? h.write(contentsOf: line); try? h.close()
        } else { try? line.write(to: url) }
    }
}

@Observable @MainActor
final class AddonManager {
    static let shared = AddonManager()
    private(set) var addons: [Addon] = []
    var scanError = ""
    @ObservationIgnored weak var store: Store?
    @ObservationIgnored private var tick: Timer?

    static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ArduTune/Addons", isDirectory: true)
    }
    private var ud: UserDefaults { .standard }

    func attach(_ s: Store) {
        store = s
        installBundledIfNeeded()
        scan()
        tick?.invalidate()
        tick = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.fireTelemetry() } }
    }

    // MARK: Сканування

    func scan() {
        for a in addons { a.runtime?.stop() }
        addons = []; scanError = ""
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        let dirs = ((try? FileManager.default.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        let enabled = Set((ud.string(forKey: "addons.enabled") ?? "").split(separator: ",").map(String.init))
        for d in dirs {
            let mf = d.appendingPathComponent("addon.json")
            guard let data = try? Data(contentsOf: mf) else { continue }
            guard let m = try? JSONDecoder().decode(AddonManifest.self, from: data), !m.id.isEmpty, !addons.contains(where: { $0.id == m.id }) else {
                scanError += String(localized: "Не вдалося прочитати \(d.lastPathComponent)/addon.json\n"); continue
            }
            let a = Addon(manifest: m, dir: d)
            a.granted = Set((ud.string(forKey: "addons.perms.\(m.id)") ?? "").split(separator: ",").map(String.init)).intersection(m.permissions ?? [])
            addons.append(a)
            if enabled.contains(m.id) { start(a) }
        }
    }

    private func saveEnabled() { ud.set(addons.filter(\.enabled).map(\.id).joined(separator: ","), forKey: "addons.enabled") }
    private func savePerms(_ a: Addon) { ud.set(a.granted.sorted().joined(separator: ","), forKey: "addons.perms.\(a.id)") }

    /// Увімкнення = згода на всі заявлені розширенням дозволи (їх можна окремо відкликати).
    func setEnabled(_ a: Addon, _ on: Bool) {
        if on {
            if a.granted.isEmpty { a.granted = Set(a.declared); savePerms(a) }
            start(a)
        } else { a.runtime?.stop(); a.runtime = nil; a.enabled = false; a.pages = []; a.hudLines = []; a.markers = []; a.lines = []; a.menu = [] }
        saveEnabled()
    }
    func setGranted(_ a: Addon, _ perm: String, _ on: Bool) {
        if on { a.granted.insert(perm) } else { a.granted.remove(perm) }
        savePerms(a)
        if a.enabled { start(a) }       // перезапуск із новими дозволами
    }
    func reload(_ a: Addon) { if a.enabled { start(a) } }

    private func start(_ a: Addon) {
        a.runtime?.stop()
        a.pages = []; a.hudLines = []; a.markers = []; a.lines = []; a.menu = []; a.status = ""
        a.enabled = true
        let rt = AddonRuntime(addon: a, manager: self)
        a.runtime = rt
        rt.run()
    }

    // MARK: Дані для інтерфейсу

    func pages(_ location: String) -> [AddonPage] { addons.filter(\.enabled).flatMap(\.pages).filter { $0.location == location } }
    func page(_ id: String) -> (Addon, AddonPage)? {
        for a in addons { if let p = a.pages.first(where: { $0.id == id }) { return (a, p) } }
        return nil
    }
    var hudLines: [String] { addons.filter(\.enabled).flatMap(\.hudLines) }
    var markers: [AddonMarker] { addons.filter(\.enabled).flatMap(\.markers) }
    var lines: [AddonLine] { addons.filter(\.enabled).flatMap(\.lines) }
    func menuItems() -> [(Addon, AddonMenuItem)] { addons.filter(\.enabled).flatMap { a in a.menu.map { (a, $0) } } }

    func fire(_ item: AddonMenuItem, _ c: CLLocationCoordinate2D) { addons.first { $0.id == item.addon }?.runtime?.fireMenu(item, c) }
    private func fireTelemetry() { for a in addons where a.enabled { a.runtime?.emitTelemetry() } }

    // MARK: Вбудовані розширення

    /// Копіює вбудовані розширення в теку користувача (один раз для кожного id; наявні не чіпає).
    func installBundledIfNeeded(force: Bool = false) {
        let fm = FileManager.default
        var src: URL? = Bundle.main.url(forResource: "addons", withExtension: nil)
        if src == nil { let dev = URL(fileURLWithPath: NSHomeDirectory() + "/Developer/ArduTune/MacApp/Resources/addons"); if fm.fileExists(atPath: dev.path) { src = dev } }
        guard let src, let items = try? fm.contentsOfDirectory(at: src, includingPropertiesForKeys: nil) else { return }
        try? fm.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        let done = Set((ud.string(forKey: "addons.bundled.installed") ?? "").split(separator: ",").map(String.init))
        var now = done
        for d in items where fm.fileExists(atPath: d.appendingPathComponent("addon.json").path) {
            let name = d.lastPathComponent
            if !force && done.contains(name) { continue }
            let dst = Self.folder.appendingPathComponent(name)
            if fm.fileExists(atPath: dst.path) { if force { try? fm.removeItem(at: dst) } else { now.insert(name); continue } }
            try? fm.copyItem(at: d, to: dst); now.insert(name)
        }
        ud.set(now.sorted().joined(separator: ","), forKey: "addons.bundled.installed")
    }
}
