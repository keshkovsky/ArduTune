import Foundation

// MARK: - Кінематична симуляція польоту по місії (без фізики прошивки і вітру)

struct SimItem {
    var cmd: Int, frame: Int
    var p1 = 0.0, p2 = 0.0, p3 = 0.0, p4 = 0.0
    var lat = 0.0, lon = 0.0, alt = 0.0
    var hasPos: Bool { !(lat == 0 && lon == 0) }
}

struct SimParams {
    var plane = false
    var cruise = 5.0          // м/с
    var climb = 2.5           // м/с
    var descent = 1.5         // м/с
    var bank = 35.0           // ° (лише літак)
    var homeAlt = 0.0         // для абсолютних висот
    var homeLat = 0.0, homeLon = 0.0
    var windSpeed = 0.0       // м/с
    var windFrom = 0.0        // ° (звідки дме)
}

struct SimSample { var t: Double, x: Double, y: Double, alt: Double, hdg: Double, spd: Double, item: Int, dist = 0.0, air = 0.0, cr = 0.0 }   // spd = швидкість по землі, air = повітряна, cr = крейсерська (з DO_CHANGE_SPEED)

/// Команда оператора під час симуляції (з контекстного меню або панелі керування).
enum SimCommand {
    case auto(from: Int)                                   // виконувати місію з пункту (індекс)
    case goTo(lat: Double, lon: Double, alt: Double, loiter: Bool)
    case loiterHere
    case rtl
    case landHere
    case straight            // FBWA/Cruise без пілота: політ прямо на поточній висоті й курсі
}
struct SimEvent: Identifiable { let id = UUID(); var t: Double, item: Int, text: String }
struct SimResult {
    var samples: [SimSample] = []
    var events: [SimEvent] = []
    var notes: [String] = []
    var distance = 0.0, maxAlt = 0.0, maxSpeed = 0.0
    var duration: Double { samples.last?.t ?? 0 }
    var finished = true
}

enum MissionSimEngine {
    static let mPerDeg = 111_320.0

    static func local(lat: Double, lon: Double, p: SimParams) -> (Double, Double) {
        ((lon - p.homeLon) * cos(p.homeLat * .pi / 180) * mPerDeg, (lat - p.homeLat) * mPerDeg)
    }
    static func geo(x: Double, y: Double, p: SimParams) -> (Double, Double) {
        (p.homeLat + y / mPerDeg, p.homeLon + x / (mPerDeg * max(0.01, cos(p.homeLat * .pi / 180))))
    }

    static func run(_ items: [SimItem], _ p: SimParams) -> SimResult {
        let s = Sim(items: items, p: p)
        s.execute()
        return s.r
    }

    /// Продовжує симуляцію з моменту `state` за командою оператора; усе, що було після цього моменту, відкидається.
    static func resume(_ prefix: SimResult, at state: SimSample, items: [SimItem], _ p: SimParams, _ c: SimCommand) -> SimResult {
        let s = Sim(items: items, p: p, prefix: prefix, state: state)
        s.command(c)
        return s.r
    }

    private static func wrap(_ a: Double) -> Double {
        var x = a.truncatingRemainder(dividingBy: 2 * .pi)
        if x > .pi { x -= 2 * .pi } else if x < -.pi { x += 2 * .pi }
        return x
    }

    private final class Sim {
        let items: [SimItem]
        let p: SimParams
        var r = SimResult()
        var t = 0.0, x = 0.0, y = 0.0, alt = 0.0, hdg = 0.0
        var vx = 0.0, vy = 0.0          // Copter
        var spd = 0.0                    // Plane
        var cruise: Double
        var item = -1
        var stop = false
        var steps = 0
        let dt = 0.25
        let tmax = 3 * 3600.0
        var lastRec = -1.0

        init(items: [SimItem], p: SimParams) { self.items = items; self.p = p; cruise = p.cruise }

        init(items: [SimItem], p: SimParams, prefix: SimResult, state s: SimSample) {
            self.items = items; self.p = p; cruise = p.cruise
            r.samples = prefix.samples.filter { $0.t < s.t - 1e-6 } + [s]
            r.events = prefix.events.filter { $0.t <= s.t }
            r.distance = s.dist; r.maxAlt = r.samples.map(\.alt).max() ?? 0; r.maxSpeed = r.samples.map(\.spd).max() ?? 0
            t = s.t; x = s.x; y = s.y; alt = s.alt; hdg = s.hdg; item = s.item; lastRec = s.t
            if s.cr > 0 { cruise = s.cr }
            if p.plane { spd = s.air > 0 ? s.air : s.spd } else { vx = s.spd * sin(s.hdg); vy = s.spd * cos(s.hdg) }
        }

        // MARK: Допоміжне
        func tAlt(_ it: SimItem) -> Double { it.frame == 0 ? it.alt - p.homeAlt : it.alt }
        func pos(_ it: SimItem) -> (Double, Double) { MissionSimEngine.local(lat: it.lat, lon: it.lon, p: p) }
        /// Вектор вітру (куди дме), м/с; діє лише на літак у повітрі.
        var wind: (Double, Double) {
            guard p.plane, p.windSpeed > 0, alt > 0.5 else { return (0, 0) }
            let a = (p.windFrom + 180) * .pi / 180
            return (p.windSpeed * sin(a), p.windSpeed * cos(a))
        }
        var groundSpeed: Double {
            if !p.plane { return (vx * vx + vy * vy).squareRoot() }
            let w = wind
            return ((sin(hdg) * spd + w.0) * (sin(hdg) * spd + w.0) + (cos(hdg) * spd + w.1) * (cos(hdg) * spd + w.1)).squareRoot()
        }
        func event(_ text: String) { r.events.append(SimEvent(t: t, item: item, text: text)) }
        func note(_ s: String) { if !r.notes.contains(s) { r.notes.append(s) } }
        var bad: Bool { stop || t >= tmax || steps > 400_000 }

        func record(force: Bool = false) {
            if force || t - lastRec >= 0.5 - 1e-9 {
                lastRec = t
                r.samples.append(SimSample(t: t, x: x, y: y, alt: alt, hdg: hdg, spd: groundSpeed, item: item, dist: r.distance, air: p.plane ? spd : groundSpeed, cr: cruise))
                r.maxAlt = max(r.maxAlt, alt); r.maxSpeed = max(r.maxSpeed, groundSpeed)
            }
        }

        func moveAlt(to target: Double, up: Double? = nil, down: Double? = nil) {
            let d = target - alt
            let step = d > 0 ? (up ?? p.climb) * dt : (down ?? p.descent) * dt
            alt += max(-step, min(step, d)); if alt < 0 { alt = 0 }
        }

        func finishStep(dx: Double, dy: Double) {
            r.distance += (dx * dx + dy * dy).squareRoot()
            t += dt; steps += 1
            record()
        }

        // MARK: Кінематика
        /// Крок Copter до точки. `cap` — обмеження швидкості (для зупинки в точці).
        func copterStep(tx: Double, ty: Double, talt: Double, cap: Double? = nil, down: Double? = nil) {
            let dx = tx - x, dy = ty - y, d = (dx * dx + dy * dy).squareRoot()
            var want = cruise
            if let cap { want = min(want, cap) }
            let a = 2.5
            do {
                let dvx = (d > 0.01 ? dx / d * want : 0) - vx, dvy = (d > 0.01 ? dy / d * want : 0) - vy
                let m = (dvx * dvx + dvy * dvy).squareRoot(), lim = a * dt
                if m > lim { vx += dvx / m * lim; vy += dvy / m * lim } else { vx += dvx; vy += dvy }
            }
            let sp = (vx * vx + vy * vy).squareRoot()
            if sp > 0.5 { hdg = atan2(vx, vy) }
            x += vx * dt; y += vy * dt
            moveAlt(to: talt, up: nil, down: down)
            finishStep(dx: vx * dt, dy: vy * dt)
        }

        func planeStep(desired: Double, talt: Double?, speedTarget: Double? = nil) {
            let target = speedTarget ?? cruise
            spd += max(-2 * dt, min(3 * dt, target - spd))
            let bank = min(max(p.bank, 10), 60) * .pi / 180
            let w = 9.81 * tan(bank) / max(spd, 8)
            let diff = MissionSimEngine.wrap(desired - hdg)
            hdg = MissionSimEngine.wrap(hdg + max(-w * dt, min(w * dt, diff)))
            let wv = wind
            let dx = (sin(hdg) * spd + wv.0) * dt, dy = (cos(hdg) * spd + wv.1) * dt
            x += dx; y += dy
            if let talt { moveAlt(to: talt) }
            finishStep(dx: dx, dy: dy)
        }

        // MARK: Навігація до точки
        /// Повертає true, коли точку досягнуто.
        @discardableResult
        func goTo(_ tx: Double, _ ty: Double, alt talt: Double, radius: Double, stopAt: Bool, needAlt: Bool = true) -> Bool {
            if p.plane {
                var dmin = Double.greatestFiniteMagnitude
                let d0 = hypot(tx - x, ty - y)
                while !bad {
                    let d = hypot(tx - x, ty - y)
                    dmin = min(dmin, d)
                    // «пройшли повз» лише якщо до цього справді наближались (не під час початкового розвороту)
                    let closed = d0 < radius * 2 || d0 - dmin > radius * 0.5
                    if d < radius || (closed && dmin < radius * 2.5 && d > dmin + radius * 0.5) { return true }
                    planeStep(desired: atan2(tx - x, ty - y), talt: talt)
                }
                return false
            }
            let a = 2.5
            while !bad {
                let d = hypot(tx - x, ty - y)
                let altOK = !needAlt || abs(alt - talt) < 2.5
                if d < (stopAt ? 1.5 : radius) && altOK && (!stopAt || groundSpeed < 1.0) { return true }
                let cap = stopAt ? max(0.3, (2 * a * max(d - 0.5, 0)).squareRoot()) : nil
                copterStep(tx: tx, ty: ty, talt: talt, cap: cap)
            }
            return false
        }

        func hold(_ seconds: Double) {
            var left = seconds
            while left > 0 && !bad {
                if p.plane { planeStep(desired: hdg, talt: nil) } else { copterStep(tx: x, ty: y, talt: alt, cap: 0) }
                left -= dt
            }
        }

        /// Кружляння навколо центра. `until` — умова виходу (викликається щокроку).
        func orbit(cx: Double, cy: Double, radius: Double, cw: Bool, talt: Double, until: (_ turned: Double, _ elapsed: Double) -> Bool) {
            // вихід на коло
            let reach = p.plane ? max(radius * 1.3, 60) : max(radius, 2)
            if !p.plane {
                // найближча точка кола
                let ang = atan2(x - cx, y - cy)
                let ex = cx + sin(ang) * radius, ey = cy + cos(ang) * radius
                goTo(ex, ey, alt: talt, radius: 2, stopAt: false)
                var phi = atan2(x - cx, y - cy); var turned = 0.0, el = 0.0
                let w = min(cruise, 3.0) / max(radius, 1) * (cw ? 1 : -1)
                while !bad && !until(turned, el) {
                    phi += w * dt; turned += abs(w * dt); el += dt
                    let nx = cx + sin(phi) * radius, ny = cy + cos(phi) * radius
                    let dx = nx - x, dy = ny - y
                    vx = dx / dt; vy = dy / dt; hdg = atan2(vx, vy)
                    x = nx; y = ny; moveAlt(to: talt)
                    finishStep(dx: dx, dy: dy)
                }
                vx = 0; vy = 0
                return
            }
            goTo(cx, cy, alt: talt, radius: reach, stopAt: false)
            var prev = atan2(x - cx, y - cy); var turned = 0.0, el = 0.0
            let dir = cw ? 1.0 : -1.0
            while !bad && !until(turned, el) {
                let rx = x - cx, ry = y - cy, d = hypot(rx, ry)
                let th = atan2(rx, ry)
                let corr = max(-1, min(1, (d - radius) / max(radius, 1))) * .pi / 3
                planeStep(desired: th + dir * (.pi / 2 + corr), talt: talt)
                let nth = atan2(x - cx, y - cy)
                if d < radius * 1.5 { turned += abs(MissionSimEngine.wrap(nth - prev)); el += dt }
                prev = nth
            }
        }

        // MARK: Виконання
        func execute() {
            guard !items.isEmpty else { r.notes.append("План порожній"); return }
            hdg = 0
            record(force: true)
            runProgram(from: 0)
        }

        var onGround: Bool { alt < 1 && groundSpeed < 1 }

        func command(_ c: SimCommand) {
            switch c {
            case .auto(let k):
                runProgram(from: max(0, min(k, items.count - 1)))
            case .goTo(let lat, let lon, let a, let loiter):
                if onGround && p.plane { note("Літак на землі: спершу зліт у режимі Auto"); record(force: true); return }
                let (tx, ty) = MissionSimEngine.local(lat: lat, lon: lon, p: p)
                event(loiter ? "Команда: лети до точки й зависни" : "Команда: лети до точки (Guided)")
                goTo(tx, ty, alt: a, radius: p.plane ? 60 : 1.5, stopAt: !p.plane)
                if !bad { event("У точці: утримання позиції"); holdForever(cx: tx, cy: ty, alt: a) }
            case .loiterHere:
                if onGround && p.plane { note("Літак на землі: спершу зліт у режимі Auto"); record(force: true); return }
                event("Команда: Loiter на місці"); holdForever(cx: nil, cy: nil, alt: alt)
            case .rtl:
                if onGround { note("Апарат на землі"); record(force: true); return }
                event("Команда: RTL"); doRTL()
            case .straight:
                if onGround { note("Апарат на землі: спершу зліт у режимі Auto"); record(force: true); return }
                event("Команда: FBWA, політ прямо на поточній висоті")
                if p.plane {
                    let hd = hdg, a = alt
                    var left = 120.0
                    while left > 0 && !bad { planeStep(desired: hd, talt: a); left -= dt }
                    if !bad { note("Режим FBWA без пілота: політ прямо; щоб продовжити, оберіть Auto чи іншу команду") }
                } else { holdForever(cx: nil, cy: nil, alt: alt) }
            case .landHere:
                if onGround { note("Апарат на землі"); record(force: true); return }
                event("Команда: посадка")
                if p.plane { doLand(0, 0) } else { doLand(x, y) }
            }
            record(force: true)
        }

        /// Утримання позиції: Copter висить, Plane кружляє (на місці — по колу праворуч від курсу). Далі потрібна нова команда.
        func holdForever(cx: Double?, cy: Double?, alt a: Double) {
            let dur = 90.0
            if p.plane {
                let rad = 80.0
                let c = (cx ?? x + cos(hdg) * rad, cy ?? y - sin(hdg) * rad)
                orbit(cx: c.0, cy: c.1, radius: rad, cw: true, talt: a) { _, el in el >= dur }
            } else { hold(dur) }
            if !bad { note("Утримання позиції: щоб продовжити місію, натисніть «Старт» (Auto) або оберіть іншу команду") }
        }

        func doRTL() {
            if p.plane {
                goTo(0, 0, alt: max(alt, 60), radius: 80, stopAt: false)
                if !bad { event("Над Home: літак кружляє до ручного керування"); note("RTL у Plane завершується кружлянням над Home (посадка лише при DO_LAND_START/RTL_AUTOLAND)"); stop = true }
            } else {
                let ra = max(alt, 15)
                goTo(0, 0, alt: ra, radius: 1.5, stopAt: true)
                while !bad && alt > 0.05 { copterStep(tx: 0, ty: 0, talt: 0, cap: 0, down: alt > 8 ? p.descent : 1.0) }
                if !bad { event("Приземлення"); stop = true }
            }
        }

        func doLand(_ tx: Double, _ ty: Double) {
            if p.plane {
                let grad = min(0.1, p.descent / max(cruise, 1))
                if alt > 40 {          // забагато висоти для заходу: знижуємось колом над точкою посадки
                    orbit(cx: tx, cy: ty, radius: 150, cw: true, talt: 25) { _, _ in self.alt <= 30 }
                }
                var dmin = Double.greatestFiniteMagnitude
                let d0 = hypot(tx - x, ty - y)
                while !bad {
                    let d = hypot(tx - x, ty - y); dmin = min(dmin, d)
                    let closed = d0 < 150 || d0 - dmin > 60
                    if d < 25 || (closed && d > dmin + 15 && dmin < 120) { break }
                    planeStep(desired: atan2(tx - x, ty - y), talt: min(alt, max(0, d * grad)))
                }
                while !bad && alt > 0.2 { planeStep(desired: hdg, talt: 0) }
                while !bad && spd > 0.5 { planeStep(desired: hdg, talt: 0, speedTarget: 0) }
            } else {
                goTo(tx, ty, alt: alt, radius: 1.5, stopAt: true, needAlt: false)
                while !bad && alt > 0.05 { copterStep(tx: x, ty: y, talt: 0, cap: 0, down: alt > 8 ? p.descent : 1.0) }
            }
            if !bad { event("Приземлення"); stop = true }
        }

        func runProgram(from start: Int) {
            var pc = start
            var jumpLeft: [Int: Int] = [:]
            var iter = 0
            while pc < items.count && !bad && iter < 100_000 {
                iter += 1
                let it = items[pc]
                item = pc
                var next = pc + 1
                let alt0 = tAlt(it)
                let label = "#\(pc + 1)"
                switch it.cmd {
                case 22, 84:
                    event(String(localized: "Зліт \(loc(label))"))
                    if p.plane {
                        if it.hasPos { let (tx, ty) = pos(it); hdg = atan2(tx - x, ty - y) } else if it.p4 != 0 { hdg = it.p4 * .pi / 180 }
                        let (tx, ty) = it.hasPos ? pos(it) : (x + sin(hdg) * 2000, y + cos(hdg) * 2000)
                        spd = 0
                        // розбіг
                        while !bad && spd < cruise * 0.75 { planeStep(desired: hdg, talt: 0) }
                        while !bad && alt < alt0 - 1 { planeStep(desired: atan2(tx - x, ty - y), talt: alt0) }
                    } else {
                        while !bad && alt < alt0 - 0.5 { copterStep(tx: x, ty: y, talt: alt0, cap: 0) }
                        if it.hasPos { let (tx, ty) = pos(it); goTo(tx, ty, alt: alt0, radius: 2, stopAt: true) }
                    }
                case 16, 82:
                    let (tx, ty) = it.hasPos ? pos(it) : (x, y)
                    let last = !items[(pc + 1)...].contains { ($0.cmd == 16 || $0.cmd == 82 || $0.cmd == 21 || $0.cmd == 22 || [17, 18, 19, 31].contains($0.cmd)) && $0.hasPos || $0.cmd == 20 }
                    let delay = p.plane ? 0 : max(it.p1, 0)
                    let rad = p.plane ? max(it.p2, 60) : max(it.p2, 3)
                    goTo(tx, ty, alt: alt0, radius: rad, stopAt: !p.plane && (delay > 0 || last))
                    if !bad { event(String(localized: "Досягнуто точку \(loc(label))")) }
                    if delay > 0 { hold(delay) }
                case 17, 18, 19, 31:
                    let (cx, cy) = it.hasPos ? pos(it) : (x, y)
                    let rad = max(abs(it.p3 == 0 ? 80 : it.p3), p.plane ? 20 : 5)
                    let cw = it.p3 >= 0
                    event(String(localized: "Кружляння \(loc(label))"))
                    if it.cmd == 17 {
                        orbit(cx: cx, cy: cy, radius: rad, cw: cw, talt: alt0) { turned, _ in turned >= 2 * .pi * 2 }
                        if !bad { note(String(localized: "Кружляння без обмеження (#\(pc + 1)): у польоті місія далі не йде; симуляцію зупинено після 2 кіл")); stop = true }
                    } else if it.cmd == 18 {
                        let n = max(it.p1, 1)
                        orbit(cx: cx, cy: cy, radius: rad, cw: cw, talt: alt0) { turned, _ in turned >= 2 * .pi * n }
                    } else if it.cmd == 19 {
                        if p.plane || it.p3 != 0 { orbit(cx: cx, cy: cy, radius: rad, cw: cw, talt: alt0) { _, el in el >= it.p1 } }
                        else { goTo(cx, cy, alt: alt0, radius: 2, stopAt: true); hold(it.p1) }
                    } else {
                        orbit(cx: cx, cy: cy, radius: rad, cw: cw, talt: alt0) { _, _ in abs(self.alt - alt0) < 2 }
                    }
                case 21, 85:
                    let (tx, ty) = it.hasPos ? pos(it) : (x, y)
                    event(String(localized: "Посадка \(loc(label))"))
                    doLand(tx, ty)
                case 20:
                    event(String(localized: "Повернення (RTL) \(loc(label))"))
                    doRTL()
                case 177:
                    let target = Int(it.p1) - 1
                    let rep = Int(it.p2)
                    var left = jumpLeft[pc] ?? rep
                    if rep < 0 || left > 0, target >= 0, target < items.count {
                        if rep >= 0 { left -= 1 }
                        jumpLeft[pc] = left
                        next = target
                        event(String(localized: "Перехід на #\(target + 1)"))
                    } else { jumpLeft[pc] = nil }
                case 178:
                    if it.p2 > 0 { cruise = it.p2; event(String(localized: "Швидкість \(Int(it.p2)) м/с")) }
                case 93:
                    if !p.plane && it.p1 > 0 { hold(it.p1) }
                default: break
                }
                pc = next
            }
            record(force: true)
            if t >= tmax || steps > 400_000 || iter >= 100_000 { r.finished = false; note("Симуляцію обмежено за часом (3 год): можливо, нескінченний цикл Jump") }
        }
    }
}
