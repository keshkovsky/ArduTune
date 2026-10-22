import SwiftUI
import MapKit
import AppKit
import Observation

// MARK: - Шари карти

/// Джерела підкладки. Apple рисує сам MapKit, решта: растрові плитки (XYZ / Bing quadkey).
enum MapLayer: String, CaseIterable, Identifiable {
    case appleSat, appleStd, googleSat, googleHybrid, googleRoad, bingSat, bingHybrid, bingRoad, osm, openTopo, esriTopo
    var id: String { rawValue }
    var title: String {
        switch self {
        case .appleSat: "Apple · Гібрид"
        case .appleStd: "Apple · Схема"
        case .googleSat: "Google · Супутник"
        case .googleHybrid: "Google · Гібрид"
        case .googleRoad: "Google · Схема"
        case .bingSat: "Bing · Супутник"
        case .bingHybrid: "Bing · Гібрид"
        case .bingRoad: "Bing · Схема"
        case .osm: "OpenStreetMap"
        case .openTopo: "OpenTopoMap · Горизонталі й висоти"
        case .esriTopo: "Esri · Топографічна"
        }
    }
    var short: String { loc(title).replacingOccurrences(of: " · ", with: " ") }
    var isTiles: Bool { self != .appleSat && self != .appleStd }
    var maxZoom: Int { switch self { case .openTopo: 17; case .esriTopo: 19; case .osm: 19; case .bingSat, .bingHybrid, .bingRoad: 19; default: 20 } }
    static let groups: [(String, [MapLayer])] = [
        ("Apple", [.appleSat, .appleStd]), ("Google", [.googleSat, .googleHybrid, .googleRoad]),
        ("Bing", [.bingSat, .bingHybrid, .bingRoad]), ("Рельєф", [.openTopo, .esriTopo]), ("Інше", [.osm]),
    ]
}

final class TileOverlay: MKTileOverlay {
    let layer: MapLayer
    static let session: URLSession = {
        let c = URLSessionConfiguration.default
        // Кеш карт лежить у «Application Support», а не в «Caches»: система не чистить його сама, і він переживає оновлення й видалення застосунку.
        let dir = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/ArduTune/MapCache")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        c.urlCache = URLCache(memoryCapacity: 48 << 20, diskCapacity: 600 << 20, directory: dir)
        c.requestCachePolicy = .returnCacheDataElseLoad
        c.timeoutIntervalForRequest = 15
        return URLSession(configuration: c)
    }()

    init(layer: MapLayer) {
        self.layer = layer
        super.init(urlTemplate: nil)
        tileSize = CGSize(width: 256, height: 256)
        maximumZ = layer.maxZoom
        canReplaceMapContent = true
    }

    static func quadkey(_ x: Int, _ y: Int, _ z: Int) -> String {
        var s = ""
        for i in stride(from: z, to: 0, by: -1) {
            var d = 0; let mask = 1 << (i - 1)
            if x & mask != 0 { d += 1 }
            if y & mask != 0 { d += 2 }
            s += String(d)
        }
        return s
    }

    override func url(forTilePath p: MKTileOverlayPath) -> URL {
        let (x, y, z) = (p.x, p.y, p.z)
        let n = (x + y) % 4
        let u: String
        switch layer {
        case .googleSat: u = "https://mt\(n).google.com/vt/lyrs=s&x=\(x)&y=\(y)&z=\(z)"
        case .googleHybrid: u = "https://mt\(n).google.com/vt/lyrs=y&x=\(x)&y=\(y)&z=\(z)"
        case .googleRoad: u = "https://mt\(n).google.com/vt/lyrs=m&x=\(x)&y=\(y)&z=\(z)"
        case .bingSat: u = "https://ecn.t\(n).tiles.virtualearth.net/tiles/a\(Self.quadkey(x, y, z)).jpeg?g=1"
        case .bingHybrid: u = "https://ecn.t\(n).tiles.virtualearth.net/tiles/h\(Self.quadkey(x, y, z)).jpeg?g=1"
        case .bingRoad: u = "https://ecn.t\(n).tiles.virtualearth.net/tiles/r\(Self.quadkey(x, y, z)).png?g=1"
        case .openTopo: u = "https://\(["a", "b", "c"][n % 3]).tile.opentopomap.org/\(z)/\(x)/\(y).png"
        case .esriTopo: u = "https://server.arcgisonline.com/ArcGIS/rest/services/World_Topo_Map/MapServer/tile/\(z)/\(y)/\(x)"
        default: u = "https://tile.openstreetmap.org/\(z)/\(x)/\(y).png"
        }
        return URL(string: u)!
    }

    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, Error?) -> Void) {
        var r = URLRequest(url: url(forTilePath: path))
        r.setValue("ArduTune/1.0 (macOS ArduPilot configurator)", forHTTPHeaderField: "User-Agent")
        if UserDefaults.standard.bool(forKey: "map.cacheOnly") { r.cachePolicy = .returnCacheDataDontLoad }
        Self.session.dataTask(with: r) { d, resp, e in
            if let h = resp as? HTTPURLResponse, h.statusCode != 200 { result(nil, e ?? URLError(.badServerResponse)) } else { result(d, e) }
        }.resume()
    }
}

// MARK: - Лінія фронту (DeepState)

struct FrontPoly { let rings: [[CLLocationCoordinate2D]]; let color: String }

/// Окуповані/звільнені території з відкритого API DeepState (deepstatemap.live). Кеш на диску, оновлення раз на годину.
@Observable @MainActor
final class FrontLine {
    static let shared = FrontLine()
    var polys: [FrontPoly] = []
    var version = 0
    var status = ""
    @ObservationIgnored private var updated: Date?
    @ObservationIgnored private var loading = false
    private static let cacheURL = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/ArduTune/frontline.json")

    func refresh(force: Bool = false) async {
        guard !loading else { return }
        if !force, !polys.isEmpty, let u = updated, Date().timeIntervalSince(u) < 3600 { return }
        loading = true; defer { loading = false }
        if polys.isEmpty { status = String(localized: "Лінія фронту: завантаження…") }
        let cache = Self.cacheURL
        let r = await Task.detached(priority: .utility) { () -> ([FrontPoly], String?, Bool)? in
            var req = URLRequest(url: URL(string: "https://deepstatemap.live/api/history/last")!)
            req.timeoutInterval = 40
            req.setValue("ArduTune/1.0 (macOS ArduPilot configurator)", forHTTPHeaderField: "User-Agent")
            if let (d, resp) = try? await URLSession.shared.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200, let p = FrontLine.parse(d) {
                try? FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? d.write(to: cache)
                return (p.0, p.1, false)
            }
            if let d = try? Data(contentsOf: cache), let p = FrontLine.parse(d) { return (p.0, p.1, true) }
            return nil
        }.value
        if let (p, asOf, offline) = r {
            polys = p; version += 1; updated = Date()
            let when = asOf.map { String($0.prefix(16)).replacingOccurrences(of: "T", with: " ") } ?? ""
            status = "DeepState" + (when.isEmpty ? "" : " · \(when)") + (offline ? " · кеш (немає мережі)" : "")
        } else if polys.isEmpty { status = String(localized: "Лінія фронту: не вдалося завантажити") }
    }

    nonisolated static func parse(_ d: Data) -> ([FrontPoly], String?)? {
        guard let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let map = j["map"] as? [String: Any], let feats = map["features"] as? [[String: Any]] else { return nil }
        func ring(_ a: [[Double]]) -> [CLLocationCoordinate2D] {
            a.compactMap { $0.count >= 2 ? CLLocationCoordinate2D(latitude: $0[1], longitude: $0[0]) : nil }
        }
        var out: [FrontPoly] = []
        for f in feats {
            guard let g = f["geometry"] as? [String: Any], let type = g["type"] as? String, let c = g["coordinates"] else { continue }
            let color = ((f["properties"] as? [String: Any])?["fill"] as? String) ?? "#a52714"
            var polys: [[[[Double]]]] = []
            if type == "Polygon", let p = c as? [[[Double]]] { polys = [p] }
            else if type == "MultiPolygon", let p = c as? [[[[Double]]]] { polys = p }
            for p in polys {
                let rings = p.map(ring).filter { $0.count >= 3 }
                if !rings.isEmpty { out.append(FrontPoly(rings: rings, color: color)) }
            }
        }
        return (out, j["datetime"] as? String)
    }
}

extension NSColor {
    convenience init(hex: String) {
        var h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        if h.count == 3 { h = h.map { "\($0)\($0)" }.joined() }
        let v = UInt32(h, radix: 16) ?? 0xa52714
        self.init(red: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1)
    }
}

// MARK: - Керування камерою

@Observable
final class MapController {
    var heading = 0.0
    @ObservationIgnored weak var map: MKMapView?
    nonisolated(unsafe) static var last: (CLLocationCoordinate2D, Double, Double)?     // центр, дистанція, курс: щоб карта не скидалась при зміні сторінки

    func center(_ c: CLLocationCoordinate2D, distance: Double? = nil, heading h: Double? = nil, animated: Bool = true) {
        guard let m = map, let cam = m.camera.copy() as? MKMapCamera else { return }
        cam.centerCoordinate = c
        if let d = distance { cam.centerCoordinateDistance = d }
        if let h { cam.heading = Self.norm(h) }
        m.setCamera(cam, animated: animated)
    }
    func zoom(_ factor: Double) {
        guard let m = map, let cam = m.camera.copy() as? MKMapCamera else { return }
        cam.centerCoordinateDistance = min(max(cam.centerCoordinateDistance * factor, 15), 2.5e7)
        m.setCamera(cam, animated: true)
    }
    func rotate(by d: Double) { setHeading((map?.camera.heading ?? 0) + d) }
    func setHeading(_ h: Double) {
        guard let m = map, let cam = m.camera.copy() as? MKMapCamera else { return }
        cam.heading = Self.norm(h)
        m.setCamera(cam, animated: true)
    }
    static func norm(_ h: Double) -> Double { let r = h.truncatingRemainder(dividingBy: 360); return r < 0 ? r + 360 : r }
}

// MARK: - MKMapView

final class MapPin: MKPointAnnotation { var kind = "" }
final class RPin: MKPointAnnotation { var wid = UUID(); var cmd = 16 }

final class FlightMKMapView: MKMapView {
    var onContext: ((CLLocationCoordinate2D, NSEvent) -> Void)?
    var onDouble: ((CLLocationCoordinate2D) -> Void)?
    var onPinContext: ((UUID, NSEvent) -> Void)?
    var flyHere = false
    var blocked: () -> [CGRect] = { [] }               // плаваючі елементи SwiftUI над картою (у координатах карти, зверху вниз)
    private var monitor: Any?
    private var down: NSPoint?
    private var rightHandled = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        down = nil; rightHandled = false
        guard window != nil else { return }
        // MapKit споживає частину подій, тому клік (меню), ПКМ і подвійний клік ловимо локальним монітором
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp]) { [weak self] e in self?.handle(e) ?? e }
    }
    deinit { if let m = monitor { NSEvent.removeMonitor(m) } }

    private func coord(_ p: NSPoint) -> CLLocationCoordinate2D { convert(convert(p, from: nil), toCoordinateFrom: self) }

    private func onMap(_ e: NSEvent) -> Bool {
        guard let w = window, e.window === w else { return false }
        let local = convert(e.locationInWindow, from: nil)
        guard bounds.contains(local) else { return false }
        let top = NSPoint(x: local.x, y: isFlipped ? local.y : bounds.height - local.y)
        return !blocked().contains { $0.contains(top) }
    }

    private func pin(at e: NSEvent) -> RPin? {
        let p = convert(e.locationInWindow, from: nil)
        for a in annotations {
            guard let r = a as? RPin, let v = view(for: r) else { continue }
            if convert(v.bounds, from: v).insetBy(dx: -3, dy: -3).contains(p) { return r }
        }
        return nil
    }

    /// Меню: по точці маршруту, інакше загальне меню карти.
    private func openMenu(_ e: NSEvent) {
        if let r = pin(at: e) { onPinContext?(r.wid, e) } else { onContext?(coord(e.locationInWindow), e) }
    }

    private func handle(_ e: NSEvent) -> NSEvent? {
        switch e.type {
        case .rightMouseDown:
            guard onMap(e) else { return e }
            rightHandled = true; openMenu(e); return nil
        case .rightMouseUp:
            if rightHandled { rightHandled = false; return nil }
            return e
        case .leftMouseDown:
            down = nil
            guard onMap(e) else { return e }
            if e.modifierFlags.contains(.control) { rightHandled = false; openMenu(e); return nil }
            if flyHere, e.clickCount == 2 { onDouble?(coord(e.locationInWindow)); return nil }
            down = e.locationInWindow
            return e
        case .leftMouseUp:
            // простий клік (без перетягування) відкриває меню; із «Fly to here» меню лишається на правій кнопці
            if let d = down {
                down = nil
                if !flyHere, e.clickCount == 1, hypot(e.locationInWindow.x - d.x, e.locationInWindow.y - d.y) < 4, onMap(e) { openMenu(e) }
            }
            return e
        default: return e
        }
    }
}

struct FlightMap: NSViewRepresentable {
    let ctl: MapController
    let layer: MapLayer
    let showTrack: Bool
    let track: [CLLocationCoordinate2D]
    let vehicle: CLLocationCoordinate2D?
    let vehicleHeading: Double
    var rays: RayData? = nil
    var rulerA: CLLocationCoordinate2D? = nil
    var rulerB: CLLocationCoordinate2D? = nil
    var rulerLabel = ""
    let home: CLLocationCoordinate2D?
    let pois: [POI]
    let circles: [(CLLocationCoordinate2D, Double)]
    let roiPoint: CLLocationCoordinate2D?
    let roiLine: [CLLocationCoordinate2D]
    let roiPoly: [CLLocationCoordinate2D]
    let front: [FrontPoly]
    let frontVersion: Int
    let flyHere: Bool
    struct RoutePin: Equatable { let id: UUID; let lat: Double; let lon: Double; let label: String; let cmd: Int }
    let route: [RoutePin]
    let routePath: [CLLocationCoordinate2D]
    let routeCurrent: UUID?
    var onContext: (CLLocationCoordinate2D, NSView, NSEvent) -> Void
    var onDouble: (CLLocationCoordinate2D) -> Void
    var onPinContext: (UUID, NSView, NSEvent) -> Void
    var blocked: () -> [CGRect] = { [] }

    func makeCoordinator() -> Coord { Coord() }

    func makeNSView(context: Context) -> FlightMKMapView {
        let m = FlightMKMapView()
        m.delegate = context.coordinator
        m.showsCompass = false; m.showsZoomControls = false; m.isPitchEnabled = false
        m.isRotateEnabled = true; m.isZoomEnabled = true; m.isScrollEnabled = true
        let (c, d, h) = MapController.last ?? (CLLocationCoordinate2D(latitude: 49.0, longitude: 31.5), 1_800_000, 0)
        m.setCamera(MKMapCamera(lookingAtCenter: c, fromDistance: d, pitch: 0, heading: h), animated: false)
        context.coordinator.map = m
        ctl.map = m
        return m
    }

    func updateNSView(_ m: FlightMKMapView, context: Context) {
        m.onContext = { c, e in onContext(c, m, e) }
        m.onDouble = onDouble
        m.onPinContext = { id, e in onPinContext(id, m, e) }
        m.flyHere = flyHere
        m.blocked = blocked
        context.coordinator.ctl = ctl
        context.coordinator.apply(self, to: m)
    }

    final class Coord: NSObject, MKMapViewDelegate {
        var map: MKMapView?
        var ctl: MapController?
        var curLayer: MapLayer?
        var tile: TileOverlay?
        var trackOv: MKPolyline?, trackCount = 0, trackAt = Date.distantPast, trackShown = true
        var dynOv: [MKOverlay] = [], dynSig = ""
        var frontOv: [MKOverlay] = [], frontVer = -1
        var veh: MapPin?, vehRot = -999, home: MapPin?, roi: MapPin?
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
        var routePins: [RPin] = [], routeOv: [MKOverlay] = [], routeSig = ""
        var lastHeadingPush = 0.0

        func apply(_ p: FlightMap, to m: MKMapView) {
            if p.layer != curLayer {
                curLayer = p.layer
                if let t = tile { m.removeOverlay(t); tile = nil }
                if p.layer.isTiles { let t = TileOverlay(layer: p.layer); tile = t; m.insertOverlay(t, at: 0, level: .aboveRoads) }
                m.mapType = p.layer == .appleStd ? .standard : .hybrid
            }
            // трек
            let wantTrack = p.showTrack && p.track.count > 1
            if !wantTrack { if let t = trackOv { m.removeOverlay(t); trackOv = nil; trackCount = 0 } }
            else if p.track.count != trackCount, Date().timeIntervalSince(trackAt) > 0.5 || trackOv == nil {
                let l = MKPolyline(coordinates: p.track, count: p.track.count); l.title = "track"
                m.addOverlay(l, level: .aboveLabels)
                if let o = trackOv { m.removeOverlay(o) }
                trackOv = l; trackCount = p.track.count; trackAt = Date()
            }
            // кола і область камери
            func r5(_ c: CLLocationCoordinate2D) -> String { String(format: "%.5f,%.5f", c.latitude, c.longitude) }
            let sig = p.circles.map { r5($0.0) + "/\(Int($0.1))" }.joined(separator: ";") + "|" + p.roiLine.map(r5).joined(separator: ";") + "|" + p.roiPoly.map(r5).joined(separator: ";")
            if sig != dynSig {
                dynSig = sig
                m.removeOverlays(dynOv); dynOv = []
                for c in p.circles { let o = MKCircle(center: c.0, radius: c.1); o.title = "circle"; dynOv.append(o) }
                if p.roiPoly.count >= 3 { let o = MKPolygon(coordinates: p.roiPoly, count: p.roiPoly.count); o.title = "roiPoly"; dynOv.append(o) }
                if p.roiLine.count >= 2 { let o = MKPolyline(coordinates: p.roiLine, count: p.roiLine.count); o.title = "roiLine"; dynOv.append(o) }
                for o in dynOv { m.addOverlay(o, level: .aboveLabels) }
            }
            // лінія фронту
            if p.frontVersion != frontVer {
                frontVer = p.frontVersion
                m.removeOverlays(frontOv); frontOv = []
                for f in p.front {
                    let holes: [MKPolygon] = f.rings.dropFirst().map { r in r.withUnsafeBufferPointer { MKPolygon(coordinates: $0.baseAddress!, count: r.count) } }
                    let o = f.rings[0].withUnsafeBufferPointer { MKPolygon(coordinates: $0.baseAddress!, count: f.rings[0].count, interiorPolygons: holes.isEmpty ? nil : holes) }
                    o.title = "front"; o.subtitle = f.color
                    frontOv.append(o)
                }
                for o in frontOv { m.insertOverlay(o, at: 0, level: .aboveLabels) }
            }
            // позначки
            pin(&home, kind: "home", at: p.home, title: "Home", in: m)
            pin(&roi, kind: "roi", at: p.roiPoint, title: "ROI", in: m)
            let psig = p.pois.map { "\($0.id)\(loc($0.name))\($0.lat),\($0.lon)" }.joined()
            if psig != poiSig {
                poiSig = psig
                m.removeAnnotations(poiPins); poiPins = []
                for o in p.pois { let a = MapPin(); a.kind = "poi"; a.title = o.name; a.coordinate = .init(latitude: o.lat, longitude: o.lon); poiPins.append(a) }
                m.addAnnotations(poiPins)
            }
            // маршрут місії (дублює план з розділу Mission)
            let rs = p.route.map { "\($0.id)\($0.lat),\($0.lon)\(loc($0.label))\($0.cmd)" }.joined() + (p.routeCurrent?.uuidString ?? "")
            if rs != routeSig {
                routeSig = rs
                m.removeAnnotations(routePins); m.removeOverlays(routeOv); routePins = []; routeOv = []
                for r in p.route { let a = RPin(); a.wid = r.id; a.cmd = r.cmd; a.title = r.label; a.coordinate = .init(latitude: r.lat, longitude: r.lon); routePins.append(a) }
                m.addAnnotations(routePins)
                if p.routePath.count > 1 {
                    let bg = MKPolyline(coordinates: p.routePath, count: p.routePath.count); bg.title = "rpathBG"
                    let l = MKPolyline(coordinates: p.routePath, count: p.routePath.count); l.title = "rpath"
                    routeOv = [bg, l]; for o in routeOv { m.addOverlay(o, level: .aboveLabels) }
                }
            }
            curRoute = p.routeCurrent
            if let c = p.vehicle {
                if veh == nil { let a = MapPin(); a.kind = "veh"; a.coordinate = c; veh = a; m.addAnnotation(a) } else { veh!.coordinate = c }
                updateVehicleImage(m, heading: p.vehicleHeading)
            } else if let a = veh { m.removeAnnotation(a); veh = nil }
            vehHeading = p.vehicleHeading
            syncRays(m, vehicle: p.vehicle, rays: p.rays)
            rulerLayer.sync(m, a: p.rulerA, b: p.rulerB, label: p.rulerLabel)
        }
        var vehHeading = 0.0
        var curRoute: UUID?

        func pin(_ slot: inout MapPin?, kind: String, at c: CLLocationCoordinate2D?, title: String, in m: MKMapView) {
            if let c {
                if let a = slot { if a.coordinate.latitude != c.latitude || a.coordinate.longitude != c.longitude { a.coordinate = c } }
                else { let a = MapPin(); a.kind = kind; a.title = title; a.coordinate = c; slot = a; m.addAnnotation(a) }
            } else if let a = slot { m.removeAnnotation(a); slot = nil }
        }

        func updateVehicleImage(_ m: MKMapView, heading: Double) {
            let rot = Int((heading - m.camera.heading).rounded() / 2) * 2
            guard rot != vehRot, let a = veh, let v = m.view(for: a) else { return }
            vehRot = rot
            v.image = Self.badge("location.north.fill", fg: .systemBlue, bg: NSColor.white.withAlphaComponent(0.9), size: 34, rotation: Double(rot), circle: false)
        }

        static func badge(_ symbol: String, fg: NSColor, bg: NSColor?, size: CGFloat, rotation: Double = 0, circle: Bool = true) -> NSImage {
            NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
                if circle, let bg { bg.setFill(); NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill() }
                else if let bg { bg.setFill(); NSBezierPath(ovalIn: rect.insetBy(dx: 3, dy: 3)).fill() }
                guard let sym = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                    .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size * 0.55, weight: .bold).applying(.init(paletteColors: [fg]))) else { return true }
                let t = NSAffineTransform()
                t.translateX(by: rect.midX, yBy: rect.midY); t.rotate(byDegrees: CGFloat(-rotation)); t.translateX(by: -rect.midX, yBy: -rect.midY)
                t.concat()
                let s = sym.size
                sym.draw(in: NSRect(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2, width: s.width, height: s.height))
                return true
            }
        }

        // MARK: Делегат
        func mapView(_ m: MKMapView, viewFor a: MKAnnotation) -> MKAnnotationView? {
            if let r = a as? RPin {
                let v = m.dequeueReusableAnnotationView(withIdentifier: "rp") ?? MKAnnotationView(annotation: r, reuseIdentifier: "rp")
                v.annotation = r; v.canShowCallout = false
                v.toolTip = MissionCatalog.find(r.cmd).name
                v.image = MarkerArt.image(label: r.title ?? "", cmd: r.cmd, bg: r.wid == curRoute ? .systemGreen : .systemBlue, main: 22)
                return v
            }
            guard let a = a as? MapPin else { return nil }
            if a.kind.hasPrefix("ruler") { return RulerLayer.view(for: a, in: m) }
            let v = m.dequeueReusableAnnotationView(withIdentifier: a.kind) ?? MKAnnotationView(annotation: a, reuseIdentifier: a.kind)
            v.annotation = a
            switch a.kind {
            case "veh":
                vehRot = -999
                v.image = Self.badge("location.north.fill", fg: .systemBlue, bg: NSColor.white.withAlphaComponent(0.9), size: 34, rotation: vehHeading - m.camera.heading, circle: false)
                v.zPriority = MKAnnotationViewZPriority(rawValue: 1000)
            case "rays":
                v.canShowCallout = false; v.isEnabled = false
                v.zPriority = MKAnnotationViewZPriority(rawValue: 900)
                v.image = HeadingRays.image(raysData ?? RayData(), mapHeading: m.camera.heading)
                raysKey = ""
            case "home": v.image = Self.badge("house.fill", fg: .white, bg: .systemGreen, size: 28); v.canShowCallout = true
            case "roi": v.image = Self.badge("camera.viewfinder", fg: .black, bg: .systemYellow, size: 28); v.canShowCallout = true
            default: v.image = Self.badge("mappin", fg: .white, bg: .systemRed, size: 28); v.canShowCallout = true
            }
            return v
        }

        func mapView(_ m: MKMapView, rendererFor o: MKOverlay) -> MKOverlayRenderer {
            if let t = o as? MKTileOverlay { return MKTileOverlayRenderer(tileOverlay: t) }
            if let l = o as? MKPolyline {
                let r = MKPolylineRenderer(polyline: l)
                if l.title == "rpath" || l.title == "rpathBG" {
                    r.strokeColor = l.title == "rpath" ? NSColor.systemYellow.withAlphaComponent(0.55) : NSColor.black.withAlphaComponent(0.18)
                    r.lineWidth = l.title == "rpath" ? 2.5 : 5; r.lineDashPattern = [7, 7]; r.lineCap = .round; r.lineJoin = .round
                    return r
                }
                if l.title == "ruler" { r.strokeColor = .white; r.lineWidth = 2.5; r.lineDashPattern = [8, 5]; r.lineCap = .round; return r }
                if l.title == "roiLine" { r.strokeColor = .systemYellow; r.lineWidth = 2; r.lineDashPattern = [6, 4] }
                else { r.strokeColor = .systemPurple; r.lineWidth = 3 }
                return r
            }
            if let g = o as? MKPolygon {
                let r = MKPolygonRenderer(polygon: g)
                if g.title == "front" {
                    let c = NSColor(hex: g.subtitle ?? "")
                    r.fillColor = c.withAlphaComponent(0.32); r.strokeColor = c.withAlphaComponent(0.9); r.lineWidth = 1
                } else { r.fillColor = NSColor.systemYellow.withAlphaComponent(0.28); r.strokeColor = .systemYellow; r.lineWidth = 1.5 }
                return r
            }
            if let c = o as? MKCircle {
                let r = MKCircleRenderer(circle: c)
                r.fillColor = NSColor.systemRed.withAlphaComponent(0.08); r.strokeColor = .systemRed; r.lineWidth = 2
                return r
            }
            return MKOverlayRenderer(overlay: o)
        }

        func mapViewDidChangeVisibleRegion(_ m: MKMapView) {
            let h = m.camera.heading
            MapController.last = (m.camera.centerCoordinate, m.camera.centerCoordinateDistance, h)
            updateVehicleImage(m, heading: vehHeading)
            updateRays(m)
            if abs(h - lastHeadingPush) > 0.5 {
                lastHeadingPush = h
                DispatchQueue.main.async { [weak ctl] in ctl?.heading = h }
            }
        }
    }
}

// MARK: - Кнопки на карті

/// Напівпрозора колонка збоку: масштаб, поворот і компас (скидання на північ).
struct MapControls: View {
    var ctl: MapController
    var body: some View {
        VStack(spacing: 0) {
            btn("plus", "Наблизити") { ctl.zoom(0.5) }
            Divider().frame(width: 20)
            btn("minus", "Віддалити") { ctl.zoom(2) }
            Divider().frame(width: 20).padding(.vertical, 3)
            btn("arrow.counterclockwise", "Повернути карту проти годинникової на 15°") { ctl.rotate(by: 15) }
            Button { ctl.setHeading(0) } label: {
                Image(systemName: "location.north.fill")
                    .rotationEffect(.degrees(-ctl.heading))
                    .foregroundStyle(abs(ctl.heading) < 0.5 || abs(ctl.heading - 360) < 0.5 ? Color.secondary : Color.red)
                    .frame(width: 30, height: 30).contentShape(Rectangle())
            }.buttonStyle(.plain).help("Північ угору (кут \(Int(ctl.heading))°). Карту також можна обертати двома пальцями на трекпаді")
            btn("arrow.clockwise", "Повернути карту за годинниковою на 15°") { ctl.rotate(by: -15) }
        }
        .font(.system(size: 13, weight: .semibold))
        .padding(.vertical, 4).padding(.horizontal, 3)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .opacity(0.85)
        .transaction { $0.animation = nil }
    }
    func btn(_ icon: String, _ help: String, _ f: @escaping () -> Void) -> some View {
        Button(action: f) { Image(systemName: icon).frame(width: 30, height: 28).contentShape(Rectangle()) }.buttonStyle(.plain).help(lk(help))
    }
}
