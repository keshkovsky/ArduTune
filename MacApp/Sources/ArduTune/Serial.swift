import SwiftUI
import Observation

struct UartInfo { var name: String; var tx: String?; var rx: String? }

/// Відповідність SERIALn → фізичний UART плати з hwdef ArduPilot (SERIAL_ORDER + піни).
@Observable
final class SerialStore {
    var map: [Int: UartInfo] = [:]
    var status = String(localized: "Визначаю плату…")
    var board: String?
    private var started = false

    func load(board: String, version: String) {
        guard !started else { return }
        started = true
        self.board = board
        Task { @MainActor in
            let base = "https://raw.githubusercontent.com/ArduPilot/ardupilot/Copter-\(version)/libraries/AP_HAL_ChibiOS/hwdef"
            var names = [board]
            if let i = board.firstIndex(of: "-") { names.append(String(board[..<i])) }
            for n in names {
                if let text = await fetchHwdef("\(base)/\(n)/hwdef.dat", base: "\(base)/\(n)", root: base) {
                    parse(text); status = map.isEmpty ? "Таблицю SERIAL_ORDER не знайдено" : "hwdef: \(n)"
                    return
                }
            }
            status = String(localized: "hwdef для плати не знайдено (офлайн?)")
        }
    }

    /// Завантажує hwdef.dat і підставляє `include` (відносні шляхи).
    private func fetchHwdef(_ url: String, base: String, root: String, depth: Int = 0) async -> String? {
        guard depth < 4, let u = URL(string: url),
              let (d, r) = try? await URLSession.shared.data(from: u),
              (r as? HTTPURLResponse)?.statusCode == 200,
              let text = String(data: d, encoding: .utf8) else { return nil }
        var out = ""
        for line in text.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("include ") {
                let rel = t.dropFirst(8).trimmingCharacters(in: .whitespaces)
                var parts = base.split(separator: "/").map(String.init)
                for seg in rel.split(separator: "/") {
                    if seg == ".." { _ = parts.popLast() } else if seg != "." { parts.append(String(seg)) }
                }
                let inc = parts.joined(separator: "/").replacingOccurrences(of: "https:/", with: "https://")
                let incBase = inc.split(separator: "/").dropLast().joined(separator: "/").replacingOccurrences(of: "https:/", with: "https://")
                if let sub = await fetchHwdef(inc, base: incBase, root: root, depth: depth + 1) { out += sub + "\n" }
            } else { out += line + "\n" }
        }
        return out
    }

    private func parse(_ text: String) {
        var order: [String] = []
        var pins: [String: (tx: String?, rx: String?)] = [:]
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? raw
            let w = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            if w.first == "SERIAL_ORDER" { order = Array(w.dropFirst()) }
            // Напр.: "PA9 USART1_TX USART1" або "PB6 USART1_TX USART1 NODMA"
            if w.count >= 2, w[0].hasPrefix("P"), let r = w[1].range(of: #"^(U?S?ART\d+)_(TX|RX)$"#, options: .regularExpression) {
                let tok = String(w[1][r]); let parts = tok.split(separator: "_").map(String.init)
                var e = pins[parts[0]] ?? (nil, nil)
                if parts[1] == "TX" { e.tx = w[0] } else { e.rx = w[0] }
                pins[parts[0]] = e
            }
        }
        map = [:]
        for (i, n) in order.enumerated() {
            let p = pins[n]
            map[i] = UartInfo(name: n, tx: p?.tx, rx: p?.rx)
        }
    }
}

struct SerialView: View {
    @Environment(Store.self) var s
    @State private var ss = SerialStore()
    @State private var optionsFor: Int?
    @State private var cs = CalStore()
    var ps: ParamStore { s.ps }

    var ports: [Int] { (0...9).filter { ps.has("SERIAL\($0)_PROTOCOL") } }

    var boardAndVersion: (String, String)? {
        let m = cs.cal?.msgs ?? []
        guard let fw = m.first(where: { $0.hasPrefix("Ardu") }),
              let v = fw.split(separator: " ").first(where: { $0.hasPrefix("V") })?.dropFirst(),
              let ci = m.firstIndex(where: { $0.hasPrefix("ChibiOS") }), ci + 1 < m.count,
              let b = m[ci + 1].split(separator: " ").first else { return nil }
        return (String(b), String(v))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                OfflineBanner()
                if !s.canView {
                    ContentUnavailableView("Польотник не підключений", systemImage: "cable.connector", description: Text("Підключіть плату по USB"))
                } else if ps.params.isEmpty {
                    ProgressView("Завантаження параметрів…")
                } else {
                    if s.armedLive { Label("Апарат ARMED: редагування заблоковано", systemImage: "lock.fill").foregroundStyle(.red) }
                    Card(title: "Serial Ports", icon: "cable.connector.horizontal", text: String(localized: "Протокол і швидкість кожного послідовного порту. Колонка UART показує, якому фізичному порту плати відповідає SERIALn. Зміни набирають чинності після перезавантаження автопілота.")) {
                        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                            GridRow { ForEach(["Порт", "UART", "TX / RX", "Протокол", "Швидкість", "Опції"], id: \.self) { Text(lk($0)).font(.caption.weight(.semibold)).foregroundStyle(.secondary) } }
                            Divider().gridCellColumns(6)
                            ForEach(ports, id: \.self) { n in
                                let u = ss.map[n]
                                GridRow {
                                    Text("SERIAL\(n)").font(.system(.body, design: .monospaced).weight(.semibold))
                                    HStack(spacing: 4) {
                                        if n == 0 { Image(systemName: "cable.connector").font(.caption) }
                                        Text(lk(uartLabel(n, u))).fontWeight(.medium)
                                    }
                                    Text(lk(pins(u))).font(.caption.monospaced()).foregroundStyle(.secondary)
                                    OptionPicker(name: "SERIAL\(n)_PROTOCOL", width: 200)
                                    if ps.has("SERIAL\(n)_BAUD") { OptionPicker(name: "SERIAL\(n)_BAUD", width: 120) } else { Text("—") }
                                    if ps.has("SERIAL\(n)_OPTIONS") {
                                        Button("Опції…") { optionsFor = n }
                                            .popover(isPresented: Binding(get: { optionsFor == n }, set: { if !$0 { optionsFor = nil } })) { optionsPopover(n) }
                                    } else { Text("—") }
                                }
                            }
                        }
                        HStack(spacing: 8) {
                            Text(LocalizedStringKey(ss.status)).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button { EngineAPI.post("/reboot") } label: { Label("Перезавантажити автопілот", systemImage: "restart") }.disabled(s.armed)
                        }
                    }
                }
            }
            .padding()
        }
        .onAppear { cs.start() }
        .onDisappear { cs.stop() }
        .onChange(of: boardAndVersion?.0) { _, _ in tryLoad() }
        .onChange(of: cs.cal?.msgs.count) { _, _ in tryLoad() }
    }

    func tryLoad() { if let (b, v) = boardAndVersion { ss.load(board: b, version: v) } }

    func uartLabel(_ n: Int, _ u: UartInfo?) -> String {
        guard let u else { return n == 0 ? "USB" : "—" }
        if u.name.hasPrefix("OTG") { return "USB (\(loc(u.name)))" }
        if u.name == "EMPTY" { return "не підключено" }
        return u.name
    }
    func pins(_ u: UartInfo?) -> String {
        guard let u, u.tx != nil || u.rx != nil else { return "—" }
        return "\(u.tx ?? "?") / \(u.rx ?? "?")"
    }

    func optionsPopover(_ n: Int) -> some View {
        let name = "SERIAL\(n)_OPTIONS"
        let bits = ps.meta[name]?.bits ?? []
        let cur = Int(ps.val(name) ?? 0)
        return VStack(alignment: .leading, spacing: 8) {
            Text("Опції SERIAL\(n)").font(.headline)
            if bits.isEmpty { Text("Немає опису опцій").foregroundStyle(.secondary) }
            ForEach(bits, id: \.self) { kv in
                let bit = Int(kv[0]) ?? 0
                Toggle(lk(kv.count > 1 ? kv[1] : String(localized: "біт \(bit)")), isOn: Binding(get: { (cur >> bit) & 1 == 1 }, set: { _ in ps.write(name, Double(cur ^ (1 << bit))) }))
                    .toggleStyle(.checkbox).disabled(s.armed)
            }
        }
        .padding(16).frame(minWidth: 320)
    }
}
