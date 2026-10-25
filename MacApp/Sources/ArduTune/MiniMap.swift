import SwiftUI
import MapKit

/// Мінікарта з центром, що завжди лишається на апараті (для вікна відео).
struct MiniMap: NSViewRepresentable {
    let coord: CLLocationCoordinate2D?
    let heading: Double
    let distance: Double
    var route: [CLLocationCoordinate2D] = []
    var toNext: CLLocationCoordinate2D? = nil
    var toEnd: CLLocationCoordinate2D? = nil

    final class Pin: MKPointAnnotation {}

    final class Coord: NSObject, MKMapViewDelegate {
        var pin: Pin?
        var heading = 0.0
        var lastRot = -999
        var overlays: [MKOverlay] = [], sig = ""
        func mapView(_ m: MKMapView, rendererFor o: MKOverlay) -> MKOverlayRenderer {
            guard let l = o as? MKPolyline else { return MKOverlayRenderer(overlay: o) }
            let r = MKPolylineRenderer(polyline: l)
            switch l.title {
            case "route": r.strokeColor = NSColor.systemYellow.withAlphaComponent(0.9); r.lineWidth = 2.5
            case "next": r.strokeColor = .systemTeal; r.lineWidth = 2; r.lineDashPattern = [6, 4]
            default: r.strokeColor = .systemOrange; r.lineWidth = 2; r.lineDashPattern = [2, 5]
            }
            r.lineCap = .round; r.lineJoin = .round
            return r
        }
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
        let sig = String(format: "%.5f,%.5f|%d|%.4f,%.4f|%.4f,%.4f", c.latitude, c.longitude, route.count, toNext?.latitude ?? 0, toNext?.longitude ?? 0, toEnd?.latitude ?? 0, toEnd?.longitude ?? 0)
        if sig != co.sig {
            co.sig = sig
            m.removeOverlays(co.overlays); co.overlays = []
            if route.count > 1 { let l = MKPolyline(coordinates: route, count: route.count); l.title = "route"; co.overlays.append(l) }
            if let n = toNext { let l = MKPolyline(coordinates: [c, n], count: 2); l.title = "next"; co.overlays.append(l) }
            if let e = toEnd { let l = MKPolyline(coordinates: [c, e], count: 2); l.title = "end"; co.overlays.append(l) }
            for o in co.overlays { m.addOverlay(o, level: .aboveLabels) }
        }
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
    @AppStorage("vmap.route") private var showRoute = true
    @AppStorage("vmap.next") private var showNext = true
    @AppStorage("vmap.end") private var showEnd = false

    var body: some View {
        let t = s.t
        let hasFix = t.gpsFix >= 2 && (t.lat != 0 || t.lon != 0)
        let m = s.mission
        let veh = CLLocationCoordinate2D(latitude: t.lat, longitude: t.lon)
        let pts = m.items.filter(\.hasPos)
        let seq = t.wpSeq
        let nextItem: MissionItem? = (s.connected && !m.dirty && seq >= 1 && seq <= m.items.count && m.items[seq - 1].hasPos) ? m.items[seq - 1] : nil
        let endItem = pts.last
        let nextAim = (hasFix && showNext) ? nextItem.map { Aim.compute(from: veh, to: $0.coord, height: 0) } : nil
        let endAim = (hasFix && showEnd) ? endItem.map { Aim.compute(from: veh, to: $0.coord, height: 0) } : nil
        let w = big ? min(max(area.width * 0.45, 320), 640) : min(220, max(area.width * 0.4, 150))
        let h = big ? min(max(area.height * 0.55, 220), 460) : min(150, max(area.height * 0.4, 100))
        ZStack {
            MiniMap(coord: hasFix ? veh : nil, heading: t.heading, distance: dist,
                    route: showRoute ? m.routeCoords : [], toNext: nextAim != nil ? nextItem?.coord : nil, toEnd: endAim != nil ? endItem?.coord : nil)
            if !hasFix {
                Text("Немає GPS-позиції").font(.caption).foregroundStyle(.white).padding(6).background(.black.opacity(0.55), in: Capsule())
            }
        }
        .frame(width: w, height: h)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.35), lineWidth: 1))
        .overlay(alignment: .topLeading) {
            Menu {
                Toggle("Маршрут місії", isOn: $showRoute)
                Toggle("До наступної точки: азимут і відстань", isOn: $showNext)
                Toggle("До кінцевої точки: азимут і відстань", isOn: $showEnd)
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 12, weight: .bold)).padding(5).background(.black.opacity(0.55), in: Circle()).foregroundStyle(.white)
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().padding(5).help("Що показувати на мінікарті")
        }
        .overlay(alignment: .bottomLeading) {
            VStack(alignment: .leading, spacing: 2) {
                if let a = nextAim { Label { Text(Aim.textShort(a)) } icon: { Image(systemName: "arrow.turn.up.right").foregroundStyle(.teal) } }
                if let a = endAim { Label { Text(Aim.textShort(a)) } icon: { Image(systemName: "flag.checkered").foregroundStyle(.orange) } }
            }
            .font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(.white).shadow(color: .black, radius: 2).padding(8)
        }
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
