import SwiftUI

/// Горизонтальна шкала з порогами (жовтий/червоний): значення, смужка й риски порогів.
struct MetricBar: View {
    let title: String
    let value: Double
    let maxValue: Double
    let warn: Double
    let bad: Double
    var format = "%.2f"

    private var color: Color { value >= bad ? .red : (value >= warn ? .orange : .green) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(lk(title)).font(.callout)
                Spacer()
                Text(String(format: format, value)).font(.callout.monospacedDigit().weight(.medium)).foregroundStyle(color)
            }
            GeometryReader { g in
                let w = g.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary.opacity(0.6))
                    Capsule().fill(color.gradient).frame(width: max(4, w * CGFloat(min(max(value / maxValue, 0), 1))))
                    ForEach([warn, bad], id: \.self) { t in
                        Rectangle().fill(.secondary.opacity(0.7)).frame(width: 1, height: 10).offset(x: w * CGFloat(t / maxValue) - 0.5)
                    }
                }
            }.frame(height: 6)
        }
    }
}

/// Позначка стану (точка + текст) для прапорців.
struct FlagChip: View {
    let name: String
    let on: Bool
    let required: Bool
    private var color: Color { on ? .green : (required ? .red : .secondary.opacity(0.6)) }
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(name).font(.system(.caption, design: .monospaced)).foregroundStyle(on || !required ? Color.primary : Color.red)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

struct StatusSection<Content: View>: View {
    let title: String
    var badge: (String, Color)?
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(lk(title)).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if let b = badge {
                    Text(lk(b.0)).font(.caption.weight(.semibold)).foregroundStyle(b.1)
                        .padding(.horizontal, 8).padding(.vertical, 2).background(b.1.opacity(0.15), in: Capsule())
                }
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// Панель «EKF Status»: дисперсії фільтра й прапорці (вкладка внизу Flight Data і окреме вікно).
struct EKFPanel: View {
    @Environment(Store.self) var s

    static let flags: [(Int, String, Bool)] = [
        (1, "attitude", true), (2, "velocity_horiz", true), (4, "velocity_vert", false), (8, "pos_horiz_rel", false),
        (16, "pos_horiz_abs", true), (32, "pos_vert_abs", true), (64, "pos_vert_agl", false), (128, "const_pos_mode", false),
        (256, "pred_pos_horiz_rel", false), (512, "pred_pos_horiz_abs", false),
    ]

    var body: some View {
        let t = s.t
        let needed = Self.flags.filter(\.2).reduce(0) { $0 | $1.0 }
        let ready = s.connected && (t.ekfFlags & needed) == needed
        let worst = max(t.ekfVelVar, t.ekfPosHVar, t.ekfPosVVar, t.ekfCompassVar)
        let badge: (String, Color) = !s.connected ? ("Немає зв'язку", .secondary) : (ready && worst < 0.8 ? ("Готовий", .green) : ("Не готовий", .red))
        ScrollView {
            HStack(alignment: .top, spacing: 14) {
                StatusSection(title: "Variances", badge: badge) {
                    VStack(spacing: 12) {
                        MetricBar(title: "Velocity", value: t.ekfVelVar, maxValue: 1, warn: 0.5, bad: 0.8)
                        MetricBar(title: "Position (Horiz)", value: t.ekfPosHVar, maxValue: 1, warn: 0.5, bad: 0.8)
                        MetricBar(title: "Position (Vert)", value: t.ekfPosVVar, maxValue: 1, warn: 0.5, bad: 0.8)
                        MetricBar(title: "Compass", value: t.ekfCompassVar, maxValue: 1, warn: 0.5, bad: 0.8)
                        MetricBar(title: "Terrain", value: t.ekfTerrainVar, maxValue: 1, warn: 0.5, bad: 0.8)
                    }
                    Text("Менше 0.5: добре, 0.5–0.8: увага, понад 0.8: фільтр не довіряє датчику.").font(.caption).foregroundStyle(.secondary)
                }
                StatusSection(title: "Flags") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 6)], spacing: 6) {
                        ForEach(Self.flags, id: \.0) { f in FlagChip(name: f.1, on: (t.ekfFlags & f.0) != 0, required: f.2) }
                    }
                    Text(lk(s.connected ? "Дані EKF_STATUS_REPORT" : "Немає зв'язку з польотником")).font(.caption).foregroundStyle(.secondary)
                }
            }.padding(14)
        }
    }
}

/// Панель «Vibration»: рівні вібрації по осях і лічильники кліппінгу.
struct VibrationPanel: View {
    @Environment(Store.self) var s

    var body: some View {
        let t = s.t
        let worst = max(t.vibeX, t.vibeY, t.vibeZ)
        let badge: (String, Color) = !s.connected ? ("Немає зв'язку", .secondary) : (worst >= 60 ? ("Небезпечно", .red) : (worst >= 30 ? ("Підвищена", .orange) : ("Норма", .green)))
        ScrollView {
            HStack(alignment: .top, spacing: 14) {
                StatusSection(title: "Vibration, m/s²", badge: badge) {
                    VStack(spacing: 12) {
                        MetricBar(title: "X", value: t.vibeX, maxValue: 90, warn: 30, bad: 60)
                        MetricBar(title: "Y", value: t.vibeY, maxValue: 90, warn: 30, bad: 60)
                        MetricBar(title: "Z", value: t.vibeZ, maxValue: 90, warn: 30, bad: 60)
                    }
                    Text("Норма: до 30 м/с². Понад 60 небезпечно для польоту.").font(.caption).foregroundStyle(.secondary)
                }
                StatusSection(title: "Clipping") {
                    VStack(spacing: 8) {
                        clip("Primary", t.vibeClip0)
                        clip("Secondary", t.vibeClip1)
                        clip("Tertiary", t.vibeClip2)
                    }
                    Text("Лічильник лише зростає: важливе його швидке збільшення в польоті.").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(14)
        }
    }

    func clip(_ title: String, _ v: Double) -> some View {
        HStack {
            Text(lk(title)).font(.callout)
            Spacer()
            Text(String(Int(v))).font(.callout.monospacedDigit().weight(.medium)).foregroundStyle(v > 0 ? Color.red : Color.secondary)
                .padding(.horizontal, 10).padding(.vertical, 2).background((v > 0 ? Color.red : Color.gray).opacity(0.15), in: Capsule())
        }
    }
}

/// Окреме вікно «EKF Status».
struct EKFStatusView: View {
    var body: some View { EKFPanel().frame(minWidth: 640, minHeight: 360) }
}

/// Окреме вікно «Vibration».
struct VibrationView: View {
    var body: some View { VibrationPanel().frame(minWidth: 560, minHeight: 320) }
}
