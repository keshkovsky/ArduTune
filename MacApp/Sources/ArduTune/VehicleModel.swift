import SwiftUI
import SceneKit
import simd

/// Міні-3D модель апарата, що повторює його орієнтацію в реальному часі.
struct VehicleModel: NSViewRepresentable {
    let kind: VehicleKind
    let roll: Double, pitch: Double, yaw: Double

    final class Coordinator { var key = ""; var node: SCNNode? }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SCNView {
        let v = SCNView()
        v.backgroundColor = .clear
        v.allowsCameraControl = true
        v.antialiasingMode = .multisampling4X
        v.autoenablesDefaultLighting = false
        return v
    }

    func updateNSView(_ v: SCNView, context: Context) {
        let key: String
        switch kind { case .copter(let n): key = "c\(n)"; case .plane: key = "p"; case .other: key = "c4" }
        if context.coordinator.key != key {
            context.coordinator.key = key
            let scene = SCNScene()
            let model = buildModel(key)
            scene.rootNode.addChildNode(model)
            context.coordinator.node = model
            let cam = SCNNode(); cam.camera = SCNCamera(); cam.camera?.fieldOfView = 38
            cam.position = SCNVector3(2.4, 1.9, 3.4); cam.look(at: SCNVector3(0, 0, 0))
            scene.rootNode.addChildNode(cam)
            let amb = SCNNode(); amb.light = SCNLight(); amb.light?.type = .ambient; amb.light?.intensity = 650
            scene.rootNode.addChildNode(amb)
            let sun = SCNNode(); sun.light = SCNLight(); sun.light?.type = .directional; sun.light?.intensity = 900
            sun.eulerAngles = SCNVector3(-0.9, 0.6, 0)
            scene.rootNode.addChildNode(sun)
            // Сітка землі
            let floor = SCNNode(geometry: SCNPlane(width: 4, height: 4))
            floor.geometry?.firstMaterial?.diffuse.contents = NSColor.gray.withAlphaComponent(0.12)
            floor.geometry?.firstMaterial?.isDoubleSided = true
            floor.eulerAngles.x = -.pi / 2; floor.position.y = -0.55
            scene.rootNode.addChildNode(floor)
            v.scene = scene
        }
        // Ніс = -Z, верх = +Y, правий борт = +X. Порядок: yaw * pitch * roll.
        let qy = simd_quatd(angle: -yaw * .pi / 180, axis: SIMD3(0, 1, 0))
        let qx = simd_quatd(angle: pitch * .pi / 180, axis: SIMD3(1, 0, 0))
        let qz = simd_quatd(angle: -roll * .pi / 180, axis: SIMD3(0, 0, 1))
        let q = qy * qx * qz
        context.coordinator.node?.simdOrientation = simd_quatf(ix: Float(q.imag.x), iy: Float(q.imag.y), iz: Float(q.imag.z), r: Float(q.real))
    }

    func mat(_ c: NSColor) -> SCNMaterial {
        let m = SCNMaterial(); m.diffuse.contents = c; m.lightingModel = .blinn; return m
    }

    func buildModel(_ key: String) -> SCNNode {
        let root = SCNNode()
        if key == "p" {
            let fus = SCNNode(geometry: SCNCapsule(capRadius: 0.11, height: 1.7))
            fus.eulerAngles.x = .pi / 2
            fus.geometry?.materials = [mat(.white)]
            root.addChildNode(fus)
            let wing = SCNNode(geometry: SCNBox(width: 2.2, height: 0.03, length: 0.42, chamferRadius: 0.01))
            wing.position = SCNVector3(0, 0, -0.1); wing.geometry?.materials = [mat(.systemBlue)]
            root.addChildNode(wing)
            let tail = SCNNode(geometry: SCNBox(width: 0.8, height: 0.025, length: 0.25, chamferRadius: 0.01))
            tail.position = SCNVector3(0, 0.02, 0.75); tail.geometry?.materials = [mat(.systemBlue)]
            root.addChildNode(tail)
            let fin = SCNNode(geometry: SCNBox(width: 0.025, height: 0.32, length: 0.25, chamferRadius: 0.01))
            fin.position = SCNVector3(0, 0.17, 0.75); fin.geometry?.materials = [mat(.systemBlue)]
            root.addChildNode(fin)
            let nose = SCNNode(geometry: SCNCone(topRadius: 0, bottomRadius: 0.11, height: 0.3))
            nose.eulerAngles.x = -.pi / 2; nose.position = SCNVector3(0, 0, -0.98)
            nose.geometry?.materials = [mat(.systemRed)]
            root.addChildNode(nose)
        } else {
            let n = Int(key.dropFirst()) ?? 4
            let body = SCNNode(geometry: SCNBox(width: 0.42, height: 0.12, length: 0.42, chamferRadius: 0.03))
            body.geometry?.materials = [mat(NSColor(white: 0.18, alpha: 1))]
            root.addChildNode(body)
            let off = n == 4 ? 45.0 : 180.0 / Double(n)
            for i in 0..<n {
                // 0° = ніс (-Z), далі за годинниковою стрілкою зверху
                let a = (off + 360.0 / Double(n) * Double(i)) * .pi / 180
                let dir = SCNVector3(Float(sin(a)), 0, Float(-cos(a)))
                let front = i == 0 || (n == 4 && i == 3)
                let arm = SCNNode(geometry: SCNBox(width: 0.06, height: 0.05, length: 0.85, chamferRadius: 0.01))
                arm.geometry?.materials = [mat(front ? .systemRed : NSColor(white: 0.3, alpha: 1))]
                arm.position = SCNVector3(dir.x * 0.42, 0, dir.z * 0.42)
                arm.eulerAngles.y = CGFloat(-a)
                root.addChildNode(arm)
                let motor = SCNNode(geometry: SCNCylinder(radius: 0.07, height: 0.09))
                motor.position = SCNVector3(dir.x * 0.85, 0.05, dir.z * 0.85)
                motor.geometry?.materials = [mat(.darkGray)]
                root.addChildNode(motor)
                let prop = SCNNode(geometry: SCNCylinder(radius: 0.3, height: 0.01))
                prop.position = SCNVector3(dir.x * 0.85, 0.11, dir.z * 0.85)
                let pm = mat(i % 2 == 0 ? .systemTeal : .systemOrange); pm.transparency = 0.45
                prop.geometry?.materials = [pm]
                root.addChildNode(prop)
            }
            // Стрілка «носа»
            let cone = SCNNode(geometry: SCNCone(topRadius: 0, bottomRadius: 0.08, height: 0.22))
            cone.eulerAngles.x = -.pi / 2; cone.position = SCNVector3(0, 0.02, -0.3)
            cone.geometry?.materials = [mat(.systemYellow)]
            root.addChildNode(cone)
        }
        return root
    }
}
