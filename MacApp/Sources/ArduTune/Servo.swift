import SwiftUI

/// Servo Output: функція, реверс, діапазон, ручне регулювання трима, симетричний діапазон (Equidistant) і тест виходів.
struct ServoView: View {
    @Environment(Store.self) var s
    @State private var io = IOStore()
    @State private var showAll = false
    @State private var equi: [Int: Bool] = [:]
    @State private var avail: CGFloat = 1300
    /// Ширина повзунка Trim підлаштовується під вікно: решта колонок фіксована (≈ 790 пт разом з відступами).
    var sliderW: CGFloat { min(420, max(140, avail - 810)) }
    var ps: ParamStore { s.ps }
    var channels: [Int] { (1...(showAll ? 32 : 16)).filter { ps.has("SERVO\($0)_FUNCTION") } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                OfflineBanner()
                if !s.canView {
                    ContentUnavailableView("Польотник не підключений", systemImage: "cable.connector", description: Text("Підключіть плату по USB"))
                } else if ps.params.isEmpty {
                    ProgressView("Завантаження параметрів…")
                } else {
                    if s.armedLive { Label("Апарат ARMED: редагування заблоковано", systemImage: "lock.fill").foregroundStyle(.red) }
                    Card(title: "Servo Output", icon: "slider.horizontal.below.rectangle", text: String(localized: "Оранжева мітка на повзунку показує поточне положення виходу в реальному часі. Тягніть повзунок, щоб змінити Trim (запис після відпускання). «Equidistant» робить діапазон симетричним: Min = Trim − Δ, Max = Trim + Δ.")) {
                        ScrollView(.horizontal, showsIndicators: true) {
                            Grid(alignment: .leading, horizontalSpacing: ServoCols.gap, verticalSpacing: 0) {
                                header
                                Divider()
                                ForEach(channels, id: \.self) { ch in
                                    ServoRow(ch: ch, io: io, sliderW: sliderW, equi: Binding(get: { equi[ch] }, set: { equi[ch] = $0 }))
                                    if ch != channels.last { Divider().opacity(0.4) }
                                }
                            }
                        }
                        Toggle("Показати всі 32 виходи", isOn: $showAll).toggleStyle(.checkbox)
                    }
                }
            }
            .padding()
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { avail = $0 }
        .onAppear { io.start() }
        .onDisappear { io.stop() }
    }

    /// Заголовок: ті самі фіксовані ширини, що й у клітинок рядків (інакше Grid розтягує колонки нерівно).
    var header: some View {
        GridRow {
            Text("№").frame(width: ServoCols.num, alignment: .leading)
            Text("Вихід, PWM").frame(width: ServoCols.live, alignment: .center)
            Text("Функція").padding(.leading, 10).frame(width: ServoCols.fn, alignment: .leading)
            Text("Реверс").frame(width: ServoCols.rev, alignment: .center)
            Text("Min").frame(width: ServoCols.val, alignment: .center)
            Text("Trim · повзунок").padding(.leading, 10).frame(width: sliderW, alignment: .leading)
            Text("Trim").frame(width: ServoCols.trim, alignment: .center)
            Text("Max").frame(width: ServoCols.val, alignment: .center)
            Text("Equidistant").frame(width: ServoCols.equi, alignment: .leading)
            Color.clear.frame(width: 30, height: 1)
        }
        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        .padding(.vertical, 6)
    }
}

enum ServoCols {
    static let gap: CGFloat = 12
    static let num: CGFloat = 22, rev: CGFloat = 48, fn: CGFloat = 170
    static let val: CGFloat = 64, slider: CGFloat = 330, equi: CGFloat = 110, live: CGFloat = 116, trim: CGFloat = 52
}

/// Один рядок. Окремий View: перемальовується лише при зміні своїх параметрів, а не від телеметрії.
struct ServoRow: View {
    @Environment(Store.self) var s
    let ch: Int
    let io: IOStore
    var sliderW: CGFloat = ServoCols.slider
    @Binding var equi: Bool?
    @State private var testOpen = false
    @State private var testPWM = 1500.0
    var ps: ParamStore { s.ps }

    var isEqui: Bool {
        if let e = equi { return e }
        guard let lo = ps.val("SERVO\(ch)_MIN"), let tr = ps.val("SERVO\(ch)_TRIM"), let hi = ps.val("SERVO\(ch)_MAX") else { return false }
        return abs((tr - lo) - (hi - tr)) < 0.5
    }

    var body: some View {
        let eq = isEqui
        GridRow {
            Text("\(ch)").font(.system(.body, design: .monospaced).weight(.semibold)).frame(width: ServoCols.num, alignment: .leading)
            ServoLiveCell(ch: ch, io: io)
            OptionPicker(name: "SERVO\(ch)_FUNCTION", width: ServoCols.fn)
            Toggle("", isOn: Binding(get: { (ps.val("SERVO\(ch)_REVERSED") ?? 0) != 0 }, set: { ps.write("SERVO\(ch)_REVERSED", $0 ? 1 : 0) }))
                .toggleStyle(.checkbox).labelsHidden().disabled(s.armed).fixedSize()
                .frame(width: ServoCols.rev, alignment: .center)
            ParamField(name: "SERVO\(ch)_MIN", width: ServoCols.val).disabled(eq)
            TrimSlider(ch: ch, io: io, equidistant: eq).frame(width: sliderW, height: 30)
            ParamField(name: "SERVO\(ch)_TRIM", width: ServoCols.trim)
            ParamField(name: "SERVO\(ch)_MAX", width: ServoCols.val).disabled(eq)
            HStack(spacing: 6) {
                Toggle("", isOn: Binding(get: { eq }, set: { setEqui($0) })).toggleStyle(.checkbox).labelsHidden().disabled(s.armed)
                if eq { DeltaField(ch: ch) }
            }.frame(width: ServoCols.equi, alignment: .leading)
            Menu {
                Button("Min = поточне положення") { setFromLive("MIN") }
                Button("Trim = поточне положення") { setFromLive("TRIM") }
                Button("Max = поточне положення") { setFromLive("MAX") }
                Divider()
                Button("Тест виходу…") { testPWM = ps.val("SERVO\(ch)_TRIM") ?? 1500; testOpen = true }
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton).frame(width: 30).disabled(s.armed)
            .popover(isPresented: $testOpen) { servoTest }
        }
        .padding(.vertical, 5)
    }

    func setFromLive(_ k: String) {
        guard ch <= 16, let v = io.io?.servo[ch - 1], v > 0 else { return }
        ps.write("SERVO\(ch)_\(k)", Double(v))
    }

    func setEqui(_ on: Bool) {
        equi = on
        guard on, let lo = ps.val("SERVO\(ch)_MIN"), let tr = ps.val("SERVO\(ch)_TRIM"), let hi = ps.val("SERVO\(ch)_MAX") else { return }
        let d = max(tr - lo, hi - tr)
        ps.write("SERVO\(ch)_MIN", tr - d); ps.write("SERVO\(ch)_MAX", tr + d)
    }

    var servoTest: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Тест виходу \(ch)").font(.headline)
            Text("Працює для виходів із функцією «Disabled».").font(.caption).foregroundStyle(.secondary)
            Slider(value: $testPWM, in: 800...2200, step: 10)
            Text("\(Int(testPWM)) µs").font(.system(.body, design: .monospaced))
            HStack {
                Button("Надіслати") { EngineAPI.post("/servo/test?channel=\(ch)&pwm=\(Int(testPWM))") }.buttonStyle(.borderedProminent)
                Button("До Trim") {
                    testPWM = ps.val("SERVO\(ch)_TRIM") ?? 1500
                    EngineAPI.post("/servo/test?channel=\(ch)&pwm=\(Int(testPWM))")
                }
            }
        }
        .padding(16).frame(width: 300)
    }
}

/// Власний повзунок Trim на абсолютній шкалі PWM (800…2200 мкс): ручка стоїть у значенні Trim, смуга показує діапазон Min…Max.
/// Перетягування не пишеться до відпускання; після відпускання ручка лишається на місці, поки плата не підтвердить значення.
/// У режимі Equidistant разом з Trim зсувається весь діапазон (Min = Trim − Δ, Max = Trim + Δ).
struct TrimSlider: View {
    @Environment(Store.self) var s
    let ch: Int
    let io: IOStore
    let equidistant: Bool
    @State private var drag: Double?
    @State private var pending: Double?

    static let scaleLo = 800.0, scaleHi = 2200.0

    var body: some View {
        let ps = s.ps
        let lo = ps.val("SERVO\(ch)_MIN") ?? 1000
        let hi = ps.val("SERVO\(ch)_MAX") ?? 2000
        let tr = ps.val("SERVO\(ch)_TRIM") ?? 1500
        let span = Self.scaleHi - Self.scaleLo
        GeometryReader { g in
            let pad: CGFloat = 10                       // половина діаметра ручки
            let w = max(g.size.width - pad * 2, 1)
            let X: (Double) -> CGFloat = { v in pad + w * CGFloat(min(max((v - Self.scaleLo) / span, 0), 1)) }
            let value = min(max(drag ?? pending ?? tr, Self.scaleLo), Self.scaleHi)
            // під час перетягування в Equidistant смуга діапазону рухається разом із ручкою
            let half = (hi - lo) / 2
            let bandLo = equidistant && (drag != nil || pending != nil) ? value - half : lo
            let bandHi = equidistant && (drag != nil || pending != nil) ? value + half : hi
            let x = X(value)
            ZStack(alignment: .leading) {
                // Доріжка на всю шкалу
                Capsule().fill(.quaternary).frame(height: 6).padding(.horizontal, pad)
                // Діапазон Min…Max
                Capsule().fill(Color.accentColor.opacity(0.35))
                    .frame(width: max(4, X(bandHi) - X(bandLo)), height: 6).offset(x: X(bandLo))
                // Поділки: 1000, 1250, 1500, 1750, 2000
                ForEach([1000.0, 1250, 1500, 1750, 2000], id: \.self) { v in
                    Rectangle().fill(.secondary.opacity(0.55)).frame(width: 1, height: v == 1500 ? 10 : 6)
                        .offset(x: X(v) - 0.5, y: 11)
                }
                // Живе положення
                LiveMarker(ch: ch, io: io, lo: Self.scaleLo, hi: Self.scaleHi, pad: pad, width: w)
                // Ручка (Trim)
                Circle().fill(.white).frame(width: 20, height: 20)
                    .overlay(Circle().stroke(Color.accentColor, lineWidth: drag == nil ? 2 : 3))
                    .shadow(color: .black.opacity(0.35), radius: drag == nil ? 1.5 : 4, y: 1)
                    .offset(x: x - 10)
                if drag != nil {
                    Text(verbatim: String(Int(value))).font(.system(size: 11, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.accentColor, in: Capsule()).foregroundStyle(.white)
                        .offset(x: min(max(x - 18, 0), g.size.width - 40), y: -17)
                }
            }
            .frame(height: g.size.height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    guard !s.armed else { return }
                    let f = min(max((v.location.x - pad) / w, 0), 1)
                    var d = (Self.scaleLo + Double(f) * span).rounded()
                    if equidistant { d = min(max(d, Self.scaleLo + half), Self.scaleHi - half) }
                    else if hi > lo { d = min(max(d, lo), hi) }                 // без Equidistant Trim не виходить за Min…Max
                    drag = d
                }
                .onEnded { _ in
                    guard let d = drag else { return }
                    drag = nil
                    guard d != tr else { return }
                    pending = d                                                   // ручка лишається на місці до підтвердження платою
                    ps.write("SERVO\(ch)_TRIM", d)
                    if equidistant { ps.write("SERVO\(ch)_MIN", (d - half).rounded()); ps.write("SERVO\(ch)_MAX", (d + half).rounded()) }
                    Task { @MainActor in try? await Task.sleep(nanoseconds: 4_000_000_000); if pending == d { pending = nil } }
                })
            .onChange(of: tr) { _, new in if let p = pending, abs(new - p) < 0.5 { pending = nil } }
        }
    }
}

/// Поточне положення виходу в реальному часі: мініатюрна шкала в межах Min…Max і значення PWM.
struct ServoLiveCell: View {
    @Environment(Store.self) var s
    let ch: Int
    let io: IOStore
    var body: some View {
        let pwm = ch <= 16 ? (io.io?.servo[ch - 1] ?? 0) : 0
        let lo = s.ps.val("SERVO\(ch)_MIN") ?? 1000, hi = s.ps.val("SERVO\(ch)_MAX") ?? 2000
        // той самий вигляд шкали, що й у калібруванні пульта (RCBar), але компактний; межі шкали = Min…Max виходу
        HStack(spacing: 6) {
            RCBar(value: Double(pwm), lo: min(lo, hi - 1), hi: max(hi, lo + 1))
                .frame(width: 70, height: 12)
            Text(lk(pwm > 0 ? "\(pwm)" : "—")).font(.system(.caption, design: .monospaced)).foregroundStyle(pwm > 0 ? Color.primary : Color.secondary)
                .frame(width: 36, alignment: .trailing)
        }
        .frame(width: ServoCols.live)
        .help(lk(pwm > 0 ? String(localized: "Поточний сигнал на виході \(ch): \(pwm) мкс") : "Немає даних про вихід (лише виходи 1–16)"))
    }
}

/// Тонка оранжева мітка поточного виходу на доріжці повзунка.
struct LiveMarker: View {
    let ch: Int
    let io: IOStore
    let lo: Double, hi: Double, pad: CGFloat, width: CGFloat
    var body: some View {
        let pwm = ch <= 16 ? (io.io?.servo[ch - 1] ?? 0) : 0
        if pwm > 0, hi > lo {
            let f = min(max((Double(pwm) - lo) / (hi - lo), 0), 1)
            Capsule().fill(.orange).frame(width: 3, height: 16).offset(x: pad + width * CGFloat(f) - 1.5)
        }
    }
}

/// Півширина діапазону для режиму Equidistant: Min = Trim − Δ, Max = Trim + Δ.
struct DeltaField: View {
    @Environment(Store.self) var s
    let ch: Int
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        let ps = s.ps
        let tr = ps.val("SERVO\(ch)_TRIM") ?? 1500, hi = ps.val("SERVO\(ch)_MAX") ?? 2000
        TextField("", text: $text)
            .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
            .font(.system(.body, design: .monospaced)).frame(width: 60)
            .focused($focused)
            .disabled(s.armed)
            .onSubmit {
                guard let d = Double(text), d > 0 else { text = String(Int(hi - tr)); return }
                ps.write("SERVO\(ch)_MIN", tr - d); ps.write("SERVO\(ch)_MAX", tr + d)
            }
            .onAppear { text = String(Int(hi - tr)) }
            .onChange(of: hi - tr) { _, v in if !focused { text = String(Int(v)) } }
    }
}
