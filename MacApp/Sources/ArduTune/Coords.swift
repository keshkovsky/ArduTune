import Foundation

/// Формат відображення координат (Налаштування → Одиниці): десяткові градуси або MGRS (WGS84).
enum Coords {
    static var isMGRS: Bool { UserDefaults.standard.string(forKey: "units.coord") == "mgrs" }

    /// Пара координат для показу: «lat, lon» з заданою кількістю знаків або MGRS (поза 80°S…84°N: десяткові).
    static func pair(_ lat: Double, _ lon: Double, decimals: Int = 6, sep: String = ", ") -> String {
        if isMGRS, let m = mgrs(lat, lon) { return m }
        if UserDefaults.standard.string(forKey: "units.coord") == "dms" { return dms(lat, true) + " " + dms(lon, false) }
        return String(format: "%.\(decimals)f", lat) + sep + String(format: "%.\(decimals)f", lon)
    }

    /// 50°27'00.36"N
    static func dms(_ v: Double, _ isLat: Bool) -> String {
        let a = abs(v), d = Int(a), m = Int((a - Double(d)) * 60), s = (a - Double(d) - Double(m) / 60) * 3600
        return String(format: "%d°%02d'%05.2f\"", d, m, s) + (isLat ? (v < 0 ? "S" : "N") : (v < 0 ? "W" : "E"))
    }

    // MARK: WGS84 ↔ UTM (ряди Крюгера)
    private static let a = 6378137.0, f = 1 / 298.257223563, k0 = 0.9996
    private static var n: Double { f / (2 - f) }
    private static var bigA: Double { a / (1 + n) * (1 + n * n / 4 + pow(n, 4) / 64) }
    private static var e: Double { (f * (2 - f)).squareRoot() }

    static func utmZone(_ lat: Double, _ lon: Double) -> Int {
        var z = Int(floor((lon + 180) / 6)) + 1
        if lat >= 56 && lat < 64 && lon >= 3 && lon < 12 { z = 32 }
        if lat >= 72 && lat < 84 {
            if lon >= 0 && lon < 9 { z = 31 } else if lon >= 9 && lon < 21 { z = 33 } else if lon >= 21 && lon < 33 { z = 35 } else if lon >= 33 && lon < 42 { z = 37 }
        }
        return min(max(z, 1), 60)
    }

    /// (зона, схід, північ у метрах від екватора з зсувом 10 000 000 для південної півкулі)
    static func toUTM(_ lat: Double, _ lon: Double, zone zIn: Int? = nil) -> (zone: Int, e: Double, n: Double) {
        let zone = zIn ?? utmZone(lat, lon)
        let lon0 = Double(zone - 1) * 6 - 180 + 3
        let phi = lat * .pi / 180, lam = (lon - lon0) * .pi / 180
        let n = Self.n
        let al = [n / 2 - 2 * n * n / 3 + 5 * pow(n, 3) / 16, 13 * n * n / 48 - 3 * pow(n, 3) / 5, 61 * pow(n, 3) / 240]
        let t = sinh(atanh(sin(phi)) - e * atanh(e * sin(phi)))
        let xp = atan2(t, cos(lam)), ep = atanh(sin(lam) / (1 + t * t).squareRoot())
        var xi = xp, eta = ep
        for j in 1...3 {
            xi += al[j - 1] * sin(2 * Double(j) * xp) * cosh(2 * Double(j) * ep)
            eta += al[j - 1] * cos(2 * Double(j) * xp) * sinh(2 * Double(j) * ep)
        }
        return (zone, 500000 + k0 * bigA * eta, k0 * bigA * xi + (lat < 0 ? 10_000_000 : 0))
    }

    static func fromUTM(zone: Int, e: Double, n nn: Double, south: Bool) -> (lat: Double, lon: Double) {
        let n = Self.n
        let be = [n / 2 - 2 * n * n / 3 + 37 * pow(n, 3) / 96, n * n / 48 + pow(n, 3) / 15, 17 * pow(n, 3) / 480]
        let de = [2 * n - 2 * n * n / 3 - 2 * pow(n, 3), 7 * n * n / 3 - 8 * pow(n, 3) / 5, 56 * pow(n, 3) / 15]
        let xi = ((south ? nn - 10_000_000 : nn)) / (k0 * bigA), eta = (e - 500000) / (k0 * bigA)
        var xp = xi, ep = eta
        for j in 1...3 {
            xp -= be[j - 1] * sin(2 * Double(j) * xi) * cosh(2 * Double(j) * eta)
            ep -= be[j - 1] * cos(2 * Double(j) * xi) * sinh(2 * Double(j) * eta)
        }
        let chi = asin(sin(xp) / cosh(ep))
        var phi = chi
        for j in 1...3 { phi += de[j - 1] * sin(2 * Double(j) * chi) }
        let lon0 = Double(zone - 1) * 6 - 180 + 3
        return (phi * 180 / .pi, lon0 + atan2(sinh(ep), cos(xp)) * 180 / .pi)
    }

    // MARK: MGRS
    private static let bands = Array("CDEFGHJKLMNPQRSTUVWX")
    private static let colSets = [Array("ABCDEFGH"), Array("JKLMNPQR"), Array("STUVWXYZ")]
    private static let rows = Array("ABCDEFGHJKLMNPQRSTUV")

    /// MGRS з точністю 1 м у вигляді «37U DQ 12345 67890»; nil поза межами 80°S…84°N.
    static func mgrs(_ lat: Double, _ lon: Double) -> String? {
        guard lat >= -80, lat <= 84, lon >= -180, lon <= 180 else { return nil }
        let u = toUTM(lat, lon)
        let band = bands[min(Int(floor((lat + 80) / 8)), 19)]
        let e100 = Int(floor(u.e / 100000)), n100 = Int(floor(u.n / 100000))
        guard e100 >= 1, e100 <= 8 else { return nil }
        let col = colSets[(u.zone - 1) % 3][e100 - 1]
        let row = rows[(n100 + (u.zone % 2 == 0 ? 5 : 0)) % 20]
        let ee = Int(u.e.truncatingRemainder(dividingBy: 100000)), nn = Int(u.n.truncatingRemainder(dividingBy: 100000))
        return String(format: "%d%@ %@%@ %05d %05d", u.zone, String(band), String(col), String(row), ee, nn)
    }

    /// Розбір MGRS («37U DQ 12345 67890», з пробілами чи без, 2–10 цифр).
    static func parseMGRS(_ s: String) -> (Double, Double)? {
        let t = s.uppercased().filter { !$0.isWhitespace }
        guard let m = t.range(of: #"^(\d{1,2})([C-HJ-NP-X])([A-HJ-NP-Z])([A-HJ-NP-V])(\d{0,10})$"#, options: .regularExpression) else { return nil }
        let str = String(t[m])
        let ch = Array(str)
        var i = 0
        var zs = ""
        while i < ch.count, ch[i].isNumber { zs.append(ch[i]); i += 1 }
        guard let zone = Int(zs), zone >= 1, zone <= 60, i + 3 <= ch.count else { return nil }
        let band = ch[i], col = ch[i + 1], row = ch[i + 2]
        let digits = String(ch[(i + 3)...])
        guard digits.count % 2 == 0, let bi = bands.firstIndex(of: band), let ci = colSets[(zone - 1) % 3].firstIndex(of: col), let ri = rows.firstIndex(of: row) else { return nil }
        let half = digits.count / 2
        let scale = pow(10, Double(5 - half))
        let ee = (half > 0 ? Double(digits.prefix(half))! : 0) * scale, nn = (half > 0 ? Double(digits.suffix(half))! : 0) * scale
        let east = Double(ci + 1) * 100000 + ee
        let south = bi < 10                                  // смуги C…M південні
        // північ: найменша північ у смузі + кратне 2 000 000, що збігається з літерою ряду
        let latMin = Double(bi) * 8 - 80
        let minN = toUTM(latMin == 80 ? 79.99 : latMin + 0.0001, Double(zone - 1) * 6 - 180 + 3, zone: zone).n
        let rowN = Double(((ri - (zone % 2 == 0 ? 5 : 0)) % 20 + 20) % 20) * 100000 + nn
        var north = rowN
        while north < minN - 1000 { north += 2_000_000 }
        let p = fromUTM(zone: zone, e: east, n: north, south: north < 10_000_000 && latMin < 0 ? south : false)
        return p
    }

    /// Розбір довільного тексту: MGRS або «lat, lon» (через кому, крапку з комою чи пробіл).
    static func parse(_ s: String) -> (Double, Double)? {
        if let p = parseMGRS(s) { return p }
        let parts = s.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == " " || $0 == "\t" }).compactMap { Double($0) }
        if parts.count == 2, abs(parts[0]) <= 90, abs(parts[1]) <= 180 { return (parts[0], parts[1]) }
        return nil
    }
}
