import Foundation

/// Розбір бінарних Dataflash-логів ArduPilot (.bin): формат FMT (тип 128), індекс повідомлень, витяг полів.
final class DFLog {
    struct Fmt {
        let type: UInt8
        let length: Int
        let name: String
        let format: [Character]
        let labels: [String]
        let offsets: [Int]          // зміщення кожного поля від початку тіла
        var timeField: Int? { labels.firstIndex(of: "TimeUS") ?? labels.firstIndex(of: "TimeMS") }
        var timeScale: Double { labels.contains("TimeUS") ? 1e-6 : 1e-3 }
    }

    struct Msg { let name: String; let time: Double; let text: String; var hint: String = "" }

    let data: Data
    let url: URL?
    private(set) var fmts: [UInt8: Fmt] = [:]
    private(set) var byName: [String: Fmt] = [:]
    private(set) var index: [UInt8: [Int]] = [:]       // тип -> зміщення початку тіла повідомлення
    private(set) var order: [String] = []               // імена типів у порядку появи
    private(set) var startTime = 0.0, endTime = 0.0     // секунди (з TimeUS)
    private(set) var messageCount = 0

    private var seriesCache: [String: [(t: Double, v: Double)]] = [:]
    private let cacheLock = NSLock()
    /// Обмеження за часом (с від початку логу): усі вибірки, повідомлення й траєкторія повертаються лише в цих межах.
    private(set) var clip: (from: Double, to: Double)?

    /// Копія з тими ж розібраними даними, але з обмеженням часу: для аналізу лише вибраної ділянки польоту.
    func clipped(from: Double, to: Double) -> DFLog { DFLog(base: self, clip: (from, to)) }
    private init(base b: DFLog, clip: (Double, Double)) {
        data = b.data; url = b.url; fmts = b.fmts; byName = b.byName; index = b.index; order = b.order
        startTime = b.startTime; endTime = b.endTime; messageCount = b.messageCount
        self.clip = clip
    }
    @inline(__always) private func inClip(_ t: Double) -> Bool { guard let c = clip else { return true }; return t >= c.from && t <= c.to }

    static func size(of c: Character) -> Int {
        switch c {
        case "b", "B", "M": return 1
        case "h", "H", "c", "C": return 2
        case "i", "I", "f", "n", "e", "E", "L": return 4
        case "q", "Q", "d": return 8
        case "N": return 16
        case "Z", "a": return 64
        default: return 0
        }
    }

    init?(url: URL) {
        guard let d = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        self.data = d; self.url = url
        if !parse() { return nil }
    }

    // MARK: Індексація
    private func parse() -> Bool {
        let n = data.count
        var firstT = Double.infinity, lastT = 0.0
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let b = raw.bindMemory(to: UInt8.self)
            var i = 0
            while i + 3 <= n {
                if b[i] != 0xA3 || b[i + 1] != 0x95 { i += 1; continue }
                let type = b[i + 2]
                if type == 128 {
                    guard i + 89 <= n else { break }
                    let t = b[i + 3], len = Int(b[i + 4])
                    func str(_ from: Int, _ cnt: Int) -> String {
                        var e = from + cnt; while e > from && b[e - 1] == 0 { e -= 1 }
                        return String(decoding: UnsafeBufferPointer(rebasing: b[from..<e]), as: UTF8.self)
                    }
                    let name = str(i + 5, 4), fmt = str(i + 9, 16), labels = str(i + 25, 64)
                    var offs: [Int] = []; var o = 0
                    for c in fmt { offs.append(o); o += Self.size(of: c) }
                    let f = Fmt(type: t, length: len, name: name, format: Array(fmt), labels: labels.split(separator: ",").map(String.init), offsets: offs)
                    fmts[t] = f; byName[name] = f
                    if !order.contains(name) { order.append(name) }
                    i += 89; messageCount += 1
                    continue
                }
                if type == 127 {        // «довгий FMT» (перетворені tlog): ім'я 40, формат 24, мітки 256
                    guard i + 325 <= n else { break }
                    let t = b[i + 3], len = Int(b[i + 4])
                    func lstr(_ from: Int, _ cnt: Int) -> String {
                        var e = from + cnt; while e > from && b[e - 1] == 0 { e -= 1 }
                        return String(decoding: UnsafeBufferPointer(rebasing: b[from..<e]), as: UTF8.self)
                    }
                    let name = lstr(i + 5, 40), fmt = lstr(i + 45, 24), labels = lstr(i + 69, 256)
                    var offs: [Int] = []; var o = 0
                    for c in fmt { offs.append(o); o += Self.size(of: c) }
                    let f = Fmt(type: t, length: len, name: name, format: Array(fmt), labels: labels.split(separator: ",").map(String.init), offsets: offs)
                    fmts[t] = f; byName[name] = f
                    if !order.contains(name) { order.append(name) }
                    i += 325; messageCount += 1
                    continue
                }
                guard let f = fmts[type], f.length >= 3 else { i += 1; continue }
                if i + f.length > n { break }
                index[type, default: []].append(i + 3)
                messageCount += 1
                if let tf = f.timeField, tf == 0 {
                    // Час першого поля: читаємо Q (TimeUS) або I (TimeMS)
                    let off = i + 3
                    let v: Double
                    if f.format[0] == "Q" { v = Double(UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: off, as: UInt64.self))) * 1e-6 }
                    else { v = Double(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: off, as: UInt32.self))) * 1e-3 }
                    if v > 0 { if v < firstT { firstT = v }; if v > lastT { lastT = v } }
                }
                i += f.length
            }
        }
        startTime = firstT.isFinite ? firstT : 0; endTime = max(lastT, startTime)
        return !fmts.isEmpty && messageCount > 0
    }

    var duration: Double { let d = max(0, endTime - startTime); return clip.map { min(d, $0.to) } ?? d }
    func count(_ name: String) -> Int { byName[name].flatMap { index[$0.type]?.count } ?? 0 }
    func fields(of name: String) -> [String] { byName[name]?.labels ?? [] }

    // MARK: Декодування
    func value(_ f: Fmt, _ field: Int, at body: Int) -> Double {
        let o = body + f.offsets[field]
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Double in
            func ld<T>(_ t: T.Type) -> T { raw.loadUnaligned(fromByteOffset: o, as: t) }
            switch f.format[field] {
            case "b": return Double(ld(Int8.self))
            case "B", "M": return Double(ld(UInt8.self))
            case "h": return Double(Int16(littleEndian: ld(Int16.self)))
            case "H": return Double(UInt16(littleEndian: ld(UInt16.self)))
            case "c": return Double(Int16(littleEndian: ld(Int16.self))) * 0.01
            case "C": return Double(UInt16(littleEndian: ld(UInt16.self))) * 0.01
            case "i": return Double(Int32(littleEndian: ld(Int32.self)))
            case "I": return Double(UInt32(littleEndian: ld(UInt32.self)))
            case "e": return Double(Int32(littleEndian: ld(Int32.self))) * 0.01
            case "E": return Double(UInt32(littleEndian: ld(UInt32.self))) * 0.01
            case "L": return Double(Int32(littleEndian: ld(Int32.self))) * 1e-7
            case "f": return Double(Float(bitPattern: UInt32(littleEndian: ld(UInt32.self))))
            case "d": return Double(bitPattern: UInt64(littleEndian: ld(UInt64.self)))
            case "q": return Double(Int64(littleEndian: ld(Int64.self)))
            case "Q": return Double(UInt64(littleEndian: ld(UInt64.self)))
            default: return .nan
            }
        }
    }

    func string(_ f: Fmt, _ field: Int, at body: Int) -> String {
        let o = body + f.offsets[field], len = Self.size(of: f.format[field])
        guard o + len <= data.count else { return "" }
        var e = o + len
        while e > o && data[e - 1] == 0 { e -= 1 }
        return String(decoding: data[o..<e], as: UTF8.self)
    }

    func time(_ f: Fmt, at body: Int) -> Double {
        guard let tf = f.timeField else { return 0 }
        return value(f, tf, at: body) * f.timeScale - startTime
    }

    /// Послідовність значень поля в часі (секунди від початку логу).
    func series(_ msg: String, _ field: String) -> [(t: Double, v: Double)] {
        let key = msg + "." + field
        cacheLock.lock(); let cached = seriesCache[key]; cacheLock.unlock()
        if let c = cached { return c }
        guard let f = byName[msg], let fi = f.labels.firstIndex(of: field), fi < f.format.count, f.format[fi] != "N", f.format[fi] != "Z", f.format[fi] != "n",
              let offs = index[f.type] else { return [] }
        var out: [(t: Double, v: Double)] = []
        out.reserveCapacity(offs.count)
        for o in offs { let t = time(f, at: o); if inClip(t) { out.append((t, value(f, fi, at: o))) } }
        cacheLock.lock(); seriesCache[key] = out; cacheLock.unlock()
        return out
    }

    /// Рядкове поле за всіма повідомленнями типу (MSG, PARM…).
    func rows(_ msg: String) -> [(t: Double, f: Fmt, body: Int)] { rawRows(msg).filter { inClip($0.t) } }
    private func rawRows(_ msg: String) -> [(t: Double, f: Fmt, body: Int)] {
        guard let f = byName[msg], let offs = index[f.type] else { return [] }
        return offs.map { (time(f, at: $0), f, $0) }
    }

    // MARK: Текстові повідомлення
    private(set) lazy var messages: [Msg] = {
        var res: [Msg] = []
        for r in rows("MSG") {
            if let i = r.f.labels.firstIndex(of: "Message") { res.append(Msg(name: "MSG", time: r.t, text: string(r.f, i, at: r.body))) }
        }
        for r in rows("MODE") {
            let m = r.f.labels.firstIndex(of: "Mode").map { Int(value(r.f, $0, at: r.body)) } ?? 0
            let mn = r.f.labels.firstIndex(of: "ModeNum").map { Int(value(r.f, $0, at: r.body)) } ?? m
            res.append(Msg(name: "MODE", time: r.t, text: String(localized: "Режим: \(modeName(mn))")))
        }
        for r in rows("ERR") {
            let sub = r.f.labels.firstIndex(of: "Subsys").map { Int(value(r.f, $0, at: r.body)) } ?? 0
            let code = r.f.labels.firstIndex(of: "ECode").map { Int(value(r.f, $0, at: r.body)) } ?? 0
            res.append(Msg(name: "ERR", time: r.t, text: String(localized: "Помилка: \(DFLog.errSubsys(sub)) (код \(code))"), hint: LogKnowledge.errMeaning(subsys: sub, code: code)))
        }
        for r in rows("EV") {
            let id = r.f.labels.firstIndex(of: "Id").map { Int(value(r.f, $0, at: r.body)) } ?? 0
            res.append(Msg(name: "EV", time: r.t, text: String(localized: "Подія: \(DFLog.event(id))")))
        }
        return res.sorted { $0.time < $1.time }
    }()

    /// Тип апарата за логом: copter, plane, rover, sub (з повідомлення MSG про версію; запасний шлях: за наявними типами записів).
    private(set) lazy var kind: String = {
        for r in rawRows("MSG").prefix(80) {
            guard let i = r.f.labels.firstIndex(of: "Message") else { continue }
            let t = string(r.f, i, at: r.body)
            if t.hasPrefix("ArduPlane") { return "plane" }
            if t.hasPrefix("ArduCopter") { return "copter" }
            if t.hasPrefix("ArduRover") || t.hasPrefix("Rover") { return "rover" }
            if t.hasPrefix("ArduSub") { return "sub" }
        }
        if byName["TECS"] != nil || byName["ARSP"] != nil && byName["CTUN"] != nil && byName["PIDP"] != nil && byName["QTUN"] != nil { return "plane" }
        return "copter"
    }()
    func modeName(_ n: Int) -> String { DFLog.modeName(n, kind: kind) }

    static let planeModes: [Int: String] = [0: "Manual", 1: "Circle", 2: "Stabilize", 3: "Training", 4: "Acro", 5: "FBWA", 6: "FBWB", 7: "Cruise", 8: "AutoTune", 10: "Auto", 11: "RTL", 12: "Loiter", 13: "Takeoff", 14: "Avoid_ADSB", 15: "Guided", 16: "Initialising", 17: "QStabilize", 18: "QHover", 19: "QLoiter", 20: "QLand", 21: "QRTL", 22: "QAutoTune", 23: "QAcro", 24: "Thermal", 25: "Loiter to QLand", 26: "AutoLand"]
    static let roverModes: [Int: String] = [0: "Manual", 1: "Acro", 3: "Steering", 4: "Hold", 5: "Loiter", 6: "Follow", 7: "Simple", 8: "Dock", 9: "Circle", 10: "Auto", 11: "RTL", 12: "SmartRTL", 15: "Guided", 16: "Initialising"]
    static let subModes: [Int: String] = [0: "Stabilize", 1: "Acro", 2: "AltHold", 3: "Auto", 4: "Guided", 7: "Circle", 9: "Surface", 16: "PosHold", 19: "Manual"]
    static func modeName(_ n: Int, kind: String) -> String {
        switch kind {
        case "plane": return planeModes[n] ?? "Mode \(n)"
        case "rover": return roverModes[n] ?? "Mode \(n)"
        case "sub": return subModes[n] ?? "Mode \(n)"
        default: return copterMode(n)
        }
    }

    var vehicleName: String { messages.first { $0.name == "MSG" && ($0.text.hasPrefix("Ardu") || $0.text.hasPrefix("PX4") || $0.text.hasPrefix("Rover")) }?.text ?? "ArduPilot" }

    /// Усі параметри з логу (останнє значення кожного).
    private(set) lazy var parameters: [(name: String, value: Double)] = {
        guard let f = byName["PARM"], let ni = f.labels.firstIndex(of: "Name"), let vi = f.labels.firstIndex(of: "Value") else { return [] }
        var d: [String: Double] = [:]; var ord: [String] = []
        for o in index[f.type] ?? [] {
            let n = string(f, ni, at: o)
            if d[n] == nil { ord.append(n) }
            d[n] = value(f, vi, at: o)
        }
        return ord.sorted().map { ($0, d[$0]!) }
    }()

    /// Траєкторія за GPS: (t, lat, lon, alt).
    func track() -> [(t: Double, lat: Double, lon: Double, alt: Double)] {
        var name = "GPS"
        if byName["GPS"] == nil { name = "GPS2" }
        guard let f = byName[name], let la = f.labels.firstIndex(of: "Lat"), let lo = f.labels.firstIndex(of: "Lng"), let offs = index[f.type] else { return [] }
        let st = f.labels.firstIndex(of: "Status"), al = f.labels.firstIndex(of: "Alt")
        var res: [(Double, Double, Double, Double)] = []
        for o in offs {
            if let st, value(f, st, at: o) < 3 { continue }
            let lat = value(f, la, at: o), lon = value(f, lo, at: o)
            if abs(lat) < 0.001 && abs(lon) < 0.001 { continue }
            let t = time(f, at: o); if !inClip(t) { continue }
            res.append((t, lat, lon, al.map { value(f, $0, at: o) } ?? 0))
        }
        return res
    }

    /// Режими в часі: (t, номер режиму).
    func modeTimeline() -> [(t: Double, mode: Int)] {
        guard let f = byName["MODE"] else { return [] }
        let mi = f.labels.firstIndex(of: "ModeNum") ?? f.labels.firstIndex(of: "Mode") ?? 1
        return (index[f.type] ?? []).compactMap { o in let t = time(f, at: o); return inClip(t) ? (t, Int(value(f, mi, at: o))) : nil }
    }

    // MARK: Довідники
    static let copterModes: [Int: String] = [0: "Stabilize", 1: "Acro", 2: "AltHold", 3: "Auto", 4: "Guided", 5: "Loiter", 6: "RTL", 7: "Circle", 9: "Land", 11: "Drift", 13: "Sport", 14: "Flip", 15: "AutoTune", 16: "PosHold", 17: "Brake", 18: "Throw", 19: "Avoid_ADSB", 20: "Guided_NoGPS", 21: "Smart_RTL", 22: "FlowHold", 23: "Follow", 24: "ZigZag", 25: "SystemID", 26: "Heli_Autorotate", 27: "Auto RTL"]
    static func copterMode(_ n: Int) -> String { copterModes[n] ?? "Mode \(n)" }
    static func errSubsys(_ n: Int) -> String {
        let t = [1: "Main", 2: "Radio", 3: "Compass", 4: "Optical flow", 5: "Radio failsafe", 6: "Battery failsafe", 7: "GPS failsafe", 8: "GCS failsafe", 9: "Fence failsafe", 10: "Flight mode", 11: "GPS", 12: "Crash check", 13: "Flip", 14: "Autotune", 15: "Parachute", 16: "EKF check", 17: "EKF failsafe", 18: "Barometer", 19: "CPU", 20: "ADSB failsafe", 21: "Terrain failsafe", 22: "Navigation", 23: "Terrain failsafe", 24: "EKF primary", 25: "Thrust loss check", 26: "Sensor failsafe", 27: "Leak failsafe", 28: "Pilot input", 29: "Vibration failsafe", 30: "Internal error", 31: "Deadreckon failsafe"]
        return t[n] ?? "Subsys \(n)"
    }
    static func event(_ n: Int) -> String {
        let t = [10: "Armed", 11: "Disarmed", 15: "Auto armed", 16: "Land complete maybe", 17: "Land complete", 18: "Lost GPS", 19: "Flip start", 21: "Flip end", 25: "Set home", 28: "Not landed", 29: "Land complete (not landed)", 30: "Set simple on", 31: "Set simple off", 32: "Not landed", 36: "Set super simple", 39: "Parachute disabled", 40: "Parachute enabled", 41: "Parachute released", 46: "Land repo active", 49: "SurfaceTracking", 52: "Disarm: motors interlock", 53: "Emergency stop", 54: "Emergency stop released", 56: "Mission start", 57: "Mission end", 58: "RTL start", 63: "Gripper grab", 64: "Gripper release", 67: "Zigzag store A", 69: "Zigzag store B", 80: "Throw ended", 81: "Take off", 86: "Surface", 87: "Not surface", 88: "Bottom"]
        return t[n] ?? "Event \(n)"
    }
}
