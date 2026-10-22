import SwiftUI

struct PortInfo: Decodable, Identifiable, Hashable { let path: String; let usb: Bool; var id: String { path } }

enum ConnKind { case auto, serial, tcp, udp, udpcl, ws }

/// Підключення польотника: AUTO, послідовні порти (USB/Bluetooth), TCP, UDP, UDPCI, WS: як у Mission Planner.
struct ConnectionControl: View {
    @Environment(Store.self) var s
    @AppStorage("conn.type") private var type = "AUTO"
    @AppStorage("conn.baud") private var baud = 115200
    @AppStorage("conn.host") private var host = "127.0.0.1"
    @AppStorage("conn.port") private var portText = "5760"
    @AppStorage("conn.recent") private var recentRaw = ""
    @AppStorage("conn.autostart") private var autostart = false
    @State private var ports: [PortInfo] = []
    @State private var open = false
    @State private var didAutostart = false

    static let bauds = [9600, 19200, 38400, 57600, 111100, 115200, 230400, 460800, 921600, 1500000]

    var kind: ConnKind {
        switch type {
        case "AUTO": return .auto
        case "TCP": return .tcp
        case "UDP": return .udp
        case "UDPCI": return .udpcl
        case "WS": return .ws
        default: return .serial
        }
    }
    var state: String { s.t.linkState ?? "searching" }
    /// Є з'єднання (або іде відкриття порту). «searching» = плати немає, двигун лише чекає її: це не з'єднання.
    var linked: Bool { state == "open" || state == "connecting" }

    var summary: String {
        switch kind {
        case .auto: return s.t.port.map { "AUTO · " + short($0) } ?? "AUTO"
        case .serial: return short(type)
        case .tcp: return "TCP \(host):\(portText)"
        case .udp: return "UDP :\(portText)"
        case .udpcl: return "UDPCI \(host):\(portText)"
        case .ws: return "WS \(host.isEmpty ? "" : host):\(portText)"
        }
    }
    func short(_ p: String) -> String { p.replacingOccurrences(of: "/dev/cu.", with: "") }

    var body: some View {
        HStack(spacing: 6) {
            Button { open.toggle() } label: {
                HStack(spacing: 5) {
                    Image(systemName: "cable.connector")
                    Text(LocalizedStringKey(summary)).font(.callout).lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 9))
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Color.gray.opacity(0.18), in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .popover(isPresented: $open, arrowEdge: .bottom) { settings }
            Button { linked ? disconnect() : connect() } label: {
                HStack(spacing: 4) {
                    Image(systemName: linked ? "bolt.slash.fill" : "bolt.fill")
                    Text(lk(linked ? "Disconnect" : "Connect")).font(.callout.weight(.semibold))
                }
                .padding(.horizontal, 12).padding(.vertical, 5)
                .foregroundStyle(linked ? Color.primary : Color.white)
                .background(linked ? Color.gray.opacity(0.25) : Color.accentColor, in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
        }
        .task { await pollPorts() }
        .onChange(of: s.engineUp) { _, up in if up { autoApply() } }
        .onAppear { if s.engineUp { autoApply() } }
    }

    // MARK: Налаштування
    var settings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Підключення").font(.headline)
            Picker("Тип", selection: $type) {
                Text("AUTO").tag("AUTO")
                if !ports.isEmpty { Divider() }
                ForEach(ports) { Text(lk(short($0.path) + ($0.usb ? "" : "  (Bluetooth/інше)"))).tag($0.path) }
                Divider()
                Text("TCP").tag("TCP")
                Text("UDP").tag("UDP")
                Text("UDPCI").tag("UDPCI")
                Text("WS").tag("WS")
            }
            .frame(width: 330)
            .onChange(of: type) { _, _ in setDefaultPort() }

            switch kind {
            case .auto, .serial:
                Picker("Швидкість", selection: $baud) { ForEach(Self.bauds, id: \.self) { Text(lk(String($0))).tag($0) } }.frame(width: 250)
                Text(lk(kind == .auto ? "AUTO: перший USB-порт польотника. Для USB швидкість не має значення." : "Послідовний порт: USB-кабель або Bluetooth-телеметрія.")).font(.caption).foregroundStyle(.secondary)
            case .udp:
                field("Порт, що слухається", $portText, 90)
                Text("Двигун слухає вхідні UDP-пакети MAVLink (за замовчуванням 14550), наприклад від MAVProxy або SITL.").font(.caption).foregroundStyle(.secondary)
            case .udpcl:
                field("Адреса (IP)", $host, 200); field("Порт", $portText, 90)
                Text("UDP-клієнт: двигун сам шле пакети на вказану адресу та порт.").font(.caption).foregroundStyle(.secondary)
            case .tcp:
                field("Адреса (IP)", $host, 200); field("Порт", $portText, 90)
                Text("TCP-клієнт: підключення до MAVLink-сервера (SITL зазвичай 127.0.0.1:5760).").font(.caption).foregroundStyle(.secondary)
            case .ws:
                field("Адреса або ws://URL", $host, 260); field("Порт", $portText, 90)
                Text("MAVLink через WebSocket (бінарні повідомлення).").font(.caption).foregroundStyle(.secondary)
            }
            if let e = s.t.linkError, !e.isEmpty, state != "open" { Label(LocalizedStringKey(e), systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange).frame(width: 330, alignment: .leading) }

            let recents = recentList
            if !recents.isEmpty {
                Divider()
                Menu("Недавні підключення") {
                    ForEach(recents, id: \.self) { r in Button(lk(r.replacingOccurrences(of: "|", with: "  "))) { apply(recent: r) } }
                    Divider()
                    Button("Очистити список") { recentRaw = "" }
                }
            }
            HStack {
                Spacer()
                Button(lk(linked ? "Перепідключити" : "Connect")) { connect(); open = false }.buttonStyle(.borderedProminent)
            }
        }
        .padding(16).frame(width: 370)
    }

    func field(_ title: String, _ binding: Binding<String>, _ width: CGFloat) -> some View {
        HStack { Text(LocalizedStringKey(title)).frame(width: 130, alignment: .leading); TextField("", text: binding).textFieldStyle(.roundedBorder).frame(width: width) }
    }

    func setDefaultPort() {
        let defaults = ["5760", "14550", ""]
        guard defaults.contains(portText) else { return }
        switch kind { case .tcp, .ws: portText = "5760"; case .udp, .udpcl: portText = "14550"; default: break }
    }

    // MARK: Дії
    var query: String? {
        func enc(_ v: String) -> String { v.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? v }
        let port = Int(portText) ?? 0
        switch kind {
        case .auto: return "type=auto&baud=\(baud)"
        case .serial: return "type=serial&path=\(enc(type))&baud=\(baud)"
        case .tcp: return host.isEmpty || port == 0 ? nil : "type=tcp&host=\(enc(host))&port=\(port)"
        case .udp: return port == 0 ? nil : "type=udp&port=\(port)"
        case .udpcl: return host.isEmpty || port == 0 ? nil : "type=udpcl&host=\(enc(host))&port=\(port)"
        case .ws: return host.isEmpty ? nil : "type=ws&host=\(enc(host))&port=\(port)"
        }
    }

    func connect() {
        guard let q = query else { return }
        autostart = kind != .auto
        EngineAPI.post("/connect?\(q)")
        remember()
    }
    func disconnect() { autostart = false; EngineAPI.post("/disconnect") }

    func autoApply() {
        guard !didAutostart else { return }
        didAutostart = true
        if autostart, kind != .auto, let q = query { EngineAPI.post("/connect?\(q)") }
    }

    var recentList: [String] { recentRaw.split(separator: "\n").map(String.init) }
    func remember() {
        guard kind != .auto else { return }
        let entry: String
        switch kind {
        case .serial: entry = "SERIAL|\(type)|\(baud)"
        case .udp: entry = "UDP||\(portText)"
        default: entry = "\(type)|\(host)|\(portText)"
        }
        var list = recentList.filter { $0 != entry }; list.insert(entry, at: 0)
        recentRaw = list.prefix(8).joined(separator: "\n")
    }
    func apply(recent r: String) {
        let p = r.components(separatedBy: "|")
        guard p.count == 3 else { return }
        if p[0] == "SERIAL" { type = p[1]; baud = Int(p[2]) ?? 115200 }
        else { type = p[0]; host = p[1]; portText = p[2] }
    }

    func pollPorts() async {
        while !Task.isCancelled {
            if let p = await EngineAPI.get("/ports", as: [PortInfo].self) { ports = p }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }
}
