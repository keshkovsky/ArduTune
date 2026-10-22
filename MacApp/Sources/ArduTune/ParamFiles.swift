import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Параметри, які не варто записувати з файлу (службові лічильники/статистика).
private let skipExact: Set<String> = ["SYSID_SW_MREV", "SYS_NUM_RESETS", "FORMAT_VERSION"]
func shouldSkip(_ name: String) -> Bool { skipExact.contains(name) || name.hasPrefix("STAT_") }

/// Формат .param / .parm: "NAME,value" або "NAME value", коментарі з #.
func parseParamFile(_ text: String) -> [String: Double] {
    var out: [String: Double] = [:]
    for raw in text.components(separatedBy: .newlines) {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.hasPrefix("#") { continue }
        let parts = line.split(whereSeparator: { ",\t =".contains($0) }).map(String.init)
        if parts.count >= 2, let v = Double(parts[1].replacingOccurrences(of: ",", with: ".")) { out[parts[0]] = v }
    }
    return out
}

/// Відомості про плату, з якої збережено файл (коментарі «# Ключ: значення» на початку файлу).
func parseParamHeader(_ text: String) -> [String: String] {
    var out: [String: String] = [:]
    for raw in text.components(separatedBy: .newlines).prefix(20) {
        let l = raw.trimmingCharacters(in: .whitespaces)
        guard l.hasPrefix("#"), let c = l.firstIndex(of: ":") else { continue }
        let k = l[l.index(after: l.startIndex)..<c].trimmingCharacters(in: .whitespaces).lowercased()
        out[k] = l[l.index(after: c)...].trimmingCharacters(in: .whitespaces)
    }
    return out
}

/// Набір параметрів з файлу для перегляду без підключеного польотника.
struct OfflineSet {
    var name: String
    var params: [Param]
    var info: [String: String]
    var dir: String?            // каталог описів, який підходить до файлу
}

/// Параметри з файлу як список `Param` (тип за значенням: ціле чи дробове).
func paramsFromFile(_ values: [String: Double]) -> [Param] {
    values.keys.sorted().map { n in
        let v = values[n]!
        return Param(name: n, value: v, type: v == v.rounded() && abs(v) < 2_000_000_000 ? 4 : 9)
    }
}

/// Тип апарата за вмістом файлу (шапка «# Vehicle» або характерні параметри): назва каталогу описів ArduPilot.
func guessVehicleDir(_ values: [String: Double], info: [String: String]) -> String? {
    let v = (info["vehicle"] ?? "").uppercased()
    if v.hasPrefix("VTOL") || v == "FIXED_WING" { return "ArduPlane" }
    if v == "GROUND_ROVER" || v == "SURFACE_BOAT" { return "Rover" }
    if v == "SUBMARINE" { return "ArduSub" }
    if v == "ANTENNA_TRACKER" { return "AntennaTracker" }
    if ["QUADROTOR", "HEXAROTOR", "OCTOROTOR", "TRICOPTER", "HELICOPTER", "COAXIAL", "DODECAROTOR", "DECAROTOR"].contains(v) { return "ArduCopter" }
    let k = Set(values.keys)
    if k.contains("TECS_CLMB_MAX") || k.contains("ARSPD_TYPE") || k.contains("LIM_ROLL_CD") || k.contains("Q_ENABLE") { return "ArduPlane" }
    if k.contains("ATC_RAT_RLL_P") || k.contains("MOT_THST_HOVER") || k.contains("WPNAV_SPEED") { return "ArduCopter" }
    if k.contains("JS_GAIN_DEFAULT") || k.contains("PSCV_POS_P") { return "ArduSub" }
    if k.contains("CRUISE_SPEED") || k.contains("ATC_STR_RAT_P") { return "Rover" }
    return nil
}

/// Діалог вибору файлу параметрів → набір для офлайн-перегляду.
func chooseOfflineSet() -> OfflineSet? {
    guard let r = chooseParamFileToOpen() else { return nil }
    return OfflineSet(name: r.0, params: paramsFromFile(r.1), info: r.2, dir: guessVehicleDir(r.1, info: r.2))
}

func chooseParamFileToOpen() -> (String, [String: Double], [String: String])? {
    let p = NSOpenPanel()
    p.allowedContentTypes = [UTType(filenameExtension: "param"), UTType(filenameExtension: "parm"), .plainText, .text].compactMap { $0 }
    p.allowsOtherFileTypes = true
    p.message = String(localized: "Оберіть файл параметрів (.param)")
    guard p.runModal() == .OK, let url = p.url, let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
    return (url.lastPathComponent, parseParamFile(text), parseParamHeader(text))
}

/// Рядки-коментарі з відомостями про плату, що додаються на початок файлу.
struct ParamSaveInfo {
    var vehicle = "", firmware = "", board = "", uid = ""
    var header: String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"
        var l = ["# ArduTune: файл параметрів", "# Saved: " + f.string(from: Date())]
        if !vehicle.isEmpty { l.append("# Vehicle: " + vehicle) }
        if !firmware.isEmpty { l.append("# Firmware: " + firmware) }
        if !board.isEmpty { l.append("# Board: " + board) }
        if !uid.isEmpty { l.append("# UID: " + uid) }
        return l.joined(separator: "\n") + "\n"
    }
    /// Збирає відомості про підключену плату з двигуна.
    static func current(vehicle: String?) async -> ParamSaveInfo {
        var i = ParamSaveInfo(); i.vehicle = vehicle ?? ""
        if let d = try? await EngineAPI.data("/autopilot"), let a = try? JSONDecoder().decode(ApInfo.self, from: d) { i.firmware = a.flight; i.uid = a.uid2 }
        if let u = await EngineAPI.get("/board", as: UsbBoards.self), let dev = u.devices.first { i.board = dev.product }
        return i
    }
}

func saveParams(_ params: [Param], info: ParamSaveInfo = ParamSaveInfo()) {
    let p = NSSavePanel()
    p.nameFieldStringValue = "arducopter.param"
    p.message = String(localized: "Зберегти поточні параметри")
    guard p.runModal() == .OK, let url = p.url else { return }
    let text = info.header + params.sorted { $0.name < $1.name }.map { "\(loc($0.name)),\(fmt($0.value, isInt: $0.isInt))" }.joined(separator: "\n") + "\n"
    try? text.write(to: url, atomically: true, encoding: .utf8)
}

enum FileRowState { case same, differs, missing }

struct FileRow: Identifiable {
    var id: String { name }
    let name: String
    let file: Double
    let current: Double?
    let isInt: Bool
    var state: FileRowState {
        guard let c = current else { return .missing }
        return abs(file - c) > 1e-6 * max(1, abs(c)) ? .differs : .same
    }
}

struct CompareSheet: View {
    let fileName: String
    let file: [String: Double]
    var fileInfo: [String: String] = [:]
    let ps: ParamStore
    let locked: Bool
    var loadMode = false
    var base: [Param]? = nil           // з чим порівнювати замість поточних параметрів польотника (офлайн: файл A)
    var baseName = ""
    var readOnly = false               // лише перегляд відмінностей, без запису
    @Environment(\.dismiss) var dismiss
    @State private var selected: Set<String> = []
    @State private var onlyDiff = false
    @State private var applying = false
    @State private var applied = 0
    @State private var total = 0
    @State private var done = false
    @State private var needReboot = false
    @State private var curUID = ""
    @State private var curBoard = ""

    var all: [FileRow] {
        let cur = Dictionary((base ?? ps.params).map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        return file.keys.sorted().map { n in FileRow(name: n, file: file[n]!, current: cur[n]?.value, isInt: cur[n]?.isInt ?? (file[n]! == file[n]!.rounded())) }
    }
    var diffRows: [FileRow] { all.filter { $0.state == .differs } }
    var shown: [FileRow] { onlyDiff ? diffRows : all }
    var sameCount: Int { all.filter { $0.state == .same }.count }
    var missingCount: Int { all.filter { $0.state == .missing }.count }
    var onlyOnDrone: Int { (base ?? ps.params).filter { file[$0.name] == nil }.count }
    var writable: [FileRow] { diffRows.filter { !shouldSkip($0.name) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(lk(readOnly ? "Порівняння файлів параметрів" : (loadMode ? "Завантаження параметрів з файлу" : "Порівняння з файлом"))).font(.title2.bold())
            Text(lk(readOnly ? "A: \(baseName)   →   B: \(fileName)" : fileName)).font(.callout).foregroundStyle(.secondary)
            if !readOnly { originNote }
            HStack(spacing: 10) {
                Pill(text: String(localized: "У файлі: \(all.count)"), tint: .blue)
                Pill(text: String(localized: "Відрізняються: \(diffRows.count)"), tint: .orange)
                Pill(text: String(localized: "Збігаються: \(sameCount)"), tint: .green)
                Pill(text: readOnly ? String(localized: "Лише в B: \(missingCount)") : String(localized: "Немає на апараті: \(missingCount)"), tint: .gray)
                if !loadMode || readOnly { Pill(text: readOnly ? String(localized: "Лише в A: \(onlyOnDrone)") : String(localized: "Лише на апараті: \(onlyOnDrone)"), tint: .gray) }
            }
            HStack {
                Toggle("Лише відмінності", isOn: $onlyDiff).toggleStyle(.checkbox)
                Spacer()
                if !readOnly {
                    Button("Обрати всі відмінні") { selected = Set(writable.map(\.name)) }
                    Button("Зняти вибір") { selected = [] }
                }
            }
            List(shown) { r in
                HStack {
                    if r.state == .differs && readOnly {
                        Image(systemName: "circle.fill").font(.system(size: 6)).foregroundStyle(.orange).frame(width: 16)
                    } else if r.state == .differs {
                        Toggle("", isOn: Binding(get: { selected.contains(r.name) }, set: { on in if on { selected.insert(r.name) } else { selected.remove(r.name) } }))
                            .toggleStyle(.checkbox).labelsHidden().disabled(shouldSkip(r.name))
                    } else {
                        Image(systemName: r.state == .same ? "checkmark" : "questionmark")
                            .font(.caption).foregroundStyle(.secondary).frame(width: 16)
                    }
                    Text(LocalizedStringKey(r.name)).font(.system(.body, design: .monospaced))
                        .foregroundStyle(r.state == .missing ? .secondary : .primary)
                    Spacer()
                    if let c = r.current {
                        Text(lk(fmt(c, isInt: r.isInt))).foregroundStyle(.secondary).font(.system(.body, design: .monospaced))
                        Image(systemName: r.state == .same ? "equal" : "arrow.right").foregroundStyle(.secondary)
                    }
                    Text(lk(fmt(r.file, isInt: r.isInt)))
                        .font(.system(.body, design: .monospaced).weight(r.state == .differs ? .semibold : .regular))
                        .foregroundStyle(r.state == .differs ? Color.orange : .primary)
                }
                .opacity(r.state == .same ? 0.7 : 1)
            }
            .frame(minHeight: 320)
            if applying { ProgressView(value: Double(applied), total: Double(max(total, 1))) { Text("Запис \(applied)/\(total)").font(.caption) } }
            if done { Label(lk(needReboot ? "Записано. Для частини параметрів потрібне перезавантаження автопілота." : "Записано."), systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
            if locked { Label("Апарат ARMED, запис заблоковано", systemImage: "lock.fill").foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Закрити") { dismiss() }
                if !readOnly {
                    Button(lk((loadMode ? "Записати в польотник" : "Застосувати вибрані") + " (\(selected.count))")) { apply() }
                        .buttonStyle(.borderedProminent).disabled(selected.isEmpty || applying || locked)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 720, minHeight: 600)
        .task {
            if let d = try? await EngineAPI.data("/autopilot"), let a = try? JSONDecoder().decode(ApInfo.self, from: d) { curUID = a.uid2 }
        }
        .onAppear {
            onlyDiff = !loadMode          // при завантаженні показуємо ВЕСЬ файл
            if loadMode && !readOnly { selected = Set(writable.map(\.name)) }
        }
    }

    /// Звідки файл: збігається з підключеною платою чи ні (щоб не плутати файли різних апаратів).
    @ViewBuilder var originNote: some View {
        let fuid = fileInfo["uid"] ?? "", saved = fileInfo["saved"] ?? ""
        let desc = [fileInfo["board"], fileInfo["vehicle"], fileInfo["firmware"].map { loc("прошивка ") + $0 }].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
        if fuid.isEmpty {
            Label("У файлі немає відомостей про плату (збережено старішою версією або іншою програмою): перевірте, чи це файл потрібного апарата.", systemImage: "questionmark.circle")
                .font(.caption).foregroundStyle(.secondary)
        } else if !curUID.isEmpty && fuid.lowercased() == curUID.lowercased() {
            Label("Файл збережено з ЦІЄЇ САМОЇ плати (\(desc.isEmpty ? "UID збігається" : desc)\(saved.isEmpty ? "" : ", " + saved)). Це не файл іншого апарата.", systemImage: "exclamationmark.triangle.fill")
                .font(.caption.weight(.semibold)).foregroundStyle(.orange)
        } else if !curUID.isEmpty {
            Label("Файл з іншої плати: \(desc.isEmpty ? "UID " + fuid : desc)\(saved.isEmpty ? "" : ", " + saved).", systemImage: "checkmark.seal")
                .font(.caption).foregroundStyle(.green)
        } else {
            Label("Файл збережено з: \(desc.isEmpty ? "UID " + fuid : desc)\(saved.isEmpty ? "" : ", " + saved).", systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
        }
    }

    func apply() {
        let todo = diffRows.filter { selected.contains($0.name) }
        applying = true; applied = 0; total = todo.count; done = false
        Task { @MainActor in
            for r in todo {
                if let p = ps.params.first(where: { $0.name == r.name }) { ps.set(p, to: r.file) }
                applied += 1
                try? await Task.sleep(nanoseconds: 40_000_000)   // не перевантажуємо канал зв'язку
            }
            applying = false; selected = []
            needReboot = todo.contains { ps.meta[$0.name]?.reboot == true }
            done = true
        }
    }
}

/// Позначка «без підключення»: показано параметри з файлу чи останнього підключення, лише перегляд. Хрестик закриває їх.
struct OfflineBanner: View {
    @Environment(Store.self) var s
    var body: some View {
        if let o = s.ps.offline, !s.connected {
            HStack(spacing: 8) {
                Image(systemName: "doc.text.magnifyingglass").foregroundStyle(.blue)
                Text("Без підключення: показано параметри «\(loc(o.name))» (\(o.params.count)), лише перегляд.").font(.callout)
                Button { s.ps.closeOffline() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain).help("Закрити ці параметри")
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}
