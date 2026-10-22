import SwiftUI

/// Flight Modes: шість режимів за положенням перемикача, Simple/Super Simple та функції каналів 7–12.
struct FlightModesView: View {
    @Environment(Store.self) var s
    @State private var io = IOStore()
    var ps: ParamStore { s.ps }

    static let ranges = ["≤ 1230", "1231–1360", "1361–1490", "1491–1620", "1621–1749", "≥ 1750"]

    var chan: Int { Int(ps.val("FLTMODE_CH") ?? 5) }
    var pwm: Int { let rc = io.io?.rc ?? []; return chan >= 1 && chan <= rc.count ? rc[chan - 1] : 0 }
    /// Слот режиму за PWM (пороги ArduPilot).
    var active: Int? {
        let p = pwm
        if p == 0 { return nil }
        return p < 1231 ? 1 : p < 1361 ? 2 : p < 1491 ? 3 : p < 1621 ? 4 : p < 1750 ? 5 : 6
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                OfflineBanner()
                if !s.canView {
                    ContentUnavailableView("Польотник не підключений", systemImage: "cable.connector", description: Text("Підключіть плату по USB"))
                } else if ps.params.isEmpty {
                    ProgressView("Завантаження параметрів…")
                } else if !ps.has("FLTMODE1") {
                    ContentUnavailableView("Недоступно", systemImage: "airplane", description: Text("Параметри FLTMODE відсутні."))
                } else {
                    if s.armedLive { Label("Апарат ARMED: редагування заблоковано", systemImage: "lock.fill").foregroundStyle(.red) }
                    modesCard
                    ModeAdvancedCard(slots: (1...6).map { Int(ps.val("FLTMODE\($0)") ?? 0) }, activeSlot: active)
                    channelsCard
                }
            }
            .padding()
        }
        .onAppear { io.start() }
        .onDisappear { io.stop() }
    }

    var modesCard: some View {
        Card(title: String(localized: "Режими польоту"), icon: "airplane", text: String(localized: "Режим вибирається положенням перемикача на каналі \(chan). Поточний слот підсвічується за сигналом приймача.")) {
            HStack(spacing: 12) {
                Text("Канал режимів").font(.callout)
                OptionPicker(name: "FLTMODE_CH", width: 150)
                Spacer()
                Label(lk(pwm == 0 ? "сигналу немає" : "PWM \(String(pwm))"), systemImage: "dot.radiowaves.left.and.right")
                    .font(.caption.monospacedDigit()).foregroundStyle(pwm == 0 ? Color.secondary : Color.green)
            }
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Text("Слот").frame(width: 50, alignment: .leading)
                    Text("PWM").frame(width: 100, alignment: .leading)
                    Text("Режим").frame(width: 220, alignment: .leading)
                    Spacer(minLength: 0)
                }
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.vertical, 6)
                Divider()
                ForEach(1...6, id: \.self) { i in
                    let on = active == i
                    HStack(spacing: 12) {
                        HStack(spacing: 4) {
                            Circle().fill(on ? Color.green : Color.clear).frame(width: 8, height: 8)
                            Text("\(i)").font(.system(.body, design: .monospaced).weight(.semibold))
                        }.frame(width: 50, alignment: .leading)
                        Text(lk(Self.ranges[i - 1])).font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary).frame(width: 100, alignment: .leading)
                        OptionPicker(name: "FLTMODE\(i)", width: 220)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 6)
                    .background(on ? Color.green.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 6))
                    Divider().opacity(0.4)
                }
            }
        }
    }

    var channelsCard: some View {
        let list = (5...24).filter { ps.has("RC\($0)_OPTION") }
        return Card(title: String(localized: "Функції каналів"), icon: "switch.2", text: String(localized: "Перемикачі приймача (RCn_OPTION, до 24 каналів, скільки підтримує прошивка): фото, ARM, RTL, автотюн тощо.")) {
            if list.isEmpty { Text("Немає параметрів RCn_OPTION").foregroundStyle(.secondary) }
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                ForEach(list, id: \.self) { n in
                    GridRow {
                        Text("Канал \(n)").font(.callout)
                        OptionPicker(name: "RC\(n)_OPTION", width: 280)
                        let rc = io.io?.rc ?? []
                        Text(lk(n <= rc.count && rc[n - 1] > 0 ? String(rc[n - 1]) : "—")).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}
