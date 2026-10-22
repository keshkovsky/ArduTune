import SwiftUI
import IOKit.hid
import Observation
import AppKit

enum JoyAxis: String, CaseIterable, Codable, Identifiable {
    case x = "X", y = "Y", z = "Z", rx = "Rx", ry = "Ry", rz = "Rz", slider1 = "Slider1", slider2 = "Slider2"
    var id: String { rawValue }
}

struct JoyRow: Codable, Equatable { var axis: JoyAxis?; var expo: Double = 0; var reverse = false }
struct JoyConfig: Codable { var device: String; var rows: [JoyRow]; var manual: Bool; var elevons: Bool }

/// USB-джойстик через IOKit HID: автовизначення пристрою та осей, мапінг на канали RC1–16, надсилання RC override.
@Observable
final class JoystickStore {
    struct Device: Identifiable, Hashable { let id: Int; let name: String }

    var devices: [Device] = []
    var selectedID: Int?
    var axes: [JoyAxis: Double] = [:]               // нормалізовано 0…1
    var rows: [JoyRow] = Array(repeating: JoyRow(axis: nil), count: 16)
    var outputs: [Int] = Array(repeating: 0, count: 16)
    var enabled = false { didSet { enabled ? startSending() : stopSending() } }
    var manualControl = false
    var elevons = false
    var detectRow: Int?
    var status = String(localized: "Джойстик не підключений")
    var started = false

    @ObservationIgnored private var manager: IOHIDManager?
    @ObservationIgnored private var baseline: [JoyAxis: Double] = [:]
    @ObservationIgnored private var sender: Task<Void, Never>?
    @ObservationIgnored private var rollCh = 1
    @ObservationIgnored private var pitchCh = 2
    @ObservationIgnored private var thrCh = 3
    @ObservationIgnored private var yawCh = 4

    var selectedName: String { devices.first { $0.id == selectedID }?.name ?? "" }

    func setStickMap(roll: Int, pitch: Int, thr: Int, yaw: Int) { rollCh = roll; pitchCh = pitch; thrCh = thr; yawCh = yaw }

    // MARK: HID
    func start() {
        guard !started else { return }
        started = true
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = mgr
        let match: [[String: Int]] = [
            [kIOHIDDeviceUsagePageKey as String: 0x01, kIOHIDDeviceUsageKey as String: 0x04],   // Joystick
            [kIOHIDDeviceUsagePageKey as String: 0x01, kIOHIDDeviceUsageKey as String: 0x05],   // Game Pad
            [kIOHIDDeviceUsagePageKey as String: 0x01, kIOHIDDeviceUsageKey as String: 0x08],   // Multi-axis
        ]
        IOHIDManagerSetDeviceMatchingMultiple(mgr, match as CFArray)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(mgr, { c, _, _, dev in
            guard let c else { return }
            Unmanaged<JoystickStore>.fromOpaque(c).takeUnretainedValue().added(dev)
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(mgr, { c, _, _, dev in
            guard let c else { return }
            Unmanaged<JoystickStore>.fromOpaque(c).takeUnretainedValue().removed(dev)
        }, ctx)
        IOHIDManagerRegisterInputValueCallback(mgr, { c, _, _, value in
            guard let c else { return }
            Unmanaged<JoystickStore>.fromOpaque(c).takeUnretainedValue().input(value)
        }, ctx)
        IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        let r = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        if r != kIOReturnSuccess { status = String(localized: "Немає доступу до HID (код \(r)). Дозвольте Input Monitoring у Системних налаштуваннях.") }
    }

    private func id(of dev: IOHIDDevice) -> Int { Int(bitPattern: Unmanaged.passUnretained(dev).toOpaque()) }

    private func added(_ dev: IOHIDDevice) {
        let name = (IOHIDDeviceGetProperty(dev, kIOHIDProductKey as CFString) as? String) ?? "HID-пристрій"
        let d = Device(id: id(of: dev), name: name)
        if !devices.contains(d) { devices.append(d) }
        if selectedID == nil { select(d.id) }
        status = String(localized: "Підключено: \(loc(name))")
    }

    private func removed(_ dev: IOHIDDevice) {
        let i = id(of: dev)
        devices.removeAll { $0.id == i }
        if selectedID == i {
            selectedID = devices.first?.id
            axes = [:]
            if selectedID == nil { enabled = false; status = String(localized: "Джойстик від'єднано") }
        }
    }

    private func input(_ value: IOHIDValue) {
        let el = IOHIDValueGetElement(value)
        guard IOHIDElementGetUsagePage(el) == 0x01 else { return }
        let dev = IOHIDElementGetDevice(el)
        if id(of: dev) != selectedID { return }
        let axis: JoyAxis
        switch IOHIDElementGetUsage(el) {
        case 0x30: axis = .x
        case 0x31: axis = .y
        case 0x32: axis = .z
        case 0x33: axis = .rx
        case 0x34: axis = .ry
        case 0x35: axis = .rz
        case 0x36: axis = .slider1
        case 0x37, 0x38: axis = .slider2
        default: return
        }
        let lo = Double(IOHIDElementGetLogicalMin(el)), hi = Double(IOHIDElementGetLogicalMax(el))
        guard hi > lo else { return }
        let v = min(max((Double(IOHIDValueGetIntegerValue(value)) - lo) / (hi - lo), 0), 1)
        axes[axis] = v
        if let row = detectRow {
            if let b = baseline[axis] {
                if abs(v - b) > 0.3 { rows[row].axis = axis; detectRow = nil }
            } else { baseline[axis] = v }
        }
        recompute()
    }

    func select(_ id: Int?) {
        selectedID = id
        axes = [:]
        guard let id, let d = devices.first(where: { $0.id == id }) else { return }
        if !load(named: d.name) { autoMap() }
    }

    /// Автомапінг за замовчуванням, як у Mission Planner: X,Y,Z,Rx,Ry,Rz,Slider2,Slider1 → RC1…RC8.
    func autoMap() {
        let order: [JoyAxis] = [.x, .y, .z, .rx, .ry, .rz, .slider2, .slider1]
        rows = Array(repeating: JoyRow(axis: nil), count: 16)
        for (i, a) in order.enumerated() { rows[i].axis = a }
    }

    func startDetect(_ row: Int) { baseline = axes; detectRow = row }

    // MARK: Вихід
    func recompute() {
        var out = [Int](repeating: 0, count: 16)
        for i in 0..<16 {
            guard let a = rows[i].axis, var v = axes[a] else { out[i] = 0; continue }
            if rows[i].reverse { v = 1 - v }
            let x = (v - 0.5) * 2
            let e = rows[i].expo / 100
            let y = x * (1 - e) + x * x * x * e
            out[i] = Int((1500 + y * 500).rounded())
        }
        if elevons, out[0] > 0, out[1] > 0 {
            let ail = out[0] - 1500, ele = out[1] - 1500
            out[0] = 1500 + max(-500, min(500, ail + ele)); out[1] = 1500 + max(-500, min(500, ail - ele))
        }
        outputs = out
    }

    private func startSending() {
        sender?.cancel()
        sender = Task { @MainActor in
            while !Task.isCancelled && enabled {
                recompute()
                if manualControl {
                    func p(_ ch: Int) -> Int { let i = ch - 1; return i >= 0 && i < 16 && outputs[i] > 0 ? outputs[i] : 1500 }
                    let x = (p(pitchCh) - 1500) * 2, y = (p(rollCh) - 1500) * 2, z = max(0, p(thrCh) - 1000), r = (p(yawCh) - 1500) * 2
                    EngineAPI.post("/rc/manual?x=\(x)&y=\(y)&z=\(z)&r=\(r)")
                } else {
                    let q = (0..<16).map { "c\($0 + 1)=\(outputs[$0] > 0 ? outputs[$0] : 65535)" }.joined(separator: "&")
                    EngineAPI.post("/rc/override?\(q)")
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    private func stopSending() {
        sender?.cancel(); sender = nil
        EngineAPI.post("/rc/stop")
    }

    // MARK: Збереження / імпорт / експорт
    private func key(_ n: String) -> String { "joy.config." + n }

    func config() -> JoyConfig { JoyConfig(device: selectedName, rows: rows, manual: manualControl, elevons: elevons) }
    func apply(_ c: JoyConfig) { rows = c.rows.count == 16 ? c.rows : rows; manualControl = c.manual; elevons = c.elevons }

    func save() {
        guard !selectedName.isEmpty, let d = try? JSONEncoder().encode(config()) else { return }
        UserDefaults.standard.set(d, forKey: key(selectedName))
        status = String(localized: "Конфігурацію збережено для «\(selectedName)»")
    }

    @discardableResult func load(named n: String) -> Bool {
        guard let d = UserDefaults.standard.data(forKey: key(n)), let c = try? JSONDecoder().decode(JoyConfig.self, from: d) else { return false }
        apply(c); status = String(localized: "Завантажено конфігурацію для «\(n)»"); return true
    }

    func exportConfig() {
        let p = NSSavePanel(); p.nameFieldStringValue = "joystick.json"
        guard p.runModal() == .OK, let u = p.url else { return }
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(config()) { try? d.write(to: u) ; status = String(localized: "Експортовано") }
    }

    func importConfig() {
        let p = NSOpenPanel(); p.allowedContentTypes = [.json]
        guard p.runModal() == .OK, let u = p.url, let d = try? Data(contentsOf: u), let c = try? JSONDecoder().decode(JoyConfig.self, from: d) else { status = String(localized: "Не вдалося імпортувати"); return }
        apply(c); status = String(localized: "Імпортовано")
    }
}

/// Вікно налаштування джойстика, як у Mission Planner.
struct JoystickSheet: View {
    @Environment(Store.self) var s
    var j: JoystickStore { s.joy }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("Joystick").font(.headline)
                Picker("", selection: Binding(get: { j.selectedID ?? -1 }, set: { j.select($0 == -1 ? nil : $0) })) {
                    if j.devices.isEmpty { Text("— немає пристроїв —").tag(-1) }
                    ForEach(j.devices) { Text(lk($0.name)).tag($0.id) }
                }.labelsHidden().frame(width: 280)
                Toggle(isOn: Binding(get: { j.enabled }, set: { j.enabled = $0 })) { Text(lk(j.enabled ? "Вимкнути" : "Enable")) }
                    .toggleStyle(.button).tint(j.enabled ? .green : nil).disabled(j.selectedID == nil || !s.connected)
                Button("Save") { j.save() }.disabled(j.selectedID == nil)
                Button("Export") { j.exportConfig() }
                Button("Import") { j.importConfig() }
                Spacer()
            }
            Text(LocalizedStringKey(j.status)).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 20) {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 5) {
                    GridRow {
                        Text(""); Text("Controller Axis"); Text(""); Text("Output"); Text("Expo"); Text("Reverse")
                    }.font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(0..<16, id: \.self) { i in
                        GridRow {
                            Text("RC \(i + 1)").font(.system(.body, design: .monospaced).weight(.semibold))
                            Picker("", selection: Binding(get: { j.rows[i].axis?.rawValue ?? "None" }, set: { j.rows[i].axis = JoyAxis(rawValue: $0) })) {
                                Text("None").tag("None")
                                ForEach(JoyAxis.allCases) { Text(lk($0.rawValue)).tag($0.rawValue) }
                            }.labelsHidden().frame(width: 110)
                            Button(lk(j.detectRow == i ? "Рухайте вісь…" : "Auto Detect")) { j.startDetect(i) }
                                .controlSize(.small).tint(j.detectRow == i ? .orange : nil).frame(width: 110)
                            OutBar(value: j.outputs[i]).frame(width: 150, height: 18)
                            HStack(spacing: 6) {
                                Slider(value: Binding(get: { j.rows[i].expo }, set: { j.rows[i].expo = $0 }), in: 0...100).frame(width: 120)
                                Text("\(Int(j.rows[i].expo))").font(.caption.monospacedDigit()).frame(width: 26, alignment: .trailing)
                            }
                            Toggle("", isOn: Binding(get: { j.rows[i].reverse }, set: { j.rows[i].reverse = $0 })).toggleStyle(.checkbox).labelsHidden()
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Manual Control", isOn: Binding(get: { j.manualControl }, set: { j.manualControl = $0 })).toggleStyle(.checkbox)
                    Toggle("Elevons", isOn: Binding(get: { j.elevons }, set: { j.elevons = $0 })).toggleStyle(.checkbox)
                    Text("Manual Control надсилає MANUAL_CONTROL замість RC override (за відображенням RCMAP). Elevons змішує RC1/RC2.").font(.caption2).foregroundStyle(.secondary).frame(width: 190)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 900, minHeight: 640)
        .onAppear { j.start(); syncMap() }
        .onChange(of: j.manualControl) { _, _ in syncMap() }
        .onChange(of: j.rows) { _, _ in j.recompute() }
    }
}

extension JoystickSheet {
    func syncMap() {
        let ps = s.ps
        j.setStickMap(roll: Int(ps.val("RCMAP_ROLL") ?? 1), pitch: Int(ps.val("RCMAP_PITCH") ?? 2), thr: Int(ps.val("RCMAP_THROTTLE") ?? 3), yaw: Int(ps.val("RCMAP_YAW") ?? 4))
    }
}

struct OutBar: View {
    let value: Int
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4).fill(.quaternary.opacity(0.7))
            GeometryReader { g in
                RoundedRectangle(cornerRadius: 4).fill(Color.green.opacity(0.8))
                    .frame(width: value > 0 ? g.size.width * CGFloat(min(max(Double(value - 1000) / 1000, 0), 1)) : 0)
            }
            Text(lk(value > 0 ? String(value) : "")).font(.system(size: 11, design: .monospaced))
        }.clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
