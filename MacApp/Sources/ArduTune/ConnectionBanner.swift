import SwiftUI

/// Прогрес підключення до польотника: двигун → зв'язок → параметри → описи.
struct ConnectionBanner: View {
    @Environment(Store.self) var s
    @State private var hideDone = false

    enum Stage { case engine, off, waiting, connecting, link, booting, params(Int, Int), meta, ready }

    var stage: Stage {
        if !s.engineUp { return .engine }
        if !s.t.replaying {
            switch s.t.linkState ?? "searching" {
            case "disconnected": return .off
            case "searching": return .waiting
            case "connecting": return .connecting
            default: break
            }
        }
        if !s.connected { return .link }
        if s.t.booting == true { return .booting }
        let ps = s.ps
        if ps.loading || ps.received < ps.count || ps.count == 0 { return .params(ps.received, ps.count) }
        if ps.meta.isEmpty { return .meta }
        return .ready
    }

    var step: Int {
        switch stage { case .engine: return 0; case .off: return 0; case .waiting: return 0; case .connecting: return 1; case .link: return 1; case .booting: return 1; case .params: return 2; case .meta: return 3; case .ready: return 4 }
    }

    var body: some View {
        Group {
            if case .ready = stage { Color.clear.frame(height: 0) } else { banner }
        }
        .animation(.easeInOut(duration: 0.25), value: step)
    }

    var banner: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                ForEach(Array(["Двигун", "З'єднання", "Параметри", "Описи"].enumerated()), id: \.offset) { i, name in
                    HStack(spacing: 5) {
                        Image(systemName: i < step ? "checkmark.circle.fill" : (i == step ? "circle.dotted" : "circle"))
                            .foregroundStyle(i < step ? Color.green : (i == step ? Color.accentColor : Color.secondary))
                        Text(LocalizedStringKey(name)).font(.caption.weight(i == step ? .semibold : .regular)).foregroundStyle(i <= step ? .primary : .secondary)
                    }
                    if i < 3 { Rectangle().fill(.quaternary).frame(width: 18, height: 1) }
                }
                Spacer()
                Text(LocalizedStringKey(title)).font(.caption).foregroundStyle(.secondary)
            }
            switch stage {
            case .params(let r, let c):
                ProgressView(value: Double(r), total: Double(max(c, 1))) {
                    Text("Завантаження параметрів \(r) / \(c)").font(.caption.monospacedDigit())
                }
            case .engine, .link, .meta, .connecting, .booting:
                ProgressView().progressViewStyle(.linear)
            default: EmptyView()
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) { Divider() }
    }

    var title: String {
        switch stage {
        case .engine: return "Запуск двигуна…"
        case .off: return "Відключено. Натисніть Connect угорі"
        case .waiting: return (s.t.linkType == "auto" || s.t.linkType == nil) ? "Підключіть польотник по USB" : String(localized: "Повторне підключення… \(s.t.linkError ?? "")")
        case .connecting: return "Підключення…"
        case .link: return "Очікування відповіді польотника (MAVLink)…"
        case .booting: return "Польотник завантажується (ArduPilot ініціалізується), чекаємо…"
        case .params: return "Читання параметрів"
        case .meta: return "Завантаження описів параметрів…"
        case .ready: return ""
        }
    }
}
