import SwiftUI
import MapKit
import Charts
import AppKit
import UniformTypeIdentifiers

// MARK: - Сторінка Mission

struct MissionPage: View {
    @Environment(Store.self) var s
    @State private var ctl = MapController()
    @State private var opt = MapOptions()
    @State private var topH: CGFloat = 52
    @AppStorage("mission.gcs.open") private var gcsOpen = true
    private var front: FrontLine { FrontLine.shared }

    var body: some View {
        let m = s.mission
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                Group {
                    if m.view3D { Mission3DPane(m: m, layer: opt.layer, topInset: topH).background(PlanKeyMonitor { e in handleKey(e, cursor: nil) }) }
                    else { MissionMapHost(ctl: ctl, opt: opt, onContext: showMenu, onPinContext: showPinMenu, onKey: handleKey) }
                }
                    .overlay(alignment: .top) {
                        // інструменти і стрічка телеметрії: в один ряд, а якщо карта вузька, то один під одним (без накладання)
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .top, spacing: 12) {
                                MissionToolbar(m: m, opt: opt).blockMap()
                                Spacer(minLength: 8)
                                MissionTelemetryStrip().blockMap().padding(8)
                            }
                            VStack(alignment: .leading, spacing: 0) {
                                MissionToolbar(m: m, opt: opt).blockMap()
                                MissionTelemetryStrip().blockMap().padding(.leading, 8)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.trailing, m.view3D ? 92 : 0)         // у 3D кут справа зайнятий компасом
                        .background(GeometryReader { g in Color.clear.preference(key: TopInsetKey.self, value: g.size.height) })
                    }
                    .onPreferenceChange(TopInsetKey.self) { topH = $0 }
                    .overlay(alignment: .trailing) { if !m.view3D { MapControls(ctl: ctl).blockMap().padding(.trailing, 10) } }
                    .overlay(alignment: .bottomLeading) { MissionControlPanel(open: $gcsOpen, ctl: ctl).blockMap().padding(10) }
                    .overlay(alignment: .top) {
                        if let f = m.following {
                            HStack(spacing: 8) {
                                Image(systemName: "location.fill")
                                Text(LocalizedStringKey(f)).font(.caption.weight(.medium))
                                Button("Скасувати") { m.followTask?.cancel(); m.following = nil }.controlSize(.mini)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 5)
                            .background(Color(nsColor: .windowBackgroundColor).opacity(0.92), in: Capsule()).blockMap().padding(.top, 52)
                        }
                    }
                    .overlay(alignment: .bottom) {
                        if m.sim.enabled { MissionSimPanel(sim: m.sim, m: m).blockMap().padding(.bottom, 10) }
                    }
                    .overlay(alignment: .bottom) {
                        if m.addMode && !m.sim.enabled && !m.view3D {
                            Label("Клік по карті додає: \(MissionToolbar.name(m.tool))", systemImage: "plus.circle.fill")
                                .font(.caption).padding(.horizontal, 10).padding(.vertical, 4)
                                .background(Color.accentColor.opacity(0.9), in: Capsule()).foregroundStyle(.white).blockMap().padding(.bottom, 8)
                        }
                    }
                    .overlay(alignment: .bottomTrailing) { RulerPanel(ruler: m.ruler).blockMap().padding(10) }
                    .onDisappear { m.sim.close(); m.ruler.active = false }
                    .onChange(of: s.armed) { _, armed in if armed { m.sim.close() } }
                    .coordinateSpace(name: "mapArea")
                    .onPreferenceChange(BlockRectsKey.self) { m.blocked = $0 }
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .padding([.top, .leading, .trailing], 8)
                MissionProfile(m: m).frame(height: 116).padding(.horizontal, 8).padding(.vertical, 6)
            }
            Divider()
            MissionInspector(m: m).frame(width: 350)
        }
        .task(id: opt.front) {
            guard opt.front else { return }
            while !Task.isCancelled { await front.refresh(); try? await Task.sleep(nanoseconds: 600_000_000_000) }
        }
    }

    // MARK: Меню правої кнопки

    func showMenu(at c: CLLocationCoordinate2D, view: NSView, event: NSEvent) {
        let m = s.mission
        let ops = MissionOps(s: s)
        let mb = MenuBuilder()
        // 1. що додати в поточному розділі
        switch m.section {
        case .route:
            let quick = [16, 22, 21, 17, 201]
            for id in quick { mb.item(loc("Додати: ") + MissionCatalog.find(id).name, symbol: MissionCatalog.badge(id).0) { m.add(id, at: c) } }
            mb.submenu("Інші команди", symbol: "ellipsis.circle") { sub in
                for g in MissionCatalog.groups { for cmd in g.1 where cmd.loc && !quick.contains(cmd.id) { mb.item(cmd.name, symbol: MissionCatalog.badge(cmd.id).0, to: sub) { m.add(cmd.id, at: c) } } }
            }
        case .fence:
            for k in [5001, 5002, 5003, 5004] { mb.item(loc("Додати зону: ") + MissionToolbar.name(k), symbol: MissionCatalog.badge(k).0) { m.tool = k; m.addFence(at: c) } }
            if m.selectedZone != nil { mb.item("Завершити зону, почати нову", symbol: "checkmark.circle") { m.selectedZone = nil } }
        case .rally:
            mb.item("Додати Rally-точку", symbol: "lifepreserver.fill") { m.addRally(at: c) }
        case .survey:
            mb.item("Додати вершину ділянки", symbol: "square.grid.3x3") { m.tool = 5200; m.addSurveyVertex(at: c) }
            if m.selectedSurvey != nil { mb.item("Завершити ділянку, почати нову", symbol: "checkmark.circle") { m.selectedSurvey = nil } }
        }
        let hasClip = MissionStore.parseCoords(NSPasteboard.general.string(forType: .string) ?? "") != nil
        mb.item("Додати точку з буфера (координати)", enabled: hasClip, soon: false, symbol: "doc.on.clipboard") { _ = m.paste(at: c) }
        // 2. керування апаратом
        mb.separator()
        mb.item("Летіти сюди (Guided)", enabled: ops.canCmd, soon: false, symbol: "location.fill") { ops.flyHere(c) }
        mb.item("Летіти сюди й зависнути (Loiter)", enabled: ops.canCmd, soon: false, symbol: "location.circle") { ops.flyAndLoiter(c, alt: nil) }
        // 3. POI і Home
        mb.separator()
        ops.poiMenu(mb, at: c) { p in ctl.center(.init(latitude: p.lat, longitude: p.lon), distance: 400) }
        mb.item("Поставити Home у плані тут", symbol: "house.circle") { m.home = HomePoint(lat: c.latitude, lon: c.longitude, alt: m.home?.alt ?? 0) }
        mb.item("Копіювати координати тут", symbol: "doc.on.doc") { ops.copy(c) }
        mb.item("Виміряти відстань до…", symbol: "ruler") { m.ruler.start(at: c) }
        // 4. вигляд карти
        mb.separator()
        mb.submenu("Шар карти", symbol: "square.3.layers.3d") { sub in
            for g in MapLayer.groups {
                for l in g.1 { mb.item(l.title, checked: opt.layer == l, to: sub) { opt.layer = l } }
                if g.0 != MapLayer.groups.last!.0 { mb.separator(sub) }
            }
            mb.separator(sub)
            mb.item("Лінія фронту (DeepState)", checked: opt.front, to: sub) { opt.front.toggle() }
            mb.item("Напрямки борту: компас · GPS · гіро", checked: opt.rays, to: sub) { opt.rays.toggle() }
        }
        mb.submenu("Обертання карти", symbol: "rotate.right") { sub in
            mb.item("Північ угору", to: sub) { ctl.setHeading(0) }
            mb.item("Повернути на 90° ↺", to: sub) { ctl.rotate(by: 90) }
            mb.item("Повернути на 90° ↻", to: sub) { ctl.rotate(by: -90) }
        }
        mb.item("Центрувати на апараті", enabled: s.t.gpsFix >= 3, soon: false, symbol: "scope") { ctl.center(.init(latitude: s.t.lat, longitude: s.t.lon), distance: 800) }
        mb.show(for: view, event: event)
    }

    /// Гарячі клавіші плану: ⌘Z / ⇧⌘Z, ⌘C / ⌘X / ⌘V, Delete.
    func handleKey(_ e: NSEvent, cursor: CLLocationCoordinate2D?) -> Bool {
        let m = s.mission
        let f = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = e.charactersIgnoringModifiers?.lowercased() ?? ""
        if f == .command {
            switch key {
            case "z": m.undo(); return true
            case "c": return m.copySelected()
            case "x": if m.copySelected() { _ = m.deleteSelected(); return true }; return false
            case "v": return m.paste(at: cursor)
            default: return false
            }
        }
        if f == [.command, .shift], key == "z" { m.redo(); return true }
        if f.isEmpty, let a = HotKeys.shared.action(for: e, scope: .mission), !m.view3D {
            switch a.id {
            case "ms.select": m.ruler.active = false; m.addMode = false; m.ruler.clear(); return true
            case "ms.add": m.ruler.active = false; m.addMode = true; m.ruler.clear(); return true
            case "ms.ruler": m.ruler.active = true; m.addMode = false; return true
            default: break
            }
        }
        if f.isEmpty, e.keyCode == 53, m.addMode, !(m.ruler.active || m.ruler.a != nil) { m.addMode = false; return true }   // Esc у «Додаванні» повертає у «Вибір»
        if f.isEmpty, e.keyCode == 53, m.ruler.active || m.ruler.a != nil { m.ruler.active = false; m.ruler.clear(); return true }   // Esc закриває лінійку
        if f.isEmpty, e.keyCode == 51 || e.keyCode == 117 { return m.deleteSelected() }       // Backspace / Delete
        return false
    }

    func showPinMenu(id: UUID, view: NSView, event: NSEvent) { MissionOps(s: s).pinMenu(id: id, view: view, event: event, editable: true) }
}

struct BlockRectsKey: PreferenceKey {
    static let defaultValue: [CGRect] = []
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) { value += nextValue() }
}
extension View {
    /// Позначає плаваючий елемент над картою: кліки по ньому не мають потрапляти на карту.
    func blockMap() -> some View {
        background(GeometryReader { g in Color.clear.preference(key: BlockRectsKey.self, value: [g.frame(in: .named("mapArea"))]) })
    }
}

// MARK: - Карта (читає телеметрію, ізольовано від решти сторінки)

struct MissionMapHost: View {
    @Environment(Store.self) var s
    let ctl: MapController
    let opt: MapOptions
    var onContext: (CLLocationCoordinate2D, NSView, NSEvent) -> Void
    var onPinContext: (UUID, NSView, NSEvent) -> Void
    var onKey: (NSEvent, CLLocationCoordinate2D?) -> Bool
    nonisolated(unsafe) static var lastDrag = 0.0
    private var front: FrontLine { FrontLine.shared }

    static func makeWPs(_ m: MissionStore) -> [MissionMap.WP] {
        // точки, згенеровані ділянкою, показуємо дрібними крапками без номерів (cmd 5201)
        func routePins() -> [MissionMap.WP] {
            m.items.enumerated().compactMap { i, it in
                guard it.hasPos else { return nil }
                if it.group != nil { return MissionMap.WP(id: it.id, lat: it.lat, lon: it.lon, label: "", cmd: 5201, radius: 0) }
                return MissionMap.WP(id: it.id, lat: it.lat, lon: it.lon, label: String(i + 1), cmd: it.cmd, radius: it.loiterRadius ?? 0)
            }
        }
        switch m.section {
        case .route: return routePins()
        case .survey:
            var r = routePins().filter { $0.cmd == 5201 }
            for sv in m.surveys { for (i, p) in sv.pts.enumerated() { r.append(MissionMap.WP(id: p.id, lat: p.lat, lon: p.lon, label: String(i + 1), cmd: 5200, radius: 0)) } }
            return r
        case .fence:
            var r: [MissionMap.WP] = []
            for z in m.zones { for (i, p) in z.pts.enumerated() { r.append(MissionMap.WP(id: p.id, lat: p.lat, lon: p.lon, label: z.isCircle ? "◎" : String(i + 1), cmd: z.kind, radius: 0)) } }
            return r
        case .rally:
            return m.rally.enumerated().map { i, r in MissionMap.WP(id: r.id, lat: r.lat, lon: r.lon, label: "R\(i + 1)", cmd: 5100, radius: 0) }
        }
    }

    var body: some View {
        let m = s.mission
        let fix = s.t.gpsFix >= 3
        let realSeq = s.connected && !m.dirty ? s.t.wpSeq : 0       // номер поточної точки має сенс, лише коли план збігається з польотником
        let simCur = m.sim.current
        let seq = simCur.map { $0.item + 1 } ?? realSeq
        let curItem = (seq >= 1 && seq <= m.items.count) ? m.items[seq - 1] : nil
        let reached = seq >= 2 ? Set(m.items.prefix(seq - 1).map(\.id)) : []
        let wps = Self.makeWPs(m)
        let zones = m.zones.map { MissionMap.ZoneVis(id: $0.id, kind: $0.kind, pts: $0.pts.map { [$0.lat, $0.lon] }, radius: $0.radius) }
            + m.surveys.map { MissionMap.ZoneVis(id: $0.id, kind: 5200, pts: $0.pts.map { [$0.lat, $0.lon] }, radius: 0) }
        let home: CLLocationCoordinate2D? = m.home.map { .init(latitude: $0.lat, longitude: $0.lon) } ?? (s.t.homeSet ? .init(latitude: s.t.homeLat, longitude: s.t.homeLon) : nil)
        MissionMap(
            ctl: ctl, layer: opt.layer, zones: zones, pois: s.poi.items, wps: wps, path: m.routeCoords, pathIDs: m.routeIDs, dimPath: m.section == .fence || m.section == .rally, blocked: { m.blocked }, home: home, homeEditable: m.home != nil,
            vehicle: simCur.map { m.sim.coord($0) } ?? (fix ? .init(latitude: s.t.lat, longitude: s.t.lon) : nil), vehicleHeading: simCur != nil ? m.sim.headingDeg : s.t.heading,
            rays: simCur != nil ? nil : (fix ? RayData.current(yaw: s.t.yaw, magHdg: s.t.magHdg, cog: s.t.cog, speed: s.t.groundSpeed, rays: opt.rays) : nil),
            rulerA: m.ruler.a, rulerB: m.ruler.b, rulerLabel: m.ruler.result.map { RulerLayer.distanceText($0.distance) + "  ·  " + String(format: "%03.0f°", $0.trueAz) } ?? "",
            onRulerDrag: { i, c, done in m.ruler.drag(i, c, done: done) },
            selected: m.selected, currentID: m.section == .route ? curItem?.id : nil, reachedIDs: m.section == .route ? reached : [],
            front: opt.front ? front.polys : [], frontVersion: opt.front ? front.version : 0, simTrack: m.sim.track, simVer: m.sim.version, simDanger: m.sim.enabled ? m.sim.dangerSegs : [],
            onSelect: { id in
                m.selected = id
                if let id, let z = m.zoneOf(vertex: id) { m.selectedZone = z.id }
            },
            onMove: { id, c, final in
                // під час перетягування оновлюємо план не частіше ~15 разів на секунду
                let now = Date().timeIntervalSinceReferenceDate
                if final || now - MissionMapHost.lastDrag > 0.07 {
                    MissionMapHost.lastDrag = now
                    m.moveAny(id, to: c)
                }
                m.selected = id
            },
            onClick: { c, empty in
                if m.ruler.capturesClick { m.ruler.place(c); return }
                guard empty else { return }
                if m.addMode {
                    switch m.section { case .route: m.add(m.tool, at: c); case .fence: m.addFence(at: c); case .rally: m.addRally(at: c); case .survey: m.addSurveyVertex(at: c) }
                } else { m.selected = nil }
            },
            onContext: onContext, onPinContext: onPinContext, onKey: onKey)
    }
}

// MARK: - Панель інструментів на карті

struct MissionToolbar: View {
    @Bindable var m: MissionStore
    @Bindable var opt: MapOptions
    static func tools(_ s: MissionSection) -> [Int] { s == .route ? [16, 22, 21, 17, 201] : s == .fence ? [5001, 5002, 5003, 5004] : s == .survey ? [5200] : [5100] }
    static func name(_ id: Int) -> String {
        [5001: "багатокутник, дозволена зона", 5002: "багатокутник, заборонена зона", 5003: "коло, дозволена зона", 5004: "коло, заборонена зона", 5100: "Rally-точка", 5200: "межі ділянки обліту"][id] ?? MissionCatalog.find(id).name
    }
    static func icon(_ id: Int) -> String { id >= 5001 ? MissionCatalog.badge(id).0 : MissionCatalog.find(id).icon }

    var body: some View {
        // у вузькому вікні панель переходить на компактний вигляд (іконки замість підписів), а кнопка 3D завжди лишається цілою
        ViewThatFits(in: .horizontal) {
            row(compact: false)
            row(compact: true)
        }
        .font(.caption)
        .padding(8)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.94), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
        .transaction { $0.animation = nil }
        .padding(8)
    }

    /// Піктограма режиму інструмента з підказкою при наведенні.
    func modeButton(_ icon: String, _ help: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 13, weight: .semibold))
                .foregroundStyle(on ? Color.white : Color.primary)
                .frame(width: 30, height: 24)
                .background(on ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain).help(LocalizedStringKey(help))
    }

    func row(compact: Bool) -> some View {
        HStack(spacing: 8) {
            if !m.view3D {     // у 3D ці інструменти не діють: не займають місце
                HStack(spacing: 2) {
                    modeButton("hand.point.up.left.fill", "Вибір", on: !m.ruler.active && !m.addMode) { m.ruler.active = false; m.addMode = false; m.ruler.clear() }
                    modeButton("plus.circle", "Додавання", on: m.addMode) { m.ruler.active = false; m.addMode = true; m.ruler.clear() }
                    modeButton("ruler", "Лінійка", on: m.ruler.active) { m.ruler.active = true; m.addMode = false }
                }
                Menu {
                    ForEach(Self.tools(m.section), id: \.self) { id in
                        Button { m.tool = id; m.addMode = true } label: { Label(lk(Self.name(id).prefix(1).uppercased() + Self.name(id).dropFirst()), systemImage: Self.icon(id)) }
                    }
                } label: { Image(systemName: Self.icon(m.tool)) }
                    .menuStyle(.borderlessButton).fixedSize().help("Що додає клік по карті: \(Self.name(m.tool))")
                Divider().frame(height: 16)
                HStack(spacing: 3) {
                    Image(systemName: "arrow.up.to.line").foregroundStyle(.secondary)
                    TextField("", value: $m.defaultAlt, format: .number).textFieldStyle(.roundedBorder).frame(width: compact ? 46 : 52).multilineTextAlignment(.trailing)
                    if !compact { Text("м").foregroundStyle(.secondary) }
                }.help("Висота нових точок, м")
            }
            HStack(spacing: 2) {
                Button { m.undo() } label: { Image(systemName: "arrow.uturn.backward") }.help("Скасувати (⌘Z)")
                Button { m.redo() } label: { Image(systemName: "arrow.uturn.forward") }.help("Повторити (⇧⌘Z)")
            }.buttonStyle(.borderless)
            Menu {
                ForEach(MapLayer.groups, id: \.0) { g in
                    Section(lk(g.0)) { ForEach(g.1) { l in Button { opt.layer = l } label: { if opt.layer == l { Label(LocalizedStringKey(l.title), systemImage: "checkmark") } else { Text(LocalizedStringKey(l.title)) } } } }
                }
                Divider()
                Toggle("Лінія фронту (DeepState)", isOn: $opt.front)
                Toggle("Напрямки борту: компас · GPS · гіро", isOn: $opt.rays)
            } label: { Image(systemName: "square.3.layers.3d") }.menuStyle(.borderlessButton).fixedSize().help("Шар карти (у 3D це текстура рельєфу)")
            Divider().frame(height: 16)
            Toggle(isOn: $m.view3D) { Label("3D", systemImage: "cube") }.toggleStyle(.button).controlSize(.small).fixedSize()
                .help("Тривимірний вигляд: рельєф з висотами, маршрут і апарат у 3D з живими показниками")
        }
    }
}

// MARK: - Телеметрія на карті

struct MissionTelemetryStrip: View {
    @Environment(Store.self) var s
    var body: some View {
        HStack(spacing: 10) {
            Text(lk(s.armed ? "ARMED" : "DISARMED")).font(.caption.weight(.bold)).foregroundStyle(s.armed ? Color.red : Color.green)
            Text(lk(s.t.mode ?? "—")).font(.caption.weight(.semibold))
            item("arrow.up.to.line", Units.alt(s.t.altRel))
            item("speedometer", Units.speed(s.t.groundSpeed, digits: 0))
            item("battery.75", s.t.batteryV > 1 ? String(format: loc("%.1f В"), s.t.batteryV) : "—")
            item("location.fill", s.t.gpsFix >= 3 ? "\(s.t.sats)" : "нема")
            if s.t.wpSeq > 0 { item("flag.checkered", "WP \(s.t.wpSeq)" + (s.t.wpDist > 0 ? " · " + Units.dist(s.t.wpDist) : "")) }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.85), in: Capsule())
        .transaction { $0.animation = nil }
    }
    func item(_ icon: String, _ v: String) -> some View {
        HStack(spacing: 3) { Image(systemName: icon).foregroundStyle(.secondary); Text(LocalizedStringKey(v)).monospacedDigit() }.font(.caption)
    }
}

// MARK: - Керування (GCS)

struct MissionControlPanel: View {
    @Environment(Store.self) var s
    @Binding var open: Bool
    let ctl: MapController
    @State private var note: String?
    @State private var takeoffAlt = 10.0

    var isCopter: Bool { let v = s.ps.metaVehicle ?? ""; return !(v == "FIXED_WING" || v == "FLAPPING_WING" || v.hasPrefix("VTOL") || v == "GROUND_ROVER" || v == "SURFACE_BOAT" || v == "SUBMARINE") }
    func modeNum(_ name: String) -> Int? { s.ps.options("FLTMODE1").first { $0.1.lowercased() == name.lowercased() }?.0 }
    var sim: MissionSim { s.mission.sim }
    var simOn: Bool { sim.active }
    var canCmd: Bool { s.connected || simOn }
    func simMode(_ name: String) {
        switch name {
        case "Auto": sim.auto(from: nil)
        case "Guided": sim.loiterHere("Guided")
        case "Loiter": sim.loiterHere()
        case "RTL": sim.rtl()
        case "Land": sim.land()
        case "Circle": sim.loiterHere("Circle")
        case "FBWA": sim.straight()
        default: break
        }
    }
    func setMode(_ name: String) {
        if simOn { simMode(name); return }
        guard let n = modeNum(name) else { note = String(localized: "Режим \(loc(name)) недоступний для цього апарата"); return }
        EngineAPI.post("/cmd/mode?m=\(n)") { ok, _ in note = ok ? nil : "Не вдалося змінити режим" }
    }
    func isMode(_ name: String) -> Bool { (simOn ? sim.mode : (s.t.mode ?? "")).lowercased() == name.lowercased() }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { open.toggle() } label: {
                HStack { Image(systemName: "gamecontroller"); Text("Керування").font(.caption.weight(.semibold)); Spacer(); Image(systemName: open ? "chevron.down" : "chevron.up").font(.caption2) }
            }.buttonStyle(.plain)
            if open {
                HStack(spacing: 5) {
                    ForEach(isCopter ? ["Auto", "Guided", "Loiter", "RTL", "Land"] : ["Auto", "Guided", "Loiter", "Circle", "FBWA", "RTL"], id: \.self) { n in
                        Button { setMode(n) } label: { Text(LocalizedStringKey(n)).font(.caption).padding(.horizontal, 7).padding(.vertical, 3).background(isMode(n) ? Color.accentColor : Color.primary.opacity(0.1), in: Capsule()).foregroundStyle(isMode(n) ? Color.white : Color.primary) }
                            .buttonStyle(.plain).disabled(!canCmd)
                    }
                }
                HStack(spacing: 6) {
                    Button { if simOn { sim.step(-1, count: s.mission.items.count) } else { EngineAPI.post("/mission/current?seq=\(max(1, s.t.wpSeq - 1))") } } label: { Image(systemName: "backward.end.fill") }.help("Попередня точка")
                    Button { setMode("Auto") } label: { Label("Старт", systemImage: "play.fill") }.help("Режим AUTO: виконувати місію")
                    Button { setMode("Loiter") } label: { Label("Пауза", systemImage: "pause.fill") }.help("Режим LOITER: зависнути на місці")
                    Button { if simOn { sim.step(1, count: s.mission.items.count) } else { EngineAPI.post("/mission/current?seq=\(s.t.wpSeq + 1)") } } label: { Image(systemName: "forward.end.fill") }.help("Наступна точка")
                }
                .controlSize(.small).disabled(!canCmd)
                if simOn { Label(lk(loc("Симуляція: ") + (sim.note.isEmpty ? "команди йдуть у віртуальний апарат" : sim.note)), systemImage: "play.circle").font(.caption2).foregroundStyle(Color.accentColor) }
                if isCopter {
                    HStack(spacing: 6) {
                        Text("Зліт").font(.caption)
                        TextField("", value: $takeoffAlt, format: .number).textFieldStyle(.roundedBorder).frame(width: 46).multilineTextAlignment(.trailing)
                        Text("м").font(.caption).foregroundStyle(.secondary)
                        Button { takeoff() } label: { Label("Guided → ARM → Зліт", systemImage: "arrow.up.circle") }.controlSize(.small).disabled(!s.connected || s.armed)
                    }
                }
                if let n = note { Text(LocalizedStringKey(n)).font(.caption2).foregroundStyle(.orange) }
                if s.armed, !isMode("Auto") { Text("Місія виконується в режимі Auto.").font(.caption2).foregroundStyle(.secondary) }
            }
        }
        .padding(10)
        .frame(width: open ? 290 : 130)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.9), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
        .transaction { $0.animation = nil }
    }

    func takeoff() {
        guard let g = modeNum("Guided") else { return }
        EngineAPI.post("/cmd/mode?m=\(g)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { EngineAPI.post("/cmd/arm") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) { EngineAPI.post("/cmd/takeoff?alt=\(takeoffAlt)") }
        note = String(localized: "Зліт на \(Int(takeoffAlt)) м: Guided → ARM → Takeoff")
    }
}

// MARK: - Права панель

struct MissionInspector: View {
    @Bindable var m: MissionStore
    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: Binding(get: { m.section }, set: { v in
                m.section = v; m.selected = nil
                m.tool = v == .route ? 16 : v == .fence ? 5001 : v == .survey ? 5200 : 5100
                if v != .route { m.addMode = true }              // у геозоні й Rally клік по карті одразу додає
            })) { ForEach(MissionSection.allCases, id: \.self) { Text(lk($0.rawValue)).tag($0) } }
                .pickerStyle(.segmented).labelsHidden().padding(10)
            Divider()
            switch m.section {
            case .route: MissionRoutePanel(m: m)
            case .fence: FencePanel(m: m)
            case .rally: RallyPanel(m: m)
            case .survey: SurveyPanel(m: m)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// Рядок стану (робота / помилка / повідомлення / зауваження).
struct MissionStatusView: View {
    let m: MissionStore
    var issues: [MissionIssue] = []
    var body: some View {
        if !issues.isEmpty || m.error != nil || m.note != nil || m.busy != nil {
            VStack(alignment: .leading, spacing: 4) {
                if let b = m.busy { HStack { ProgressView().controlSize(.small); Text(LocalizedStringKey(b)).font(.caption) } }
                if let e = m.error { Label(LocalizedStringKey(e), systemImage: "exclamationmark.octagon.fill").font(.caption).foregroundStyle(.red) }
                if let n = m.note { Label(LocalizedStringKey(n), systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary) }
                ForEach(issues) { i in Label(LocalizedStringKey(i.text), systemImage: i.level == 1 ? "exclamationmark.triangle.fill" : "info.circle").font(.caption).foregroundStyle(i.level == 1 ? .orange : .secondary) }
            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct ExtraHeader: View {
    @Bindable var m: MissionStore
    @Environment(Store.self) var s
    let type: Int
    let title: String
    let count: String
    let dirty: Bool
    var clearLocal: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(LocalizedStringKey(title)).font(.headline)
                if dirty { Text("не записано").font(.caption2).padding(.horizontal, 6).padding(.vertical, 1).background(Color.orange.opacity(0.2), in: Capsule()).foregroundStyle(.orange) }
                Spacer()
                Text(LocalizedStringKey(count)).font(.caption).foregroundStyle(.secondary)
                Menu {
                    Button("Очистити план") { clearLocal() }
                    Button("Очистити на польотнику") { Task { try? await EngineAPI.send("/mission/clear?type=\(type)"); m.note = String(localized: "Очищено на польотнику") } }.disabled(!s.connected)
                } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).fixedSize()
            }
            HStack(spacing: 8) {
                Button { Task { await m.readExtra(type) } } label: { Label("Читати", systemImage: "arrow.down.circle").frame(maxWidth: .infinity) }.disabled(!s.connected || m.busy != nil)
                Button { Task { await m.writeExtra(type) } } label: { Label("Записати", systemImage: "arrow.up.circle.fill").frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent).disabled(!s.connected || m.busy != nil)
            }
        }.padding(12)
    }
}

/// Параметри в вузькій колонці: назва й опис зверху, елемент керування під ними. Показуються лише ті, що є в прошивці.
struct NarrowParams: View {
    @Environment(Store.self) var s
    let title: String; let icon: String; var text: String? = nil
    let params: [String]
    var body: some View {
        let present = params.filter { s.ps.has($0) }
        Card(title: title, icon: icon, text: text) {
            if present.isEmpty {
                Label(lk(s.connected ? "Цих параметрів немає в прошивці." : "Параметри з'являться після підключення польотника."), systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
            }
            VStack(spacing: 12) {
                ForEach(present, id: \.self) { n in NarrowParamRow(name: n); if n != present.last { Divider().opacity(0.4) } }
            }
        }
    }
}

struct NarrowParamRow: View {
    @Environment(Store.self) var s
    let name: String
    var body: some View {
        let ps = s.ps; let m = ps.meta[name]; let ua = ParamTexts.info(name)
        VStack(alignment: .leading, spacing: 4) {
            Text(lk(ua?.title ?? ps.tr[m?.label ?? ""] ?? m?.label ?? name)).font(.callout.weight(.medium))
            if let d = ua?.text ?? ParamTexts.shortDoc(ps.tr[m?.doc ?? ""] ?? m?.doc) {
                Text(LocalizedStringKey(d)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                if let m, let bits = m.bits, !bits.isEmpty { BitsMenu(name: name, bits: bits) }
                else if let m, let v = m.values, !v.isEmpty, v.count <= 30 { OptionPicker(name: name, width: 230) }
                else { ParamField(name: name, width: 100); Text(lk(m?.units ?? "")).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Text(LocalizedStringKey(name)).font(.system(.caption2, design: .monospaced)).foregroundStyle(.tertiary)
            }
        }
    }
}

/// Велика кнопка вибору інструмента (тип зони тощо).
struct ToolChoice: View {
    let cmd: Int; let title: String; let hint: String
    let active: Bool
    let action: () -> Void
    var body: some View {
        let b = MissionCatalog.badge(cmd)
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: b.0).font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 26, height: 26).background(Color(nsColor: b.1), in: Circle())
                VStack(alignment: .leading, spacing: 0) {
                    Text(LocalizedStringKey(title)).font(.callout.weight(.medium)).lineLimit(1)
                    Text(LocalizedStringKey(hint)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .background(active ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(active ? Color.accentColor : .clear, lineWidth: 1.5))
        }.buttonStyle(.plain)
    }
}

struct FencePanel: View {
    @Bindable var m: MissionStore
    @Environment(Store.self) var s
    static let kinds: [(Int, String, String)] = [(5001, "Дозволена територія", "Багатокутник"), (5002, "Заборонена зона", "Багатокутник"), (5003, "Дозволене коло", "Центр і радіус"), (5004, "Заборонене коло", "Центр і радіус")]

    var enabled: Bool { (s.ps.find("FENCE_ENABLE")?.value ?? 0) != 0 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ExtraHeader(m: m, type: 1, title: String(localized: "Геозона"), count: m.zones.isEmpty ? "зон немає" : String(localized: "зон: \(m.zones.count)"), dirty: m.fenceDirty) { m.zones = []; m.selectedZone = nil; m.note = "План геозони очищено" }
                    .padding(.horizontal, -12).padding(.top, -12)
                // стан на польотнику
                if s.ps.has("FENCE_ENABLE") {
                    HStack(spacing: 8) {
                        Image(systemName: enabled ? "checkmark.shield.fill" : "shield.slash").foregroundStyle(enabled ? Color.green : Color.orange)
                        Text(lk(enabled ? "Геозона увімкнена на польотнику" : "Геозона вимкнена на польотнику: зони не діють")).font(.callout)
                        Spacer()
                        if !enabled { Button("Увімкнути") { if let p = s.ps.find("FENCE_ENABLE") { s.ps.set(p, to: 1) } }.controlSize(.small) }
                    }
                    .padding(10).background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                }
                Card(title: String(localized: "1. Оберіть, що намалювати"), icon: "pencil.and.outline", text: nil) {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                        ForEach(Self.kinds, id: \.0) { k in
                            ToolChoice(cmd: k.0, title: k.1, hint: k.2, active: m.addMode && m.tool == k.0) {
                                if m.addMode && m.tool == k.0 { m.addMode = false } else { m.tool = k.0; m.addMode = true; m.selectedZone = nil }
                            }
                        }
                    }
                    hint
                }
                Card(title: String(localized: "2. Зони"), icon: "square.dashed", text: nil) {
                    if m.zones.isEmpty { Text("Поки порожньо. Оберіть тип вище й клацайте по карті.").font(.callout).foregroundStyle(.secondary) }
                    ForEach(Array(m.zones.enumerated()), id: \.element.id) { i, z in zoneRow(i, z) }
                    if let zid = m.selectedZone, let zi = m.zones.firstIndex(where: { $0.id == zid }) { editor(zi) }
                }
                MissionStatusView(m: m, issues: m.fenceIssues).padding(-10)
                NarrowParams(title: String(localized: "Параметри геозони"), icon: "gearshape", text: String(localized: "Геозона працює, лише коли вона увімкнена й вибрано потрібні типи обмежень."),
                             params: ["FENCE_ENABLE", "FENCE_TYPE", "FENCE_ACTION", "FENCE_ALT_MAX", "FENCE_ALT_MIN", "FENCE_RADIUS", "FENCE_MARGIN", "FENCE_AUTOENABLE", "FENCE_RET_RALLY"])
            }
            .padding(12)
        }
    }

    @ViewBuilder var hint: some View {
        if m.addMode, m.tool >= 5001, m.tool <= 5004 {
            let circle = m.tool >= 5003
            let cur = m.zones.first { $0.id == m.selectedZone }
            VStack(alignment: .leading, spacing: 6) {
                Label(lk(circle ? "Клацніть по карті: там з'явиться центр кола. Радіус задається нижче в списку зон." : (cur == nil ? "Клацайте по карті, щоб поставити вершини. Потрібно щонайменше 3." : String(localized: "Вершин: \(cur!.pts.count). Клацайте далі, щоб додати ще (мінімум 3). Вершини можна перетягувати."))), systemImage: "hand.tap").font(.caption).foregroundStyle(.secondary)
                if !circle, cur != nil { Button { m.selectedZone = nil } label: { Label("Завершити зону, почати нову", systemImage: "checkmark.circle") }.controlSize(.small) }
            }
        } else {
            Label("Виберіть тип зони, щоб клік по карті ставив її точки.", systemImage: "hand.tap").font(.caption).foregroundStyle(.secondary)
        }
    }

    func zoneRow(_ i: Int, _ z: FenceZone) -> some View {
        let sel = m.selectedZone == z.id
        let b = MissionCatalog.badge(z.kind)
        return HStack(spacing: 8) {
            Image(systemName: b.0).font(.system(size: 9, weight: .bold)).foregroundStyle(.white).frame(width: 20, height: 20).background(Color(nsColor: b.1), in: Circle())
            VStack(alignment: .leading, spacing: 0) {
                Text(lk(String(localized: "Зона \(i + 1): ") + (z.exclusion ? "заборонена" : "дозволена"))).font(.callout)
                Text(lk(z.isCircle ? String(format: loc("Коло, радіус %.0f м"), z.radius) : String(localized: "Багатокутник, вершин: \(z.pts.count)") + (z.pts.count < 3 ? " (треба ≥ 3)" : ""))).font(.caption2).foregroundStyle(z.isCircle || z.pts.count >= 3 ? Color.secondary : Color.orange)
            }
            Spacer()
            Button(role: .destructive) { m.removeZone(z.id) } label: { Image(systemName: "trash") }.buttonStyle(.borderless).help("Видалити зону")
        }
        .padding(6)
        .background(sel ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture { m.selectedZone = sel ? nil : z.id; m.selected = nil }
    }

    func editor(_ zi: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Picker("Тип", selection: Binding(get: { m.zones.indices.contains(zi) ? m.zones[zi].kind : 5001 }, set: { k in
                guard m.zones.indices.contains(zi) else { return }
                if (k == 5003 || k == 5004), !m.zones[zi].isCircle { m.zones[zi].pts = Array(m.zones[zi].pts.prefix(1)) }
                m.zones[zi].kind = k
            })) { ForEach(Self.kinds, id: \.0) { Text(lk($0.1 + ($0.0 >= 5003 ? " (коло)" : " (багатокутник)"))).tag($0.0) } }.controlSize(.small)
            if m.zones.indices.contains(zi), m.zones[zi].isCircle {
                HStack {
                    Text("Радіус, м").font(.caption)
                    TextField("", value: Binding(get: { m.zones.indices.contains(zi) ? m.zones[zi].radius : 0 }, set: { if m.zones.indices.contains(zi) { m.zones[zi].radius = max(1, $0) } }), format: .number).textFieldStyle(.roundedBorder).frame(width: 90)
                }
            } else if let sel = m.selected, m.zones.indices.contains(zi), m.zones[zi].pts.contains(where: { $0.id == sel }) {
                Button(role: .destructive) { m.removeVertex(sel) } label: { Label("Видалити вибрану вершину", systemImage: "minus.circle") }.controlSize(.small)
            }
        }
    }
}

struct RallyPanel: View {
    @Bindable var m: MissionStore
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ExtraHeader(m: m, type: 2, title: String(localized: "Rally-точки"), count: m.rally.isEmpty ? "точок немає" : String(localized: "точок: \(m.rally.count)"), dirty: m.rallyDirty) { m.rally = []; m.note = "План Rally очищено" }
                    .padding(.horizontal, -12).padding(.top, -12)
                Card(title: String(localized: "Що це"), icon: "lifepreserver", text: String(localized: "Rally-точка це запасне місце, куди апарат повертається замість Home: наприклад, безпечніший майданчик для посадки. Автопілот обирає найближчу.")) {
                    ToolChoice(cmd: 5100, title: String(localized: "Поставити Rally-точку"), hint: String(localized: "Клік по карті"), active: m.addMode && m.tool == 5100) { m.tool = 5100; m.addMode.toggle() }
                    Label(lk(m.addMode ? "Клацайте по карті, щоб додати точки. Їх можна перетягувати." : "Натисніть кнопку вище, щоб ставити точки кліком по карті."), systemImage: "hand.tap").font(.caption).foregroundStyle(.secondary)
                }
                Card(title: String(localized: "Точки"), icon: "mappin.and.ellipse", text: nil) {
                    if m.rally.isEmpty { Text("Поки порожньо.").font(.callout).foregroundStyle(.secondary) }
                    ForEach(Array(m.rally.enumerated()), id: \.element.id) { i, r in row(i, r) }
                }
                MissionStatusView(m: m, issues: m.rally.isEmpty ? [] : [MissionIssue(level: 0, text: String(localized: "Висота відносна до Home. Кількість точок на польотнику (RALLY_TOTAL) задається автоматично при записі."))]).padding(-10)
                NarrowParams(title: String(localized: "Параметри Rally"), icon: "gearshape", params: ["RALLY_TOTAL", "RALLY_LIMIT_KM", "RALLY_INCL_HOME"])
            }
            .padding(12)
        }
    }

    func row(_ i: Int, _ r: RallyPoint) -> some View {
        let sel = m.selected == r.id
        return HStack(spacing: 8) {
            Text("R\(i + 1)").font(.caption.weight(.bold)).frame(width: 28, height: 22).background(Color.teal, in: Capsule()).foregroundStyle(.white)
            Text(Coords.pair(r.lat, r.lon, decimals: 5)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Spacer()
            TextField("", value: Binding(get: { m.rally.first { $0.id == r.id }?.alt ?? 0 }, set: { v in if let k = m.rally.firstIndex(where: { $0.id == r.id }) { m.rally[k].alt = v } }), format: .number)
                .textFieldStyle(.roundedBorder).frame(width: 56).multilineTextAlignment(.trailing)
            Text("м").font(.caption).foregroundStyle(.secondary)
            Button(role: .destructive) { m.removeRally(r.id) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
        }
        .padding(6)
        .background(sel ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture { m.selected = r.id }
    }
}

// MARK: - Панель маршруту

struct MissionRoutePanel: View {
    @Bindable var m: MissionStore
    @Environment(Store.self) var s

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if m.items.isEmpty && m.home == nil {
                ContentUnavailableView {
                    Label("Місія порожня", systemImage: "map")
                } description: {
                    Text("Увімкніть «Додавання» на карті й клацайте, щоб поставити точки. Або прочитайте місію з польотника чи відкрийте файл.")
                }
                .frame(maxHeight: .infinity)
            } else {
                List(selection: $m.selected) {
                    if let h = m.home {
                        HomeRow(home: h).tag(MissionStore.homeID)
                            .contextMenu {
                                Button("Копіювати координати") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(MissionStore.coordString(h.lat, h.lon), forType: .string) }
                                Divider()
                                Button("Видалити Home", role: .destructive) { m.selected = MissionStore.homeID; _ = m.deleteSelected() }
                            }
                    }
                    ForEach(Array(m.items.enumerated()), id: \.element.id) { i, it in
                        MissionRow(index: i + 1, it: it, current: s.connected && !m.dirty && s.t.wpSeq == i + 1)
                            .tag(it.id)
                            .contextMenu {
                                Button("Дублювати") { m.duplicate(it.id) }
                                Menu("Вставити після") { ForEach(MissionCatalog.groups, id: \.0) { g in Menu(lk(g.0)) { ForEach(g.1) { c in Button(lk(c.name)) { m.add(c.id, at: it.hasPos ? it.coord : nil, after: i) } } } } }
                                Divider()
                                Button("Видалити", role: .destructive) { m.remove(it.id) }
                            }
                    }
                    .onMove { m.items.move(fromOffsets: $0, toOffset: $1) }
                    .onDelete { for i in $0 { m.remove(m.items[i].id) } }
                }
                .listStyle(.inset)
                .onDeleteCommand { _ = m.deleteSelected() }
            }
            if m.selected == MissionStore.homeID, m.home != nil {
                Divider()
                HomeEditor(m: m).frame(maxHeight: 330)
            } else if let id = m.selected, m.items.contains(where: { $0.id == id }) {
                Divider()
                MissionItemEditor(m: m, id: id).frame(maxHeight: 330)
            }
            MissionStatusView(m: m, issues: m.issues)
        }
    }

    var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("План місії").font(.headline)
                if m.dirty { Text("не записано").font(.caption2).padding(.horizontal, 6).padding(.vertical, 1).background(Color.orange.opacity(0.2), in: Capsule()).foregroundStyle(.orange) }
                Spacer()
                Menu {
                    Button("Відкрити файл .waypoints…") { openFile() }
                    Button("Зберегти у файл…") { saveFile() }.disabled(m.items.isEmpty)
                    Divider()
                    Button("Імпорт з KML…") { openKML() }
                    Button("Зберегти як KML…") { saveKML() }.disabled(m.items.isEmpty && m.zones.isEmpty && m.rally.isEmpty && m.surveys.isEmpty)
                    Divider()
                    Button("Очистити план") { m.clearLocal() }.disabled(m.items.isEmpty)
                    Button("Очистити місію на польотнику") { Task { await m.clearVehicle() } }.disabled(!s.connected || m.busy != nil)
                } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).fixedSize()
            }
            HStack(spacing: 14) {
                stat("mappin.and.ellipse", "\(m.items.count)")
                stat("ruler", Units.dist(m.distance))
                stat("clock", String(format: loc("≈ %d хв %d с"), Int(m.eta) / 60, Int(m.eta) % 60))
                stat("arrow.up.to.line", Units.alt(m.maxAlt))
            }
            HStack(spacing: 8) {
                Button { Task { await m.readFromVehicle() } } label: { Label("Читати", systemImage: "arrow.down.circle").frame(maxWidth: .infinity) }.disabled(!s.connected || m.busy != nil)
                Button { Task { await m.writeToVehicle(homeFallback: s.t.homeSet ? HomePoint(lat: s.t.homeLat, lon: s.t.homeLon, alt: 0) : nil) } } label: { Label("Записати", systemImage: "arrow.up.circle.fill").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).disabled(!s.connected || m.busy != nil)
            }
            // симуляція недоступна під час реального польоту (ARMED або апарат у повітрі)
            let flying = s.armed || (s.connected && s.t.altRel > 3 && s.t.groundSpeed > 1.5)
            Button { m.sim.enabled.toggle(); if !m.sim.enabled { m.sim.pause() } else { m.sim.play() } } label: {
                Label(lk(m.sim.enabled ? "Вимкнути симуляцію" : "Симуляція польоту по місії"), systemImage: m.sim.enabled ? "stop.circle.fill" : "play.circle.fill").frame(maxWidth: .infinity)
            }.controlSize(.large).disabled(m.items.isEmpty || (flying && !m.sim.enabled))
                .help(lk(flying ? "Недоступна під час реального польоту" : (m.items.isEmpty ? "Спершу додайте точки місії" : "Віртуальний політ по плану на карті, без польотника")))
            if flying { Label("Симуляція недоступна: апарат у польоті (ARMED)", systemImage: "lock.fill").font(.caption2).foregroundStyle(.orange) }
            HStack(spacing: 4) {
                Text("Швидкість для розрахунку").font(.caption).foregroundStyle(.secondary)
                Spacer()
                TextField("", value: $m.cruise, format: .number).textFieldStyle(.roundedBorder).frame(width: 46).multilineTextAlignment(.trailing).controlSize(.small)
                Text("м/с").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(12)
    }

    func stat(_ icon: String, _ v: String) -> some View { HStack(spacing: 3) { Image(systemName: icon).foregroundStyle(.secondary); Text(LocalizedStringKey(v)).monospacedDigit() }.font(.caption) }

    func openFile() {
        let p = NSOpenPanel(); p.allowedContentTypes = [UTType(filenameExtension: "waypoints") ?? .plainText, .plainText]; p.allowsOtherFileTypes = true
        guard p.runModal() == .OK, let u = p.url, let t = try? String(contentsOf: u, encoding: .utf8) else { return }
        m.importText(t)
    }
    func openKML() {
        let p = NSOpenPanel(); p.allowedContentTypes = [UTType(filenameExtension: "kml") ?? .xml, .xml]; p.allowsOtherFileTypes = true
        guard p.runModal() == .OK, let u = p.url, let d = try? Data(contentsOf: u) else { return }
        m.importKML(d)
    }
    func saveKML() {
        let p = NSSavePanel(); p.nameFieldStringValue = "mission.kml"
        guard p.runModal() == .OK, let u = p.url else { return }
        do { try MissionKML.export(m).write(to: u, atomically: true, encoding: .utf8); m.note = String(localized: "Збережено: \(u.lastPathComponent)") } catch { m.error = error.localizedDescription }
    }
    func saveFile() {
        let p = NSSavePanel(); p.nameFieldStringValue = "mission.waypoints"
        guard p.runModal() == .OK, let u = p.url else { return }
        do { try m.exportText().write(to: u, atomically: true, encoding: .utf8); m.note = String(localized: "Збережено: \(u.lastPathComponent)") } catch { m.error = error.localizedDescription }
    }
}

struct MissionRow: View {
    let index: Int
    let it: MissionItem
    let current: Bool
    var body: some View {
        HStack(spacing: 8) {
            Text("\(index)").font(.caption.weight(.bold).monospacedDigit()).frame(width: 22, height: 22)
                .background(current ? Color.green : Color.accentColor.opacity(0.85), in: Circle()).foregroundStyle(.white)
            Image(systemName: MissionCatalog.badge(it.cmd).0).font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                .frame(width: 18, height: 18).background(Color(nsColor: MissionCatalog.badge(it.cmd).1), in: Circle())
            VStack(alignment: .leading, spacing: 0) {
                Text(LocalizedStringKey(it.def.name)).font(.callout).lineLimit(1)
                if it.def.loc { Text(lk(it.hasPos ? String(format: loc("%.0f м · "), it.alt) + Coords.pair(it.lat, it.lon, decimals: 5) : "без координат")).font(.caption2).foregroundStyle(it.hasPos ? Color.secondary : Color.orange) }
                else if let l = it.def.params.first, let l { Text("\(l): \(it.p1.formatted())").font(.caption2).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 1)
    }
}

// MARK: - Редактор вибраної точки

struct MissionItemEditor: View {
    @Bindable var m: MissionStore
    let id: UUID
    @Environment(Store.self) var s

    var item: MissionItem? { m.items.first { $0.id == id } }
    func num(_ kp: WritableKeyPath<MissionItem, Double>) -> Binding<Double> {
        Binding(get: { m.items.first { $0.id == id }?[keyPath: kp] ?? 0 }, set: { v in m.update(id) { $0[keyPath: kp] = v } })
    }
    func param(_ i: Int) -> Binding<Double> {
        Binding(get: { m.items.first { $0.id == id }?.param(i) ?? 0 }, set: { v in m.update(id) { $0.setParam(i, v) } })
    }

    var body: some View {
        if let it = item {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Menu {
                            ForEach(MissionCatalog.groups, id: \.0) { g in
                                Menu(lk(g.0)) { ForEach(g.1) { c in Button { m.update(id) { $0.cmd = c.id; if !c.loc { $0.alt = 0 } else if $0.alt == 0 { $0.alt = m.defaultAlt } } } label: { Label(LocalizedStringKey(c.name), systemImage: c.icon) } } }
                            }
                        } label: { Label(LocalizedStringKey(it.def.name), systemImage: it.def.icon).font(.callout.weight(.semibold)) }.menuStyle(.borderlessButton).fixedSize()
                        Spacer()
                        Button { m.move(id, by: -1) } label: { Image(systemName: "chevron.up") }.help("Вище")
                        Button { m.move(id, by: 1) } label: { Image(systemName: "chevron.down") }.help("Нижче")
                        Button { m.duplicate(id) } label: { Image(systemName: "plus.square.on.square") }.help("Дублювати")
                        Button(role: .destructive) { m.remove(id) } label: { Image(systemName: "trash") }.help("Видалити")
                    }.buttonStyle(.borderless)
                    if it.group != nil {
                        Label("Точку згенеровано ділянкою обліту: зміни втратяться, коли ви зміните параметри ділянки. Керуйте нею у вкладці «Ділянка».", systemImage: "square.grid.3x3").font(.caption).foregroundStyle(.purple)
                    }
                    if it.def.loc {
                        HStack { field("Широта", num(\.lat)); field("Довгота", num(\.lon)) }
                        if Coords.isMGRS, it.hasPos {
                            MGRSEditField(lat: it.lat, lon: it.lon) { la, lo in m.update(id) { $0.lat = la; $0.lon = lo } }.id("\(it.lat),\(it.lon)")
                        }
                        HStack(alignment: .bottom) {
                            field("Висота, м", num(\.alt))
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Система висоти").font(.caption2).foregroundStyle(.secondary)
                                Picker("", selection: Binding(get: { item?.frame ?? 3 }, set: { v in m.update(id) { $0.frame = v } })) {
                                    ForEach(MissionCatalog.frames, id: \.0) { Text(lk($0.1)).tag($0.0) }
                                }.labelsHidden()
                            }
                        }
                    }
                    ForEach(0..<4, id: \.self) { i in
                        if let l = it.def.params[i] { field(l, param(i)) }
                    }
                    HStack {
                        if s.connected, !m.dirty, let i = m.selectedIndex {
                            Button("Зробити поточною") { EngineAPI.post("/mission/current?seq=\(i + 1)") }.controlSize(.small)
                        }
                    }
                }.padding(12)
            }
        }
    }

    func field(_ title: String, _ b: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(LocalizedStringKey(title)).font(.caption2).foregroundStyle(.secondary)
            TextField("", value: b, format: .number.precision(.fractionLength(0...7))).textFieldStyle(.roundedBorder).multilineTextAlignment(.leading)
        }
    }
}

/// Поле MGRS у редакторі точки (показується, коли в Налаштуваннях обрано формат MGRS): Return застосовує введене.
struct MGRSEditField: View {
    let lat: Double, lon: Double
    let apply: (Double, Double) -> Void
    @State private var text = ""
    @State private var bad = false
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("MGRS").font(.caption2).foregroundStyle(.secondary)
            TextField("", text: $text).textFieldStyle(.roundedBorder).font(.system(.callout, design: .monospaced))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(bad ? Color.red : .clear))
                .onSubmit {
                    if let p = Coords.parseMGRS(text) { bad = false; apply(p.0, p.1) } else { bad = true }
                }
        }
        .onAppear { text = Coords.mgrs(lat, lon) ?? "" }
    }
}

// MARK: - Home у плані

struct HomeRow: View {
    let home: HomePoint
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "house.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                .frame(width: 22, height: 22).background(Color.green, in: Circle())
            VStack(alignment: .leading, spacing: 0) {
                Text("Home").font(.callout).lineLimit(1)
                Text(lk(String(format: loc("%.0f м · "), home.alt) + Coords.pair(home.lat, home.lon, decimals: 5))).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 1)
    }
}

/// Редактор домашньої точки плану: координати, висота, видалення.
struct HomeEditor: View {
    @Bindable var m: MissionStore
    @State private var mgrsBad = false

    func num(_ kp: WritableKeyPath<HomePoint, Double>) -> Binding<Double> {
        Binding(get: { m.home?[keyPath: kp] ?? 0 }, set: { v in if var h = m.home { h[keyPath: kp] = v; m.home = h } })
    }
    func field(_ title: String, _ b: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(LocalizedStringKey(title)).font(.caption2).foregroundStyle(.secondary)
            TextField("", value: b, format: .number.precision(.fractionLength(0...7))).textFieldStyle(.roundedBorder)
        }
    }

    var body: some View {
        if let h = m.home {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("Home", systemImage: "house.fill").font(.headline)
                        Spacer()
                        Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(MissionStore.coordString(h.lat, h.lon), forType: .string) } label: { Image(systemName: "doc.on.doc") }.help("Копіювати координати")
                        Button(role: .destructive) { m.selected = MissionStore.homeID; _ = m.deleteSelected() } label: { Image(systemName: "trash") }.help("Видалити Home")
                    }.buttonStyle(.borderless)
                    HStack { field("Широта", num(\.lat)); field("Довгота", num(\.lon)) }
                    if Coords.isMGRS { MGRSEditField(lat: h.lat, lon: h.lon) { la, lo in m.home = HomePoint(lat: la, lon: lo, alt: h.alt) }.id("\(h.lat),\(h.lon)") }
                    field("Висота, м", num(\.alt))
                    Text("Home у плані записується як перша точка місії (seq 0). Польотник може підставити свій Home, якщо GPS уже його встановив.").font(.caption2).foregroundStyle(.secondary)
                }.padding(12)
            }
        }
    }
}

/// Гарячі клавіші плану (⌘Z, ⇧⌘Z, ⌘C/⌘X/⌘V, Delete) у 3D-режимі, де немає MKMapView з власним монітором подій.
struct PlanKeyMonitor: NSViewRepresentable {
    let onKey: (NSEvent) -> Bool
    final class V: NSView {
        var onKey: ((NSEvent) -> Bool)?
        var monitor: Any?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
                guard let self, let w = self.window, e.window === w, w.isKeyWindow, !(w.firstResponder is NSText) else { return e }
                return (self.onKey?(e) ?? false) ? nil : e
            }
        }
        deinit { if let m = monitor { NSEvent.removeMonitor(m) } }
    }
    func makeNSView(context: Context) -> V { let v = V(); v.onKey = onKey; return v }
    func updateNSView(_ v: V, context: Context) { v.onKey = onKey }
}
