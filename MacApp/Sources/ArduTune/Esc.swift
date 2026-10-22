import SwiftUI

/// ESC Calibration: підготовка автокалібрування регуляторів (ESC_CALIBRATION) за процедурою ArduCopter.
struct EscView: View {
    @Environment(Store.self) var s
    @State private var done = false
    var ps: ParamStore { s.ps }
    /// Префікс параметрів моторів: MOT_ (Copter/Heli) або Q_M_ (VTOL-мотори QuadPlane); nil, якщо моторів-мультикоптерів немає.
    var pfx: String? { ps.has("MOT_PWM_TYPE") || ps.has("MOT_PWM_MIN") ? "MOT_" : (ps.has("Q_M_PWM_TYPE") || ps.has("Q_M_PWM_MIN") ? "Q_M_" : nil) }
    var pwmType: Int { Int(ps.val((pfx ?? "MOT_") + "PWM_TYPE") ?? 0) }
    var digital: Bool { pwmType >= 4 }          // DShot / ProShot: калібрування не потрібне
    var cur: Int { Int(ps.val("ESC_CALIBRATION") ?? 0) }

    /// Опис параметра українською (назва + пояснення) для правої колонки.
    func paramDesc(_ n: String) -> some View {
        let ua = ParamTexts.info(n)
        return VStack(alignment: .leading, spacing: 2) {
            Text(lk(ua?.title ?? ps.meta[n]?.label ?? n)).font(.callout.weight(.medium))
            if let t = ua?.text { Text(LocalizedStringKey(t)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var typeCard: some View {
        Card(title: String(localized: "Протокол регуляторів"), icon: "bolt.horizontal", text: nil) {
            Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 10) {
                GridRow {
                    Text(lk((pfx ?? "MOT_") + "PWM_TYPE")).font(.system(.body, design: .monospaced))
                    OptionPicker(name: (pfx ?? "MOT_") + "PWM_TYPE", width: 240)
                    paramDesc((pfx ?? "MOT_") + "PWM_TYPE")
                }
            }
            if digital {
                Label("Використовується цифровий протокол (DShot/ProShot). Калібрування PWM-діапазону не потрібне.", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
            } else {
                Text("Аналоговий PWM: регулятори потрібно калібрувати на діапазон сигналу автопілота.").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    var rangeCard: some View {
        Card(title: String(localized: "Діапазон і старт моторів"), icon: "slider.horizontal.3", text: nil) {
            Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 10) {
                ForEach(["PWM_MIN", "PWM_MAX", "SAFE_DISARM", "SPIN_ARM", "SPIN_MIN", "SPIN_MAX", "SPOOL_TIME", "SLEW_UP_TIME", "SLEW_DN_TIME"].map { (pfx ?? "MOT_") + $0 }.filter { ps.has($0) }, id: \.self) { n in
                    GridRow {
                        Text(LocalizedStringKey(n)).font(.system(.body, design: .monospaced)).gridColumnAlignment(.leading)
                        Group {
                            if n.hasSuffix("SAFE_DISARM") { OptionPicker(name: n, width: 240) } else { ParamField(name: n, width: 80) }
                        }.gridColumnAlignment(.leading)
                        paramDesc(n)
                    }
                }
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                OfflineBanner()
                if !s.canView {
                    ContentUnavailableView("Польотник не підключений", systemImage: "cable.connector", description: Text("Підключіть плату по USB"))
                } else if ps.params.isEmpty {
                    ProgressView("Завантаження параметрів…")
                } else if !ps.has("ESC_CALIBRATION") {
                    if pfx != nil {
                        Label(lk(pfx == "Q_M_" ? "VTOL-мотори QuadPlane (параметри Q_M_*). Калібрування ESC (ESC_CALIBRATION) у цій прошивці недоступне." : "Калібрування ESC (ESC_CALIBRATION) у цій прошивці недоступне."), systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
                        typeCard
                        rangeCard
                    } else {
                        ContentUnavailableView("Калібрування ESC недоступне", systemImage: "bolt.slash", description: Text("ESC_CALIBRATION відсутній у цій прошивці. Конфігуратор AM32 нижче доступний."))
                    }
                    AM32Card()
                } else {
                    if s.armedLive { Label("Апарат ARMED: калібрування заблоковано", systemImage: "lock.fill").foregroundStyle(.red) }
                    typeCard
                    rangeCard
                    Card(title: String(localized: "Калібрування ESC"), icon: "bolt.fill", text: nil) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("1. Натисніть «Підготувати» нижче (ESC_CALIBRATION = 3).")
                            Text("2. Повністю відключіть живлення: USB і батарею.")
                            Text("3. Підключіть USB, потім батарею. Автопілот подасть максимум, потім мінімум газу, регулятори просигналізують.")
                            Text("4. Після завершення (звуки регуляторів) відключіть живлення й підключіть знову. Параметр скинеться сам.")
                        }.font(.callout)
                        HStack {
                            Button("Підготувати калібрування") { ps.write("ESC_CALIBRATION", 3); done = true }.buttonStyle(.borderedProminent).tint(.orange)
                                .disabled(s.armed || digital)
                            if cur == 3 { Label("ESC_CALIBRATION = 3: калібрування виконається при наступному живленні", systemImage: "checkmark.circle.fill").foregroundStyle(.orange) }
                            if cur != 0 && cur != 3 { Text("ESC_CALIBRATION = \(cur)").font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            if cur != 0 { Button("Скасувати (0)") { ps.write("ESC_CALIBRATION", 0); done = false } }
                        }
                    }
                    AM32Card()
                }
            }
            .padding()
        }
    }
}
