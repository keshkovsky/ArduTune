import SwiftUI
import Observation
import Translation

struct Param: Identifiable, Hashable {
    var id: String { name }
    let name: String
    var value: Double
    let type: Int      // MAV_PARAM_TYPE: 1..8 цілі, 9 float32
    var isInt: Bool { type < 9 }
}

struct ParamMeta: Decodable {
    let name: String
    let label: String?
    let doc: String?
    let units: String?
    let min: Double?
    let max: Double?
    let inc: Double?
    let values: [[String]]?
    let bits: [[String]]?
    let readOnly: Bool?
    let reboot: Bool?
    let user: String?
}

private struct ParamsDTO: Decodable {
    struct Item: Decodable { let n: String; let v: Double; let t: Int }
    let loading: Bool; let count: Int; let received: Int; let items: [Item]
}

@Observable
final class ParamStore {
    func find(_ n: String) -> Param? {
        if let i = nameIndex[n], i < params.count, params[i].name == n { return params[i] }
        nameIndex = Dictionary(params.enumerated().map { ($1.name, $0) }, uniquingKeysWith: { a, _ in a })
        if let i = nameIndex[n], i < params.count { return params[i] }
        return nil
    }

    var params: [Param] = []
    /// Параметри для перегляду без підключення (файл або знімок останнього підключення). Поки задано й польотника немає, замінюють `params`.
    var offline: OfflineSet?
    var meta: [String: ParamMeta] = [:]
    var loading = false
    var count = 0
    var received = 0
    var changed: Set<String> = []     // змінені в цій сесії
    var error: String?
    var tr: [String: String] = [:]    // кеш перекладів описів
    private var polling = false
    @ObservationIgnored var nameIndex: [String: Int] = [:]
    @ObservationIgnored var metaVehicle: String?
    var metaSource = ""                    // з яких версій прошивки взято описи (приходить від двигуна)
    @ObservationIgnored private var metaLoading = false
    private let base = "http://127.0.0.1:14560"

    func start() {
        if !polling { polling = true; poll() }
        if meta.isEmpty { loadMeta() }
    }

    func refresh() {
        post("/params/refresh") { }
        changed = []
        params = []
        loading = true
    }

    private func poll() {
        Task { @MainActor in
            while true {
                await fetchParams()
                try? await Task.sleep(nanoseconds: loading ? 400_000_000 : 1_500_000_000)
            }
        }
    }

    /// Показати набір параметрів без підключення (лише читання).
    func showOffline(_ set: OfflineSet) {
        offline = set
        params = set.params
        changed = []
        nameIndex = [:]
    }
    /// Закрити перегляд: параметри очищаються, справжні прийдуть від польотника після підключення.
    func closeOffline() {
        guard offline != nil else { return }
        offline = nil
        params = []
        nameIndex = [:]
    }
    /// Зв'язок з польотником зник: зберігаємо останні параметри як набір для перегляду.
    func captureOffline() {
        guard offline == nil, !params.isEmpty else { return }
        offline = OfflineSet(name: "останнє підключення", params: params, info: [:], dir: nil)
    }

    @MainActor private func fetchParams() async {
        if offline != nil { return }
        guard let url = URL(string: base + "/params"),
              let (d, _) = try? await URLSession.shared.data(for: EngineAPI.request(url)),
              let dto = try? JSONDecoder().decode(ParamsDTO.self, from: d) else { return }
        loading = dto.loading; count = dto.count; received = dto.received
        // Не перезаписуємо весь список, якщо нічого не змінилось (економимо UI)
        if dto.items.count != params.count || changedValuesDiffer(dto.items) {
            params = dto.items.map { Param(name: $0.n, value: $0.v, type: $0.t) }
        }
    }

    private func changedValuesDiffer(_ items: [ParamsDTO.Item]) -> Bool {
        for (i, it) in items.enumerated() where i < params.count {
            if params[i].name != it.n || params[i].value != it.v { return true }
        }
        return false
    }

    /// Тип апарата змінився (наприклад, Copter → Plane): метадані потрібно завантажити для нового типу.
    func reloadMeta(for vehicle: String) {
        metaVehicle = vehicle
        meta = [:]
        Task { @MainActor in
            // Двигун перемикає каталог синхронно з heartbeat; чекаємо появи непорожнього списку
            try? await Task.sleep(nanoseconds: 500_000_000)
            self.metaLoading = false
            self.loadMeta()
        }
    }

    /// Двигун підібрав описи під версію прошивки плати: оновлюємо словник.
    func reloadMeta(source: String) {
        metaSource = source
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            self.metaLoading = false
            self.meta = [:]
            self.loadMeta()
        }
    }

    /// «stable-4.7.0 + latest + stable-4.6.3» → «прошивка 4.7.0, запасні описи: свіжіші й 4.6.3».
    var metaSourceNice: String {
        let parts = metaSource.components(separatedBy: " + ")
        guard let first = parts.first, !first.isEmpty else { return "" }
        let main = first == "latest" ? "найсвіжіші (master)" : loc("версія ") + first.replacingOccurrences(of: "stable-", with: "")
        let extra = parts.dropFirst().map { $0 == "latest" ? "master" : $0.replacingOccurrences(of: "stable-", with: "") }
        return String(localized: "Описи: \(main)") + (extra.isEmpty ? "" : loc(", запасні: ") + extra.joined(separator: ", "))
    }

    private func loadMeta() {
        guard !metaLoading else { return }
        metaLoading = true
        Task { @MainActor in
            while meta.isEmpty {
                let arr: [ParamMeta]? = await Task.detached(priority: .utility) {
                    guard let url = URL(string: EngineAPI.base + "/meta"),
                          let (d, _) = try? await URLSession.shared.data(for: EngineAPI.request(url)) else { return nil }
                    return try? JSONDecoder().decode([ParamMeta].self, from: d)
                }.value
                if let arr, !arr.isEmpty {
                    meta = Dictionary(arr.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
                    break
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
            metaLoading = false
        }
    }

    func set(_ p: Param, to v: Double) {
        guard offline == nil else { return }
        var c = URLComponents(string: base + "/params/set")!
        c.queryItems = [.init(name: "name", value: p.name), .init(name: "value", value: String(v))]
        let r = EngineAPI.request(c.url!, method: "POST")
        URLSession.shared.dataTask(with: r) { _, resp, _ in
            DispatchQueue.main.async {
                if (resp as? HTTPURLResponse)?.statusCode == 200 { self.changed.insert(p.name) }
                else { self.error = String(localized: "Не вдалося записати \(loc(p.name))") }
            }
        }.resume()
    }

    private func post(_ path: String, done: @escaping () -> Void) {
        let r = EngineAPI.request(URL(string: base + path)!, method: "POST")
        URLSession.shared.dataTask(with: r) { _, _, _ in DispatchQueue.main.async(execute: done) }.resume()
    }
}

func fmt(_ v: Double, isInt: Bool) -> String {
    if isInt { return String(Int(v)) }
    return String(format: "%.6g", v)
}

struct ParamsView: View {
    @Environment(Store.self) var s
    var ps: ParamStore { s.ps }
    @State private var query = ""
    @State private var onlyChanged = false
    @State private var selected: String?
    @State private var trConfig: TranslationSession.Configuration?
    @State private var showOriginal = false
    /// До 5 параметрів тієї ж групи (за префіксом до першого «_») з описом: контекст для параметра без метаданих.
    func relatedParams(_ name: String?) -> [(String, String)] {
        guard let name, ps.meta[name] == nil, let pre = name.split(separator: "_").first.map(String.init) else { return [] }
        return shown.lazy.filter { $0.name.hasPrefix(pre + "_") && $0.name != name }
            .compactMap { p in ps.meta[p.name]?.label.map { (p.name, $0) } }.prefix(5).map { $0 }
    }

    struct CompareJob { var name: String; var file: [String: Double]; var info: [String: String]; var load: Bool; var base: [Param]? = nil; var baseName = ""; var readOnly = false }
    @State private var compare: CompareJob?
    /// Набір для перегляду без підключення (файл або останнє підключення): спільний для всіх розділів.
    var offline: OfflineSet? { ps.offline }
    @State private var offlineDir = "ArduCopter"

    /// Параметри, що показуються: файл (офлайн), інакше те, що є від польотника (в т. ч. останнє з'єднання).
    var shown: [Param] { offline?.params ?? ps.params }
    /// Дані «живі» з польотника: можна редагувати й записувати.
    var isLive: Bool { s.connected }
    static let vehicleDirs: [(String, String)] = [("ArduCopter", "Copter"), ("ArduPlane", "Plane"), ("Rover", "Rover"), ("ArduSub", "Sub"), ("AntennaTracker", "Tracker")]

    func openOffline() {
        guard let set = chooseOfflineSet() else { return }
        ps.showOffline(set)
        selected = nil; query = ""
        if let d = set.dir { selectDir(d) }
    }
    func selectDir(_ d: String) {
        offlineDir = d
        EngineAPI.post("/meta/select?dir=\(d)") { _, _ in ps.reloadMeta(for: d) }
    }
    func compareFiles() {
        guard let a = chooseParamFileToOpen(), let b = chooseParamFileToOpen() else { return }
        compare = CompareJob(name: b.0, file: b.1, info: b.2, load: false, base: paramsFromFile(a.1), baseName: a.0, readOnly: true)
    }
    @State private var confirmReboot = false
    @State private var rebootNote: String?
    private let target = Locale.current.language
    var needsTranslation: Bool { (target.languageCode?.identifier ?? "en") != "en" }

    var filtered: [Param] {
        let q = query.lowercased()
        return shown.filter { p in
            if onlyChanged && !ps.changed.contains(p.name) { return false }
            if q.isEmpty { return true }
            if p.name.lowercased().contains(q) { return true }
            if let m = ps.meta[p.name], (m.label ?? "").lowercased().contains(q) { return true }
            return false
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Пошук за назвою або описом", text: $query).textFieldStyle(.plain)
                if !ps.metaSource.isEmpty { Text(LocalizedStringKey(ps.metaSourceNice)).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).help("Звідки взято описи параметрів. Підбираються під версію прошивки плати; для параметрів, яких немає в цій версії, використовуються запасні джерела.") }
                Toggle("Змінені", isOn: $onlyChanged).toggleStyle(.checkbox)
                if needsTranslation { Toggle("Оригінал (EN)", isOn: $showOriginal).toggleStyle(.checkbox) }
                if !s.connected {
                    Picker("", selection: Binding(get: { offlineDir }, set: { selectDir($0) })) {
                        ForEach(Self.vehicleDirs, id: \.0) { Text(lk($0.1)).tag($0.0) }
                    }.labelsHidden().fixedSize().controlSize(.small).help("Тип апарата для описів параметрів (без підключення)")
                }
                Menu {
                    if !s.connected {
                        Button("Відкрити файл для перегляду…") { openOffline() }
                        if offline != nil { Button("Закрити перегляд") { ps.closeOffline(); selected = nil } }
                    }
                    Button("Порівняти два файли…") { compareFiles() }
                    Divider()
                    if isLive {
                        Button("Завантажити файл у польотник…") { if let r = chooseParamFileToOpen() { compare = CompareJob(name: r.0, file: r.1, info: r.2, load: true) } }
                    }
                    Button(lk(isLive ? "Порівняти з файлом…" : "Порівняти з відкритими параметрами…")) {
                        if let r = chooseParamFileToOpen() {
                            compare = CompareJob(name: r.0, file: r.1, info: r.2, load: false, base: isLive ? nil : shown, baseName: offline?.name ?? "останні параметри польотника", readOnly: !isLive)
                        }
                    }.disabled(shown.isEmpty)
                    Divider()
                    Button("Зберегти у файл…") {
                        let list = shown, veh = s.t.vehicle
                        Task { saveParams(list, info: isLive ? await ParamSaveInfo.current(vehicle: veh) : ParamSaveInfo()) }
                    }.disabled(shown.isEmpty)
                } label: { Label("Файл", systemImage: "doc") }
                Button { ps.refresh() } label: { Label("Оновити", systemImage: "arrow.clockwise") }
                    .disabled(!isLive || ps.loading)
                Button(role: .destructive) { confirmReboot = true } label: { Label("Перезавантажити", systemImage: "restart") }
                    .disabled(!isLive || s.armed)
            }
            .padding(10)
            .background(.regularMaterial)

            OfflineBanner()
            if !s.connected && shown.isEmpty {
                ContentUnavailableView {
                    Label("Польотник не підключений", systemImage: "cable.connector")
                } description: {
                    Text("Підключіть плату по USB або відкрийте файл параметрів (.param), щоб переглянути й порівняти його без підключення.")
                } actions: {
                    HStack(spacing: 10) {
                        Button("Відкрити файл") { openOffline() }.fixedSize()
                        Button("Порівняти два файли") { compareFiles() }.fixedSize()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                if isLive && (ps.loading || ps.received < ps.count) {
                    ProgressView(value: Double(ps.received), total: Double(max(ps.count, 1))) {
                        Text("Завантаження параметрів \(ps.received)/\(ps.count)").font(.caption)
                    }.padding(.horizontal, 10).padding(.top, 6)
                }
                HSplitView {
                    List(filtered, selection: $selected) { p in
                        ParamRow(p: p, meta: ps.meta[p.name], changed: isLive && ps.changed.contains(p.name), locked: s.armed || !isLive) { v in if isLive { ps.set(p, to: v) } }
                            .tag(p.name)
                    }
                    .frame(minWidth: 420)
                    DetailPane(p: shown.first { $0.name == selected }, meta: selected.flatMap { ps.meta[$0] }, locked: s.armed || !isLive, tr: showOriginal ? [:] : ps.tr,
                               related: relatedParams(selected), source: ps.metaSource) { p, v in if isLive { ps.set(p, to: v) } }
                        .frame(minWidth: 280, idealWidth: 320)
                }
                HStack {
                    Text("\(filtered.count) із \(shown.count)").font(.caption).foregroundStyle(.secondary)
                    if s.armed { Label("Апарат у режимі ARMED, редагування заблоковано", systemImage: "lock.fill").font(.caption).foregroundStyle(.red) }
                    Spacer()
                    if let r = rebootNote { Text(LocalizedStringKey(r)).font(.caption).foregroundStyle(.secondary) }
                    if let e = ps.error { Text(LocalizedStringKey(e)).font(.caption).foregroundStyle(.red) }
                }.padding(8)
            }
        }
        .onAppear { ps.start() }
        .task {
            struct MV: Decodable { let dir: String }
            if let v = await EngineAPI.get("/meta/vehicle", as: MV.self) { offlineDir = v.dir }
        }
        .sheet(isPresented: Binding(get: { compare != nil }, set: { if !$0 { compare = nil } })) {
            if let c = compare { CompareSheet(fileName: c.name, file: c.file, fileInfo: c.info, ps: ps, locked: s.armed || !s.connected, loadMode: c.load, base: c.base, baseName: c.baseName, readOnly: c.readOnly) }
        }
        .confirmationDialog("Перезавантажити автопілот?", isPresented: $confirmReboot) {
            Button("Перезавантажити", role: .destructive) {
                EngineAPI.post("/reboot") { ok, err in rebootNote = ok ? "Команду надіслано, чекаємо повернення польотника…" : (err == "armed" ? "Недоступно: ARMED" : "Помилка") }
            }
        } message: { Text("З'єднання тимчасово зникне й відновиться автоматично. Параметри завантажаться знову.") }
        .translationTask(trConfig) { session in
            guard let sel = selected, let m = ps.meta[sel] else { return }
            let texts = ([m.label, m.doc] + (m.values ?? []).map { $0.count > 1 ? $0[1] : nil } + (m.bits ?? []).map { $0.count > 1 ? $0[1] : nil })
                .compactMap { $0 }.filter { ps.tr[$0] == nil }
            guard !texts.isEmpty else { return }
            let reqs = texts.map { TranslationSession.Request(sourceText: $0, clientIdentifier: $0) }
            do {
                for try await r in session.translate(batch: reqs) {
                    if let id = r.clientIdentifier { ps.tr[id] = r.targetText }
                }
            } catch { }
        }
        .onChange(of: selected) { _, _ in
            guard needsTranslation, !showOriginal else { return }
            if trConfig == nil { trConfig = .init(source: Locale.Language(identifier: "en"), target: target) }
            else { trConfig?.invalidate() }
        }
    }
}

struct ParamRow: View {
    let p: Param; let meta: ParamMeta?; let changed: Bool; let locked: Bool
    let onCommit: (Double) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(LocalizedStringKey(p.name)).font(.system(.body, design: .monospaced).weight(.medium))
                if let l = meta?.label { Text(LocalizedStringKey(l)).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer()
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .font(.system(.body, design: .monospaced))
                .frame(width: 110)
                .focused($focused)
                .disabled(locked || meta?.readOnly == true)
                .foregroundStyle(invalid ? .red : .primary)
                .onSubmit { commit() }
            Text(lk(meta?.units ?? "")).font(.caption).foregroundStyle(.secondary).frame(width: 50, alignment: .leading)
            if changed { Circle().fill(.orange).frame(width: 8, height: 8) }
        }
        .onAppear { text = fmt(p.value, isInt: p.isInt) }
        .onChange(of: p.value) { _, new in if !focused { text = fmt(new, isInt: p.isInt) } }
        .padding(.vertical, 2)
    }

    var parsed: Double? { Double(text.replacingOccurrences(of: ",", with: ".")) }
    var invalid: Bool {
        guard let v = parsed else { return true }
        if let m = meta, let lo = m.min, let hi = m.max, m.values == nil, m.bits == nil { return v < lo || v > hi }
        return false
    }
    func commit() {
        guard let v = parsed, !invalid else { text = fmt(p.value, isInt: p.isInt); return }
        if v != p.value { onCommit(v) }
    }
}

struct DetailPane: View {
    let p: Param?; let meta: ParamMeta?; let locked: Bool
    let tr: [String: String]
    var related: [(String, String)] = []         // параметри тієї ж групи з описом (для контексту, якщо в цього опису немає)
    var source = ""                              // звідки взято описи
    let onSet: (Param, Double) -> Void
    func t(_ s: String) -> String { tr[s] ?? s }

    var body: some View {
        ScrollView {
            if let p {
                VStack(alignment: .leading, spacing: 12) {
                    Text(LocalizedStringKey(p.name)).font(.system(.title2, design: .monospaced).weight(.semibold))
                    if let l = meta?.label { Text(lk(t(l))).font(.headline) }
                    HStack {
                        Pill(text: "= " + fmt(p.value, isInt: p.isInt) + (meta?.units.map { " " + $0 } ?? ""), tint: .blue)
                        if meta?.reboot == true { Pill(text: String(localized: "Потрібне перезавантаження"), tint: .orange) }
                        if let u = meta?.user { Pill(text: u, tint: .gray) }
                    }
                    if let d = meta?.doc { Text(lk(t(d))).font(.callout).textSelection(.enabled) }
                    if let lo = meta?.min, let hi = meta?.max {
                        Text(lk(String(localized: "Діапазон: \(fmt(lo, isInt: false)) … \(fmt(hi, isInt: false))") + (meta?.inc.map { String(localized: ", крок \(fmt($0, isInt: false))") } ?? "")))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let vals = meta?.values, !vals.isEmpty {
                        Text("Значення").font(.subheadline.weight(.semibold))
                        ForEach(vals, id: \.self) { kv in
                            let code = Double(kv[0]) ?? 0
                            Button { onSet(p, code) } label: {
                                HStack { Image(systemName: code == p.value ? "largecircle.fill.circle" : "circle"); Text("\(kv[0]) — \(t(kv[1]))"); Spacer() }
                            }.buttonStyle(.plain).disabled(locked)
                        }
                    }
                    if let bits = meta?.bits, !bits.isEmpty {
                        Text("Біти").font(.subheadline.weight(.semibold))
                        ForEach(bits, id: \.self) { kv in
                            let bit = Int(kv[0]) ?? 0
                            let on = (Int(p.value) >> bit) & 1 == 1
                            Button { onSet(p, Double(Int(p.value) ^ (1 << bit))) } label: {
                                HStack { Image(systemName: on ? "checkmark.square.fill" : "square"); Text("\(bit) — \(t(kv[1]))"); Spacer() }
                            }.buttonStyle(.plain).disabled(locked)
                        }
                    }
                    if meta == nil {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("Опису немає в каталозі ArduPilot для цієї версії прошивки", systemImage: "questionmark.circle").font(.callout.weight(.medium))
                            Text(lk(loc("Типово так буває з параметрами новішої dev-збірки: вони вже є на платі, а офіційні описи ще не опубліковані.") + (source.isEmpty ? "" : String(localized: " Джерела описів: \(source)."))))
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            Text(lk(loc("Тип: ") + ["", "int8", "int8", "int16", "int16", "int32", "int32", "int64", "int64", "float"][min(max(p.type, 0), 9)] + (p.isInt ? " (ціле)" : " (дробове)")))
                                .font(.caption).foregroundStyle(.secondary)
                            let hints = ParamGuess.hints(p.name, isInt: p.isInt, value: p.value)
                            if !hints.isEmpty {
                                Text("Припущення за назвою (не з офіційних описів)").font(.caption.weight(.semibold)).padding(.top, 4)
                                ForEach(hints, id: \.self) { Text(lk("• " + $0)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                            }
                            HStack(spacing: 10) {
                                if let u = ParamGuess.searchURL(p.name) { Link(destination: u) { Label("Пошук у коді ArduPilot", systemImage: "magnifyingglass") }.font(.caption) }
                                if let u = ParamGuess.docsURL(p.name) { Link(destination: u) { Label("Документація", systemImage: "book") }.font(.caption) }
                            }.padding(.top, 2)
                            if !related.isEmpty {
                                Text("Схожі параметри тієї ж групи").font(.caption.weight(.semibold)).padding(.top, 4)
                                ForEach(related, id: \.0) { r in
                                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                                        Text(LocalizedStringKey(r.0)).font(.system(.caption, design: .monospaced))
                                        Text(lk(t(r.1))).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    }
                                }
                            }
                        }
                        .padding(10).background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ContentUnavailableView("Оберіть параметр", systemImage: "slider.horizontal.3")
            }
        }
    }
}


/// Підказки для параметрів, яких немає в описах ArduPilot (нова dev-збірка): висновки з назви й посилання на джерела.
enum ParamGuess {
    static let suffixes: [(String, String)] = [
        ("_ENABLE", "вмикач (0 — вимкнено, 1 — увімкнено)"), ("_EN", "вмикач (0 — вимкнено, 1 — увімкнено)"),
        ("_MASK", "бітова маска: кожен біт — окрема опція"), ("_OPTIONS", "бітова маска додаткових опцій"), ("_BITMASK", "бітова маска"),
        ("_TYPE", "тип або вибір варіанта зі списку"), ("_MODE", "режим роботи (номер варіанта)"), ("_SRC", "джерело даних (номер варіанта)"),
        ("_TIME", "час, найімовірніше в секундах"), ("_TIMEOUT", "тайм-аут, найімовірніше в секундах або мілісекундах"), ("_DELAY", "затримка"),
        ("_MS", "значення в мілісекундах"), ("_HZ", "частота, Гц"), ("_RATE", "швидкість або частота"),
        ("_DIST", "відстань, найімовірніше в метрах"), ("_ALT", "висота, найімовірніше в метрах"), ("_CM", "значення в сантиметрах"), ("_M", "значення в метрах"),
        ("_SPD", "швидкість"), ("_SPEED", "швидкість"), ("_ACCEL", "прискорення"),
        ("_DEG", "кут у градусах"), ("_ANGLE", "кут"), ("_LIM", "обмеження"), ("_MAX", "верхня межа"), ("_MIN", "нижня межа"),
        ("_P", "пропорційне підсилення (P) регулятора"), ("_I", "інтегральне підсилення (I) регулятора"), ("_D", "диференціальне підсилення (D) регулятора"),
        ("_FF", "пряма подача (feedforward)"), ("_IMAX", "обмеження інтегральної складової"), ("_FILT", "частота зрізу фільтра, Гц"),
        ("_PIN", "номер виводу (піна) плати"), ("_CHAN", "номер каналу"), ("_ID", "ідентифікатор"), ("_PCT", "значення у відсотках"), ("_PERCENT", "значення у відсотках"),
        ("_SCALE", "масштабний коефіцієнт"), ("_OFS", "зсув (offset)"), ("_OFFSET", "зсув (offset)"), ("_TRIM", "нейтральне положення чи підгонка"),
    ]

    static func hints(_ name: String, isInt: Bool, value: Double) -> [String] {
        var out: [String] = []
        if let g = name.split(separator: "_").first, name.contains("_") { out.append(String(localized: "Група «\(String(g))_»: параметри однієї підсистеми, див. схожі нижче."))}
        if let m = suffixes.filter({ name.hasSuffix($0.0) }).max(by: { $0.0.count < $1.0.count }) { out.append(String(localized: "Закінчення «\(m.0)»: \(loc(m.1)).")) }
        if isInt && (value == 0 || value == 1) && out.count < 3 { out.append(String(localized: "Значення 0 або 1: схоже на перемикач.")) }
        return out
    }

    /// Пошук імені параметра в репозиторії ArduPilot.
    static func searchURL(_ name: String) -> URL? {
        var c = URLComponents(string: "https://github.com/search")
        c?.queryItems = [.init(name: "q", value: "repo:ArduPilot/ardupilot \"\(name)\""), .init(name: "type", value: "code")]
        return c?.url
    }
    static func docsURL(_ name: String) -> URL? { URL(string: "https://ardupilot.org/dev/docs/parameters.html#" + name.lowercased().replacingOccurrences(of: "_", with: "-")) }
}
