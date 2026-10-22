import Foundation
import AppKit
import SwiftUI

/// Мова інтерфейсу: українська (типова; тексти в коді) або англійська (переклад у `en.lproj/Localizable.strings`).
/// Мова застосовується при запуску через `AppleLanguages`, тому після зміни застосунок перезапускається.
enum AppLanguage {
    /// Вибір користувача (Налаштування); без нього: українська або російська мова macOS → українська, інакше англійська.
    static var current: String { UserDefaults.standard.string(forKey: "app.lang") ?? systemDefault }
    static let systemDefault: String = {
        let langs = CFPreferencesCopyValue("AppleLanguages" as CFString, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String] ?? Locale.preferredLanguages
        let first = (langs.first ?? "en").lowercased()
        return first.hasPrefix("uk") || first.hasPrefix("ru") ? "uk" : "en"
    }()
    static var isEnglish: Bool { current == "en" }

    /// Викликати на самому початку запуску.
    static func applyAtLaunch() {
        UserDefaults.standard.set([current], forKey: "AppleLanguages")
    }

    /// Змінює мову й пропонує перезапуск.
    @MainActor static func change(to lang: String) {
        guard lang != current else { return }
        UserDefaults.standard.set(lang, forKey: "app.lang")
        UserDefaults.standard.set([lang], forKey: "AppleLanguages")
        let a = NSAlert()
        a.messageText = lang == "en" ? "Restart to switch to English?" : "Перезапустити, щоб перейти на українську?"
        a.informativeText = lang == "en" ? "The interface language changes after ArduTune restarts." : "Мова інтерфейсу зміниться після перезапуску ArduTune."
        a.addButton(withTitle: lang == "en" ? "Restart" : "Перезапустити")
        a.addButton(withTitle: lang == "en" ? "Later" : "Пізніше")
        if a.runModal() == .alertFirstButtonReturn { relaunch() }
    }

    @MainActor static func relaunch() {
        let url = URL(fileURLWithPath: Bundle.main.bundlePath)
        let cfg = NSWorkspace.OpenConfiguration(); cfg.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}

/// Переклад рядка, відомого лише під час виконання (меню, діалоги, повідомлення): ключ = український текст.
func tr(_ s: String) -> String { NSLocalizedString(s, comment: "") }

/// Ключ локалізації з рядка, відомого лише під час виконання (для `Text`, `Label` тощо): не знайдено → лишається оригінал.
func lk(_ s: String) -> LocalizedStringKey { LocalizedStringKey(smart(s)) }
/// Те саме, що `tr`, але з іншою назвою (у деяких файлах `tr` затінено локальною змінною).
func loc(_ s: String) -> String { smart(s) }
/// Для інтерполяцій невідомого типу: не рядок лишається без змін.
func loc<T>(_ v: T) -> T { v }

/// Переклад із запасним розбиттям складених рядків («Ключ: значення», «А · Б», «А — Б»): кожна частина шукається окремо.
func smart(_ s: String) -> String {
    if !AppLanguage.isEnglish || s.isEmpty { return s }
    let miss = "\u{1}"
    let whole = NSLocalizedString(s, value: miss, comment: "")
    if whole != miss { return whole }
    for sep in [": ", " · ", " — ", " / ", ", "] {
        guard let r = s.range(of: sep) else { continue }
        let a = String(s[..<r.lowerBound]), b = String(s[r.upperBound...])
        let ta = NSLocalizedString(a, value: miss, comment: ""), tb = smart(b)
        if ta != miss || tb != b { return (ta == miss ? a : ta) + sep + tb }
    }
    return s
}
