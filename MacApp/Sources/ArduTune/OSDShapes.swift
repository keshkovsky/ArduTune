import Foundation

/// Вміст елемента OSD у клітинках шрифту: nil = порожня клітинка (прозора), інакше код символу шрифту.
struct OSDShape {
    var cells: [[UInt8?]]
    var dx = 0, dy = 0              // зсув лівого верхнього кута габариту відносно (X, Y); центровані елементи мають від'ємні значення
    var mspOnly = false             // малює лише MSP OSD (окуляри), внутрішній рендерер ArduPilot його ігнорує
    var w: Int { cells.map(\.count).max() ?? 1 }
    var h: Int { cells.count }

    init(cells: [[UInt8?]], dx: Int = 0, dy: Int = 0) { self.cells = cells; self.dx = dx; self.dy = dy }
    /// Звичайний текст (ASCII): символи шрифту стоять на своїх ASCII-кодах.
    init(rows: [String], dx: Int = 0, dy: Int = 0) { self.init(cells: rows.map { OSDShapes.ascii($0) }, dx: dx, dy: dy) }
}

/// Форма й вміст елементів за вихідним кодом AP_OSD_Screen.cpp (Copter-4.6.3, шрифт і символи MAX7456).
enum OSDShapes {
    /// Елементи, які внутрішній рендерер ArduPilot (MAX7456, DisplayPort) не малює (опис параметра: «MSP OSD only»).
    static let mspOnly: Set<String> = ["CRSSHAIR", "HOMEDIST", "HOMEDIR", "POWER", "CELLVOLT", "BATTBAR", "ARMING"]

    /// Налаштування, від яких залежить вигляд (з параметрів польотника): OSD_UNITS, OSD_SB_V_EXT, OSD_SB_H_OFS.
    nonisolated(unsafe) static var units = 0
    nonisolated(unsafe) static var sidebarVExt = 0
    nonisolated(unsafe) static var sidebarHOffset = 0

    static func ascii(_ s: String) -> [UInt8?] {
        s.unicodeScalars.map { $0.value == 32 ? nil : ($0.value < 256 ? UInt8($0.value) : 0x3F) }
    }

    /// Рядок клітинок: UInt8 = код символу, String = ASCII-текст.
    private static func R(_ parts: Any...) -> [UInt8?] {
        var out: [UInt8?] = []
        for p in parts {
            if let c = p as? UInt8 { out.append(c) } else if let s = p as? String { out += ascii(s) }
        }
        return out
    }
    private static func f(_ fmt: String, _ v: Double) -> String { String(format: fmt, v) }
    private static func d(_ fmt: String, _ v: Int) -> String { String(format: fmt, v) }

    /// Стрілка напряму за кутом (get_arrow_font_index): 16 секторів, перший код 0x60.
    private static func arrow(_ deg: Double) -> UInt8 {
        let cd = Int((deg.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) * 100)
        return OSDSym.arrowStart + UInt8(((cd + 1125) / 2250) % 16)
    }

    static func shape(_ k: String) -> OSDShape {
        let u = units
        func ic(_ kind: OSDUnitKind) -> UInt8 { OSDUnits.icon(u, kind) }
        func sc(_ kind: OSDUnitKind, _ v: Double) -> Double { OSDUnits.scale(u, kind, v) }
        /// draw_distance
        func dist(_ meters: Double) -> [UInt8?] {
            var icon = ic(.distance), v = sc(.distance, meters), fmt = "%4.0f"
            if v > 9999 {
                v = sc(.distanceLong, meters); icon = ic(.distanceLong)
                fmt = v < 9 ? "%1.3f" : (v < 99 ? "%2.2f" : (v < 999 ? "%3.1f" : "%4.0f"))
            } else if v < 10 { fmt = "% 3.1f" }
            return R(f(fmt, v), icon)
        }
        /// draw_speed: стрілка + значення
        func speed(_ ms: Double, angle: Double = 0) -> [UInt8?] {
            let v = sc(.speed, ms)
            return v < 9.95 ? R(arrow(angle), " ", f("%1.1f", v), ic(.speed)) : R(arrow(angle), d("%3d", Int(v.rounded())), ic(.speed))
        }
        let battSym = OSDSym.battFull + 1     // 75 % залишку: p = (100 − 75) / 16.6 = 1

        if mspOnly.contains(k) {
            var s: OSDShape
            switch k {
            case "CRSSHAIR": s = OSDShape(cells: [R(OSDSym.ahCenterLeft, OSDSym.ahCenter, OSDSym.ahCenterRight)], dx: -1)
            case "HOMEDIST": s = OSDShape(cells: [dist(350)])
            case "HOMEDIR": s = OSDShape(cells: [R(arrow(45))])
            case "POWER": s = OSDShape(rows: ["186W"])
            case "CELLVOLT": s = OSDShape(cells: [R("3.76", OSDSym.volt)])
            case "BATTBAR": s = OSDShape(cells: [R(OSDSym.battFull, OSDSym.battFull + 1, OSDSym.battFull + 2, OSDSym.battFull + 3, OSDSym.battFull + 4)])
            default: s = OSDShape(rows: ["ARMED"])
            }
            s.mspOnly = true; return s
        }
        switch k {
        case "ALTITUDE": return OSDShape(cells: [R(d("%4d", Int(sc(.altitude, 120))), ic(.altitude))])
        case "BAT_VOLT": return OSDShape(cells: [R(battSym, f("%2.1f", 15.1), OSDSym.volt)])
        case "BAT2_VLT": return OSDShape(cells: [R(battSym, f("%2.1f", 15.0), OSDSym.volt)])
        case "RESTVOLT": return OSDShape(cells: [R(battSym, f("%2.1f", 15.8), OSDSym.volt)])
        case "AVGCELLV", "ACRVOLT": return OSDShape(cells: [R(battSym, f("%1.2f", 3.78), OSDSym.volt)])
        case "RSSI": return OSDShape(cells: [R(OSDSym.rssi, d("%2d", 92))])
        case "LINK_Q": return OSDShape(cells: [R(OSDSym.lq, d("%2d", 98))])
        case "CURRENT", "CURRENT2": return OSDShape(cells: [R(f("%2.1f", 12.3), OSDSym.amp)])
        case "BATUSED", "BAT2USED": return OSDShape(cells: [R(d("%4d", 850), OSDSym.mah)])
        case "SATS": return OSDShape(cells: [R(OSDSym.satL, OSDSym.satR, d("%2u", 14))])
        case "FLTMODE": return OSDShape(cells: [R("STAB", OSDSym.armed)])
        case "MESSAGE": return OSDShape(cells: [ascii("ARMED: READY TO FLY".padding(toLength: 26, withPad: " ", startingAt: 0))])
        case "GSPEED": return OSDShape(cells: [R(OSDSym.gspd) + speed(17)])
        case "WIND": return OSDShape(cells: [R(OSDSym.wspd) + speed(6, angle: 45)])
        case "ASPEED", "ASPD1", "ASPD2": return OSDShape(cells: [R(OSDSym.aspd, d("%4d", Int(sc(.speed, 18))), ic(.speed))])
        case "VSPEED":
            let v = sc(.vspeed, 1.2)
            if u != 3 && v < 9.95 { return OSDShape(cells: [R(OSDSym.up, f("%.1f", v), ic(.vspeed))]) }
            return OSDShape(cells: [R(OSDSym.up, d(u == 3 ? "%4d" : "%2d", Int(v.rounded())), ic(.vspeed))])
        case "THROTTLE": return OSDShape(cells: [R(d("%3d", 55), OSDSym.pcnt)])
        case "HEADING": return OSDShape(cells: [R(d("%3d", 120), OSDSym.degr)])
        case "HOME": return OSDShape(cells: [R(OSDSym.home, arrow(45)) + dist(350)])
        case "COMPASS":                                                                // 9 символів, X = центр
            return OSDShape(cells: [(-4...4).map { OSDSym.compassCircle[($0 + 16) % 16] }], dx: -4)
        case "HORIZON":                                                                // 9×9 навколо центра (X, Y); при нульових крені й тангажі лінія в середньому рядку
            var rows = [[UInt8?]](repeating: [UInt8?](repeating: nil, count: 9), count: 9)
            rows[4] = [UInt8?](repeating: OSDSym.ahHStart + 4, count: 9)
            rows[4][3] = OSDSym.ahCenterLeft; rows[4][4] = OSDSym.ahCenter; rows[4][5] = OSDSym.ahCenterRight
            return OSDShape(cells: rows, dx: -4, dy: -4)
        case "GPSLAT": return OSDShape(cells: [R(OSDSym.gpsLat, d("%4d", 50), ".", "4501000")])
        case "GPSLONG": return OSDShape(cells: [R(OSDSym.gpsLong, d("%4d", 30), ".", "5234000")])
        case "ROLL": return OSDShape(cells: [R(OSDSym.rollR, d("%3d", 12), OSDSym.degr)])
        case "PITCH": return OSDShape(cells: [R(OSDSym.ptchUp, d("%3d", 4), OSDSym.degr)])
        case "TEMP", "ATEMP", "BTEMP", "ESCTEMP": return OSDShape(cells: [R(d("%3d", Int(sc(.temperature, 34))), ic(.temperature))])
        case "HDOP": return OSDShape(cells: [R(OSDSym.hdopL, OSDSym.hdopR, f("%3.2f", 0.9))])
        case "WAYPOINT": return OSDShape(cells: [R(OSDSym.wpno, d("%2u", 3), arrow(0)) + dist(420)])
        case "XTRACK": return OSDShape(cells: [R(OSDSym.xerr) + dist(4)])
        case "DIST": return OSDShape(cells: [R(OSDSym.dist) + dist(4200)])
        case "STATS":
            return OSDShape(cells: [
                [nil, nil, 0x4D, 0x41, 0x58],
                R(OSDSym.gspd, d("%4d", Int(sc(.speed, 25))), ic(.speed)),
                R(f("%5.1f", 18.4), OSDSym.amp),
                R(d("%5d", Int(sc(.altitude, 120))), ic(.altitude)),
                R(OSDSym.home) + dist(350),
                R(OSDSym.dist) + dist(4200),
            ])
        case "FLTIME": return OSDShape(cells: [R(OSDSym.fly, d("%3u", 12), ":", d("%02u", 40))])
        case "CLK": return OSDShape(cells: [R(OSDSym.clk, d("%02u", 14), ":", d("%02u", 25))])
        case "EFF": return OSDShape(cells: [R(OSDSym.eff, d("%3d", Int(1000 * 12.3 / sc(.speed, 17))), OSDSym.mah)])
        case "CLIMBEFF": return OSDShape(cells: [R(OSDSym.ptchUp, OSDSym.eff, f("%3.1f", 3.6 * sc(.vspeed, 1.2) / 12.3), ic(.distance))])
        case "ESCRPM": return OSDShape(cells: [R(f("%.2f", 5.4), OSDSym.kilo, OSDSym.rpm)])
        case "ESCAMPS": return OSDShape(cells: [R(f("%4.1f", 12.3), OSDSym.amp)])
        case "RPM": return OSDShape(cells: [R(d("%4d", 5400), OSDSym.rpm)])
        case "TER_HGT": return OSDShape(cells: [R(d("%4d", Int(sc(.altitude, 85))), ic(.altitude), OSDSym.terAlt)])
        case "RNGF": return OSDShape(cells: [R(OSDSym.rngfd, f("%4.1f", sc(.distance, 3.4)), ic(.distance))])
        case "FENCE": return OSDShape(cells: [R(OSDSym.fenceOn)])
        case "VTX_PWR": return OSDShape(cells: [R(d("%4d", 200), OSDSym.mw)])
        case "CALLSIGN": return OSDShape(rows: ["UAV-01"])
        case "PLUSCODE": return OSDShape(rows: ["8GWR+PF4+QQ"])
        case "RC_PWR": return OSDShape(cells: [R(d("%3d", 100), OSDSym.mw)])
        case "RSSIDBM": return OSDShape(cells: [R(OSDSym.rssi, d("%4d", -90), OSDSym.dbm)])
        case "RC_SNR": return OSDShape(cells: [R(OSDSym.snr, d("%3d", 12), OSDSym.db)])
        case "RC_ANT": return OSDShape(cells: [R(OSDSym.ant, "1")])
        case "RC_LQ": return OSDShape(cells: [R(OSDSym.lq, d("%2d", 99))])
        case "SIDEBARS":                                                                // ліва шкала швидкості (x…x+4) й права висоти (x+16+зсув), 7 + 2·OSD_SB_V_EXT рядків
            let barH = 7 + sidebarVExt * 2, mid = barH / 2
            let sp = sc(.speed, 18), al = sc(.altitude, 120)
            let altInterval = (u == 1 || u == 3) ? 20.0 : 10.0
            var si = Int(fmod(sp, 10) / 10 * 18)
            var ai = Int(fmod(fmod(al, altInterval) + altInterval, altInterval) / altInterval * 18)
            let hoff = max(0, sidebarHOffset)
            var rows: [[UInt8?]] = []
            for i in 0..<barH {
                var row = [UInt8?](repeating: nil, count: 22 + hoff)
                if i == mid {
                    for (j, c) in R(d("%3d", Int(sp)), ic(.speed), OSDSym.sbRArrow).enumerated() { row[j] = c }
                    for (j, c) in R(OSDSym.sbLArrow, String(Int(al)), ic(.altitude)).enumerated() where 16 + hoff + j < row.count { row[16 + hoff + j] = c }
                } else {
                    row[4] = OSDSym.sidebarSectors[si]; row[16 + hoff] = OSDSym.sidebarSectors[ai]
                }
                si = (si + 12) % 18; ai = (ai + 12) % 18
                rows.append(row)
            }
            return OSDShape(cells: rows)
        default: return OSDShape(rows: [OSDInfo.sample(k).uppercased()])
        }
    }
}
