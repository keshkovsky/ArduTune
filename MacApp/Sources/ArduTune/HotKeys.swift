import SwiftUI
import AppKit

enum HKScope: String { case flight, mission }

struct HKAction: Identifiable {
    let id: String
    let scope: HKScope
    let title: String
    let def: Int            // фізичний код клавіші (ANSI), не залежить від розкладки
}

/// Гарячі клавіші карт (Flight Data і Mission): без модифікаторів, змінюються в Налаштуваннях.
/// Зберігається фізичний код клавіші, тому працює в будь-якій розкладці (укр/англ).
@Observable
final class HotKeys {
    static let shared = HotKeys()
    private static let key = "hotkeys.v1"

    static let actions: [HKAction] = [
        HKAction(id: "fd.ruler", scope: .flight, title: "Лінійка: увімкнути/вимкнути", def: 15),
        HKAction(id: "fd.track", scope: .flight, title: "Показувати трек", def: 17),
        HKAction(id: "fd.clearTrack", scope: .flight, title: "Очистити трек", def: 8),
        HKAction(id: "fd.center", scope: .flight, title: "Центр на дроні", def: 49),
        HKAction(id: "fd.autopan", scope: .flight, title: "Auto Pan", def: 35),
        HKAction(id: "fd.zoomIn", scope: .flight, title: "Масштаб +", def: 24),
        HKAction(id: "fd.zoomOut", scope: .flight, title: "Масштаб −", def: 27),
        HKAction(id: "fd.rotL", scope: .flight, title: "Повернути карту на 15° ліворуч", def: 33),
        HKAction(id: "fd.rotR", scope: .flight, title: "Повернути карту на 15° праворуч", def: 30),
        HKAction(id: "fd.north", scope: .flight, title: "Північ угору", def: 45),
        HKAction(id: "ms.select", scope: .mission, title: "Режим «Вибір»", def: 9),
        HKAction(id: "ms.add", scope: .mission, title: "Режим «Додавання»", def: 0),
        HKAction(id: "ms.ruler", scope: .mission, title: "Режим «Лінійка»", def: 15),
    ]

    /// Клавіші, які вже зайняті (стрілки й Return керують трекером, Esc/Delete — редагуванням).
    static let reserved: Set<Int> = [53, 51, 117, 36, 76, 123, 124, 125, 126]

    /// Підписи для типових клавіш (ANSI).
    static let usLabels: [Int: String] = [0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P",
        37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 49: "␣"]

    private struct Saved: Codable { var codes: [String: Int]; var labels: [String: String] }
    var codes: [String: Int] = [:]          // перевизначення; -1 = без клавіші
    var labels: [String: String] = [:]      // підпис, який бачив користувач при призначенні (розкладка)

    init() {
        if let d = UserDefaults.standard.data(forKey: Self.key), let s = try? JSONDecoder().decode(Saved.self, from: d) { codes = s.codes; labels = s.labels }
    }
    private func save() {
        if let d = try? JSONEncoder().encode(Saved(codes: codes, labels: labels)) { UserDefaults.standard.set(d, forKey: Self.key) }
    }

    func code(_ a: HKAction) -> Int { codes[a.id] ?? a.def }
    func label(_ a: HKAction) -> String {
        let c = code(a)
        if c < 0 { return "—" }
        return labels[a.id] ?? Self.usLabels[c] ?? "#\(c)"
    }
    var isDefault: Bool { codes.isEmpty }

    /// Дія для натиснутої клавіші в цьому розділі (без модифікаторів).
    func action(for e: NSEvent, scope: HKScope) -> HKAction? {
        guard e.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty, !e.isARepeat else { return nil }
        let c = Int(e.keyCode)
        return Self.actions.first { $0.scope == scope && code($0) == c }
    }

    /// Призначає клавішу; повертає назву дії-конфлікту, якщо клавіша зайнята (тоді не змінюється).
    func assign(_ a: HKAction, e: NSEvent) -> String? {
        let c = Int(e.keyCode)
        if Self.reserved.contains(c) { return String(localized: "ця клавіша зарезервована") }
        if let o = Self.actions.first(where: { $0.scope == a.scope && $0.id != a.id && code($0) == c }) { return o.title }
        codes[a.id] = c
        labels[a.id] = c == 49 ? "␣" : (e.charactersIgnoringModifiers?.uppercased() ?? Self.usLabels[c] ?? "#\(c)")
        save(); return nil
    }
    func clear(_ a: HKAction) { codes[a.id] = -1; labels[a.id] = nil; save() }
    func reset(_ a: HKAction) { codes[a.id] = nil; labels[a.id] = nil; save() }
    func resetAll() { codes = [:]; labels = [:]; UserDefaults.standard.removeObject(forKey: Self.key) }
}

/// Картка «Гарячі клавіші» в Налаштуваннях.
struct HotKeysCard: View {
    private var hk: HotKeys { HotKeys.shared }
    @State private var recording: String?
    @State private var monitor: Any?
    @State private var message: String?

    var body: some View {
        Card(title: String(localized: "Гарячі клавіші"), icon: "keyboard", text: String(localized: "Клавіші карт без модифікаторів. Працюють, коли відкрито Flight Data чи Mission і фокус не в текстовому полі. Натисніть на клавішу в рядку й натисніть нову; Esc скасовує. Esc також закриває лінійку, Delete видаляє вибрану точку, стрілки й Return керують трекером.")) {
            ForEach([HKScope.flight, .mission], id: \.self) { scope in
                Text(scope == .flight ? "Flight Data" : "Mission").font(.subheadline.weight(.semibold)).padding(.top, scope == .flight ? 0 : 6)
                ForEach(HotKeys.actions.filter { $0.scope == scope }) { a in
                    HStack {
                        Text(lk(a.title)).font(.callout)
                        Spacer()
                        Button { start(a) } label: {
                            Text(recording == a.id ? loc("натисніть клавішу…") : hk.label(a))
                                .font(.system(.callout, design: .monospaced).weight(.semibold))
                                .frame(minWidth: 96).padding(.vertical, 3)
                                .background(recording == a.id ? Color.accentColor.opacity(0.25) : Color.gray.opacity(0.18), in: RoundedRectangle(cornerRadius: 6))
                        }.buttonStyle(.plain)
                        Button { hk.reset(a) } label: { Image(systemName: "arrow.uturn.backward") }.buttonStyle(.borderless).help("Типова клавіша").disabled(hk.codes[a.id] == nil)
                        Button { hk.clear(a) } label: { Image(systemName: "xmark.circle") }.buttonStyle(.borderless).help("Прибрати клавішу")
                    }
                }
            }
            HStack {
                if let m = message { Label(lk(m), systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
                Spacer()
                Button("Скинути всі") { hk.resetAll() }.controlSize(.small).disabled(hk.isDefault)
            }
        }
        .onDisappear { stop() }
    }

    private func start(_ a: HKAction) {
        stop(); message = nil; recording = a.id
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == 53 { stop(); return nil }
            if let c = hk.assign(a, e: e) { message = String(localized: "Не призначено: \(loc(c))") } else { message = nil }
            stop(); return nil
        }
    }
    private func stop() {
        recording = nil
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }
}
