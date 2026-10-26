import Foundation
import JavaScriptCore
import Darwin
import CoreLocation
import Network

/// Послідовний порт для розширень (USB-UART): читання йде на головному потоці й віддається в JS як масив байтів.
final class AddonSerial {
    let path: String
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    var onData: ((Data) -> Void)?
    var onClose: (() -> Void)?
    var isOpen: Bool { fd >= 0 }

    init?(path: String, baud: Int) {
        let f = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard f >= 0 else { return nil }
        var t = termios()
        tcgetattr(f, &t); cfmakeraw(&t); cfsetspeed(&t, speed_t(baud))
        t.c_cflag |= tcflag_t(CLOCAL | CREAD)
        tcsetattr(f, TCSANOW, &t)
        self.path = path; fd = f
        let src = DispatchSource.makeReadSource(fileDescriptor: f, queue: .main)
        src.setEventHandler { [weak self] in self?.read() }
        src.setCancelHandler { Darwin.close(f) }
        src.resume(); source = src
    }
    private func read() {
        var buf = [UInt8](repeating: 0, count: 2048)
        let n = Darwin.read(fd, &buf, buf.count)
        if n > 0 { onData?(Data(buf[0..<n])) }
        else if n == 0 || (errno != EAGAIN && errno != EINTR) { close(); onClose?() }
    }
    func write(_ bytes: [UInt8]) -> Bool {
        guard fd >= 0 else { return false }
        var off = 0
        while off < bytes.count {
            let n = bytes[off...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if n < 0 { if errno == EAGAIN { usleep(2000); continue }; return false }
            off += n
        }
        return true
    }
    func close() { source?.cancel(); source = nil; fd = -1 }
}

/// TCP/UDP-з'єднання для розширень (RNDIS/Ethernet-пристрої). Лише приватні адреси локальної мережі.
final class AddonNet {
    private let conn: NWConnection
    private(set) var isOpen = false
    private var closed = false
    var onOpen: (() -> Void)?
    var onData: ((Data) -> Void)?
    var onClose: (() -> Void)?

    /// Приватні IPv4: 10/8, 172.16/12, 192.168/16, link-local 169.254/16.
    static func isLAN(_ host: String) -> Bool {
        let o = host.split(separator: ".").compactMap { Int($0) }
        guard o.count == 4, o.allSatisfy({ (0...255).contains($0) }) else { return false }
        return o[0] == 10 || (o[0] == 172 && (16...31).contains(o[1])) || (o[0] == 192 && o[1] == 168) || (o[0] == 169 && o[1] == 254)
    }

    init?(host: String, port: Int, udp: Bool) {
        guard AddonNet.isLAN(host), (1...65535).contains(port), let p = NWEndpoint.Port(rawValue: UInt16(port)) else { return nil }
        conn = NWConnection(host: NWEndpoint.Host(host), port: p, using: udp ? .udp : .tcp)
        conn.stateUpdateHandler = { [weak self] st in
            guard let self else { return }
            switch st {
            case .ready: self.isOpen = true; self.onOpen?(); self.receive()
            case .failed, .cancelled: self.finish()
            default: break
            }
        }
        conn.start(queue: .main)
    }
    private func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] d, _, _, err in
            guard let self, !self.closed else { return }
            if let d, !d.isEmpty { self.onData?(d) }
            if err != nil { self.finish() } else { self.receive() }
        }
    }
    private func finish() {
        guard !closed else { return }
        closed = true; isOpen = false
        onClose?()
    }
    func write(_ bytes: [UInt8]) -> Bool {
        guard isOpen, !closed else { return false }
        conn.send(content: Data(bytes), completion: .contentProcessed { _ in })
        return true
    }
    func close() { closed = true; isOpen = false; conn.cancel() }
}

/// Виконує скрипт одного розширення й надає йому API `ardutune`.
@MainActor
final class AddonRuntime {
    let addon: Addon
    unowned let manager: AddonManager
    private var ctx: JSContext!
    private var timers: [Int: Timer] = [:]
    private var nextTimer = 1
    private var ports: [Int: AddonSerial] = [:]
    private var nextPort = 1
    private var nets: [Int: AddonNet] = [:]
    private var listeners: [String: [JSValue]] = [:]
    private var lastConnected: Bool?
    private var running = false
    private var storage: [String: Any] = [:]
    private var storageLoaded = false
    private var storageURL: URL { addon.dir.appendingPathComponent("storage.json") }

    init(addon: Addon, manager: AddonManager) { self.addon = addon; self.manager = manager }

    private var store: Store? { manager.store }
    private func has(_ p: String) -> Bool { addon.granted.contains(p) }
    private func need(_ p: String) -> Bool {
        if has(p) { return true }
        fail(String(localized: "Немає дозволу: \(AddonPermission.title(p))")); return false
    }
    private func fail(_ s: String) { addon.addLog("⚠︎ " + s); addon.status = s }
    private func log(_ s: String) { addon.addLog(s) }

    // MARK: Запуск / зупинка

    func run() {
        let main = addon.dir.appendingPathComponent(addon.manifest.main ?? "main.js")
        guard let code = try? String(contentsOf: main, encoding: .utf8) else { fail(String(localized: "Немає файлу \(main.lastPathComponent)")); return }
        guard let c = JSContext() else { return }
        ctx = c
        c.name = addon.id
        c.exceptionHandler = { [weak self] _, e in
            let msg = e?.toString() ?? "?"
            let line = e?.forProperty("line")?.toInt32() ?? 0
            Task { @MainActor in self?.fail("JS: \(msg) (рядок \(line))") }
        }
        running = true
        installAPI()
        c.evaluateScript(code, withSourceURL: main)
        if addon.status.isEmpty { addon.status = String(localized: "Працює") }
        log("Запущено v\(addon.manifest.version ?? "?")")
    }

    func stop() {
        running = false
        for (_, t) in timers { t.invalidate() }
        timers = [:]
        for (_, p) in ports { p.onData = nil; p.onClose = nil; p.close() }
        ports = [:]
        for (_, n) in nets { n.onOpen = nil; n.onData = nil; n.onClose = nil; n.close() }
        nets = [:]
        listeners = [:]
        ctx = nil
    }

    // MARK: Події

    func emitTelemetry() {
        guard running, ctx != nil else { return }
        if let s = store, lastConnected != s.connected {
            lastConnected = s.connected
            emit("connection", [s.connected])
        }
        if let l = listeners["telemetry"], !l.isEmpty, has("telemetry") {
            let snap = snapshot()
            for f in l { f.call(withArguments: [snap]) }
        }
    }
    private func emit(_ ev: String, _ args: [Any]) { for f in listeners[ev] ?? [] { f.call(withArguments: args) } }

    /// Знімок телеметрії як звичайний об'єкт JS (усі прості поля структури Telemetry).
    private func snapshot() -> [String: Any] {
        guard let s = store else { return [:] }
        var d: [String: Any] = ["connected": s.connected, "armed": s.armed]
        for ch in Mirror(reflecting: s.t).children {
            guard let k = ch.label else { continue }
            let m = Mirror(reflecting: ch.value)
            if m.displayStyle == .optional { if let f = m.children.first { d[k] = f.value } else { d[k] = NSNull() } }
            else if ch.value is Double || ch.value is Int || ch.value is Bool || ch.value is String { d[k] = ch.value }
        }
        return d
    }

    // MARK: API

    private func def(_ obj: JSValue, _ name: String, _ f: @escaping ([JSValue]) -> Any?) {
        let block: @convention(block) () -> Any? = { f(JSContext.currentArguments() as? [JSValue] ?? []) }
        obj.setValue(unsafeBitCast(block, to: AnyObject.self), forProperty: name)
    }
    private func ns(_ parent: JSValue, _ name: String) -> JSValue {
        let o = JSValue(newObjectIn: ctx)!
        parent.setValue(o, forProperty: name)
        return o
    }

    private func installAPI() {
        let g = ctx.globalObject!
        let api = JSValue(newObjectIn: ctx)!
        g.setValue(api, forProperty: "ardutune")
        api.setValue(AppLanguage.current, forProperty: "lang")
        api.setValue((Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "dev", forProperty: "version")
        api.setValue(addon.dir.path, forProperty: "dir")

        // консоль
        let console = JSValue(newObjectIn: ctx)!
        g.setValue(console, forProperty: "console")
        for n in ["log", "info", "warn", "error"] {
            def(console, n) { [weak self] a in self?.log(a.map { $0.toString() ?? "" }.joined(separator: " ")); return nil }
        }
        def(api, "log") { [weak self] a in self?.log(a.map { $0.toString() ?? "" }.joined(separator: " ")); return nil }

        // таймери
        def(g, "setTimeout") { [weak self] a in self?.addTimer(a, repeats: false) }
        def(g, "setInterval") { [weak self] a in self?.addTimer(a, repeats: true) }
        for n in ["clearTimeout", "clearInterval"] {
            def(g, n) { [weak self] a in if let id = a.first?.toInt32() { self?.timers[Int(id)]?.invalidate(); self?.timers[Int(id)] = nil }; return nil }
        }

        // події
        def(api, "on") { [weak self] a in
            guard a.count >= 2, let ev = a[0].toString() else { return nil }
            if ev == "telemetry", self?.need("telemetry") != true { return nil }
            self?.listeners[ev, default: []].append(a[1]); return nil
        }

        // телеметрія
        def(api, "telemetry") { [weak self] _ in
            guard let self, self.need("telemetry") else { return nil }
            return self.snapshot()
        }

        // параметри
        let params = ns(api, "params")
        def(params, "has") { [weak self] a in guard let self, self.need("params.read"), let n = a.first?.toString() else { return false }; return self.store?.ps.has(n) ?? false }
        def(params, "get") { [weak self] a in
            guard let self, self.need("params.read"), let n = a.first?.toString(), let v = self.store?.ps.val(n) else { return nil }
            return v
        }
        def(params, "set") { [weak self] a in
            guard let self, self.need("params.write"), a.count >= 2, let n = a[0].toString(), let s = self.store else { return false }
            if s.armed { self.fail(String(localized: "Запис параметра \(n) заборонено: апарат ARMED")); return false }
            guard s.ps.has(n) else { self.fail(String(localized: "Параметра \(n) немає")); return false }
            s.ps.write(n, a[1].toDouble()); return true
        }

        // команди
        let cmd = ns(api, "cmd")
        def(cmd, "long") { [weak self] a in
            guard let self, self.need("commands"), let c = a.first?.toInt32() else { return false }
            var q = "cmd=\(c)"
            for i in 1...7 { q += "&p\(i)=\(a.count > i ? a[i].toDouble() : 0)" }
            EngineAPI.post("/cmd/long?" + q); return true
        }

        // послідовні порти
        let serial = ns(api, "serial")
        def(serial, "list") { [weak self] _ in
            guard let self, self.need("serial") else { return [] }
            let names = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
            return names.filter { $0.hasPrefix("cu.usb") }.sorted().map { "/dev/" + $0 }
        }
        def(serial, "open") { [weak self] a in
            guard let self, self.need("serial"), let path = a.first?.toString() else { return nil }
            guard path.hasPrefix("/dev/cu.") else { self.fail(String(localized: "Дозволені лише порти /dev/cu.*")); return nil }
            let baud = a.count > 1 ? Int(a[1].forProperty("baud")?.toInt32() ?? 115200) : 115200
            return self.openPort(path, baud: baud == 0 ? 115200 : baud)
        }

        // мережа (TCP/UDP, лише локальна мережа)
        let net = ns(api, "net")
        def(net, "open") { [weak self] a in
            guard let self, self.need("net"), let o = a.first, let host = o.forProperty("host")?.toString() else { return nil }
            let port = Int(o.forProperty("port")?.toInt32() ?? 0)
            let udp = (o.forProperty("proto")?.toString() ?? "tcp").lowercased() == "udp"
            return self.openNet(host, port: port, udp: udp)
        }

        // сховище
        let st = ns(api, "storage")
        def(st, "get") { [weak self] a in
            guard let self, let k = a.first?.toString() else { return nil }
            self.loadStorage()
            return self.storage[k] ?? (a.count > 1 ? a[1] : nil)
        }
        def(st, "set") { [weak self] a in
            guard let self, a.count >= 2, let k = a[0].toString() else { return nil }
            self.loadStorage()
            self.storage[k] = a[1].toObject() ?? NSNull()
            if let d = try? JSONSerialization.data(withJSONObject: self.storage, options: []) { try? d.write(to: self.storageURL) }
            return nil
        }

        // інтерфейс
        let ui = ns(api, "ui")
        def(ui, "page") { [weak self] a in
            guard let self, self.need("ui"), let o = a.first, let pid = o.forProperty("id")?.toString(), let r = o.forProperty("render"), !r.isUndefined else { return nil }
            var loc = o.forProperty("location")?.toString() ?? "addons"
            if !["addons", "optional", "flight"].contains(loc) { loc = "addons" }
            let page = AddonPage(id: "\(self.addon.id)/\(pid)", pageID: pid, title: o.forProperty("title")?.toString() ?? pid,
                                 icon: o.forProperty("icon")?.toString() ?? "puzzlepiece", location: loc, render: r)
            self.addon.pages.removeAll { $0.id == page.id }
            self.addon.pages.append(page)
            return nil
        }
        def(ui, "refresh") { _ in nil }

        // HUD
        let hud = ns(api, "hud")
        def(hud, "lines") { [weak self] a in
            guard let self, self.need("hud") else { return nil }
            self.addon.hudLines = (a.first?.toArray() as? [Any] ?? []).compactMap { $0 as? String }
            return nil
        }

        // мапа
        let map = ns(api, "map")
        def(map, "markers") { [weak self] a in
            guard let self, self.need("map") else { return nil }
            self.addon.markers = (a.first?.toArray() as? [[String: Any]] ?? []).enumerated().compactMap { i, d in
                guard let la = d["lat"] as? Double, let lo = d["lon"] as? Double else { return nil }
                return AddonMarker(id: "\(self.addon.id)#\(d["id"] ?? i)", lat: la, lon: lo, title: d["title"] as? String ?? "", symbol: d["symbol"] as? String ?? "mappin", color: d["color"] as? String ?? "#FF3B30")
            }
            return nil
        }
        def(map, "lines") { [weak self] a in
            guard let self, self.need("map") else { return nil }
            self.addon.lines = (a.first?.toArray() as? [[String: Any]] ?? []).enumerated().compactMap { i, d in
                guard let pts = d["points"] as? [[Double]], pts.count >= 2 else { return nil }
                return AddonLine(id: "\(self.addon.id)#\(d["id"] ?? i)", points: pts, color: d["color"] as? String ?? "#30B0C7", dashed: d["dashed"] as? Bool ?? false)
            }
            return nil
        }
        let menu = ns(api, "menu")
        def(menu, "add") { [weak self] a in
            guard let self, self.need("map"), let o = a.first, let t = o.forProperty("title")?.toString(), let h = o.forProperty("onClick") else { return nil }
            self.addon.menu.append(AddonMenuItem(addon: self.addon.id, title: t, handler: h)); return nil
        }
    }

    func fireMenu(_ item: AddonMenuItem, _ c: CLLocationCoordinate2D) {
        item.handler.call(withArguments: [["lat": c.latitude, "lon": c.longitude]])
    }

    private func addTimer(_ a: [JSValue], repeats: Bool) -> Any? {
        guard let f = a.first else { return nil }
        let ms = max(a.count > 1 ? a[1].toDouble() : 0, 1)
        let id = nextTimer; nextTimer += 1
        timers[id] = Timer.scheduledTimer(withTimeInterval: ms / 1000, repeats: repeats) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.running else { return }
                f.call(withArguments: [])
                if !repeats { self.timers[id] = nil }
            }
        }
        return id
    }

    private func loadStorage() {
        guard !storageLoaded else { return }
        storageLoaded = true
        if let d = try? Data(contentsOf: storageURL), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { storage = o }
    }

    private func openNet(_ host: String, port: Int, udp: Bool) -> Any? {
        guard let n = AddonNet(host: host, port: port, udp: udp) else {
            fail(String(localized: "Мережа: дозволені лише адреси локальної мережі (10.x, 172.16–31.x, 192.168.x, 169.254.x) і порт 1–65535")); return nil
        }
        let id = nextPort; nextPort += 1
        nets[id] = n
        let o = JSValue(newObjectIn: ctx)!
        o.setValue(host, forProperty: "host"); o.setValue(port, forProperty: "port")
        var openCB: JSValue?, dataCB: JSValue?, closeCB: JSValue?
        def(o, "write") { [weak n] a in
            let bytes = (a.first?.toArray() as? [Any] ?? []).compactMap { ($0 as? NSNumber).map { UInt8(truncatingIfNeeded: $0.intValue) } }
            return n?.write(bytes) ?? false
        }
        def(o, "isOpen") { [weak n] _ in n?.isOpen ?? false }
        def(o, "onOpen") { a in openCB = a.first; return nil }
        def(o, "onData") { a in dataCB = a.first; return nil }
        def(o, "onClose") { a in closeCB = a.first; return nil }
        def(o, "close") { [weak self, weak n] _ in n?.close(); self?.nets[id] = nil; return nil }
        n.onOpen = { openCB?.call(withArguments: []) }
        n.onData = { d in dataCB?.call(withArguments: [d.map { Int($0) }]) }
        n.onClose = { [weak self] in closeCB?.call(withArguments: []); self?.nets[id] = nil }
        return o
    }

    private func openPort(_ path: String, baud: Int) -> Any? {
        guard let p = AddonSerial(path: path, baud: baud) else { fail(String(localized: "Не вдалося відкрити \(path)")); return nil }
        let id = nextPort; nextPort += 1
        ports[id] = p
        let o = JSValue(newObjectIn: ctx)!
        o.setValue(path, forProperty: "path")
        var dataCB: JSValue?, closeCB: JSValue?
        def(o, "write") { [weak p] a in
            let bytes = (a.first?.toArray() as? [Any] ?? []).compactMap { ($0 as? NSNumber).map { UInt8(truncatingIfNeeded: $0.intValue) } }
            return p?.write(bytes) ?? false
        }
        def(o, "isOpen") { [weak p] _ in p?.isOpen ?? false }
        def(o, "onData") { a in dataCB = a.first; return nil }
        def(o, "onClose") { a in closeCB = a.first; return nil }
        def(o, "close") { [weak self, weak p] _ in p?.close(); self?.ports[id] = nil; return nil }
        p.onData = { d in dataCB?.call(withArguments: [d.map { Int($0) }]) }
        p.onClose = { [weak self] in closeCB?.call(withArguments: []); self?.ports[id] = nil }
        return o
    }
}
