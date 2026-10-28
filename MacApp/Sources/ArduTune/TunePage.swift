import SwiftUI

// MARK: - Рядок параметра з повзунком, підказкою та записом в історію

struct TuneRow: View {
    @Environment(Store.self) var s
    let name: String
    var context = ""
    var describe = true
    @State private var value = 0.0
    @State private var editing = false
    @State private var showTip = false
    @State private var text = ""
    @FocusState private var focused: Bool
    var ps: ParamStore { s.ps }
    var meta: ParamMeta? { ps.meta[name] }
    var tip: TuneTip? { TuneTips.tip(name) }

    func write(_ v: Double) {
        guard !s.armed else { return }
        s.tune.apply(ps, [name: TunePresets.clamp(ps, name, v)], label: loc("Ручні зміни") + (context.isEmpty ? "" : ": \(context)"), merge: true)
    }

    var title: String { ParamTexts.info(name)?.title ?? tip?.title ?? ps.tr[meta?.label ?? ""] ?? meta?.label ?? name }
    var desc: String? { ParamTexts.info(name)?.text ?? tip?.what ?? ParamTexts.shortDoc(ps.tr[meta?.doc ?? ""] ?? meta?.doc) }

    var body: some View {
        let cur = ps.val(name)
        let base = s.tune.baseline[name]
        let changed = base != nil && cur != nil && abs(base! - cur!) > 1e-9
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(LocalizedStringKey(title)).font(.callout).lineLimit(2)
                        if changed { Circle().fill(Color.orange).frame(width: 6, height: 6).tip("Змінено порівняно з початковим значенням") }
                    }
                    Text(LocalizedStringKey(name)).font(.system(.caption2, design: .monospaced)).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 8)
                control(cur)
                if tip != nil {
                    Button { withAnimation(.snappy(duration: 0.18)) { showTip.toggle() } } label: {
                        Image(systemName: showTip ? "lightbulb.fill" : "lightbulb").font(.system(size: 14, weight: .medium)).foregroundStyle(showTip ? Color.yellow : Color.secondary)
                            .frame(width: 28, height: 28).background(Color.primary.opacity(showTip ? 0.12 : 0.07), in: Circle()).contentShape(Circle())
                    }.buttonStyle(.plain).tip("Порада щодо налаштування")
                } else { Color.clear.frame(width: 28, height: 1) }
                Button { if let b = base { write(b) } } label: { Image(systemName: "arrow.uturn.backward") }
                    .buttonStyle(.borderless).opacity(changed ? 1 : 0).disabled(!changed || s.armed).tip("Повернути початкове значення")
            }
            if describe, let d = desc {
                Text(LocalizedStringKey(d)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).frame(maxWidth: 560, alignment: .leading)
            }
            if showTip, let t = tip {
                VStack(alignment: .leading, spacing: 5) {
                    line("info.circle", "Що це", t.what)
                    line("slider.horizontal.3", "Як налаштовувати", t.howTo)
                    line("exclamationmark.triangle", "Увага", t.warning)
                }
                .padding(10)
                .background(Color.yellow.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .transition(.opacity)
            }
        }
        .padding(.vertical, 5)
        .onAppear { sync(cur) }
        .onChange(of: cur) { _, v in if !editing && !focused { sync(v) } }
    }

    func line(_ icon: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).font(.caption).foregroundStyle(.secondary).frame(width: 14)
            (Text(lk(title + ": ")).fontWeight(.semibold) + Text(LocalizedStringKey(text))).font(.caption).fixedSize(horizontal: false, vertical: true)
        }
    }

    func sync(_ v: Double?) { if let v { value = v; text = fmt(v, isInt: ps.find(name)?.isInt ?? false) } }

    @ViewBuilder func control(_ cur: Double?) -> some View {
        if let m = meta, let vals = m.values, !vals.isEmpty, vals.count <= 30 {
            Picker("", selection: Binding(get: { Int(cur ?? 0) }, set: { write(Double($0)) })) {
                ForEach(vals, id: \.self) { kv in Text(lk(kv.count > 1 ? kv[1] : kv[0])).tag(Int(kv[0]) ?? 0) }
            }.labelsHidden().frame(width: 220).disabled(s.armed || cur == nil)
        } else if let m = meta, let bits = m.bits, !bits.isEmpty {
            let c = Int(cur ?? 0)
            Menu {
                ForEach(bits, id: \.self) { kv in
                    let b = Int(kv[0]) ?? 0
                    Toggle(lk(kv.count > 1 ? kv[1] : String(localized: "біт \(b)")), isOn: Binding(get: { (c >> b) & 1 == 1 }, set: { _ in write(Double(c ^ (1 << b))) }))
                }
            } label: { Text("вибрано: \(bits.filter { (c >> (Int($0[0]) ?? 0)) & 1 == 1 }.count)").frame(width: 130, alignment: .leading) }
            .menuStyle(.borderlessButton).disabled(s.armed)
        } else {
            HStack(spacing: 6) {
                StepField(name: name, context: context, width: 74)
                Text(lk(meta?.units ?? "")).font(.caption).foregroundStyle(.secondary).frame(width: 34, alignment: .leading)
            }
        }
    }
}

/// Значення параметра з кнопками − і +: точне підлаштування малими кроками (Option = крок ×10). Крок береться з метаданих.
struct StepField: View {
    @Environment(Store.self) var s
    let name: String
    var context = ""
    var width: CGFloat = 64
    @State private var text = ""
    @FocusState private var focused: Bool
    var ps: ParamStore { s.ps }

    var isInt: Bool { ps.find(name)?.isInt ?? false }
    var step: Double {
        if let inc = ps.meta[name]?.inc, inc > 0 { return inc }
        if isInt { return 1 }
        let v = abs(ps.val(name) ?? 1)
        return v == 0 ? 0.01 : max(0.001, pow(10, floor(log10(v)) - 1))
    }

    func write(_ v: Double) {
        guard !s.armed else { return }
        s.tune.apply(ps, [name: TunePresets.clamp(ps, name, v)], label: loc("Ручні зміни") + (context.isEmpty ? "" : ": \(context)"), merge: true)
    }
    func bump(_ dir: Double) {
        let mult = NSEvent.modifierFlags.contains(.option) ? 10.0 : 1.0
        let cur = ps.val(name) ?? 0
        write(cur + dir * step * mult)
    }

    var body: some View {
        let cur = ps.val(name)
        let base = s.tune.baseline[name]
        let changed = base != nil && cur != nil && abs(base! - cur!) > 1e-9
        HStack(spacing: 4) {
            Button { bump(-1) } label: { Image(systemName: "minus").font(.system(size: 10, weight: .bold)).frame(width: 22, height: 22).background(Color.primary.opacity(0.08), in: Circle()) }
                .buttonStyle(.plain).disabled(s.armed || cur == nil).tip("Зменшити на крок \(fmt(step, isInt: false)) (⌥ = ×10)")
            TextField("", text: $text).textFieldStyle(.plain).multilineTextAlignment(.center)
                .font(.system(.callout, design: .monospaced).weight(changed ? .semibold : .regular)).foregroundStyle(changed ? Color.orange : Color.primary)
                .frame(width: width).padding(.vertical, 3).background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .focused($focused).disabled(s.armed || cur == nil)
                .onSubmit { if let v = Double(text.replacingOccurrences(of: ",", with: ".")) { write(v) }; sync(ps.val(name)) }
            Button { bump(1) } label: { Image(systemName: "plus").font(.system(size: 10, weight: .bold)).frame(width: 22, height: 22).background(Color.primary.opacity(0.08), in: Circle()) }
                .buttonStyle(.plain).disabled(s.armed || cur == nil).tip("Збільшити на крок \(fmt(step, isInt: false)) (⌥ = ×10)")
        }
        .onAppear { sync(cur) }
        .onChange(of: cur) { _, v in if !focused { sync(v) } }
    }
    func sync(_ v: Double?) { text = v.map { fmt($0, isInt: isInt) } ?? "—" }
}

// MARK: - Сторінка PID та фільтрів

struct TuneView: View {
    @Environment(Store.self) var s
    @Environment(\.openWindow) private var openWindow
    @State private var showWorkflow = false
    var ps: ParamStore { s.ps }

    var body: some View {
        ConfigGate {
            if let m = TuneModel(ps) {
                content(m)
                    .onAppear { s.tune.captureBaseline(ps, names: m.allNames) }
            } else {
                ContentUnavailableView("PID недоступні", systemImage: "dial.medium", description: Text("У цій прошивці не знайдено параметрів швидкісних контролерів (ATC_RAT_*, RLL_RATE_*, RLL2SRV_*)."))
            }
        }
    }

    func kind(_ n: String) -> String { String(TuneTips.key(n).dropFirst(5)) }
    func name(_ axis: TuneAxis, _ k: String) -> String? { axis.rate.first { TuneTips.key($0) == "RATE_" + k } }

    @ViewBuilder func content(_ m: TuneModel) -> some View {
        header(m)
        PageTitle(title: String(localized: "Основні налаштування"), subtitle: String(localized: "Швидкісні PID по осях, фільтри вібрацій і стартовий пресет. Все інше в блоці «Додатково»."))
        pidMatrix(m, title: String(localized: "Швидкісні PID"), icon: "dial.medium", kinds: ["P", "I", "D", "FF"],
                  text: String(localized: "Кнопки − і + змінюють значення на мінімальний крок (⌥ = ×10). Лампочка біля стовпця показує пораду."), showAdvice: true, model: m)
        HStack(alignment: .top, spacing: 14) {
            TunePresetsCard(model: m)
            basicFilters(m)
        }

        AdvancedSection(key: "tune.advanced", subtitle: String(localized: "Фільтри осей, обмеження, кутовий контур, режекторний фільтр, навігація, історія та порівняння.")) {
            pidMatrix(m, title: String(localized: "Фільтри осей"), icon: "waveform.path", kinds: ["FLTT", "FLTD", "FLTE"], text: String(localized: "Частоти зрізу цілі, D-складової та помилки (Гц)."), showAdvice: false, model: m)
            pidMatrix(m, title: String(localized: "Обмеження"), icon: "gauge.with.dots.needle.33percent", kinds: ["IMAX", "SMAX"], text: String(localized: "Ліміт інтегралу й швидкості наростання виходу."), showAdvice: false, model: m)
            extraRateCard(m)
            outerCard(m)
            if !m.notch.isEmpty {
                card("Гармонічний режекторний фільтр (notch)", "waveform.path.ecg", "Вирізає вузький пік шуму на частоті моторів. Вмикайте, лише коли вібрації помітні, після налаштування основних фільтрів.", m.notch, ctx: "Notch")
            }
            if !m.position.isEmpty {
                card(m.kind == .copter ? "Утримання позиції та висоти" : "Енергія, висота й навігація літака", "scope", m.kind == .copter ? "Контролер позиції. Змінюйте лише після налаштування швидкісних PID." : "TECS керує висотою й швидкістю, L1 керує траєкторією. Змінюйте обережно.", m.position, ctx: "Навігація")
            }
            PageTitle(title: String(localized: "Зміни й порівняння"), subtitle: String(localized: "Історія змін, знімки та порівняння конфігурацій без перезавантаження сторінки."))
            TuneHistoryCard(model: m)
            RebootRow(text: String(localized: "Режекторний фільтр, частота дискретизації гіроскопа та деякі інші параметри застосовуються після перезавантаження автопілота."))
        }
    }

    func header(_ m: TuneModel) -> some View {
        HStack(spacing: 12) {
            Pill(text: m.title, tint: .blue)
            Text("\(m.allNames.count) параметрів").font(.caption).foregroundStyle(.secondary)
            Spacer()
            TuneVibeStrip()
            Button { showWorkflow.toggle() } label: { Label("Порадник", systemImage: "questionmark.circle") }
                .popover(isPresented: $showWorkflow, arrowEdge: .bottom) { workflow }
            Button { openWindow(id: "pidgame") } label: { Label("Тренажер PID", systemImage: "gamecontroller.fill") }
                .tip("Інтерактивна гра у віртуальному дроні в окремому вікні; нічого не змінює на реальному апараті")
        }
    }

    var workflow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Як налаштовувати безпечно").font(.headline)
            ForEach(Array(TuneTips.workflow.enumerated()), id: \.offset) { i, w in
                HStack(alignment: .top, spacing: 10) {
                    Text("\(i + 1)").font(.caption.weight(.bold)).frame(width: 20, height: 20).background(Color.primary.opacity(0.1), in: Circle())
                    VStack(alignment: .leading, spacing: 1) {
                        Text(LocalizedStringKey(w.0)).font(.callout.weight(.semibold))
                        Text(LocalizedStringKey(w.1)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }.padding(16).frame(width: 420)
    }

    /// Компактна таблиця: рядки це осі, стовпці це типи параметрів.
    func pidMatrix(_ m: TuneModel, title: String, icon: String, kinds: [String], text: String, showAdvice: Bool, model: TuneModel) -> some View {
        let axes = m.axes.filter { a in kinds.contains { name(a, $0) != nil } }
        return Group {
            if !axes.isEmpty {
                Card(title: title, icon: icon, text: text) {
                    Grid(alignment: .center, horizontalSpacing: 12, verticalSpacing: 8) {
                        GridRow {
                            Text("").gridColumnAlignment(.leading)
                            ForEach(kinds, id: \.self) { k in MatrixHeader(kind: k, sample: axes.compactMap { name($0, k) }.first) }
                        }
                        Divider().gridCellColumns(kinds.count + 1)
                        ForEach(axes) { a in
                            GridRow {
                                Label(LocalizedStringKey(a.title), systemImage: a.icon).font(.callout).labelStyle(.titleAndIcon).frame(width: 150, alignment: .leading)
                                ForEach(kinds, id: \.self) { k in
                                    if let n = name(a, k) { StepField(name: n, context: a.title, width: 64) } else { Text("—").foregroundStyle(.tertiary).frame(width: 130) }
                                }
                            }
                        }
                    }
                    if showAdvice { TuneAdviceInline(model: model) }
                }
            }
        }
    }

    /// Фільтри гіроскопа й акселерометра: два компактні рядки.
    func basicFilters(_ m: TuneModel) -> some View {
        let names = m.filters.filter { $0 == "INS_GYRO_FILTER" || $0 == "INS_ACCEL_FILTER" }
        return Card(title: String(localized: "Фільтри"), icon: "waveform.path", text: String(localized: "Спершу переконайтеся, що вібрація нормальна.")) {
            ForEach(names, id: \.self) { n in
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(lk(TuneTips.tip(n)?.title ?? n)).font(.callout)
                        Text(LocalizedStringKey(n)).font(.system(.caption2, design: .monospaced)).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    StepField(name: n, context: "Фільтри", width: 54); Text("Гц").font(.caption).foregroundStyle(.secondary)
                    if TuneTips.tip(n) != nil { TipButton(name: n) }
                }
            }
            if names.contains("INS_GYRO_FILTER") { FilterCurveCard() }
        }
        .frame(maxWidth: 380)
    }

    func extraRateCard(_ m: TuneModel) -> some View {
        let std: Set<String> = ["P", "I", "D", "FF", "FLTT", "FLTD", "FLTE", "IMAX", "SMAX"]
        let extra = m.axes.flatMap { a in a.rate.filter { !std.contains(kind($0)) || !TuneTips.key($0).hasPrefix("RATE_") }.map { (a, $0) } }
        return Group {
            if !extra.isEmpty {
                Card(title: String(localized: "Інші параметри осей"), icon: "ellipsis.circle", text: nil) {
                    VStack(spacing: 0) { ForEach(extra, id: \.1) { TuneRow(name: $0.1, context: $0.0.title); Divider().opacity(0.4) } }
                }
            }
        }
    }

    func outerCard(_ m: TuneModel) -> some View {
        Card(title: String(localized: "Кутовий контур й загальні"), icon: "gyroscope", text: String(localized: "Як швидко апарат займає й утримує задане положення. Змінюйте після швидкісних PID.")) {
            ForEach(m.axes.filter { !$0.outer.isEmpty }) { a in
                Text(verbatim: loc(a.title).uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 4)
                VStack(spacing: 0) { ForEach(a.outer, id: \.self) { TuneRow(name: $0, context: a.title); Divider().opacity(0.4) } }
            }
            let extraFilters = m.filters.filter { $0 != "INS_GYRO_FILTER" && $0 != "INS_ACCEL_FILTER" }
            if !m.global.isEmpty || !extraFilters.isEmpty {
                Text("ЗАГАЛЬНІ").font(.caption2.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 8)
                VStack(spacing: 0) { ForEach(m.global + extraFilters, id: \.self) { TuneRow(name: $0, context: "Загальні"); Divider().opacity(0.4) } }
            }
        }
    }

    func card(_ title: String, _ icon: String, _ text: String?, _ names: [String], ctx: String) -> some View {
        Card(title: title, icon: icon, text: text) {
            VStack(spacing: 0) { ForEach(names, id: \.self) { TuneRow(name: $0, context: ctx); Divider().opacity(0.4) } }
        }
    }
}

/// Заголовок стовпця таблиці з кнопкою поради.
struct MatrixHeader: View {
    let kind: String
    let sample: String?
    @State private var show = false
    static let names = ["P": "P", "I": "I", "D": "D", "FF": "FF", "FLTT": "FLTT", "FLTD": "FLTD", "FLTE": "FLTE", "IMAX": "IMAX", "SMAX": "SMAX"]
    var body: some View {
        HStack(spacing: 6) {
            Text(lk(Self.names[kind] ?? kind)).font(.system(size: 19, weight: .bold, design: .rounded))
            if let s = sample, TuneTips.tip(s) != nil {
                Button { show.toggle() } label: {
                    Image(systemName: show ? "lightbulb.fill" : "lightbulb").font(.system(size: 15, weight: .medium))
                        .foregroundStyle(show ? Color.yellow : Color.secondary)
                        .frame(width: 30, height: 30)
                        .background(Color.primary.opacity(show ? 0.12 : 0.07), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain).tip("Порада щодо параметра \(loc(kind))")
                .popover(isPresented: $show, arrowEdge: .bottom) { TipView(tip: TuneTips.tip(s)!) }
            }
        }
        .frame(width: 130)
    }
}

struct TipView: View {
    let tip: TuneTip
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(LocalizedStringKey(tip.title)).font(.headline)
            row("info.circle", "Що це", tip.what)
            row("slider.horizontal.3", "Як налаштовувати", tip.howTo)
            row("exclamationmark.triangle", "Увага", tip.warning)
        }.padding(14).frame(width: 340)
    }
    func row(_ icon: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).font(.caption).foregroundStyle(.secondary).frame(width: 14)
            (Text(lk(title + ": ")).fontWeight(.semibold) + Text(LocalizedStringKey(text))).font(.caption).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct TipButton: View {
    let name: String
    @State private var show = false
    var body: some View {
        if let t = TuneTips.tip(name) {
            Button { show.toggle() } label: {
                Image(systemName: show ? "lightbulb.fill" : "lightbulb").font(.system(size: 14, weight: .medium)).foregroundStyle(show ? Color.yellow : Color.secondary)
                    .frame(width: 28, height: 28).background(Color.primary.opacity(show ? 0.12 : 0.07), in: Circle()).contentShape(Circle())
            }.buttonStyle(.plain).tip("Порада")
            .popover(isPresented: $show, arrowEdge: .bottom) { TipView(tip: t) }
        }
    }
}

/// Жива вібрація: окремий компонент, щоб 10-герцова телеметрія не перемальовувала всю сторінку.
struct TuneVibeStrip: View {
    @Environment(Store.self) var s
    var body: some View {
        let mx = max(s.t.vibeX, s.t.vibeY, s.t.vibeZ)
        HStack(spacing: 8) {
            Image(systemName: "waveform").foregroundStyle(mx > 30 ? .red : (mx > 15 ? .orange : .green))
            Text(String(format: loc("Вібрація X %.1f  Y %.1f  Z %.1f м/с²"), s.t.vibeX, s.t.vibeY, s.t.vibeZ)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 5).background(Color.primary.opacity(0.06), in: Capsule())
    }
}

/// Стислий підсумок перевірки конфігурації з розгортанням.
struct TuneAdviceInline: View {
    @Environment(Store.self) var s
    let model: TuneModel
    @State private var open = false
    var body: some View {
        let list = TuneLint.run(s.ps, model, vibe: max(s.t.vibeX, s.t.vibeY, s.t.vibeZ))
        let warns = list.filter { $0.level == .warn }.count, infos = list.filter { $0.level == .info }.count
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            Button { withAnimation(.snappy(duration: 0.18)) { open.toggle() } } label: {
                HStack(spacing: 8) {
                    Image(systemName: warns > 0 ? "exclamationmark.triangle.fill" : (infos > 0 ? "lightbulb.fill" : "checkmark.circle.fill")).foregroundStyle(warns > 0 ? .orange : (infos > 0 ? .secondary : .green))
                    Text(lk(warns + infos == 0 ? "Перевірка конфігурації: зауважень немає" : String(localized: "Перевірка конфігурації: \(warns > 0 ? String(localized: "\(warns) важливих, ") : "")\(infos) порад"))).font(.callout)
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary).rotationEffect(.degrees(open ? 90 : 0))
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            if open {
                ForEach(list) { a in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: a.icon).foregroundStyle(a.color).frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(LocalizedStringKey(a.title)).font(.callout.weight(.semibold))
                            Text(LocalizedStringKey(a.detail)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Пресети

struct TunePresetsCard: View {
    @Environment(Store.self) var s
    let model: TuneModel
    @State private var selected: String?
    @State private var values: [String: Double] = [:]
    @State private var note: String?
    var ps: ParamStore { s.ps }

    var presets: [TunePreset] { TunePresets.presets(for: model) }

    func choose(_ p: TunePreset) {
        selected = p.id
        values = p.id == "baseline" ? s.tune.baseline.filter { ps.val($0.key) != nil } : p.values(ps, model)
        note = nil
    }
    var diff: [(String, Double, Double)] {
        values.compactMap { n, v in
            guard let cur = ps.val(n), abs(cur - v) > 1e-9 else { return nil }
            return (n, cur, v)
        }.sorted { $0.0 < $1.0 }
    }

    var body: some View {
        Card(title: String(localized: "Пресети"), icon: "square.stack.3d.up", text: String(localized: "Відправна точка, а не готове налаштування. Завжди з переглядом змін і відкатом в історії.")) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(presets) { p in
                        let on = selected == p.id
                        Button { choose(p) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Image(systemName: p.icon).font(.system(size: 15, weight: .semibold))
                                Text(LocalizedStringKey(p.title)).font(.callout.weight(.semibold)).lineLimit(2).multilineTextAlignment(.leading)
                                Text(LocalizedStringKey(p.subtitle)).font(.caption2).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.leading)
                            }
                            .padding(9).frame(width: 150, height: 92, alignment: .topLeading)
                            .background(on ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(on ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.08), lineWidth: on ? 1.5 : 1))
                        }.buttonStyle(.plain)
                    }
                }.padding(.vertical, 2)
            }
            if selected != nil {
                if diff.isEmpty {
                    Label("Цей набір не змінює поточних значень.", systemImage: "checkmark.circle").font(.callout).foregroundStyle(.secondary)
                } else {
                    Text("ЩО ЗМІНИТЬСЯ (\(diff.count))").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 3) {
                        GridRow { Text("Параметр").bold(); Text("Зараз").bold(); Text("Стане").bold(); Text("Зміна").bold() }.font(.caption).foregroundStyle(.secondary)
                        ForEach(diff.prefix(40), id: \.0) { r in
                            GridRow {
                                Text(LocalizedStringKey(r.0)).font(.system(.caption, design: .monospaced))
                                Text(lk(fmt(r.1, isInt: false))).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                                Text(lk(fmt(r.2, isInt: false))).font(.system(.caption, design: .monospaced).weight(.semibold)).foregroundStyle(.blue)
                                Text(lk(r.1 != 0 ? String(format: "%+.0f%%", (r.2 - r.1) / abs(r.1) * 100) : "")).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if diff.count > 40 { Text("… і ще \(diff.count - 40)").font(.caption).foregroundStyle(.secondary) }
                    HStack {
                        Button { apply() } label: { Label("Застосувати (\(diff.count))", systemImage: "checkmark") }.buttonStyle(.borderedProminent).disabled(s.armed)
                        Button("Скасувати") { selected = nil; values = [:] }
                        Spacer()
                    }
                }
            }
            if let n = note { Label(LocalizedStringKey(n), systemImage: "checkmark.circle.fill").font(.callout).foregroundStyle(.green) }
        }
    }

    func apply() {
        guard let id = selected, let p = presets.first(where: { $0.id == id }) else { return }
        s.tune.apply(ps, values, label: loc("Пресет: ") + p.title)
        note = String(localized: "Застосовано. Зміну можна відкотити в блоці «Зміни й порівняння».")
        selected = nil; values = [:]
    }
}

// MARK: - Історія, знімки, порівняння

struct TuneHistoryCard: View {
    @Environment(Store.self) var s
    let model: TuneModel
    @State private var tab = "history"
    @State private var source = "baseline"            // baseline | snapshot:<id> | file
    @State private var file: (name: String, values: [String: Double])?
    var ps: ParamStore { s.ps }
    var tune: TuneStore { s.tune }

    static let df: DateFormatter = { let f = DateFormatter(); f.dateStyle = .short; f.timeStyle = .short; return f }()

    var body: some View {
        Card(title: String(localized: "Історія змін і знімки"), icon: "clock.arrow.circlepath", text: nil) {
            Picker("", selection: $tab) {
                Text("Історія (\(tune.history.count))").tag("history")
                Text("Знімки (\(tune.snapshots.count))").tag("snapshots")
                Text("Порівняння").tag("compare")
            }.pickerStyle(.segmented).labelsHidden().frame(width: 420)
            switch tab {
            case "snapshots": snapshots
            case "compare": compare
            default: history
            }
        }
    }

    // MARK: Історія
    var history: some View {
        VStack(alignment: .leading, spacing: 6) {
            if tune.history.isEmpty { Text("Змін ще не було. Тут зберігатимуться пресети й ручні зміни параметрів з можливістю відкату.").font(.callout).foregroundStyle(.secondary) }
            ForEach(Array(tune.history.suffix(40).reversed())) { e in
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(e.changes, id: \.name) { c in
                            HStack(spacing: 10) {
                                Text(LocalizedStringKey(c.name)).font(.system(.caption, design: .monospaced)).frame(width: 170, alignment: .leading)
                                Text(lk(fmt(c.old, isInt: false))).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                                Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
                                Text(lk(fmt(c.new, isInt: false))).font(.system(.caption, design: .monospaced).weight(.semibold))
                            }
                        }
                        HStack {
                            Button("Відкотити") { tune.revert(ps, e) }.disabled(s.armed)
                            Button("Видалити запис") { tune.deleteEntry(e.id) }
                        }.padding(.top, 4)
                    }.padding(.vertical, 4)
                } label: {
                    HStack {
                        Text(LocalizedStringKey(e.label)).font(.callout)
                        Spacer()
                        Text("\(e.changes.count) парам.").font(.caption).foregroundStyle(.secondary)
                        Text(lk(Self.df.string(from: e.date))).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: Знімки
    var snapshots: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                guard let r = Prompt.ask("Новий знімок", message: String(localized: "Збереже поточні значення PID і фільтрів."), fields: [("Назва", loc("Знімок ") + Self.df.string(from: Date()))]), !r[0].isEmpty else { return }
                tune.addSnapshot(ps, name: r[0], names: model.allNames)
            } label: { Label("Зберегти поточні налаштування як знімок", systemImage: "camera") }
            if tune.snapshots.isEmpty { Text("Знімків ще немає. Зберігайте знімок перед серією змін, щоб повернутися одним кліком.").font(.callout).foregroundStyle(.secondary) }
            ForEach(tune.snapshots) { sn in
                HStack(spacing: 10) {
                    Image(systemName: "camera.fill").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(LocalizedStringKey(sn.name)).font(.callout)
                        Text("\(Self.df.string(from: sn.date)) · \(sn.values.count) параметрів").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Порівняти") { source = "snapshot:\(sn.id.uuidString)"; tab = "compare" }
                    Button("Застосувати") { tune.apply(ps, sn.values, label: loc("Знімок: ") + sn.name) }.disabled(s.armed)
                    Button(role: .destructive) { tune.deleteSnapshot(sn.id) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                }
            }
        }
    }

    // MARK: Порівняння
    var otherValues: (String, [String: Double])? {
        if source == "baseline" { return ("Початкові значення", tune.baseline) }
        if source == "file" { return file.map { ($0.name, $0.values) } }
        if source.hasPrefix("snapshot:"), let id = UUID(uuidString: String(source.dropFirst(9))), let sn = tune.snapshots.first(where: { $0.id == id }) { return (sn.name, sn.values) }
        return nil
    }

    var compare: some View {
        let other = otherValues
        let rows: [(String, Double, Double)] = {
            guard let o = other?.1 else { return [] }
            return model.allNames.compactMap { n in
                guard let cur = ps.val(n), let ov = o[n], abs(cur - ov) > 1e-9 else { return nil }
                return (n, cur, ov)
            }
        }()
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("Порівняти поточні значення з:").font(.callout)
                Picker("", selection: $source) {
                    Text("Початкові значення").tag("baseline")
                    ForEach(tune.snapshots) { Text("Знімок: \(loc($0.name))").tag("snapshot:\($0.id.uuidString)") }
                    Text(lk(file.map { String(localized: "Файл: \(loc($0.name))") } ?? "Файл .param…")).tag("file")
                }.labelsHidden().frame(width: 300)
                Button("Обрати файл…") {
                    if let f = chooseParamFileToOpen() { file = (name: f.0, values: f.1); source = "file" }
                }
            }
            if other == nil { Text("Оберіть файл .param, щоб порівняти.").font(.callout).foregroundStyle(.secondary) }
            else if rows.isEmpty { Label("Різниць немає: значення збігаються (\(other!.0)).", systemImage: "checkmark.circle").font(.callout).foregroundStyle(.secondary) }
            else {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 3) {
                    GridRow { Text("Параметр").bold(); Text("Зараз").bold(); Text(lk(other!.0)).bold().lineLimit(1); Text("") }.font(.caption).foregroundStyle(.secondary)
                    ForEach(rows.prefix(80), id: \.0) { r in
                        GridRow {
                            Text(LocalizedStringKey(r.0)).font(.system(.caption, design: .monospaced))
                            Text(lk(fmt(r.1, isInt: false))).font(.system(.caption, design: .monospaced))
                            Text(lk(fmt(r.2, isInt: false))).font(.system(.caption, design: .monospaced).weight(.semibold)).foregroundStyle(.blue)
                            Button { tune.apply(ps, [r.0: r.2], label: loc("З порівняння: ") + other!.0, merge: true) } label: { Image(systemName: "arrow.left") }.buttonStyle(.borderless).disabled(s.armed).tip("Прийняти значення з порівнюваного набору")
                        }
                    }
                }
                HStack {
                    Button { tune.apply(ps, Dictionary(uniqueKeysWithValues: rows.map { ($0.0, $0.2) }), label: loc("З порівняння: ") + other!.0) } label: { Label("Застосувати все (\(rows.count))", systemImage: "checkmark") }.disabled(s.armed)
                    Text("\(rows.count) відмінностей").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}
