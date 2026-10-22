import Foundation
import Observation
import Darwin

/// Пульт EdgeTX з Lua-скриптом по USB Serial (VCP, 115200): текстові рядки каналів.
/// «$v1,v2,…» (R2D2: до 24 значень −1024…+1024, PWM = v/2 + 1500) або «RC p1,…,p16» (ESP-Bridge: PWM 800…2200).
@Observable
final class VCPRadio {
    var ports: [String] = []
    var port: String = UserDefaults.standard.string(forKey: "joy.vcpPort") ?? "" { didSet { UserDefaults.standard.set(port, forKey: "joy.vcpPort") } }
    var channels = [Int](repeating: 0, count: 16)
    var status = String(localized: "Порт не відкрито")
    var open = false

    @ObservationIgnored private var fd: Int32 = -1
    @ObservationIgnored private var source: DispatchSourceRead?
    @ObservationIgnored private var buffer = Data()
    @ObservationIgnored private(set) var lastFrame = Date.distantPast
    @ObservationIgnored private var frames = 0

    func refreshPorts() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        ports = names.filter { $0.hasPrefix("cu.usbmodem") }.sorted().map { "/dev/" + $0 }
        if port.isEmpty || !ports.contains(port) { port = ports.first ?? "" }
    }

    /// Значення каналів для override; 0 = «не чіпати». Якщо кадрів давно немає, повертає нулі.
    func outputs() -> [Int] { Date().timeIntervalSince(lastFrame) < 0.5 ? channels : [Int](repeating: 0, count: 16) }
    var receiving: Bool { open && Date().timeIntervalSince(lastFrame) < 0.5 }

    func openPort() {
        closePort()
        guard !port.isEmpty else { status = String(localized: "Порт не вибрано"); return }
        let f = Darwin.open(port, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard f >= 0 else { status = String(localized: "Не вдалося відкрити \(port): \(String(cString: strerror(errno)))"); return }
        var t = termios()
        tcgetattr(f, &t); cfmakeraw(&t); cfsetspeed(&t, 115200)
        t.c_cflag |= tcflag_t(CLOCAL | CREAD)
        tcsetattr(f, TCSANOW, &t)
        fd = f; open = true; frames = 0; buffer = Data()
        status = String(localized: "Очікування даних від пульта…")
        let src = DispatchSource.makeReadSource(fileDescriptor: f, queue: .main)
        src.setEventHandler { [weak self] in self?.readData() }
        src.setCancelHandler { Darwin.close(f) }
        src.resume(); source = src
    }

    func closePort() {
        source?.cancel(); source = nil
        fd = -1; open = false
        channels = [Int](repeating: 0, count: 16)
        status = String(localized: "Порт не відкрито")
    }

    private func readData() {
        var tmp = [UInt8](repeating: 0, count: 1024)
        let n = read(fd, &tmp, tmp.count)
        if n <= 0 {
            if n == 0 || (errno != EAGAIN && errno != EINTR) { closePort(); status = String(localized: "Пульт відключено") }
            return
        }
        buffer.append(contentsOf: tmp[0..<n])
        if buffer.count > 8192 { buffer.removeAll() }
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            buffer.removeSubrange(buffer.startIndex...nl)
            parse(line)
        }
    }

    private func parse(_ line: String) {
        var out = [Int](repeating: 0, count: 16)
        func ints(_ s: Substring) -> [Int] { s.split(whereSeparator: { $0 == "," || $0 == " " || $0 == ";" }).compactMap { Int($0) } }
        if line.hasPrefix("$") {
            let v = ints(line.dropFirst())
            guard v.count >= 4 else { return }
            for i in 0..<min(16, v.count) { out[i] = max(1000, min(2000, v[i] / 2 + 1500)) }
        } else if line.hasPrefix("RC") {
            let v = ints(line.dropFirst(2))
            guard v.count >= 4 else { return }
            for i in 0..<min(16, v.count) { out[i] = max(800, min(2200, v[i])) }
        } else { return }
        channels = out; lastFrame = Date(); frames += 1
        if frames == 1 || frames % 50 == 0 { status = String(localized: "Приймаю канали з пульта (кадрів: \(frames))") }
    }
}
