import Foundation

enum EngineAPI {
    static let base = "http://127.0.0.1:14560"

    /// Випадковий токен цього запуску: застосунок передає його двигуну в середовищі й додає до кожного запиту.
    /// Інші програми й веб-сторінки токена не знають, тому двигун їм відмовляє (401).
    static let token: String = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()

    /// Запит до двигуна з токеном.
    static func request(_ url: URL, method: String? = nil) -> URLRequest {
        var r = URLRequest(url: url)
        r.setValue(token, forHTTPHeaderField: "X-ArduTune-Token")
        if let method { r.httpMethod = method }
        return r
    }

    /// POST до двигуна. completion(true) — HTTP 200; completion(false, "armed") тощо — помилка.
    static func post(_ path: String, completion: ((Bool, String?) -> Void)? = nil) {
        guard let url = URL(string: base + path) else { return }
        let r = request(url, method: "POST")
        URLSession.shared.dataTask(with: r) { data, resp, _ in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            var err: String? = nil
            if code != 200, let d = data, let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { err = j["error"] as? String }
            DispatchQueue.main.async { completion?(code == 200, err) }
        }.resume()
    }

    static func get<T: Decodable>(_ path: String, as: T.Type) async -> T? {
        guard let url = URL(string: base + path),
              let (d, _) = try? await URLSession.shared.data(for: request(url)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: d)
    }

    struct APIError: Error { let message: String }

    /// Сирі дані з двигуна (GET). Помилка двигуна (JSON {"error":…}) перетворюється на APIError.
    static func data(_ path: String) async throws -> Data {
        guard let url = URL(string: base + path) else { throw APIError(message: "URL") }
        var r = request(url); r.timeoutInterval = 120
        let (d, resp) = try await URLSession.shared.data(for: r)
        if let code = (resp as? HTTPURLResponse)?.statusCode, code != 200 { throw APIError(message: errorText(d)) }
        return d
    }

    /// POST з необов'язковим тілом, очікує завершення. Кидає APIError із текстом двигуна.
    @discardableResult
    static func send(_ path: String, body: Data? = nil) async throws -> Data {
        guard let url = URL(string: base + path) else { throw APIError(message: "URL") }
        var r = request(url, method: "POST"); r.httpBody = body; r.timeoutInterval = 120
        let (d, resp) = try await URLSession.shared.data(for: r)
        if let code = (resp as? HTTPURLResponse)?.statusCode, code != 200 { throw APIError(message: errorText(d)) }
        return d
    }

    static func errorText(_ d: Data) -> String {
        if let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let e = j["error"] as? String {
            return e == "armed" ? "Апарат ARMED: дію заблоковано" : e
        }
        return "Помилка двигуна"
    }

    static func q(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=?#"))) ?? s }
}
