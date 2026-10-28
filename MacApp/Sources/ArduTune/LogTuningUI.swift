import SwiftUI

// MARK: - Інтерфейс рекомендованих змін


/// Блок «Рекомендовані зміни» під спостереженням помічника: поточне й нове значення, пояснення, кнопка запису в польотник.
struct ChangesBlock: View {
    @Environment(Store.self) var s
    let log: DFLog
    let changes: [ParamChange]
    @State private var done: Set<String> = []

    private func logValue(_ n: String) -> Double? { log.parameters.first { $0.name == n }?.value }
    private func current(_ n: String) -> Double? { s.connected ? (s.ps.val(n) ?? logValue(n)) : logValue(n) }
    private func fmtV(_ n: String, _ v: Double) -> String {
        let isInt = s.ps.find(n)?.isInt ?? (v == v.rounded() && abs(v) < 1e6)
        return isInt ? String(Int(v.rounded())) : String(format: "%.4g", v)
    }
    private func proposed(_ c: ParamChange) -> Double? {
        guard let cur = current(c.name) else { if case .set(let v) = c.op { return v }; return nil }
        var v = c.proposed(from: cur)
        if let m = s.ps.meta[c.name] { if let lo = m.min { v = max(v, lo) }; if let hi = m.max { v = min(v, hi) } }
        // три значущі цифри для дробових, цілі для цілих
        if s.ps.find(c.name)?.isInt ?? false { v = v.rounded() } else if abs(v) > 0 { let d = pow(10, floor(log10(abs(v))) - 2); v = (v / d).rounded() * d }
        return v
    }
    private var canWrite: Bool { s.connected && !s.armedLive }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("РЕКОМЕНДОВАНІ ЗМІНИ").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if changes.count > 1 {
                    Button("Застосувати всі") { for c in changes { apply(c) } }.controlSize(.small).disabled(!canWrite || changes.allSatisfy { done.contains($0.name) })
                }
            }
            ForEach(changes) { c in
                let cur = current(c.name), new = proposed(c)
                let exists = s.connected ? s.ps.has(c.name) : true
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text(LocalizedStringKey(c.name)).font(.system(.callout, design: .monospaced).weight(.semibold))
                            if let cur, let new {
                                Text("\(fmtV(c.name, cur))  →  \(fmtV(c.name, new))").font(.system(.callout, design: .monospaced))
                                if case .scale(let k) = c.op, cur != 0 { Text(String(format: "%+.0f %%", (k - 1) * 100)).font(.caption.weight(.semibold)).foregroundStyle(k < 1 ? Color.orange : Color.green) }
                            } else if let new { Text("→ \(fmtV(c.name, new))").font(.system(.callout, design: .monospaced)) }
                            if s.ps.meta[c.name]?.reboot == true { Text("потрібне перезавантаження").font(.caption2).padding(.horizontal, 6).padding(.vertical, 1).background(Color.orange.opacity(0.2), in: Capsule()) }
                        }
                        Text(LocalizedStringKey(c.why)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if cur != nil, s.connected, logValue(c.name) != nil, let l = logValue(c.name), let v = s.ps.val(c.name), abs(l - v) > 1e-9 * max(1, abs(l)) {
                            Text("У логу було \(fmtV(c.name, l)); на польотнику зараз \(fmtV(c.name, v)): нове значення пораховано від поточного.").font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    Spacer(minLength: 8)
                    if done.contains(c.name) {
                        Label("записано", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                    } else {
                        Button("Застосувати") { apply(c) }.controlSize(.small).disabled(!canWrite || !exists || new == nil)
                            .tip(!s.connected ? "Підключіть польотник, щоб записати значення" : (s.armedLive ? "Апарат ARMED" : (!exists ? "У цій прошивці немає такого параметра" : "Записати нове значення в польотник")))
                    }
                }
                .padding(8).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            if !s.connected { Label("Польотник не підключений: значення показано за логом. Підключіть плату, щоб записати зміни.", systemImage: "cable.connector").font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func apply(_ c: ParamChange) {
        guard canWrite, let v = proposed(c), let p = s.ps.find(c.name) else { return }
        s.ps.set(p, to: v)
        done.insert(c.name)
    }
}
