import SwiftUI
import AppKit

/// Підключення до конфігуратора AM32 (і BLHeli) через прохід (passthrough) польотного контролера по USB.
/// Конфігуратор потребує ексклюзивного доступу до USB-порту, тому застосунок тимчасово звільняє порт.
struct AM32Card: View {
    @Environment(Store.self) var s
    @AppStorage("am32.url") private var url = "https://am32.ca"
    @AppStorage("am32.app") private var localApp = ""
    @State private var released = false
    @State private var note: String?
    var ps: ParamStore { s.ps }

    static let browsers: [(String, String)] = [("Google Chrome", "com.google.Chrome"), ("Microsoft Edge", "com.microsoft.edgemac"), ("Brave", "com.brave.Browser"), ("Chromium", "org.chromium.Chromium")]
    var webSerialBrowser: (String, URL)? {
        for b in Self.browsers { if let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: b.1) { return (b.0, u) } }
        return nil
    }

    /// Вихідні канали з функціями моторів/газу (для SERVO_BLH_MASK).
    var motorMask: Int {
        var m = 0
        for n in 1...32 {
            let f = Int(ps.val("SERVO\(n)_FUNCTION") ?? 0)
            if (33...40).contains(f) || (82...85).contains(f) || f == 70 || f == 73 || f == 74 { m |= 1 << (n - 1) }
        }
        return m
    }

    var body: some View {
        Card(title: String(localized: "AM32 / BLHeli: конфігуратор регуляторів"), icon: "cpu", text: String(localized: "Налаштування регуляторів з прошивкою AM32 (або BLHeli) через польотний контролер: автопілот пропускає сигнал з USB на лінію регулятора. Потрібне живлення регуляторів від батареї.")) {
            // Готовність
            VStack(alignment: .leading, spacing: 6) {
                Text("ГОТОВНІСТЬ ПЛАТИ").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                if ps.has("SERVO_BLH_AUTO") {
                    HStack {
                        Image(systemName: (ps.val("SERVO_BLH_AUTO") ?? 0) > 0 ? "checkmark.circle.fill" : "exclamationmark.circle.fill").foregroundStyle((ps.val("SERVO_BLH_AUTO") ?? 0) > 0 ? .green : .orange)
                        Text("SERVO_BLH_AUTO").font(.system(.callout, design: .monospaced))
                        Text(lk((ps.val("SERVO_BLH_AUTO") ?? 0) > 0 ? "автовизначення моторів увімкнено" : "вимкнено: канали для проходу не будуть вибрані автоматично")).font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        if (ps.val("SERVO_BLH_AUTO") ?? 0) == 0 { Button("Увімкнути") { ps.write("SERVO_BLH_AUTO", 1) }.disabled(s.armed) }
                    }
                } else {
                    Label("Параметрів SERVO_BLH_* немає: у цій прошивці прохід BLHeli/AM32 недоступний.", systemImage: "xmark.octagon.fill").foregroundStyle(.red).font(.callout)
                }
                if ps.has("SERVO_BLH_MASK") {
                    let cur = Int(ps.val("SERVO_BLH_MASK") ?? 0)
                    HStack {
                        Image(systemName: cur != 0 ? "checkmark.circle.fill" : "info.circle").foregroundStyle(cur != 0 ? .green : .secondary)
                        Text("SERVO_BLH_MASK = \(cur)").font(.system(.callout, design: .monospaced))
                        Text("канали з моторами за SERVOx_FUNCTION: \(motorMask)").font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        if cur != motorMask && motorMask != 0 { Button("Підставити маску") { ps.write("SERVO_BLH_MASK", Double(motorMask)) }.disabled(s.armed) }
                    }
                }
                ForEach(["SERVO_BLH_PORT", "SERVO_BLH_OTYPE", "SERVO_BLH_POLES", "SERVO_BLH_TRATE"].filter { ps.has($0) }, id: \.self) { AdvParamRow(name: $0, describe: true) }
            }
            Divider()
            // Кроки
            VStack(alignment: .leading, spacing: 4) {
                Text("1. Подайте живлення на регулятори (батарея), USB підключено.")
                Text("2. Натисніть «Відкрити конфігуратор»: ArduTune звільнить USB-порт і відкриє AM32 Configurator.")
                Text("3. У конфігураторі натисніть Connect і виберіть порт польотника (usbmodem…). Читайте й записуйте налаштування регуляторів.")
                Text("4. Закінчивши, закрийте з'єднання в конфігураторі та натисніть «Повернути підключення» тут.")
            }.font(.callout)
            HStack(spacing: 8) {
                Text("Адреса:").font(.caption).foregroundStyle(.secondary)
                TextField("https://am32.ca", text: $url).textFieldStyle(.roundedBorder).frame(width: 300)
            }
            HStack(spacing: 10) {
                Button { openWeb() } label: { Label(lk(webSerialBrowser.map { String(localized: "Відкрити в \($0.0)") } ?? "Відкрити в браузері"), systemImage: "globe") }
                    .buttonStyle(.borderedProminent).disabled(s.armed || !s.connected && !released)
                Button { pickLocalApp() } label: { Label(lk(localApp.isEmpty ? "Локальний застосунок…" : String(localized: "Відкрити «\((localApp as NSString).lastPathComponent)»")), systemImage: "app.badge") }
                    .disabled(s.armed)
                if !localApp.isEmpty { Button { localApp = "" } label: { Image(systemName: "xmark.circle") }.buttonStyle(.borderless).tip("Забути локальний застосунок") }
                Spacer()
                if released || !s.connected {
                    Button { reconnect() } label: { Label("Повернути підключення", systemImage: "arrow.triangle.2.circlepath") }.tint(.green)
                }
            }
            if webSerialBrowser == nil { Label("Web Serial підтримують лише Chrome, Edge та Brave. Safari не підходить: встановіть один із них або оберіть локальний застосунок.", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
            if released { Label("USB-порт звільнено для конфігуратора. Після роботи поверніть підключення.", systemImage: "cable.connector.slash").font(.callout).foregroundStyle(.orange) }
            if let n = note { Text(LocalizedStringKey(n)).font(.caption).foregroundStyle(.secondary) }
        }
    }

    func release(_ then: @escaping () -> Void) {
        EngineAPI.post("/disconnect") { _, _ in
            released = true
            // Невелика пауза, щоб двигун встиг закрити порт
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { then() }
        }
    }

    func openWeb() {
        guard let u = URL(string: url.hasPrefix("http") ? url : "https://" + url) else { note = String(localized: "Некоректна адреса"); return }
        release {
            if let b = webSerialBrowser {
                NSWorkspace.shared.open([u], withApplicationAt: b.1, configuration: NSWorkspace.OpenConfiguration())
                note = String(localized: "Відкрито в \(b.0).")
            } else { NSWorkspace.shared.open(u); note = String(localized: "Відкрито в браузері за замовчуванням.") }
        }
    }

    func pickLocalApp() {
        if localApp.isEmpty {
            let p = NSOpenPanel(); p.allowedFileTypes = ["app"]; p.directoryURL = URL(fileURLWithPath: "/Applications")
            p.message = String(localized: "Оберіть застосунок AM32 Configurator")
            guard p.runModal() == .OK, let u = p.url else { return }
            localApp = u.path
        }
        let app = URL(fileURLWithPath: localApp)
        release {
            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration()) { _, e in
                DispatchQueue.main.async { note = e == nil ? "Застосунок запущено." : "Не вдалося запустити застосунок" }
            }
        }
    }

    func reconnect() {
        EngineAPI.post("/connect?type=auto") { ok, _ in
            released = false
            note = ok ? "Підключення відновлюється…" : "Не вдалося відновити підключення"
        }
    }
}
