import SwiftUI

/// Тема HUD «MILI»: моно-блакитний мінімалістичний HUD із кутовими рамками, вертикальними драбинами швидкості й висоти,
/// дугою компаса, прицілом із драбиною тангажа та текстовими блоками «КЛЮЧ : значення» з показниками, що виводяться на OSD.
struct MiliHUD: View {
    let t: Telemetry
    var config = HUDConfig()
    var alerts: [Alert] = []

    private func show(_ k: String) -> Bool { !config.hidden.contains(k) }
    static let cyan = Color(red: 0.36, green: 0.86, blue: 0.92)
    static let red = Color(red: 1.0, green: 0.22, blue: 0.26)

    private var speed: Double { t.airSpeed > 0.5 ? t.airSpeed : t.groundSpeed }
    private var ekfOK: Bool { (t.ekfFlags & 7) == 7 }
    private var vibe: Double { max(t.vibeX, t.vibeY, t.vibeZ) }
    private var rssiPct: Double { t.rssi > 100 ? min(100, t.rssi / 255 * 100) : max(0, t.rssi) }
    private var gpsText: String {
        switch t.gpsFix { case 0, 1: return "NO FIX"; case 2: return "2D"; case 3: return "3D"; case 4: return "DGPS"; case 5: return "RTK FLT"; default: return "RTK FIX" }
    }
    private var homeDist: Double? {
        guard t.homeSet, t.gpsFix >= 3 else { return nil }
        let la = (t.lat - t.homeLat) * 111_320, lo = (t.lon - t.homeLon) * 111_320 * cos(t.homeLat * .pi / 180)
        return (la * la + lo * lo).squareRoot()
    }

    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            let u = max(0.6, min(1.5, min(w / 1000, h / 560))) * CGFloat(config.scale)
            let ink = config.theme.ink, dim = ink.opacity(0.55), red = config.theme.accent
            let main = ink                                   // основний колір ліній і тексту
            if !config.videoBackground { ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black)) }

            func T(_ s: String, _ size: CGFloat, _ c: Color, _ wt: Font.Weight = .medium) -> Text {
                Text(LocalizedStringKey(s)).font(.system(size: size * u, weight: wt, design: .monospaced)).foregroundColor(c)
            }
            func line(_ a: CGPoint, _ b: CGPoint, _ c: Color, _ lw: CGFloat = 1.3) {
                var p = Path(); p.move(to: a); p.addLine(to: b); ctx.stroke(p, with: .color(c), lineWidth: lw * min(u, 1.2))
            }

            // --- Кутові рамки ---
            let m = 18 * u, armX = w * 0.28, armY = h * 0.17
            for (cx, sx) in [(m, CGFloat(1)), (w - m, CGFloat(-1))] {
                for (cy, sy) in [(m, CGFloat(1)), (h - m, CGFloat(-1))] {
                    line(CGPoint(x: cx, y: cy), CGPoint(x: cx + sx * armX, y: cy), dim)
                    line(CGPoint(x: cx, y: cy), CGPoint(x: cx, y: cy + sy * armY), dim)
                }
            }

            // --- Драбини швидкості (ліворуч) і висоти (праворуч) ---
            func ladder(x: CGFloat, value: Double, visible: Double, minor: Double, major: Double, left: Bool, title: String, readout: String, key: String) {
                guard show(key) else { return }
                let top = h * 0.27, bottom = h * 0.66, mid = (top + bottom) / 2
                let ppu = (bottom - top) / visible
                line(CGPoint(x: x, y: top), CGPoint(x: x, y: bottom), dim)
                var v = (value - visible / 2 / 1).rounded(.down)
                v = (v / minor).rounded(.down) * minor
                while v <= value + visible / 2 {
                    let y = mid - CGFloat(v - value) * ppu
                    if y >= top, y <= bottom, abs(y - mid) > 30 * u {
                        let isMajor = v.truncatingRemainder(dividingBy: major) == 0
                        let a = 1.0 - 0.65 * Double(abs(y - mid) / ((bottom - top) / 2))
                        let len: CGFloat = (isMajor ? 10 : 5) * u
                        line(CGPoint(x: x, y: y), CGPoint(x: x + (left ? len : -len), y: y), main.opacity(a))
                        if isMajor {
                            ctx.draw(T(String(Int(v.rounded())), 12, main.opacity(a), .semibold), at: CGPoint(x: x + (left ? -12 : 12) * u, y: y), anchor: left ? .trailing : .leading)
                        }
                    }
                    v += minor
                }
                // вікно поточного значення (шестикутник зі стрілкою назовні)
                let bw: CGFloat = 96 * u, bh: CGFloat = 44 * u, tip: CGFloat = 14 * u
                let xl = left ? x - 62 * u : x - 34 * u
                let xr = xl + bw
                var p = Path()
                if left {
                    p.move(to: CGPoint(x: xl + tip, y: mid - bh / 2)); p.addLine(to: CGPoint(x: xr, y: mid - bh / 2)); p.addLine(to: CGPoint(x: xr, y: mid + bh / 2))
                    p.addLine(to: CGPoint(x: xl + tip, y: mid + bh / 2)); p.addLine(to: CGPoint(x: xl, y: mid)); p.closeSubpath()
                } else {
                    p.move(to: CGPoint(x: xl, y: mid - bh / 2)); p.addLine(to: CGPoint(x: xr - tip, y: mid - bh / 2)); p.addLine(to: CGPoint(x: xr, y: mid))
                    p.addLine(to: CGPoint(x: xr - tip, y: mid + bh / 2)); p.addLine(to: CGPoint(x: xl, y: mid + bh / 2)); p.closeSubpath()
                }
                ctx.fill(p, with: .color(.black.opacity(config.videoBackground ? 0.55 : 1)))
                ctx.stroke(p, with: .color(main), lineWidth: 1.8 * min(u, 1.2))
                ctx.draw(T(readout, 22, .white, .bold), at: CGPoint(x: (xl + xr) / 2 + (left ? tip / 2 : -tip / 2), y: mid), anchor: .center)
                ctx.draw(T(title, 11, dim, .semibold), at: CGPoint(x: (xl + xr) / 2, y: mid - bh / 2 - 10 * u), anchor: .center)
            }
            ladder(x: w * 0.135, value: Units.speedValue(speed), visible: 60, minor: 5, major: 20, left: true, title: "SPD", readout: Units.speedNum(speed, digits: 0), key: "speed")
            ladder(x: w * 0.865, value: Units.altValue(t.altRel), visible: 120, minor: 10, major: 50, left: false, title: "ALT", readout: Units.altNum(t.altRel), key: "alt")
            if show("alt") {
                // вертикальна швидкість під вікном висоти
                ctx.draw(T(String(format: "VS %+.1f", t.climb), 12, t.climb < -3 ? red : main), at: CGPoint(x: w * 0.865 + 14 * u, y: (h * 0.27 + h * 0.66) / 2 + 40 * u), anchor: .center)
            }

            // --- Дуга компаса зверху ---
            if show("compass") {
                let c = CGPoint(x: w / 2, y: h * 0.22), R = h * 0.15
                let hd = t.heading
                let k = 1.5                                         // градуси дуги на градус курсу
                var arc = Path()
                var a = -68.0
                while a <= 68.0 { let rad = a * .pi / 180; let pt = CGPoint(x: c.x + R * CGFloat(sin(rad)), y: c.y - R * CGFloat(cos(rad))); if a == -68 { arc.move(to: pt) } else { arc.addLine(to: pt) }; a += 2 }
                ctx.stroke(arc, with: .color(main), lineWidth: 1.5 * min(u, 1.2))
                var d = ((hd - 68 / k) / 5).rounded(.down) * 5
                while d <= hd + 68 / k {
                    let ang = (d - hd) * k * .pi / 180
                    let isMajor = Int(d.rounded()) % 15 == 0 || (Int(d.rounded()) % 360 + 360) % 90 == 0
                    let r1 = R, r2 = R + (isMajor ? 9 : 5) * u
                    line(CGPoint(x: c.x + r1 * CGFloat(sin(ang)), y: c.y - r1 * CGFloat(cos(ang))), CGPoint(x: c.x + r2 * CGFloat(sin(ang)), y: c.y - r2 * CGFloat(cos(ang))), main)
                    if isMajor {
                        let dn = (Int(d.rounded()) % 360 + 360) % 360
                        let lbl = [0: "N", 90: "E", 180: "S", 270: "W"][dn] ?? String(dn)
                        let rl = R + 22 * u
                        ctx.draw(T(lbl, 12, main, .semibold), at: CGPoint(x: c.x + rl * CGFloat(sin(ang)), y: c.y - rl * CGFloat(cos(ang))), anchor: .center)
                    }
                    d += 5
                }
                line(CGPoint(x: w * 0.30, y: c.y), CGPoint(x: w * 0.70, y: c.y), main, 1.4)
                // червона мітка курсу зверху й біла стрілка на основі
                var rt = Path(); rt.move(to: CGPoint(x: c.x - 7 * u, y: c.y - R - 36 * u)); rt.addLine(to: CGPoint(x: c.x + 7 * u, y: c.y - R - 36 * u)); rt.addLine(to: CGPoint(x: c.x, y: c.y - R - 24 * u)); rt.closeSubpath()
                ctx.fill(rt, with: .color(red))
                var wt = Path(); wt.move(to: CGPoint(x: c.x, y: c.y + 4 * u)); wt.addLine(to: CGPoint(x: c.x - 8 * u, y: c.y + 17 * u)); wt.addLine(to: CGPoint(x: c.x + 8 * u, y: c.y + 17 * u)); wt.closeSubpath()
                ctx.fill(wt, with: .color(.white))
                ctx.draw(T(String(format: "%03.0f°", (hd.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)), 13, .white, .bold), at: CGPoint(x: c.x, y: c.y + 30 * u), anchor: .center)
            }

            // --- Приціл і драбина тангажа ---
            let cc = CGPoint(x: w / 2, y: h * 0.50)
            if show("pitch") {
                var l = ctx
                l.translateBy(x: cc.x, y: cc.y)
                l.rotate(by: .degrees(-t.roll))
                let ppd = h / 64
                for d in stride(from: -30, through: 30, by: 10) {
                    let y = CGFloat(t.pitch - Double(d)) * ppd
                    if abs(y) > h * 0.24 { continue }
                    let fade = 1.0 - 0.7 * Double(abs(y) / (h * 0.24))
                    let col = main.opacity(max(0.25, fade) * (d == 0 ? 1.0 : 0.85))
                    let inner = 38 * u, outer = (d == 0 ? 150 : 92) * u
                    func seg(_ a: CGFloat, _ b: CGFloat) { var p = Path(); p.move(to: CGPoint(x: a, y: y)); p.addLine(to: CGPoint(x: b, y: y)); l.stroke(p, with: .color(col), lineWidth: 1.4 * min(u, 1.2)) }
                    seg(-outer, -inner); seg(inner, outer)
                    if d % 10 == 0 && d != 0 {
                        l.draw(T(String(abs(d)), 11, col, .semibold), at: CGPoint(x: -outer - 14 * u, y: y), anchor: .center)
                        l.draw(T(String(abs(d)), 11, col, .semibold), at: CGPoint(x: outer + 14 * u, y: y), anchor: .center)
                    }
                }
            }
            line(CGPoint(x: cc.x - 34 * u, y: cc.y), CGPoint(x: cc.x - 8 * u, y: cc.y), .white, 1.8)
            line(CGPoint(x: cc.x + 8 * u, y: cc.y), CGPoint(x: cc.x + 34 * u, y: cc.y), .white, 1.8)
            line(CGPoint(x: cc.x, y: cc.y - 34 * u), CGPoint(x: cc.x, y: cc.y - 8 * u), .white, 1.8)
            line(CGPoint(x: cc.x, y: cc.y + 8 * u), CGPoint(x: cc.x, y: cc.y + 34 * u), .white, 1.8)
            ctx.fill(Path(ellipseIn: CGRect(x: cc.x - 2.5 * u, y: cc.y - 2.5 * u, width: 5 * u, height: 5 * u)), with: .color(red))

            // --- Текстові блоки «КЛЮЧ : значення» (показники OSD) ---
            func block(_ rows: [(String, String, Color?)], x: CGFloat, y0: CGFloat, right: Bool) {
                let kw = rows.map { $0.0.count }.max() ?? 0
                for (i, r) in rows.enumerated() {
                    let y = y0 + CGFloat(i) * 24 * u
                    let key = right ? r.0 : r.0.padding(toLength: kw, withPad: " ", startingAt: 0)
                    let txt = T(key, 13, dim, .medium) + T(" : ", 13, dim, .medium) + T(r.1, 13, r.2 ?? main, .semibold)
                    ctx.draw(txt, at: CGPoint(x: x, y: y), anchor: right ? .trailing : .leading)
                }
            }
            let lowBatt = t.batteryPct > 0 && t.batteryPct < 20
            var tl: [(String, String, Color?)] = []
            if show("mode") { tl.append(("MODE", (t.mode ?? "—").uppercased(), nil)) }
            if show("status") { tl.append(("ARMED", t.armed ? "YES" : "NO", t.armed ? red : nil)) }
            if show("battery") {
                tl.append(("BATT", String(format: "%.1f V  %.1f A", t.batteryV, t.batteryA), lowBatt ? red : nil))
            }
            if show("gps") { tl.append(("SATS", "\(t.sats)  \(gpsText)", t.gpsFix >= 3 ? nil : red)) }
            block(tl, x: w * 0.045, y0: h * 0.115, right: false)

            var tr: [(String, String, Color?)] = []
            if show("status") { tr.append(("STATUS", t.armed ? "ARMED" : "DISARMED", t.armed ? red : nil)) }
            tr.append(("EKF", ekfOK ? "OK" : "CHECK", ekfOK ? nil : red))
            if show("wp") { tr.append(("WP", t.wpDist > 0 ? Units.dist(t.wpDist, en: true).uppercased() : "—", nil)) }
            block(tr, x: w * 0.955, y0: h * 0.115, right: true)
            if t.recording { ctx.draw(T("REC", 13, red, .bold), at: CGPoint(x: w * 0.955, y: h * 0.115 + CGFloat(tr.count) * 24 * u), anchor: .trailing) }

            var bl: [(String, String, Color?)] = []
            let nominal = ekfOK && vibe < 30
            bl.append(("SYS DIAG", nominal ? "NOMINAL" : "CHECK", nominal ? nil : red))
            if show("battery") { bl.append(("POWER", "\(max(0, t.batteryPct))%", lowBatt ? red : nil)) }
            bl.append(("THR", String(format: "%.0f%%", t.throttle), nil))
            bl.append(("VIBE", String(format: "%.1f", vibe), vibe >= 30 ? red : nil))
            block(bl, x: w * 0.045, y0: h * 0.80 - CGFloat(bl.count - 1) * 24 * u, right: false)

            var br: [(String, String, Color?)] = []
            let ns = t.lat >= 0 ? "N" : "S", ew = t.lon >= 0 ? "E" : "W"
            br.append(("LAT", String(format: "%.4f %@", abs(t.lat), ns), nil))
            br.append(("LON", String(format: "%.4f %@", abs(t.lon), ew), nil))
            br.append(("HOME", homeDist.map { Units.dist($0, en: true).uppercased() } ?? "—", nil))
            let y0 = h * 0.80 - CGFloat(br.count) * 24 * u
            block(br, x: w * 0.955, y0: y0, right: true)
            // шкала сигналу (RSSI) п'ять стовпчиків
            let sy = y0 + CGFloat(br.count) * 24 * u
            ctx.draw(T("SIG", 13, dim, .medium) + T(" : ", 13, dim, .medium), at: CGPoint(x: w * 0.955 - 66 * u, y: sy), anchor: .trailing)
            let bars = Int((rssiPct / 20).rounded(.up))
            for i in 0..<5 {
                let bh = CGFloat(5 + i * 4) * u
                let r = CGRect(x: w * 0.955 - 60 * u + CGFloat(i) * 12 * u, y: sy + 8 * u - bh, width: 8 * u, height: bh)
                ctx.fill(Path(r), with: .color(i < bars ? main : dim.opacity(0.4)))
            }

            // --- Критичні повідомлення знизу по центру ---
            let crit = alerts.suffix(2)
            for (i, al) in crit.enumerated() {
                ctx.draw(T(al.text.uppercased(), 12, al.sev <= 3 ? red : .orange, .semibold), at: CGPoint(x: w / 2, y: h - 38 * u - CGFloat(i) * 20 * u), anchor: .center)
            }
        }
    }
}
