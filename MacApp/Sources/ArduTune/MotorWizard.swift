import SwiftUI

/// Стан майстра визначення моторів (як у Betaflight): мотори крутяться по черзі, користувач тисне на схемі той, що обертається.
@Observable
final class MotorWizardStore {
    var step: Int?
    var picks: [Int: Int] = [:]      // логічний мотор, що крутився -> мотор, якого обрав користувач
    var orig: [Int: Int] = [:]       // логічний мотор -> початковий вихід SERVO
    var note: String?
    var done = false
    var minSpin = true
    var throttle = 5.0

    var eff: Double { minSpin ? 5 : throttle }

    func fnCode(_ n: Int) -> Int { n <= 8 ? 32 + n : 82 + (n - 9) }
    func motors(_ ps: ParamStore) -> [MotorDef] {
        let fc = Int(ps.val("FRAME_CLASS") ?? 0), ft = Int(ps.val("FRAME_TYPE") ?? 1)
        return (motorLayouts["\(fc)"]?["\(ft)"] ?? []).sorted { $0.o < $1.o }
    }
    func output(_ ps: ParamStore, _ n: Int) -> Int? {
        let fn = fnCode(n)
        return (1...32).first { Int(ps.val("SERVO\($0)_FUNCTION") ?? -99) == fn }
    }
    func letter(_ o: Int) -> String { String(UnicodeScalar(UInt8(64 + max(1, min(o, 26))))) }

    func start(_ s: Store) {
        let ord = motors(s.ps)
        var o: [Int: Int] = [:]
        for m in ord {
            guard let out = output(s.ps, m.n) else { note = String(localized: "Для M\(m.n) не призначено вихід SERVO. Призначте його в таблиці «Відповідність моторів»."); return }
            o[m.n] = out
        }
        orig = o; picks = [:]; done = false; note = nil; step = 0
        spin(s)
    }
    func spin(_ s: Store) {
        let ord = motors(s.ps)
        guard let i = step, i < ord.count else { return }
        EngineAPI.post("/motor/test?motor=\(ord[i].o)&throttle=\(eff)&timeout=10&count=1&order=1") { [self] ok, e in
            if !ok { note = e == "armed" ? "Апарат ARMED" : "Помилка команди тесту" }
        }
    }
    func cancel() {
        if step != nil { EngineAPI.post("/motor/stop") }
        step = nil; picks = [:]; done = false
    }
    func pick(_ s: Store, _ x: MotorDef) {
        let ord = motors(s.ps)
        guard let i = step, i < ord.count else { return }
        if picks.values.contains(x.n) { note = String(localized: "M\(x.n) уже обрано"); return }
        note = nil
        picks[ord[i].n] = x.n
        EngineAPI.post("/motor/stop")
        if i + 1 < ord.count {
            step = i + 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [self] in spin(s) }
        } else {
            apply(s)
        }
    }
    func apply(_ s: Store) {
        var changed = 0
        for (spun, x) in picks {
            guard let out = orig[spun], spun != x else { continue }
            s.ps.write("SERVO\(out)_FUNCTION", Double(fnCode(x))); changed += 1
        }
        step = nil; done = true
        note = changed == 0 ? "Відповідність уже коректна, змін немає." : String(localized: "Застосовано: змінено \(changed) виходів SERVO.")
    }
}

struct MotorWizardWindow: View {
    @Environment(Store.self) var s
    var w: MotorWizardStore { s.wizard }

    var body: some View {
        @Bindable var w = s.wizard
        let ord = w.motors(s.ps)
        let badges: [Int: String] = Dictionary(uniqueKeysWithValues: w.picks.compactMap { spun, x in
            ord.first(where: { $0.n == spun }).map { (x, w.letter($0.o)) }
        })
        VStack(spacing: 14) {
            Label("Майстер визначення моторів", systemImage: "hand.tap.fill").font(.title3.weight(.semibold))
            if !s.connected {
                ContentUnavailableView("Польотник не підключений", systemImage: "cable.connector")
            } else if ord.isEmpty {
                ContentUnavailableView("Схема недоступна", systemImage: "info.circle", description: Text("Для цієї рами немає матричної розкладки."))
            } else {
                if s.armed { Label("Апарат ARMED: майстер заблоковано", systemImage: "lock.fill").foregroundStyle(.red) }
                FrameScheme(motors: ord, selected: nil, badges: badges, onTap: { m in
                    guard !s.armed else { return }
                    w.pick(s, m)
                })
                .frame(width: 400, height: 400)

                if let i = w.step {
                    VStack(spacing: 8) {
                        ProgressView(value: Double(i), total: Double(ord.count))
                        Text("Крок \(i + 1) з \(ord.count): подивіться, який мотор обертається, і натисніть його на схемі.").font(.callout.weight(.medium)).multilineTextAlignment(.center)
                        Text(lk(loc("Обрано: ") + (w.picks.isEmpty ? "—" : ord.prefix(i).compactMap { m in w.picks[m.n].map { "\(w.letter(m.o))→M\($0)" } }.joined(separator: "  ")))).font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Button("Крутити ще раз") { w.spin(s) }
                        Button("Скасувати") { w.cancel() }
                    }
                } else {
                    Text(lk(w.done ? "Готово." : "Мотори крутитимуться по черзі на мінімальних обертах. Для кожного натисніть на схемі мотор, який обертається фізично. Без пропелерів!"))
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    HStack(spacing: 16) {
                        Toggle("Мінімальні оберти (5%)", isOn: $w.minSpin)
                        Button { w.start(s) } label: { Label(lk(w.done ? "Повторити" : "Почати"), systemImage: "play.fill") }
                            .buttonStyle(.borderedProminent).disabled(s.armed)
                    }
                }
                if let n = w.note { Text(LocalizedStringKey(n)).font(.caption).foregroundStyle(.orange).multilineTextAlignment(.center) }
            }
        }
        .padding(20).frame(width: 460)
        .onDisappear { w.cancel() }
    }
}
