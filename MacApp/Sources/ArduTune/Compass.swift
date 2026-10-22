import SwiftUI

/// Сторінка «Compass» за зразком Mission Planner: пріоритет, використання, onboard-калібрування.
struct CompassView: View {
    @Environment(Store.self) var s
    @State private var cs = CalStore()
    @State private var confirmReboot = false
    @State private var rebootNote: String?
    @State private var showLarge = false
    @State private var rebootHint: String?
    var ps: ParamStore { s.ps }
    var armed: Bool { s.armed }

    func pv(_ n: String) -> Double? { ps.params.first { $0.name == n }?.value }
    func setP(_ n: String, _ v: Double) { if let p = ps.params.first(where: { $0.name == n }) { ps.set(p, to: v) } }
    func metaValues(_ n: String, fallback: [[String]]) -> [[String]] { ps.meta[n]?.values ?? fallback }

    struct Row: Identifiable {
        var id: Int { prio }
        let prio: Int            // 1…3
        let prioName: String?    // COMPASS_PRIOn_ID (nil, якщо у прошивці немає)
        let devid: Int
        let slot: Int?           // позиція в COMPASS_DEV_ID (nil = відсутній)
    }

    var devSlots: [Int] { ["COMPASS_DEV_ID", "COMPASS_DEV_ID2", "COMPASS_DEV_ID3"].map { Int(pv($0) ?? 0) } }

    var rows: [Row] {
        let slots = devSlots
        var out: [Row] = []
        for i in 1...3 {
            let n = "COMPASS_PRIO\(i)_ID"
            guard let v = pv(n), Int(v) != 0 else { continue }
            out.append(Row(prio: i, prioName: n, devid: Int(v), slot: slots.firstIndex(of: Int(v)).map { $0 + 1 }))
        }
        if out.isEmpty {   // старі прошивки без PRIO-параметрів
            for (i, d) in slots.enumerated() where d != 0 { out.append(Row(prio: i + 1, prioName: nil, devid: d, slot: i + 1)) }
        }
        return out
    }

    var present: Bool { !devSlots.allSatisfy { $0 == 0 } || !rows.isEmpty }
    var enabled: Bool? { pv("COMPASS_ENABLE").map { $0 != 0 } }
    func slotName(_ base: String, _ slot: Int) -> String { slot == 1 ? base : base + String(slot) }
    func extName(_ slot: Int) -> String { slot == 1 ? "COMPASS_EXTERNAL" : "COMPASS_EXTERN\(slot)" }
    func orientName(_ slot: Int) -> String { slot == 1 ? "COMPASS_ORIENT" : "COMPASS_ORIENT\(slot)" }
    func useName(_ slot: Int) -> String { slot == 1 ? "COMPASS_USE" : "COMPASS_USE\(slot)" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                OfflineBanner()
                if !s.canView {
                    ContentUnavailableView("Польотник не підключений", systemImage: "cable.connector", description: Text("Підключіть плату по USB"))
                } else if ps.params.isEmpty {
                    ProgressView("Завантаження параметрів…")
                } else {
                    if s.armedLive { Label("Апарат ARMED: зміни та калібрування заблоковано", systemImage: "lock.fill").foregroundStyle(.red) }
                    if let n = cs.note { Label(LocalizedStringKey(n), systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                    enableCard
                    if present {
                        primaryCard
                        priorityCard
                        useCard
                        calCard
                        CompassMotCard(cs: cs)
                    } else {
                        Card(title: String(localized: "Компас не виявлено"), icon: "nosign", text: enabled == false ? "Компас вимкнено в прошивці (COMPASS_ENABLE = 0). Увімкніть його та перезавантажте автопілот." : "Жодного компаса не знайдено. Перевірте підключення та перезавантажте автопілот.") { EmptyView() }
                    }
                    HStack {
                        Button { confirmReboot = true } label: { Label("Перезавантажити автопілот", systemImage: "restart") }.disabled(armed)
                        if let r = rebootNote { Text(LocalizedStringKey(r)).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
            .padding()
        }
        .onAppear { cs.start() }
        .onDisappear { cs.stop() }
        .sheet(isPresented: $showLarge) { LargeVehicleSheet(cs: cs, usedMask: usedMask, lat: s.t.lat, lon: s.t.lon, hasFix: s.t.gpsFix >= 3, heading: s.t.heading) }
        .confirmationDialog("Перезавантажити автопілот?", isPresented: $confirmReboot) {
            Button("Перезавантажити", role: .destructive) {
                EngineAPI.post("/reboot") { ok, err in rebootNote = ok ? "Команду надіслано, чекаємо повернення польотника…" : (err == "armed" ? "Недоступно: ARMED" : "Помилка") }
            }
        } message: { Text("З'єднання тимчасово зникне й відновиться автоматично.") }
    }

    // MARK: Увімкнення
    var enableCard: some View {
        Card(title: String(localized: "Компас"), icon: "safari", text: nil) {
            Toggle("Компас увімкнено (COMPASS_ENABLE)", isOn: Binding(get: { enabled ?? false }, set: { setP("COMPASS_ENABLE", $0 ? 1 : 0) }))
                .disabled(armed || enabled == nil)
            Text("Зміна вимагає перезавантаження автопілота.").font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Основний компас
    var primaryCard: some View {
        Card(title: String(localized: "Основний компас"), icon: "star", text: String(localized: "Основний компас використовується для курсу в першу чергу. Зміна вимагає перезавантаження автопілота.")) {
            let list = rows
            if list.count < 2 {
                Text(lk(list.first.map { String(localized: "Єдиний компас: \(sensorName(DevID(raw: $0.devid), .compass))") } ?? "")).font(.callout).foregroundStyle(.secondary)
            } else {
                Picker("Основний", selection: Binding(
                    get: { list.first?.devid ?? 0 },
                    set: { setPrimary(devid: $0) })) {
                    ForEach(list) { r in
                        Text("Компас \(r.prio): \(sensorName(DevID(raw: r.devid), .compass)) (\(DevID(raw: r.devid).busName))").tag(r.devid)
                    }
                }
                .pickerStyle(.radioGroup).disabled(armed || list.first?.prioName == nil && pv("COMPASS_PRIMARY") == nil)
            }
            if let m = rebootHint { Label(LocalizedStringKey(m), systemImage: "arrow.triangle.2.circlepath").font(.caption).foregroundStyle(.orange) }
        }
    }

    /// Робить компас з даним DevID пріоритетом №1, решту зсуває вниз зі збереженням порядку.
    func setPrimary(devid: Int) {
        let ids = rows.map(\.devid)
        guard ids.first != devid, ids.contains(devid) else { return }
        if pv("COMPASS_PRIO1_ID") != nil {
            let order = [devid] + ids.filter { $0 != devid }
            for (i, id) in order.enumerated() { setP("COMPASS_PRIO\(i + 1)_ID", Double(id)) }
        } else if let slot = devSlots.firstIndex(of: devid) {
            setP("COMPASS_PRIMARY", Double(slot))
        }
        rebootHint = String(localized: "Порядок змінено. Перезавантажте автопілот, щоб застосувати.")
    }

    // MARK: Пріоритет
    var priorityCard: some View {
        Card(title: String(localized: "Пріоритет компасів"), icon: "list.number", text: String(localized: "Порядок задається таблицею (найвищий зверху). Для зміни порядку потрібне перезавантаження автопілота.")) {
            let orient = metaValues("COMPASS_ORIENT", fallback: [["0", "None"]])
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                GridRow {
                    ForEach(["Пріор.", "DevID", "Шина", "№", "Адреса", "Тип", "Відсутній", "Зовнішній", "Орієнтація", ""], id: \.self) { Text(lk($0)).font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
                }
                Divider().gridCellColumns(10)
                ForEach(rows) { r in
                    let d = DevID(raw: r.devid)
                    GridRow {
                        HStack(spacing: 4) { Text("\(r.prio)"); if r.prio == 1 { Image(systemName: "star.fill").foregroundStyle(.yellow).font(.caption) } }
                        Text("\(r.devid)").font(.system(.body, design: .monospaced))
                        Text(LocalizedStringKey(d.busName))
                        Text("\(d.bus)")
                        Text("\(d.address)")
                        Text(lk(sensorName(d, .compass))).fontWeight(.medium)
                        Image(systemName: r.slot == nil ? "checkmark.square.fill" : "square").foregroundStyle(r.slot == nil ? .orange : .secondary)
                        if let sl = r.slot {
                            Toggle("", isOn: Binding(get: { (pv(extName(sl)) ?? 0) != 0 }, set: { setP(extName(sl), $0 ? 1 : 0) })).toggleStyle(.checkbox).labelsHidden().disabled(armed)
                            Picker("", selection: Binding(get: { Int(pv(orientName(sl)) ?? 0) }, set: { setP(orientName(sl), Double($0)) })) {
                                ForEach(orient, id: \.self) { kv in Text(lk(kv.count > 1 ? kv[1] : kv[0])).tag(Int(kv[0]) ?? 0) }
                            }.labelsHidden().frame(width: 190).disabled(armed)
                        } else { Text("—"); Text("—") }
                        HStack(spacing: 4) {
                            Button { swapPrio(r.prio, r.prio - 1) } label: { Image(systemName: "arrow.up") }.disabled(r.prioName == nil || r.prio == 1 || armed)
                            Button { swapPrio(r.prio, r.prio + 1) } label: { Image(systemName: "arrow.down") }.disabled(r.prioName == nil || r.prio >= 3 || armed)
                        }
                    }
                }
            }
        }
    }

    func swapPrio(_ a: Int, _ b: Int) {
        guard (1...3).contains(a), (1...3).contains(b), let va = pv("COMPASS_PRIO\(a)_ID"), let vb = pv("COMPASS_PRIO\(b)_ID") else { return }
        setP("COMPASS_PRIO\(a)_ID", vb); setP("COMPASS_PRIO\(b)_ID", va)
        rebootHint = String(localized: "Порядок змінено. Перезавантажте автопілот, щоб застосувати.")
    }

    // MARK: Використання
    var useCard: some View {
        Card(title: String(localized: "Використання компасів"), icon: "checklist", text: String(localized: "Вимкніть компаси, які не потрібно використовувати для визначення курсу.")) {
            HStack(spacing: 18) {
                ForEach(1...3, id: \.self) { n in
                    Toggle("Використовувати компас \(n)", isOn: Binding(get: { (pv(useName(n)) ?? 0) != 0 }, set: { setP(useName(n), $0 ? 1 : 0) }))
                        .disabled(armed || pv(useName(n)) == nil)
                }
            }
            HStack(spacing: 14) {
                Button("Прибрати відсутні") { removeMissing() }.disabled(armed || !rows.contains { $0.slot == nil && $0.prioName != nil })
                let learn = metaValues("COMPASS_LEARN", fallback: [["0", "Disabled"]])
                if pv("COMPASS_LEARN") != nil {
                    Picker("Автоматично вчити зміщення", selection: Binding(get: { Int(pv("COMPASS_LEARN") ?? 0) }, set: { setP("COMPASS_LEARN", Double($0)) })) {
                        ForEach(learn, id: \.self) { kv in Text(lk(kv.count > 1 ? kv[1] : kv[0])).tag(Int(kv[0]) ?? 0) }
                    }.frame(maxWidth: 360).disabled(armed)
                }
            }
            Text("Після зміни порядку чи прибирання відсутніх потрібне перезавантаження та нове калібрування.").font(.caption).foregroundStyle(.secondary)
        }
    }

    func removeMissing() { for r in rows where r.slot == nil { if let n = r.prioName { setP(n, 0) } } }

    // MARK: Onboard-калібрування
    var usedMask: Int {
        let slots = devSlots
        var m = 0
        for i in 1...3 where slots[i - 1] != 0 && (pv(useName(i)) ?? 1) != 0 { m |= 1 << (i - 1) }
        return m
    }

    var calState: CalState {
        let mags = cs.cal?.mags ?? []
        if mags.isEmpty { return cs.magRunning ? .starting : .idle }
        if mags.allSatisfy({ $0.done }) {
            return mags.allSatisfy({ $0.status == 4 }) ? .success(saved: mags.allSatisfy { $0.autosaved == 1 }) : .failed(mags.first { $0.status >= 5 }.map { magStatusText($0.status) } ?? "помилка")
        }
        let overall = mags.map(\.pct).reduce(0, +) / max(mags.count, 1)
        let step = mags.contains { $0.status == 3 } ? 2 : 1
        return .running(step: step, pct: overall, attempt: mags.map(\.attempt).max() ?? 1)
    }

    var calCard: some View {
        Card(title: String(localized: "Калібрування компаса (Onboard)"), icon: "scope", text: String(localized: "Повертайте апарат у всіх напрямках, поки смуги не заповняться. Калібруються компаси, відмічені «Використовувати».")) {
            let mags = cs.cal?.mags ?? []
            let finished = !mags.isEmpty && mags.allSatisfy { $0.done }
            let success = finished && mags.allSatisfy { $0.status == 4 }
            HStack {
                Button("Старт") { cs.run("/cal/mag/start?mask=\(usedMask)") { cs.magRunning = true } }
                    .buttonStyle(.borderedProminent).disabled(armed || cs.magRunning || usedMask == 0)
                Button("Прийняти") { cs.run("/cal/mag/accept") }.disabled(!success || mags.allSatisfy { $0.autosaved == 1 })
                Button("Скасувати") { cs.run("/cal/cancel") { cs.magRunning = false } }.disabled(!cs.magRunning)
                Spacer()
                if success { Label(lk(mags.allSatisfy { $0.autosaved == 1 } ? "Збережено" : "Успішно, натисніть «Прийняти»"), systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                else if finished { Label("Не вдалося", systemImage: "xmark.octagon.fill").foregroundStyle(.red) }
            }
            CalStatusBar(state: calState, elapsed: cs.cal?.magElapsed ?? 0, running: cs.magRunning)
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(1...3, id: \.self) { n in
                        let m = mags.first { $0.id == n - 1 }
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text("Компас \(n)").font(.caption.weight(.semibold))
                                Spacer()
                                if let m { Text(lk(magStatusText(m.status))).font(.caption).foregroundStyle(m.status == 4 ? .green : (m.status >= 5 ? .red : .secondary)) }
                            }
                            HStack(spacing: 8) {
                                ProgressView(value: Double(m?.pct ?? 0), total: 100)
                                Text("\(m?.pct ?? 0)%").font(.caption.monospacedDigit()).frame(width: 36, alignment: .trailing)
                            }
                            if let m, !m.done, m.status >= 2 { CoverageGrid(mask: m.mask) }
                            if let m, m.done { Text(String(format: loc("fitness %.1f · зміщення %.0f / %.0f / %.0f"), m.fitness, m.x, m.y, m.z)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary) }
                        }
                        .opacity(devSlots[n - 1] == 0 ? 0.35 : 1)
                    }
                    let fit = metaValues("COMPASS_CAL_FIT", fallback: [["4", "Very Strict"], ["8", "Strict"], ["16", "Default"], ["32", "Relaxed"]])
                    if pv("COMPASS_CAL_FIT") != nil {
                        Picker("Fitness", selection: Binding(get: { Int(pv("COMPASS_CAL_FIT") ?? 16) }, set: { setP("COMPASS_CAL_FIT", Double($0)) })) {
                            ForEach(fit, id: \.self) { kv in Text(lk(kv.count > 1 ? kv[1] : kv[0])).tag(Int(kv[0]) ?? 16) }
                        }.frame(maxWidth: 260).disabled(cs.magRunning || armed)
                        Text("Послабте fitness, якщо калібрування не вдається.").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: 360)
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array((cs.cal?.msgs ?? []).suffix(30).enumerated()), id: \.offset) { _, m in
                            Text(LocalizedStringKey(m)).font(.caption.monospaced()).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }.padding(8)
                }
                .frame(minHeight: 130, maxHeight: 170)
                .background(.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }
            Button("Large Vehicle MagCal…") { showLarge = true }.disabled(armed || cs.magRunning || usedMask == 0)
        }
    }
}

/// Калібрування за відомим курсом для великих апаратів (MAV_CMD_FIXED_MAG_CAL_YAW).
struct LargeVehicleSheet: View {
    let cs: CalStore
    let usedMask: Int
    let lat: Double; let lon: Double; let hasFix: Bool; let heading: Double
    @Environment(\.dismiss) var dismiss
    @State private var yaw = ""
    @State private var latText = ""
    @State private var lonText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Large Vehicle MagCal").font(.title2.bold())
            Text("Для великих апаратів, які не можна обертати. Поставте апарат носом у відомому напрямку (за компасом чи картою) і вкажіть курс у градусах (0–360, 0 = північ).")
                .font(.callout).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow { Text("Курс, °"); TextField("0–360", text: $yaw).frame(width: 140) }
                GridRow { Text("Широта"); TextField("авто за GPS", text: $latText).frame(width: 140) }
                GridRow { Text("Довгота"); TextField("авто за GPS", text: $lonText).frame(width: 140) }
            }
            if !hasFix { Label("Немає GPS-фіксу: введіть координати вручну (або 0 для автовизначення прошивкою)", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
            HStack {
                Spacer()
                Button("Скасувати") { dismiss() }
                Button("Калібрувати") {
                    let y = Double(yaw.replacingOccurrences(of: ",", with: ".")) ?? heading
                    let la = Double(latText.replacingOccurrences(of: ",", with: ".")) ?? (hasFix ? lat : 0)
                    let lo = Double(lonText.replacingOccurrences(of: ",", with: ".")) ?? (hasFix ? lon : 0)
                    cs.run("/cal/mag/fixedyaw?yaw=\(y)&mask=\(usedMask)&lat=\(la)&lon=\(lo)") { cs.magRunning = true }
                    dismiss()
                }.buttonStyle(.borderedProminent).disabled(Double(yaw.replacingOccurrences(of: ",", with: ".")) == nil)
            }
        }
        .padding(20).frame(width: 440)
    }
}


enum CalState {
    case idle, starting
    case running(step: Int, pct: Int, attempt: Int)
    case success(saved: Bool)
    case failed(String)
}

/// Загальний статусбар процесу калібрування.
struct CalStatusBar: View {
    let state: CalState
    let elapsed: Double
    let running: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: icon).foregroundStyle(tint)
                Text(LocalizedStringKey(title)).font(.subheadline.weight(.semibold))
                Spacer()
                if case .running(_, _, let a) = state, a > 1 { Text("Спроба \(a)").font(.caption).foregroundStyle(.secondary) }
                if showTime { Text(LocalizedStringKey(time)).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
            }
            switch state {
            case .starting: ProgressView().progressViewStyle(.linear)
            case .running(_, let pct, _): ProgressView(value: Double(pct), total: 100).tint(tint)
            case .success: ProgressView(value: 1).tint(.green)
            case .failed: ProgressView(value: 1).tint(.red)
            case .idle: ProgressView(value: 0)
            }
            if let hint { Text(LocalizedStringKey(hint)).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(10)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
    }

    var showTime: Bool { if case .idle = state { return false }; return elapsed > 0 }
    var time: String { String(format: "%d:%02d", Int(elapsed) / 60, Int(elapsed) % 60) }
    var tint: Color {
        switch state { case .idle: return .gray; case .starting, .running: return .blue; case .success: return .green; case .failed: return .red }
    }
    var icon: String {
        switch state { case .idle: return "pause.circle"; case .starting: return "hourglass"; case .running: return "arrow.triangle.2.circlepath"; case .success: return "checkmark.circle.fill"; case .failed: return "xmark.octagon.fill" }
    }
    var title: String {
        switch state {
        case .idle: return "Готово до калібрування"
        case .starting: return "Запуск калібрування…"
        case .running(let step, let pct, _): return String(localized: "Крок \(step) із 2 · \(pct)%")
        case .success(let saved): return saved ? "Калібрування завершено та збережено" : "Калібрування успішне, натисніть «Прийняти»"
        case .failed(let r): return String(localized: "Калібрування не вдалося: \(r)")
        }
    }
    var hint: String? {
        switch state {
        case .running(let step, _, _): return step == 1 ? "Повертайте апарат у всіх напрямках, ніби малюєте ним кулю." : "Продовжуйте обертати: прошивка уточнює результат."
        case .success(let saved): return saved ? "Перезавантажте автопілот, щоб застосувати." : nil
        case .failed: return "Спробуйте ще раз, за потреби послабте fitness."
        default: return nil
        }
    }
}

/// 80 секторів сфери: заповнені ті, де вже зібрані дані (completion_mask, 10 байт).
struct CoverageGrid: View {
    let mask: [Int]
    var body: some View {
        Canvas { ctx, size in
            let cols = 20, rows = 4
            let w = size.width / CGFloat(cols), h = size.height / CGFloat(rows)
            for i in 0..<80 {
                let byte = i / 8, bit = i % 8
                let on = byte < mask.count && (mask[byte] >> bit) & 1 == 1
                let r = CGRect(x: CGFloat(i % cols) * w + 0.5, y: CGFloat(i / cols) * h + 0.5, width: w - 1, height: h - 1)
                ctx.fill(Path(roundedRect: r, cornerRadius: 1.5), with: .color(on ? .green : .gray.opacity(0.25)))
            }
        }
        .frame(height: 18)
    }
}
