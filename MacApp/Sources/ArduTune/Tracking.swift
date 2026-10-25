import Foundation
import CoreLocation
import Observation

/// Наведення антени: азимут, кут місця й відстань від станції (антени) до апарата.
struct AimResult { var azimuth: Double; var elevation: Double; var distance: Double }

enum Aim {
    /// Азимут (0…360° від півночі), кут місця над горизонтом і відстань по землі (м). `height` = різниця висот апарата й антени, м.
    static func compute(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D, height: Double) -> AimResult {
        let la1 = a.latitude * .pi / 180, la2 = b.latitude * .pi / 180, dlo = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dlo) * cos(la2), x = cos(la1) * sin(la2) - sin(la1) * cos(la2) * cos(dlo)
        let az = (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
        let dla = la2 - la1
        let h = sin(dla / 2) * sin(dla / 2) + cos(la1) * cos(la2) * sin(dlo / 2) * sin(dlo / 2)
        let d = 2 * 6_371_000 * asin(min(1, h.squareRoot()))
        return AimResult(azimuth: az, elevation: atan2(height, max(d, 0.001)) * 180 / .pi, distance: d)
    }
    static func text(_ r: AimResult) -> String {
        String(format: "%03.0f°  ·  %+.0f°  ·  ", r.azimuth, r.elevation) + Units.dist(r.distance)
    }
}

/// Позиція станції (антени): Home апарата, геолокація цього Mac або точка, задана вручну.
@Observable
final class StationStore: NSObject, CLLocationManagerDelegate {
    static let shared = StationStore()

    var source: String = UserDefaults.standard.string(forKey: "station.source") ?? "home" {
        didSet { UserDefaults.standard.set(source, forKey: "station.source"); updateLocation() }
    }
    var manualLat: Double = UserDefaults.standard.double(forKey: "station.lat") { didSet { UserDefaults.standard.set(manualLat, forKey: "station.lat") } }
    var manualLon: Double = UserDefaults.standard.double(forKey: "station.lon") { didSet { UserDefaults.standard.set(manualLon, forKey: "station.lon") } }
    var hasManual: Bool { manualLat != 0 || manualLon != 0 }
    var mac: CLLocationCoordinate2D?
    var macStatus = ""
    var aimLine = UserDefaults.standard.object(forKey: "map.aim") as? Bool ?? true { didSet { UserDefaults.standard.set(aimLine, forKey: "map.aim") } }

    @ObservationIgnored private var manager: CLLocationManager?

    func setManual(_ c: CLLocationCoordinate2D) { manualLat = c.latitude; manualLon = c.longitude; source = "manual" }

    /// Координата станції для поточного джерела (home: Home апарата чи плану).
    func coordinate(home: CLLocationCoordinate2D?) -> CLLocationCoordinate2D? {
        switch source {
        case "mac": return mac
        case "manual": return hasManual ? .init(latitude: manualLat, longitude: manualLon) : nil
        default: return home
        }
    }

    func updateLocation() {
        if source == "mac" {
            if manager == nil { let m = CLLocationManager(); m.delegate = self; m.desiredAccuracy = kCLLocationAccuracyBest; manager = m }
            manager?.requestWhenInUseAuthorization()
            manager?.startUpdatingLocation()
            macStatus = String(localized: "Визначаю положення Mac…")
        } else { manager?.stopUpdatingLocation() }
    }

    func locationManager(_ m: CLLocationManager, didUpdateLocations l: [CLLocation]) {
        if let c = l.last { mac = c.coordinate; macStatus = String(format: loc("Mac: точність %.0f м"), c.horizontalAccuracy) }
    }
    func locationManager(_ m: CLLocationManager, didFailWithError error: Error) { macStatus = String(localized: "Геолокація недоступна: \(error.localizedDescription)") }
    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        if m.authorizationStatus == .denied || m.authorizationStatus == .restricted { macStatus = String(localized: "Немає дозволу на геолокацію (Системні налаштування → Конфіденційність → Служби геолокації)") }
        else if source == "mac" { m.startUpdatingLocation() }
    }
}
