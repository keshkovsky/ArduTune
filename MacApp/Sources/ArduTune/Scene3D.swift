import SwiftUI
import SceneKit
import AppKit

/// Вхідні дані маршруту для 3D-сцени.
struct Route3D: Equatable {
    struct WP: Equatable { var lat: Double, lon: Double, frame: Int, alt: Double, label: String, cmd: Int, icon: String, color: NSColor }
    var wps: [WP] = []
    var home: (lat: Double, lon: Double)?
    static func == (a: Route3D, b: Route3D) -> Bool { a.wps == b.wps && a.home?.lat == b.home?.lat && a.home?.lon == b.home?.lon }
}

/// Поточний стан апарата для 3D-сцени.
struct Vehicle3D: Equatable {
    var lat = 0.0, lon = 0.0
    var msl = 0.0                        // висота над рівнем моря, м
    var heading = 0.0, pitch = 0.0, roll = 0.0     // °
    var plane = false
}

/// Запит на зміну положення камери (з куба або кнопки скидання): азимут розташування камери, кут місця.
struct CameraRequest: Equatable {
    var token = 0
    var azimuth = 180.0, elevation = 35.0
    var resetDistance = false
}

enum SceneBuilder {
    static let sky = NSColor(calibratedRed: 0.09, green: 0.11, blue: 0.17, alpha: 1)

    /// Висота точки маршруту над рівнем моря за системою координат MAVLink.
    static func routeMSL(_ w: Route3D.WP, terrain: Terrain3D, homeElev: Double) -> Double {
        switch w.frame {
        case 0: return w.alt
        case 10: return terrain.elevation(lat: w.lat, lon: w.lon) + w.alt
        default: return homeElev + w.alt
        }
    }

    /// Відображувана висота Y: рельєф × vexag, а висота над землею ще й × boost, щоб політ над рельєфом виглядав виразнішим.
    static func displayY(msl: Double, ground: Double, base: Double, vexag: Double, boost: Double) -> Double {
        (ground - base) * vexag + (msl - ground) * vexag * boost
    }

    private static func cyl(_ a: SCNVector3, _ b: SCNVector3, radius: CGFloat, color: NSColor) -> SCNNode {
        let dx = b.x - a.x, dy = b.y - a.y, dz = b.z - a.z
        let len = (dx * dx + dy * dy + dz * dz).squareRoot()
        let g = SCNCylinder(radius: radius, height: max(len, 0.001))
        g.radialSegmentCount = 8
        let m = SCNMaterial(); m.diffuse.contents = color; m.lightingModel = .constant; g.materials = [m]
        let n = SCNNode(geometry: g)
        n.position = SCNVector3((a.x + b.x) / 2, (a.y + b.y) / 2, (a.z + b.z) / 2)
        n.look(at: b, up: SCNVector3(0, 1, 0), localFront: SCNVector3(0, 1, 0))
        return n
    }

    /// Маркер точки в стилі Apple: об'ємна «кнопка» кольору типу з градієнтом, бліком і тінню; усередині значок типу
    /// (зліт, посадка, коло…), у куті бейдж із номером, унизу підпис висоти над землею. Центр кружечка = центр зображення.
    static func markerImage(number: String, icon: String, color: NSColor, agl: String = "") -> NSImage {
        let S: CGFloat = 256
        let img = NSImage(size: NSSize(width: S, height: S))
        img.lockFocus()
        let rgb = color.usingColorSpace(.deviceRGB) ?? color
        let lum = 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
        let ink: NSColor = lum > 0.7 ? NSColor(white: 0.12, alpha: 1) : .white
        let R: CGFloat = 76
        let c = NSRect(x: S / 2 - R, y: S / 2 - R, width: 2 * R, height: 2 * R)
        // тінь і тіло
        NSGraphicsContext.saveGraphicsState()
        let sh = NSShadow(); sh.shadowColor = NSColor.black.withAlphaComponent(0.5); sh.shadowBlurRadius = 14; sh.shadowOffset = NSSize(width: 0, height: -7); sh.set()
        color.setFill(); NSBezierPath(ovalIn: c).fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGradient(colors: [rgb.shadow(withLevel: 0.38) ?? rgb, rgb, rgb.highlight(withLevel: 0.42) ?? rgb])?.draw(in: NSBezierPath(ovalIn: c), angle: 90)
        // м'яке світло знизу й блик зверху
        NSGradient(colors: [NSColor.white.withAlphaComponent(0.0), NSColor.white.withAlphaComponent(0.0), NSColor.white.withAlphaComponent(0.14)])?.draw(in: NSBezierPath(ovalIn: c.insetBy(dx: 10, dy: 10).offsetBy(dx: 0, dy: -6)), angle: -90)
        let gl = NSRect(x: c.minX + 16, y: c.midY + 8, width: 2 * R - 32, height: R - 14)
        NSGradient(colors: [NSColor.white.withAlphaComponent(0.55), NSColor.white.withAlphaComponent(0.04)])?.draw(in: NSBezierPath(ovalIn: gl), angle: -90)
        NSColor.white.withAlphaComponent(0.92).setStroke(); let ring = NSBezierPath(ovalIn: c.insetBy(dx: 2.5, dy: 2.5)); ring.lineWidth = 5; ring.stroke()
        NSColor.black.withAlphaComponent(0.25).setStroke(); let outer = NSBezierPath(ovalIn: c.insetBy(dx: 0.5, dy: 0.5)); outer.lineWidth = 1.5; outer.stroke()
        // значок типу точки
        func symbol(_ pt: CGFloat, _ tint: NSColor) -> NSImage? {
            guard let sym = NSImage(systemSymbolName: icon, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: pt, weight: .bold)) else { return nil }
            return NSImage(size: sym.size, flipped: false) { r in sym.draw(in: r); tint.set(); r.fill(using: .sourceAtop); return true }
        }
        if let t = symbol(number.isEmpty ? 84 : 76, ink) {
            NSGraphicsContext.saveGraphicsState()
            let isd = NSShadow(); isd.shadowColor = NSColor.black.withAlphaComponent(0.35); isd.shadowBlurRadius = 4; isd.shadowOffset = NSSize(width: 0, height: -2); isd.set()
            t.draw(in: NSRect(x: S / 2 - t.size.width / 2, y: S / 2 - t.size.height / 2, width: t.size.width, height: t.size.height))
            NSGraphicsContext.restoreGraphicsState()
        }
        // бейдж з номером у куті
        if !number.isEmpty {
            let fs: CGFloat = number.count >= 3 ? 40 : (number.count == 2 ? 50 : 58)
            let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: fs, weight: .heavy), .foregroundColor: NSColor(white: 0.08, alpha: 1)]
            let tsz = (number as NSString).size(withAttributes: a)
            let bw = max(92, tsz.width + 30), bh: CGFloat = 92
            let bc = NSRect(x: min(S - bw - 2, S / 2 + 20), y: S / 2 + 20, width: bw, height: bh)
            let bp = NSBezierPath(roundedRect: bc, xRadius: bh / 2, yRadius: bh / 2)
            NSGraphicsContext.saveGraphicsState()
            let bs = NSShadow(); bs.shadowColor = NSColor.black.withAlphaComponent(0.45); bs.shadowBlurRadius = 8; bs.shadowOffset = NSSize(width: 0, height: -4); bs.set()
            NSColor.white.setFill(); bp.fill()
            NSGraphicsContext.restoreGraphicsState()
            NSGradient(colors: [NSColor(white: 0.84, alpha: 1), NSColor(white: 1.0, alpha: 1)])?.draw(in: bp, angle: 90)
            NSColor.black.withAlphaComponent(0.18).setStroke(); bp.lineWidth = 1.5; bp.stroke()
            (number as NSString).draw(at: NSPoint(x: bc.midX - tsz.width / 2, y: bc.midY - tsz.height / 2), withAttributes: a)
        }
        // висота над землею
        if !agl.isEmpty {
            let a: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 40, weight: .bold), .foregroundColor: NSColor.white]
            let tsz = (agl as NSString).size(withAttributes: a)
            let w = tsz.width + 30, h: CGFloat = 56
            let b = NSRect(x: S / 2 - w / 2, y: 2, width: w, height: h)
            NSColor.black.withAlphaComponent(0.72).setFill(); NSBezierPath(roundedRect: b, xRadius: h / 2, yRadius: h / 2).fill()
            NSColor.white.withAlphaComponent(0.25).setStroke(); let bp = NSBezierPath(roundedRect: b.insetBy(dx: 1, dy: 1), xRadius: h / 2, yRadius: h / 2); bp.lineWidth = 2; bp.stroke()
            (agl as NSString).draw(at: NSPoint(x: b.midX - tsz.width / 2, y: b.midY - tsz.height / 2), withAttributes: a)
        }
        img.unlockFocus()
        return img
    }

    /// Стрічки сталої екранної товщини: пунктир маршруту й суцільні опори. Перебудовуються щокадру від положення камери.
    static func ribbon(_ segs: [(SCNVector3, SCNVector3)], cam: SCNVector3, width: Double, dash: Double?, gap: Double, maxQuads: Int = 4000) -> SCNGeometry? {
        var verts: [SCNVector3] = [], idx: [Int32] = []
        func quad(_ p: SCNVector3, _ q: SCNVector3, _ n: SCNVector3) {
            let i = Int32(verts.count)
            verts += [SCNVector3(p.x - n.x, p.y - n.y, p.z - n.z), SCNVector3(p.x + n.x, p.y + n.y, p.z + n.z),
                      SCNVector3(q.x + n.x, q.y + n.y, q.z + n.z), SCNVector3(q.x - n.x, q.y - n.y, q.z - n.z)]
            idx += [i, i + 1, i + 2, i, i + 2, i + 3]
        }
        for (a, b) in segs {
            let dx = Double(b.x - a.x), dy = Double(b.y - a.y), dz = Double(b.z - a.z)
            let len = (dx * dx + dy * dy + dz * dz).squareRoot()
            if len < 0.01 { continue }
            let ux = dx / len, uy = dy / len, uz = dz / len
            let mx = Double(a.x + b.x) / 2 - Double(cam.x), my = Double(a.y + b.y) / 2 - Double(cam.y), mz = Double(a.z + b.z) / 2 - Double(cam.z)
            let d = max((mx * mx + my * my + mz * mz).squareRoot(), 1)
            var nx = uy * mz - uz * my, ny = uz * mx - ux * mz, nz = ux * my - uy * mx
            let nl = (nx * nx + ny * ny + nz * nz).squareRoot()
            if nl < 1e-9 { continue }
            let w = width * d / 2 / nl
            nx *= w; ny *= w; nz *= w
            let n = SCNVector3(nx, ny, nz)
            if let dash {
                let dl = dash * d, gl = gap * d
                var t = 0.0
                var k = 0
                while t < len, k < 300, verts.count / 4 < maxQuads {
                    let e = min(t + dl, len)
                    quad(SCNVector3(Double(a.x) + ux * t, Double(a.y) + uy * t, Double(a.z) + uz * t),
                         SCNVector3(Double(a.x) + ux * e, Double(a.y) + uy * e, Double(a.z) + uz * e), n)
                    t += dl + gl; k += 1
                }
            } else { quad(a, b, n) }
        }
        guard !verts.isEmpty else { return nil }
        return SCNGeometry(sources: [SCNGeometrySource(vertices: verts)], elements: [SCNGeometryElement(indices: idx, primitiveType: .triangles)])
    }

    /// Billboard-маркер: квадрат 1×1, що завжди дивиться в камеру; розмір на екрані задає делегат (вузол «fixed»).
    static func billboardMarker(_ image: NSImage) -> SCNNode {
        let p = SCNPlane(width: 1, height: 1)
        let m = SCNMaterial(); m.diffuse.contents = image; m.lightingModel = .constant; m.isDoubleSided = true
        m.transparencyMode = .aOne; m.writesToDepthBuffer = false; m.readsFromDepthBuffer = false     // завжди видно, навіть за горою
        p.materials = [m]
        let n = SCNNode(geometry: p)
        n.name = "fixed"
        let bb = SCNBillboardConstraint(); bb.freeAxes = .all
        n.constraints = [bb]
        n.renderingOrder = 10
        return n
    }

    static func terrainNode(_ t: Terrain3D, vexag: Double) -> SCNNode {
        let side = t.n + 1
        var verts: [SCNVector3] = [], uvs: [CGPoint] = []
        verts.reserveCapacity(side * side)
        for r in 0..<side { for c in 0..<side {
            let lat = t.latMax - (t.latMax - t.latMin) * Double(r) / Double(t.n)
            let lon = t.lonMin + (t.lonMax - t.lonMin) * Double(c) / Double(t.n)
            let (x, z) = t.local(lat: lat, lon: lon)
            let y = (t.elev[r * side + c] - t.base) * vexag
            verts.append(SCNVector3(x, y, z))
            let u = (Terrain3D.tileX(lon, t.tileZoom) - t.tileBounds.x0) / t.tileBounds.w
            let v = (Terrain3D.tileY(lat, t.tileZoom) - t.tileBounds.y0) / t.tileBounds.h
            uvs.append(CGPoint(x: u, y: 1 - v))
        } }
        var idx: [Int32] = []
        for r in 0..<t.n { for c in 0..<t.n {
            let i = Int32(r * side + c)
            idx += [i, i + Int32(side), i + 1, i + 1, i + Int32(side), i + Int32(side) + 1]
        } }
        var normals = [SCNVector3](repeating: SCNVector3(0, 1, 0), count: verts.count)
        for r in 0..<side { for c in 0..<side {
            let l = verts[r * side + max(c - 1, 0)], rr = verts[r * side + min(c + 1, side - 1)]
            let u = verts[max(r - 1, 0) * side + c], d = verts[min(r + 1, side - 1) * side + c]
            let ax = rr.x - l.x, ay = rr.y - l.y, az = rr.z - l.z, bx = d.x - u.x, by = d.y - u.y, bz = d.z - u.z
            var nx = ay * bz - az * by, ny = az * bx - ax * bz, nz = ax * by - ay * bx
            let ln = (nx * nx + ny * ny + nz * nz).squareRoot()
            if ln > 0 { nx /= ln; ny /= ln; nz /= ln }
            if ny < 0 { nx = -nx; ny = -ny; nz = -nz }
            normals[r * side + c] = SCNVector3(nx, ny, nz)
        } }
        let g = SCNGeometry(sources: [SCNGeometrySource(vertices: verts), SCNGeometrySource(normals: normals), SCNGeometrySource(textureCoordinates: uvs)],
                            elements: [SCNGeometryElement(indices: idx, primitiveType: .triangles)])
        let m = SCNMaterial()
        m.diffuse.contents = t.texture ?? NSColor.darkGray
        m.lightingModel = .lambert
        m.isDoubleSided = true
        g.materials = [m]
        return SCNNode(geometry: g)
    }

    static func vehicleNode(plane: Bool, size: CGFloat) -> SCNNode {
        let root = SCNNode()
        func mat(_ c: NSColor) -> SCNMaterial { let m = SCNMaterial(); m.diffuse.contents = c; m.lightingModel = .constant; return m }
        let s = size
        if plane {
            let body = SCNCapsule(capRadius: s * 0.06, height: s * 0.9); body.materials = [mat(.white)]
            let bn = SCNNode(geometry: body); bn.eulerAngles.x = .pi / 2
            let wing = SCNBox(width: s * 1.0, height: s * 0.02, length: s * 0.18, chamferRadius: 0); wing.materials = [mat(.systemOrange)]
            let wn = SCNNode(geometry: wing); wn.position = SCNVector3(0, 0, -s * 0.05)
            let tail = SCNBox(width: s * 0.36, height: s * 0.02, length: s * 0.1, chamferRadius: 0); tail.materials = [mat(.systemOrange)]
            let tn = SCNNode(geometry: tail); tn.position = SCNVector3(0, 0, s * 0.4)
            let fin = SCNBox(width: s * 0.02, height: s * 0.18, length: s * 0.12, chamferRadius: 0); fin.materials = [mat(.systemOrange)]
            let fn = SCNNode(geometry: fin); fn.position = SCNVector3(0, s * 0.09, s * 0.4)
            let nose = SCNSphere(radius: s * 0.045); nose.materials = [mat(.systemRed)]
            let nn = SCNNode(geometry: nose); nn.position = SCNVector3(0, 0, -s * 0.46)
            [bn, wn, tn, fn, nn].forEach { root.addChildNode($0) }
        } else {
            let body = SCNBox(width: s * 0.22, height: s * 0.08, length: s * 0.22, chamferRadius: s * 0.02); body.materials = [mat(.white)]
            root.addChildNode(SCNNode(geometry: body))
            let arm1 = SCNBox(width: s * 0.9, height: s * 0.03, length: s * 0.04, chamferRadius: 0); arm1.materials = [mat(.darkGray)]
            let a1 = SCNNode(geometry: arm1); a1.eulerAngles.y = .pi / 4
            let a2 = SCNNode(geometry: arm1); a2.eulerAngles.y = -.pi / 4
            root.addChildNode(a1); root.addChildNode(a2)
            for (i, p) in [(1, 1), (1, -1), (-1, 1), (-1, -1)].enumerated() {
                let rot = SCNCylinder(radius: s * 0.17, height: s * 0.01); rot.materials = [mat(i < 2 ? .systemOrange : .systemTeal)]
                rot.materials[0].transparency = 0.6
                let rn = SCNNode(geometry: rot); rn.position = SCNVector3(CGFloat(p.0) * s * 0.32, s * 0.04, CGFloat(p.1) * s * 0.32)
                root.addChildNode(rn)
            }
            let nose = SCNSphere(radius: s * 0.04); nose.materials = [mat(.systemRed)]       // ніс уперед (−z)
            let nn = SCNNode(geometry: nose); nn.position = SCNVector3(0, 0, -s * 0.14)
            root.addChildNode(nn)
        }
        return root
    }

    /// Вміст сцени: рельєф, маршрут (труби на висоті, опори до землі, маркери типів), Home.
    @discardableResult
    static func populate(_ scene: SCNScene, terrain t: Terrain3D, route: Route3D, vexag: Double, boost: Double) -> (path: [SCNVector3], tethers: [(SCNVector3, SCNVector3)]) {
        let root = scene.rootNode
        root.childNodes.filter { $0.name == "content" }.forEach { $0.removeFromParentNode() }
        let content = SCNNode(); content.name = "content"
        content.addChildNode(terrainNode(t, vexag: vexag))
        let ext = max(t.extent, 500)
        let r = CGFloat(ext / 520)
        let homePos: (Double, Double)? = route.home.map { ($0.lat, $0.lon) } ?? route.wps.first.map { ($0.lat, $0.lon) }
        let homeElev = homePos.map { t.elevation(lat: $0.0, lon: $0.1) } ?? t.base
        func pos(_ lat: Double, _ lon: Double, msl: Double) -> SCNVector3 {
            let g = t.elevation(lat: lat, lon: lon)
            let (x, z) = t.local(lat: lat, lon: lon)
            return SCNVector3(x, displayY(msl: msl, ground: g, base: t.base, vexag: vexag, boost: boost), z)
        }
        var path: [SCNVector3] = []
        var tethers: [(SCNVector3, SCNVector3)] = []
        for w in route.wps {
            let msl = routeMSL(w, terrain: t, homeElev: homeElev)
            let p = pos(w.lat, w.lon, msl: msl)
            path.append(p)
            let gnd = pos(w.lat, w.lon, msl: t.elevation(lat: w.lat, lon: w.lon))
            tethers.append((gnd, p))
            // точка на землі під маркером
            let foot = SCNCylinder(radius: r * 1.1, height: r * 0.12)
            let fm = SCNMaterial(); fm.diffuse.contents = w.color.withAlphaComponent(0.9); fm.lightingModel = .constant; foot.materials = [fm]
            let fn = SCNNode(geometry: foot); fn.position = SCNVector3(gnd.x, gnd.y + r * 0.1, gnd.z); content.addChildNode(fn)
            // точка нижче поверхні (малий або від'ємний запас над землею): червоне попередження
            let agl = msl - t.elevation(lat: w.lat, lon: w.lon)
            let under = agl < 5
            let mk = billboardMarker(markerImage(number: w.label, icon: under ? "exclamationmark.triangle.fill" : w.icon, color: under ? .systemRed : w.color,
                                                 agl: t.ok ? String(format: loc("%.0f м"), agl) : "")); mk.position = p
            mk.geometry?.name = "wp"
            content.addChildNode(mk)
        }
        if let h = route.home {
            let hp = pos(h.lat, h.lon, msl: homeElev)
            let mk = billboardMarker(markerImage(number: "", icon: "house.fill", color: .systemGreen))
            mk.position = SCNVector3(hp.x, hp.y + r * 3, hp.z)
            content.addChildNode(mk)
        }
        root.addChildNode(content)
        return (path, tethers)
    }

    static func makeScene() -> SCNScene {
        let s = SCNScene()
        s.background.contents = sky
        let amb = SCNNode(); amb.light = SCNLight(); amb.light!.type = .ambient; amb.light!.intensity = 700
        let sun = SCNNode(); sun.light = SCNLight(); sun.light!.type = .directional; sun.light!.intensity = 900
        sun.eulerAngles = SCNVector3(-0.9, 0.7, 0)
        s.rootNode.addChildNode(amb); s.rootNode.addChildNode(sun)
        return s
    }
}

// MARK: - Орбітальна камера без перевертання

/// SCNView із власним керуванням камерою: кут місця 5…88° (перевернути догори дном неможливо), обертання ЛКМ,
/// панорама ЛКМ, обертання (ПКМ або двопальцева прокрутка) навколо точки під курсором, масштаб жестом двох пальців до точки під курсором. Положення можна зафіксувати (`locked`).
final class OrbitSCNView: SCNView {
    var azimuth = 180.0, elevation = 35.0, distance = 8000.0
    var target = SCNVector3(0, 0, 0)
    var locked = false
    var minDistance = 30.0, maxDistance = 1_200_000.0
    var onCamera: ((Double, Double, Double) -> Void)?
    let camNode = SCNNode()

    func setup(scene: SCNScene) {
        self.scene = scene
        camNode.camera = SCNCamera(); camNode.camera!.zNear = 5; camNode.camera!.zFar = 600_000; camNode.camera!.fieldOfView = 50
        scene.rootNode.addChildNode(camNode)
        pointOfView = camNode
        allowsCameraControl = false
        antialiasingMode = .multisampling4X
        backgroundColor = SceneBuilder.sky
        apply(notify: false)
    }

    func apply(notify: Bool = true) {
        elevation = min(max(elevation, 5), 88)
        distance = min(max(distance, minDistance), maxDistance)
        camNode.camera?.zNear = max(2, distance * 0.01); camNode.camera?.zFar = max(600_000, distance * 8)
        azimuth = azimuth.truncatingRemainder(dividingBy: 360); if azimuth < 0 { azimuth += 360 }
        let a = azimuth * .pi / 180, e = elevation * .pi / 180
        let d = CGFloat(distance)
        camNode.position = SCNVector3(target.x + d * CGFloat(cos(e) * sin(a)), target.y + d * CGFloat(sin(e)), target.z - d * CGFloat(cos(e) * cos(a)))
        camNode.look(at: target, up: SCNVector3(0, 1, 0), localFront: SCNVector3(0, 0, -1))
        if notify { onCamera?(azimuth, elevation, distance) }
    }

    private var pivot: (x: Double, y: Double, z: Double)?

    /// Точка на площині цілі під курсором (перетин променя з площиною y = target.y).
    private func groundPoint(_ event: NSEvent) -> (x: Double, z: Double)? {
        let loc = convert(event.locationInWindow, from: nil)
        let n = unprojectPoint(SCNVector3(loc.x, loc.y, 0)), f = unprojectPoint(SCNVector3(loc.x, loc.y, 1))
        let dy = Double(f.y - n.y)
        guard abs(dy) > 1e-6 else { return nil }
        let t = (Double(target.y) - Double(n.y)) / dy
        guard t > 0 else { return nil }
        return (Double(n.x) + Double(f.x - n.x) * t, Double(n.z) + Double(f.z - n.z) * t)
    }

    /// Жорстке обертання камери разом із ціллю навколо точки p (на площині цілі): точка лишається на екрані на місці.
    private func rotate(da: Double, dEl: Double, around p: (x: Double, y: Double, z: Double)?) {
        guard !locked else { return }
        let newEl = min(max(elevation + dEl, 5), 88)
        let de = newEl - elevation
        guard let p else { azimuth += da; elevation = newEl; apply(); return }
        var wx = Double(target.x) - p.x, wy = Double(target.y) - p.y, wz = Double(target.z) - p.z
        let th = da * .pi / 180
        (wx, wz) = (wx * cos(th) - wz * sin(th), wx * sin(th) + wz * cos(th))
        azimuth += da
        let a = azimuth * .pi / 180
        let hx = sin(a), hz = -cos(a)
        let s = wx * hx + wz * hz
        let lx = wx - s * hx, lz = wz - s * hz
        let dl = de * .pi / 180
        let s2 = s * cos(dl) - wy * sin(dl), y2 = s * sin(dl) + wy * cos(dl)
        target = SCNVector3(p.x + lx + s2 * hx, p.y + y2, p.z + lz + s2 * hz)
        elevation = newEl
        apply()
    }

    private var grab: (x: Double, z: Double)?
    private var downAt = NSPoint.zero
    private var moved = false
    /// Точка маршруту, на якій зафіксовано камеру (ЛКМ по точці); клік у будь-яке інше місце знімає фіксацію.
    var focus: SCNVector3?
    private var focusTimer: Timer?

    /// Плавне переміщення цілі камери в точку p.
    private func glide(to p: SCNVector3) {
        focusTimer?.invalidate()
        let from = target, t0 = Date(), dur = 0.45
        focusTimer = Timer.scheduledTimer(withTimeInterval: 1 / 60, repeats: true) { [weak self] tm in
            guard let self else { tm.invalidate(); return }
            let k = min(1, Date().timeIntervalSince(t0) / dur), e = CGFloat(1 - pow(1 - k, 3))
            self.target = SCNVector3(from.x + (p.x - from.x) * e, from.y + (p.y - from.y) * e, from.z + (p.z - from.z) * e)
            self.apply()
            if k >= 1 { tm.invalidate() }
        }
    }

    func clearFocus() { focus = nil; focusTimer?.invalidate(); focusTimer = nil }

    private func waypointNode(at event: NSEvent) -> SCNNode? {
        let loc = convert(event.locationInWindow, from: nil)
        let hits = hitTest(loc, options: [.searchMode: SCNHitTestSearchMode.all.rawValue, .ignoreHiddenNodes: true])
        return hits.first { $0.node.geometry?.name == "wp" }?.node
    }
    private var scrollPivot: (x: Double, y: Double, z: Double)?

    /// ЛКМ: зміщення; ПКМ: обертання. Двопальцева прокрутка без натискання теж обертає (див. scrollWheel).
    override func rightMouseDown(with e: NSEvent) { pivot = groundPoint(e).map { ($0.x, Double(target.y), $0.z) } }
    override func rightMouseUp(with e: NSEvent) { pivot = nil }
    override func rightMouseDragged(with e: NSEvent) {
        rotate(da: Double(e.deltaX) * 0.35, dEl: Double(e.deltaY) * 0.3, around: focus == nil ? pivot : nil)
    }
    override func mouseDown(with e: NSEvent) { grab = groundPoint(e); downAt = e.locationInWindow; moved = false }
    override func mouseUp(with e: NSEvent) {
        grab = nil
        guard !moved, !locked else { return }
        if let n = waypointNode(at: e) { focus = n.worldPosition; glide(to: n.worldPosition) }
        else if focus != nil { clearFocus() }
    }
    /// Перетягування: точка землі, за яку «схопили» карту, лишається під курсором (швидкість не залежить від масштабу).
    override func mouseDragged(with e: NSEvent) {
        guard !locked else { return }
        if hypot(e.locationInWindow.x - downAt.x, e.locationInWindow.y - downAt.y) > 3 { moved = true }
        if focus != nil { rotate(da: Double(e.deltaX) * 0.35, dEl: Double(e.deltaY) * 0.3, around: nil); return }
        guard let g = grab, let p = groundPoint(e) else { pan(dx: e.deltaX, dy: e.deltaY); return }
        var dx = g.x - p.x, dz = g.z - p.z
        let len = (dx * dx + dz * dz).squareRoot(), lim = distance * 3
        if len > lim { dx *= lim / len; dz *= lim / len }
        target.x += CGFloat(dx); target.z += CGFloat(dz)
        apply()
    }
    override func otherMouseDragged(with e: NSEvent) { guard !locked, focus == nil else { return }; pan(dx: e.deltaX, dy: e.deltaY) }
    func pan(dx: CGFloat, dy: CGFloat) {
        let a = azimuth * .pi / 180
        let k = distance * 0.0012
        let rx = -cos(a), rz = -sin(a), fx = -sin(a), fz = cos(a)     // «праворуч» екрана й «вперед» по землі (камера на азимуті a дивиться в бік (−sin a, cos a))
        target.x -= CGFloat((Double(dx) * rx - Double(dy) * fx) * k)
        target.z -= CGFloat((Double(dx) * rz - Double(dy) * fz) * k)
        apply()
    }
    /// Наближення до точки під курсором: точка на площині цілі лишається під вказівником.
    private func zoom(factor k: Double, at event: NSEvent) {
        let old = distance
        let nd = min(max(old * k, minDistance), maxDistance)
        let kk = nd / old
        if !locked, kk != 1, focus == nil {
            let loc = convert(event.locationInWindow, from: nil)
            let n = unprojectPoint(SCNVector3(loc.x, loc.y, 0)), f = unprojectPoint(SCNVector3(loc.x, loc.y, 1))
            let dy = f.y - n.y
            if abs(dy) > 1e-6 {
                let t = (target.y - n.y) / dy
                if t > 0 {
                    let px = n.x + (f.x - n.x) * t, pz = n.z + (f.z - n.z) * t
                    target.x = px + (target.x - px) * CGFloat(kk)
                    target.z = pz + (target.z - pz) * CGFloat(kk)
                }
            }
        }
        distance = nd
        apply()
    }
    /// Двопальцева прокрутка трекпадом без натискання обертає карту навколо точки під курсором; масштаб лише жестом (magnify).
    override func scrollWheel(with e: NSEvent) {
        guard e.hasPreciseScrollingDeltas else {      // звичайне коліщатко миші: масштаб
            zoom(factor: pow(0.88, Double(e.scrollingDeltaY == 0 ? e.deltaY : e.scrollingDeltaY)), at: e); return
        }
        // Точка обертання фіксується на початку жесту й не «пливе» за курсором.
        if focus == nil, e.phase.contains(.began) || scrollPivot == nil, let g = groundPoint(e) { scrollPivot = (g.x, Double(target.y), g.z) }
        rotate(da: Double(e.scrollingDeltaX) * 0.3, dEl: Double(e.scrollingDeltaY) * 0.25, around: focus == nil ? scrollPivot : nil)
        if e.momentumPhase.contains(.ended) || e.phase.contains(.cancelled) || (e.phase.contains(.ended) && e.momentumPhase.isEmpty) { scrollPivot = nil }
    }
    override func magnify(with e: NSEvent) { zoom(factor: 1 / (1 + Double(e.magnification) * 3), at: e) }
}

// MARK: - SwiftUI-обгортка

struct Scene3DView: NSViewRepresentable {
    let terrain: Terrain3D?
    let terrainVersion: Int
    let route: Route3D
    let vexag: Double
    let boost: Double
    var markerScale: Double = 1
    let vehicle: Vehicle3D?
    let follow: Bool
    let locked: Bool
    let request: CameraRequest
    var onCamera: (Double, Double, Double) -> Void

    final class Coord: NSObject, SCNSceneRendererDelegate {
        let scene = SceneBuilder.makeScene()
        var veh: SCNNode?
        var tether: SCNNode?
        var vehPlane: Bool?
        var sig = ""
        var lastToken = -1
        var vehSize = 100.0
        var markerScale = 1.0
        weak var view: OrbitSCNView?
        let lock = NSLock()
        var path: [SCNVector3] = []
        var tethers: [(SCNVector3, SCNVector3)] = []
        let routeNode = SCNNode(), tetherNode = SCNNode()
        override init() {
            super.init()
            func mat(_ c: NSColor) -> SCNMaterial { let m = SCNMaterial(); m.diffuse.contents = c; m.lightingModel = .constant; m.isDoubleSided = true; m.readsFromDepthBuffer = false; m.writesToDepthBuffer = false; return m }
            routeNode.name = "route"; tetherNode.name = "tether"
            routeNode.renderingOrder = 5; tetherNode.renderingOrder = 4
            routeNode.geometry = nil
            scene.rootNode.addChildNode(routeNode); scene.rootNode.addChildNode(tetherNode)
            routeMat = mat(NSColor.systemYellow.withAlphaComponent(0.95)); tetherMat = mat(NSColor.white.withAlphaComponent(0.5))
        }
        var routeMat = SCNMaterial(), tetherMat = SCNMaterial()

        /// Постійний розмір маркерів на екрані й мінімальний видимий розмір апарата.
        func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
            guard let cam = view?.camNode else { return }
            let cp = cam.worldPosition
            func dist(_ p: SCNVector3) -> CGFloat {
                let dx = p.x - cp.x, dy = p.y - cp.y, dz = p.z - cp.z
                return (dx * dx + dy * dy + dz * dz).squareRoot()
            }
            lock.lock(); let p = path, th = tethers; lock.unlock()
            var segs: [(SCNVector3, SCNVector3)] = []
            if p.count > 1 { for i in 1..<p.count { segs.append((p[i - 1], p[i])) } }
            if let g = SceneBuilder.ribbon(segs, cam: cp, width: 0.0026, dash: 0.014, gap: 0.01) { g.materials = [routeMat]; routeNode.geometry = g } else { routeNode.geometry = nil }
            if let g = SceneBuilder.ribbon(th, cam: cp, width: 0.0018, dash: nil, gap: 0) { g.materials = [tetherMat]; tetherNode.geometry = g } else { tetherNode.geometry = nil }
            scene.rootNode.enumerateChildNodes { n, _ in
                if n.name == "fixed" { let s = dist(n.worldPosition) * 0.1 * CGFloat(markerScale); n.scale = SCNVector3(s, s, s) }
            }
            if let v = veh {
                let want = dist(v.worldPosition) * 0.07
                let s = max(1, want / CGFloat(vehSize))
                v.scale = SCNVector3(s, s, s)
            }
        }
    }
    func makeCoordinator() -> Coord { Coord() }

    func makeNSView(context: Context) -> OrbitSCNView {
        let v = OrbitSCNView()
        v.setup(scene: context.coordinator.scene)
        v.delegate = context.coordinator
        v.isPlaying = true                      // делегат викликається щокадру
        context.coordinator.view = v
        return v
    }

    func updateNSView(_ v: OrbitSCNView, context: Context) {
        let c = context.coordinator
        v.onCamera = onCamera
        c.markerScale = markerScale
        v.locked = locked
        guard let t = terrain, !t.elev.isEmpty else { return }
        let key = "\(terrainVersion)|\(vexag)|\(boost)|\(route.wps.count)|\(route.wps.map { String(format: "%.5f,%.5f,%.0f,%d", $0.lat, $0.lon, $0.alt, $0.frame) }.joined())|\(route.home?.lat ?? 0)"
        if key != c.sig {
            c.sig = key
            let built = SceneBuilder.populate(c.scene, terrain: t, route: route, vexag: vexag, boost: boost)
            c.lock.lock(); c.path = built.path; c.tethers = built.tethers; c.lock.unlock()
            c.veh?.removeFromParentNode(); c.veh = nil; c.vehPlane = nil; c.tether?.removeFromParentNode(); c.tether = nil
        }
        v.minDistance = max(t.extent, 800) * 0.03
        v.maxDistance = max(t.extent, 800) * 6
        if c.lastToken != request.token {
            c.lastToken = request.token
            v.azimuth = request.azimuth; v.elevation = request.elevation
            if request.resetDistance { v.clearFocus() }
            if request.resetDistance {
                let mid = CGFloat(((t.elev.max() ?? 0) - t.base) * vexag) * 0.3
                v.target = SCNVector3(0, mid, 0)
                v.distance = max(t.extent, 800) * 1.25
            }
            v.apply()
        }
        // апарат
        if let veh = vehicle {
            c.vehSize = max(t.extent, 800) / 26
            if c.veh == nil || c.vehPlane != veh.plane {
                c.veh?.removeFromParentNode()
                let n = SceneBuilder.vehicleNode(plane: veh.plane, size: CGFloat(c.vehSize))
                c.scene.rootNode.addChildNode(n); c.veh = n; c.vehPlane = veh.plane
            }
            let ground = t.elevation(lat: veh.lat, lon: veh.lon)
            let (x, z) = t.local(lat: veh.lat, lon: veh.lon)
            let y = SceneBuilder.displayY(msl: veh.msl, ground: ground, base: t.base, vexag: vexag, boost: boost)
            let gy = (ground - t.base) * vexag
            SCNTransaction.begin(); SCNTransaction.animationDuration = 0.12
            c.veh?.position = SCNVector3(x, y, z)
            let qy = simd_quatf(angle: Float(-veh.heading * .pi / 180), axis: SIMD3(0, 1, 0))
            let qp = simd_quatf(angle: Float(veh.pitch * .pi / 180), axis: SIMD3(1, 0, 0))
            let qr = simd_quatf(angle: Float(-veh.roll * .pi / 180), axis: SIMD3(0, 0, 1))
            c.veh?.simdOrientation = qy * qp * qr
            if c.tether == nil {
                let g = SCNCylinder(radius: CGFloat(max(t.extent, 800) / 2200), height: 1)
                let mt = SCNMaterial(); mt.diffuse.contents = NSColor.systemCyan.withAlphaComponent(0.9); mt.lightingModel = .constant; g.materials = [mt]
                let n = SCNNode(geometry: g); c.scene.rootNode.addChildNode(n); c.tether = n
            }
            c.tether?.scale = SCNVector3(1, max(abs(y - gy), 0.1), 1)
            c.tether?.position = SCNVector3(x, (y + gy) / 2, z)
            SCNTransaction.commit()
            if follow && !locked && v.focus == nil { v.target = SCNVector3(x, y, z); v.apply() }
        } else if let n = c.veh { n.removeFromParentNode(); c.veh = nil; c.vehPlane = nil; c.tether?.removeFromParentNode(); c.tether = nil }
    }
}

// MARK: - Компас

/// Напівпрозорий об'ємний компас у куті: диск повертається разом з камерою (N вказує на північ карти) і нахиляється
/// за кутом місця. Клік ставить камеру на північ угору; контекстне меню: вигляд зверху / під кутом; замок фіксує камеру.
struct OrbitCompass: View {
    var azimuth: Double, elevation: Double
    var locked: Bool
    var snap: (Double, Double) -> Void
    var toggleLock: () -> Void

    var body: some View {
        let size: CGFloat = 72
        let heading = azimuth - 180                                     // куди дивиться камера, °
        let k = 0.42 + 0.58 * sin(elevation * .pi / 180)                // стиснення диска за кутом місця
        VStack(spacing: 4) {
            Canvas { ctx, sz in
                let c = CGPoint(x: sz.width / 2, y: sz.height / 2 - 3)
                let rx = sz.width / 2 - 6, ry = rx * k
                let thick: CGFloat = 5
                func pt(_ bearing: Double, _ f: CGFloat = 1) -> CGPoint {
                    let p = (bearing - heading) * .pi / 180
                    return CGPoint(x: c.x + rx * f * CGFloat(sin(p)), y: c.y - ry * f * CGFloat(cos(p)))
                }
                let top = Path(ellipseIn: CGRect(x: c.x - rx, y: c.y - ry, width: 2 * rx, height: 2 * ry))
                let under = Path(ellipseIn: CGRect(x: c.x - rx, y: c.y - ry + thick, width: 2 * rx, height: 2 * ry))
                // тінь і бічна стінка
                ctx.drawLayer { l in
                    l.addFilter(.blur(radius: 4))
                    l.fill(Path(ellipseIn: CGRect(x: c.x - rx, y: c.y - ry + thick + 3, width: 2 * rx, height: 2 * ry)), with: .color(.black.opacity(0.35)))
                }
                // бічна стінка: частина нижнього диска, не прикрита верхнім
                var crescent = Path(); crescent.addPath(under); crescent.addPath(top)
                ctx.drawLayer { l in
                    l.clip(to: crescent, style: FillStyle(eoFill: true))
                    l.fill(under, with: .linearGradient(Gradient(colors: [.white.opacity(0.10), .white.opacity(0.30)]),
                                                        startPoint: CGPoint(x: c.x, y: c.y + ry), endPoint: CGPoint(x: c.x, y: c.y + ry + thick)))
                }
                ctx.stroke(under, with: .color(.white.opacity(0.22)), lineWidth: 0.8)
                // верхня грань: скляний диск
                ctx.fill(top, with: .linearGradient(Gradient(colors: [.white.opacity(0.34), .white.opacity(0.08)]),
                                                    startPoint: CGPoint(x: c.x, y: c.y - ry), endPoint: CGPoint(x: c.x, y: c.y + ry)))
                ctx.stroke(top, with: .color(.white.opacity(0.6)), lineWidth: 1)
                let inner = Path(ellipseIn: CGRect(x: c.x - rx * 0.72, y: c.y - ry * 0.72, width: 2 * rx * 0.72, height: 2 * ry * 0.72))
                ctx.stroke(inner, with: .color(.white.opacity(0.18)), lineWidth: 0.7)
                // поділки
                for i in 0..<24 {
                    let b = Double(i) * 15
                    let long = i % 6 == 0
                    var t = Path(); t.move(to: pt(b, 1)); t.addLine(to: pt(b, long ? 0.84 : 0.92))
                    ctx.stroke(t, with: .color(.white.opacity(long ? 0.8 : 0.45)), lineWidth: long ? 1.3 : 0.8)
                }
                // сторони світу
                for (name, b) in [("E", 90.0), ("S", 180.0), ("W", 270.0)] {
                    ctx.draw(Text(LocalizedStringKey(name)).font(.system(size: 10, weight: .semibold, design: .rounded)).foregroundColor(.white.opacity(0.9)), at: pt(b, 0.64))
                }
                // північ: червоний трикутник і літера
                var tri = Path()
                tri.move(to: pt(0, 1.02)); tri.addLine(to: pt(-9, 0.86)); tri.addLine(to: pt(9, 0.86)); tri.closeSubpath()
                ctx.fill(tri, with: .color(Color(red: 1, green: 0.27, blue: 0.23)))
                ctx.draw(Text("N").font(.system(size: 12, weight: .bold, design: .rounded)).foregroundColor(Color(red: 1, green: 0.35, blue: 0.3)), at: pt(0, 0.62))
                // центр
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - 2.5, y: c.y - 2.5, width: 5, height: 5)), with: .color(.white.opacity(0.9)))
            }
            .frame(width: size, height: size)
            .contentShape(Rectangle())
            .onTapGesture { snap(180, elevation) }
            .contextMenu {
                Button("Північ угору") { snap(180, elevation) }
                Button("Вигляд зверху") { snap(180, 88) }
                Button("Під кутом 35°") { snap(180, 35) }
            }
            Button(action: toggleLock) {
                Image(systemName: locked ? "lock.fill" : "lock.open").font(.system(size: 10, weight: .medium)).foregroundStyle(locked ? Color.orange : Color.white.opacity(0.75))
            }
            .buttonStyle(.plain).help(lk(locked ? "Камеру зафіксовано: натисніть, щоб розблокувати" : "Зафіксувати камеру в поточному положенні"))
        }
        .padding(4)
        .shadow(color: .black.opacity(0.55), radius: 2.5, y: 1)
        .help("Компас: клік ставить північ угору; права кнопка: вигляд зверху чи під кутом")
    }
}
