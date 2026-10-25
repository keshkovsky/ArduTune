import SwiftUI
import MapKit

/// Мінікарта з центром, що завжди лишається на апараті (для вікна відео).
struct MiniMap: NSViewRepresentable {
    let coord: CLLocationCoordinate2D?
    let heading: Double
    let distance: Double

    final class Pin: MKPointAnnotation {}

    final class Coord: NSObject, MKMapViewDelegate {
        var pin: Pin?
        var heading = 0.0
        var lastRot = -999
        func mapView(_ m: MKMapView, viewFor a: MKAnnotation) -> MKAnnotationView? {
            guard a is Pin else { return nil }
            let v = m.dequeueReusableAnnotationView(withIdentifier: "veh") ?? MKAnnotationView(annotation: a, reuseIdentifier: "veh")
            v.annotation = a; v.isEnabled = false
            v.image = FlightMap.Coord.badge("location.north.fill", fg: .systemBlue, bg: NSColor.white.withAlphaComponent(0.92), size: 30, rotation: heading, circle: false)
            return v
        }
    }

    func makeCoordinator() -> Coord { Coord() }

    func makeNSView(context: Context) -> MKMapView {
        let m = MKMapView()
        m.delegate = context.coordinator
        m.mapType = .hybrid
        m.showsCompass = false; m.showsZoomControls = false
        m.isScrollEnabled = false; m.isZoomEnabled = false; m.isRotateEnabled = false; m.isPitchEnabled = false
        return m
    }

    func updateNSView(_ m: MKMapView, context: Context) {
        let co = context.coordinator
        guard let c = coord else {
            if let p = co.pin { m.removeAnnotation(p); co.pin = nil }
            return
        }
        m.setCamera(MKMapCamera(lookingAtCenter: c, fromDistance: distance, pitch: 0, heading: 0), animated: false)
        if let p = co.pin { p.coordinate = c }
        else { let p = Pin(); p.coordinate = c; co.pin = p; m.addAnnotation(p) }
        let rot = Int((heading / 4).rounded()) * 4
        co.heading = heading
        if rot != co.lastRot, let p = co.pin, let v = m.view(for: p) {
            co.lastRot = rot
            v.image = FlightMap.Coord.badge("location.north.fill", fg: .systemBlue, bg: NSColor.white.withAlphaComponent(0.92), size: 30, rotation: heading, circle: false)
        }
    }
}

/// Панель мінікарти у куті вікна відео: розгортається/згортається, масштаб кнопками.
struct MiniMapPanel: View {
    @Environment(Store.self) var s
    let area: CGSize
    @AppStorage("vmap.big") private var big = false
    @AppStorage("vmap.dist") private var dist = 900.0

    var body: some View {
        let t = s.t
        let hasFix = t.gpsFix >= 2 && (t.lat != 0 || t.lon != 0)
        let w = big ? min(max(area.width * 0.45, 320), 640) : min(220, max(area.width * 0.4, 150))
        let h = big ? min(max(area.height * 0.55, 220), 460) : min(150, max(area.height * 0.4, 100))
        ZStack {
            MiniMap(coord: hasFix ? .init(latitude: t.lat, longitude: t.lon) : nil, heading: t.heading, distance: dist)
            if !hasFix {
                Text("Немає GPS-позиції").font(.caption).foregroundStyle(.white).padding(6).background(.black.opacity(0.55), in: Capsule())
            }
        }
        .frame(width: w, height: h)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.35), lineWidth: 1))
        .overlay(alignment: .topTrailing) {
            Button { withAnimation(.snappy(duration: 0.2)) { big.toggle() } } label: {
                Image(systemName: big ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 11, weight: .bold)).padding(6).background(.black.opacity(0.55), in: Circle()).foregroundStyle(.white)
            }.buttonStyle(.plain).padding(5).help(lk(big ? "Згорнути мінікарту" : "Розгорнути мінікарту"))
        }
        .overlay(alignment: .bottomTrailing) {
            VStack(spacing: 3) {
                Button { dist = max(150, dist / 1.6) } label: { Image(systemName: "plus").font(.system(size: 11, weight: .bold)).frame(width: 22, height: 22).background(.black.opacity(0.55), in: Circle()).foregroundStyle(.white) }.buttonStyle(.plain)
                Button { dist = min(60_000, dist * 1.6) } label: { Image(systemName: "minus").font(.system(size: 11, weight: .bold)).frame(width: 22, height: 22).background(.black.opacity(0.55), in: Circle()).foregroundStyle(.white) }.buttonStyle(.plain)
            }.padding(5)
        }
        .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
    }
}
