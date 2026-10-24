import SwiftUI
import AppKit

/// Кольорова тема HUD: небо, земля, колір ліній і тексту, колір покажчиків.
struct HUDTheme: Equatable {
    var id: String
    var name: String
    var skyTop: Color, skyBottom: Color
    var groundTop: Color, groundBottom: Color
    var ink: Color            // лінії, шкали, текст
    var accent: Color         // покажчики й маркери
    var plate: Color          // підкладка під значення на стрічках

    static func rgb(_ r: Double, _ g: Double, _ b: Double) -> Color { Color(red: r, green: g, blue: b) }

    static let classic = HUDTheme(id: "classic", name: "Класична", skyTop: rgb(0.0, 0.38, 0.74), skyBottom: rgb(0.02, 0.53, 0.85), groundTop: rgb(0.86, 0.54, 0.09), groundBottom: rgb(0.62, 0.38, 0.05),
                                  ink: .white, accent: .orange, plate: Color.black.opacity(0.32))
    static let graphite = HUDTheme(id: "graphite", name: "Графіт", skyTop: rgb(0.15, 0.18, 0.22), skyBottom: rgb(0.25, 0.29, 0.34), groundTop: rgb(0.10, 0.11, 0.13), groundBottom: rgb(0.05, 0.06, 0.07),
                                   ink: Color.white.opacity(0.96), accent: rgb(0.25, 0.85, 0.95), plate: Color.white.opacity(0.10))
    static let arctic = HUDTheme(id: "arctic", name: "Арктика", skyTop: rgb(0.06, 0.18, 0.30), skyBottom: rgb(0.16, 0.37, 0.55), groundTop: rgb(0.13, 0.18, 0.23), groundBottom: rgb(0.07, 0.10, 0.13),
                                 ink: rgb(0.90, 0.98, 1.0), accent: rgb(0.45, 0.95, 1.0), plate: Color.white.opacity(0.10))
    static let tactical = HUDTheme(id: "tactical", name: "Тактична", skyTop: rgb(0.02, 0.08, 0.07), skyBottom: rgb(0.05, 0.16, 0.13), groundTop: rgb(0.03, 0.06, 0.04), groundBottom: rgb(0.01, 0.03, 0.02),
                                   ink: rgb(0.58, 1.0, 0.68), accent: rgb(0.96, 1.0, 0.40), plate: Color.black.opacity(0.35))
    static let night = HUDTheme(id: "night", name: "Ніч (червона)", skyTop: rgb(0.03, 0.03, 0.04), skyBottom: rgb(0.07, 0.04, 0.05), groundTop: rgb(0.11, 0.02, 0.02), groundBottom: rgb(0.05, 0.01, 0.01),
                                ink: rgb(1.0, 0.30, 0.26), accent: rgb(1.0, 0.62, 0.25), plate: Color.black.opacity(0.4))
    static let day = HUDTheme(id: "day", name: "Світла", skyTop: rgb(0.78, 0.87, 0.97), skyBottom: rgb(0.90, 0.95, 1.0), groundTop: rgb(0.80, 0.75, 0.65), groundBottom: rgb(0.70, 0.64, 0.53),
                              ink: rgb(0.08, 0.10, 0.14), accent: rgb(0.0, 0.45, 0.95), plate: Color.white.opacity(0.45))
    static let mono = HUDTheme(id: "mono", name: "Моно", skyTop: rgb(0.30, 0.30, 0.32), skyBottom: rgb(0.42, 0.42, 0.44), groundTop: rgb(0.17, 0.17, 0.18), groundBottom: rgb(0.09, 0.09, 0.10),
                               ink: .white, accent: rgb(1.0, 0.85, 0.20), plate: Color.black.opacity(0.28))

    static let all: [HUDTheme] = [.classic, .graphite, .arctic, .tactical, .night, .day, .mono]

    /// Тема з урахуванням власних кольорів користувача (hex; порожній рядок = колір теми).
    static func make(id: String, sky: String = "", ground: String = "", ink: String = "", accent: String = "") -> HUDTheme {
        var t = all.first { $0.id == id } ?? .classic
        if let c = Color(hex: sky) { t.skyTop = c.adjusted(-0.08); t.skyBottom = c.adjusted(0.06) }
        if let c = Color(hex: ground) { t.groundTop = c.adjusted(0.05); t.groundBottom = c.adjusted(-0.10) }
        if let c = Color(hex: ink) { t.ink = c }
        if let c = Color(hex: accent) { t.accent = c }
        return t
    }
}

extension Color {
    init?(hex: String) {
        var h = hex.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "")
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        h = ""
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
    var hex: String {
        let c = NSColor(self).usingColorSpace(.sRGB) ?? .white
        return String(format: "%02X%02X%02X", Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
    }
    /// Світліший (>0) або темніший (<0) відтінок для градієнтів.
    func adjusted(_ d: Double) -> Color {
        let c = NSColor(self).usingColorSpace(.sRGB) ?? .gray
        func f(_ x: CGFloat) -> Double { min(1, max(0, Double(x) + d)) }
        return Color(red: f(c.redComponent), green: f(c.greenComponent), blue: f(c.blueComponent))
    }
}

extension ParamStore {
    /// Чим користується навігація: GPS чи оптична одометрія (VISO), за параметрами автопілота.
    var navSource: NavSource {
        let gpsType = val("GPS1_TYPE") ?? val("GPS_TYPE") ?? 1
        let gpsUse = val("AHRS_GPS_USE") ?? 1
        let posSrc = val("EK3_SRC1_POSXY") ?? 3
        let viso = (val("VISO_TYPE") ?? 0) != 0
        if gpsType != 0 && gpsUse != 0 && posSrc != 6 { return .gps }
        if viso || posSrc == 6 { return .viso }
        return gpsType != 0 ? .gps : .none
    }
}

/// Вікно налаштування теми HUD: вибір теми, власні кольори й попередній перегляд.
struct HUDThemeWindow: View {
    @AppStorage("hud.theme") private var themeID = "classic"
    @AppStorage("hud.sky") private var sky = ""
    @AppStorage("hud.ground") private var ground = ""
    @AppStorage("hud.ink") private var ink = ""
    @AppStorage("hud.accent") private var accent = ""
    @AppStorage("hud.scale") private var scale = 1.0

    var theme: HUDTheme { HUDTheme.make(id: themeID, sky: sky, ground: ground, ink: ink, accent: accent) }
    static var sample: Telemetry {
        var t = Telemetry()
        t.connected = true; t.mode = "FBWA"; t.armed = true; t.roll = 12; t.pitch = 4; t.yaw = 120; t.heading = 120
        t.altRel = 48.2; t.altMsl = 190; t.groundSpeed = 17.4; t.airSpeed = 18.1; t.climb = 1.2; t.throttle = 55
        t.batteryV = 15.1; t.batteryA = 12.3; t.batteryPct = 74; t.gpsFix = 3; t.sats = 14; t.ekfFlags = 0x1FF
        return t
    }

    func colorBinding(_ hex: Binding<String>, _ fallback: Color) -> Binding<Color> {
        Binding(get: { Color(hex: hex.wrappedValue) ?? fallback }, set: { hex.wrappedValue = $0.hex })
    }

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Тема HUD").font(.title3.weight(.semibold))
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 10)], spacing: 10) {
                    ForEach(HUDTheme.all, id: \.id) { th in
                        Button { themeID = th.id; sky = ""; ground = ""; ink = ""; accent = "" } label: {
                            VStack(spacing: 4) {
                                ZStack {
                                    VStack(spacing: 0) {
                                        LinearGradient(colors: [th.skyTop, th.skyBottom], startPoint: .top, endPoint: .bottom)
                                        LinearGradient(colors: [th.groundTop, th.groundBottom], startPoint: .top, endPoint: .bottom)
                                    }
                                    Rectangle().fill(th.ink).frame(height: 1.5).padding(.horizontal, 12)
                                    Circle().strokeBorder(th.accent, lineWidth: 2).frame(width: 14, height: 14)
                                }
                                .frame(height: 54).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(themeID == th.id ? Color.accentColor : Color.primary.opacity(0.15), lineWidth: themeID == th.id ? 2 : 1))
                                Text(LocalizedStringKey(th.name)).font(.caption).foregroundStyle(themeID == th.id ? Color.primary : Color.secondary)
                            }
                        }.buttonStyle(.plain)
                    }
                }
                Divider()
                Text("Масштаб інтерфейсу").font(.headline)
                HStack {
                    Image(systemName: "textformat.size.smaller").foregroundStyle(.secondary)
                    Slider(value: $scale, in: 0.6...1.6, step: 0.05)
                    Image(systemName: "textformat.size.larger").foregroundStyle(.secondary)
                    Text("\(Int((scale * 100).rounded()))%").monospacedDigit().frame(width: 44, alignment: .trailing)
                }
                Button("100%") { scale = 1.0 }.disabled(abs(scale - 1) < 0.01)
                Divider()
                Text("Кольори").font(.headline)
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                    GridRow { Text("Небо"); ColorPicker("", selection: colorBinding($sky, theme.skyBottom), supportsOpacity: false).labelsHidden() }
                    GridRow { Text("Земля"); ColorPicker("", selection: colorBinding($ground, theme.groundTop), supportsOpacity: false).labelsHidden() }
                    GridRow { Text("Лінії й текст"); ColorPicker("", selection: colorBinding($ink, theme.ink), supportsOpacity: false).labelsHidden() }
                    GridRow { Text("Акцент (покажчики)"); ColorPicker("", selection: colorBinding($accent, theme.accent), supportsOpacity: false).labelsHidden() }
                }
                HStack {
                    Button("Скинути кольори теми") { sky = ""; ground = ""; ink = ""; accent = "" }.disabled(sky.isEmpty && ground.isEmpty && ink.isEmpty && accent.isEmpty)
                    Spacer()
                }
                Text("Кольори застосовуються до HUD у Flight Data та до HUD поверх відео.").font(.caption).foregroundStyle(.secondary)
            }
            .frame(width: 300)
            VStack(alignment: .leading, spacing: 6) {
                Text("Перегляд").font(.headline)
                HUDView(t: Self.sample, navSource: .gps, alerts: [], config: { var c = HUDConfig(); c.theme = theme; c.scale = scale; c.userItems = ["alt", "throttle", "pitch", "roll"]; return c }())
                    .frame(width: 560, height: 400)
            }
        }
        .padding(20)
    }
}
