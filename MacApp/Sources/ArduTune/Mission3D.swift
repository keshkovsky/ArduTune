import SwiftUI
import SceneKit
import CoreLocation

/// Показники, які можна додавати на 3D-вигляд і прибирати.
struct M3DTile: Identifiable {
    let id: String
    let title: String
    let icon: String
    static let all: [M3DTile] = [
        .init(id: "agl", title: String(localized: "Висота над рельєфом"), icon: "mountain.2"),
        .init(id: "alt", title: String(localized: "Висота відносна (Home)"), icon: "arrow.up.to.line"),
        .init(id: "msl", title: String(localized: "Висота над морем"), icon: "water.waves"),
        .init(id: "hdg", title: String(localized: "Азимут польоту"), icon: "location.north.line"),
        .init(id: "gs", title: String(localized: "Швидкість по землі"), icon: "speedometer"),
        .init(id: "as", title: String(localized: "Повітряна швидкість"), icon: "wind"),
        .init(id: "vs", title: String(localized: "Вертикальна швидкість"), icon: "arrow.up.and.down"),
        .init(id: "wp", title: String(localized: "До наступної точки"), icon: "flag.checkered"),
        .init(id: "wpaz", title: String(localized: "Азимут на точку"), icon: "arrow.triangle.turn.up.right.diamond"),
        .init(id: "volt", title: String(localized: "Напруга батареї"), icon: "bolt.fill"),
        .init(id: "curr", title: String(localized: "Струм"), icon: "gauge.with.dots.needle.33percent"),
        .init(id: "used", title: String(localized: "Витрачено, мАг"), icon: "battery.50"),
        .init(id: "pct", title: String(localized: "Залишок заряду"), icon: "battery.75"),
        .init(id: "left", title: String(localized: "Орієнтовний залишок польоту"), icon: "timer"),
        .init(id: "thr", title: String(localized: "Газ"), icon: "dial.medium"),
        .init(id: "gps", title: String(localized: "GPS: супутники й HDOP"), icon: "location.fill"),
        .init(id: "rssi", title: "RSSI", icon: "antenna.radiowaves.left.and.right"),
        .init(id: "link", title: String(localized: "Якість зв'язку (пакетів/с)"), icon: "dot.radiowaves.left.and.right"),
        .init(id: "mode", title: String(localized: "Режим і ARM"), icon: "airplane"),
        .init(id: "vibe", title: String(localized: "Вібрація"), icon: "waveform.path.ecg"),
        .init(id: "ekf", title: String(localized: "Стан EKF"), icon: "checkmark.shield"),
    ]
    static let defaults = "agl,hdg,gs,wp,volt,curr,used,left,gps,rssi,mode"
}

/// Модель 3D-вигляду: завантажує рельєф і текстуру під маршрут і перебудовує сцену, коли маршрут виходить за область.
@Observable
final class Mission3DModel {
    var terrain: Terrain3D?
    var version = 0
    var status = ""
    var vexag = UserDefaults.standard.object(forKey: "m3d.vexag") as? Double ?? 2.0 { didSet { UserDefaults.standard.set(vexag, forKey: "m3d.vexag") } }
    var boost = UserDefaults.standard.object(forKey: "m3d.boost") as? Double ?? 2.5 { didSet { UserDefaults.standard.set(boost, forKey: "m3d.boost") } }
    /// Розмір позначок точок на екрані (1 = найбільші).
    var marker = UserDefaults.standard.object(forKey: "m3d.marker") as? Double ?? 1.0 { didSet { UserDefaults.standard.set(marker, forKey: "m3d.marker") } }
    var follow = false
    var locked = false
    var request = CameraRequest()
    var azimuth = 180.0          // оновлюється з камери (для куба)
    var elevation = 35.0
    var distance = 0.0
    func snap(az: Double, el: Double, resetDistance: Bool = false) {
        request = CameraRequest(token: request.token + 1, azimuth: az, elevation: el, resetDistance: resetDistance)
    }
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var builtLayer: MapLayer?
    @ObservationIgnored private var want = ""

    /// Перевіряє, що поточна область охоплює точки; інакше будує нову (із затримкою, щоб не перебудовувати під час перетягування).
    func ensure(points: [CLLocationCoordinate2D], layer: MapLayer) {
        guard !points.isEmpty else { return }
        let la = points.map(\.latitude), lo = points.map(\.longitude)
        let minLat = la.min()!, maxLat = la.max()!, minLon = lo.min()!, maxLon = lo.max()!
        if let t = terrain, builtLayer == layer {
            let mLat = (t.latMax - t.latMin) * 0.04, mLon = (t.lonMax - t.lonMin) * 0.04
            if minLat >= t.latMin + mLat, maxLat <= t.latMax - mLat, minLon >= t.lonMin + mLon, maxLon <= t.lonMax - mLon { return }
        }
        let key = String(format: "%.4f,%.4f,%.4f,%.4f,%@", minLat, maxLat, minLon, maxLon, "\(layer)")
        guard key != want else { return }
        want = key
        task?.cancel()
        task = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled, let self else { return }
            self.status = String(localized: "Завантаження рельєфу й текстури…")
            let t = await Terrain3D.build(minLat: minLat, maxLat: maxLat, minLon: minLon, maxLon: maxLon, layer: layer) { _ in }
            guard !Task.isCancelled else { return }
            self.terrain = t; self.builtLayer = layer; self.version += 1
            self.snap(az: 180, el: 35, resetDistance: true)
            self.status = t.ok ? "" : "Висоти недоступні (немає мережі?): показано плоску поверхню"
        }
    }
}

/// Висота верхньої панелі інструментів Mission (щоб показники й куб не накладались на неї).
struct TopInsetKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct Mission3DPane: View {
    @Environment(Store.self) var s
    let m: MissionStore
    let layer: MapLayer
    var topInset: CGFloat = 56
    @State private var model = Mission3DModel()
    @AppStorage("m3d.tilesOpen") private var tilesOpen = true
    @AppStorage("m3d.tiles") private var tilesCSV = M3DTile.defaults
    private var chosen: [String] { tilesCSV.split(separator: ",").map(String.init) }

    var route: Route3D {
        var r = Route3D()
        for (i, it) in m.items.enumerated() where it.hasPos && it.def.nav && it.group == nil {
            let b = MissionCatalog.badge(it.cmd)
            r.wps.append(.init(lat: it.lat, lon: it.lon, frame: it.frame, alt: it.alt, label: String(i + 1), cmd: it.cmd, icon: b.0, color: b.1))
        }
        if let h = m.home { r.home = (h.lat, h.lon) }
        else if s.t.homeSet { r.home = (s.t.homeLat, s.t.homeLon) }
        return r
    }

    /// Стан апарата: віртуальний (симуляція) або реальний з телеметрії.
    var vehicle: Vehicle3D? {
        let t = model.terrain
        let homeElev = route.home.flatMap { h in t?.elevation(lat: h.lat, lon: h.lon) } ?? t?.base ?? 0
        if let c = m.sim.current {
            let co = m.sim.coord(c)
            return Vehicle3D(lat: co.latitude, lon: co.longitude, msl: homeElev + c.alt, heading: m.sim.headingDeg, pitch: 0, roll: 0, plane: m.sim.params.plane)
        }
        guard s.connected, s.t.gpsFix >= 3, s.t.lat != 0 || s.t.lon != 0 else { return nil }
        let msl = s.t.altMsl != 0 ? s.t.altMsl : homeElev + s.t.altRel
        return Vehicle3D(lat: s.t.lat, lon: s.t.lon, msl: msl, heading: s.t.heading, pitch: s.t.pitch, roll: s.t.roll, plane: MissionSim.isPlane(s.t.vehicle))
    }

    var allPoints: [CLLocationCoordinate2D] {
        var p = route.wps.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
        if let h = route.home { p.append(.init(latitude: h.lat, longitude: h.lon)) }
        if let v = vehicle, p.isEmpty || p.contains(where: { hypot($0.latitude - v.lat, $0.longitude - v.lon) < 0.5 }) { p.append(.init(latitude: v.lat, longitude: v.lon)) }
        return p
    }

    var body: some View {
        let veh = vehicle
        ZStack {
            Scene3DView(terrain: model.terrain, terrainVersion: model.version, route: route, vexag: model.vexag, boost: model.boost, markerScale: model.marker, vehicle: veh,
                        follow: model.follow, locked: model.locked, request: model.request,
                        onCamera: { a, e, d in DispatchQueue.main.async { model.azimuth = a; model.elevation = e; model.distance = d } })
            if model.terrain == nil || !model.status.isEmpty {
                VStack(spacing: 8) {
                    if model.terrain == nil && model.status.isEmpty && allPoints.isEmpty {
                        Image(systemName: "cube.transparent").font(.system(size: 34)).foregroundStyle(.secondary)
                        Text("Додайте точки маршруту або дочекайтесь GPS-позиції апарата").font(.callout).foregroundStyle(.secondary)
                    } else {
                        if model.status == String(localized: "Завантаження рельєфу й текстури…") { ProgressView().controlSize(.small) }
                        Text(lk(model.status.isEmpty ? "Підготовка сцени…" : model.status)).font(.callout).foregroundStyle(.secondary)
                    }
                }
                .padding(14).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .overlay(alignment: .topLeading) { tilesPanel(veh).padding(.top, topInset + 16).padding(.leading, 12) }
        .overlay(alignment: .bottomTrailing) { controls.padding(12) }
        .overlay(alignment: .topTrailing) {
            OrbitCompass(azimuth: model.azimuth, elevation: model.elevation, locked: model.locked,
                     snap: { a, e in model.snap(az: a, el: e) }, toggleLock: { model.locked.toggle() })
                .padding(.top, 6).padding(.trailing, 8)
        }
        .task(id: allPoints.count) { model.ensure(points: allPoints, layer: layer) }
        .onChange(of: layer) { _, _ in model.ensure(points: allPoints, layer: layer) }
        .onChange(of: veh?.lat) { _, _ in
            // апарат поза поточною областю: перебудувати
            if let v = veh, model.terrain != nil { model.ensure(points: allPoints + [.init(latitude: v.lat, longitude: v.lon)], layer: layer) }
        }
        .onChange(of: m.items) { _, _ in model.ensure(points: allPoints, layer: layer) }
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: Керування виглядом
    var controls: some View {
        HStack(spacing: 8) {
            Menu {
                Section("Показники на екрані") {
                    ForEach(M3DTile.all) { t in
                        Toggle(lk(t.title), isOn: Binding(get: { chosen.contains(t.id) }, set: { on in
                            var l = chosen; if on { if !l.contains(t.id) { l.append(t.id) } } else { l.removeAll { $0 == t.id } }
                            tilesCSV = l.joined(separator: ",")
                        }))
                    }
                }
                Divider()
                Button("Типовий набір") { tilesCSV = M3DTile.defaults }
                Button("Прибрати всі") { tilesCSV = "" }
            } label: { Label("Показники", systemImage: "list.bullet.rectangle") }.menuStyle(.borderlessButton).fixedSize()
            Divider().frame(height: 16)
            Menu {
                Section("Масштаб рельєфу (вертикальне перебільшення)") {
                    ForEach([1.0, 2.0, 3.0, 5.0], id: \.self) { v in
                        Button { model.vexag = v } label: { if model.vexag == v { Label("×\(Int(v))", systemImage: "checkmark") } else { Text("×\(Int(v))") } }
                    }
                }
                Section("Розмір позначок точок") {
                    ForEach([(0.4, "Дрібні"), (0.6, "Малі"), (0.8, "Середні"), (1.0, "Великі")], id: \.0) { v, name in
                        Button { model.marker = v } label: { if model.marker == v { Label(LocalizedStringKey(name), systemImage: "checkmark") } else { Text(LocalizedStringKey(name)) } }
                    }
                }
                Section("Висота точок над землею (підсилення)") {
                    ForEach([1.0, 2.5, 4.0], id: \.self) { v in
                        Button { model.boost = v } label: {
                            let t = v == 2.5 ? "×2.5" : "×\(Int(v))"
                            if model.boost == v { Label(LocalizedStringKey(t), systemImage: "checkmark") } else { Text(LocalizedStringKey(t)) }
                        }
                    }
                }
            } label: {
                Label("Масштаб", systemImage: "mountain.2")
            }
            .menuStyle(.borderlessButton).fixedSize()
            .help("Масштаб рельєфу ×\(Int(model.vexag)) і підсилення висоти точок ×\(model.boost == 2.5 ? "2.5" : String(Int(model.boost)))")
            Toggle(isOn: Binding(get: { model.follow }, set: { model.follow = $0 })) { Image(systemName: "scope") }.toggleStyle(.button).help("Слідувати за апаратом: камера тримає його в центрі й рухається разом з ним (потрібна GPS-позиція або симуляція)")
            Button { model.snap(az: 180, el: 35, resetDistance: true) } label: { Image(systemName: "arrow.counterclockwise") }.help("Скинути камеру")
        }
        .controlSize(.small)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.9), in: Capsule())
        .overlay(Capsule().strokeBorder(.quaternary))
    }

    // MARK: Показники
    func bearing(from v: Vehicle3D, to lat: Double, lon: Double) -> Double {
        MapRuler.bearing(.init(latitude: v.lat, longitude: v.lon), .init(latitude: lat, longitude: lon))
    }
    var nextWP: MissionItem? {
        let seq = s.connected && !m.dirty ? s.t.wpSeq : 0
        if seq >= 1, seq <= m.items.count, m.items[seq - 1].hasPos { return m.items[seq - 1] }
        if let c = m.sim.current, c.item >= 0, c.item < m.items.count, m.items[c.item].hasPos { return m.items[c.item] }
        return nil
    }
    func remaining() -> (minutes: Double?, note: String) {
        let t = s.t
        guard t.batteryA > 0.5 else { return (nil, "немає струму") }
        var capacity = s.ps.val("BATT_CAPACITY") ?? 0
        if capacity <= 0, t.mahUsed > 50, t.batteryPct > 0, t.batteryPct < 100 { capacity = t.mahUsed / (1 - Double(t.batteryPct) / 100) }
        guard capacity > 0 else { return (nil, "ємність невідома") }
        let rest = t.batteryPct > 0 ? capacity * Double(t.batteryPct) / 100 : max(0, capacity - t.mahUsed)
        return (rest / (t.batteryA * 1000) * 60, "")
    }

    func value(_ id: String, _ veh: Vehicle3D?) -> (String, Color?)? {
        let t = s.t
        let ground = veh.flatMap { v in model.terrain.map { $0.elevation(lat: v.lat, lon: v.lon) } }
        switch id {
        case "agl":
            guard let v = veh, let g = ground, model.terrain?.ok == true else { return (Units.alt(t.altRel) + loc(" (відн.)"), nil) }
            let a = v.msl - g
            return (Units.alt(a), a < 15 ? .red : (a < 30 ? .orange : nil))
        case "alt": return (Units.alt(m.sim.current?.alt ?? t.altRel), nil)
        case "msl": return (Units.alt(veh?.msl ?? t.altMsl), nil)
        case "hdg": return (String(format: "%03.0f°", veh?.heading ?? t.heading), nil)
        case "gs": return (Units.speed(m.sim.current?.spd ?? t.groundSpeed), nil)
        case "as": return (Units.speed(m.sim.current?.air ?? t.airSpeed), nil)
        case "vs": return (String(format: loc("%+.1f м/с"), t.climb), nil)
        case "wp":
            if let w = nextWP, let v = veh {
                let d = CLLocation(latitude: v.lat, longitude: v.lon).distance(from: CLLocation(latitude: w.lat, longitude: w.lon))
                return (Units.dist(d) + String(format: " (№%d)", (m.items.firstIndex { $0.id == w.id } ?? 0) + 1), nil)
            }
            return t.wpDist > 0 ? (Units.dist(t.wpDist), nil) : ("—", nil)
        case "wpaz":
            if let w = nextWP, let v = veh { return (String(format: "%03.0f°", bearing(from: v, to: w.lat, lon: w.lon)), nil) }
            return ("—", nil)
        case "volt": return (String(format: loc("%.2f В"), t.batteryV), t.batteryPct > 0 && t.batteryPct < 20 ? .red : nil)
        case "curr": return (String(format: loc("%.1f А"), t.batteryA), nil)
        case "used": return (String(format: loc("%.0f мАг"), t.mahUsed), nil)
        case "pct": return ("\(max(0, t.batteryPct)) %", t.batteryPct > 0 && t.batteryPct < 20 ? .red : nil)
        case "left":
            let r = remaining()
            guard let mm = r.minutes else { return ("— (\(loc(r.note)))", .secondary) }
            return (mm >= 60 ? String(format: loc("~%d год %02d хв"), Int(mm) / 60, Int(mm) % 60) : String(format: loc("~%.0f хв"), mm), mm < 4 ? .red : (mm < 8 ? .orange : nil))
        case "thr": return (String(format: "%.0f %%", t.throttle), nil)
        case "gps":
            let fix = t.gpsFix >= 3 ? String(localized: "\(t.sats) сат.") : "немає фіксації"
            return ("\(fix) · HDOP " + (t.hdop > 0 && t.hdop < 99 ? String(format: "%.1f", t.hdop) : "—"), t.gpsFix >= 3 ? nil : .red)
        case "rssi": return (t.rssi > 0 ? String(format: "%.0f", t.rssi) : "—", nil)
        case "link": return (String(format: loc("%.0f пак./с"), t.msgRate), t.msgRate < 5 ? .red : nil)
        case "mode": return ("\(t.mode ?? "—") · " + (t.armed ? "ARMED" : "DISARMED"), t.armed ? .orange : nil)
        case "vibe": let v = max(t.vibeX, t.vibeY, t.vibeZ); return (String(format: loc("%.1f м/с²"), v), v >= 30 ? .red : (v >= 15 ? .orange : nil))
        case "ekf": let ok = (t.ekfFlags & 7) == 7; return (ok ? "OK" : "перевірте", ok ? nil : .red)
        default: return nil
        }
    }

    func tilesPanel(_ veh: Vehicle3D?) -> some View {
        let list = chosen.compactMap { id in M3DTile.all.first { $0.id == id } }
        return VStack(alignment: .leading, spacing: 5) {
            Button { withAnimation(.snappy(duration: 0.2)) { tilesOpen.toggle() } } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).rotationEffect(.degrees(tilesOpen ? 0 : -90)).frame(width: 16)
                    Text("Показники").font(.caption2.weight(.semibold))
                    Spacer(minLength: 0)
                    Text("\(list.count)").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 7).padding(.vertical, 1).background(Color.white.opacity(0.22), in: Capsule())
                }
                .foregroundStyle(.primary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).help(lk(tilesOpen ? "Згорнути панель показників" : "Розгорнути панель показників"))
            if tilesOpen {
                ForEach(list) { tile in
                    if let v = value(tile.id, veh) {
                        HStack(spacing: 8) {
                            Image(systemName: tile.icon).foregroundStyle(.secondary).frame(width: 16)
                            Text(LocalizedStringKey(tile.title)).font(.caption2).foregroundStyle(.secondary).frame(width: 140, alignment: .leading)
                            Text(LocalizedStringKey(v.0)).font(.system(.callout, design: .monospaced).weight(.semibold)).foregroundStyle(v.1 ?? .primary)
                        }
                    }
                }
            }
        }
        .padding(10)
        .frame(minWidth: tilesOpen ? nil : 0)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.78), in: RoundedRectangle(cornerRadius: 10))
        .fixedSize()
    }
}
