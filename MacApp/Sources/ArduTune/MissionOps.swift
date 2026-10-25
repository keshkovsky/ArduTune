import SwiftUI
import MapKit
import AppKit

/// Спільні дії та меню для карт Mission і Flight Data: політ до точки, перехід між точками місії, POI.
struct MissionOps {
    let s: Store
    var m: MissionStore { s.mission }

    var sim: MissionSim { m.sim }
    /// Чи діє симуляція: тоді команди йдуть у віртуальний апарат, а не на польотник.
    var simOn: Bool { sim.active }
    var canCmd: Bool { s.connected || simOn }

    func modeNum(_ name: String) -> Int? { s.ps.options("FLTMODE1").first { $0.1.lowercased() == name.lowercased() }?.0 }

    func flyHere(_ c: CLLocationCoordinate2D, alt altIn: Double? = nil) {
        if simOn { sim.goTo(c, alt: altIn, loiter: false); return }
        guard let g = modeNum("Guided") else { return }
        let alt = altIn ?? (s.t.altRel > 2 ? s.t.altRel : m.defaultAlt)
        EngineAPI.post("/cmd/mode?m=\(g)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { EngineAPI.post("/cmd/goto?lat=\(c.latitude)&lon=\(c.longitude)&alt=\(alt)") }
    }

    /// Летіти до точки в Guided і після прибуття перейти в Loiter.
    func flyAndLoiter(_ c: CLLocationCoordinate2D, alt: Double?) {
        if simOn { sim.goTo(c, alt: alt, loiter: true); return }
        guard let loiter = modeNum("Loiter"), modeNum("Guided") != nil else { m.note = String(localized: "Режими Guided/Loiter недоступні для цього апарата"); return }
        m.followTask?.cancel()
        flyHere(c, alt: alt)
        let v = s.ps.metaVehicle ?? ""
        let radius: Double = (v == "FIXED_WING" || v.hasPrefix("VTOL")) ? 90 : 12
        m.following = String(localized: "Лечу до точки, потім Loiter")
        let store = s, m = self.m
        m.followTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            let start = Date()
            while !Task.isCancelled, Date().timeIntervalSince(start) < 1800 {
                guard store.connected else { m.note = String(localized: "Слідування перервано: немає зв'язку"); break }
                if (store.t.mode ?? "").lowercased() != "guided" { m.note = String(localized: "Слідування скасовано: режим змінено"); break }
                let d = CLLocation(latitude: store.t.lat, longitude: store.t.lon).distance(from: CLLocation(latitude: c.latitude, longitude: c.longitude))
                m.following = String(format: loc("Лечу до точки: %.0f м, потім Loiter"), d)
                if d < radius { EngineAPI.post("/cmd/mode?m=\(loiter)"); m.note = String(localized: "Прибув у точку: перехід у Loiter"); break }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            m.following = nil
        }
    }

    func copy(_ c: CLLocationCoordinate2D) {
        let t = MissionStore.coordString(c.latitude, c.longitude)
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(t, forType: .string)
        m.note = loc("Скопійовано: ") + t
    }
    func startMission() { if simOn { sim.auto(from: nil); return }; if let a = modeNum("Auto") { EngineAPI.post("/cmd/mode?m=\(a)") } }
    func step(_ d: Int) { if simOn { sim.step(d, count: m.items.count); return }; EngineAPI.post("/mission/current?seq=\(max(1, s.t.wpSeq + d))") }

    /// Чи збігається план із тим, що на польотнику (дозволяє перемикати поточну точку).
    var synced: Bool { simOn || s.connected && !m.dirty && !m.items.isEmpty }

    // MARK: Меню точки

    /// Меню правої кнопки по точці. editable = Mission (редагування), інакше Flight Data (лише дії).
    func pinMenu(id: UUID, view: NSView, event: NSEvent, editable: Bool, openInMission: (() -> Void)? = nil) {
        m.selected = id
        var coord: CLLocationCoordinate2D?; var title = "Точка"; var kind = 0      // 0 маршрут, 1 вершина геозони, 2 Rally
        var alt: Double?
        if id == MissionStore.homeID, let h = m.home { coord = .init(latitude: h.lat, longitude: h.lon); title = "Home" }
        else if let i = m.items.firstIndex(where: { $0.id == id }) {
            let it = m.items[i]; coord = it.coord; title = String(localized: "Точка \(i + 1): ") + it.def.name
            if it.hasPos, it.frame == 3, it.alt > 0 { alt = it.alt }
        } else if editable, let sv = m.surveyOf(vertex: id), let v = sv.pts.first(where: { $0.id == id }) { coord = v.coord; kind = 3; title = "Вершина ділянки" }
        else if editable, let z = m.zoneOf(vertex: id), let v = z.pts.first(where: { $0.id == id }) { coord = v.coord; kind = 1; title = z.isCircle ? "Центр кола" : "Вершина зони" }
        else if editable, let i = m.rally.firstIndex(where: { $0.id == id }) { coord = .init(latitude: m.rally[i].lat, longitude: m.rally[i].lon); kind = 2; title = String(localized: "Rally-точка \(i + 1)") }
        guard let c = coord else { return }
        let mb = MenuBuilder()
        mb.header(title)
        mb.separator()
        let on = canCmd
        mb.item("Летіти до точки (Guided)", enabled: on, soon: false, symbol: "location.fill") { flyHere(c, alt: alt) }
        mb.item("Летіти до точки й зависнути (Loiter)", enabled: on, soon: false, symbol: "location.circle") { flyAndLoiter(c, alt: alt) }
        if m.following != nil { mb.item("Скасувати слідування", symbol: "xmark.circle") { m.followTask?.cancel(); m.following = nil } }
        if kind == 0 { mb.item("Зробити поточною точкою місії", enabled: synced, soon: false, symbol: "flag.checkered") { if let i = m.items.firstIndex(where: { $0.id == id }) { if simOn { sim.auto(from: i) } else { EngineAPI.post("/mission/current?seq=\(i + 1)") } } } }
        mb.separator()
        mb.item("Копіювати координати", symbol: "doc.on.doc") { copy(c) }
        mb.item("Виміряти відстань до…", symbol: "ruler") { m.ruler.start(at: c) }
        if editable {
            if kind == 0 { mb.item("Дублювати точку", symbol: "plus.square.on.square") { m.duplicate(id) } }
            mb.separator()
            mb.item("Видалити точку", symbol: "trash") { switch kind { case 1: m.removeVertex(id); case 2: m.removeRally(id); case 3: m.removeSurveyVertex(id); default: m.remove(id) } }
        } else if let openInMission {
            mb.separator()
            mb.item("Редагувати в Mission", symbol: "map") { openInMission() }
        }
        mb.show(for: view, event: event)
    }

    // MARK: Меню місії для карти Flight Data

    func missionSubmenu(_ mb: MenuBuilder, showRoute: Bool, toggleRoute: @escaping () -> Void, openMission: @escaping () -> Void) {
        mb.submenu("Місія", symbol: "flag.checkered") { sub in
            mb.item("Показувати маршрут місії", checked: showRoute, to: sub) { toggleRoute() }
            mb.separator(sub)
            mb.item("Старт місії (Auto)", enabled: canCmd, soon: false, symbol: "play.fill", to: sub) { startMission() }
            mb.item("Наступна точка", enabled: canCmd, soon: false, symbol: "forward.end.fill", to: sub) { step(1) }
            mb.item("Попередня точка", enabled: canCmd, soon: false, symbol: "backward.end.fill", to: sub) { step(-1) }
            mb.separator(sub)
            mb.item("Відкрити в Mission", symbol: "map", to: sub) { openMission() }
        }
    }

    // MARK: POI

    func nearestPOI(_ c: CLLocationCoordinate2D) -> Int? {
        s.poi.items.enumerated().min { hypot($0.element.lat - c.latitude, $0.element.lon - c.longitude) < hypot($1.element.lat - c.latitude, $1.element.lon - c.longitude) }?.offset
    }
    func poiMenu(_ mb: MenuBuilder, at c: CLLocationCoordinate2D, jump: @escaping (POI) -> Void) {
        mb.submenu("POI", symbol: "mappin.and.ellipse") { sub in
            mb.item("Додати POI тут…", symbol: "plus", to: sub) {
                if let r = Prompt.ask("Новий POI", message: MissionStore.coordString(c.latitude, c.longitude), fields: [("Назва", "POI \(s.poi.items.count + 1)")]), !r[0].isEmpty {
                    s.poi.items.append(POI(name: r[0], lat: c.latitude, lon: c.longitude)); m.note = String(localized: "POI «\(r[0])» додано")
                }
            }
            if !s.poi.items.isEmpty {
                mb.submenu("Перейти до POI", to: sub) { j in for p in s.poi.items { mb.item(p.name, to: j) { jump(p) } } }
                mb.separator(sub)
                mb.item("Видалити найближчий POI", to: sub) { if let i = nearestPOI(c) { m.note = String(localized: "POI «\(s.poi.items[i].name)» видалено"); s.poi.items.remove(at: i) } }
                mb.item("Очистити всі POI", to: sub) { s.poi.items.removeAll(); m.note = String(localized: "POI очищено") }
            }
        }
    }
}
