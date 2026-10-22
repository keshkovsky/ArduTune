import SwiftUI
import Observation

extension ParamStore {
    func val(_ n: String) -> Double? { find(n)?.value }
    func write(_ n: String, _ v: Double) { if let p = find(n) { set(p, to: v) } }
    func has(_ n: String) -> Bool { find(n) != nil }
    /// Варіанти значень із метаданих: (код, назва).
    func options(_ n: String) -> [(Int, String)] {
        let o = (meta[n]?.values ?? []).compactMap { kv in Int(kv[0]).map { ($0, kv.count > 1 ? kv[1] : kv[0]) } }
        // Режими польоту мають працювати й до завантаження метаданих
        if o.isEmpty, n.hasPrefix("FLTMODE"), n != "FLTMODE_CH" { return fallbackModes }
        return o
    }

    static let planeModes: [(Int, String)] = [(0, "Manual"), (1, "Circle"), (2, "Stabilize"), (3, "Training"), (4, "Acro"), (5, "FlyByWireA"), (6, "FlyByWireB"), (7, "Cruise"), (8, "Autotune"),
        (10, "Auto"), (11, "RTL"), (12, "Loiter"), (13, "Takeoff"), (14, "AvoidADSB"), (15, "Guided"), (17, "QStabilize"), (18, "QHover"), (19, "QLoiter"), (20, "QLand"), (21, "QRTL"), (22, "QAutotune"), (23, "QAcro"), (24, "Thermal"), (26, "AutoLand")]
    /// Режими до завантаження метаданих: за типом апарата.
    var fallbackModes: [(Int, String)] {
        let v = metaVehicle ?? ""
        if v == "FIXED_WING" || v == "FLAPPING_WING" || v.hasPrefix("VTOL") { return Self.planeModes }
        return Self.copterModes
    }

    static let copterModes: [(Int, String)] = [
        (0, "Stabilize"), (1, "Acro"), (2, "AltHold"), (3, "Auto"), (4, "Guided"), (5, "Loiter"), (6, "RTL"), (7, "Circle"),
        (9, "Land"), (11, "Drift"), (13, "Sport"), (14, "Flip"), (15, "AutoTune"), (16, "PosHold"), (17, "Brake"), (18, "Throw"),
        (19, "Avoid_ADSB"), (20, "Guided_NoGPS"), (21, "Smart_RTL"), (22, "FlowHold"), (23, "Follow"), (24, "ZigZag"),
        (25, "SystemID"), (26, "Heli_Autorotate"), (27, "Auto RTL"),
    ]
}

/// Вибір значення параметра. Короткі списки — меню, довгі (функції серво тощо) — легкий popover з пошуком.
struct OptionPicker: View {
    @Environment(Store.self) var s
    let name: String
    var width: CGFloat? = nil
    var disabled = false
    @State private var open = false
    @State private var query = ""

    var body: some View {
        let ps = s.ps
        let opts = ps.options(name)
        let cur = Int(ps.val(name) ?? 0)
        let curName = opts.first { $0.0 == cur }?.1 ?? String(localized: "\(cur) (невідомо)")
        let off = disabled || s.armed || !ps.has(name)
        if opts.count > 14 {
            Button { open = true } label: {
                HStack(spacing: 4) {
                    Text(LocalizedStringKey(curName)).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 2)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 9)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .frame(width: width, alignment: .leading)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain).disabled(off)
            .popover(isPresented: $open, arrowEdge: .bottom) { list(opts, cur: cur) }
        } else {
            Picker("", selection: Binding(get: { cur }, set: { ps.write(name, Double($0)) })) {
                if !opts.contains(where: { $0.0 == cur }) { Text(LocalizedStringKey(curName)).tag(cur) }
                ForEach(opts, id: \.0) { Text(lk($0.1)).tag($0.0) }
            }
            .labelsHidden().frame(width: width).disabled(off)
        }
    }

    func list(_ opts: [(Int, String)], cur: Int) -> some View {
        let q = query.lowercased()
        let shown = q.isEmpty ? opts : opts.filter { $0.1.lowercased().contains(q) || String($0.0).contains(q) }
        return VStack(spacing: 6) {
            TextField("Пошук", text: $query).textFieldStyle(.roundedBorder)
            List(shown, id: \.0) { o in
                Button {
                    s.ps.write(name, Double(o.0)); open = false; query = ""
                } label: {
                    HStack {
                        Image(systemName: "checkmark").opacity(o.0 == cur ? 1 : 0).foregroundStyle(Color.accentColor)
                        Text(LocalizedStringKey(o.1))
                        Spacer()
                        Text("\(o.0)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
        .padding(10).frame(width: 300, height: 360)
    }
}

/// Числове поле параметра: запис по Enter, валідація за діапазоном з метаданих.
struct ParamField: View {
    @Environment(Store.self) var s
    let name: String
    var width: CGFloat = 70
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        let ps = s.ps
        let cur = ps.val(name)
        TextField("", text: $text)
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .font(.system(.body, design: .monospaced))
            .frame(width: width)
            .focused($focused)
            .disabled(s.armed || cur == nil)
            .foregroundStyle(invalid ? .red : .primary)
            .onSubmit { commit() }
            .onAppear { sync() }
            .onChange(of: cur) { _, _ in if !focused { sync() } }
    }

    var parsed: Double? { Double(text.replacingOccurrences(of: ",", with: ".")) }
    var invalid: Bool {
        guard let v = parsed else { return true }
        if let m = s.ps.meta[name], let lo = m.min, let hi = m.max { return v < lo || v > hi }
        return false
    }
    func sync() { if let c = s.ps.val(name) { text = fmt(c, isInt: s.ps.find(name)?.isInt ?? false) } }
    func commit() {
        guard let v = parsed, !invalid else { sync(); return }
        if v != s.ps.val(name) { s.ps.write(name, v) }
    }
}

struct IODTO: Decodable { let servo: [Int]; let rc: [Int]; let testEnabled: Bool; let armed: Bool }

@Observable
final class IOStore {
    var io: IODTO?
    private var polling = false
    func start() {
        guard !polling else { return }
        polling = true
        Task { @MainActor in
            while polling {
                if let v = await EngineAPI.get("/io", as: IODTO.self) { io = v }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
    }
    func stop() { polling = false }
}
