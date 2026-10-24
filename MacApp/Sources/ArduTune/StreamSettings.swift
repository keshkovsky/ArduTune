import Foundation
import Observation

/// Адреси відеопотоків (pipeline, Herelink) зберігаються у файлі в `~/Library/Application Support/ArduTune/Video/streams.json`
/// (поза програмою й поза налаштуваннями, які експортуються в профіль), бо pipeline може містити логін і пароль камери.
@Observable
final class StreamSettings {
    static let shared = StreamSettings()
    static let defaultPipeline = "rtspsrc location=rtsp://192.168.0.10:8554/stream latency=0 ! rtph264depay ! h264parse ! avdec_h264"

    var pipeline = StreamSettings.defaultPipeline { didSet { save() } }
    var ip = "192.168.0.10" { didSet { let c = Self.cleanHost(ip); if c != ip { ip = c } else { save() } } }
    var port = 8554 { didSet { save() } }
    var path = "fpv_stream" { didSet { save() } }

    private struct Stored: Codable { var pipeline: String; var ip: String; var port: Int; var path: String }
    @ObservationIgnored private var loading = true

    private static var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ArduTune/Video", isDirectory: true)
        return base.appendingPathComponent("streams.json")
    }

    /// Якщо в поле адреси вставили повне посилання (rtsp://host:port/…), лишається тільки хост.
    static func cleanHost(_ s: String) -> String {
        var h = s.trimmingCharacters(in: .whitespaces)
        if let r = h.range(of: "://") { h = String(h[r.upperBound...]) }
        if let at = h.lastIndex(of: "@") { h = String(h[h.index(after: at)...]) }
        if let i = h.firstIndex(where: { $0 == ":" || $0 == "/" }) { h = String(h[..<i]) }
        return h
    }

    init() {
        if let d = try? Data(contentsOf: Self.url), let s = try? JSONDecoder().decode(Stored.self, from: d) {
            pipeline = s.pipeline; ip = s.ip; port = s.port; path = s.path
        } else {
            // Перенесення зі старих налаштувань (UserDefaults), якщо вони були.
            let ud = UserDefaults.standard
            if let p = ud.string(forKey: "video.pipeline") { pipeline = p }
            if let i = ud.string(forKey: "herelink.ip"), i == Self.cleanHost(i), !i.isEmpty { ip = i }
            if ud.object(forKey: "herelink.port") != nil { port = ud.integer(forKey: "herelink.port") }
            if let p = ud.string(forKey: "herelink.path") { path = p }
        }
        let ud = UserDefaults.standard
        for k in ["video.pipeline", "herelink.ip", "herelink.port", "herelink.path"] { ud.removeObject(forKey: k) }
        loading = false
        save()
    }

    func resetHerelink() { ip = "192.168.0.10"; port = 8554; path = "fpv_stream" }

    private func save() {
        guard !loading else { return }
        let s = Stored(pipeline: pipeline, ip: ip, port: port, path: path)
        guard let d = try? JSONEncoder().encode(s) else { return }
        let dir = Self.url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? d.write(to: Self.url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.url.path)
    }
}
