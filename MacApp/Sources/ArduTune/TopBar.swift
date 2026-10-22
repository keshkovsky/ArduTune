import SwiftUI

/// Верхня панель: кнопка ARM/DISARM, обрані режими польоту та короткий стан.
struct TopBar: View {
    @Environment(Store.self) var s
    /// true лише у Flight Data й Mission: ARM/DISARM і режими польоту. В інших розділах: назва програми й підключення.
    var full = true
    @AppStorage("favModes") private var legacyFav = ""            // старий спільний список (Copter)
    @State private var favTick = 0

    var allModes: [(Int, String)] { s.ps.options("FLTMODE1") }
    /// Обрані режими зберігаються окремо для кожного типу апарата.
    var familyKey: String {
        let v = s.ps.metaVehicle ?? ""
        if v == "FIXED_WING" || v == "FLAPPING_WING" || v.hasPrefix("VTOL") { return "plane" }
        if v == "GROUND_ROVER" || v == "SURFACE_BOAT" { return "rover" }
        if v == "SUBMARINE" { return "sub" }
        return "copter"
    }
    var favDefaultsKey: String { "favModes." + familyKey }
    var favRaw: String {
        get { _ = favTick; return UserDefaults.standard.string(forKey: favDefaultsKey) ?? (familyKey == "copter" ? legacyFav : "") }
        nonmutating set { UserDefaults.standard.set(newValue, forKey: favDefaultsKey); favTick += 1 }
    }
    /// Режими, призначені на слоти перемикача пульта (FLTMODE1…6): режим → номери слотів.
    var mapped: [(mode: Int, slots: [Int])] {
        var res: [(Int, [Int])] = []
        for i in 1...6 {
            guard let v = s.ps.val("FLTMODE\(i)").map(Int.init) else { continue }
            if let k = res.firstIndex(where: { $0.0 == v }) { res[k].1.append(i) } else { res.append((v, [i])) }
        }
        return res.map { (mode: $0.0, slots: $0.1) }
    }
    var favs: [Int] {
        let valid: (Int) -> Bool = { m in allModes.isEmpty || allModes.contains { $0.0 == m } }
        if favRaw == "none" { return [] }
        let saved = favRaw.split(separator: ",").compactMap { Int($0) }.filter(valid)
        if !saved.isEmpty { return saved }
        return mapped.map(\.mode).filter(valid)
    }
    func name(_ m: Int) -> String { allModes.first { $0.0 == m }?.1 ?? "Mode \(m)" }

    var body: some View {
        if full { fullBar } else { compactBar }
    }

    var compactBar: some View {
        HStack(spacing: 10) {
            Spacer()
            if s.joy.enabled { Label("Джойстик", systemImage: "gamecontroller.fill").font(.caption).foregroundStyle(.green) }
            Text(LocalizedStringKey(statusText)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Divider().frame(height: 22)
            ConnectionControl()
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) { Divider() }
    }

    var fullBar: some View {
        HStack(spacing: 10) {
            armButton
            Divider().frame(height: 22)
            ForEach(favs, id: \.self) { m in
                let on = s.t.customMode == m && s.connected
                Button { EngineAPI.post("/cmd/mode?m=\(m)") } label: {
                    Text(lk(name(m))).font(.system(size: 12.5, weight: on ? .semibold : .medium)).padding(.horizontal, 12).padding(.vertical, 6)
                }.buttonStyle(PillButtonStyle(tint: .accentColor, prominent: on, solid: true)).disabled(!s.connected)
            }
            Menu {
                let mappedModes = mapped.filter { m in allModes.contains { $0.0 == m.mode } }
                let others = allModes.filter { a in !mappedModes.contains { $0.mode == a.0 } }
                Section("На перемикачі пульта") {
                    ForEach(mappedModes, id: \.mode) { m in
                        Toggle(isOn: favBinding(m.mode)) { Text("\(name(m.mode))  ·  слот \(m.slots.map(String.init).joined(separator: ", "))") }
                    }
                }
                Section("Інші режими") {
                    ForEach(others, id: \.0) { m in Toggle(isOn: favBinding(m.0)) { Text(LocalizedStringKey(m.1)) } }
                }
                Divider()
                Button("Скинути до режимів перемикача") { favRaw = "" }
            } label: { Image(systemName: "star.circle") }
            .menuStyle(.borderlessButton).frame(width: 30).disabled(allModes.isEmpty)
            Spacer()
            if s.joy.enabled { Label("Джойстик", systemImage: "gamecontroller.fill").font(.caption).foregroundStyle(.green) }
            Text(LocalizedStringKey(statusText)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Divider().frame(height: 22)
            ConnectionControl()
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) { Divider() }
    }

    var statusText: String {
        guard s.connected else { return "немає зв'язку" }
        return String(format: "Sats %d · %@  ·  %.1f V", s.t.sats, s.t.gpsFix >= 3 ? "3D" : "no fix", s.t.batteryV)
    }

    var armButton: some View {
        Button { EngineAPI.post(s.armed ? "/cmd/disarm" : "/cmd/arm") } label: {
            HStack(spacing: 8) {
                ZStack {
                    Circle().fill(Color.white.opacity(0.28)).frame(width: 18, height: 18)
                    Image(systemName: "power").font(.system(size: 9.5, weight: .bold)).foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(lk(s.armed ? "Armed" : "Disarmed")).font(.system(size: 12.5, weight: .semibold))
                    Text(lk(s.armed ? "Натисніть для DISARM" : "Натисніть для ARM")).font(.system(size: 9.5)).opacity(0.85)
                }
            }
            .foregroundStyle(.white)
            .padding(.leading, 8).padding(.trailing, 14).padding(.vertical, 4)
        }
        .buttonStyle(ArmButtonStyle(armed: s.armed))
        .disabled(!s.connected)
        .help(lk(s.armed ? "Вимкнути мотори (DISARM)" : "Увімкнути мотори (ARM)"))
    }

    func favBinding(_ m: Int) -> Binding<Bool> {
        Binding(get: { favs.contains(m) }, set: { on in
            var cur = favs
            if on { if !cur.contains(m) { cur.append(m) } } else { cur.removeAll { $0 == m } }
            favRaw = cur.isEmpty ? "none" : cur.map(String.init).joined(separator: ",")
        })
    }
}


/// Кнопка-капсула у стилі macOS: м'який фон, тонка рамка, легке стиснення при натисканні.
struct PillButtonStyle: ButtonStyle {
    var tint: Color = .accentColor
    var prominent = false
    var solid = false              // суцільна заливка кольором (для вибраного режиму)
    @Environment(\.isEnabled) private var enabled
    @State private var hover = false

    func makeBody(configuration: Configuration) -> some View {
        let fill: Color = (prominent && solid) ? tint : (prominent ? tint.opacity(0.18) : Color.primary.opacity(hover ? 0.12 : 0.07))
        configuration.label
            .foregroundStyle((prominent && solid) ? Color.white : Color.primary)
            .background(fill, in: Capsule())
            .overlay(Capsule().strokeBorder(prominent ? tint.opacity(solid ? 0 : 0.55) : Color.primary.opacity(0.12), lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(enabled ? 1 : 0.45)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .onHover { hover = $0 }
            .contentShape(Capsule())
    }
}


/// Кнопка ARM/DISARM: суцільна капсула, зелена в стані Armed і червона в стані Disarmed.
struct ArmButtonStyle: ButtonStyle {
    let armed: Bool
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        let base: Color = armed ? Color(red: 0.20, green: 0.70, blue: 0.33) : Color(red: 0.90, green: 0.25, blue: 0.22)
        configuration.label
            .background(LinearGradient(colors: [base.opacity(0.92), base], startPoint: .top, endPoint: .bottom), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.22), lineWidth: 0.5))
            .shadow(color: base.opacity(0.35), radius: 3, y: 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .brightness(configuration.isPressed ? -0.06 : 0)
            .opacity(enabled ? 1 : 0.4)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

/// Назва програми в стилі логотипа: «Ardu» світлим, «Tune» блакитним градієнтом.
struct AppWordmark: View {
    var size: CGFloat = 24
    var body: some View {
        HStack(spacing: 0) {
            Text("Ardu").foregroundStyle(.primary)
            Text("Tune").foregroundStyle(LinearGradient(colors: [Color(red: 0.16, green: 0.82, blue: 1.0), Color(red: 0.04, green: 0.50, blue: 1.0)], startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        .font(.system(size: size, weight: .bold))
        .tracking(-0.4)
        .fixedSize()
    }
}
