import SwiftUI

/// Налаштування HUD (меню правої кнопки миші).
struct HUDConfig {
    var groundColor = true
    var videoBackground = false
    var cellVoltage = false
    var hidden: Set<String> = []
    var userItems: [String] = []
    var userNames: [String: String] = [:]      // власні назви User Items (ключ → назва на HUD)
    var userValues: [String: String] = [:]     // поточні значення довільних полів MAVLink (ключ «m:ПОВІДОМЛЕННЯ.поле»)
    var theme: HUDTheme = .classic
    var scale = 1.0                 // масштаб елементів HUD (0.6…1.6)

    static let elements: [(String, String)] = [
        ("compass", "Компасна стрічка"), ("speed", "Стрічка швидкості"), ("alt", "Стрічка висоти"),
        ("pitch", "Сходи тангажа"), ("bank", "Шкала крену"),
        ("battery", "Батарея"), ("gps", "GPS"), ("mode", "Режим польоту"), ("status", "ARMED / DISARMED"), ("wp", "Відстань до WP"),
    ]
    /// Типовий набір User Items (текстові параметри зліва на HUD).
    static let defaultUser = "alt,throttle,navpitch,navroll,pitch,roll,vibex,vibey,vibez,yaw"
    static let userDefs: [(String, String)] = [
        ("alt", "ALT (відносна висота)"), ("throttle", "Throttle"), ("navpitch", "nav_pitch"), ("navroll", "nav_roll"),
        ("pitch", "pitch"), ("roll", "roll"), ("vibex", "vibex"), ("vibey", "vibey"), ("vibez", "vibez"), ("yaw", "yaw"),
        ("altmsl", "Висота MSL"), ("airspeed", "Повітряна швидкість"), ("climb", "Вертикальна швидкість"), ("hdop", "HDOP"),
        ("sats", "Супутники"), ("mah", "Витрачено, мАг"), ("rssi", "RSSI"), ("wpdist", "Дистанція до WP"),
        ("timeinair", "Час у повітрі"), ("disttrav", "Пройдена дистанція"), ("vibemax", "Вібрація (макс.)"), ("heading", "Курс"),
        ("groundspeed", "Швидкість по землі"), ("lat", "Широта"), ("lng", "Довгота"), ("battv", "Напруга батареї, В"),
        ("battcurr", "Струм, А"), ("battpct", "Залишок батареї, %"), ("gpsfix", "Тип фіксації GPS"), ("wpno", "Номер WP"),
        ("magheading", "Курс за компасом"), ("cog", "Курс GPS (COG)"), ("vibeclip0", "Vibe clip 0"), ("vibeclip1", "Vibe clip 1"),
        ("vibeclip2", "Vibe clip 2"), ("ekfvel", "EKF: дисперсія швидкості"), ("ekfposh", "EKF: дисперсія позиції (гор.)"),
        ("ekfposv", "EKF: дисперсія позиції (верт.)"), ("ekfcompass", "EKF: дисперсія компаса"), ("ekfterrain", "EKF: дисперсія рельєфу"),
        ("mode", "Режим польоту"), ("armed", "Стан ARM"),
    ]
    /// Префікс ключа довільного поля MAVLink: «m:ATTITUDE.roll».
    static let mavPrefix = "m:"
    /// Заголовок за замовчуванням для ключа User Items.
    static func defaultLabel(_ key: String) -> String {
        if key.hasPrefix(mavPrefix) { return String(key.dropFirst(mavPrefix.count)) }
        return userDefs.first { $0.0 == key }?.1 ?? key
    }
}

/// HUD у стилі Mission Planner: штучний горизонт, шкала крену, компасна стрічка, стрічки швидкості та висоти, оверлеї.
enum NavSource { case gps, viso, none }

struct HUDView: View {
    @Environment(\.openWindow) private var openWindow
    let t: Telemetry
    var navSource: NavSource = .gps
    var alerts: [Alert] = []
    var config = HUDConfig()
    private func show(_ k: String) -> Bool { !config.hidden.contains(k) }
    /// Рядки User Items у порядку вибору: «Назва: значення». Назву можна перейменувати (config.userNames).
    private func userLines() -> [String] {
        AddonManager.shared.hudLines + config.userItems.compactMap { k -> String? in
            let name = config.userNames[k]
            if k.hasPrefix(HUDConfig.mavPrefix) {
                return "\(name ?? HUDConfig.defaultLabel(k)): \(config.userValues[k] ?? "—")"
            }
            guard let raw = builtinLine(k) else { return nil }
            guard let n = name, let c = raw.firstIndex(of: ":") else { return raw }
            return n + raw[c...]
        }
    }
    private func builtinLine(_ k: String) -> String? {
        do {
            switch k {
            case "alt": return "ALT: " + Units.altNum(t.altRel, digits: 2) + (Units.altKey == "m" ? "" : " " + Units.altLabel(en: true))
            case "throttle": return String(format: "Throttle: %.0f", t.throttle)
            case "navpitch": return String(format: "nav_pitch: %.0f", t.navPitch)
            case "navroll": return String(format: "nav_roll: %.0f", t.navRoll)
            case "pitch": return String(format: "pitch: %.2f", t.pitch)
            case "roll": return String(format: "roll: %.2f", t.roll)
            case "vibex": return String(format: "vibex: %.2f", t.vibeX)
            case "vibey": return String(format: "vibey: %.2f", t.vibeY)
            case "vibez": return String(format: "vibez: %.2f", t.vibeZ)
            case "yaw": return String(format: "yaw: %.2f", t.yaw)
            case "altmsl": return "ALT MSL: " + Units.altNum(t.altMsl, digits: 1) + (Units.altKey == "m" ? "" : " " + Units.altLabel(en: true))
            case "airspeed": return "AirSpeed: " + Units.speedNum(t.airSpeed) + (Units.speedKey == "ms" ? "" : " " + Units.speedLabel(en: true))
            case "climb": return String(format: "VSpeed: %.2f", t.climb)
            case "hdop": return t.hdop > 0 && t.hdop < 99 ? String(format: "HDOP: %.1f", t.hdop) : "HDOP: —"
            case "sats": return "Sats: \(t.sats)"
            case "mah": return String(format: "mAh: %.0f", t.mahUsed)
            case "rssi": return String(format: "RSSI: %.0f", t.rssi)
            case "wpdist": return "WP dist: " + Units.distNum(t.wpDist) + (Units.distKey == "m" ? "" : " " + Units.distLabel(en: true))
            case "timeinair": return String(format: "TiA: %d:%02d", Int(t.timeInAir) / 60, Int(t.timeInAir) % 60)
            case "disttrav": return "Dist: " + Units.distNum(t.distTraveled) + (Units.distKey == "m" ? "" : " " + Units.distLabel(en: true))
            case "vibemax": return String(format: "Vibe: %.1f", max(t.vibeX, t.vibeY, t.vibeZ))
            case "heading": return String(format: "Heading: %.0f", t.heading)
            case "groundspeed": return "GroundSpeed: " + Units.speedNum(t.groundSpeed) + (Units.speedKey == "ms" ? "" : " " + Units.speedLabel(en: true))
            case "lat": return Coords.isMGRS ? "MGRS: " + (Coords.mgrs(t.lat, t.lon) ?? "—") : String(format: "Lat: %.6f", t.lat)
            case "lng": return Coords.isMGRS ? "" : String(format: "Lng: %.6f", t.lon)
            case "battv": return String(format: "Battery V: %.2f", t.batteryV)
            case "battcurr": return String(format: "Current: %.1f", t.batteryA)
            case "battpct": return "Battery: \(t.batteryPct)%"
            case "gpsfix": return "GPS fix: \(t.gpsFix)"
            case "wpno": return "WP: \(t.wpSeq)"
            case "magheading": return t.magHdg.map { $0 >= 0 ? String(format: "MagHdg: %.0f", $0) : "MagHdg: —" } ?? "MagHdg: —"
            case "cog": return t.cog.map { $0 >= 0 ? String(format: "COG: %.0f", $0) : "COG: —" } ?? "COG: —"
            case "vibeclip0": return String(format: "Clip0: %.0f", t.vibeClip0)
            case "vibeclip1": return String(format: "Clip1: %.0f", t.vibeClip1)
            case "vibeclip2": return String(format: "Clip2: %.0f", t.vibeClip2)
            case "ekfvel": return String(format: "EKF vel: %.2f", t.ekfVelVar)
            case "ekfposh": return String(format: "EKF posH: %.2f", t.ekfPosHVar)
            case "ekfposv": return String(format: "EKF posV: %.2f", t.ekfPosVVar)
            case "ekfcompass": return String(format: "EKF compass: %.2f", t.ekfCompassVar)
            case "ekfterrain": return String(format: "EKF terrain: %.2f", t.ekfTerrainVar)
            case "mode": return "Mode: \(t.mode ?? "—")"
            case "armed": return "Armed: \(t.armed ? "yes" : "no")"
            default: return nil
            }
        }
    }

    private var ekfOK: Bool { (t.ekfFlags & 7) == 7 }
    private var vibeMax: Double { max(t.vibeX, t.vibeY, t.vibeZ) }
    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            let u = max(0.7, min(1.35, min(w, h * 1.25) / 520)) * CGFloat(config.scale)
            let c = CGPoint(x: w / 2, y: h * 0.44)
            let ppd = h / 42
            let rad = Double.pi / 180
            // Опорні розміри та зони (щоб елементи не накладалися)
            let Rr = max(26, min(h * 0.105, 58 * u))
            let alertBand: CGFloat = 26 * min(u, 1) + 2 + 5 + 8                  // смуга внизу під попередження
            let rc = CGPoint(x: c.x, y: h - Rr - max(30 * u, alertBand + 2))
            let gr = Rr * 0.54, gOff = Rr * 2.4
            let th = config.theme
            let ink = th.ink, accent = th.accent
            let wide = (c.x - gOff - gr > 108 * u) && h > 360          // дуги THR/BATT вміщуються між стрічками
            let textWide = w > 600 * u                                 // текст стоїть поряд зі стрічкою швидкості
            let userL = userLines()
            let roseTop = show("compass") ? rc.y - Rr - 32 * u : h - 10 * u
            let maxText = max(1, Int((c.y - 30 * u - 16 * u) / (14 * u)))
            let cardLines = textWide ? userL.count : min(userL.count, maxText)
            let cardBottom = textWide || userL.isEmpty ? 4 * u : 8 * u + CGFloat(cardLines) * 14 * u + 10 * u
            func T(_ s: String, _ sz: CGFloat, _ wt: Font.Weight = .medium, _ op: Double = 1, _ col: Color? = nil) -> Text {
                Text(LocalizedStringKey(s)).font(.system(size: sz * u, weight: wt, design: .rounded).monospacedDigit()).foregroundColor((col ?? ink).opacity(op))
            }
            func line(_ a: CGPoint, _ b: CGPoint, _ col: Color, _ lw: CGFloat, dash: [CGFloat] = []) {
                var p = Path(); p.move(to: a); p.addLine(to: b); ctx.stroke(p, with: .color(col), style: StrokeStyle(lineWidth: lw, lineCap: .round, dash: dash))
            }

            // --- Горизонт ---
            ctx.clip(to: Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 10))
            var g = ctx
            g.translateBy(x: c.x, y: c.y)
            g.rotate(by: .radians(-t.roll * rad))
            g.translateBy(x: 0, y: t.pitch * ppd)
            let big = max(w, h) * 2.5
            if !config.videoBackground {
                g.fill(Path(CGRect(x: -big, y: -big, width: big * 2, height: big)),
                       with: .linearGradient(Gradient(colors: [th.skyTop, th.skyBottom]), startPoint: CGPoint(x: 0, y: -h), endPoint: .zero))
                g.fill(Path(CGRect(x: -big, y: 0, width: big * 2, height: big)),
                       with: config.groundColor
                        ? .linearGradient(Gradient(colors: [th.groundTop, th.groundBottom]), startPoint: .zero, endPoint: CGPoint(x: 0, y: h))
                        : .color(Color(white: 0.12)))
            }
            // Лінія горизонту: коротка, пунктирна й прозора
            var hz = Path(); hz.move(to: CGPoint(x: -120 * u, y: 0)); hz.addLine(to: CGPoint(x: 120 * u, y: 0))
            g.stroke(hz, with: .color(ink.opacity(0.5)), style: StrokeStyle(lineWidth: 1.2, lineCap: .round, dash: [7 * u, 5 * u]))
            // Сходи тангажа: короткі пунктирні лінії; цифри прив'язані до кінців ліній, рухаються з ними і лишаються вертикальними
            if show("pitch") {
                for d in stride(from: -60, through: 60, by: 5) where d != 0 {
                    let y = -Double(d) * ppd
                    if abs(y + t.pitch * ppd) > h * 0.30 { continue }   // не заходимо під розу й шкалу крену
                    let op = max(0.08, 1 - abs(y + t.pitch * ppd) / (h * 0.30)) * 0.6
                    let half: CGFloat = (d % 10 == 0 ? 34 : 20) * u
                    var ln = Path(); ln.move(to: CGPoint(x: -half, y: y)); ln.addLine(to: CGPoint(x: half, y: y))
                    g.stroke(ln, with: .color(ink.opacity(op)), style: StrokeStyle(lineWidth: 1.1, lineCap: .round, dash: [4 * u, 3 * u]))
                    let tx = Text("\(abs(d))").font(.system(size: 9.5 * u, weight: .medium, design: .rounded)).foregroundColor(ink.opacity(min(1, op * 1.4)))
                    for sx in [-1.0, 1.0] {
                        var gt = g
                        gt.translateBy(x: CGFloat(sx) * (half + 11 * u), y: y)
                        gt.rotate(by: .radians(t.roll * rad))      // компенсуємо крен: цифри лишаються прямими, але прив'язані до лінії
                        gt.draw(tx, at: .zero)
                    }
                }
            }

            // --- Шкала крену ---
            let Rb = 0.82 * max(48 * u, min(h * 0.26, c.y - 66 * u))
            if show("bank") {
                for a in [-60, -45, -30, -20, -10, 0, 10, 20, 30, 45, 60] {
                    let ang = (Double(a) - 90) * rad
                    let long = a % 30 == 0
                    line(CGPoint(x: c.x + Rb * cos(ang), y: c.y + Rb * sin(ang)),
                         CGPoint(x: c.x + (Rb - (long ? 8 : 5) * u) * cos(ang), y: c.y + (Rb - (long ? 8 : 5) * u) * sin(ang)), ink.opacity(0.6), long ? 1.4 : 0.9)
                }
                var arc = Path(); arc.addArc(center: c, radius: Rb, startAngle: .degrees(-150), endAngle: .degrees(-30), clockwise: false)
                ctx.stroke(arc, with: .color(ink.opacity(0.16)), lineWidth: 3 * u)
                let ra = (-t.roll - 90) * rad
                var tri = Path()
                tri.move(to: CGPoint(x: c.x + (Rb - 2) * cos(ra), y: c.y + (Rb - 2) * sin(ra)))
                tri.addLine(to: CGPoint(x: c.x + (Rb - 15 * u) * cos(ra - 0.07), y: c.y + (Rb - 15 * u) * sin(ra - 0.07)))
                tri.addLine(to: CGPoint(x: c.x + (Rb - 15 * u) * cos(ra + 0.07), y: c.y + (Rb - 15 * u) * sin(ra + 0.07)))
                tri.closeSubpath()
                ctx.fill(tri, with: .color(accent))
                var zero = Path(); zero.move(to: CGPoint(x: c.x, y: c.y - Rb - 2 * u)); zero.addLine(to: CGPoint(x: c.x - 6 * u, y: c.y - Rb - 11 * u)); zero.addLine(to: CGPoint(x: c.x + 6 * u, y: c.y - Rb - 11 * u)); zero.closeSubpath()
                ctx.stroke(zero, with: .color(ink), lineWidth: 1.4)
            }

            // --- Приціл апарата: кільце + «крила» ---
            ctx.stroke(Path(ellipseIn: CGRect(x: c.x - 7 * u, y: c.y - 7 * u, width: 14 * u, height: 14 * u)), with: .color(ink.opacity(0.8)), lineWidth: 1.6)
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - 2.5 * u, y: c.y - 2.5 * u, width: 5 * u, height: 5 * u)), with: .color(ink))
            for s in [-1.0, 1.0] {
                var wing = Path()
                wing.move(to: CGPoint(x: c.x + s * 58 * u, y: c.y)); wing.addLine(to: CGPoint(x: c.x + s * 20 * u, y: c.y)); wing.addLine(to: CGPoint(x: c.x + s * 20 * u, y: c.y + 6 * u))
                ctx.stroke(wing, with: .color(ink.opacity(0.85)), style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
            }

            // --- Стрічки швидкості (ліворуч) і висоти (праворуч): без рамок, згасають від центру ---
            func tape(left: Bool, value: Double, big: String, unit: String, sub: String) {
                let ppu = 7.5 * u, span = 150 * u, mid = c.y
                let topLim = left ? cardBottom : (show("gps") ? 46 * u : 4 * u)
                let botLim = left ? h - (wide ? 34 * u : 76 * u) : h - 46 * u
                let edge = left ? 80 * u : w - 80 * u
                let dir: CGFloat = left ? 1 : -1
                for v in Int(value.rounded(.down)) - 22...Int(value.rounded(.down)) + 22 {
                    let y = mid - (Double(v) - value) * ppu
                    let dy = abs(y - mid)
                    if dy > span || y < topLim || y > botLim { continue }
                    let op = max(0, 1 - dy / span)
                    let major = v % 5 == 0
                    line(CGPoint(x: edge, y: y), CGPoint(x: edge + dir * (major ? 13 : 6) * u, y: y), ink.opacity(op * 0.9), 1.2)
                    if major && dy > 54 * u { ctx.draw(T("\(v)", 12, .medium, op), at: CGPoint(x: left ? 56 * u : w - 56 * u, y: y)) }
                }
                line(CGPoint(x: edge, y: max(mid - span, topLim)), CGPoint(x: edge, y: min(mid + span, botLim)), ink.opacity(0.18), 1)
                let pill = CGRect(x: left ? 6 * u : w - 76 * u, y: mid - 17 * u, width: 70 * u, height: 34 * u)
                ctx.fill(Path(roundedRect: pill, cornerRadius: 9 * u, style: .continuous), with: .color(th.plate))
                ctx.draw(T(big, 20, .semibold), at: CGPoint(x: pill.midX, y: pill.midY))
                var tri = Path()
                tri.move(to: CGPoint(x: edge, y: mid)); tri.addLine(to: CGPoint(x: edge - dir * 8 * u, y: mid - 6 * u)); tri.addLine(to: CGPoint(x: edge - dir * 8 * u, y: mid + 6 * u)); tri.closeSubpath()
                ctx.fill(tri, with: .color(accent))
                ctx.draw(T(unit, 10, .medium, 0.75), at: CGPoint(x: pill.midX, y: pill.maxY + 9 * u))
                if !sub.isEmpty { ctx.draw(T(sub, 11, .medium, 0.85), at: CGPoint(x: pill.midX, y: pill.maxY + 23 * u)) }
            }
            if show("speed") { tape(left: true, value: t.groundSpeed, big: Units.speedNum(t.groundSpeed), unit: "GS " + Units.speedLabel(en: true), sub: "AS " + Units.speedNum(t.airSpeed)) }
            if show("alt") {
                tape(left: false, value: t.altRel, big: Units.altNum(t.altRel, digits: 1), unit: "ALT " + Units.altLabel(en: true), sub: "MSL " + Units.altNum(t.altMsl))
                // Шкала вертикальної швидкості
                if w > 460 {
                    let x0 = w - 124 * u, k = 10 * u
                    let vTop = show("gps") ? 46 * u : 4 * u, vBot = h - 46 * u
                    for v in -6...6 {
                        let y = c.y - Double(v) * k
                        if y < vTop || y > vBot { continue }
                        line(CGPoint(x: x0, y: y), CGPoint(x: x0 + 8 * u, y: y), ink.opacity(0.75), 1.1)
                        if v != 0 { ctx.draw(T("\(abs(v))", 10, .medium, 0.8), at: CGPoint(x: x0 - 9 * u, y: y)) }
                    }
                    let cl = max(-6, min(6, t.climb))
                    var p = Path(); let py = min(max(c.y - cl * k, vTop), vBot)
                    p.move(to: CGPoint(x: x0 + 9 * u, y: py)); p.addLine(to: CGPoint(x: x0 + 18 * u, y: py - 5 * u)); p.addLine(to: CGPoint(x: x0 + 18 * u, y: py + 5 * u)); p.closeSubpath()
                    ctx.fill(p, with: .color(t.climb >= 0 ? .green : .orange))
                    if c.y - 6 * k - 14 * u > vTop { ctx.draw(T(String(format: "%.2f", t.climb), 12, .semibold), at: CGPoint(x: x0 + 8 * u, y: c.y - 6 * k - 14 * u)) }
                    if c.y + 6 * k + 12 * u < vBot { ctx.draw(T("m/s", 9, .medium, 0.7), at: CGPoint(x: x0 + 8 * u, y: c.y + 6 * k + 12 * u)) }
                }
            }

            // --- Режим і статус ---
            let topY = max(16 * u, c.y - Rb - 48 * u)
            if show("mode") { ctx.draw(T((t.mode ?? "—").uppercased(), 20, .bold), at: CGPoint(x: c.x, y: topY)) }
            if show("status") {
                let txt = t.armed ? "ARMED" : "DISARMED"
                let chip = CGRect(x: c.x - 40 * u, y: topY + 13 * u, width: 80 * u, height: 17 * u)
                ctx.fill(Path(roundedRect: chip, cornerRadius: 8.5 * u, style: .continuous), with: .color((t.armed ? Color.green : Color.red).opacity(0.85)))
                ctx.draw(T(txt, 10, .bold), at: CGPoint(x: chip.midX, y: chip.midY))
            }

            // --- Компасна роза знизу + дуги газу та батареї ---
            if show("compass") {
                let hdg = t.heading
                ctx.fill(Path(ellipseIn: CGRect(x: rc.x - Rr, y: rc.y - Rr, width: Rr * 2, height: Rr * 2)), with: .color(.black.opacity(0.10)))
                ctx.stroke(Path(ellipseIn: CGRect(x: rc.x - Rr, y: rc.y - Rr, width: Rr * 2, height: Rr * 2)), with: .color(ink.opacity(0.5)), lineWidth: 1)
                ctx.stroke(Path(ellipseIn: CGRect(x: rc.x - Rr * 0.55, y: rc.y - Rr * 0.55, width: Rr * 1.1, height: Rr * 1.1)), with: .color(ink.opacity(0.25)), lineWidth: 0.8)
                for d in stride(from: 0, to: 360, by: 5) {
                    let ang = (Double(d) - hdg - 90) * rad
                    let len: CGFloat = (d % 30 == 0 ? 7 : (d % 10 == 0 ? 4 : 2.5)) * u
                    line(CGPoint(x: rc.x + Rr * cos(ang), y: rc.y + Rr * sin(ang)), CGPoint(x: rc.x + (Rr - len) * cos(ang), y: rc.y + (Rr - len) * sin(ang)), ink.opacity(0.55), 0.9)
                }
                let names = [0: "N", 90: "E", 180: "S", 270: "W"]
                for d in stride(from: 0, to: 360, by: 30) {
                    var cg = ctx
                    cg.translateBy(x: rc.x, y: rc.y); cg.rotate(by: .degrees(Double(d) - hdg))
                    let label = names[d] ?? "\(d / 10)"
                    cg.draw(T(label, names[d] != nil ? 11 : 8.5, names[d] != nil ? .semibold : .medium, names[d] != nil ? 0.9 : 0.65, names[d] == "N" ? .red : nil), at: CGPoint(x: 0, y: -(Rr - 16 * u)))
                }
                var mark = Path(); mark.move(to: CGPoint(x: rc.x, y: rc.y - Rr + 1)); mark.addLine(to: CGPoint(x: rc.x - 6 * u, y: rc.y - Rr - 9 * u)); mark.addLine(to: CGPoint(x: rc.x + 6 * u, y: rc.y - Rr - 9 * u)); mark.closeSubpath()
                ctx.fill(mark, with: .color(ink))
                ctx.draw(T("\(Int(hdg.rounded()) % 360)°", 13, .semibold, 0.9), at: CGPoint(x: rc.x, y: rc.y - Rr - 19 * u))
                line(CGPoint(x: rc.x - 7 * u, y: rc.y), CGPoint(x: rc.x + 7 * u, y: rc.y), ink.opacity(0.7), 1.1)
                line(CGPoint(x: rc.x, y: rc.y - 7 * u), CGPoint(x: rc.x, y: rc.y + 7 * u), ink.opacity(0.7), 1.1)
            }
            func gauge(_ ctr: CGPoint, _ r: CGFloat, frac: Double, color: Color, value: String, label: String, sub: [String]) {
                func arc(_ f: Double) -> Path {
                    var p = Path(); let n = 48
                    for i in 0...n {
                        let ang = (135 + 270 * f * Double(i) / Double(n)) * rad
                        let pt = CGPoint(x: ctr.x + r * cos(ang), y: ctr.y + r * sin(ang))
                        if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                    }
                    return p
                }
                ctx.stroke(arc(1), with: .color(ink.opacity(0.28)), style: StrokeStyle(lineWidth: 4 * u, lineCap: .round))
                if frac > 0.005 { ctx.stroke(arc(min(1, frac)), with: .color(color), style: StrokeStyle(lineWidth: 4 * u, lineCap: .round)) }
                ctx.draw(T(value, 17, .semibold), at: ctr)
                for (i, s) in sub.enumerated() { ctx.draw(T(s, 10, .medium, 0.7), at: CGPoint(x: ctr.x, y: ctr.y + r * 0.62 + CGFloat(i) * 12 * u)) }
                ctx.draw(T(label, 11, .bold), at: CGPoint(x: ctr.x, y: ctr.y + r + 13 * u))
            }
            let battCol: Color = t.batteryPct < 20 ? .red : (t.batteryPct < 40 ? .orange : ink)
            if wide {
                gauge(CGPoint(x: rc.x - gOff, y: rc.y), gr, frac: max(0, min(1, t.throttle / 100)), color: ink, value: String(format: "%.0f", t.throttle), label: "THR %", sub: [])
                if show("battery") {
                    gauge(CGPoint(x: rc.x + gOff, y: rc.y), gr, frac: Double(max(0, min(100, t.batteryPct))) / 100, color: battCol, value: "\(max(0, t.batteryPct))",
                          label: "BATT %", sub: [String(format: "%.2f V", t.batteryV), String(format: "%.1f A", t.batteryA)])
                    if config.cellVoltage {
                        let cells = max(1, Int(ceil(t.batteryV / 4.3)))
                        ctx.draw(T(String(format: "%.2fV/cell (%dS)", t.batteryV / Double(cells), cells), 11, .medium, 1, .yellow), at: CGPoint(x: rc.x + gOff, y: rc.y - gr - 14 * u))
                    }
                }
            } else if show("battery") {
                // Компактний режим: батарея текстом
                let bx: CGFloat = 12 * u, by = h - 72 * u
                ctx.stroke(Path(roundedRect: CGRect(x: bx, y: by, width: 20 * u, height: 36 * u), cornerRadius: 3), with: .color(battCol), lineWidth: 2)
                let frac = CGFloat(max(0, min(100, t.batteryPct))) / 100
                ctx.fill(Path(CGRect(x: bx + 2, y: by + 2 + 32 * u * (1 - frac), width: 16 * u, height: 32 * u * frac)), with: .color(battCol))
                ctx.draw(T(String(format: "%.2fV", t.batteryV), 12, .bold), at: CGPoint(x: bx + 28 * u, y: by + 6 * u), anchor: .leading)
                ctx.draw(T(String(format: "%.1fA", t.batteryA), 12, .bold), at: CGPoint(x: bx + 28 * u, y: by + 20 * u), anchor: .leading)
                ctx.draw(T("\(max(0, t.batteryPct))%", 12, .bold), at: CGPoint(x: bx + 28 * u, y: by + 34 * u), anchor: .leading)
            }

            // --- Текстові оверлеї (User Items) ---
            if !userL.isEmpty {
                var lines = Array(userL.prefix(cardLines))
                if cardLines < userL.count { lines[lines.count - 1] = String(localized: "… ще \(userL.count - cardLines + 1)") }
                let x0: CGFloat = textWide ? 104 * u : 10 * u
                let y0: CGFloat = textWide ? 20 * u : 8 * u + 7 * u
                if !textWide {
                    ctx.fill(Path(roundedRect: CGRect(x: 6 * u, y: 6 * u, width: 104 * u, height: cardBottom - 6 * u), cornerRadius: 8 * u, style: .continuous), with: .color(.black.opacity(0.28)))
                }
                for (i, l) in lines.enumerated() {
                    ctx.draw(Text(LocalizedStringKey(l)).font(.system(size: 11 * u, weight: .medium, design: .monospaced)).foregroundColor(ink.opacity(0.9)),
                             at: CGPoint(x: x0, y: y0 + CGFloat(i) * 14 * u), anchor: .leading)
                }
            }

            // --- Критичні та небезпечні повідомлення (червоним): стопка між прицілом і розою ---
            var items: [(String, Bool)] = alerts.suffix(4).map { ($0.text, $0.sev <= 3) }
            if !t.armed && alerts.contains(where: { $0.text.localizedCaseInsensitiveContains("prearm") }) { items.append(("Not Ready to Arm", true)) }
            if !ekfOK { items.append(("EKF не готовий", true)) }
            // Попередження: один ряд у самому низу HUD (під компасною розою вільна смуга), найновіші по центру
            let bh: CGFloat = 26 * min(u, 1) + 2
            let yRow = h - 5 - bh / 2
            var chips: [(String, Bool, GraphicsContext.ResolvedText, CGSize)] = []
            for al in items {
                let r = ctx.resolve(Text(LocalizedStringKey(al.0)).font(.system(size: 12.5 * min(u, 1), weight: .semibold)).foregroundColor(.white))
                chips.append((al.0, al.1, r, r.measure(in: CGSize(width: w - 80, height: 30))))
            }
            let reserve: CGFloat = max(show("wp") ? 100 * u : 24, 150)      // ліворуч унизу «WP ▸ …», праворуч чіпи EKF/VIBE
            let avail = max(80, w - 2 * reserve)
            var shown: [(String, Bool, GraphicsContext.ResolvedText, CGSize)] = []
            var used: CGFloat = 0
            for ch in chips.reversed() {
                let cw = ch.3.width + 44 + (shown.isEmpty ? 0 : 6)
                if used + cw > avail && !shown.isEmpty { break }
                shown.insert(ch, at: 0); used += cw
            }
            var x = c.x - used / 2
            for ch in shown {
                let col: Color = ch.1 ? Color(red: 1, green: 0.27, blue: 0.23) : Color.orange
                let bw = ch.3.width + 44
                let box = CGRect(x: x, y: yRow - bh / 2, width: bw, height: bh)
                ctx.fill(Path(roundedRect: box, cornerRadius: bh / 2, style: .continuous), with: .color(.black.opacity(0.5)))
                var icon = ctx.resolve(Image(systemName: ch.1 ? "exclamationmark.triangle.fill" : "exclamationmark.circle.fill"))
                icon.shading = .color(col)
                ctx.draw(icon, at: CGPoint(x: box.minX + 17, y: yRow))
                ctx.draw(ch.2, at: CGPoint(x: box.minX + 30 + ch.3.width / 2, y: yRow))
                x += bw + 6
            }
            if show("wp") { ctx.draw(T(String(format: "WP ▸ %.0f m", t.wpDist), 11, .medium, 0.9), at: CGPoint(x: 12 * u, y: h - 12 * u), anchor: .leading) }
        }
        .overlay(alignment: .topTrailing) { if show("gps") { NavStatusChip(t: t, source: navSource).scaleEffect(config.scale, anchor: .topTrailing).padding(10) } }
        .overlay(alignment: .bottomTrailing) {
            HStack(spacing: 6) {
                statusBadge("EKF", ok: ekfOK, id: "ekf")
                statusBadge("VIBE", ok: vibeMax < 30, id: "vibration")
            }.scaleEffect(config.scale, anchor: .bottomTrailing).padding(10)
        }
        .background(config.videoBackground ? Color.clear : Color.black, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.gray.opacity(0.4), lineWidth: 1))
    }

    func statusBadge(_ title: String, ok: Bool, id: String) -> some View {
        Button { openWindow(id: id) } label: {
            HStack(spacing: 5) {
                Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(ok ? Color.green : Color.red)
                Text(LocalizedStringKey(title)).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(.ultraThinMaterial.opacity(0.9), in: Capsule())
            .background(Color.black.opacity(0.28), in: Capsule())
        }
        .buttonStyle(.plain)
        .tip(id == "ekf" ? "Відкрити EKF Status" : "Відкрити Vibration")
    }
}

/// Ситуативна позначка навігації: GPS 3D Fix, якщо GPS використовується, інакше стан VISO (оптична одометрія).
struct NavStatusChip: View {
    let t: Telemetry
    let source: NavSource

    var spec: (icon: String, text: String, color: Color)? {
        switch source {
        case .gps:
            let names = ["No GPS", "No Fix", "2D Fix", "3D Fix", "DGPS", "RTK Float", "RTK Fixed"]
            let name = names[min(max(t.gpsFix, 0), names.count - 1)]
            let color: Color = t.gpsFix >= 3 ? .green : (t.gpsFix == 2 ? .orange : .red)
            return ("location.fill", "GPS \(loc(name))" + (t.gpsFix >= 2 ? " · \(t.sats)" : ""), color)
        case .viso:
            // Позиція від зовнішнього джерела: стан за SYS_STATUS і прапорцями EKF (позиція відносна/абсолютна)
            let ekfPos = (t.ekfFlags & (8 | 16)) != 0
            if t.visoPresent && t.visoHealthy && ekfPos { return ("viewfinder", "VISO OK", .green) }
            if t.visoPresent && t.visoHealthy { return ("viewfinder", "VISO · очікування EKF", .orange) }
            return ("viewfinder", t.visoPresent ? "VISO без даних" : "VISO не активне", t.visoPresent ? .red : .orange)
        case .none:
            return ("location.slash", "Без GPS", .secondary)
        }
    }

    var body: some View {
        if let s = spec {
            HStack(spacing: 6) {
                Image(systemName: s.icon).font(.system(size: 11, weight: .bold)).foregroundStyle(s.color)
                Text(LocalizedStringKey(s.text)).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
            }
            .padding(.horizontal, 11).padding(.vertical, 5)
            .background(.ultraThinMaterial.opacity(0.9), in: Capsule())
            .background(Color.black.opacity(0.28), in: Capsule())
        }
    }
}
