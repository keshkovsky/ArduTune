import SwiftUI
import MapKit
import Charts
import Observation

// MARK: - Керування симуляцією польоту по місії (опція в розділі Mission)

@Observable
final class MissionSim {
    var enabled = false
    var kind = 0                       // 0 авто, 1 Copter, 2 Plane
    var cruiseOverride = 0.0           // 0 = із параметрів польотника
    var windSpeed = UserDefaults.standard.double(forKey: "sim.windSpeed") { didSet { UserDefaults.standard.set(windSpeed, forKey: "sim.windSpeed") } }
    var windFrom = UserDefaults.standard.double(forKey: "sim.windFrom") { didSet { UserDefaults.standard.set(windFrom, forKey: "sim.windFrom") } }
    var result = SimResult()
    var params = SimParams()
    var t = 0.0
    var playing = false
    var rate = 4.0
    var version = 0                    // змінюється при перерахунку (для перемальовування траєкторії)
    var status = ""
    var mode = "Auto"                     // режим віртуального апарата (підсвічується в панелі «Керування»)
    var note = ""                         // відповідь на останню команду
    @ObservationIgnored private var lastItems: [SimItem] = []
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var sig = ""
    // Рельєф уздовж справжньої траєкторії симуляції
    var ground: [(t: Double, g: Double)] = []          // висота рельєфу відносно Home
    var clearance: Double?                              // мінімальний просвіт над землею, м
    var clearAt = 0.0                                   // коли (с симуляції)
    var dangerSegs: [[CLLocationCoordinate2D]] = []     // ділянки траєкторії нижче безпечної висоти
    var terrainStatus = ""
    @ObservationIgnored private var tTask: Task<Void, Never>?

    var duration: Double { result.duration }
    var hasData: Bool { result.samples.count > 1 }

    static func isPlane(_ vehicle: String?) -> Bool { (vehicle ?? "").contains("FIXED_WING") || (vehicle ?? "").contains("VTOL") }

    /// Параметри польотника (або типові значення), що визначають швидкості симуляції.
    func makeParams(ps: ParamStore, vehicle: String?, home: HomePoint?, first: MissionItem?) -> SimParams? {
        var p = SimParams()
        p.plane = kind == 2 || (kind == 0 && Self.isPlane(vehicle))
        func v(_ n: String) -> Double? { ps.find(n)?.value }
        if p.plane {
            p.cruise = (v("AIRSPEED_CRUISE") ?? v("TRIM_ARSPD_CM").map { $0 / 100 }) ?? 18
            if p.cruise <= 0 { p.cruise = 18 }
            p.climb = min(v("TECS_CLMB_MAX") ?? 5, 6); p.descent = min(v("TECS_SINK_MAX") ?? 5, 6)
            p.bank = min((v("ROLL_LIMIT_DEG") ?? v("LIM_ROLL_CD").map { $0 / 100 }) ?? 35, 45)
        } else {
            p.cruise = (v("WPNAV_SPEED").map { $0 / 100 }) ?? 5
            p.climb = (v("WPNAV_SPEED_UP").map { $0 / 100 }) ?? 2.5
            p.descent = (v("WPNAV_SPEED_DN").map { $0 / 100 }) ?? 1.5
        }
        if cruiseOverride > 0 { p.cruise = cruiseOverride }
        p.windSpeed = max(0, windSpeed); p.windFrom = windFrom
        if let h = home { p.homeLat = h.lat; p.homeLon = h.lon; p.homeAlt = h.alt }
        else if let f = first { p.homeLat = f.lat; p.homeLon = f.lon }
        else { return nil }
        return p
    }

    func rebuild(items: [MissionItem], home: HomePoint?, ps: ParamStore, vehicle: String?) {
        guard let p = makeParams(ps: ps, vehicle: vehicle, home: home, first: items.first { $0.hasPos }) else {
            result = SimResult(); params = SimParams(); status = String(localized: "Немає Home або точок з координатами"); version += 1; return
        }
        params = p
        mode = "Auto"; note = ""
        let list = items.map { SimItem(cmd: $0.cmd, frame: $0.frame, p1: $0.p1, p2: $0.p2, p3: $0.p3, p4: $0.p4, lat: $0.lat, lon: $0.lon, alt: $0.alt) }
        lastItems = list
        let r = MissionSimEngine.run(list, p)
        result = r; t = min(t, r.duration); version += 1
        status = r.samples.count > 1 ? "" : "Нічого симулювати"
        loadTerrain()
    }

    /// Рельєф під траєкторією: просвіт над землею вздовж справжнього шляху (дуги, кружляння), а не лише між точками плану.
    func loadTerrain() {
        tTask?.cancel()
        let s = result.samples, p = params
        guard s.count > 1 else { ground = []; clearance = nil; dangerSegs = []; terrainStatus = ""; return }
        let n = min(s.count, 240)
        let idx = (0..<n).map { Int((Double($0) * Double(s.count - 1) / Double(max(n - 1, 1))).rounded()) }
        var coords = idx.map { MissionSimEngine.geo(x: s[$0].x, y: s[$0].y, p: p) }
        coords.append((p.homeLat, p.homeLon))
        terrainStatus = String(localized: "Завантаження рельєфу…")
        let minAGL = UserDefaults.standard.object(forKey: "mission.minAGL") as? Double ?? 30
        tTask = Task { @MainActor [weak self] in
            let el = await ElevationService.shared.elevations(coords)
            guard let self, !Task.isCancelled else { return }
            guard let homeElev = el.last ?? nil, !el.contains(where: { $0 == nil }) else {
                self.ground = []; self.clearance = nil; self.dangerSegs = []
                self.terrainStatus = String(localized: "Рельєф недоступний (немає мережі?)")
                return
            }
            var g: [(Double, Double)] = []; var minC: Double?; var at = 0.0
            var segs: [[CLLocationCoordinate2D]] = []; var cur: [CLLocationCoordinate2D] = []
            for (k, i) in idx.enumerated() {
                let rel = (el[k] ?? homeElev) - homeElev
                g.append((s[i].t, rel))
                let c = s[i].alt - rel
                let low = s[i].alt >= 8                     // зліт і посадка біля землі не рахуємо
                if low, minC == nil || c < minC! { minC = c; at = s[i].t }
                let pt = CLLocationCoordinate2D(latitude: coords[k].0, longitude: coords[k].1)
                if low && c < minAGL { cur.append(pt) } else { if cur.count > 1 { segs.append(cur) }; cur = [] }
            }
            if cur.count > 1 { segs.append(cur) }
            self.ground = g; self.clearance = minC; self.clearAt = at; self.dangerSegs = segs
            self.terrainStatus = ""
            self.version += 1
        }
    }

    /// Підпис входів, за зміни якого потрібен перерахунок.
    func signature(items: [MissionItem], home: HomePoint?, ps: ParamStore, vehicle: String?) -> String {
        var h = Hasher()
        for i in items { h.combine(i.cmd); h.combine(i.frame); h.combine(i.p1); h.combine(i.p2); h.combine(i.p3); h.combine(i.p4); h.combine(i.lat); h.combine(i.lon); h.combine(i.alt) }
        h.combine(home?.lat); h.combine(home?.lon); h.combine(home?.alt); h.combine(kind); h.combine(cruiseOverride); h.combine(windSpeed); h.combine(windFrom); h.combine(Self.isPlane(vehicle))
        for n in ["WPNAV_SPEED", "WPNAV_SPEED_UP", "WPNAV_SPEED_DN", "AIRSPEED_CRUISE", "TRIM_ARSPD_CM", "TECS_CLMB_MAX", "TECS_SINK_MAX", "ROLL_LIMIT_DEG", "LIM_ROLL_CD"] { h.combine(ps.find(n)?.value) }
        return String(h.finalize())
    }

    // MARK: Відтворення
    func play() {
        guard hasData, !playing else { return }
        if t >= duration { t = 0 }
        playing = true
        task = Task { @MainActor [weak self] in
            var last = Date()
            while let s = self, !Task.isCancelled, s.playing {
                try? await Task.sleep(nanoseconds: 100_000_000)
                let n = Date()
                s.t = min(s.duration, s.t + n.timeIntervalSince(last) * s.rate); last = n
                if s.t >= s.duration { s.playing = false }
            }
        }
    }
    func pause() { playing = false; task?.cancel() }
    func toggle() { playing ? pause() : play() }
    func restart() { t = 0 }
    func close() { pause(); enabled = false }

    // MARK: Команди оператора
    var active: Bool { enabled && hasData }
    /// Номер поточного пункту плану (індекс з нуля); -1, якщо ще не почато.
    var currentIndex: Int { current?.item ?? -1 }

    /// Застосовує команду з поточного моменту: хвіст симуляції перераховується, відтворення триває.
    func command(_ c: SimCommand, mode newMode: String, text: String) {
        guard active, let st = sample(at: t) else { return }
        let before = result.notes
        var r = MissionSimEngine.resume(result, at: st, items: lastItems, params, c)
        r.notes = Array(Set(before + r.notes)).sorted()
        result = r; mode = newMode; note = text; version += 1
        if !playing { play() }
    }
    func goTo(_ c: CLLocationCoordinate2D, alt: Double?, loiter: Bool) {
        let a = alt ?? ((current?.alt ?? 0) > 2 ? current!.alt : 50)
        command(.goTo(lat: c.latitude, lon: c.longitude, alt: a, loiter: loiter), mode: loiter ? "Loiter" : "Guided", text: loiter ? "Лечу до точки й зависаю" : "Лечу до точки (Guided)")
    }
    func auto(from index: Int?) { command(.auto(from: index ?? max(currentIndex, 0)), mode: "Auto", text: String(localized: "Виконую місію")) }
    func loiterHere(_ name: String = "Loiter") { command(.loiterHere, mode: name, text: name == "Guided" ? "Утримую позицію (Guided)" : "Зависаю на місці") }
    func rtl() { command(.rtl, mode: "RTL", text: String(localized: "Повертаюсь додому")) }
    func straight() { command(.straight, mode: "FBWA", text: String(localized: "Лечу прямо (FBWA без пілота)")) }
    func land() { command(.landHere, mode: "Land", text: String(localized: "Сідаю")) }
    func step(_ d: Int, count: Int) { guard count > 0 else { return }; auto(from: min(max(currentIndex + d, 0), count - 1)) }

    // MARK: Поточний стан
    func sample(at time: Double) -> SimSample? {
        let s = result.samples
        guard let first = s.first else { return nil }
        if time <= first.t { return first }
        guard let last = s.last, time < last.t else { return s.last }
        var lo = 0, hi = s.count - 1
        while hi - lo > 1 { let mid = (lo + hi) / 2; if s[mid].t <= time { lo = mid } else { hi = mid } }
        let a = s[lo], b = s[hi]
        let f = (time - a.t) / max(b.t - a.t, 1e-6)
        var dh = (b.hdg - a.hdg).truncatingRemainder(dividingBy: 2 * .pi)
        if dh > .pi { dh -= 2 * .pi } else if dh < -.pi { dh += 2 * .pi }
        return SimSample(t: time, x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f, alt: a.alt + (b.alt - a.alt) * f, hdg: a.hdg + dh * f, spd: a.spd + (b.spd - a.spd) * f, item: a.item, dist: a.dist + (b.dist - a.dist) * f, air: a.air + (b.air - a.air) * f, cr: a.cr)
    }
    func coord(_ s: SimSample) -> CLLocationCoordinate2D {
        let (la, lo) = MissionSimEngine.geo(x: s.x, y: s.y, p: params)
        return .init(latitude: la, longitude: lo)
    }
    var current: SimSample? { enabled && hasData ? sample(at: t) : nil }
    var headingDeg: Double { ((current?.hdg ?? 0) * 180 / .pi).truncatingRemainder(dividingBy: 360) }

    /// Траєкторія для карти (проріджена до ~1500 точок).
    var track: [CLLocationCoordinate2D] {
        guard enabled, hasData else { return [] }
        let s = result.samples; let step = max(1, s.count / 1500)
        return stride(from: 0, to: s.count, by: step).map { coord(s[$0]) } + [coord(s[s.count - 1])]
    }
}

// MARK: - Панель симуляції

struct MissionSimPanel: View {
    @Environment(Store.self) var s
    @Bindable var sim: MissionSim
    let m: MissionStore

    @AppStorage("mission.minAGL") private var minAGL = 30.0

    static func clock(_ t: Double) -> String { String(format: "%d:%02d", Int(t) / 60, Int(t) % 60) }

    var body: some View {
        let cur = sim.current
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button { sim.toggle() } label: { Image(systemName: sim.playing ? "pause.fill" : "play.fill").frame(width: 18) }
                    .buttonStyle(.borderedProminent).controlSize(.small).disabled(!sim.hasData)
                Button { sim.restart() } label: { Image(systemName: "backward.end.fill") }.controlSize(.small).disabled(!sim.hasData).help("На початок")
                Slider(value: Binding(get: { sim.t }, set: { sim.t = $0 }), in: 0...max(sim.duration, 1))
                    .disabled(!sim.hasData)
                Text("\(Self.clock(sim.t)) / \(Self.clock(sim.duration))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Menu("×\(Int(sim.rate))") {
                    ForEach([1.0, 2, 4, 8, 16, 32, 64], id: \.self) { r in Button("×\(Int(r))") { sim.rate = r } }
                }.menuStyle(.borderlessButton).fixedSize().help("Швидкість відтворення")
                Button { sim.close() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain).help("Вимкнути симуляцію")
            }
            HStack(spacing: 10) {
                Picker("", selection: $sim.kind) { Text("Авто").tag(0); Text("Copter").tag(1); Text("Plane").tag(2) }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 170)
                HStack(spacing: 3) {
                    Image(systemName: "speedometer").foregroundStyle(.secondary)
                    TextField("авто", value: $sim.cruiseOverride, format: .number.precision(.fractionLength(0...1)))
                        .textFieldStyle(.roundedBorder).frame(width: 46).multilineTextAlignment(.trailing)
                    Text("м/с").foregroundStyle(.secondary)
                }.help("Крейсерська швидкість; 0 = із параметрів (\(sim.params.plane ? "AIRSPEED_CRUISE" : "WPNAV_SPEED")): зараз \(String(format: "%.1f", sim.params.cruise)) м/с")
                HStack(spacing: 3) {
                    Image(systemName: "wind").foregroundStyle(.secondary)
                    TextField("0", value: $sim.windSpeed, format: .number.precision(.fractionLength(0...1)))
                        .textFieldStyle(.roundedBorder).frame(width: 42).multilineTextAlignment(.trailing)
                    Text("м/с з").foregroundStyle(.secondary)
                    TextField("0", value: $sim.windFrom, format: .number.precision(.fractionLength(0)))
                        .textFieldStyle(.roundedBorder).frame(width: 44).multilineTextAlignment(.trailing)
                    Text("°").foregroundStyle(.secondary)
                }.help("Вітер: швидкість і напрямок, ЗВІДКИ дме (0° = північний). Діє лише на літак у повітрі.")
                Spacer(minLength: 0)
            }
            if let c = cur {
                HStack(spacing: 14) {
                    stat("arrow.up.to.line", Units.alt(c.alt))
                    stat("speedometer", sim.windSpeed > 0 && sim.params.plane ? "GS " + Units.speedNum(c.spd, digits: 0) + " · AS " + Units.speed(c.air, digits: 0) : Units.speed(c.spd))
                    if c.item >= 0 { stat("flag", String(localized: "точка \(c.item + 1)")) }
                    Spacer(minLength: 0)
                }
            }
            if sim.hasData {
                Chart {
                    ForEach(Array(stride(from: 0, to: sim.result.samples.count, by: max(1, sim.result.samples.count / 300))), id: \.self) { i in
                        let p = sim.result.samples[i]
                        AreaMark(x: .value("t", p.t), y: .value("alt", p.alt), series: .value("s", "alt")).foregroundStyle(Color.accentColor.opacity(0.18))
                        LineMark(x: .value("t", p.t), y: .value("alt", p.alt), series: .value("s", "alt")).foregroundStyle(Color.accentColor)
                    }
                    ForEach(Array(sim.ground.enumerated()), id: \.offset) { _, g in
                        AreaMark(x: .value("t", g.t), yStart: .value("низ", min(0, g.g)), yEnd: .value("рельєф", g.g), series: .value("s", "gnd")).foregroundStyle(Color.brown.opacity(0.35))
                    }
                    RuleMark(x: .value("t", sim.t)).foregroundStyle(.orange)
                }
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 5)) { v in AxisValueLabel { if let d = v.as(Double.self) { Text(lk(Self.clock(d))).font(.caption2) } } } }
                .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 2)) { _ in AxisValueLabel().font(.caption2) } }
                .frame(height: 46)
                HStack(spacing: 12) {
                    stat("clock", Self.clock(sim.duration))
                    stat("ruler", Units.dist(sim.result.distance))
                    stat("arrow.up.to.line.compact", loc("макс. ") + Units.alt(sim.result.maxAlt))
                    stat("bolt", loc("макс. ") + Units.speed(sim.result.maxSpeed))
                    if let c = sim.clearance {
                        let low = c < minAGL
                        HStack(spacing: 3) {
                            Image(systemName: low ? "exclamationmark.triangle.fill" : "mountain.2").foregroundStyle(low ? Color.red : Color.secondary)
                            Text(lk(loc("над землею мін. ") + Units.alt(c))).monospacedDigit().foregroundStyle(low ? Color.red : Color.primary)
                        }.font(.caption).help("Мінімальний просвіт над рельєфом уздовж траєкторії (без зльоту й посадки); безпечна висота \(Int(minAGL)) м з профілю висоти")
                    } else if !sim.terrainStatus.isEmpty {
                        Text(LocalizedStringKey(sim.terrainStatus)).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "info.circle").font(.caption).foregroundStyle(.tertiary)
                        .help("Спрощена кінематика: постійний вітер, без фізики прошивки й турбулентності")
                }
            } else {
                Text(lk(sim.status.isEmpty ? "Розрахунок…" : sim.status)).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(sim.result.notes, id: \.self) { n in
                Label(LocalizedStringKey(n), systemImage: "info.circle").font(.caption2).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(width: 640)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.95), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
        .transaction { $0.animation = nil }
        .task(id: sim.signature(items: m.items, home: m.home, ps: s.ps, vehicle: s.t.vehicle)) {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if Task.isCancelled { return }
            sim.rebuild(items: m.items, home: m.home, ps: s.ps, vehicle: s.t.vehicle)
        }
    }
    func stat(_ icon: String, _ v: String) -> some View {
        HStack(spacing: 3) { Image(systemName: icon).foregroundStyle(.secondary); Text(LocalizedStringKey(v)).monospacedDigit().lineLimit(1) }.font(.caption).fixedSize()
    }
}
