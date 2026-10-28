import SwiftUI
import MapKit
import AppKit

/// Параметри сектора антени на мапі: від станції в бік азимута на задану відстань.
struct BeamSpec: Equatable {
    var origin: CLLocationCoordinate2D
    var azimuth: Double          // °, від півночі, з поправкою
    var width: Double            // °, повний кут розкриття
    var range: Double            // м
    var colorHex: String
    var fill: Double
    var stroke: Double
    static func == (a: BeamSpec, b: BeamSpec) -> Bool {
        a.origin.latitude == b.origin.latitude && a.origin.longitude == b.origin.longitude && a.azimuth == b.azimuth && a.width == b.width
            && a.range == b.range && a.colorHex == b.colorHex && a.fill == b.fill && a.stroke == b.stroke
    }
}

/// Керування антенним трекером і сектор антени на мапі Flight Data.
///
/// Прошивка AntennaTracker сама наводиться в режимі Auto на позицію, яку їй надсилає апарат (GLOBAL_POSITION_INT від SYSID_TARGET).
/// Якщо апарат не має навігації, ArduTune надсилає трекеру позицію, вказану на мапі («борт тут»). У режимі Guided трекер
/// слухається абсолютного напряму (SET_ATTITUDE_TARGET: азимут і кут місця), яким керують клавіші зі стрілками.
@Observable
final class TrackerStore {
    static let shared = TrackerStore()
    private static let ud = UserDefaults.standard

    // Сектор антени
    var beamOn = ud.object(forKey: "trk.beam.on") as? Bool ?? true { didSet { Self.ud.set(beamOn, forKey: "trk.beam.on") } }
    var beamWidth = ud.object(forKey: "trk.beam.width") as? Double ?? 30 { didSet { Self.ud.set(beamWidth, forKey: "trk.beam.width") } }
    var beamRange = ud.object(forKey: "trk.beam.range") as? Double ?? 1500 { didSet { Self.ud.set(beamRange, forKey: "trk.beam.range") } }
    var beamColor = ud.string(forKey: "trk.beam.color") ?? "#30B0C7" { didSet { Self.ud.set(beamColor, forKey: "trk.beam.color") } }
    var beamFill = ud.object(forKey: "trk.beam.fill") as? Double ?? 0.2 { didSet { Self.ud.set(beamFill, forKey: "trk.beam.fill") } }
    var beamStroke = ud.object(forKey: "trk.beam.stroke") as? Double ?? 0.45 { didSet { Self.ud.set(beamStroke, forKey: "trk.beam.stroke") } }
    /// Поправка азимута, °: антена фактично дивиться на цю величину правіше (+) чи лівіше (−) за розрахунковий напрям.
    var azOffset = ud.object(forKey: "trk.azoff") as? Double ?? 0 { didSet { Self.ud.set(azOffset, forKey: "trk.azoff") } }

    // Ручна ціль («борт тут»)
    var target: CLLocationCoordinate2D?
    var targetAlt = ud.object(forKey: "trk.target.alt") as? Double ?? 100 { didSet { Self.ud.set(targetAlt, forKey: "trk.target.alt") } }
    var feed = ud.object(forKey: "trk.feed") as? Bool ?? true { didSet { Self.ud.set(feed, forKey: "trk.feed") } }

    // Керування клавішами
    var keys = false
    var step = ud.object(forKey: "trk.step") as? Double ?? 5 { didSet { Self.ud.set(step, forKey: "trk.step") } }
    /// Заданий напрям (Guided на трекері або лише на мапі, якщо трекер не підключено).
    var aimAz: Double?
    var aimEl: Double = 0
    var note = ""

    @ObservationIgnored weak var store: Store?
    @ObservationIgnored private var timer: Timer?

    var connectedTracker: Bool { store?.connected == true && store?.t.vehicle == "ANTENNA_TRACKER" }

    // MARK: Позиція станції й напрям

    /// Позиція антени: GPS трекера, START_LATITUDE/LONGITUDE трекера або джерело зі StationStore.
    func station(_ s: Store, home: CLLocationCoordinate2D?) -> CLLocationCoordinate2D? {
        if connectedTracker {
            if s.t.gpsFix >= 3 { return .init(latitude: s.t.lat, longitude: s.t.lon) }
            if let la = s.ps.val("START_LATITUDE"), let lo = s.ps.val("START_LONGITUDE"), abs(la) > 1e-6 || abs(lo) > 1e-6 { return .init(latitude: la, longitude: lo) }
        }
        return StationStore.shared.coordinate(home: home)
    }

    /// Азимут осі променя (без поправки): фактичний курс антени трекера, заданий вручну або розрахований на ціль.
    func rawAzimuth(_ s: Store, station: CLLocationCoordinate2D?, aimTo: CLLocationCoordinate2D?) -> Double? {
        if connectedTracker, s.t.mode != nil { return s.t.heading }
        if let a = aimAz { return a }
        if let st = station, let to = aimTo { return Aim.compute(from: st, to: to, height: 0).azimuth }
        return nil
    }

    func beam(_ s: Store, station: CLLocationCoordinate2D?, aimTo: CLLocationCoordinate2D?) -> BeamSpec? {
        guard beamOn, let st = station, let az = rawAzimuth(s, station: st, aimTo: aimTo) else { return nil }
        return BeamSpec(origin: st, azimuth: (az + azOffset + 720).truncatingRemainder(dividingBy: 360), width: beamWidth, range: beamRange,
                        colorHex: beamColor, fill: beamFill, stroke: beamStroke)
    }

    // MARK: Ручна ціль

    func setTarget(_ c: CLLocationCoordinate2D) {
        target = c; aimAz = nil
        note = String(localized: "Ціль: борт у точці \(Coords.pair(c.latitude, c.longitude, decimals: 5))")
        if connectedTracker && feed {
            EngineAPI.post("/cmd/mode?m=10")                  // Auto: трекер наводиться на позицію «апарата»
            sendPosition()
        }
    }
    func clearTarget() { target = nil; note = "" }

    func sendPosition() {
        guard connectedTracker, feed, let c = target, let s = store else { return }
        let sysid = max(1, Int(s.ps.val("SYSID_TARGET") ?? 1))
        let base = s.t.altMsl
        EngineAPI.post(String(format: "/tracker/pos?lat=%.7f&lon=%.7f&alt=%.1f&rel=%.1f&sysid=%d", c.latitude, c.longitude, base + targetAlt, targetAlt, sysid)) { [weak self] ok, err in
            if !ok { self?.note = String(localized: "Не вдалося надіслати позицію трекеру") + (err.map { ": " + $0 } ?? "") }
        }
    }

    /// Раз на секунду нагадує трекеру позицію цілі (він вважає її застарілою через кілька секунд).
    func start(_ s: Store) {
        store = s
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.sendPosition() }
    }
    func stop() { timer?.invalidate(); timer = nil }

    // MARK: Клавіші

    /// Стрілки міняють напрям на `step`°, Return наводить на ціль. Повертає true, якщо клавішу оброблено.
    func handleKey(_ e: NSEvent, _ s: Store, station: CLLocationCoordinate2D?) -> Bool {
        guard keys else { return false }
        var dAz = 0.0, dEl = 0.0
        switch e.keyCode {
        case 123: dAz = -step
        case 124: dAz = step
        case 126: dEl = step
        case 125: dEl = -step
        case 36, 76:
            guard let st = station, let to = target else { return false }
            let a = Aim.compute(from: st, to: to, height: targetAlt)
            setAim(az: a.azimuth, el: a.elevation, s); return true
        default: return false
        }
        let az0 = aimAz ?? (connectedTracker ? s.t.heading : (station.flatMap { st in target.map { Aim.compute(from: st, to: $0, height: 0).azimuth } } ?? 0))
        let el0 = aimAz != nil ? aimEl : (connectedTracker ? s.t.pitch : 0)
        setAim(az: az0 + dAz, el: el0 + dEl, s)
        return true
    }

    func setAim(az: Double, el: Double, _ s: Store) {
        let a = (az + 720).truncatingRemainder(dividingBy: 360), e = min(90, max(-90, el))
        let first = aimAz == nil
        aimAz = a; aimEl = e
        guard connectedTracker else { return }
        if first || s.t.mode != "Guided" {
            EngineAPI.post("/cmd/mode?m=4")                   // Guided
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { EngineAPI.post(String(format: "/tracker/aim?az=%.2f&el=%.2f", a, e)) }
        } else { EngineAPI.post(String(format: "/tracker/aim?az=%.2f&el=%.2f", a, e)) }
    }
    func releaseAim() { aimAz = nil }
}

/// Кнопка-радар у куті мапи: відкриває швидкі налаштування трекера й променя антени.
struct TrackerRadarButton: View {
    @Environment(Store.self) var s
    @State private var open = false
    private var trk: TrackerStore { TrackerStore.shared }

    var body: some View {
        let active = trk.connectedTracker || trk.target != nil || trk.aimAz != nil
        Button { open.toggle() } label: {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(active ? Color.white : Color.primary)
                .frame(width: 32, height: 32)
                .background(active ? Color.teal.opacity(0.9) : Color(nsColor: .windowBackgroundColor).opacity(0.58), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain).blockMap()
        .help("Антенний трекер і сектор антени")
        .popover(isPresented: $open, arrowEdge: .bottom) { TrackerQuickMenu().environment(s) }
    }
}

/// Невелике меню налаштувань трекера (відкривається з радара на мапі).
struct TrackerQuickMenu: View {
    @Environment(Store.self) var s
    private var trk: TrackerStore { TrackerStore.shared }

    var body: some View {
        @Bindable var t = TrackerStore.shared
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                Divider()
                group("Промінь антени") {
                    Toggle("Показувати сектор на мапі", isOn: $t.beamOn).toggleStyle(.switch).controlSize(.small)
                    slider("Кут розкриття", value: $t.beamWidth, range: 3...180, unit: "°", format: "%.0f")
                    slider("Дальність", value: $t.beamRange, range: 100...20000, unit: loc(" м"), format: "%.0f")
                    HStack {
                        Text("Колір").font(.callout)
                        ColorPicker("", selection: Binding(get: { Color(nsColor: NSColor(hex: t.beamColor)) }, set: { t.beamColor = NSColor($0).hexString }), supportsOpacity: false).labelsHidden()
                        Spacer()
                        Button("Скинути") { t.beamColor = "#30B0C7"; t.beamFill = 0.2; t.beamStroke = 0.45; t.beamWidth = 30; t.beamRange = 1500 }.controlSize(.small)
                    }
                    slider("Прозорість заливки", value: $t.beamFill, range: 0...0.8, unit: "", format: "%.2f")
                    slider("Контур", value: $t.beamStroke, range: 0...1, unit: "", format: "%.2f")
                    HStack(spacing: 6) {
                        Text("Поправка азимута").font(.callout)
                        Spacer()
                        Button("−1°") { t.azOffset -= 1 }.controlSize(.small)
                        Text(String(format: "%+.0f°", t.azOffset)).font(.callout.monospacedDigit()).frame(width: 46)
                        Button("+1°") { t.azOffset += 1 }.controlSize(.small)
                        Button("0") { t.azOffset = 0 }.controlSize(.small)
                    }
                    Text("Поправка лише зсуває сектор на мапі (антена дивиться не точно за розрахунковим напрямом); трекеру вона не надсилається.").font(.caption2).foregroundStyle(.secondary)
                }
                Divider()
                group("Борт тут (ручна ціль)") {
                    if let c = t.target {
                        Text(lk(Coords.pair(c.latitude, c.longitude, decimals: 5))).font(.callout.monospacedDigit())
                    } else {
                        Text("Не задано: правий клік по мапі → «Скерувати трекер сюди».").font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Висота борта над трекером").font(.callout)
                        TextField("", value: $t.targetAlt, format: .number.precision(.fractionLength(0))).textFieldStyle(.roundedBorder).frame(width: 64)
                        Text("м").font(.callout)
                        Spacer()
                        Button("Зняти") { t.clearTarget() }.controlSize(.small).disabled(t.target == nil)
                    }
                    Toggle("Надсилати позицію підключеному трекеру (Auto)", isOn: $t.feed).toggleStyle(.checkbox).font(.callout).disabled(!t.connectedTracker)
                    Text("Трекер у режимі Auto наводиться на позицію, яку отримує як позицію апарата (SYSID_TARGET). Для висоти поставте ALT_SOURCE = GPS або «GPS лише апарата».").font(.caption2).foregroundStyle(.secondary)
                }
                Divider()
                group("Ручне наведення клавішами") {
                    Toggle("Клавіші ← → ↑ ↓ керують антеною", isOn: $t.keys.animation()).toggleStyle(.switch).controlSize(.small)
                    if t.keys {
                        HStack {
                            Text("Крок").font(.callout)
                            TextField("", value: $t.step, format: .number.precision(.fractionLength(0))).textFieldStyle(.roundedBorder).frame(width: 52)
                            Text("°").font(.callout)
                            Spacer()
                            Button("Відпустити") { t.releaseAim(); EngineAPI.post("/cmd/mode?m=10") }.controlSize(.small).disabled(t.aimAz == nil)
                        }
                        if let a = t.aimAz { Text(String(format: loc("Напрям: азимут %03.0f°, кут місця %+.0f°"), a, t.aimEl)).font(.callout.monospacedDigit()) }
                        Text("← → азимут, ↑ ↓ кут місця, Return наводить на ціль. Працює, поки вікно Flight Data активне і фокус не в текстовому полі. Підключений трекер переходить у Guided.").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if !t.note.isEmpty { Text(lk(t.note)).font(.caption).foregroundStyle(.orange) }
            }.padding(14)
        }
        .frame(width: 340, height: 520)
    }

    @ViewBuilder var header: some View {
        if trk.connectedTracker {
            HStack {
                Label("Антенний трекер", systemImage: "antenna.radiowaves.left.and.right").font(.headline)
                Spacer()
                Text(lk(s.t.mode ?? "—")).font(.caption.weight(.semibold)).padding(.horizontal, 8).padding(.vertical, 3).background(Color.teal.opacity(0.25), in: Capsule())
            }
            Text(String(format: loc("Курс антени %03.0f°, ціль %03.0f°"), s.t.heading, s.t.navBearing)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ForEach([("Auto", 10), ("Manual", 0), ("Guided", 4), ("Stop", 1), ("Scan", 2)], id: \.1) { m in
                    Button(m.0) { EngineAPI.post("/cmd/mode?m=\(m.1)") }.controlSize(.small)
                        .buttonStyle(.bordered).tint(s.t.mode == m.0 ? .teal : nil)
                }
            }
        } else {
            Label("Антенний трекер", systemImage: "antenna.radiowaves.left.and.right").font(.headline)
            Text("Трекер не підключено: сектор показує напрям із позиції станції на апарат чи ручну ціль. Щоб керувати реальним трекером, підключіть його плату (AntennaTracker).").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func group<C: View>(_ title: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(lk(title)).font(.subheadline.weight(.semibold))
            c()
        }
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, unit: String, format: String) -> some View {
        HStack(spacing: 8) {
            Text(lk(title)).font(.callout).frame(width: 128, alignment: .leading)
            Slider(value: value, in: range)
            Text(String(format: format, value.wrappedValue) + unit).font(.caption.monospacedDigit()).frame(width: 62, alignment: .trailing)
        }
    }
}

extension NSColor {
    /// "#RRGGBB" (sRGB).
    var hexString: String {
        let c = usingColorSpace(.sRGB) ?? self
        return String(format: "#%02X%02X%02X", Int(round(c.redComponent * 255)), Int(round(c.greenComponent * 255)), Int(round(c.blueComponent * 255)))
    }
}

/// Вершини сектора: центр і дуга радіусом `range` від (az − width/2) до (az + width/2).
func beamPolygon(_ b: BeamSpec) -> [CLLocationCoordinate2D] {
    let R = 6_371_000.0, lat1 = b.origin.latitude * .pi / 180, lon1 = b.origin.longitude * .pi / 180, d = b.range / R
    func dest(_ az: Double) -> CLLocationCoordinate2D {
        let br = az * .pi / 180
        let lat2 = asin(sin(lat1) * cos(d) + cos(lat1) * sin(d) * cos(br))
        let lon2 = lon1 + atan2(sin(br) * sin(d) * cos(lat1), cos(d) - sin(lat1) * sin(lat2))
        return CLLocationCoordinate2D(latitude: lat2 * 180 / .pi, longitude: lon2 * 180 / .pi)
    }
    let w = min(max(b.width, 1), 360), n = max(2, Int(ceil(w / 2)))
    var pts = [b.origin]
    for i in 0...n { pts.append(dest(b.azimuth - w / 2 + w * Double(i) / Double(n))) }
    return pts
}
