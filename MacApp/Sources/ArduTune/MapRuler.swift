import SwiftUI
import MapKit
import AppKit

/// Результат вимірювання лінійкою між двома точками карти.
struct RulerResult {
    var distance = 0.0            // м
    var trueAz = 0.0              // географічний (істинний) азимут A→B, °
    var backAz = 0.0              // зворотний істинний азимут B→A
    var magAz = 0.0               // магнітний азимут A→B
    var declination = 0.0         // схилення в точці A (+ на схід)
    var elevA: Double?, elevB: Double?
    var minElev: Double?, maxElev: Double?
    var reliefLoading = false
    var reliefFailed = false
    var slopeDeg: Double? { guard let a = elevA, let b = elevB, distance > 1 else { return nil }; return atan2(b - a, distance) * 180 / .pi }
}

/// Лінійка на картах Flight Data і Mission: дві точки, відстань, азимути (істинний і магнітний) та рельєф уздовж лінії.
/// Режим «Лінійка» в тулбарі Mission або пункт меню «Виміряти відстань до…» (далі ЛКМ по карті ставить другу точку).
@Observable
final class MapRuler {
    var active = false                                 // постійний режим лінійки (кнопка в тулбарі)
    var a: CLLocationCoordinate2D?
    var b: CLLocationCoordinate2D?
    var result: RulerResult?
    @ObservationIgnored private var task: Task<Void, Never>?

    /// Чекаємо другу точку (перша вже поставлена).
    var waiting: Bool { a != nil && b == nil }
    /// Наступний ЛКМ по карті належить лінійці.
    var capturesClick: Bool { active || waiting }

    func start(at c: CLLocationCoordinate2D) { task?.cancel(); a = c; b = nil; result = nil }
    func clear() { task?.cancel(); a = nil; b = nil; result = nil }

    /// Клік по карті: ставить першу точку, потім другу; наступний клік починає нове вимірювання.
    func place(_ c: CLLocationCoordinate2D) {
        if a == nil || b != nil { start(at: c); return }
        b = c
        measure()
    }

    /// Перетягування точки A (0) або B (1): під час руху рахуються лише відстань і азимути, рельєф — після відпускання.
    func drag(_ i: Int, _ c: CLLocationCoordinate2D, done: Bool) {
        if i == 0 { a = c } else { b = c }
        guard a != nil, b != nil else { return }
        if done { measure(); return }
        guard let a, let b else { return }
        task?.cancel()
        var r = RulerResult()
        r.distance = CLLocation(latitude: a.latitude, longitude: a.longitude).distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
        r.trueAz = Self.bearing(a, b); r.backAz = Self.bearing(b, a)
        r.declination = MagneticModel.declination(lat: a.latitude, lon: a.longitude)
        r.magAz = (r.trueAz - r.declination + 720).truncatingRemainder(dividingBy: 360)
        r.reliefLoading = true
        result = r
    }

    static func bearing(_ p: CLLocationCoordinate2D, _ q: CLLocationCoordinate2D) -> Double {
        let f1 = p.latitude * .pi / 180, f2 = q.latitude * .pi / 180, dl = (q.longitude - p.longitude) * .pi / 180
        let y = sin(dl) * cos(f2), x = cos(f1) * sin(f2) - sin(f1) * cos(f2) * cos(dl)
        var d = atan2(y, x) * 180 / .pi
        if d < 0 { d += 360 }
        return d
    }

    private func measure() {
        guard let a, let b else { return }
        var r = RulerResult()
        r.distance = CLLocation(latitude: a.latitude, longitude: a.longitude).distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
        r.trueAz = Self.bearing(a, b)
        r.backAz = Self.bearing(b, a)
        r.declination = MagneticModel.declination(lat: a.latitude, lon: a.longitude)
        var m = r.trueAz - r.declination
        m = m.truncatingRemainder(dividingBy: 360); if m < 0 { m += 360 }
        r.magAz = m
        r.reliefLoading = true
        result = r
        // рельєф: 41 точка вздовж лінії (Open-Meteo, кеш)
        let n = 40
        let pts = (0...n).map { i -> (Double, Double) in
            let f = Double(i) / Double(n)
            return (a.latitude + (b.latitude - a.latitude) * f, a.longitude + (b.longitude - a.longitude) * f)
        }
        task?.cancel()
        task = Task { @MainActor [weak self] in
            let el = await ElevationService.shared.elevations(pts)
            guard let self, !Task.isCancelled, self.a?.latitude == a.latitude, self.b?.latitude == b.latitude else { return }
            var res = self.result ?? r
            res.reliefLoading = false
            let vals = el.compactMap { $0 }
            if vals.count == el.count, let f = vals.first, let l = vals.last {
                res.elevA = f; res.elevB = l; res.minElev = vals.min(); res.maxElev = vals.max()
            } else { res.reliefFailed = true }
            self.result = res
        }
    }
}

// MARK: - Шар на карті MKMapView

/// Малює лінію, кінцеві точки й підпис лінійки на довільній MKMapView (спільно для карт Flight Data і Mission).
final class RulerLayer {
    private var line: MKPolyline?
    private var pinA: MapPin?, pinB: MapPin?, pinL: MapPin?
    private var key = ""

    func sync(_ m: MKMapView, a: CLLocationCoordinate2D?, b: CLLocationCoordinate2D?, label: String) {
        let k = String(format: "%.6f,%.6f|%.6f,%.6f|%@", a?.latitude ?? 0, a?.longitude ?? 0, b?.latitude ?? 0, b?.longitude ?? 0, label)
        guard k != key else { return }
        key = k
        if let l = line { m.removeOverlay(l); line = nil }
        for p in [pinA, pinB, pinL] { if let p { m.removeAnnotation(p) } }
        pinA = nil; pinB = nil; pinL = nil
        guard let a else { return }
        pinA = Self.pin("rulerA", a, "A"); m.addAnnotation(pinA!)
        if let b {
            pinB = Self.pin("rulerB", b, "B"); m.addAnnotation(pinB!)
            var pts = [a, b]
            let l = MKPolyline(coordinates: &pts, count: 2); l.title = "ruler"; line = l
            m.addOverlay(l, level: .aboveLabels)
            if !label.isEmpty {
                pinL = Self.pin("rulerLbl", CLLocationCoordinate2D(latitude: (a.latitude + b.latitude) / 2, longitude: (a.longitude + b.longitude) / 2), label)
                m.addAnnotation(pinL!)
            }
        }
    }

    private static func pin(_ kind: String, _ c: CLLocationCoordinate2D, _ title: String) -> MapPin {
        let p = MapPin(); p.kind = kind; p.coordinate = c; p.title = title; return p
    }

    /// Вигляд анотацій лінійки: маленькі кружечки A/B і підпис відстані посередині.
    static func view(for p: MapPin, in m: MKMapView) -> MKAnnotationView {
        let v = m.dequeueReusableAnnotationView(withIdentifier: p.kind) ?? MKAnnotationView(annotation: p, reuseIdentifier: p.kind)
        v.annotation = p; v.canShowCallout = false; v.isEnabled = false
        v.zPriority = MKAnnotationViewZPriority(rawValue: 950)
        v.image = p.kind == "rulerLbl" ? labelImage(p.title ?? "") : dotImage(p.title ?? "")
        return v
    }

    static func dotImage(_ t: String) -> NSImage {
        let s: CGFloat = 20
        let img = NSImage(size: NSSize(width: s, height: s))
        img.lockFocus()
        NSColor.systemOrange.setFill(); NSBezierPath(ovalIn: NSRect(x: 2, y: 2, width: s - 4, height: s - 4)).fill()
        NSColor.black.withAlphaComponent(0.7).setStroke(); let b = NSBezierPath(ovalIn: NSRect(x: 2, y: 2, width: s - 4, height: s - 4)); b.lineWidth = 1; b.stroke()
        let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10, weight: .bold), .foregroundColor: NSColor.black]
        let sz = (t as NSString).size(withAttributes: a)
        (t as NSString).draw(at: NSPoint(x: (s - sz.width) / 2, y: (s - sz.height) / 2), withAttributes: a)
        img.unlockFocus()
        return img
    }

    static func labelImage(_ t: String) -> NSImage {
        let a: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.white]
        let sz = (t as NSString).size(withAttributes: a)
        let img = NSImage(size: NSSize(width: sz.width + 16, height: sz.height + 8))
        img.lockFocus()
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: NSRect(origin: .zero, size: img.size), xRadius: img.size.height / 2, yRadius: img.size.height / 2).fill()
        (t as NSString).draw(at: NSPoint(x: 8, y: 4), withAttributes: a)
        img.unlockFocus()
        return img
    }

    static func distanceText(_ d: Double) -> String { Units.dist(d) }
}

// MARK: - Панель результатів

struct RulerPanel: View {
    let ruler: MapRuler

    var body: some View {
        if let r = ruler.result {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("Лінійка", systemImage: "ruler").font(.caption.weight(.semibold))
                    Spacer()
                    Button { ruler.clear() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain).help("Прибрати лінійку")
                }
                row("Відстань", RulerLayer.distanceText(r.distance) + (r.distance >= 1000 && Units.distKey == "m" ? String(format: loc(" (%.0f м)"), r.distance) : ""))
                row("Азимут істинний", String(format: "%05.1f°", r.trueAz) + String(format: loc("  (зворотний %05.1f°)"), r.backAz))
                row("Азимут магнітний", String(format: "%05.1f°", r.magAz) + String(format: loc("  · схилення %+.1f°"), r.declination))
                if r.reliefLoading { row("Рельєф", "завантаження…") }
                else if r.reliefFailed { row("Рельєф", "недоступний (немає мережі?)") }
                else if let a = r.elevA, let b = r.elevB {
                    row("Рельєф", "A " + Units.alt(a) + " → B " + Units.alt(b) + String(format: "  (Δ %+.0f ", Units.altValue(b - a)) + Units.altLabel() + (r.slopeDeg.map { String(format: loc(", нахил %+.1f°"), $0) } ?? "") + ")")
                    if let lo = r.minElev, let hi = r.maxElev { row("Вздовж лінії", loc("мін. ") + Units.alt(lo) + loc(" · макс. ") + Units.alt(hi)) }
                }
                Text("Наступний клік по карті починає нове вимірювання.").font(.caption2).foregroundStyle(.tertiary)
            }
            .font(.caption)
            .padding(10)
            .frame(width: 330, alignment: .leading)
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.94), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
        } else if ruler.waiting {
            Label("Лінійка: клікніть ЛКМ по карті, щоб поставити другу точку", systemImage: "ruler")
                .font(.caption).padding(.horizontal, 10).padding(.vertical, 6)
                .background(Color(nsColor: .windowBackgroundColor).opacity(0.94), in: Capsule())
                .overlay(Capsule().strokeBorder(.quaternary))
        }
    }

    func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(LocalizedStringKey(k)).foregroundStyle(.secondary).frame(width: 96, alignment: .leading)
            Text(LocalizedStringKey(v)).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
        }
    }
}


extension MKMapView {
    /// Яка точка лінійки (0 = A, 1 = B) під курсором; p у координатах цього вʼю.
    func rulerPin(at p: NSPoint) -> Int? {
        for a in annotations {
            guard let m = a as? MapPin, m.kind == "rulerA" || m.kind == "rulerB", let v = view(for: m) else { continue }
            if convert(v.bounds, from: v).insetBy(dx: -4, dy: -4).contains(p) { return m.kind == "rulerA" ? 0 : 1 }
        }
        return nil
    }
}
