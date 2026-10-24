import SwiftUI
import AppKit

// Шрифти й символи екранного меню ArduPilot (MAX7456): шрифт 12×18 пікселів, 2 біти на піксель, 256 символів.
// Файли font0…font4.bin взято з ArduPilot (libraries/AP_OSD/fonts, GPLv3); номер шрифту задає параметр OSD_FONT.

/// Коди символів стандартної таблиці MAX7456 (AP_OSD_Backend.h).
enum OSDSym {
    static let m: UInt8 = 0xB9, km: UInt8 = 0xBA, ft: UInt8 = 0x0F, mi: UInt8 = 0xBB, altM: UInt8 = 0xB1, altFt: UInt8 = 0xB3
    static let battFull: UInt8 = 0x90, rssi: UInt8 = 0x01, volt: UInt8 = 0x06, amp: UInt8 = 0x9A, mah: UInt8 = 0x07
    static let ms: UInt8 = 0x9F, fs: UInt8 = 0x99, kmh: UInt8 = 0xA1, mph: UInt8 = 0xB0, degr: UInt8 = 0xA8, pcnt: UInt8 = 0x25
    static let rpm: UInt8 = 0xE0, aspd: UInt8 = 0xE1, gspd: UInt8 = 0xE2, wspd: UInt8 = 0xE3, wpno: UInt8 = 0xE5, ftmin: UInt8 = 0xE8
    static let satL: UInt8 = 0x1E, satR: UInt8 = 0x1F, hdopL: UInt8 = 0xBD, hdopR: UInt8 = 0xBE, home: UInt8 = 0xBF
    static let arrowStart: UInt8 = 0x60, ahHStart: UInt8 = 0x80, ahCenterLeft: UInt8 = 0x26, ahCenterRight: UInt8 = 0x27, ahCenter: UInt8 = 0x7E
    static let headingN: UInt8 = 0x18, headingS: UInt8 = 0x19, headingE: UInt8 = 0x1A, headingW: UInt8 = 0x1B, headingDivided: UInt8 = 0x1C, headingLine: UInt8 = 0x1D
    static let upUp: UInt8 = 0xA2, up: UInt8 = 0xA3, down: UInt8 = 0xA4, downDown: UInt8 = 0xA5
    static let degC: UInt8 = 0x0E, degF: UInt8 = 0x0D, gpsLat: UInt8 = 0xA6, gpsLong: UInt8 = 0xA7, armed: UInt8 = 0x00, disarmed: UInt8 = 0xE9
    static let roll0: UInt8 = 0x2D, rollR: UInt8 = 0xEA, rollL: UInt8 = 0xEB, ptch0: UInt8 = 0x7C, ptchUp: UInt8 = 0xEC, ptchDwn: UInt8 = 0xED
    static let xerr: UInt8 = 0xEE, kn: UInt8 = 0xF0, nm: UInt8 = 0xF1, dist: UInt8 = 0x22, fly: UInt8 = 0x9C, eff: UInt8 = 0xF2, ah: UInt8 = 0xF3
    static let mw: UInt8 = 0xF4, clk: UInt8 = 0xBC, kilo: UInt8 = 0x4B, terAlt: UInt8 = 0xEF, fenceOn: UInt8 = 0xF5, fenceOff: UInt8 = 0xF6
    static let rngfd: UInt8 = 0xF7, lq: UInt8 = 0xF8, watt: UInt8 = 0xAE, wh: UInt8 = 0xAB, db: UInt8 = 0xF9, dbm: UInt8 = 0xFA, snr: UInt8 = 0xFB, ant: UInt8 = 0xFC
    static let sbRArrow: UInt8 = 0x09, sbLArrow: UInt8 = 0x0A
    static let sidebarSectors: [UInt8] = [0x13, 0x14, 0x15, 0xDD, 0xDB, 0xDC, 0xDA, 0xDB, 0xDC, 0xDA, 0xDB, 0xDC, 0xDA, 0xDB, 0xDC, 0xDE, 0x11, 0x12]
    static let compassCircle: [UInt8] = [headingN, headingLine, headingDivided, headingLine, headingE, headingLine, headingDivided, headingLine,
                                         headingS, headingLine, headingDivided, headingLine, headingW, headingLine, headingDivided, headingLine]
}

/// Завантаження шрифтів і малювання символів.
enum OSDFontLib {
    private static var cache: [Int: [CGImage?]] = [:]

    private static func fileData(_ font: Int) -> Data? {
        let name = "font\(font)"
        if let u = Bundle.main.url(forResource: name, withExtension: "bin", subdirectory: "osdfonts"), let d = try? Data(contentsOf: u) { return d }
        let dev = URL(fileURLWithPath: NSHomeDirectory() + "/Developer/ArduTune/MacApp/Resources/osdfonts/\(name).bin")
        return try? Data(contentsOf: dev)
    }

    /// 256 зображень символів 12×18: чорний контур, білий відбиток, прозорий фон.
    static func glyphs(_ font: Int) -> [CGImage?] {
        let f = min(max(font, 0), 4)
        if let c = cache[f] { return c }
        var out = [CGImage?](repeating: nil, count: 256)
        if let d = fileData(f), d.count >= 256 * 54 {
            let cs = CGColorSpaceCreateDeviceRGB()
            for ch in 0..<256 {
                var px = [UInt8](repeating: 0, count: 12 * 18 * 4)
                for i in 0..<216 {
                    let byte = d[ch * 54 + i / 4]
                    let v = (byte >> UInt8(6 - 2 * (i % 4))) & 3
                    let o = i * 4
                    switch v {
                    case 0: px[o] = 0; px[o + 1] = 0; px[o + 2] = 0; px[o + 3] = 255          // чорний
                    case 2: px[o] = 255; px[o + 1] = 255; px[o + 2] = 255; px[o + 3] = 255    // білий
                    default: break                                                          // прозорий
                    }
                }
                let provider = CGDataProvider(data: Data(px) as CFData)!
                out[ch] = CGImage(width: 12, height: 18, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 48, space: cs,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
                                  decode: nil, shouldInterpolate: false, intent: .defaultIntent)
            }
        }
        cache[f] = out
        return out
    }
}

/// Одиниці виміру OSD (параметр OSD_UNITS: 0 метричні, 1 імперські, 2 SI, 3 авіаційні): таблиці з AP_OSD_Screen.cpp.
enum OSDUnitKind: Int { case altitude, speed, vspeed, distance, distanceLong, temperature }

enum OSDUnits {
    static func icon(_ units: Int, _ k: OSDUnitKind) -> UInt8 {
        let t: [[UInt8]] = [
            [OSDSym.altM, OSDSym.kmh, OSDSym.ms, OSDSym.m, OSDSym.km, OSDSym.degC],
            [OSDSym.altFt, OSDSym.mph, OSDSym.fs, OSDSym.ft, OSDSym.mi, OSDSym.degF],
            [OSDSym.altM, OSDSym.ms, OSDSym.ms, OSDSym.m, OSDSym.km, OSDSym.degC],
            [OSDSym.altFt, OSDSym.kn, OSDSym.ftmin, OSDSym.ft, OSDSym.nm, OSDSym.degC],
        ]
        return t[min(max(units, 0), 3)][k.rawValue]
    }
    static func scale(_ units: Int, _ k: OSDUnitKind, _ v: Double) -> Double {
        let s: [[Double]] = [
            [1, 3.6, 1, 1, 1.0 / 1000, 1],
            [3.28084, 2.23694, 3.28084, 3.28084, 1.0 / 1609.34, 1.8],
            [1, 1, 1, 1, 1.0 / 1000, 1],
            [3.28084, 1.94384, 196.85, 3.28084, 0.000539957, 1],
        ]
        let u = min(max(units, 0), 3)
        return v * s[u][k.rawValue] + (u == 1 && k == .temperature ? 32 : 0)
    }
}
