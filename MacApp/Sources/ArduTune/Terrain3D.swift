import Foundation
import AppKit
import MapKit

/// Дані рельєфу для 3D-сцени: сітка висот над рівнем моря й мозаїка супутникових плиток для текстури.
struct Terrain3D {
    var lat0 = 0.0, lon0 = 0.0                 // центр
    var latMin = 0.0, latMax = 0.0, lonMin = 0.0, lonMax = 0.0
    var n = 40                                  // клітинок по стороні (вершин n + 1)
    var elev: [Double] = []                     // (n+1)² значень: рядок 0 = північ, стовпець 0 = захід
    var texture: NSImage?
    var tileBounds = (x0: 0.0, y0: 0.0, w: 1.0, h: 1.0)   // межі мозаїки в тайловому просторі
    var tileZoom = 0
    var ok = true                               // false: висоти недоступні (плоска сцена)

    var base: Double { elev.min() ?? 0 }
    var widthM: Double { (lonMax - lonMin) * cos(lat0 * .pi / 180) * 111_320 }
    var heightM: Double { (latMax - latMin) * 111_320 }
    var extent: Double { max(widthM, heightM) }

    /// Локальні метри: x на схід, z на південь (північ = −z).
    func local(lat: Double, lon: Double) -> (Double, Double) {
        ((lon - lon0) * cos(lat0 * .pi / 180) * 111_320, -(lat - lat0) * 111_320)
    }
    /// Висота рельєфу в точці (білінійна інтерполяція), м над рівнем моря.
    func elevation(lat: Double, lon: Double) -> Double {
        guard !elev.isEmpty, latMax > latMin, lonMax > lonMin else { return 0 }
        let fy = min(max((latMax - lat) / (latMax - latMin), 0), 1) * Double(n)
        let fx = min(max((lon - lonMin) / (lonMax - lonMin), 0), 1) * Double(n)
        let x0 = min(Int(fx), n - 1), y0 = min(Int(fy), n - 1)
        let tx = fx - Double(x0), ty = fy - Double(y0)
        func e(_ x: Int, _ y: Int) -> Double { elev[y * (n + 1) + x] }
        return (e(x0, y0) * (1 - tx) + e(x0 + 1, y0) * tx) * (1 - ty) + (e(x0, y0 + 1) * (1 - tx) + e(x0 + 1, y0 + 1) * tx) * ty
    }

    // MARK: Web Mercator
    static func tileX(_ lon: Double, _ z: Int) -> Double { (lon + 180) / 360 * pow(2, Double(z)) }
    static func tileY(_ lat: Double, _ z: Int) -> Double {
        let r = lat * .pi / 180
        return (1 - log(tan(r) + 1 / cos(r)) / .pi) / 2 * pow(2, Double(z))
    }

    /// Збирає рельєф і текстуру для області. `progress` викликається з текстом стану.
    static func build(minLat: Double, maxLat: Double, minLon: Double, maxLon: Double, layer: MapLayer, progress: @escaping @Sendable (String) -> Void) async -> Terrain3D {
        var t = Terrain3D()
        // область: запас 25%, не менше ~1,6 км, не більше ~300 км (маршрут має вміщатися повністю)
        let cl = (minLat + maxLat) / 2, co = (minLon + maxLon) / 2
        let cosL = max(0.2, cos(cl * .pi / 180))
        var halfLat = max((maxLat - minLat) / 2 * 1.25, 800 / 111_320.0)
        var halfLon = max((maxLon - minLon) / 2 * 1.25, 800 / (111_320.0 * cosL))
        halfLat = min(halfLat, 150_000 / 111_320.0); halfLon = min(halfLon, 150_000 / (111_320.0 * cosL))
        // квадратна область у метрах
        let halfM = max(halfLat * 111_320, halfLon * 111_320 * cosL)
        halfLat = halfM / 111_320; halfLon = halfM / (111_320 * cosL)
        t.lat0 = cl; t.lon0 = co
        t.latMin = cl - halfLat; t.latMax = cl + halfLat; t.lonMin = co - halfLon; t.lonMax = co + halfLon
        let big = halfM > 30_000
        t.n = big ? 110 : 72
        let side = t.n + 1
        // сітка вершин
        var pts: [(Double, Double)] = []
        for r in 0..<side { for c in 0..<side {
            pts.append((t.latMax - (t.latMax - t.latMin) * Double(r) / Double(t.n), t.lonMin + (t.lonMax - t.lonMin) * Double(c) / Double(t.n)))
        } }
        // висоти: тайли Terrarium (AWS Terrain Tiles, без ключа й лімітів), до 4×4 плиток; Rб·256 + G + B/256 − 32768
        progress("Рельєф: завантаження висот…")
        var ze = 13
        func erange(_ z: Int) -> (Int, Int, Int, Int) { (Int(tileX(t.lonMin, z)), Int(tileX(t.lonMax, z)), Int(tileY(t.latMax, z)), Int(tileY(t.latMin, z))) }
        while ze > 5 { let r = erange(ze); if r.1 - r.0 + 1 <= (big ? 6 : 4) && r.3 - r.2 + 1 <= (big ? 6 : 4) { break }; ze -= 1 }
        let (ex0, ex1, ey0, ey1) = erange(ze)
        let enx = ex1 - ex0 + 1, eny = ey1 - ey0 + 1
        var mosaic = [Float](repeating: 0, count: enx * 256 * eny * 256)
        var failed = false
        let tiles = await withTaskGroup(of: (Int, Int, Data?).self) { group -> [(Int, Int, Data?)] in
            for ty in ey0...ey1 { for tx in ex0...ex1 {
                group.addTask {
                    var req = URLRequest(url: URL(string: "https://s3.amazonaws.com/elevation-tiles-prod/terrarium/\(ze)/\(tx)/\(ty).png")!)
                    req.timeoutInterval = 20
                    let d = try? await URLSession.shared.data(for: req).0
                    return (tx, ty, d)
                }
            } }
            var out: [(Int, Int, Data?)] = []
            for await r in group { out.append(r) }
            return out
        }
        for (tx, ty, d) in tiles {
            guard let d, let rep = NSBitmapImageRep(data: d), let px = rep.bitmapData, rep.pixelsWide == 256 else { failed = true; continue }
            let spp = max(3, rep.bitsPerPixel / 8), bpr = rep.bytesPerRow
            for y in 0..<256 { for x in 0..<256 {
                let o = y * bpr + x * spp
                let e = Float(px[o]) * 256 + Float(px[o + 1]) + Float(px[o + 2]) / 256 - 32768
                mosaic[((ty - ey0) * 256 + y) * (enx * 256) + (tx - ex0) * 256 + x] = e
            } }
        }
        t.ok = !failed
        let mw = enx * 256, mh = eny * 256
        t.elev = pts.map { p in
            let fx = min(max((tileX(p.1, ze) - Double(ex0)) * 256, 0), Double(mw - 1)), fy = min(max((tileY(p.0, ze) - Double(ey0)) * 256, 0), Double(mh - 1))
            let x0 = Int(fx), y0 = Int(fy), x1 = min(x0 + 1, mw - 1), y1 = min(y0 + 1, mh - 1)
            let ax = fx - Double(x0), ay = fy - Double(y0)
            func m(_ x: Int, _ y: Int) -> Double { Double(mosaic[y * mw + x]) }
            return (m(x0, y0) * (1 - ax) + m(x1, y0) * ax) * (1 - ay) + (m(x0, y1) * (1 - ax) + m(x1, y1) * ax) * ay
        }
        // текстура: мозаїка плиток, не більше 5×5
        progress("Текстура: завантаження плиток…")
        var z = 18
        func range(_ z: Int) -> (Int, Int, Int, Int) {
            (Int(tileX(t.lonMin, z)), Int(tileX(t.lonMax, z)), Int(tileY(t.latMax, z)), Int(tileY(t.latMin, z)))
        }
        while z > 6 { let r = range(z); if r.1 - r.0 + 1 <= (big ? 8 : 5) && r.3 - r.2 + 1 <= (big ? 8 : 5) { break }; z -= 1 }
        let layerTiles = layer.isTiles ? layer : .googleSat
        let overlay = TileOverlay(layer: layerTiles)
        let (x0, x1, y0, y1) = range(z)
        let nx = x1 - x0 + 1, ny = y1 - y0 + 1
        t.tileZoom = z
        t.tileBounds = (Double(x0), Double(y0), Double(nx), Double(ny))
        let size = 256
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: nx * size, pixelsHigh: ny * size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let datas = await withTaskGroup(of: (Int, Int, Data?).self) { group -> [(Int, Int, Data?)] in
            for ty in y0...y1 { for tx in x0...x1 {
                group.addTask {
                    await withCheckedContinuation { cont in
                        overlay.loadTile(at: MKTileOverlayPath(x: tx, y: ty, z: z, contentScaleFactor: 1)) { d, _ in cont.resume(returning: (tx, ty, d)) }
                    }
                }
            } }
            var out: [(Int, Int, Data?)] = []
            for await r in group { out.append(r) }
            return out
        }
        NSGraphicsContext.saveGraphicsState()
        if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.current = ctx
            NSColor(white: 0.18, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: nx * size, height: ny * size).fill()
            for (tx, ty, d) in datas {
                guard let d, let img = NSImage(data: d) else { continue }
                // зображення малюємо зверху вниз: ряд 0 мозаїки = верх
                let rect = NSRect(x: (tx - x0) * size, y: (ny - 1 - (ty - y0)) * size, width: size, height: size)
                img.draw(in: rect)
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        let img = NSImage(size: NSSize(width: nx * size, height: ny * size)); img.addRepresentation(rep)
        t.texture = img
        progress("")
        return t
    }
}
