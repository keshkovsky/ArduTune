import SwiftUI

enum AppInfo {
    static let name = "ArduTune"
    static let developer = "keshkovsky"
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev" }
    static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "" }
    static let credits: [(String, String)] = [
        ("MAVLink (C#)", "Michael Oborne, GNU GPL v3: бібліотека протоколу з проєкту Mission Planner"),
        ("ArduPilot", "ArduPilot Dev Team, GNU GPL v3: протокол, метадані параметрів, схеми моторів, таблиці датчиків і UART"),
        ("GStreamer", "LGPL: відео (окремий процес, встановлюється окремо)"),
        (".NET", "Microsoft, MIT: середовище виконання двигуна"),
    ]
    static var licenseText: String {
        let paths = [Bundle.main.url(forResource: "COPYING", withExtension: "txt")?.path,
                     NSHomeDirectory() + "/Developer/ArduTune/LICENSE"].compactMap { $0 }
        for p in paths { if let t = try? String(contentsOfFile: p, encoding: .utf8) { return t } }
        return "Текст ліцензії GNU GPL v3: https://www.gnu.org/licenses/gpl-3.0.html"
    }
}

struct AboutView: View {
    @State private var showLicense = false
    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
            Text(LocalizedStringKey(AppInfo.name)).font(.largeTitle.bold())
            Text(lk(String(localized: "Конфігуратор ArduPilot для macOS · версія \(AppInfo.version)") + (AppInfo.build.isEmpty ? "" : String(localized: " (збірка \(AppInfo.build))")))).foregroundStyle(.secondary)
            Divider()
            VStack(spacing: 4) {
                Text("Розробник").font(.caption).foregroundStyle(.secondary)
                Text(LocalizedStringKey(AppInfo.developer)).font(.title3.weight(.semibold))
                Text("© 2026 \(AppInfo.developer)").font(.caption).foregroundStyle(.secondary)
            }
            Text("Вільне програмне забезпечення на умовах GNU General Public License v3. Програма постачається без жодних гарантій. Ви можете поширювати її та змінювати на умовах цієї ліцензії.")
                .font(.callout).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            GroupBox("Використані компоненти") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(AppInfo.credits, id: \.0) { c in
                        (Text(LocalizedStringKey(c.0)).bold() + Text(": ") + Text(lk(c.1))).font(.caption).fixedSize(horizontal: false, vertical: true)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button("Ліцензія GPL v3") { showLicense = true }
                Link("gnu.org/licenses/gpl-3.0", destination: URL(string: "https://www.gnu.org/licenses/gpl-3.0.html")!)
            }
        }
        .padding(24).frame(width: 480)
        .sheet(isPresented: $showLicense) {
            VStack(spacing: 0) {
                ScrollView { Text(LocalizedStringKey(AppInfo.licenseText)).font(.system(.caption, design: .monospaced)).textSelection(.enabled).padding() }
                Divider()
                Button("Закрити") { showLicense = false }.keyboardShortcut(.defaultAction).padding(10)
            }.frame(width: 640, height: 520)
        }
    }
}
