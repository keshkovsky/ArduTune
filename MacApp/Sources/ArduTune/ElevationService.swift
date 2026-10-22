import Foundation

/// Висоти рельєфу з відкритого API Open-Meteo (Copernicus DEM, ~90 м) з кешем у пам'яті; до 100 точок на запит.
actor ElevationService {
    static let shared = ElevationService()
    private var cache: [String: Double] = [:]

    private static func key(_ p: (Double, Double)) -> String { String(format: "%.5f,%.5f", p.0, p.1) }

    /// Висоти (м над рівнем моря) для списку (широта, довгота); nil, якщо мережі немає.
    func elevations(_ pts: [(Double, Double)]) async -> [Double?] {
        let missing = Array(Set(pts.map(Self.key).filter { cache[$0] == nil }))
        for chunk in stride(from: 0, to: missing.count, by: 100).map({ Array(missing[$0..<min($0 + 100, missing.count)]) }) {
            if Task.isCancelled { break }
            let lat = chunk.map { String($0.split(separator: ",")[0]) }.joined(separator: ",")
            let lon = chunk.map { String($0.split(separator: ",")[1]) }.joined(separator: ",")
            guard let url = URL(string: "https://api.open-meteo.com/v1/elevation?latitude=\(lat)&longitude=\(lon)") else { break }
            var req = URLRequest(url: url); req.timeoutInterval = 20
            guard let (d, resp) = try? await URLSession.shared.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200,
                  let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let e = j["elevation"] as? [Double], e.count == chunk.count else { break }
            for (k, v) in zip(chunk, e) { cache[k] = v }
        }
        return pts.map { cache[Self.key($0)] }
    }
}
