import AppKit

/// Азимути борту за різними джерелами: компас (магнітометр), GPS (курс над землею), гіроскоп (курс AHRS/ATTITUDE).
struct RayData: Equatable {
    var compass: Double?
    var gps: Double?
    var gyro: Double?
    var isEmpty: Bool { compass == nil && gps == nil && gyro == nil }

    static func current(yaw: Double, magHdg: Double?, cog: Double?, speed: Double, rays: Bool) -> RayData? {
        guard rays else { return nil }
        func norm(_ a: Double) -> Double { var x = a.truncatingRemainder(dividingBy: 360); if x < 0 { x += 360 }; return x }
        var r = RayData()
        if let m = magHdg, m >= 0 { r.compass = norm(m) }
        if let c = cog, c >= 0, speed > 1.0 { r.gps = norm(c) }            // на місці курс GPS недостовірний
        r.gyro = norm(yaw)
        return r.isEmpty ? nil : r
    }
}

/// Мінімалістичні промені від борту: тонкі лінії приглушених кольорів із маленьким підписом азимута.
enum HeadingRays {
    static let size: CGFloat = 220
    static let colors: [NSColor] = [
        NSColor(calibratedRed: 0.28, green: 0.62, blue: 0.62, alpha: 0.85),   // компас: приглушений бірюзовий
        NSColor(calibratedRed: 0.78, green: 0.55, blue: 0.25, alpha: 0.85),   // GPS: приглушений бурштиновий
        NSColor(calibratedRed: 0.58, green: 0.45, blue: 0.75, alpha: 0.85),   // гіроскоп: приглушений фіолетовий
    ]

    static func image(_ r: RayData, mapHeading: Double) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size))
        img.lockFocus()
        defer { img.unlockFocus() }
        let c = CGPoint(x: size / 2, y: size / 2)
        let items: [(Double?, NSColor)] = [(r.compass, colors[0]), (r.gps, colors[1]), (r.gyro, colors[2])]
        let font = NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .medium)
        for (i, it) in items.enumerated() {
            guard let az = it.0 else { continue }
            let a = (az - mapHeading) * .pi / 180
            let dx = CGFloat(sin(a)), dy = CGFloat(cos(a))
            let p0 = CGPoint(x: c.x + dx * 19, y: c.y + dy * 19), p1 = CGPoint(x: c.x + dx * 66, y: c.y + dy * 66)
            let path = NSBezierPath()
            path.move(to: p0); path.line(to: p1); path.lineWidth = 1.1; path.lineCapStyle = .round
            it.1.setStroke(); path.stroke()
            let tick = NSBezierPath(); tick.lineWidth = 1.1
            tick.move(to: CGPoint(x: p1.x - dy * 3, y: p1.y + dx * 3)); tick.line(to: CGPoint(x: p1.x + dy * 3, y: p1.y - dx * 3)); tick.stroke()
            let label = "\(Int(az.rounded()) % 360)°" as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: it.1]
            let sz = label.size(withAttributes: attrs)
            let rad: CGFloat = 82 + CGFloat(i) * 7         // підписи на різній відстані, щоб менше перекривались
            label.draw(at: CGPoint(x: c.x + dx * rad - sz.width / 2, y: c.y + dy * rad - sz.height / 2), withAttributes: attrs)
        }
        return img
    }
}
