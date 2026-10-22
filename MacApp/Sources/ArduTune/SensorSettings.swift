import SwiftUI
import SceneKit
import simd

// MARK: - Орієнтація плати (AHRS_ORIENTATION)

struct BoardRot: Identifiable { let id: Int; let name: String; let roll: Double; let pitch: Double; let yaw: Double }

enum BoardRotations {
    /// Таблиця rotation з ArduPilot: кути в градусах (крен, тангаж, рискання).
    static let all: [BoardRot] = [
        BoardRot(id: 0, name: "None", roll: 0, pitch: 0, yaw: 0),
        BoardRot(id: 1, name: "Yaw 45°", roll: 0, pitch: 0, yaw: 45),
        BoardRot(id: 2, name: "Yaw 90°", roll: 0, pitch: 0, yaw: 90),
        BoardRot(id: 3, name: "Yaw 135°", roll: 0, pitch: 0, yaw: 135),
        BoardRot(id: 4, name: "Yaw 180°", roll: 0, pitch: 0, yaw: 180),
        BoardRot(id: 5, name: "Yaw 225°", roll: 0, pitch: 0, yaw: 225),
        BoardRot(id: 6, name: "Yaw 270°", roll: 0, pitch: 0, yaw: 270),
        BoardRot(id: 7, name: "Yaw 315°", roll: 0, pitch: 0, yaw: 315),
        BoardRot(id: 8, name: "Roll 180°", roll: 180, pitch: 0, yaw: 0),
        BoardRot(id: 9, name: "Roll 180° + Yaw 45°", roll: 180, pitch: 0, yaw: 45),
        BoardRot(id: 10, name: "Roll 180° + Yaw 90°", roll: 180, pitch: 0, yaw: 90),
        BoardRot(id: 11, name: "Roll 180° + Yaw 135°", roll: 180, pitch: 0, yaw: 135),
        BoardRot(id: 12, name: "Pitch 180°", roll: 0, pitch: 180, yaw: 0),
        BoardRot(id: 13, name: "Roll 180° + Yaw 225°", roll: 180, pitch: 0, yaw: 225),
        BoardRot(id: 14, name: "Roll 180° + Yaw 270°", roll: 180, pitch: 0, yaw: 270),
        BoardRot(id: 15, name: "Roll 180° + Yaw 315°", roll: 180, pitch: 0, yaw: 315),
        BoardRot(id: 16, name: "Roll 90°", roll: 90, pitch: 0, yaw: 0),
        BoardRot(id: 17, name: "Roll 90° + Yaw 45°", roll: 90, pitch: 0, yaw: 45),
        BoardRot(id: 18, name: "Roll 90° + Yaw 90°", roll: 90, pitch: 0, yaw: 90),
        BoardRot(id: 19, name: "Roll 90° + Yaw 135°", roll: 90, pitch: 0, yaw: 135),
        BoardRot(id: 20, name: "Roll 270°", roll: 270, pitch: 0, yaw: 0),
        BoardRot(id: 21, name: "Roll 270° + Yaw 45°", roll: 270, pitch: 0, yaw: 45),
        BoardRot(id: 22, name: "Roll 270° + Yaw 90°", roll: 270, pitch: 0, yaw: 90),
        BoardRot(id: 23, name: "Roll 270° + Yaw 135°", roll: 270, pitch: 0, yaw: 135),
        BoardRot(id: 24, name: "Pitch 90°", roll: 0, pitch: 90, yaw: 0),
        BoardRot(id: 25, name: "Pitch 270°", roll: 0, pitch: 270, yaw: 0),
        BoardRot(id: 26, name: "Pitch 180° + Yaw 90°", roll: 0, pitch: 180, yaw: 90),
        BoardRot(id: 27, name: "Pitch 180° + Yaw 270°", roll: 0, pitch: 180, yaw: 270),
        BoardRot(id: 28, name: "Roll 90° + Pitch 90°", roll: 90, pitch: 90, yaw: 0),
        BoardRot(id: 29, name: "Roll 180° + Pitch 90°", roll: 180, pitch: 90, yaw: 0),
        BoardRot(id: 30, name: "Roll 270° + Pitch 90°", roll: 270, pitch: 90, yaw: 0),
        BoardRot(id: 31, name: "Roll 90° + Pitch 180°", roll: 90, pitch: 180, yaw: 0),
        BoardRot(id: 32, name: "Roll 270° + Pitch 180°", roll: 270, pitch: 180, yaw: 0),
        BoardRot(id: 33, name: "Roll 90° + Pitch 270°", roll: 90, pitch: 270, yaw: 0),
        BoardRot(id: 34, name: "Roll 180° + Pitch 270°", roll: 180, pitch: 270, yaw: 0),
        BoardRot(id: 35, name: "Roll 270° + Pitch 270°", roll: 270, pitch: 270, yaw: 0),
        BoardRot(id: 36, name: "Roll 90° + Pitch 180° + Yaw 90°", roll: 90, pitch: 180, yaw: 90),
        BoardRot(id: 37, name: "Roll 90° + Yaw 270°", roll: 90, pitch: 0, yaw: 270),
        BoardRot(id: 38, name: "Roll 90° + Pitch 68° + Yaw 293°", roll: 90, pitch: 68, yaw: 293),
        BoardRot(id: 39, name: "Pitch 315°", roll: 0, pitch: 315, yaw: 0),
        BoardRot(id: 40, name: "Roll 90° + Pitch 315°", roll: 90, pitch: 315, yaw: 0),
        BoardRot(id: 100, name: "Custom (AHRS_CUSTOM_*)", roll: 0, pitch: 0, yaw: 0),
    ]

    static func rotation(_ id: Int, custom: (Double, Double, Double)) -> (Double, Double, Double) {
        if id == 100 { return custom }
        let r = all.first { $0.id == id } ?? all[0]
        return (r.roll, r.pitch, r.yaw)
    }

    /// Матриця «плата → тіло апарата» (Rz·Ry·Rx), як в ArduPilot, переведена в систему координат сцени
    /// (нос −Z, праворуч +X, вгору +Y). Повертає стовпці матриці.
    static func sceneColumns(roll: Double, pitch: Double, yaw: Double) -> [SIMD3<Float>] {
        let r = roll * .pi / 180, p = pitch * .pi / 180, y = yaw * .pi / 180
        let cr = cos(r), sr = sin(r), cp = cos(p), sp = sin(p), cy = cos(y), sy = sin(y)
        let rx = [[1, 0, 0], [0, cr, -sr], [0, sr, cr]]
        let ry = [[cp, 0, sp], [0, 1, 0], [-sp, 0, cp]]
        let rz = [[cy, -sy, 0], [sy, cy, 0], [0, 0, 1]]
        func mul(_ a: [[Double]], _ b: [[Double]]) -> [[Double]] {
            var out = [[Double]](repeating: [0, 0, 0], count: 3)
            for i in 0..<3 {
                for j in 0..<3 {
                    var sum = 0.0
                    for k in 0..<3 { sum += a[i][k] * b[k][j] }
                    out[i][j] = sum
                }
            }
            return out
        }
        let R = mul(rz, mul(ry, rx))
        let M: [[Double]] = [[0, 1, 0], [0, 0, -1], [-1, 0, 0]]      // тіло (x вперед, y праворуч, z вниз) → сцена
        var Mt = [[Double]](repeating: [0, 0, 0], count: 3)
        for i in 0..<3 { for j in 0..<3 { Mt[i][j] = M[j][i] } }
        let S = mul(M, mul(R, Mt))
        var cols: [SIMD3<Float>] = []
        for j in 0..<3 { cols.append(SIMD3<Float>(Float(S[0][j]), Float(S[1][j]), Float(S[2][j]))) }
        return cols
    }
}

/// 3D-схема: апарат і плата польотного контролера, повернута згідно орієнтації.
struct BoardOrientationView: NSViewRepresentable {
    let kind: VehicleKind
    let roll: Double, pitch: Double, yaw: Double

    final class Coordinator { var key = ""; var board: SCNNode? }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SCNView {
        let v = SCNView()
        v.backgroundColor = .clear
        v.allowsCameraControl = true
        v.antialiasingMode = .multisampling4X
        return v
    }

    func updateNSView(_ v: SCNView, context: Context) {
        let key: String
        switch kind { case .copter(let n): key = "c\(n)"; case .plane: key = "p"; case .other: key = "c4" }
        if context.coordinator.key != key {
            context.coordinator.key = key
            let scene = SCNScene()
            let helper = VehicleModel(kind: kind, roll: 0, pitch: 0, yaw: 0)
            let model = helper.buildModel(key)
            scene.rootNode.addChildNode(model)
            let board = SCNNode()
            board.position = SCNVector3(0, 0.2, 0)
            let pcb = SCNNode(geometry: SCNBox(width: 0.42, height: 0.04, length: 0.42, chamferRadius: 0.012))
            pcb.geometry?.materials = [helper.mat(NSColor(red: 0.04, green: 0.42, blue: 0.24, alpha: 1))]
            board.addChildNode(pcb)
            let chip = SCNNode(geometry: SCNBox(width: 0.14, height: 0.03, length: 0.14, chamferRadius: 0.005))
            chip.position = SCNVector3(0, 0.035, 0.02); chip.geometry?.materials = [helper.mat(NSColor(white: 0.1, alpha: 1))]
            board.addChildNode(chip)
            let usb = SCNNode(geometry: SCNBox(width: 0.12, height: 0.035, length: 0.07, chamferRadius: 0.005))
            usb.position = SCNVector3(0, 0.03, 0.2); usb.geometry?.materials = [helper.mat(NSColor(white: 0.75, alpha: 1))]
            board.addChildNode(usb)
            // Стрілка «вперед» на платі
            let shaft = SCNNode(geometry: SCNCylinder(radius: 0.012, height: 0.16))
            shaft.eulerAngles.x = .pi / 2; shaft.position = SCNVector3(0, 0.04, -0.1)
            shaft.geometry?.materials = [helper.mat(.systemYellow)]
            board.addChildNode(shaft)
            let head = SCNNode(geometry: SCNCone(topRadius: 0, bottomRadius: 0.05, height: 0.1))
            head.eulerAngles.x = -.pi / 2; head.position = SCNVector3(0, 0.04, -0.23)
            head.geometry?.materials = [helper.mat(.systemYellow)]
            board.addChildNode(head)
            scene.rootNode.addChildNode(board)
            context.coordinator.board = board

            let cam = SCNNode(); cam.camera = SCNCamera(); cam.camera?.fieldOfView = 40
            cam.position = SCNVector3(0.1, 3.4, 2.7); cam.look(at: SCNVector3(0, 0, 0))
            scene.rootNode.addChildNode(cam)
            let amb = SCNNode(); amb.light = SCNLight(); amb.light?.type = .ambient; amb.light?.intensity = 700
            scene.rootNode.addChildNode(amb)
            let sun = SCNNode(); sun.light = SCNLight(); sun.light?.type = .directional; sun.light?.intensity = 900
            sun.eulerAngles = SCNVector3(-0.9, 0.5, 0)
            scene.rootNode.addChildNode(sun)
            v.scene = scene
        }
        guard let board = context.coordinator.board else { return }
        let c = BoardRotations.sceneColumns(roll: roll, pitch: pitch, yaw: yaw)
        let pos = SIMD3<Float>(0, 0.2, 0)
        SCNTransaction.begin(); SCNTransaction.animationDuration = 0.45
        board.simdTransform = simd_float4x4(SIMD4(c[0], 0), SIMD4(c[1], 0), SIMD4(c[2], 0), SIMD4(pos, 1))
        SCNTransaction.commit()
    }
}

struct BoardOrientationCard: View {
    @Environment(Store.self) var s
    @State private var pending: Int?
    @State private var note: String?
    var ps: ParamStore { s.ps }
    var current: Int { Int(ps.val("AHRS_ORIENTATION") ?? 0) }
    var shown: Int { pending ?? current }
    var custom: (Double, Double, Double) { (ps.val("AHRS_CUSTOM_ROLL") ?? 0, ps.val("AHRS_CUSTOM_PIT") ?? 0, ps.val("AHRS_CUSTOM_YAW") ?? 0) }
    var frameClass: Int { Int(ps.val("FRAME_CLASS") ?? 1) }

    func label(_ r: BoardRot) -> String { r.id == 0 ? "None (стрілка вперед)" : r.name }

    var body: some View {
        let rot = BoardRotations.rotation(shown, custom: custom)
        Card(title: String(localized: "Орієнтація польотного контролера"), icon: "rotate.3d", text: String(localized: "Як плата встановлена відносно апарата (AHRS_ORIENTATION). Жовта стрілка на платі вказує її «вперед»; червоний/жовтий промінь апарата вказує на ніс. USB-роз'єм (сірий) на задньому краї плати.")) {
            HStack(alignment: .top, spacing: 18) {
                BoardOrientationView(kind: vehicleKind(s.t.vehicle, frameClass: frameClass), roll: rot.0, pitch: rot.1, yaw: rot.2)
                    .frame(width: 330, height: 260)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 10) {
                    if !ps.has("AHRS_ORIENTATION") {
                        Label("Параметр AHRS_ORIENTATION недоступний", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    } else {
                        Text("Поточна: \(BoardRotations.all.first { $0.id == current }?.name ?? "\(current)")").font(.callout)
                        Picker("Нова орієнтація", selection: Binding(get: { shown }, set: { pending = $0 == current ? nil : $0 })) {
                            ForEach(BoardRotations.all) { r in Text(lk(label(r))).tag(r.id) }
                        }.frame(width: 320).disabled(s.armed)
                        Text(String(format: loc("Крен %.0f°  ·  тангаж %.0f°  ·  рискання %.0f°"), rot.0, rot.1, rot.2)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        if shown == 100 {
                            HStack(spacing: 10) {
                                ForEach([("AHRS_CUSTOM_ROLL", "крен"), ("AHRS_CUSTOM_PIT", "тангаж"), ("AHRS_CUSTOM_YAW", "рискання")], id: \.0) { n in
                                    if ps.has(n.0) { VStack(alignment: .leading) { Text(LocalizedStringKey(n.1)).font(.caption2).foregroundStyle(.secondary); ParamField(name: n.0, width: 70) } }
                                }
                            }
                        }
                        if let p = pending {
                            HStack {
                                Button { apply(p) } label: { Label("Застосувати", systemImage: "checkmark") }.buttonStyle(.borderedProminent).disabled(s.armed)
                                Button("Скасувати") { pending = nil }
                            }
                            Label("Це лише перегляд, поки не натиснете «Застосувати».", systemImage: "eye").font(.caption).foregroundStyle(.secondary)
                        }
                        if let n = note {
                            VStack(alignment: .leading, spacing: 6) {
                                Label(LocalizedStringKey(n), systemImage: "info.circle.fill").font(.callout).foregroundStyle(.orange)
                                Button { EngineAPI.post("/reboot") } label: { Label("Перезавантажити автопілот", systemImage: "restart") }.disabled(s.armed)
                            }
                        }
                        Text("Після зміни орієнтації повторіть калібрування акселерометра й вирівнювання горизонту.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    func apply(_ v: Int) {
        ps.write("AHRS_ORIENTATION", Double(v))
        pending = nil
        note = String(localized: "Орієнтацію записано. Для застосування потрібне перезавантаження автопілота.")
    }
}

// MARK: - Фільтри гіроскопа й акселерометра

/// Повзунок параметра: значення пишеться лише після відпускання.
struct ParamSlider: View {
    @Environment(Store.self) var s
    let name: String
    var lo = 0.0, hi = 256.0, step = 1.0
    var unit = "Гц"
    @State private var value = 0.0
    @State private var editing = false

    var body: some View {
        let cur = s.ps.val(name)
        HStack(spacing: 10) {
            Slider(value: $value, in: lo...hi, step: step) { e in
                editing = e
                if !e, value != s.ps.val(name) { s.ps.write(name, value) }
            }
            .disabled(s.armed || cur == nil)
            Text("\(Int(value)) \(loc(unit))").font(.system(.callout, design: .monospaced)).frame(width: 70, alignment: .trailing)
        }
        .onAppear { value = cur ?? 0 }
        .onChange(of: cur) { _, v in if !editing, let v { value = v } }
    }
}

struct SensorFiltersCard: View {
    @Environment(Store.self) var s
    var ps: ParamStore { s.ps }

    func preset(_ title: String, _ hz: Double, _ hint: String) -> some View {
        Button(lk(title)) { ps.write("INS_GYRO_FILTER", hz); ps.write("INS_ACCEL_FILTER", hz) }.help(lk(hint)).disabled(s.armed)
    }

    var body: some View {
        Card(title: String(localized: "Фільтри інерціальних датчиків"), icon: "waveform.path.ecg", text: String(localized: "Нижчий поріг прибирає більше вібраційного шуму, але додає затримку відгуку. Вищий дає різкіший відгук, але пропускає більше шуму до PID. Зміни діють одразу, якщо не зазначено інше.")) {
            if !ps.has("INS_GYRO_FILTER") && !ps.has("INS_ACCEL_FILTER") {
                Label("Параметри фільтрів недоступні в цій прошивці.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            if ps.has("INS_GYRO_FILTER") {
                VStack(alignment: .leading, spacing: 2) {
                    HStack { Label("Гіроскоп: низькочастотний фільтр", systemImage: "gyroscope").font(.callout.weight(.medium)); Text("INS_GYRO_FILTER").font(.caption2.monospaced()).foregroundStyle(.secondary) }
                    ParamSlider(name: "INS_GYRO_FILTER", lo: 0, hi: 256)
                }
            }
            if ps.has("INS_ACCEL_FILTER") {
                VStack(alignment: .leading, spacing: 2) {
                    HStack { Label("Акселерометр: низькочастотний фільтр", systemImage: "move.3d").font(.callout.weight(.medium)); Text("INS_ACCEL_FILTER").font(.caption2.monospaced()).foregroundStyle(.secondary) }
                    ParamSlider(name: "INS_ACCEL_FILTER", lo: 0, hi: 256)
                }
            }
            HStack(spacing: 8) {
                Text("Швидкі пресети:").font(.caption).foregroundStyle(.secondary)
                preset("М'який · 10 Гц", 10, "Для великих важких апаратів і сильної вібрації")
                preset("Стандарт · 20 Гц", 20, "Типове значення ArduPilot")
                preset("Різкий · 40 Гц", 40, "Для малих легких апаратів із чистою вібрацією")
            }
            let rate = ["INS_GYRO_RATE", "INS_FAST_SAMPLE"].filter { ps.has($0) }
            if !rate.isEmpty {
                Divider()
                Text("ДИСКРЕТИЗАЦІЯ").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(rate, id: \.self) { AdvParamRow(name: $0) }
            }
            if ps.has("INS_HNTCH_ENABLE") {
                Divider()
                Text("ГАРМОНІЧНИЙ РЕЖЕКТОРНИЙ ФІЛЬТР (NOTCH)").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Text("Вирізає вузькі піки шуму на частоті моторів. Вмикається окремо й потребує перезавантаження.").font(.caption).foregroundStyle(.secondary)
                ForEach(["INS_HNTCH_ENABLE", "INS_HNTCH_MODE", "INS_HNTCH_REF", "INS_HNTCH_FREQ", "INS_HNTCH_BW", "INS_HNTCH_ATT", "INS_HNTCH_HMNCS", "INS_HNTCH_OPTS", "INS_HNTCH_FM_RAT"].filter { ps.has($0) }, id: \.self) {
                    AdvParamRow(name: $0)
                }
            }
            HStack(spacing: 14) {
                Text("Вібрація зараз:").font(.caption).foregroundStyle(.secondary)
                ForEach([("X", s.t.vibeX), ("Y", s.t.vibeY), ("Z", s.t.vibeZ)], id: \.0) { v in
                    Text(String(format: "%@ %.1f", v.0, v.1)).font(.caption.monospacedDigit()).foregroundStyle(v.1 > 30 ? .red : (v.1 > 15 ? .orange : .green))
                }
                Text("м/с² (норма < 30)").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
