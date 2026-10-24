import SwiftUI

/// Парашут: купол із фестонами, стропи й вантаж (лінійний малюнок у стилі SF Symbols).
struct ParachuteShape: Shape {
    func path(in r: CGRect) -> Path {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x * r.width, y: r.minY + y * r.height) }
        var s = Path()
        // купол
        s.move(to: p(0.04, 0.50)); s.addQuadCurve(to: p(0.96, 0.50), control: p(0.50, -0.24))
        // фестони знизу
        let xs: [CGFloat] = [0.04, 0.347, 0.653, 0.96]
        for i in 0..<3 { s.move(to: p(xs[i], 0.50)); s.addQuadCurve(to: p(xs[i + 1], 0.50), control: p((xs[i] + xs[i + 1]) / 2, 0.64)) }
        // стропи
        for x in xs { s.move(to: p(x, 0.52)); s.addLine(to: p(0.5, 0.82)) }
        // вантаж
        s.addRoundedRect(in: CGRect(x: r.minX + 0.40 * r.width, y: r.minY + 0.82 * r.height, width: 0.20 * r.width, height: 0.18 * r.height),
                         cornerSize: CGSize(width: r.width * 0.04, height: r.width * 0.04))
        return s
    }
}

/// Механічний захват: кріплення, корпус і дві щелепи; `closed` — щелепи зімкнені (захоплено), інакше розведені.
struct GripperShape: Shape {
    var closed: Bool
    func path(in r: CGRect) -> Path {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x * r.width, y: r.minY + y * r.height) }
        var s = Path()
        // кріплення й корпус
        s.addRect(CGRect(x: r.minX + 0.42 * r.width, y: r.minY, width: 0.16 * r.width, height: 0.14 * r.height))
        s.addRoundedRect(in: CGRect(x: r.minX + 0.26 * r.width, y: r.minY + 0.14 * r.height, width: 0.48 * r.width, height: 0.22 * r.height),
                         cornerSize: CGSize(width: r.width * 0.05, height: r.width * 0.05))
        // щелепи
        if closed {
            s.move(to: p(0.34, 0.36)); s.addLine(to: p(0.34, 0.68)); s.addLine(to: p(0.47, 0.96))
            s.move(to: p(0.66, 0.36)); s.addLine(to: p(0.66, 0.68)); s.addLine(to: p(0.53, 0.96))
        } else {
            s.move(to: p(0.32, 0.36)); s.addLine(to: p(0.10, 0.66)); s.addLine(to: p(0.20, 0.96))
            s.move(to: p(0.68, 0.36)); s.addLine(to: p(0.90, 0.66)); s.addLine(to: p(0.80, 0.96))
        }
        // шарніри
        s.addEllipse(in: CGRect(x: r.minX + 0.29 * r.width, y: r.minY + 0.31 * r.height, width: 0.07 * r.width, height: 0.07 * r.height))
        s.addEllipse(in: CGRect(x: r.minX + 0.64 * r.width, y: r.minY + 0.31 * r.height, width: 0.07 * r.width, height: 0.07 * r.height))
        return s
    }
}

/// Значок заголовка: «custom:…» малюється власними фігурами, інакше системний SF Symbol.
struct CardIcon: View {
    let name: String
    var body: some View {
        switch name {
        case "custom:parachute": ParachuteShape().stroke(style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)).frame(width: 17, height: 17)
        case "custom:gripper": GripperShape(closed: false).stroke(style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)).frame(width: 17, height: 17)
        case "custom:gripper.closed": GripperShape(closed: true).stroke(style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)).frame(width: 17, height: 17)
        default: Image(systemName: name)
        }
    }
}
