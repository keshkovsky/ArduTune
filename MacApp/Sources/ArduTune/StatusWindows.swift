import SwiftUI

/// Вертикальний датчик з двома порогами (як у Mission Planner): зелена зона, жовта/оранжева, червона.
struct Gauge: View {
    let value: Double
    let maxValue: Double
    let warn: Double
    let bad: Double
    let label: String
    var warnLabel: String
    var badLabel: String

    var body: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 5)
                    .fill(LinearGradient(colors: [Color(white: 0.55), Color(white: 0.22)], startPoint: .leading, endPoint: .trailing))
                GeometryReader { g in
                    let h = g.size.height
                    let f = CGFloat(min(max(value / maxValue, 0), 1))
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        Rectangle().fill(color.opacity(0.85)).frame(height: h * f)
                    }
                    line(at: h * (1 - CGFloat(bad / maxValue)), text: badLabel)
                    line(at: h * (1 - CGFloat(warn / maxValue)), text: warnLabel)
                }
            }
            .frame(width: 92, height: 250)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(.gray.opacity(0.6), lineWidth: 1))
            Text(LocalizedStringKey(label)).font(.callout).multilineTextAlignment(.center).frame(width: 96)
            Text(String(format: "%.2f", value)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    var color: Color { value >= bad ? .red : (value >= warn ? .orange : .green) }

    func line(at y: CGFloat, text: String) -> some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(.red).frame(height: 2).offset(y: y)
            Text(LocalizedStringKey(text)).font(.system(size: 12)).foregroundStyle(.white.opacity(0.9)).offset(x: 4, y: y - 16)
        }
    }
}

/// Окреме вікно «EKF Status».
struct EKFStatusView: View {
    @Environment(Store.self) var s

    static let flags: [(Int, String, Bool)] = [
        (1, "attitude", true), (2, "velocity_horiz", true), (4, "velocity_vert", false), (8, "pos_horiz_rel", false),
        (16, "pos_horiz_abs", true), (32, "pos_vert_abs", true), (64, "pos_vert_agl", false), (128, "const_pos_mode", false),
        (256, "pred_pos_horiz_rel", false), (512, "pred_pos_horiz_abs", false),
    ]

    var body: some View {
        let t = s.t
        HStack(alignment: .top, spacing: 30) {
            VStack(spacing: 16) {
                Text("EKF Status").font(.title.bold())
                HStack(alignment: .top, spacing: 14) {
                    Gauge(value: t.ekfVelVar, maxValue: 1, warn: 0.5, bad: 0.8, label: "Velocity", warnLabel: "0.5", badLabel: "0.8")
                    Gauge(value: t.ekfPosHVar, maxValue: 1, warn: 0.5, bad: 0.8, label: "Position\n(Horiz)", warnLabel: "0.5", badLabel: "0.8")
                    Gauge(value: t.ekfPosVVar, maxValue: 1, warn: 0.5, bad: 0.8, label: "Position\n(Vert)", warnLabel: "0.5", badLabel: "0.8")
                    Gauge(value: t.ekfCompassVar, maxValue: 1, warn: 0.5, bad: 0.8, label: "Compass", warnLabel: "0.5", badLabel: "0.8")
                    Gauge(value: t.ekfTerrainVar, maxValue: 1, warn: 0.5, bad: 0.8, label: "Terrain", warnLabel: "0.5", badLabel: "0.8")
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("Flags").font(.title2.bold()).padding(.bottom, 6)
                ForEach(Self.flags, id: \.0) { f in
                    let on = (t.ekfFlags & f.0) != 0
                    Text("\(f.1) \(on ? "On" : "Off")")
                        .font(.system(size: 14))
                        .foregroundStyle(on ? Color.primary : (f.2 ? Color.red : Color.primary))
                }
                Divider().padding(.vertical, 4)
                Text(lk(s.connected ? "Дані EKF_STATUS_REPORT" : "Немає зв'язку з польотником")).font(.caption).foregroundStyle(.secondary)
            }
            .frame(width: 190, alignment: .leading)
        }
        .padding(26)
        .frame(minWidth: 780, minHeight: 440)
    }
}

/// Окреме вікно «Vibration».
struct VibrationView: View {
    @Environment(Store.self) var s

    var body: some View {
        let t = s.t
        HStack(alignment: .top, spacing: 30) {
            VStack(spacing: 16) {
                Text("Vibration").font(.title.bold())
                HStack(alignment: .top, spacing: 16) {
                    Gauge(value: t.vibeX, maxValue: 90, warn: 30, bad: 60, label: "X", warnLabel: "30", badLabel: "60")
                    Gauge(value: t.vibeY, maxValue: 90, warn: 30, bad: 60, label: "Y", warnLabel: "30", badLabel: "60")
                    Gauge(value: t.vibeZ, maxValue: 90, warn: 30, bad: 60, label: "Z", warnLabel: "30", badLabel: "60")
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                Text("Clipping").font(.title2.bold())
                clip("Primary", t.vibeClip0)
                clip("Secondary", t.vibeClip1)
                clip("Tertiary", t.vibeClip2)
                Divider().padding(.vertical, 4)
                Text("Норма: до 30 м/с². Понад 60 небезпечно для польоту.").font(.caption).foregroundStyle(.secondary).frame(width: 180, alignment: .leading)
            }
        }
        .padding(26)
        .frame(minWidth: 560, minHeight: 440)
    }

    func clip(_ title: String, _ v: Double) -> some View {
        HStack {
            Text(LocalizedStringKey(title)).frame(width: 90, alignment: .leading)
            Text(lk(String(Int(v)))).font(.system(.body, design: .monospaced))
                .padding(.horizontal, 10).padding(.vertical, 3).frame(width: 80, alignment: .leading)
                .background((v > 0 ? Color.red.opacity(0.25) : Color.gray.opacity(0.2)), in: RoundedRectangle(cornerRadius: 4))
        }
    }
}
