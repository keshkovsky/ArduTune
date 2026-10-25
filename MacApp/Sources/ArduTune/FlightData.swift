import SwiftUI
import MapKit

enum FDTab: String, CaseIterable, Identifiable {
    case dashboard = "Dashboard", actions = "Actions", messages = "Messages", params = "Params", video = "Video"
    case preflight = "PreFlight", status = "Status", servo = "Servo/Relay", aux = "Aux Function", scripts = "Scripts", inspector = "MAVLink Inspector", ekf = "EKF", vibe = "Vibration"
    var id: String { rawValue }
}

/// Flight Data: HUD + карта зверху, вкладки з даними та діями знизу.
struct FlightView: View {
    @Environment(Store.self) var s
    @Environment(\.openWindow) private var openWindow
    @State private var tab: FDTab = .dashboard
    @State private var fs = FlightStore()
    @AppStorage("hud.hidden") private var hudHidden = ""
    @AppStorage("hud.user2") private var hudUser = HUDConfig.defaultUser
    @AppStorage("hud.names") private var hudNamesJSON = "{}"          // власні назви User Items (JSON {ключ: назва})
    @AppStorage("hud.scale") private var hudScale = 1.0
    @AppStorage("hud.theme") private var hudTheme = "classic"
    @AppStorage("hud.sky") private var hudSky = ""
    @AppStorage("hud.ground") private var hudGround2 = ""
    @AppStorage("hud.ink") private var hudInk = ""
    @AppStorage("hud.accent") private var hudAccent = ""
    @AppStorage("fd.tabs.inspector") private var inspectorAdded = false
    @AppStorage("fd.tabs.ekfvibe") private var ekfVibeAdded = false
    @AppStorage("fd.tabs") private var tabsCSV = FDTab.allCases.map(\.rawValue).joined(separator: ",")
    @AppStorage("hud.aspect") private var hudAspect = "auto"
    @AppStorage("hud.swap") private var hudSwap = false
    private var herelinkIP: String { get { StreamSettings.shared.ip } nonmutating set { StreamSettings.shared.ip = newValue } }
    private var herelinkPort: Int { StreamSettings.shared.port }
    private var herelinkPath: String { StreamSettings.shared.path }

    var hudConfig: HUDConfig {
        var c = HUDConfig()
        c.hidden = Set(hudHidden.split(separator: ",").map(String.init))
        c.userItems = hudUser.split(separator: ",").map(String.init)
        c.userNames = hudNames
        let mav = c.userItems.filter { $0.hasPrefix(HUDConfig.mavPrefix) }
        if !mav.isEmpty {
            let want = Set(mav.map { String($0.dropFirst(HUDConfig.mavPrefix.count)) })
            for f in fs.fields where want.contains(f.k) { c.userValues[HUDConfig.mavPrefix + f.k] = f.v }
        }
        c.videoBackground = s.video.showInHUD && s.video.running
        c.scale = hudScale
        c.theme = HUDTheme.make(id: hudTheme, sky: hudSky, ground: hudGround2, ink: hudInk, accent: hudAccent)
        return c
    }
    var hudNames: [String: String] {
        (try? JSONDecoder().decode([String: String].self, from: Data(hudNamesJSON.utf8))) ?? [:]
    }
    func setHudName(_ key: String, _ name: String) {
        var n = hudNames
        if name.isEmpty || name == HUDConfig.defaultLabel(key) { n.removeValue(forKey: key) } else { n[key] = name }
        if let d = try? JSONEncoder().encode(n), let str = String(data: d, encoding: .utf8) { hudNamesJSON = str }
    }
    /// Додає або прибирає пункт User Items; при додаванні пропонує перейменувати.
    func toggleUserItem(_ key: String) {
        let was = hudUser.split(separator: ",").contains(Substring(key))
        csvToggle(&hudUser, key)
        if !was { askRename(key) }
    }
    func askRename(_ key: String) {
        let cur = hudNames[key] ?? HUDConfig.defaultLabel(key)
        if let r = Prompt.ask("Перейменувати параметр на HUD", message: HUDConfig.defaultLabel(key) + loc("\nНазва, яка показуватиметься на HUD замість стандартної."), fields: [("Назва", cur)]) {
            setHudName(key, r[0].trimmingCharacters(in: .whitespaces))
        }
    }
    var navSource: NavSource { s.ps.navSource }
    var aspectRatio: CGFloat? {
        let p = hudAspect.split(separator: ":").compactMap { Double($0) }
        return p.count == 2 && p[1] > 0 ? CGFloat(p[0] / p[1]) : nil
    }

    var hudPane: some View {
        ZStack {
            if s.video.showInHUD && s.video.running {
                VideoSurface(video: s.video, t: s.t, overlay: false).clipShape(RoundedRectangle(cornerRadius: 10))
            }
            HUDView(t: s.t, navSource: navSource, alerts: fs.alerts, config: hudConfig)
        }
        .modifier(AspectModifier(ratio: aspectRatio))
        .overlay { RightClickCatcher { _, view, event in showHUDMenu(view: view, event: event) } }
        .frame(minWidth: 380).padding(8)
        .task(id: hudUser.contains(HUDConfig.mavPrefix)) {
            // значення довільних полів MAVLink потрібні HUD лише коли такі пункти вибрано
            if hudUser.contains(HUDConfig.mavPrefix) { fs.startFields() }
        }
    }

    var body: some View {
        VSplitView {
            HSplitView {
                if hudSwap { MapPanel().frame(minWidth: 380).padding(8); hudPane }
                else { hudPane; MapPanel().frame(minWidth: 380).padding(8) }
            }
            .frame(minHeight: 300)
            VStack(spacing: 0) {
                tabBar
                Divider()
                tabContent.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(minHeight: 200, idealHeight: 280)
        }
        .environment(fs)
        .onAppear {
            fs.startLog()
            if !ekfVibeAdded {
                ekfVibeAdded = true
                for t in [FDTab.ekf, FDTab.vibe] where !tabsCSV.contains(t.rawValue) { tabsCSV += "," + t.rawValue }
            }
            if !inspectorAdded {                       // нова вкладка з'являється й у тих, хто вже налаштував порядок вкладок
                inspectorAdded = true
                if !tabsCSV.contains(FDTab.inspector.rawValue) { tabsCSV += "," + FDTab.inspector.rawValue }
            }
        }
        .onDisappear { fs.stop("log") }
        .onChange(of: s.flightTabRequest) { _, v in if let v, let t = FDTab(rawValue: v) { tab = t; s.flightTabRequest = nil } }
    }

    // MARK: Меню HUD (правий клік)
    func csvToggle(_ raw: inout String, _ key: String) {
        var l = raw.split(separator: ",").map(String.init)
        if let i = l.firstIndex(of: key) { l.remove(at: i) } else { l.append(key) }
        raw = l.joined(separator: ",")
    }

    func showHUDMenu(view: NSView, event: NSEvent) {
        let v = s.video
        v.refreshCameras()
        let mb = MenuBuilder()
        mb.submenu("Video") { m in
            mb.item("Показувати відео на HUD", enabled: v.running, checked: v.showInHUD, to: m) { v.showInHUD.toggle() }
            mb.item("Відкрити відео у вікні", to: m) { openWindow(id: "video") }
            mb.separator(m)
            if v.cameras.isEmpty { mb.item("Камер не знайдено", enabled: false, to: m) }
            for cam in v.cameras {
                mb.item(cam.name, checked: v.active == .camera && v.selectedCamera == cam.id, to: m) { v.selectedCamera = cam.id; v.startCamera(); v.showInHUD = true }
            }
            mb.separator(m)
            mb.item("Запустити GStreamer (поточний pipeline)", enabled: VideoStore.gstAvailable, to: m) { v.startGStreamer(); v.showInHUD = true }
            mb.item("Задати GStreamer pipeline…", to: m) {
                if let r = Prompt.ask("GStreamer pipeline", message: String(localized: "Кінцівку appsink можна не вказувати."), fields: [("Pipeline", v.pipeline)]), !r[0].isEmpty { v.startGStreamer(r[0]); v.showInHUD = true }
            }
            mb.item("Налаштування відео…", to: m) { tab = .video }
            mb.submenu("Herelink", to: m) { h in
                mb.item(String(localized: "Запустити (rtsp://\(herelinkIP):\(herelinkPort)/\(herelinkPath))"), enabled: VideoStore.gstAvailable, to: h) {
                    v.startGStreamer("rtspsrc location=rtsp://\(herelinkIP):\(herelinkPort)/\(herelinkPath) latency=0 ! rtph264depay ! h264parse ! avdec_h264"); v.showInHUD = true
                }
                mb.item("Налаштування Herelink…", to: h) { tab = .video }
                mb.item("Змінити IP Herelink…", to: h) { if let r = Prompt.ask("Herelink", fields: [("IP-адреса", herelinkIP)]), !r[0].isEmpty { herelinkIP = r[0] } }
            }
            mb.separator(m)
            mb.item("Зупинити відео", enabled: v.running, to: m) { v.stopAll() }
        }
        mb.submenu("Set Aspect Ratio") { m in
            for (title, val) in [("Авто", "auto"), ("16:9", "16:9"), ("4:3", "4:3"), ("3:2", "3:2"), ("21:9", "21:9"), ("1:1", "1:1")] {
                mb.item(title, checked: hudAspect == val, to: m) { hudAspect = val }
            }
        }
        fs.startFields()                      // список полів MAVLink для меню й значень на HUD
        mb.submenu("User Items") { m in
            let chosen = hudUser.split(separator: ",").map(String.init)
            for (key, title) in HUDConfig.userDefs {
                mb.item(title, checked: chosen.contains(key), to: m) { toggleUserItem(key) }
            }
            // усі поля всіх повідомлень MAVLink, що надходять від польотника (як CurrentState у Mission Planner)
            mb.separator(m)
            mb.submenu("Усі параметри MAVLink", to: m) { all in
                let fields = fs.fields
                if fields.isEmpty { mb.item("Немає даних (підключіть польотник)", enabled: false, soon: false, to: all) { } }
                var groups: [(String, [String])] = []
                for f in fields {
                    guard let dot = f.k.firstIndex(of: ".") else { continue }
                    let msg = String(f.k[..<dot])
                    if let gi = groups.firstIndex(where: { $0.0 == msg }) { groups[gi].1.append(f.k) } else { groups.append((msg, [f.k])) }
                }
                for (msg, keys) in groups.sorted(by: { $0.0 < $1.0 }) {
                    mb.submenu(msg + "  (\(keys.count))", to: all) { sub in
                        for k in keys {
                            let key = HUDConfig.mavPrefix + k
                            let field = String(k[k.index(after: k.firstIndex(of: ".")!)...])
                            mb.item(field, checked: chosen.contains(key), to: sub) { toggleUserItem(key) }
                        }
                    }
                }
            }
            if !chosen.isEmpty {
                mb.submenu("Перейменувати…", to: m) { rn in
                    for key in chosen { mb.item((hudNames[key] ?? HUDConfig.defaultLabel(key)) + "  ←  " + HUDConfig.defaultLabel(key), to: rn) { askRename(key) } }
                }
            }
            mb.separator(m)
            mb.item("Типовий набір", to: m) { hudUser = HUDConfig.defaultUser }
            mb.item("Показати всі основні", to: m) { hudUser = HUDConfig.userDefs.map(\.0).joined(separator: ",") }
            mb.item("Прибрати всі", to: m) { hudUser = "" }
        }
        mb.submenu("Масштаб HUD") { m in
            for pct in [60, 75, 90, 100, 115, 130, 150] {
                mb.item("\(pct)%", checked: Int((hudScale * 100).rounded()) == pct, to: m) { hudScale = Double(pct) / 100 }
            }
            mb.separator(m)
            mb.item("Налаштувати плавно…", to: m) { openWindow(id: "hudtheme") }
        }
        mb.submenu("Тема HUD") { m in
            for th in HUDTheme.all {
                mb.item(th.name, checked: hudTheme == th.id, to: m) { hudTheme = th.id; hudSky = ""; hudGround2 = ""; hudInk = ""; hudAccent = "" }
            }
            mb.separator(m)
            mb.item("Налаштувати кольори…", to: m) { openWindow(id: "hudtheme") }
        }
        mb.item("Swap With Map", checked: hudSwap) { hudSwap.toggle() }
        mb.submenu("HUD Items") { m in
            for (key, title) in HUDConfig.elements {
                mb.item(title, checked: !hudHidden.split(separator: ",").contains(Substring(key)), to: m) { csvToggle(&hudHidden, key) }
            }
            mb.separator(m)
            mb.item("Показати все", to: m) { hudHidden = "" }
        }
        mb.show(for: view, event: event)
    }

    // MARK: Вкладки знизу: порядок, прибирання, додавання
    var visibleTabs: [FDTab] { tabsCSV.split(separator: ",").compactMap { FDTab(rawValue: String($0)) } }
    var hiddenTabs: [FDTab] { FDTab.allCases.filter { !visibleTabs.contains($0) } }
    func saveTabs(_ l: [FDTab]) { tabsCSV = l.map(\.rawValue).joined(separator: ",") }
    func moveTab(_ raw: String, before target: FDTab) {
        guard let t = FDTab(rawValue: raw), t != target else { return }
        var l = visibleTabs; l.removeAll { $0 == t }
        let i = l.firstIndex(of: target) ?? l.count
        l.insert(t, at: i); saveTabs(l)
    }
    func shiftTab(_ t: FDTab, by d: Int) {
        var l = visibleTabs
        guard let i = l.firstIndex(of: t), l.indices.contains(i + d) else { return }
        l.swapAt(i, i + d); saveTabs(l)
    }
    func removeTab(_ t: FDTab) {
        var l = visibleTabs; l.removeAll { $0 == t }; saveTabs(l)
        if tab == t { tab = l.first ?? .dashboard }
    }

    var tabBar: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(visibleTabs) { t in
                        Button { tab = t } label: {
                            Text(LocalizedStringKey(t.rawValue)).font(.callout.weight(tab == t ? .semibold : .regular))
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(tab == t ? Color.accentColor.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: 6))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .draggable(t.rawValue)
                        .dropDestination(for: String.self) { items, _ in
                            if let r = items.first { moveTab(r, before: t) }
                            return true
                        }
                        .contextMenu {
                            Button("Відкрити в окремому вікні") { openWindow(id: "fdtab", value: t.rawValue) }
                            Divider()
                            Button("Перемістити ліворуч") { shiftTab(t, by: -1) }.disabled(visibleTabs.first == t)
                            Button("Перемістити праворуч") { shiftTab(t, by: 1) }.disabled(visibleTabs.last == t)
                            Divider()
                            Button("Прибрати вкладку", role: .destructive) { removeTab(t) }.disabled(visibleTabs.count <= 1)
                        }
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
            }
            Menu {
                if hiddenTabs.isEmpty { Text("Усі вкладки вже додано") }
                ForEach(hiddenTabs) { t in Button(lk(t.rawValue)) { saveTabs(visibleTabs + [t]); tab = t } }
                Divider()
                Button("Скинути до типових") { saveTabs(FDTab.allCases); }
            } label: { Image(systemName: "plus.circle").font(.system(size: 15)) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .padding(.horizontal, 10)
            .help("Додати вкладку. Перетягніть вкладку, щоб змінити порядок; правий клік: перемістити чи прибрати.")
        }
        .background(.regularMaterial)
    }

    @ViewBuilder var tabContent: some View {
        switch tab {
        case .dashboard: DashboardTab()
        case .actions: ActionsTab()
        case .messages: MessagesTab()
        case .params: ParamsView()
        case .video: VideoTab()
        case .preflight: PreFlightTab()
        case .status: StatusTab()
        case .servo: ServoRelayTab()
        case .aux: AuxTab()
        case .scripts: ScriptsTab()
        case .inspector: MavInspectorTab()
        case .ekf: EKFPanel()
        case .vibe: VibrationPanel()
        }
    }
}

/// Вкладка Flight Data в окремому вікні (правий клік по вкладці → «Відкрити в окремому вікні»).
struct FDTabWindow: View {
    let raw: String
    var body: some View {
        Group {
            switch FDTab(rawValue: raw) ?? .dashboard {
            case .dashboard: DashboardTab()
            case .actions: ActionsTab()
            case .messages: MessagesTab()
            case .params: ParamsView()
            case .video: VideoTab()
            case .preflight: PreFlightTab()
            case .status: StatusTab()
            case .servo: ServoRelayTab()
            case .aux: AuxTab()
            case .scripts: ScriptsTab()
            case .inspector: MavInspectorTab()
            case .ekf: EKFPanel()
            case .vibe: VibrationPanel()
            }
        }
        .frame(minWidth: 520, minHeight: 320)
        .navigationTitle(lk(raw))
    }
}

struct AspectModifier: ViewModifier {
    let ratio: CGFloat?
    func body(content: Content) -> some View {
        if let r = ratio { content.aspectRatio(r, contentMode: .fit) } else { content }
    }
}

struct PlaceholderTab: View {
    let icon: String, title: String, text: String
    var body: some View { ContentUnavailableView(title, systemImage: icon, description: Text(LocalizedStringKey(text))) }
}

// MARK: - Карта

/// Параметри карти в окремому спостережуваному об'єкті: панель перемикачів не перемальовується від 10-герцової телеметрії.
@Observable final class MapOptions {
    var autoPan = true
    var flyHere = false
    var showTrack = true
    var headingUp = false
    var layer: MapLayer = MapLayer(rawValue: UserDefaults.standard.string(forKey: "map.layer") ?? "") ?? .appleSat { didSet { UserDefaults.standard.set(layer.rawValue, forKey: "map.layer") } }
    var front = UserDefaults.standard.bool(forKey: "map.front") { didSet { UserDefaults.standard.set(front, forKey: "map.front") } }
    var rays = UserDefaults.standard.object(forKey: "map.rays") as? Bool ?? true { didSet { UserDefaults.standard.set(rays, forKey: "map.rays") } }
    var showRoute = UserDefaults.standard.object(forKey: "map.route") as? Bool ?? true { didSet { UserDefaults.standard.set(showRoute, forKey: "map.route") } }
}

struct MapToolbar: View {
    @Bindable var opt: MapOptions
    var body: some View {
        HStack(spacing: 10) {
            Toggle("Auto Pan", isOn: $opt.autoPan).toggleStyle(.checkbox).lineLimit(1).fixedSize()
            Toggle("Fly to here (double-click)", isOn: $opt.flyHere).toggleStyle(.checkbox).lineLimit(1).fixedSize()
            Toggle("Трек", isOn: $opt.showTrack).toggleStyle(.checkbox).lineLimit(1).fixedSize()
            Menu {
                ForEach(MapLayer.groups, id: \.0) { g in
                    Section(lk(g.0)) { ForEach(g.1) { l in Button { opt.layer = l } label: { if opt.layer == l { Label(LocalizedStringKey(l.title), systemImage: "checkmark") } else { Text(LocalizedStringKey(l.title)) } } } }
                }
                Divider()
                Toggle("Лінія фронту (DeepState)", isOn: $opt.front)
                Toggle("Напрямки борту: компас · GPS · гіро", isOn: $opt.rays)
                Toggle("Маршрут місії", isOn: $opt.showRoute)
            } label: { Label(LocalizedStringKey(opt.layer.barTitle), systemImage: "square.3.layers.3d").lineLimit(1) }
                .menuStyle(.borderlessButton).fixedSize()
        }
        .font(.caption)
        .padding(8)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.94), in: RoundedRectangle(cornerRadius: 8))   // без розмиття: матеріал над картою мерехтить
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
        .transaction { $0.animation = nil }
        .padding(8)
    }
}

struct MapPanel: View {
    @Environment(Store.self) var s
    @State private var ctl = MapController()
    @State private var opt = MapOptions()
    @State private var lastPan = Date.distantPast
    @State private var note: String?
    @State private var circles: [(CLLocationCoordinate2D, Double)] = []
    @State private var roi: CLLocationCoordinate2D?
    @State private var centered = false
    @State private var blockBox = BlockBox()
    @AppStorage("cam.fov") private var fov = 60.0
    private var front: FrontLine { FrontLine.shared }

    var body: some View {
        let hasFix = s.t.gpsFix >= 3
        let veh = CLLocationCoordinate2D(latitude: s.t.lat, longitude: s.t.lon)
        let mis = s.mission
        let routePins: [FlightMap.RoutePin] = opt.showRoute ? mis.items.enumerated().compactMap { i, it in it.hasPos ? FlightMap.RoutePin(id: it.id, lat: it.lat, lon: it.lon, label: String(i + 1), cmd: it.cmd) : nil } : []
        let curSeq = s.t.wpSeq
        let routeCur: UUID? = (opt.showRoute && s.connected && !mis.dirty && curSeq >= 1 && curSeq <= mis.items.count) ? mis.items[curSeq - 1].id : nil
        FlightMap(
            ctl: ctl, layer: opt.layer, showTrack: opt.showTrack, track: s.track,
            vehicle: hasFix ? veh : nil, vehicleHeading: s.t.heading,
            rays: hasFix ? RayData.current(yaw: s.t.yaw, magHdg: s.t.magHdg, cog: s.t.cog, speed: s.t.groundSpeed, rays: opt.rays) : nil,
            rulerA: s.mission.ruler.a, rulerB: s.mission.ruler.b, rulerLabel: s.mission.ruler.result.map { RulerLayer.distanceText($0.distance) + "  ·  " + String(format: "%03.0f°", $0.trueAz) } ?? "",
            home: s.t.homeSet ? .init(latitude: s.t.homeLat, longitude: s.t.homeLon) : nil,
            pois: s.poi.items, circles: circles,
            roiPoint: roi, roiLine: (roi != nil && hasFix) ? [veh, roi!] : [], roiPoly: (roi != nil && hasFix) ? footprint(from: veh, to: roi!) : [],
            front: opt.front ? front.polys : [], frontVersion: opt.front ? front.version : 0,
            flyHere: opt.flyHere,
            route: routePins, routePath: opt.showRoute ? mis.routeCoords : [], routeCurrent: routeCur,
            onContext: { c, v, e in showMenu(at: c, view: v, event: e) },
            onDouble: { c in flyTo(c, alt: nil) },
            onPinContext: { id, v, e in MissionOps(s: s).pinMenu(id: id, view: v, event: e, editable: false, openInMission: { s.navigate = "Mission" }) },
            blocked: { [blockBox] in blockBox.rects })
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(alignment: .topLeading) { toolbar.blockMap() }
        .overlay(alignment: .trailing) { MapControls(ctl: ctl).blockMap().padding(.trailing, 10) }
        .overlay(alignment: .top) {
            if let f = s.mission.following {
                HStack(spacing: 8) {
                    Image(systemName: "location.fill")
                    Text(LocalizedStringKey(f)).font(.caption.weight(.medium))
                    Button("Скасувати") { s.mission.followTask?.cancel(); s.mission.following = nil }.controlSize(.mini)
                }
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(Color(nsColor: .windowBackgroundColor).opacity(0.92), in: Capsule()).blockMap().padding(.top, 50)
            }
        }
        .overlay(alignment: .bottom) { bottomBar.blockMap() }
        .overlay(alignment: .bottomTrailing) { RulerPanel(ruler: s.mission.ruler).blockMap().padding(.trailing, 10).padding(.bottom, 46) }
        .coordinateSpace(name: "mapArea")
        .onPreferenceChange(BlockRectsKey.self) { blockBox.rects = $0 }
        .task(id: opt.front) {
            guard opt.front else { return }
            while !Task.isCancelled { await front.refresh(); try? await Task.sleep(nanoseconds: 600_000_000_000) }
        }
        .onChange(of: s.t.lat) { _, _ in
            guard opt.autoPan, s.t.gpsFix >= 3, Date().timeIntervalSince(lastPan) > 1 else { return }
            lastPan = Date()
            let c = CLLocationCoordinate2D(latitude: s.t.lat, longitude: s.t.lon)
            ctl.center(c, distance: centered ? nil : 500, heading: opt.headingUp ? s.t.heading : nil)
            centered = true
        }
    }

    var toolbar: some View { MapToolbar(opt: opt) }

    var bottomBar: some View {
        HStack(spacing: 14) {
            Text(Coords.pair(s.t.lat, s.t.lon, decimals: 7, sep: "  ")).font(.system(.caption, design: .monospaced))
            Text(String(format: loc("%.1f м"), s.t.altRel)).font(.system(.caption, design: .monospaced))
            if let n = note { Text(LocalizedStringKey(n)).font(.caption).foregroundStyle(.orange).lineLimit(1) }
            Spacer()
            Button("Clear Track") { s.track.removeAll() }.controlSize(.small)
            Button("До дрона") { centerOnVehicle() }.controlSize(.small)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.regularMaterial)
    }

    func centerOnVehicle() { if s.t.gpsFix >= 3 { ctl.center(.init(latitude: s.t.lat, longitude: s.t.lon), distance: 500) } }
    var defaultAlt: Double { s.t.altRel > 2 ? s.t.altRel : 10 }
    func fmt(_ c: CLLocationCoordinate2D) -> String { Coords.pair(c.latitude, c.longitude) }
    func post(_ path: String, _ msg: String) { EngineAPI.post(path) { ok, _ in note = ok ? msg : "Помилка команди" } }

    /// Приблизна область, яку бачить камера: трапеція навколо точки ROI за висотою, відстанню та полем зору.
    func footprint(from v: CLLocationCoordinate2D, to r: CLLocationCoordinate2D) -> [CLLocationCoordinate2D] {
        let mLat = 111_320.0, mLon = 111_320.0 * cos(v.latitude * .pi / 180)
        let dn = (r.latitude - v.latitude) * mLat, de = (r.longitude - v.longitude) * mLon
        let d = max(hypot(dn, de), 1)
        let h = max(s.t.altRel, 2)
        let ux = de / d, uy = dn / d                       // одиничний вектор «дрон → ROI»
        let hf = fov * .pi / 180, vf = hf * 9 / 16
        let dep = atan2(h, d)                              // кут нахилу камери вниз
        let near = max(h / tan(min(dep + vf / 2, 1.55)), 0)
        let far = h / tan(max(dep - vf / 2, 0.05))
        func halfW(_ dist: Double) -> Double { hypot(dist, h) * tan(hf / 2) }
        func pt(_ along: Double, _ side: Double) -> CLLocationCoordinate2D {
            let east = ux * along + (-uy) * side, north = uy * along + ux * side
            return CLLocationCoordinate2D(latitude: v.latitude + north / mLat, longitude: v.longitude + east / mLon)
        }
        let nearD = min(near, far), farD = min(max(far, near + 1), 3000)
        return [pt(nearD, -halfW(nearD)), pt(nearD, halfW(nearD)), pt(farD, halfW(farD)), pt(farD, -halfW(farD))]
    }

    // MARK: Дії

    func flyTo(_ c: CLLocationCoordinate2D, alt: Double?) {
        let a = alt ?? defaultAlt
        EngineAPI.post("/cmd/mode?m=4")                       // Guided
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { EngineAPI.post("/cmd/goto?lat=\(c.latitude)&lon=\(c.longitude)&alt=\(a)") }
        note = String(localized: "Fly to \(fmt(c)), \(Int(a)) м")
    }

    func askCoords(_ title: String, withAlt: Bool) -> (CLLocationCoordinate2D, Double)? {
        var fields = [(label: "Широта, довгота", value: s.t.gpsFix >= 3 ? Coords.pair(s.t.lat, s.t.lon) : "")]
        if withAlt { fields.append((label: "Висота, м", value: String(Int(defaultAlt)))) }
        guard let r = Prompt.ask(title, message: String(localized: "Формат: 50.450100, 30.523400"), fields: fields) else { return nil }
        let parts = r[0].replacingOccurrences(of: ";", with: ",").split(separator: ",").compactMap { Prompt.number(String($0)) }
        guard parts.count == 2, abs(parts[0]) <= 90, abs(parts[1]) <= 180 else { note = String(localized: "Некоректні координати"); return nil }
        let alt = withAlt ? (Prompt.number(r[1]) ?? defaultAlt) : defaultAlt
        return (CLLocationCoordinate2D(latitude: parts[0], longitude: parts[1]), alt)
    }

    func takeoff(alt: Double) {
        EngineAPI.post("/cmd/mode?m=4")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { EngineAPI.post("/cmd/arm") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) { EngineAPI.post("/cmd/takeoff?alt=\(alt)") }
        note = String(localized: "Зліт на \(Int(alt)) м: Guided → ARM → Takeoff")
    }

    // MARK: Меню

    func showMenu(at c: CLLocationCoordinate2D, view: NSView, event: NSEvent) {
        // лінійка чекає другу точку: цей клік належить їй, а не меню
        if s.mission.ruler.capturesClick { s.mission.ruler.place(c); return }
        let mb = MenuBuilder()
        mb.item("Виміряти відстань до…") { s.mission.ruler.start(at: c) }
        mb.separator()
        mb.item("Fly To Here") { flyTo(c, alt: nil) }
        mb.item("Fly To Here Alt") {
            if let r = Prompt.ask("Fly To Here Alt", message: fmt(c), fields: [("Висота, м", String(Int(defaultAlt)))]), let a = Prompt.number(r[0]) { flyTo(c, alt: a) }
        }
        mb.item("Fly To Coords") { if let (cc, a) = askCoords("Fly To Coords", withAlt: true) { flyTo(cc, alt: a) } }
        let ops = MissionOps(s: s)
        ops.poiMenu(mb, at: c) { p in ctl.center(.init(latitude: p.lat, longitude: p.lon), distance: 400); opt.autoPan = false }
        mb.item("Point Camera Here") { roi = c; post("/cmd/roi?lat=\(c.latitude)&lon=\(c.longitude)&alt=0", String(localized: "Камера націлена на \(fmt(c))")) }
        mb.item("Point Camera Coords") {
            if let (cc, a) = askCoords("Point Camera Coords", withAlt: true) { roi = cc; post("/cmd/roi?lat=\(cc.latitude)&lon=\(cc.longitude)&alt=\(a)", String(localized: "Камера націлена на \(fmt(cc))")) }
        }
        if roi != nil { mb.item("Скасувати ROI камери") { roi = nil; post("/cmd/roinone", "ROI скасовано") } }
        mb.item("Поле зору камери…") {
            if let r = Prompt.ask("Поле зору камери", message: String(localized: "Горизонтальний кут для відображення області на карті"), fields: [("Кут, °", String(Int(fov)))]), let v = Prompt.number(r[0]), v > 5, v < 170 { fov = v }
        }
        mb.item("Trigger Camera NOW") { post("/cmd/camtrigger", "Команду спуску затвора надіслано") }
        ops.missionSubmenu(mb, showRoute: opt.showRoute, toggleRoute: { opt.showRoute.toggle() }, openMission: { s.navigate = "Mission" })
        mb.submenu("Set Home Here") { m in
            mb.item("Home у цій точці", to: m) { post("/cmd/sethome?lat=\(c.latitude)&lon=\(c.longitude)", "Home: \(fmt(c))") }
            mb.item("Home у поточній позиції дрона", to: m) { post("/cmd/home", "Home у позиції дрона") }
        }
        mb.item("TakeOff") {
            if let r = Prompt.ask("TakeOff", message: String(localized: "Guided → ARM → зліт"), fields: [("Висота, м", "10")]), let a = Prompt.number(r[0]), a > 0 { takeoff(alt: a) }
        }
        mb.separator()
        mb.submenu("Шар карти") { m in
            for g in MapLayer.groups {
                for l in g.1 { mb.item(l.title, checked: opt.layer == l, to: m) { opt.layer = l } }
                if g.0 != MapLayer.groups.last!.0 { mb.separator(m) }
            }
            mb.separator(m)
            mb.item("Лінія фронту (DeepState)", checked: opt.front, to: m) { opt.front.toggle() }
            mb.item("Напрямки борту: компас · GPS · гіро", checked: opt.rays, to: m) { opt.rays.toggle() }
        }
        mb.submenu("Обертання карти") { m in
            mb.item("Північ угору", to: m) { opt.headingUp = false; ctl.setHeading(0) }
            mb.item("Курс дрона угору (стежити)", checked: opt.headingUp, to: m) { opt.headingUp.toggle(); if opt.headingUp { ctl.setHeading(s.t.heading) } }
            mb.item("Повернути на 90° ↺", to: m) { ctl.rotate(by: 90) }
            mb.item("Повернути на 90° ↻", to: m) { ctl.rotate(by: -90) }
        }
        mb.separator()
        mb.item("Draw Fence Dist") {
            if let r = Prompt.ask("Draw Fence Dist", message: String(localized: "Коло навколо Home (або вибраної точки)"), fields: [("Радіус, м", "100")]), let rad = Prompt.number(r[0]), rad > 0 {
                let center = s.t.homeSet ? CLLocationCoordinate2D(latitude: s.t.homeLat, longitude: s.t.homeLon) : c
                circles.append((center, rad)); note = String(localized: "Коло \(Int(rad)) м додано")
            }
        }
        if !circles.isEmpty { mb.item("Прибрати кола дистанції") { circles.removeAll() } }
        mb.show(for: view, event: event)
    }

    func nearestPOI(_ c: CLLocationCoordinate2D) -> Int? {
        s.poi.items.enumerated().min { a, b in
            hypot(a.element.lat - c.latitude, a.element.lon - c.longitude) < hypot(b.element.lat - c.latitude, b.element.lon - c.longitude)
        }?.offset
    }
}

// MARK: - Спільний стор для вкладок

struct LogItem: Decodable, Identifiable { let t: String; let sev: Int; let text: String; var id: String { t + text } }
struct LogDTO: Decodable { let seq: Int; let items: [LogItem] }
struct FieldDTO: Decodable, Equatable { let k: String; let v: String }
struct Alert: Identifiable { let id = UUID(); let text: String; let sev: Int; let at: Date }
struct TlogFile: Decodable, Identifiable { let name: String; let path: String; let size: Int; let date: String; var id: String { path } }

@Observable
final class FlightStore {
    var log: [LogItem] = []
    var fields: [FieldDTO] = []
    var tlogs: [TlogFile] = []
    var alerts: [Alert] = []          // критичні повідомлення, що показуються на HUD (≈20 с)
    @ObservationIgnored private var lastSeq = -1
    private var polling: Set<String> = []

    func poll(_ key: String, every ns: UInt64, _ block: @escaping @MainActor () async -> Void) {
        guard !polling.contains(key) else { return }
        polling.insert(key)
        Task { @MainActor in
            while polling.contains(key) { await block(); try? await Task.sleep(nanoseconds: ns) }
        }
    }
    func stop(_ key: String) { polling.remove(key) }

    func startLog() {
        poll("log", every: 1_000_000_000) {
            guard let d = await EngineAPI.get("/log", as: LogDTO.self) else { return }
            self.log = d.items
            if self.lastSeq >= 0 {
                let fresh = max(0, d.seq - self.lastSeq)
                for m in d.items.suffix(min(fresh, d.items.count)) where m.sev <= 4 {
                    self.alerts.removeAll { $0.text == m.text }          // повторне повідомлення оновлює таймер
                    self.alerts.append(Alert(text: m.text, sev: m.sev, at: Date()))
                }
            }
            self.lastSeq = d.seq
            self.alerts.removeAll { Date().timeIntervalSince($0.at) > 20 }
            if self.alerts.count > 5 { self.alerts.removeFirst(self.alerts.count - 5) }
        }
    }
    func startFields() { poll("fields", every: 600_000_000) { if let d = await EngineAPI.get("/fields", as: [FieldDTO].self) { self.fields = d } } }
    func startTlogs() { poll("tlogs", every: 3_000_000_000) { if let d = await EngineAPI.get("/logs", as: [TlogFile].self) { self.tlogs = d } } }
}

/// Прямокутники плаваючих елементів над картою; змінюються без перемальовування в'ю.
final class BlockBox { var rects: [CGRect] = [] }
