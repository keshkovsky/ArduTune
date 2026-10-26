import SwiftUI
import JavaScriptCore

/// Декларативний вузол інтерфейсу розширення: JS повертає дерево об'єктів, ArduTune малює його у своєму стилі.
final class AddonNode {
    var type = "column"
    var p: [String: Any] = [:]
    var children: [AddonNode] = []
    var handlers: [String: JSValue] = [:]

    func str(_ k: String) -> String? { p[k] as? String }
    func num(_ k: String) -> Double? { (p[k] as? NSNumber)?.doubleValue }
    func bool(_ k: String) -> Bool { (p[k] as? NSNumber)?.boolValue ?? false }

    static let handlerKeys = ["onClick", "onChange", "onSubmit"]
    static let propKeys = ["text", "label", "title", "icon", "value", "min", "max", "step", "style", "color", "disabled", "prominent", "spacing", "warn", "bad", "format", "placeholder", "width", "caption", "options", "tint"]

    static func parse(_ v: JSValue?, depth: Int = 0) -> AddonNode? {
        guard let v, v.isObject, depth < 24 else { return nil }
        let n = AddonNode()
        n.type = v.forProperty("type")?.toString() ?? "column"
        for k in propKeys {
            guard let pv = v.forProperty(k), !pv.isUndefined, !pv.isNull else { continue }
            if k == "options" { n.p[k] = pv.toArray() ?? []; continue }
            if pv.isBoolean { n.p[k] = pv.toBool() } else if pv.isNumber { n.p[k] = pv.toDouble() } else if pv.isString { n.p[k] = pv.toString() ?? "" }
        }
        for k in handlerKeys {
            if let h = v.forProperty(k), h.isObject { n.handlers[k] = h }
        }
        if let ch = v.forProperty("children"), ch.isObject, let len = ch.forProperty("length")?.toInt32(), len > 0 {
            for i in 0..<Int(len) { if let c = parse(ch.atIndex(i), depth: depth + 1) { n.children.append(c) } }
        }
        return n
    }
}

/// Сторінка розширення: періодично викликає render() і малює результат.
struct AddonPageView: View {
    let addonID: String
    let pageID: String
    @State private var root: AddonNode?
    @State private var tickID = 0
    private var mgr: AddonManager { AddonManager.shared }

    var body: some View {
        Group {
            if let root {
                ScrollView { AddonNodeView(node: root, onAction: refresh).padding(14).frame(maxWidth: .infinity, alignment: .leading) }
            } else {
                ContentUnavailableView("Сторінка розширення недоступна", systemImage: "puzzlepiece", description: Text("Розширення вимкнене або не зареєструвало цю сторінку."))
            }
        }
        .onAppear { refresh() }
        .task(id: "\(addonID)/\(pageID)") {
            while !Task.isCancelled { refresh(); try? await Task.sleep(nanoseconds: 300_000_000) }
        }
    }

    @MainActor func refresh() {
        guard let (_, page) = mgr.page("\(addonID)/\(pageID)") else { root = nil; return }
        let v = page.render.call(withArguments: [])
        root = AddonNode.parse(v)
    }
}

struct AddonNodeView: View {
    let node: AddonNode
    let onAction: () -> Void

    var body: some View { content }

    /// Порівняння значень без різниці 0 / 0.0 (JS-числа приходять як Double).
    private func norm(_ v: Any?) -> String {
        if let n = v as? NSNumber, !(CFGetTypeID(n) == CFBooleanGetTypeID()) { let d = n.doubleValue; return d == d.rounded() ? String(Int(d)) : String(d) }
        return "\(v ?? "")"
    }

    private func call(_ key: String, _ arg: Any? = nil) {
        guard let h = node.handlers[key] else { return }
        _ = arg.map { h.call(withArguments: [$0]) } ?? h.call(withArguments: [])
        onAction()
    }

    private func color(_ s: String?) -> Color? {
        switch s {
        case "red": return .red; case "green": return .green; case "orange": return .orange; case "yellow": return .yellow
        case "blue": return .blue; case "teal": return .teal; case "gray", "secondary": return .secondary
        default: if let s, s.hasPrefix("#"), let c = Color(hex: s) { return c }; return nil
        }
    }

    @ViewBuilder private var kids: some View {
        ForEach(Array(node.children.enumerated()), id: \.offset) { _, c in AddonNodeView(node: c, onAction: onAction) }
    }

    @ViewBuilder var content: some View {
        switch node.type {
        case "row":
            HStack(alignment: .center, spacing: node.num("spacing") ?? 8) { kids }
        case "wrap":
            LazyVGrid(columns: [GridItem(.adaptive(minimum: node.num("width") ?? 90), spacing: node.num("spacing") ?? 6)], alignment: .leading, spacing: node.num("spacing") ?? 6) { kids }
        case "card":
            VStack(alignment: .leading, spacing: 10) {
                if let t = node.str("title") {
                    Label { Text(lk(t)).font(.headline) } icon: { Image(systemName: node.str("icon") ?? "puzzlepiece") }
                }
                if let c = node.str("text") { Text(lk(c)).font(.callout).foregroundStyle(.secondary) }
                kids
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        case "text":
            let t = node.str("text") ?? ""
            Group {
                switch node.str("style") {
                case "title": Text(lk(t)).font(.title3.weight(.semibold))
                case "headline": Text(lk(t)).font(.headline)
                case "caption": Text(lk(t)).font(.caption).foregroundStyle(.secondary)
                case "mono": Text(verbatim: t).font(.system(.callout, design: .monospaced))
                case "big": Text(lk(t)).font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
                default: Text(lk(t)).font(.callout)
                }
            }
            .foregroundStyle(color(node.str("color")) ?? .primary)
            .fixedSize(horizontal: false, vertical: true)
        case "button":
            Button { call("onClick") } label: {
                if let ic = node.str("icon") { Label { Text(lk(node.str("label") ?? "")) } icon: { Image(systemName: ic) } } else { Text(lk(node.str("label") ?? "")) }
            }
            .disabled(node.bool("disabled"))
            .buttonStyle(.bordered).tint(node.bool("prominent") ? .accentColor : color(node.str("tint")))
        case "toggle":
            Toggle(lk(node.str("label") ?? ""), isOn: Binding(get: { node.bool("value") }, set: { call("onChange", $0) })).toggleStyle(.checkbox).disabled(node.bool("disabled"))
        case "picker":
            let opts = (node.p["options"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
            HStack {
                if let l = node.str("label") { Text(lk(l)).font(.callout) }
                Picker("", selection: Binding(get: { norm(node.p["value"]) }, set: { v in
                    let orig = opts.first { norm($0["value"]) == v }?["value"]
                    call("onChange", orig ?? v)
                })) {
                    ForEach(Array(opts.enumerated()), id: \.offset) { _, o in Text(lk("\(o["label"] ?? o["value"] ?? "")")).tag(norm(o["value"])) }
                }.labelsHidden().fixedSize().disabled(node.bool("disabled"))
            }
        case "slider":
            HStack {
                if let l = node.str("label") { Text(lk(l)).font(.callout) }
                Slider(value: Binding(get: { node.num("value") ?? 0 }, set: { call("onChange", $0) }), in: (node.num("min") ?? 0)...(node.num("max") ?? 1))
                    .frame(maxWidth: 260).disabled(node.bool("disabled"))
                Text(String(format: node.str("format") ?? "%.0f", node.num("value") ?? 0)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 52, alignment: .trailing)
            }
        case "field":
            AddonField(node: node) { call("onSubmit", $0) }
        case "progress":
            VStack(alignment: .leading, spacing: 3) {
                if let l = node.str("label") { Text(lk(l)).font(.caption).foregroundStyle(.secondary) }
                ProgressView(value: min(max(node.num("value") ?? 0, node.num("min") ?? 0), node.num("max") ?? 1), total: node.num("max") ?? 1).tint(color(node.str("color")))
            }
        case "meter":
            let v = node.num("value") ?? 0, mx = max(node.num("max") ?? 1, 0.0001), warn = node.num("warn"), bad = node.num("bad")
            let c: Color = (bad != nil && v >= bad!) ? .red : ((warn != nil && v >= warn!) ? .orange : .green)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(lk(node.str("label") ?? "")).font(.callout); Spacer()
                    Text(String(format: node.str("format") ?? "%.1f", v)).font(.callout.monospacedDigit().weight(.medium)).foregroundStyle(c)
                }
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary.opacity(0.6))
                        Capsule().fill(c.gradient).frame(width: max(4, g.size.width * CGFloat(min(max(v / mx, 0), 1))))
                    }
                }.frame(height: 6)
            }
        case "divider": Divider().opacity(0.6)
        case "spacer": Spacer(minLength: node.num("width") ?? 8)
        default:
            VStack(alignment: .leading, spacing: node.num("spacing") ?? 10) { kids }
        }
    }
}

/// Поле вводу: поки користувач друкує, текст не перезаписується відтворенням сторінки.
struct AddonField: View {
    let node: AddonNode
    let submit: (String) -> Void
    @State private var text = ""
    @State private var seen = ""
    @FocusState private var focused: Bool
    var body: some View {
        HStack {
            if let l = node.str("label") { Text(lk(l)).font(.callout) }
            TextField(node.str("placeholder") ?? "", text: $text).textFieldStyle(.roundedBorder).frame(maxWidth: node.num("width") ?? 260)
                .focused($focused).onSubmit { submit(text) }.disabled(node.bool("disabled"))
        }
        .onAppear { text = node.str("value") ?? ""; seen = text }
        .onChange(of: node.str("value") ?? "") { _, v in if !focused && v != seen { text = v; seen = v } }
    }
}

// MARK: - Сторінка «Розширення»

struct AddonsView: View {
    @Environment(Store.self) var s
    @AppStorage("addons.tab") private var tab = "manage"
    private var mgr: AddonManager { AddonManager.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PageTitle(title: String(localized: "Розширення"), subtitle: String(localized: "Скрипти в теці Addons додають нові можливості: пристрої, панелі, рядки HUD, позначки на мапі."))
                .padding(.horizontal, 16)
            let pages = mgr.pages("addons")
            TabStrip(selection: $tab, tabs: [("manage", "Керування")] + pages.map { ($0.id, $0.title) }).padding(.horizontal, 16)
            if tab == "manage" || !pages.contains(where: { $0.id == tab }) { manage } else if let p = pages.first(where: { $0.id == tab }) {
                AddonPageView(addonID: String(p.id.split(separator: "/").first ?? ""), pageID: p.pageID)
            }
        }
        .padding(.top, 8)
    }

    var manage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Button { mgr.scan() } label: { Label("Перезавантажити розширення", systemImage: "arrow.clockwise") }
                    Button { NSWorkspace.shared.open(AddonManager.folder) } label: { Label("Відкрити теку", systemImage: "folder") }
                    Spacer()
                }
                Text(verbatim: AddonManager.folder.path).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                if !mgr.scanError.isEmpty { Label(lk(mgr.scanError), systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
                if mgr.addons.isEmpty {
                    ContentUnavailableView("Розширень ще немає", systemImage: "puzzlepiece.extension", description: Text("Покладіть теку розширення (addon.json і main.js) у теку вище й натисніть «Перезавантажити розширення»."))
                        .frame(maxWidth: .infinity)
                }
                ForEach(mgr.addons) { a in AddonCard(addon: a) }
                Label("Розширення виконує код з файлів. Вмикайте лише ті, яким довіряєте: перегляньте їхні дозволи. Команди польоту без дозволу «Команди польотнику» недоступні.", systemImage: "lock.shield").font(.caption).foregroundStyle(.secondary)
            }.padding(16)
        }
    }
}

struct AddonCard: View {
    @Bindable var addon: Addon
    @State private var showLog = false
    private var mgr: AddonManager { AddonManager.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Image(systemName: addon.manifest.icon ?? "puzzlepiece.extension").font(.title3).frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: addon.name).font(.headline)
                    Text(verbatim: "v\(addon.manifest.version ?? "?")" + (addon.manifest.author.map { " · \($0)" } ?? "")).font(.caption).foregroundStyle(.secondary)
                    if let d = addon.manifest.description { Text(verbatim: d).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                }
                Spacer()
                Toggle("", isOn: Binding(get: { addon.enabled }, set: { mgr.setEnabled(addon, $0) })).toggleStyle(.switch).labelsHidden()
            }
            if !addon.declared.isEmpty {
                Text("Дозволи").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 6)], alignment: .leading, spacing: 6) {
                    ForEach(addon.declared, id: \.self) { p in
                        Toggle(isOn: Binding(get: { addon.granted.contains(p) }, set: { mgr.setGranted(addon, p, $0) })) {
                            Text(lk(AddonPermission.title(p))).font(.caption)
                        }.toggleStyle(.checkbox).help(lk(AddonPermission.all.first { $0.id == p }?.detail ?? p)).disabled(!addon.enabled)
                    }
                }
            }
            HStack {
                Text(lk(addon.enabled ? (addon.status.isEmpty ? "Працює" : addon.status) : "Вимкнено")).font(.caption)
                    .foregroundStyle(addon.status.hasPrefix("JS") || addon.status.hasPrefix("⚠︎") ? Color.orange : Color.secondary)
                Spacer()
                Button { mgr.reload(addon) } label: { Image(systemName: "arrow.clockwise") }.help("Перезапустити розширення").disabled(!addon.enabled)
                Button { showLog.toggle() } label: { Label("Журнал", systemImage: "text.alignleft") }
            }.buttonStyle(.borderless)
            if showLog {
                ScrollView { Text(verbatim: addon.log.suffix(60).joined(separator: "\n")).font(.system(size: 11, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                    .frame(maxHeight: 160).padding(8).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}
