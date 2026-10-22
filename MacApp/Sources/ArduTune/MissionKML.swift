import SwiftUI
import MapKit
import AppKit

// MARK: - KML: експорт і імпорт плану

enum MissionKML {
    static func esc(_ s: String) -> String { s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;") }
    static func c(_ lat: Double, _ lon: Double, _ alt: Double) -> String { String(format: "%.7f,%.7f,%.1f", lon, lat, alt) }

    static func export(_ m: MissionStore) -> String {
        var x = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<kml xmlns=\"http://www.opengis.net/kml/2.2\"><Document>\n<name>ArduTune</name>\n"
        x += "<Style id=\"route\"><LineStyle><color>ff00ffff</color><width>3</width></LineStyle></Style>\n"
        x += "<Style id=\"area\"><LineStyle><color>ffff00ff</color><width>2</width></LineStyle><PolyStyle><color>33ff00ff</color></PolyStyle></Style>\n"
        x += "<Style id=\"fenceIn\"><LineStyle><color>ff00ff00</color><width>2</width></LineStyle><PolyStyle><color>2200ff00</color></PolyStyle></Style>\n"
        x += "<Style id=\"fenceEx\"><LineStyle><color>ff0000ff</color><width>2</width></LineStyle><PolyStyle><color>440000ff</color></PolyStyle></Style>\n"
        let pts = m.items.enumerated().filter { $0.element.def.nav && $0.element.hasPos }
        if pts.count > 1 {
            x += "<Placemark><name>Маршрут</name><styleUrl>#route</styleUrl><LineString><altitudeMode>relativeToGround</altitudeMode><coordinates>"
            x += pts.map { c($0.element.lat, $0.element.lon, $0.element.alt) }.joined(separator: " ")
            x += "</coordinates></LineString></Placemark>\n"
        }
        for (i, it) in m.items.enumerated() where it.hasPos && it.group == nil {
            x += String(localized: "<Placemark><name>\(i + 1) \(esc(it.def.name))</name><description>cmd \(it.cmd), висота \(Int(it.alt)) м</description><Point><altitudeMode>relativeToGround</altitudeMode><coordinates>\(c(it.lat, it.lon, it.alt))</coordinates></Point></Placemark>\n")
        }
        for (i, s) in m.surveys.enumerated() where s.pts.count >= 3 {
            let ring = (s.pts + [s.pts[0]]).map { c($0.lat, $0.lon, 0) }.joined(separator: " ")
            x += String(localized: "<Placemark><name>Ділянка \(i + 1)</name><styleUrl>#area</styleUrl><Polygon><outerBoundaryIs><LinearRing><coordinates>\(ring)</coordinates></LinearRing></outerBoundaryIs></Polygon></Placemark>\n")
        }
        for (i, z) in m.zones.enumerated() {
            if z.isCircle, let p = z.pts.first {
                let ring = (0...36).map { k -> String in
                    let a = Double(k) * 10 * .pi / 180
                    return c(p.lat + z.radius * cos(a) / 111_320, p.lon + z.radius * sin(a) / (111_320 * cos(p.lat * .pi / 180)), 0)
                }.joined(separator: " ")
                x += String(localized: "<Placemark><name>Геозона \(i + 1) (коло \(Int(z.radius)) м)</name><styleUrl>#\(z.exclusion ? "fenceEx" : "fenceIn")</styleUrl><Polygon><outerBoundaryIs><LinearRing><coordinates>\(ring)</coordinates></LinearRing></outerBoundaryIs></Polygon></Placemark>\n")
            } else if z.pts.count >= 3 {
                let ring = (z.pts + [z.pts[0]]).map { c($0.lat, $0.lon, 0) }.joined(separator: " ")
                x += String(localized: "<Placemark><name>Геозона \(i + 1)</name><styleUrl>#\(z.exclusion ? "fenceEx" : "fenceIn")</styleUrl><Polygon><outerBoundaryIs><LinearRing><coordinates>\(ring)</coordinates></LinearRing></outerBoundaryIs></Polygon></Placemark>\n")
            }
        }
        for (i, r) in m.rally.enumerated() {
            x += "<Placemark><name>Rally \(i + 1)</name><Point><altitudeMode>relativeToGround</altitudeMode><coordinates>\(c(r.lat, r.lon, r.alt))</coordinates></Point></Placemark>\n"
        }
        return x + "</Document></kml>\n"
    }

    /// Результат розбору: точки (Point і вершини LineString) та багатокутники.
    struct Parsed { var points: [(lat: Double, lon: Double, alt: Double)] = []; var polygons: [[(Double, Double)]] = [] }

    final class Parser: NSObject, XMLParserDelegate {
        var res = Parsed()
        private var text = ""
        private var kind = ""            // Point | LineString | Polygon
        private var inOuter = false
        func parser(_ p: XMLParser, didStartElement e: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            text = ""
            switch e { case "Point", "LineString", "Polygon": kind = e; case "outerBoundaryIs": inOuter = true; default: break }
        }
        func parser(_ p: XMLParser, foundCharacters s: String) { text += s }
        func parser(_ p: XMLParser, didEndElement e: String, namespaceURI: String?, qualifiedName: String?) {
            if e == "outerBoundaryIs" { inOuter = false }
            guard e == "coordinates" else { return }
            let pts: [(Double, Double, Double)] = text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" }).compactMap { tok in
                let v = tok.split(separator: ",").compactMap { Double($0) }
                return v.count >= 2 ? (v[1], v[0], v.count > 2 ? v[2] : 0) : nil
            }
            switch kind {
            case "Point", "LineString": res.points += pts.map { ($0.0, $0.1, $0.2) }
            case "Polygon": if inOuter || true { var ring = pts.map { ($0.0, $0.1) }; if ring.count > 1, ring.first! == ring.last! { ring.removeLast() }; if ring.count >= 3 { res.polygons.append(ring) } }
            default: break
            }
        }
    }

    static func parse(_ data: Data) -> Parsed? {
        let p = Parser(); let x = XMLParser(data: data); x.delegate = p
        return x.parse() ? p.res : nil
    }
}

extension MissionStore {
    /// Додає до плану точки й ділянки з KML. LineString і Point стають точками маршруту, Polygon стає ділянкою обліту.
    @discardableResult
    func importKML(_ data: Data) -> Bool {
        guard let r = MissionKML.parse(data), !(r.points.isEmpty && r.polygons.isEmpty) else { error = String(localized: "У KML немає точок, ліній чи багатокутників"); return false }
        error = nil
        // LineString дублює Point-и (експорт ArduTune): якщо точок багато підряд однакових, прибираємо повтори
        var seen = Set<String>(); var uniq: [(lat: Double, lon: Double, alt: Double)] = []
        for p in r.points { let k = String(format: "%.6f,%.6f", p.lat, p.lon); if seen.insert(k).inserted { uniq.append(p) } }
        for p in uniq {
            var it = makeItem(16, at: .init(latitude: p.lat, longitude: p.lon))
            if p.alt > 0 { it.alt = p.alt }
            items.append(it)
        }
        for ring in r.polygons {
            var s = SurveyArea(); s.pts = ring.map { GeoPt(lat: $0.0, lon: $0.1) }; s.alt = defaultAlt; s.frame = defaultFrame
            s.fov = UserDefaults.standard.object(forKey: "cam.fov") as? Double ?? 60
            withoutRecording { surveys.append(s) }
            regenerate(s); selectedSurvey = s.id
        }
        note = String(localized: "Додано з KML: \(uniq.count) точок, \(r.polygons.count) ділянок")
        return true
    }
}
