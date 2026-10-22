import SwiftUI

/// Frame & Motors: вибір розкладки, схема з порядком і напрямком обертання, тест моторів.
struct FrameMotorsView: View {
    @Environment(Store.self) var s
    @State private var io = IOStore()
    @State private var throttle = 5.0
    @State private var duration = 2.0
    @State private var selected: Int?
    @State private var note: String?
    @State private var rebootNote: String?
    @Environment(\.openWindow) private var openWindow
    var ps: ParamStore { s.ps }

    var frameClass: Int { Int(ps.val("FRAME_CLASS") ?? 0) }
    var frameType: Int { Int(ps.val("FRAME_TYPE") ?? 1) }
    var motors: [MotorDef] { (motorLayouts["\(frameClass)"]?["\(frameType)"] ?? []).sorted { $0.n < $1.n } }

    func letter(_ order: Int) -> String { String(UnicodeScalar(UInt8(64 + max(1, min(order, 26))))) }
    /// Який серво-вихід призначений мотору n (SERVOx_FUNCTION = 32 + n; Motor1 = 33…Motor8 = 40, Motor9–12 = 82–85).
    func fnCode(_ n: Int) -> Int { n <= 8 ? 32 + n : 82 + (n - 9) }
    func output(for n: Int) -> Int? {
        let fn = fnCode(n)
        return (1...32).first { Int(ps.val("SERVO\($0)_FUNCTION") ?? -99) == fn }
    }
    var outputs: [Int] { (1...32).filter { ps.has("SERVO\($0)_FUNCTION") } }
    var ordered: [MotorDef] { motors.sorted { $0.o < $1.o } }
    var effThrottle: Double { throttle }

    /// Призначає мотору вихід. Якщо вихід зайнятий іншою функцією, функції міняються місцями.
    func assign(_ n: Int, to out: Int) {
        guard !s.armed else { note = String(localized: "Апарат ARMED"); return }
        let old = output(for: n)
        if out == 0 { if let o = old { ps.write("SERVO\(o)_FUNCTION", 0) }; return }
        if old == out { return }
        let occupied = Int(ps.val("SERVO\(out)_FUNCTION") ?? 0)
        ps.write("SERVO\(out)_FUNCTION", Double(fnCode(n)))
        if let o = old { ps.write("SERVO\(o)_FUNCTION", Double(occupied)) }
        note = String(localized: "M\(n) → вихід SERVO\(out)")
    }

    func schemeTap(_ m: MotorDef) {
        guard s.connected, !s.armed else { return }
        run(m)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                OfflineBanner()
                if !s.canView {
                    ContentUnavailableView("Польотник не підключений", systemImage: "cable.connector", description: Text("Підключіть плату по USB"))
                } else if ps.params.isEmpty {
                    ProgressView("Завантаження параметрів…")
                } else if !ps.has("FRAME_CLASS") {
                    ContentUnavailableView("Недоступно для цього апарата", systemImage: "airplane", description: Text("Розкладка моторів налаштовується лише на мультикоптерах (ArduCopter)."))
                } else {
                    if s.armedLive { Label("Апарат ARMED: зміни та тести заблоковано", systemImage: "lock.fill").foregroundStyle(.red) }
                    frameCard
                    HStack(alignment: .top, spacing: 16) { schemeCard; tableCard }
                    testCard
                }
            }
            .padding()
        }
        .onAppear { io.start() }
        .onDisappear { io.stop() }
    }

    // MARK: Вибір розкладки
    var frameCard: some View {
        Card(title: String(localized: "Розкладка моторів"), icon: "square.grid.2x2", text: String(localized: "Клас і тип рами визначають нумерацію моторів і напрямок обертання. Після зміни потрібне перезавантаження автопілота.")) {
            HStack(spacing: 18) {
                VStack(alignment: .leading) { Text("Клас рами").font(.caption).foregroundStyle(.secondary); OptionPicker(name: "FRAME_CLASS", width: 220) }
                if ps.has("FRAME_TYPE") { VStack(alignment: .leading) { Text("Тип рами").font(.caption).foregroundStyle(.secondary); OptionPicker(name: "FRAME_TYPE", width: 220) } }
                Spacer()
                Button { EngineAPI.post("/reboot") { ok, _ in rebootNote = ok ? "Перезавантаження…" : "Недоступно" } } label: { Label("Перезавантажити", systemImage: "restart") }.disabled(s.armed)
            }
            if motors.isEmpty { Label("Для цієї рами схема недоступна (немає матричного розкладу).", systemImage: "info.circle").font(.caption).foregroundStyle(.secondary) }
            if let r = rebootNote { Text(LocalizedStringKey(r)).font(.caption).foregroundStyle(.secondary) }
        }
    }

    // MARK: Схема
    var schemeCard: some View {
        Card(title: String(localized: "Схема (вид зверху)"), icon: "scope", text: nil) {
            FrameScheme(motors: motors, selected: selected, onTap: schemeTap)
                .frame(width: 360, height: 360)
            HStack(spacing: 14) {
                Legend(color: .orange, text: String(localized: "Проти годинникової (CCW)"), sym: "arrow.counterclockwise")
                Legend(color: .teal, text: String(localized: "За годинниковою (CW)"), sym: "arrow.clockwise")
            }
            Text("Цифра в колі: номер мотора (вихід MOTn). Літера поряд: порядок тесту (A, B, C…). Клік по мотору запускає його (мін. оберти); ").font(.caption).foregroundStyle(.secondary)
        }
    }

    var tableCard: some View {
        Card(title: String(localized: "Відповідність моторів"), icon: "list.number", text: nil) {
            if motors.isEmpty { Text("—").foregroundStyle(.secondary) } else {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                    GridRow { ForEach(["Мотор", "Тест", "Обертання", "Вихід", ""], id: \.self) { Text(lk($0)).font(.caption.weight(.semibold)).foregroundStyle(.secondary) } }
                    Divider().gridCellColumns(5)
                    ForEach(motors) { m in
                        GridRow {
                            Text("M\(m.n)").font(.system(.body, design: .monospaced).weight(.semibold))
                            Text(lk(letter(m.o))).font(.system(.body, design: .monospaced))
                            Label(lk(m.y > 0 ? "CCW" : (m.y < 0 ? "CW" : "—")), systemImage: m.y > 0 ? "arrow.counterclockwise" : (m.y < 0 ? "arrow.clockwise" : "minus"))
                                .foregroundStyle(m.y > 0 ? .orange : (m.y < 0 ? .teal : .secondary))
                            Picker("", selection: Binding(get: { output(for: m.n) ?? 0 }, set: { assign(m.n, to: $0) })) {
                                Text("не призначено").tag(0)
                                ForEach(outputs, id: \.self) { o in Text("SERVO\(o)").tag(o) }
                            }
                            .labelsHidden().frame(width: 130).disabled(s.armed)
                            .help("Вихід серво для мотора M\(m.n). Якщо вихід зайнятий, функції міняються місцями.")
                            Button("Тест \(letter(m.o))") { run(m) }
                                .disabled(s.armed || !s.connected)
                        }
                        .background(selected == m.n ? Color.accentColor.opacity(0.15) : .clear)
                        .onHover { selected = $0 ? m.n : (selected == m.n ? nil : selected) }
                    }
                }
            }
        }
    }

    // MARK: Тест
    var testCard: some View {
        Card(title: String(localized: "Тест моторів"), icon: "fanblades", text: String(localized: "Мотор обертається вказаний час із заданою тягою. Перевірте, що порядок і напрямок збігаються зі схемою.")) {
            HStack(spacing: 24) {
                VStack(alignment: .leading) {
                    Text("Тяга: \(Int(effThrottle))%").font(.caption)
                    Slider(value: $throttle, in: 1...30, step: 1).frame(width: 200)
                }
                VStack(alignment: .leading) {
                    Text("Тривалість: \(Int(duration)) с").font(.caption)
                    Slider(value: $duration, in: 1...8, step: 1).frame(width: 200)
                }
            }
            HStack {
                ForEach(motors) { m in
                    Button("\(letter(m.o))") { run(m) }.buttonStyle(.borderedProminent).tint(m.y > 0 ? .orange : .teal)
                        .help("Мотор M\(m.n)")
                }
                Divider().frame(height: 20)
                Button("Усі по черзі") {
                    post("/motor/test?motor=1&throttle=\(throttle)&timeout=\(duration)&count=\(motors.count)&order=1")
                }.disabled(motors.isEmpty)
                Button(role: .destructive) { EngineAPI.post("/motor/stop") } label: { Label("СТОП", systemImage: "stop.circle.fill") }
            }
            .disabled(s.armed || !s.connected)
            Divider()
            autoCard
            if let n = note { Text(LocalizedStringKey(n)).font(.caption).foregroundStyle(.orange) }
        }
    }

    var autoCard: some View {
        HStack(spacing: 10) {
            Button { openWindow(id: "motorwizard") } label: { Label("Майстер визначення моторів…", systemImage: "hand.tap.fill") }
                .disabled(motors.isEmpty)
        }
        .disabled(s.armed || !s.connected)
    }

    func run(_ m: MotorDef) { post("/motor/test?motor=\(m.o)&throttle=\(effThrottle)&timeout=\(duration)&count=1&order=1") }
    func post(_ path: String) {
        EngineAPI.post(path) { ok, e in note = ok ? nil : (e == "armed" ? "Апарат ARMED" : "Помилка команди") }
    }
}

struct Legend: View {
    let color: Color; let text: String; let sym: String
    var body: some View { Label(LocalizedStringKey(text), systemImage: sym).font(.caption).foregroundStyle(color) }
}

/// Креслення рами: промені, мотори, номери, літери тесту та напрямок обертання. Мотори клікабельні.
struct FrameScheme: View {
    let motors: [MotorDef]
    let selected: Int?
    var badges: [Int: String] = [:]
    var onTap: ((MotorDef) -> Void)? = nil

    struct Spot { let m: MotorDef; let p: CGPoint; let dup: Int }
    static func layout(_ motors: [MotorDef], _ size: CGSize) -> (c: CGPoint, R: CGFloat, pr: CGFloat, spots: [Spot]) {
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let R = min(size.width, size.height) * 0.36
        let pr = min(size.width, size.height) * (motors.count > 8 ? 0.055 : 0.075)
        var seen: [Int: Int] = [:]
        var spots: [Spot] = []
        for m in motors {
            let key = Int((m.a * 2).rounded())
            let dup = seen[key, default: 0]; seen[key] = dup + 1
            let rr = dup == 0 ? R : R * 0.62
            let a = m.a * .pi / 180
            spots.append(Spot(m: m, p: CGPoint(x: c.x + rr * sin(a), y: c.y - rr * cos(a)), dup: dup))
        }
        return (c, R, pr, spots)
    }

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in draw(ctx, size) }
                .contentShape(Rectangle())
                .onTapGesture(coordinateSpace: .local) { loc in
                    let g = Self.layout(motors, geo.size)
                    if let hit = g.spots.min(by: { hypot($0.p.x - loc.x, $0.p.y - loc.y) < hypot($1.p.x - loc.x, $1.p.y - loc.y) }),
                       hypot(hit.p.x - loc.x, hit.p.y - loc.y) <= g.pr * 1.5 { onTap?(hit.m) }
                }
        }
    }

    func draw(_ ctx: GraphicsContext, _ size: CGSize) {
        let g = Self.layout(motors, size)
        let c = g.c, R = g.R, pr = g.pr
        // Перед
        var front = Path()
        front.move(to: CGPoint(x: c.x, y: c.y - R - pr * 2.6)); front.addLine(to: CGPoint(x: c.x - 9, y: c.y - R - pr * 2.6 + 16)); front.addLine(to: CGPoint(x: c.x + 9, y: c.y - R - pr * 2.6 + 16)); front.closeSubpath()
        ctx.fill(front, with: .color(.red))
        ctx.draw(Text("ПЕРЕД").font(.caption2.weight(.bold)).foregroundColor(.red), at: CGPoint(x: c.x + 36, y: c.y - R - pr * 2.6 + 8))
        // Корпус
        ctx.fill(Path(roundedRect: CGRect(x: c.x - 24, y: c.y - 24, width: 48, height: 48), cornerRadius: 8), with: .color(.gray.opacity(0.55)))
        for sp in g.spots {
            let m = sp.m, p = sp.p, dup = sp.dup
            let a = m.a * .pi / 180
            var arm = Path(); arm.move(to: c); arm.addLine(to: p)
            ctx.stroke(arm, with: .color(.gray.opacity(0.6)), lineWidth: 5)
            let col: Color = m.y > 0 ? .orange : (m.y < 0 ? .teal : .gray)
            let rect = CGRect(x: p.x - pr, y: p.y - pr, width: pr * 2, height: pr * 2)
            ctx.fill(Path(ellipseIn: rect), with: .color(col.opacity(selected == m.n ? 0.85 : 0.45)))
            ctx.stroke(Path(ellipseIn: rect), with: .color(col), lineWidth: selected == m.n ? 4 : 2)
            // Стрілка обертання
            let r2 = pr + 5
            var arc = Path()
            let cw = m.y < 0
            arc.addArc(center: p, radius: r2, startAngle: .degrees(-70), endAngle: .degrees(150), clockwise: !cw)
            if m.y != 0 { ctx.stroke(arc, with: .color(col), style: StrokeStyle(lineWidth: 2, lineCap: .round)) }
            if m.y != 0 {
                let ang = 150.0 * .pi / 180
                let tip = CGPoint(x: p.x + r2 * cos(ang), y: p.y + r2 * sin(ang))
                let dir = (cw ? ang + .pi / 2 : ang - .pi / 2)
                var head = Path()
                head.move(to: tip)
                head.addLine(to: CGPoint(x: tip.x + 8 * cos(dir + 2.6), y: tip.y + 8 * sin(dir + 2.6)))
                head.addLine(to: CGPoint(x: tip.x + 8 * cos(dir - 2.6), y: tip.y + 8 * sin(dir - 2.6)))
                head.closeSubpath()
                ctx.fill(head, with: .color(col))
            }
            ctx.draw(Text("\(m.n)").font(.system(size: pr * 0.95, weight: .bold)), at: p)
            // Літера порядку тесту ззовні
            let lp = CGPoint(x: p.x + (pr + 18) * sin(a), y: p.y - (pr + 18) * cos(a))
            ctx.draw(Text(lk(String(UnicodeScalar(UInt8(64 + max(1, min(m.o, 26))))))).font(.system(size: 13, weight: .heavy, design: .monospaced)).foregroundColor(.primary), at: dup == 0 ? lp : CGPoint(x: p.x - (pr + 14) * sin(a), y: p.y + (pr + 14) * cos(a)))
            // Позначка вибору в майстрі: літера кроку, на якому мотор обертався
            if let b = badges[m.n] {
                let bp = CGPoint(x: p.x + pr * 0.85, y: p.y - pr * 0.85)
                ctx.fill(Path(ellipseIn: CGRect(x: bp.x - 9, y: bp.y - 9, width: 18, height: 18)), with: .color(.green))
                ctx.draw(Text(LocalizedStringKey(b)).font(.system(size: 11, weight: .heavy)).foregroundColor(.white), at: bp)
            }
        }
    }
}
