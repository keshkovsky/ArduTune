import SwiftUI
import MapKit
import AppKit

class WPPin: MKPointAnnotation { var wid = UUID(); var cmd = 16 }
/// Домашня точка плану: вибирається, перетягується й видаляється, як інші точки.
final class HomeWPPin: WPPin { override init() { super.init(); wid = MissionStore.homeID; cmd = -1 } }

/// MKMapView для редагування місії: клік додає точку (у режимі додавання), точки перетягуються вручну, ПКМ дає меню.
/// Події ловимо локальним монітором: внутрішні в'юшки MapKit споживають натискання раніше за перевизначення mouseDown.
final class MissionMKMapView: MKMapView {
    var onContext: ((CLLocationCoordinate2D, NSEvent) -> Void)?
    var onClick: ((CLLocationCoordinate2D, Bool) -> Void)?        // (координата, клік по порожньому місцю)
    var onPinDown: ((UUID) -> Void)?
    var onPinContext: ((UUID, NSEvent) -> Void)?
    var onKey: ((NSEvent, CLLocationCoordinate2D?) -> Bool)?       // гарячі клавіші плану (true = оброблено)
    var blocked: () -> [CGRect] = { [] }                          // плаваючі елементи SwiftUI над картою (у координатах карти, зверху вниз)
    var onDrag: ((UUID, CLLocationCoordinate2D, Bool) -> Void)?   // (точка, нова координата, завершено)
    private var down: NSPoint?
    private(set) var dragPin: WPPin?
    private var dragMoved = false
    private var rightHandled = false
    private var monitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown, .rightMouseUp, .keyDown]) { [weak self] e in self?.handle(e) ?? e }
    }
    deinit { if let m = monitor { NSEvent.removeMonitor(m) } }

    private func coord(_ p: NSPoint) -> CLLocationCoordinate2D { convert(convert(p, from: nil), toCoordinateFrom: self) }

    /// Чи потрапляє подія саме на карту (а не на плаваючі елементи SwiftUI поверх неї).
    /// Чи потрапляє подія на карту, а не на плаваючі елементи SwiftUI поверх неї.
    private func onMap(_ e: NSEvent, strict: Bool = true) -> Bool {
        guard let w = window, e.window === w else { return false }
        let local = convert(e.locationInWindow, from: nil)
        guard bounds.contains(local) else { return false }
        let top = NSPoint(x: local.x, y: isFlipped ? local.y : bounds.height - local.y)
        if blocked().contains(where: { $0.contains(top) }) { return false }
        guard let cv = w.contentView, let sv = cv.superview, let hit = cv.hitTest(sv.convert(e.locationInWindow, from: nil)) else { return true }
        if hit === self || hit.isDescendant(of: self) || self.isDescendant(of: hit) { return true }
        return !strict
    }

    /// Маркер точки під курсором (за кадром видимого маркера).
    private func pin(at e: NSEvent) -> WPPin? {
        let p = convert(e.locationInWindow, from: nil)
        var best: (WPPin, CGFloat)?
        for a in annotations {
            guard let w = a as? WPPin, w.cmd != 5201, let v = view(for: w) else { continue }
            let r = convert(v.bounds, from: v)
            guard r.insetBy(dx: -3, dy: -3).contains(p) else { continue }
            let d = hypot(r.midX - p.x, r.midY - p.y)
            if best == nil || d < best!.1 { best = (w, d) }
        }
        return best?.0
    }

    private func handle(_ e: NSEvent) -> NSEvent? {
        switch e.type {
        case .keyDown:
            // у текстових полях лишаємо стандартну поведінку (копіювати/вставити/скасувати текст)
            guard let w = window, e.window === w, w.isKeyWindow, !(w.firstResponder is NSText) else { return e }
            var cursor: CLLocationCoordinate2D?
            let lp = convert(w.mouseLocationOutsideOfEventStream, from: nil)
            if bounds.contains(lp) { cursor = convert(lp, toCoordinateFrom: self) }
            return (onKey?(e, cursor) ?? false) ? nil : e
        case .rightMouseDown:
            if let w = pin(at: e), onMap(e, strict: false) { rightHandled = true; onPinContext?(w.wid, e); return nil }
            guard onMap(e) else { return e }
            rightHandled = true; onContext?(coord(e.locationInWindow), e); return nil
        case .rightMouseUp:
            if rightHandled { rightHandled = false; return nil }
            return e
        case .leftMouseDown:
            dragPin = nil; down = nil           // скидаємо залишки попередніх жестів
            if let w = pin(at: e), onMap(e, strict: false) { dragPin = w; dragMoved = false; down = nil; onPinDown?(w.wid); return nil }
            guard onMap(e) else { return e }
            if e.modifierFlags.contains(.control) { onContext?(coord(e.locationInWindow), e); return nil }
            down = e.locationInWindow
            return e
        case .leftMouseDragged:
            guard let w = dragPin else { return e }
            if NSEvent.pressedMouseButtons & 1 == 0 { dragPin = nil; return e }
            dragMoved = true
            let c = coord(e.locationInWindow)
            w.coordinate = c
            onDrag?(w.wid, c, false)
            return nil
        case .leftMouseUp:
            if let w = dragPin {
                if dragMoved { onDrag?(w.wid, w.coordinate, true) }
                dragPin = nil; return nil
            }
            if let d = down {
                down = nil
                if hypot(e.locationInWindow.x - d.x, e.locationInWindow.y - d.y) < 4, e.clickCount == 1, onMap(e) { onClick?(coord(e.locationInWindow), true) }
            }
            return e
        default: return e
        }
    }
}

struct MissionMap: NSViewRepresentable {
    struct WP: Equatable { let id: UUID; let lat: Double; let lon: Double; let label: String; let cmd: Int; let radius: Double }
    struct ZoneVis: Equatable { let id: UUID; let kind: Int; let pts: [[Double]]; let radius: Double }
    let ctl: MapController
    let layer: MapLayer
    let zones: [ZoneVis]
    let pois: [POI]
    let wps: [WP]
    let path: [CLLocationCoordinate2D]
    let pathIDs: [UUID?]
    let dimPath: Bool
    let blocked: () -> [CGRect]
    let home: CLLocationCoordinate2D?
    var homeEditable = false
    let vehicle: CLLocationCoordinate2D?
    let vehicleHeading: Double
    var rays: RayData? = nil
    var rulerA: CLLocationCoordinate2D? = nil
    var rulerB: CLLocationCoordinate2D? = nil
    var rulerLabel = ""
    let selected: UUID?
    let currentID: UUID?
    let reachedIDs: Set<UUID>
    let front: [FrontPoly]
    let frontVersion: Int
    var simTrack: [CLLocationCoordinate2D] = []
    var simVer = 0
    var simDanger: [[CLLocationCoordinate2D]] = []
    var onSelect: (UUID?) -> Void
    var onMove: (UUID, CLLocationCoordinate2D, Bool) -> Void
    var onClick: (CLLocationCoordinate2D, Bool) -> Void
    var onContext: (CLLocationCoordinate2D, NSView, NSEvent) -> Void
    var onPinContext: (UUID, NSView, NSEvent) -> Void
    var onKey: (NSEvent, CLLocationCoordinate2D?) -> Bool

    func makeCoordinator() -> Coord { Coord() }

    func makeNSView(context: Context) -> MissionMKMapView {
        let m = MissionMKMapView()
        m.delegate = context.coordinator
        m.showsCompass = false; m.showsZoomControls = false; m.isPitchEnabled = false; m.isRotateEnabled = true
        let (c, d, h) = MapController.last ?? (CLLocationCoordinate2D(latitude: 49.0, longitude: 31.5), 1_800_000, 0)
        m.setCamera(MKMapCamera(lookingAtCenter: c, fromDistance: d, pitch: 0, heading: h), animated: false)
        context.coordinator.map = m
        ctl.map = m
        return m
    }

    func updateNSView(_ m: MissionMKMapView, context: Context) {
        m.onContext = { c, e in onContext(c, m, e) }
        m.onClick = onClick
        m.onPinDown = onSelect
        m.onKey = onKey
        m.onPinContext = { id, e in onPinContext(id, m, e) }
        m.blocked = blocked
        let co = context.coordinator
        m.onDrag = { id, c, final in onMove(id, c, final); co.livePath(id, c, in: m) }
        context.coordinator.apply(self, to: m)
    }

    final class Coord: NSObject, MKMapViewDelegate {
        var map: MKMapView?
        var parent: MissionMap?
        var curLayer: MapLayer?
        var tile: TileOverlay?
        var sig = "", pathSig = "", frontVer = -1, zoneSig = ""
        var zoneOv: [MKOverlay] = []
        var pins: [WPPin] = []
        var pathOv: [MKOverlay] = []
        var radiusOv: [MKOverlay] = []
        var frontOv: [MKOverlay] = []
        var homePin: MapPin?, homeWP: HomeWPPin?, veh: MapPin?, vehRot = -999, vehHeading = 0.0

        // промені напрямку борту (компас · GPS · гіроскоп)
        var raysPin: MapPin?, raysKey = "", raysData: RayData?
        let rulerLayer = RulerLayer()
        func updateRays(_ m: MKMapView) {
            guard let d = raysData, let a = raysPin, let v = m.view(for: a) else { return }
            let key = "\(d.compass.map { Int($0.rounded()) } ?? -1)|\(d.gps.map { Int($0.rounded()) } ?? -1)|\(d.gyro.map { Int($0.rounded()) } ?? -1)|\(Int(m.camera.heading.rounded()))"
            guard key != raysKey else { return }
            raysKey = key
            v.image = HeadingRays.image(d, mapHeading: m.camera.heading)
        }
        func syncRays(_ m: MKMapView, vehicle c: CLLocationCoordinate2D?, rays: RayData?) {
            raysData = rays
            if let c, rays != nil {
                if raysPin == nil { let a = MapPin(); a.kind = "rays"; a.coordinate = c; raysPin = a; raysKey = ""; m.addAnnotation(a) }
                else if raysPin!.coordinate.latitude != c.latitude || raysPin!.coordinate.longitude != c.longitude { raysPin!.coordinate = c }
                updateRays(m)
            } else if let a = raysPin { m.removeAnnotation(a); raysPin = nil; raysKey = "" }
        }
        var poiPins: [MapPin] = [], poiSig = ""
        var legOv: MKPolyline?, legSig = ""
        var simOv: MKPolyline?, simSig = -1
        var dangerOv: [MKPolyline] = [], dangerSig = -1
        var styleSig = ""

        func apply(_ p: MissionMap, to m: MKMapView) {
            parent = p
            if p.layer != curLayer {
                curLayer = p.layer
                if let t = tile { m.removeOverlay(t); tile = nil }
                if p.layer.isTiles { let t = TileOverlay(layer: p.layer); tile = t; m.insertOverlay(t, at: 0, level: .aboveRoads) }
                m.mapType = p.layer == .appleStd ? .standard : .hybrid
            }
            // точки
            let s = p.wps.map { "\($0.id)\(loc($0.label))\($0.cmd)" }.joined()
            if s != sig {
                sig = s
                m.removeAnnotations(pins); pins = []
                for w in p.wps {
                    let a = WPPin(); a.wid = w.id; a.cmd = w.cmd; a.title = w.label; a.coordinate = .init(latitude: w.lat, longitude: w.lon); pins.append(a)
                }
                m.addAnnotations(pins)
                styleSig = ""      // зображення оновимо нижче
            } else {
                let dragging = (m as? MissionMKMapView)?.dragPin?.wid
                for (a, w) in zip(pins, p.wps) where a.wid != dragging && (a.coordinate.latitude != w.lat || a.coordinate.longitude != w.lon) {
                    a.coordinate = .init(latitude: w.lat, longitude: w.lon)
                }
            }
            // маршрут і кола
            let dragging2 = (m as? MissionMKMapView)?.dragPin != nil
            let ps = p.path.map { String(format: "%.6f,%.6f", $0.latitude, $0.longitude) }.joined(separator: ";") + "|" + p.wps.map { "\($0.radius)" }.joined() + (p.dimPath ? "d" : "n")
            if ps != pathSig && !dragging2 {
                pathSig = ps
                m.removeOverlays(pathOv + radiusOv); pathOv = []; radiusOv = []
                pathOv = Self.pathOverlays(p.path)
                for w in p.wps where w.radius > 0 {
                    let c = MKCircle(center: .init(latitude: w.lat, longitude: w.lon), radius: w.radius); c.title = "rad"; radiusOv.append(c)
                }
                for o in pathOv + radiusOv { m.addOverlay(o, level: .aboveLabels) }
                dim = p.dimPath
                if let r = pathRenderers() { for x in r { x.alpha = dim ? 0.3 : 1 } }
            }
            // геозона
            let zs = p.zones.map { "\($0.id)\(loc($0.kind))\($0.radius)" + $0.pts.map { String(format: "%.6f,%.6f", $0[0], $0[1]) }.joined(separator: ";") }.joined(separator: "|")
            if zs != zoneSig {
                zoneSig = zs
                m.removeOverlays(zoneOv); zoneOv = []
                for z in p.zones {
                    let ex = z.kind == 5002 || z.kind == 5004
                    let cs = z.pts.map { CLLocationCoordinate2D(latitude: $0[0], longitude: $0[1]) }
                    if z.kind == 5200 {
                        if cs.count >= 3 { let o = MKPolygon(coordinates: cs, count: cs.count); o.title = "sv"; zoneOv.append(o) }
                        else if cs.count == 2 { let o = MKPolyline(coordinates: cs, count: 2); o.title = "svLine"; zoneOv.append(o) }
                    } else if z.kind == 5003 || z.kind == 5004 {
                        if let c = cs.first { let o = MKCircle(center: c, radius: z.radius); o.title = ex ? "fcEx" : "fcIn"; zoneOv.append(o) }
                    } else if cs.count >= 3 { let o = MKPolygon(coordinates: cs, count: cs.count); o.title = ex ? "fEx" : "fIn"; zoneOv.append(o) }
                    else if cs.count == 2 { let o = MKPolyline(coordinates: cs, count: 2); o.title = ex ? "fLineEx" : "fLineIn"; zoneOv.append(o) }
                }
                for o in zoneOv { m.addOverlay(o, level: .aboveLabels) }
            }
            // лінія фронту
            if p.frontVersion != frontVer {
                frontVer = p.frontVersion
                m.removeOverlays(frontOv); frontOv = []
                for f in p.front {
                    let holes: [MKPolygon] = f.rings.dropFirst().map { r in r.withUnsafeBufferPointer { MKPolygon(coordinates: $0.baseAddress!, count: r.count) } }
                    let o = f.rings[0].withUnsafeBufferPointer { MKPolygon(coordinates: $0.baseAddress!, count: f.rings[0].count, interiorPolygons: holes.isEmpty ? nil : holes) }
                    o.title = "front"; o.subtitle = f.color; frontOv.append(o)
                }
                for o in frontOv { m.insertOverlay(o, at: 0, level: .aboveLabels) }
            }
            // POI (спільні з Flight Data)
            let psig = p.pois.map { "\($0.id)\(loc($0.name))\($0.lat),\($0.lon)" }.joined()
            if psig != poiSig {
                poiSig = psig
                m.removeAnnotations(poiPins); poiPins = []
                for o in p.pois { let a = MapPin(); a.kind = "poi"; a.title = o.name; a.coordinate = .init(latitude: o.lat, longitude: o.lon); poiPins.append(a) }
                m.addAnnotations(poiPins)
            }
            // Home
            if let c = p.home, p.homeEditable {
                if let a = homePin { m.removeAnnotation(a); homePin = nil }
                if let a = homeWP { if (a.coordinate.latitude != c.latitude || a.coordinate.longitude != c.longitude) && homeWP !== (m as? MissionMKMapView)?.dragPin { a.coordinate = c } }
                else { let a = HomeWPPin(); a.title = "Home"; a.coordinate = c; homeWP = a; m.addAnnotation(a) }
            } else if let c = p.home {
                if let a = homeWP { m.removeAnnotation(a); homeWP = nil }
                if let a = homePin { if a.coordinate.latitude != c.latitude || a.coordinate.longitude != c.longitude { a.coordinate = c } }
                else { let a = MapPin(); a.kind = "home"; a.title = "Home"; a.coordinate = c; homePin = a; m.addAnnotation(a) }
            } else {
                if let a = homePin { m.removeAnnotation(a); homePin = nil }
                if let a = homeWP { m.removeAnnotation(a); homeWP = nil }
            }
            // апарат і лінія до поточної цілі
            if let c = p.vehicle {
                if veh == nil { let a = MapPin(); a.kind = "veh"; a.coordinate = c; veh = a; m.addAnnotation(a) } else { veh!.coordinate = c }
                vehHeading = p.vehicleHeading; updateVeh(m)
            } else if let a = veh { m.removeAnnotation(a); veh = nil }
            syncRays(m, vehicle: p.vehicle, rays: p.rays)
            rulerLayer.sync(m, a: p.rulerA, b: p.rulerB, label: p.rulerLabel)
            var ls = ""
            var leg: [CLLocationCoordinate2D] = []
            if let c = p.vehicle, let cid = p.currentID, let w = p.wps.first(where: { $0.id == cid }) {
                leg = [c, .init(latitude: w.lat, longitude: w.lon)]
                ls = String(format: "%.5f,%.5f>%.5f,%.5f", c.latitude, c.longitude, w.lat, w.lon)
            }
            if ls != legSig {
                legSig = ls
                if let o = legOv { m.removeOverlay(o); legOv = nil }
                if leg.count == 2 { let l = MKPolyline(coordinates: leg, count: 2); l.title = "leg"; legOv = l; m.addOverlay(l, level: .aboveLabels) }
            }
            // траєкторія симуляції
            let ssig = p.simTrack.isEmpty ? -1 : p.simVer
            if ssig != simSig {
                simSig = ssig
                if let o = simOv { m.removeOverlay(o); simOv = nil }
                if p.simTrack.count > 1 { let l = MKPolyline(coordinates: p.simTrack, count: p.simTrack.count); l.title = "simTrack"; simOv = l; m.addOverlay(l, level: .aboveLabels) }
            }
            // небезпечні ділянки траєкторії (нижче безпечної висоти над рельєфом)
            let dsig = p.simDanger.isEmpty ? -1 : p.simVer &* 31 &+ p.simDanger.count
            if dsig != dangerSig {
                dangerSig = dsig
                m.removeOverlays(dangerOv); dangerOv = []
                for seg in p.simDanger where seg.count > 1 {
                    let l = MKPolyline(coordinates: seg, count: seg.count); l.title = "simDanger"; dangerOv.append(l)
                }
                m.addOverlays(dangerOv, level: .aboveLabels)
            }
            // вигляд маркерів: вибір / поточна / пройдені
            let st = "\(p.selected?.uuidString ?? "")|\(p.currentID?.uuidString ?? "")|\(p.reachedIDs.count)|\(sig.hashValue)"
            if st != styleSig {
                styleSig = st
                for a in pins { if let v = m.view(for: a) { v.image = image(for: a, p) } }
                if let h = homeWP, let v = m.view(for: h) { v.image = FlightMap.Coord.badge("house.fill", fg: .white, bg: p.selected == MissionStore.homeID ? .systemOrange : .systemGreen, size: p.selected == MissionStore.homeID ? 32 : 28) }
            }
        }

        var dim = false
        static func pathOverlays(_ path: [CLLocationCoordinate2D]) -> [MKOverlay] {
            guard path.count > 1 else { return [] }
            let bg = MKPolyline(coordinates: path, count: path.count); bg.title = "pathBG"
            let l = MKPolyline(coordinates: path, count: path.count); l.title = "path"
            return [bg, l]
        }
        func pathRenderers() -> [MKOverlayRenderer]? { pathOv.compactMap { map?.renderer(for: $0) } }

        /// Під час перетягування маршрут перебудовується одразу, не чекаючи оновлення плану.
        func livePath(_ id: UUID, _ c: CLLocationCoordinate2D, in m: MKMapView) {
            guard let p = parent, let i = p.pathIDs.firstIndex(where: { $0 == id }), p.path.indices.contains(i) else { return }
            var path = p.path; path[i] = c
            m.removeOverlays(pathOv); pathOv = Self.pathOverlays(path)
            for o in pathOv { m.addOverlay(o, level: .aboveLabels) }
            pathSig = ""        // після завершення перетягування план оновить маршрут остаточно
        }

        func image(for a: WPPin, _ p: MissionMap) -> NSImage {
            let sel = a.wid == p.selected, cur = a.wid == p.currentID, done = p.reachedIDs.contains(a.wid)
            let base: NSColor = [5001, 5003].contains(a.cmd) ? .systemGreen : [5002, 5004].contains(a.cmd) ? .systemRed : a.cmd == 5100 ? .systemTeal : a.cmd == 5200 ? .systemPurple : .systemBlue
            let bg: NSColor = sel ? .systemOrange : cur ? .systemGreen : done ? .systemGray : base
            return MarkerArt.image(label: a.title ?? "", cmd: a.cmd, bg: bg, main: sel ? 30 : 26)
        }

        func updateVeh(_ m: MKMapView) {
            let rot = Int((vehHeading - m.camera.heading).rounded() / 2) * 2
            guard rot != vehRot, let a = veh, let v = m.view(for: a) else { return }
            vehRot = rot
            v.image = FlightMap.Coord.badge("location.north.fill", fg: .systemBlue, bg: NSColor.white.withAlphaComponent(0.9), size: 34, rotation: Double(rot), circle: false)
        }

        // MARK: Делегат
        func mapView(_ m: MKMapView, viewFor a: MKAnnotation) -> MKAnnotationView? {
            if let a = a as? HomeWPPin {
                let v = m.dequeueReusableAnnotationView(withIdentifier: "homeWP") ?? MKAnnotationView(annotation: a, reuseIdentifier: "homeWP")
                v.annotation = a; v.isDraggable = false; v.canShowCallout = false; v.toolTip = "Home"
                let sel = parent?.selected == MissionStore.homeID
                v.image = FlightMap.Coord.badge("house.fill", fg: .white, bg: sel ? .systemOrange : .systemGreen, size: sel ? 32 : 28)
                return v
            }
            if let a = a as? WPPin {
                let v = m.dequeueReusableAnnotationView(withIdentifier: "wp") ?? MKAnnotationView(annotation: a, reuseIdentifier: "wp")
                v.annotation = a; v.isDraggable = false; v.canShowCallout = false
                v.toolTip = MissionCatalog.find(a.cmd).name
                if let p = parent { v.image = image(for: a, p) }
                return v
            }
            guard let a = a as? MapPin else { return nil }
            if a.kind.hasPrefix("ruler") { return RulerLayer.view(for: a, in: m) }
            let v = m.dequeueReusableAnnotationView(withIdentifier: a.kind) ?? MKAnnotationView(annotation: a, reuseIdentifier: a.kind)
            v.annotation = a
            switch a.kind {
            case "veh": vehRot = -999; v.image = FlightMap.Coord.badge("location.north.fill", fg: .systemBlue, bg: NSColor.white.withAlphaComponent(0.9), size: 34, rotation: vehHeading - m.camera.heading, circle: false); v.zPriority = MKAnnotationViewZPriority(rawValue: 1000)
            case "rays":
                v.canShowCallout = false; v.isEnabled = false
                v.zPriority = MKAnnotationViewZPriority(rawValue: 900)
                v.image = HeadingRays.image(raysData ?? RayData(), mapHeading: m.camera.heading)
                raysKey = ""
            case "poi": v.image = FlightMap.Coord.badge("mappin", fg: .white, bg: .systemRed, size: 26); v.canShowCallout = true
            default: v.image = FlightMap.Coord.badge("house.fill", fg: .white, bg: .systemGreen, size: 28); v.canShowCallout = true
            }
            return v
        }

        func mapView(_ m: MKMapView, didSelect v: MKAnnotationView) {
            if let a = v.annotation as? WPPin { parent?.onSelect(a.wid); m.deselectAnnotation(a, animated: false) }
        }

        func mapView(_ m: MKMapView, rendererFor o: MKOverlay) -> MKOverlayRenderer {
            if let t = o as? MKTileOverlay { return MKTileOverlayRenderer(tileOverlay: t) }
            if let l = o as? MKPolyline {
                let r = MKPolylineRenderer(polyline: l)
                switch l.title {
                case "svLine": r.strokeColor = .systemPurple; r.lineWidth = 2
                case "fLineIn": r.strokeColor = .systemGreen; r.lineWidth = 2
                case "fLineEx": r.strokeColor = .systemRed; r.lineWidth = 2
                case "pathBG": r.strokeColor = NSColor.black.withAlphaComponent(0.18); r.lineWidth = 5; r.lineDashPattern = [7, 7]
                case "ruler": r.strokeColor = .white; r.lineWidth = 2.5; r.lineDashPattern = [8, 5]
                case "simDanger": r.strokeColor = NSColor.systemRed; r.lineWidth = 4.5
                case "simTrack": r.strokeColor = NSColor.systemPink.withAlphaComponent(0.85); r.lineWidth = 2.5
                case "leg": r.strokeColor = .systemGreen; r.lineWidth = 2.5; r.lineDashPattern = [6, 5]
                default: r.strokeColor = NSColor.systemYellow.withAlphaComponent(0.55); r.lineWidth = 2.5; r.lineDashPattern = [7, 7]
                }
                r.lineCap = .round; r.lineJoin = .round
                if dim, l.title == "path" || l.title == "pathBG" { r.alpha = 0.3 }
                return r
            }
            if let g = o as? MKPolygon {
                let r = MKPolygonRenderer(polygon: g)
                if g.title == "sv" {
                    r.fillColor = NSColor.systemPurple.withAlphaComponent(0.14); r.strokeColor = NSColor.systemPurple; r.lineWidth = 2.5
                    return r
                }
                if g.title == "fIn" || g.title == "fEx" {
                    let c: NSColor = g.title == "fIn" ? .systemGreen : .systemRed
                    r.fillColor = c.withAlphaComponent(g.title == "fIn" ? 0.10 : 0.22); r.strokeColor = c; r.lineWidth = 2.5
                    if g.title == "fIn" { r.lineDashPattern = [8, 5] }
                    return r
                }
                let c = NSColor(hex: g.subtitle ?? "")
                r.fillColor = c.withAlphaComponent(0.32); r.strokeColor = c.withAlphaComponent(0.9); r.lineWidth = 1
                return r
            }
            if let c = o as? MKCircle {
                let r = MKCircleRenderer(circle: c)
                if c.title == "fcIn" || c.title == "fcEx" {
                    let col: NSColor = c.title == "fcIn" ? .systemGreen : .systemRed
                    r.fillColor = col.withAlphaComponent(c.title == "fcIn" ? 0.10 : 0.22); r.strokeColor = col; r.lineWidth = 2.5
                    if c.title == "fcIn" { r.lineDashPattern = [8, 5] }
                    return r
                }
                r.fillColor = NSColor.systemYellow.withAlphaComponent(0.08); r.strokeColor = NSColor.systemYellow.withAlphaComponent(0.8); r.lineWidth = 1.5; r.lineDashPattern = [5, 4]
                return r
            }
            return MKOverlayRenderer(overlay: o)
        }

        func mapViewDidChangeVisibleRegion(_ m: MKMapView) {
            let h = m.camera.heading
            MapController.last = (m.camera.centerCoordinate, m.camera.centerCoordinateDistance, h)
            updateVeh(m)
            updateRays(m)
            if abs(h - lastHeading) > 0.5 { lastHeading = h; DispatchQueue.main.async { [weak ctl = parent?.ctl] in ctl?.heading = h } }
        }
        var lastHeading = 0.0
    }
}

/// Маркер точки: номер у великому колі та маленька іконка типу в кружечку (спільний для Mission і Flight Data).
enum MarkerArt {
    static func image(label: String, cmd: Int, bg: NSColor, main: CGFloat) -> NSImage {
        if cmd == 5201 {            // точка, згенерована ділянкою: дрібна крапка
            return NSImage(size: NSSize(width: 12, height: 12), flipped: false) { r in
                NSColor.white.setFill(); NSBezierPath(ovalIn: r).fill()
                NSColor.systemPurple.setFill(); NSBezierPath(ovalIn: r.insetBy(dx: 2, dy: 2)).fill()
                return true
            }
        }
        let (sym, bc) = MissionCatalog.badge(cmd)
        let W: CGFloat = main + 16
        return NSImage(size: NSSize(width: W, height: W), flipped: false) { _ in
            let c = CGRect(x: (W - main) / 2, y: (W - main) / 2, width: main, height: main)      // головний круг у центрі: точка прив'язана до координати
            NSColor.white.setFill(); NSBezierPath(ovalIn: c.insetBy(dx: 0.5, dy: 0.5)).fill()
            bg.setFill(); NSBezierPath(ovalIn: c.insetBy(dx: 2.5, dy: 2.5)).fill()
            let attr: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: main * 0.42, weight: .bold), .foregroundColor: NSColor.white]
            let ts = (label as NSString).size(withAttributes: attr)
            (label as NSString).draw(at: NSPoint(x: c.midX - ts.width / 2, y: c.midY - ts.height / 2), withAttributes: attr)
            let d: CGFloat = 17, br = CGRect(x: W - d, y: W - d, width: d, height: d)
            NSColor.white.setFill(); NSBezierPath(ovalIn: br).fill()
            bc.setFill(); NSBezierPath(ovalIn: br.insetBy(dx: 1.5, dy: 1.5)).fill()
            if let img = NSImage(systemSymbolName: sym, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 8.5, weight: .bold).applying(.init(paletteColors: [.white]))) {
                let s = img.size
                img.draw(in: NSRect(x: br.midX - s.width / 2, y: br.midY - s.height / 2, width: s.width, height: s.height))
            }
            return true
        }
    }
}
