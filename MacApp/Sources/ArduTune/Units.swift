import Foundation

/// Одиниці виміру для відображення: відстань, висота й швидкість (налаштування застосунку, розділ «Налаштування ArduTune»).
/// Як і в Mission Planner, вкладки параметрів і редактор місії лишаються в «сирих» метрах і м/с.
enum Units {
    private static var d: UserDefaults { .standard }
    static var distKey: String { d.string(forKey: "units.dist") ?? "m" }     // m | ft
    static var altKey: String { d.string(forKey: "units.alt") ?? "m" }       // m | ft
    static var speedKey: String { d.string(forKey: "units.speed") ?? "ms" }  // ms | kmh | mph | kn
    static var isMetric: Bool { distKey == "m" && altKey == "m" && speedKey == "ms" }

    static let ftPerM = 3.280839895
    static let mPerMile = 1609.344

    // Числові значення в обраних одиницях
    static func distValue(_ m: Double) -> Double { distKey == "ft" ? m * ftPerM : m }
    static func altValue(_ m: Double) -> Double { altKey == "ft" ? m * ftPerM : m }
    static func speedValue(_ ms: Double) -> Double {
        switch speedKey { case "kmh": return ms * 3.6; case "mph": return ms * 2.2369362921; case "kn": return ms * 1.9438444924; default: return ms }
    }

    // Підписи (en: для англомовних шкал HUD)
    static func distLabel(en: Bool = false) -> String { distKey == "ft" ? (en ? "ft" : "фт") : (en ? "m" : "м") }
    static func altLabel(en: Bool = false) -> String { altKey == "ft" ? (en ? "ft" : "фт") : (en ? "m" : "м") }
    static func speedLabel(en: Bool = false) -> String {
        switch speedKey {
        case "kmh": return en ? "km/h" : "км/год"
        case "mph": return en ? "mph" : "миль/год"
        case "kn": return en ? "kn" : "вуз."
        default: return en ? "m/s" : "м/с"
        }
    }

    // Готові рядки
    /// Відстань: метри/фути, великі значення в км/милях.
    static func dist(_ m: Double, digits: Int = 0, en: Bool = false) -> String {
        if distKey == "ft" {
            if abs(m) >= mPerMile { return String(format: "%.2f ", m / mPerMile) + (en ? "mi" : "миль") }
            return String(format: "%.\(digits)f ", m * ftPerM) + distLabel(en: en)
        }
        if abs(m) >= 1000 { return String(format: "%.2f ", m / 1000) + (en ? "km" : "км") }
        return String(format: "%.\(digits)f ", m) + distLabel(en: en)
    }
    static func alt(_ m: Double, digits: Int = 0, en: Bool = false) -> String { String(format: "%.\(digits)f ", altValue(m)) + altLabel(en: en) }
    static func speed(_ ms: Double, digits: Int = 1, en: Bool = false) -> String { String(format: "%.\(digits)f ", speedValue(ms)) + speedLabel(en: en) }
    /// Лише число без одиниці.
    static func altNum(_ m: Double, digits: Int = 0) -> String { String(format: "%.\(digits)f", altValue(m)) }
    static func speedNum(_ ms: Double, digits: Int = 1) -> String { String(format: "%.\(digits)f", speedValue(ms)) }
    static func distNum(_ m: Double, digits: Int = 0) -> String { String(format: "%.\(digits)f", distValue(m)) }
}
