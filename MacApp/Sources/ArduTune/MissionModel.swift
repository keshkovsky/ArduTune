import SwiftUI
import MapKit
import AppKit
import Observation

// MARK: - Каталог команд

struct MissionCmd: Identifiable {
    let id: Int
    let name: String
    let icon: String
    let loc: Bool              // має координати
    let params: [String?]      // підписи p1…p4 (nil = не використовується)
    var nav = false            // навігаційна точка (є в маршруті)
}

enum MissionCatalog {
    static let groups: [(String, [MissionCmd])] = [
        ("Навігація", [
            MissionCmd(id: 16, name: "Точка маршруту", icon: "mappin.circle", loc: true, params: ["Затримка, с", "Радіус прийому, м", "Радіус проходу, м", "Курс, °"], nav: true),
            MissionCmd(id: 22, name: "Зліт", icon: "airplane.departure", loc: true, params: ["Кут тангажа, °", nil, nil, "Курс, °"], nav: true),
            MissionCmd(id: 21, name: "Посадка", icon: "airplane.arrival", loc: true, params: ["Витримка, с", "Точна посадка", nil, "Курс, °"], nav: true),
            MissionCmd(id: 20, name: "Повернення (RTL)", icon: "house", loc: false, params: [nil, nil, nil, nil]),
            MissionCmd(id: 17, name: "Кружляти (без обмеження)", icon: "arrow.triangle.2.circlepath", loc: true, params: [nil, nil, "Радіус, м (−: проти годинникової)", nil], nav: true),
            MissionCmd(id: 18, name: "Кружляти N кіл", icon: "arrow.triangle.2.circlepath", loc: true, params: ["Кіл", nil, "Радіус, м", nil], nav: true),
            MissionCmd(id: 19, name: "Кружляти за часом", icon: "timer", loc: true, params: ["Час, с", nil, "Радіус, м", nil], nav: true),
            MissionCmd(id: 31, name: "Кружляти до висоти", icon: "arrow.up.circle", loc: true, params: ["Напрям (0 за замовч.)", nil, "Радіус, м", nil], nav: true),
            MissionCmd(id: 82, name: "Сплайн-точка", icon: "point.topleft.down.curvedto.point.bottomright.up", loc: true, params: ["Затримка, с", nil, nil, nil], nav: true),
            MissionCmd(id: 84, name: "VTOL зліт", icon: "airplane.departure", loc: true, params: [nil, nil, nil, "Курс, °"], nav: true),
            MissionCmd(id: 85, name: "VTOL посадка", icon: "airplane.arrival", loc: true, params: [nil, nil, nil, "Курс, °"], nav: true),
            MissionCmd(id: 93, name: "Очікування", icon: "hourglass", loc: false, params: ["Секунд (−1: ігнор.)", "Година", "Хвилина", "Секунда"]),
        ]),
        ("Дії", [
            MissionCmd(id: 178, name: "Змінити швидкість", icon: "speedometer", loc: false, params: ["Тип (0 повітряна, 1 шляхова)", "Швидкість, м/с", "Газ, % (−1 без змін)", nil]),
            MissionCmd(id: 177, name: "Перейти до точки (Jump)", icon: "arrow.uturn.backward", loc: false, params: ["Номер точки", "Повторів (−1 вічно)", nil, nil]),
            MissionCmd(id: 183, name: "Серво", icon: "slider.horizontal.below.rectangle", loc: false, params: ["Канал", "PWM, мкс", nil, nil]),
            MissionCmd(id: 184, name: "Серво (повтор)", icon: "slider.horizontal.below.rectangle", loc: false, params: ["Канал", "PWM, мкс", "Разів", "Пауза, с"]),
            MissionCmd(id: 181, name: "Реле", icon: "switch.2", loc: false, params: ["Номер реле", "Стан (0/1)", nil, nil]),
            MissionCmd(id: 182, name: "Реле (повтор)", icon: "switch.2", loc: false, params: ["Номер реле", "Разів", "Пауза, с", nil]),
            MissionCmd(id: 201, name: "ROI (ціль камери)", icon: "camera.viewfinder", loc: true, params: ["Режим ROI", nil, nil, nil]),
            MissionCmd(id: 205, name: "Керування підвісом", icon: "camera.aperture", loc: false, params: ["Тангаж, °", "Крен, °", "Курс, °", nil]),
            MissionCmd(id: 206, name: "Камера: кадр кожні N м", icon: "camera", loc: false, params: ["Відстань, м", "Затвор, мс", "Спуск (0/1)", nil]),
            MissionCmd(id: 203, name: "Керування камерою", icon: "camera.shutter.button", loc: false, params: ["Сесія", "Zoom", "Фокус", "Затвор"]),
            MissionCmd(id: 207, name: "Геозона вкл/викл", icon: "square.dashed", loc: false, params: ["0 викл, 1 вкл", nil, nil, nil]),
            MissionCmd(id: 211, name: "Захват (Gripper)", icon: "hand.raised", loc: false, params: ["Номер", "Дія (0 відпустити, 1 стиснути)", nil, nil]),
            MissionCmd(id: 189, name: "Початок посадки (DO_LAND_START)", icon: "flag", loc: false, params: [nil, nil, nil, nil]),
            MissionCmd(id: 179, name: "Встановити Home", icon: "house.circle", loc: true, params: ["Поточна позиція (1)", nil, nil, nil]),
        ]),
        ("Умови", [
            MissionCmd(id: 112, name: "Умова: затримка", icon: "clock", loc: false, params: ["Секунд", nil, nil, nil]),
            MissionCmd(id: 113, name: "Умова: висота", icon: "arrow.up.and.down", loc: false, params: ["Швидкість, м/с", nil, nil, nil]),
            MissionCmd(id: 114, name: "Умова: відстань", icon: "ruler", loc: false, params: ["Метрів", nil, nil, nil]),
            MissionCmd(id: 115, name: "Умова: курс", icon: "location.north", loc: false, params: ["Курс, °", "Швидкість, °/с", "Напрям (1/−1)", "Відносно (0/1)"]),
        ]),
    ]
    /// Іконка й колір типу точки (для маркерів на карті та списку).
    static func badge(_ cmd: Int) -> (String, NSColor) {
        switch cmd {
        case 16: return ("arrow.turn.up.right", .systemBlue)
        case 82: return ("point.topleft.down.curvedto.point.bottomright.up", .systemTeal)
        case 22, 84: return ("airplane.departure", .systemGreen)
        case 21, 85: return ("airplane.arrival", .systemRed)
        case 20: return ("house.fill", .systemGray)
        case 17, 18, 19, 31: return ("arrow.triangle.2.circlepath", .systemOrange)
        case 201: return ("camera.viewfinder", .systemPurple)
        case 5001: return ("square.dashed", .systemGreen)
        case 5002: return ("square.dashed", .systemRed)
        case 5003: return ("circle.dashed", .systemGreen)
        case 5004: return ("circle.dashed", .systemRed)
        case 5100: return ("lifepreserver.fill", .systemTeal)
        case 5200, 5201: return ("square.grid.3x3", .systemPurple)
        default: return (find(cmd).icon, .systemIndigo)
        }
    }
    static let all: [MissionCmd] = groups.flatMap { $0.1 }
    static func find(_ id: Int) -> MissionCmd { all.first { $0.id == id } ?? MissionCmd(id: id, name: String(localized: "Команда \(id)"), icon: "questionmark.circle", loc: false, params: ["p1", "p2", "p3", "p4"]) }
    static let frames: [(Int, String)] = [(3, "Відносна (над Home)"), (0, "Абсолютна (AMSL)"), (10, "Над рельєфом")]
}

// MARK: - Елемент

struct MissionItem: Identifiable, Codable, Equatable {
    var id = UUID()
    var cmd = 16
    var frame = 3
    var p1 = 0.0, p2 = 0.0, p3 = 0.0, p4 = 0.0
    var lat = 0.0, lon = 0.0, alt = 50.0
    var auto = true
    var group: UUID?                 // ділянка обліту, що згенерувала цю точку

    var def: MissionCmd { MissionCatalog.find(cmd) }
    var hasPos: Bool { def.loc && !(lat == 0 && lon == 0) }
    var coord: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }
    func param(_ i: Int) -> Double { [p1, p2, p3, p4][i] }
    mutating func setParam(_ i: Int, _ v: Double) { switch i { case 0: p1 = v; case 1: p2 = v; case 2: p3 = v; default: p4 = v } }
    /// Радіус кола для точок з кружлянням.
    var loiterRadius: Double? { [17, 18, 19, 31].contains(cmd) ? abs(p3 == 0 ? 80 : p3) : nil }
}

struct WireItem: Codable { var seq: Int, cmd: Int, frame: Int, p1: Double, p2: Double, p3: Double, p4: Double, lat: Double, lon: Double, alt: Double, auto: Bool }
struct HomePoint: Codable, Equatable { var lat: Double, lon: Double, alt: Double }

struct MissionIssue: Identifiable { let id = UUID(); let level: Int; let text: String }       // 0 інфо, 1 попередження

// MARK: - Геозона і Rally

struct GeoPt: Codable, Equatable, Identifiable {
    var id = UUID(); var lat: Double; var lon: Double
    var coord: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }
}
/// Зона геозони: 5001/5002 багатокутник (включення/виключення), 5003/5004 коло.
struct FenceZone: Identifiable, Codable, Equatable {
    var id = UUID(); var kind = 5001; var pts: [GeoPt] = []; var radius = 200.0
    var isCircle: Bool { kind == 5003 || kind == 5004 }
    var exclusion: Bool { kind == 5002 || kind == 5004 }
    var title: String { [5001: "Багатокутник: дозволена зона", 5002: "Багатокутник: заборонена зона", 5003: "Коло: дозволена зона", 5004: "Коло: заборонена зона"][kind] ?? "Зона" }
}
struct RallyPoint: Identifiable, Codable, Equatable { var id = UUID(); var lat: Double; var lon: Double; var alt = 50.0 }
enum MissionSection: String, CaseIterable { case route = "Маршрут", survey = "Ділянка", fence = "Геозона", rally = "Rally" }

// MARK: - Сховище

@Observable
final class MissionStore {
    var items: [MissionItem] = [] { didSet { dirty = true; saveDraft(); rec("items", Snap(items: oldValue, zones: zones, rally: rally, home: home, surveys: surveys)) } }
    var home: HomePoint? { didSet { saveDraft(); rec("home", Snap(items: items, zones: zones, rally: rally, home: oldValue, surveys: surveys)) } }
    var selected: UUID?
    var busy: String?
    var note: String?
    var error: String?
    var dirty = false
    var section: MissionSection = .route
    var zones: [FenceZone] = [] { didSet { fenceDirty = true; saveDraft(); rec("zones", Snap(items: items, zones: oldValue, rally: rally, home: home, surveys: surveys)) } }
    var rally: [RallyPoint] = [] { didSet { rallyDirty = true; saveDraft(); rec("rally", Snap(items: items, zones: zones, rally: oldValue, home: home, surveys: surveys)) } }
    var surveys: [SurveyArea] = [] { didSet { saveDraft(); rec("surveys", Snap(items: items, zones: zones, rally: rally, home: home, surveys: oldValue)) } }
    var selectedSurvey: UUID?
    let sim = MissionSim()
    let ruler = MapRuler()
    var view3D = UserDefaults.standard.bool(forKey: "mission.view3D") { didSet { UserDefaults.standard.set(view3D, forKey: "mission.view3D") } }
    var following: String?                           // стан «летіти до точки й зависнути»
    @ObservationIgnored var followTask: Task<Void, Never>?
    @ObservationIgnored private var undoStack: [Snap] = []
    @ObservationIgnored private var redoStack: [Snap] = []
    @ObservationIgnored private var lastRec = Date.distantPast
    @ObservationIgnored private var lastKind = ""
    @ObservationIgnored private var restoring = false
    @ObservationIgnored var clipItem: MissionItem?
    @ObservationIgnored var clipText = ""
    var fenceDirty = false
    var rallyDirty = false
    var selectedZone: UUID?
    @ObservationIgnored var blocked: [CGRect] = []
    var tool = 16                                    // яку команду додає клік по карті
    var addMode = false
    var defaultAlt: Double { didSet { UserDefaults.standard.set(defaultAlt, forKey: "mission.alt") } }
    var defaultFrame: Int { didSet { UserDefaults.standard.set(defaultFrame, forKey: "mission.frame") } }
    var cruise: Double { didSet { UserDefaults.standard.set(cruise, forKey: "mission.cruise") } }

    private static let draftURL = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/ArduTune/Mission/draft.json")

    init() {
        let d = UserDefaults.standard
        defaultAlt = d.object(forKey: "mission.alt") as? Double ?? 50
        defaultFrame = d.object(forKey: "mission.frame") as? Int ?? 3
        cruise = d.object(forKey: "mission.cruise") as? Double ?? 15
        if let data = try? Data(contentsOf: Self.draftURL), let dr = try? JSONDecoder().decode(Draft.self, from: data) { items = dr.items; home = dr.home; zones = dr.zones ?? []; rally = dr.rally ?? []; surveys = dr.surveys ?? [] }
        dirty = false; fenceDirty = false; rallyDirty = false
    }

    struct Draft: Codable { var items: [MissionItem]; var home: HomePoint?; var zones: [FenceZone]?; var rally: [RallyPoint]?; var surveys: [SurveyArea]? }
    private func saveDraft() {
        try? FileManager.default.createDirectory(at: Self.draftURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(Draft(items: items, home: home, zones: zones, rally: rally, surveys: surveys)) { try? d.write(to: Self.draftURL) }
    }

    var selectedIndex: Int? { items.firstIndex { $0.id == selected } }

    // MARK: Редагування

    func makeItem(_ cmd: Int, at c: CLLocationCoordinate2D?) -> MissionItem {
        var it = MissionItem(); it.cmd = cmd; it.frame = defaultFrame; it.alt = defaultAlt
        if let c, it.def.loc { it.lat = c.latitude; it.lon = c.longitude }
        switch cmd {
        case 22: it.p1 = 15; it.alt = min(defaultAlt, 30)
        case 21: it.alt = 0
        case 17, 31: it.p3 = 80
        case 18: it.p3 = 80; it.p1 = 1
        case 19: it.p3 = 80; it.p1 = 30
        case 16: it.p2 = 0
        case 178: it.p1 = 1; it.p2 = cruise; it.p3 = -1
        case 206: it.p1 = 20
        default: break
        }
        if !it.def.loc { it.alt = 0 }
        return it
    }
    func add(_ cmd: Int, at c: CLLocationCoordinate2D?, after: Int? = nil) {
        let it = makeItem(cmd, at: c)
        if let i = after ?? selectedIndex, i < items.count { items.insert(it, at: i + 1) } else { items.append(it) }
        selected = it.id
    }
    func remove(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items.remove(at: i)
        selected = items.isEmpty ? nil : items[min(i, items.count - 1)].id
    }
    func duplicate(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        var c = items[i]; c.id = UUID(); c.group = nil
        if c.hasPos { c.lat += 0.0001; c.lon += 0.0001 }
        items.insert(c, at: i + 1); selected = c.id
    }
    func move(_ id: UUID, by d: Int) {
        guard let i = items.firstIndex(where: { $0.id == id }), items.indices.contains(i + d) else { return }
        items.swapAt(i, i + d)
    }
    func update(_ id: UUID, _ f: (inout MissionItem) -> Void) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        var c = items[i]; f(&c); if c != items[i] { items[i] = c }
    }
    func clearLocal() { items = []; withoutRecording { surveys = [] }; selected = nil; selectedSurvey = nil; note = String(localized: "План очищено") }

    // MARK: Розрахунки

    /// Точки маршруту з координатами в порядку виконання (з Home на початку, якщо відомий).
    var routeCoords: [CLLocationCoordinate2D] {
        var r: [CLLocationCoordinate2D] = []
        if let h = home { r.append(.init(latitude: h.lat, longitude: h.lon)) }
        for it in items where it.def.nav && it.hasPos { r.append(it.coord) }
        return r
    }
    /// Ідентифікатори вершин маршруту в тому ж порядку, що й routeCoords (nil = Home).
    var routeIDs: [UUID?] {
        var r: [UUID?] = []
        if home != nil { r.append(nil) }
        for it in items where it.def.nav && it.hasPos { r.append(it.id) }
        return r
    }
    var distance: Double {
        let r = routeCoords; guard r.count > 1 else { return 0 }
        return zip(r, r.dropFirst()).reduce(0) { $0 + CLLocation(latitude: $1.0.latitude, longitude: $1.0.longitude).distance(from: CLLocation(latitude: $1.1.latitude, longitude: $1.1.longitude)) }
    }
    var eta: Double {
        var t = distance / max(cruise, 1)
        for it in items { if it.cmd == 19 || it.cmd == 16 || it.cmd == 21 { t += max(0, it.p1) } }
        return t
    }
    var maxAlt: Double { items.filter { $0.def.loc && $0.cmd != 21 }.map(\.alt).max() ?? 0 }

    var issues: [MissionIssue] {
        var l: [MissionIssue] = []
        guard !items.isEmpty else { return l }
        let navs = items.filter { $0.def.nav }
        if let f = navs.first, f.cmd != 22, f.cmd != 84 { l.append(.init(level: 0, text: String(localized: "Місія починається не зі зльоту: для мультикоптера додайте «Зліт» першою точкою."))) }
        if let last = items.last, ![20, 21, 85].contains(last.cmd), !items.contains(where: { $0.cmd == 17 }) { l.append(.init(level: 0, text: String(localized: "Місія не завершується RTL чи посадкою: апарат зависне в останній точці."))) }
        if items.contains(where: { $0.def.nav && !$0.hasPos }) { l.append(.init(level: 1, text: String(localized: "Є навігаційні точки без координат."))) }
        if let h = home, items.contains(where: { $0.hasPos && CLLocation(latitude: h.lat, longitude: h.lon).distance(from: CLLocation(latitude: $0.lat, longitude: $0.lon)) > 10_000 }) { l.append(.init(level: 1, text: String(localized: "Точка далі ніж за 10 км від Home."))) }
        for (i, it) in items.enumerated() where it.cmd == 177 && (Int(it.p1) < 1 || Int(it.p1) > items.count) { l.append(.init(level: 1, text: String(localized: "Точка \(i + 1): Jump веде на неіснуючу точку \(Int(it.p1))."))) }
        if items.contains(where: { $0.def.nav && $0.cmd != 21 && $0.hasPos && $0.alt <= 0 && $0.frame != 0 }) { l.append(.init(level: 1, text: String(localized: "Є точка з нульовою висотою."))) }
        return l
    }

    // MARK: Обмін з польотником

    @MainActor func readFromVehicle() async {
        busy = String(localized: "Читання місії з польотника…"); error = nil; note = nil
        defer { busy = nil }
        do {
            let d = try await EngineAPI.data("/mission/download")
            let w = try JSONDecoder().decode([WireItem].self, from: d)
            var list: [MissionItem] = []
            for x in w {
                if x.seq == 0 { if x.lat != 0 || x.lon != 0 { home = HomePoint(lat: x.lat, lon: x.lon, alt: x.alt) }; continue }
                list.append(MissionItem(cmd: x.cmd, frame: x.frame, p1: x.p1, p2: x.p2, p3: x.p3, p4: x.p4, lat: x.lat, lon: x.lon, alt: x.alt, auto: x.auto))
            }
            items = list; withoutRecording { surveys = [] }; selected = list.first?.id; dirty = false
            note = list.isEmpty ? "На польотнику немає місії" : String(localized: "Прочитано точок: \(list.count)")
        } catch let e as EngineAPI.APIError { error = e.message } catch let e { error = e.localizedDescription }
    }

    @MainActor func writeToVehicle(homeFallback: HomePoint?) async {
        busy = String(localized: "Запис місії на польотник…"); error = nil; note = nil
        defer { busy = nil }
        let h = home ?? homeFallback ?? HomePoint(lat: 0, lon: 0, alt: 0)
        var w = [WireItem(seq: 0, cmd: 16, frame: 0, p1: 0, p2: 0, p3: 0, p4: 0, lat: h.lat, lon: h.lon, alt: h.alt, auto: true)]
        for (i, it) in items.enumerated() {
            let fr = it.def.loc ? it.frame : 2
            w.append(WireItem(seq: i + 1, cmd: it.cmd, frame: fr, p1: it.p1, p2: it.p2, p3: it.p3, p4: it.p4, lat: it.lat, lon: it.lon, alt: it.alt, auto: it.auto))
        }
        do {
            let body = try JSONEncoder().encode(items.isEmpty ? [] : w)
            try await EngineAPI.send("/mission/upload", body: body)
            dirty = false; note = items.isEmpty ? "Місію на польотнику очищено" : String(localized: "Місію записано: \(items.count) точок")
        } catch let e as EngineAPI.APIError { error = e.message } catch let e { error = e.localizedDescription }
    }

    @MainActor func clearVehicle() async {
        busy = String(localized: "Очищення місії на польотнику…"); error = nil
        defer { busy = nil }
        do { try await EngineAPI.send("/mission/clear"); note = String(localized: "Місію на польотнику очищено") }
        catch let e as EngineAPI.APIError { error = e.message } catch let e { error = e.localizedDescription }
    }

    // MARK: Скасування / повторення

    struct Snap { var items: [MissionItem]; var zones: [FenceZone]; var rally: [RallyPoint]; var home: HomePoint?; var surveys: [SurveyArea] }
    private func rec(_ kind: String, _ s: @autoclosure () -> Snap) {
        guard !restoring else { return }
        let now = Date()
        if kind == lastKind, now.timeIntervalSince(lastRec) < 0.6 { lastRec = now; return }      // серія змін (перетягування, набір тексту) = один крок
        lastKind = kind; lastRec = now
        undoStack.append(s()); if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack.removeAll()
    }
    private var snap: Snap { Snap(items: items, zones: zones, rally: rally, home: home, surveys: surveys) }
    var currentSnap: Snap { snap }
    func recordSnap(_ kind: String, _ s: Snap) { rec(kind, s) }
    func withoutRecording(_ f: () -> Void) { let was = restoring; restoring = true; f(); restoring = was }
    private func restore(_ s: Snap) {
        restoring = true
        items = s.items; zones = s.zones; rally = s.rally; home = s.home; surveys = s.surveys
        restoring = false
        lastKind = ""
        if let sel = selected, !(sel == Self.homeID && home != nil), !items.contains(where: { $0.id == sel }), !zones.contains(where: { $0.pts.contains { $0.id == sel } }), !rally.contains(where: { $0.id == sel }) { selected = nil }
    }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    func undo() {
        guard let s = undoStack.popLast() else { note = String(localized: "Немає що скасовувати"); return }
        redoStack.append(snap); restore(s); note = String(localized: "Скасовано")
    }
    func redo() {
        guard let s = redoStack.popLast() else { note = String(localized: "Немає що повторювати"); return }
        undoStack.append(snap); restore(s); note = String(localized: "Повторено")
    }

    /// Ідентифікатор точки Home у виборі (рядок списку й позначка на карті).
    static let homeID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    // MARK: Копіювання / вставка

    static func coordString(_ lat: Double, _ lon: Double) -> String { Coords.pair(lat, lon, decimals: 7) }
    /// Розпізнає «широта, довгота» у довільному тексті (наприклад, скопійованому з карт).
    static func parseCoords(_ s: String) -> CLLocationCoordinate2D? {
        if let m = Coords.parseMGRS(s) { return .init(latitude: m.0, longitude: m.1) }
        guard let re = try? NSRegularExpression(pattern: #"([-+]?\d{1,3}(?:\.\d+)?)\s*[,; ]\s*([-+]?\d{1,3}(?:\.\d+)?)"#),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let a = Range(m.range(at: 1), in: s), let b = Range(m.range(at: 2), in: s),
              let lat = Double(s[a]), let lon = Double(s[b]), abs(lat) <= 90, abs(lon) <= 180, !(lat == 0 && lon == 0) else { return nil }
        return .init(latitude: lat, longitude: lon)
    }
    /// Координати та назва вибраної точки поточного розділу.
    func selectedPoint() -> (CLLocationCoordinate2D, String)? {
        guard let id = selected else { return nil }
        if id == Self.homeID, let h = home { return (.init(latitude: h.lat, longitude: h.lon), "Home") }
        if let i = items.firstIndex(where: { $0.id == id }), items[i].hasPos { return (items[i].coord, String(localized: "точку \(i + 1)")) }
        if let z = zoneOf(vertex: id), let v = z.pts.first(where: { $0.id == id }) { return (v.coord, "вершину") }
        if let sv = surveyOf(vertex: id), let v = sv.pts.first(where: { $0.id == id }) { return (v.coord, "вершину ділянки") }
        if let r = rally.first(where: { $0.id == id }) { return (.init(latitude: r.lat, longitude: r.lon), "Rally-точку") }
        return nil
    }
    func copySelected() -> Bool {
        guard let (c, what) = selectedPoint() else { return false }
        let s = Self.coordString(c.latitude, c.longitude)
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string)
        clipText = s; clipItem = selected.flatMap { id in items.first { $0.id == id } }
        note = String(localized: "Скопійовано \(what): ") + s
        return true
    }
    func deleteSelected() -> Bool {
        guard let id = selected else { return false }
        if id == Self.homeID, home != nil { home = nil; selected = nil; note = String(localized: "Home у плані видалено"); return true }
        if items.contains(where: { $0.id == id }) { remove(id); return true }
        if zoneOf(vertex: id) != nil { removeVertex(id); return true }
        if surveyOf(vertex: id) != nil { removeSurveyVertex(id); return true }
        if rally.contains(where: { $0.id == id }) { removeRally(id); return true }
        return false
    }
    /// Вставка в точку `at` (позиція курсора на карті; nil = зі зсувом).
    func paste(at: CLLocationCoordinate2D?) -> Bool {
        let s = NSPasteboard.general.string(forType: .string) ?? ""
        if section == .route, let ci = clipItem, s == clipText {
            var c = ci; c.id = UUID(); c.group = nil
            if c.hasPos { if let at { c.lat = at.latitude; c.lon = at.longitude } else { c.lat += 0.0002; c.lon += 0.0002 } }
            if let i = selectedIndex { items.insert(c, at: i + 1) } else { items.append(c) }
            selected = c.id; note = String(localized: "Вставлено точку"); return true
        }
        guard let c = Self.parseCoords(s) else { note = String(localized: "У буфері немає координат («широта, довгота»)"); return false }
        switch section {
        case .route: add(tool < 5000 ? tool : 16, at: c)
        case .fence: addFence(at: c)
        case .rally: addRally(at: c)
        case .survey: addSurveyVertex(at: c)
        }
        note = loc("Додано точку з буфера: ") + Self.coordString(c.latitude, c.longitude); return true
    }

    // MARK: Геозона і Rally

    /// Клік по карті в розділі «Геозона»: додає вершину до вибраного багатокутника або створює нову зону.
    func addFence(at c: CLLocationCoordinate2D) {
        let k = tool >= 5001 && tool <= 5004 ? tool : 5001
        if k == 5003 || k == 5004 {
            let z = FenceZone(kind: k, pts: [GeoPt(lat: c.latitude, lon: c.longitude)], radius: 200)
            zones.append(z); selectedZone = z.id; selected = z.pts[0].id
        } else if let zi = zones.firstIndex(where: { $0.id == selectedZone && !$0.isCircle && $0.kind == k }) {
            let v = GeoPt(lat: c.latitude, lon: c.longitude)
            zones[zi].pts.append(v); selected = v.id
        } else {
            let z = FenceZone(kind: k, pts: [GeoPt(lat: c.latitude, lon: c.longitude)])
            zones.append(z); selectedZone = z.id; selected = z.pts[0].id
        }
    }
    func addRally(at c: CLLocationCoordinate2D) { let r = RallyPoint(lat: c.latitude, lon: c.longitude, alt: defaultAlt); rally.append(r); selected = r.id }
    func zoneOf(vertex id: UUID) -> FenceZone? { zones.first { $0.pts.contains { $0.id == id } } }

    /// Переміщення будь-якої редагованої точки (маршрут, вершина геозони, Rally).
    func moveAny(_ id: UUID, to c: CLLocationCoordinate2D) {
        if id == Self.homeID, let h = home { home = HomePoint(lat: c.latitude, lon: c.longitude, alt: h.alt); return }
        if items.contains(where: { $0.id == id }) { update(id) { $0.lat = c.latitude; $0.lon = c.longitude }; return }
        for zi in zones.indices { if let vi = zones[zi].pts.firstIndex(where: { $0.id == id }) { zones[zi].pts[vi].lat = c.latitude; zones[zi].pts[vi].lon = c.longitude; return } }
        if let sv = surveyOf(vertex: id) { mutateSurvey(sv.id) { if let j = $0.pts.firstIndex(where: { $0.id == id }) { $0.pts[j].lat = c.latitude; $0.pts[j].lon = c.longitude } }; return }
        if let ri = rally.firstIndex(where: { $0.id == id }) { rally[ri].lat = c.latitude; rally[ri].lon = c.longitude }
    }
    func removeVertex(_ id: UUID) {
        for zi in zones.indices { if let vi = zones[zi].pts.firstIndex(where: { $0.id == id }) {
            zones[zi].pts.remove(at: vi)
            if zones[zi].pts.isEmpty { zones.remove(at: zi); selectedZone = nil }
            selected = nil; return } }
    }
    func removeZone(_ id: UUID) { zones.removeAll { $0.id == id }; if selectedZone == id { selectedZone = nil }; selected = nil }
    func removeRally(_ id: UUID) { rally.removeAll { $0.id == id }; if selected == id { selected = nil } }

    var fenceIssues: [MissionIssue] {
        var l: [MissionIssue] = []
        for (i, z) in zones.enumerated() where !z.isCircle && z.pts.count < 3 { l.append(.init(level: 1, text: String(localized: "Зона \(i + 1): для багатокутника потрібні щонайменше 3 вершини."))) }
        if zones.contains(where: { $0.isCircle && $0.radius < 5 }) { l.append(.init(level: 1, text: String(localized: "Є коло з радіусом менше 5 м."))) }
        if !zones.isEmpty && !zones.contains(where: { !$0.exclusion }) { l.append(.init(level: 0, text: String(localized: "Є лише заборонені зони: дозволеної області не задано."))) }
        if !zones.isEmpty { l.append(.init(level: 0, text: String(localized: "Щоб геозона діяла, увімкніть FENCE_ENABLE і потрібні типи в FENCE_TYPE."))) }
        return l
    }

    @MainActor func readExtra(_ type: Int) async {
        busy = type == 1 ? "Читання геозони…" : "Читання Rally-точок…"; error = nil; note = nil
        defer { busy = nil }
        do {
            let d = try await EngineAPI.data("/mission/download?type=\(type)")
            let w = try JSONDecoder().decode([WireItem].self, from: d)
            if type == 1 {
                var zs: [FenceZone] = []; var i = 0
                while i < w.count {
                    let x = w[i]
                    switch x.cmd {
                    case 5001, 5002:
                        let n = max(1, Int(x.p1)); let sl = w[i..<min(i + n, w.count)]
                        zs.append(FenceZone(kind: x.cmd, pts: sl.map { GeoPt(lat: $0.lat, lon: $0.lon) })); i += n
                    case 5003, 5004: zs.append(FenceZone(kind: x.cmd, pts: [GeoPt(lat: x.lat, lon: x.lon)], radius: x.p1)); i += 1
                    default: i += 1
                    }
                }
                zones = zs; fenceDirty = false; selectedZone = zs.first?.id
                note = zs.isEmpty ? "На польотнику немає геозони" : String(localized: "Прочитано зон: \(zs.count)")
            } else {
                rally = w.filter { $0.cmd == 5100 }.map { RallyPoint(lat: $0.lat, lon: $0.lon, alt: $0.alt) }; rallyDirty = false
                note = rally.isEmpty ? "На польотнику немає Rally-точок" : String(localized: "Прочитано Rally-точок: \(rally.count)")
            }
        } catch let e as EngineAPI.APIError { error = e.message } catch let e { error = e.localizedDescription }
    }

    @MainActor func writeExtra(_ type: Int) async {
        busy = type == 1 ? "Запис геозони…" : "Запис Rally-точок…"; error = nil; note = nil
        defer { busy = nil }
        var w: [WireItem] = []
        if type == 1 {
            for z in zones {
                if z.isCircle, let p = z.pts.first { w.append(WireItem(seq: w.count, cmd: z.kind, frame: 0, p1: z.radius, p2: 0, p3: 0, p4: 0, lat: p.lat, lon: p.lon, alt: 0, auto: true)) }
                else { for p in z.pts { w.append(WireItem(seq: w.count, cmd: z.kind, frame: 0, p1: Double(z.pts.count), p2: 0, p3: 0, p4: 0, lat: p.lat, lon: p.lon, alt: 0, auto: true)) } }
            }
        } else {
            for r in rally { w.append(WireItem(seq: w.count, cmd: 5100, frame: 3, p1: 0, p2: 0, p3: 0, p4: 0, lat: r.lat, lon: r.lon, alt: r.alt, auto: true)) }
        }
        do {
            try await EngineAPI.send("/mission/upload?type=\(type)", body: try JSONEncoder().encode(w))
            if type == 1 { fenceDirty = false; note = w.isEmpty ? "Геозону на польотнику очищено" : "Геозону записано" } else { rallyDirty = false; note = w.isEmpty ? "Rally-точки очищено" : String(localized: "Rally-точки записано: \(w.count)") }
        } catch let e as EngineAPI.APIError { error = e.message } catch let e { error = e.localizedDescription }
    }

    // MARK: Файли (.waypoints, QGC WPL 110)

    func exportText() -> String {
        var s = "QGC WPL 110\n"
        let h = home ?? HomePoint(lat: 0, lon: 0, alt: 0)
        func f(_ v: Double, _ p: Int = 8) -> String { String(format: "%.\(p)f", v) }
        s += "0\t1\t0\t16\t0\t0\t0\t0\t\(f(h.lat))\t\(f(h.lon))\t\(f(h.alt, 6))\t1\n"
        for (i, it) in items.enumerated() {
            s += "\(i + 1)\t0\t\(it.def.loc ? it.frame : 2)\t\(it.cmd)\t\(f(it.p1, 6))\t\(f(it.p2, 6))\t\(f(it.p3, 6))\t\(f(it.p4, 6))\t\(f(it.lat))\t\(f(it.lon))\t\(f(it.alt, 6))\t\(it.auto ? 1 : 0)\n"
        }
        return s
    }
    @discardableResult
    func importText(_ text: String) -> Bool {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        guard let first = lines.first, first.hasPrefix("QGC WPL") else { error = String(localized: "Це не файл .waypoints (очікується заголовок QGC WPL)"); return false }
        var list: [MissionItem] = []; var h: HomePoint?
        for l in lines.dropFirst() {
            let c = l.split(whereSeparator: { $0 == "\t" || $0 == " " }).map(String.init)
            guard c.count >= 12, let seq = Int(c[0]), let cmd = Int(c[3]), let fr = Int(c[2]) else { continue }
            let v = c[4...10].map { Double($0) ?? 0 }
            if seq == 0 { h = HomePoint(lat: v[4], lon: v[5], alt: v[6]); continue }
            list.append(MissionItem(cmd: cmd, frame: fr == 2 ? defaultFrame : fr, p1: v[0], p2: v[1], p3: v[2], p4: v[3], lat: v[4], lon: v[5], alt: v[6], auto: c[11] != "0"))
        }
        items = list; withoutRecording { surveys = [] }; if let h, h.lat != 0 || h.lon != 0 { home = h }
        selected = list.first?.id; error = nil; note = String(localized: "Імпортовано точок: \(list.count)")
        return true
    }
}
