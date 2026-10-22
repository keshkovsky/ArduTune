import SwiftUI

/// Стан тренажера: рівень, значення регуляторів, результат прогону й прогрес.
@Observable
final class PIDGameModel {
    var levelIndex = 0
    var gains = GameLevel.levels[0].start
    var run: GameRun?
    var started: Date?
    var showHint = false
    var evaluated: (stars: Int, notes: [(Bool, String)])?
    var attempts = 0
    var stars: [Int: Int] = [:]

    init() {
        if let s = UserDefaults.standard.string(forKey: "game.stars") {
            for part in s.split(separator: ",") { let kv = part.split(separator: ":"); if kv.count == 2, let k = Int(kv[0]), let v = Int(kv[1]) { stars[k] = v } }
        }
        select(0)
    }
    var level: GameLevel { GameLevel.levels[levelIndex] }

    func select(_ i: Int) {
        levelIndex = i
        gains = level.fixed
        let s = level.start
        if level.edit.contains("P") { gains.p = s.p }; if level.edit.contains("I") { gains.i = s.i }
        if level.edit.contains("D") { gains.d = s.d }; if level.edit.contains("FF") { gains.ff = s.ff }
        if level.edit.contains("FLT") { gains.fltd = s.fltd }
        // Фіксовані значення рівня мають пріоритет над стартовими тих параметрів, що не редагуються
        if !level.edit.contains("P") { gains.p = level.fixed.p }; if !level.edit.contains("I") { gains.i = level.fixed.i }
        if !level.edit.contains("D") { gains.d = level.fixed.d }; if !level.edit.contains("FF") { gains.ff = level.fixed.ff }
        if !level.edit.contains("FLT") { gains.fltd = 150 }
        run = nil; started = nil; evaluated = nil; showHint = false; attempts = 0
    }

    func start() {
        let r = GameSim.run(level, gains)
        run = r; started = Date(); attempts += 1
        evaluated = GameSim.evaluate(level, r)
        if let e = evaluated, e.stars > (stars[level.id] ?? 0) { stars[level.id] = e.stars; save() }
    }
    func save() { UserDefaults.standard.set(stars.map { "\($0.key):\($0.value)" }.joined(separator: ","), forKey: "game.stars") }
}

// MARK: - Інтерфейс тренажера

struct PIDGameCard: View {
    @State private var g = PIDGameModel()
    @State private var speed = 1.0

    static let fltSteps: [Double] = [5, 8, 12, 20, 30, 50, 80, 150]

    var body: some View {
        let lv = g.level
        Card(title: String(localized: "Тренажер PID: навчіться налаштовувати"), icon: "gamecontroller.fill", text: String(localized: "Інтерактивна гра у віртуальному дроні. Це окремий тренажер і він нічого не змінює на реальному апараті. Проходьте рівні по черзі й дивіться, як кожен параметр впливає на політ.")) {
            levelBar
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Label(LocalizedStringKey(lv.title), systemImage: "target").font(.headline)
                    Text(LocalizedStringKey(lv.mission)).font(.callout).fixedSize(horizontal: false, vertical: true)
                    Text("Тема: \(lv.teaches)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            HStack(alignment: .top, spacing: 14) {
                GameScene(model: g, speed: speed).frame(width: 230, height: 190)
                GameChart(model: g, speed: speed).frame(height: 190)
            }
            controls(lv)
            actions(lv)
            if g.showHint { hintBox(lv) }
            result(lv)
        }
    }

    // Вибір рівня
    var levelBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(GameLevel.levels) { l in
                    let on = g.levelIndex == l.id - 1, st = g.stars[l.id] ?? 0
                    Button { g.select(l.id - 1) } label: {
                        HStack(spacing: 6) {
                            Text("\(l.id)").font(.caption.weight(.bold)).frame(width: 20, height: 20).background(on ? Color.accentColor : Color.primary.opacity(0.12), in: Circle()).foregroundStyle(on ? .white : .primary)
                            Text(LocalizedStringKey(l.title)).font(.callout.weight(on ? .semibold : .regular))
                            HStack(spacing: 1) { ForEach(0..<3, id: \.self) { Image(systemName: $0 < st ? "star.fill" : "star").font(.system(size: 9)).foregroundStyle($0 < st ? Color.yellow : Color.secondary.opacity(0.5)) } }
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(on ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.06), in: Capsule())
                        .overlay(Capsule().strokeBorder(on ? Color.accentColor.opacity(0.5) : .clear, lineWidth: 1))
                    }.buttonStyle(.plain)
                }
            }
        }
    }

    // Регулятори
    func controls(_ lv: GameLevel) -> some View {
        HStack(spacing: 14) {
            gainControl("P", "Пропорційна", lv.edit.contains("P"), g.gains.p, 0...12, 0.25, 2) { g.gains.p = $0 }
            gainControl("I", "Інтегральна", lv.edit.contains("I"), g.gains.i, 0...8, 0.25, 2) { g.gains.i = $0 }
            gainControl("D", "Диференціальна", lv.edit.contains("D"), g.gains.d, 0...4, 0.1, 1) { g.gains.d = $0 }
            gainControl("FF", "Випередження", lv.edit.contains("FF"), g.gains.ff, 0...1.8, 0.05, 2) { g.gains.ff = $0 }
            fltControl(lv.edit.contains("FLT"))
        }
    }

    func gainControl(_ name: String, _ sub: String, _ enabled: Bool, _ value: Double, _ range: ClosedRange<Double>, _ step: Double, _ digits: Int, _ set: @escaping (Double) -> Void) -> some View {
        VStack(spacing: 5) {
            HStack(spacing: 4) {
                Text(LocalizedStringKey(name)).font(.system(size: 19, weight: .bold, design: .rounded))
                Text(LocalizedStringKey(sub)).font(.caption2).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                stepButton("minus", enabled && value > range.lowerBound + 1e-9) { set(max(range.lowerBound, ((value - step) / step).rounded() * step)); resetResult() }
                Text(String(format: "%.\(digits)f", value)).font(.system(size: 17, weight: .semibold, design: .monospaced)).frame(width: 54)
                stepButton("plus", enabled && value < range.upperBound - 1e-9) { set(min(range.upperBound, ((value + step) / step).rounded() * step)); resetResult() }
            }
            if !enabled { Text("фіксовано").font(.caption2).foregroundStyle(.tertiary) } else { Text(" ").font(.caption2) }
        }
        .padding(8).frame(maxWidth: .infinity)
        .background(enabled ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .opacity(enabled ? 1 : 0.55)
    }

    func fltControl(_ enabled: Bool) -> some View {
        let idx = Self.fltSteps.firstIndex(of: g.gains.fltd) ?? (Self.fltSteps.count - 1)
        return VStack(spacing: 5) {
            HStack(spacing: 4) { Text("Фільтр").font(.system(size: 15, weight: .bold, design: .rounded)); Text("Гц").font(.caption2).foregroundStyle(.secondary) }
            HStack(spacing: 6) {
                stepButton("minus", enabled && idx > 0) { g.gains.fltd = Self.fltSteps[idx - 1]; resetResult() }
                Text(lk(g.gains.fltd >= 150 ? "—" : "\(Int(g.gains.fltd))")).font(.system(size: 17, weight: .semibold, design: .monospaced)).frame(width: 54)
                stepButton("plus", enabled && idx < Self.fltSteps.count - 1) { g.gains.fltd = Self.fltSteps[idx + 1]; resetResult() }
            }
            if !enabled { Text("вимкнено").font(.caption2).foregroundStyle(.tertiary) } else { Text(lk(g.gains.fltd >= 150 ? "без фільтра" : " ")).font(.caption2).foregroundStyle(.secondary) }
        }
        .padding(8).frame(maxWidth: .infinity)
        .background(enabled ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .opacity(enabled ? 1 : 0.55)
    }

    func stepButton(_ icon: String, _ on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 13, weight: .bold)).frame(width: 30, height: 30).background(Color.primary.opacity(0.1), in: Circle()).contentShape(Circle())
        }.buttonStyle(.plain).disabled(!on).opacity(on ? 1 : 0.35)
    }
    func resetResult() { g.run = nil; g.started = nil; g.evaluated = nil }

    func actions(_ lv: GameLevel) -> some View {
        HStack(spacing: 10) {
            Button { g.start() } label: { Label(lk(g.attempts == 0 ? "Запустити політ" : "Спробувати ще раз"), systemImage: "play.fill") }.buttonStyle(.borderedProminent)
            Button { g.select(g.levelIndex) } label: { Label("Скинути", systemImage: "arrow.counterclockwise") }
            Button { withAnimation(.snappy(duration: 0.18)) { g.showHint.toggle() } } label: { Label("Підказка", systemImage: g.showHint ? "lightbulb.fill" : "lightbulb") }
            Spacer()
            Picker("", selection: $speed) { Text("0.5×").tag(0.5); Text("1×").tag(1.0); Text("2×").tag(2.0) }.pickerStyle(.segmented).labelsHidden().frame(width: 130)
            if g.levelIndex < GameLevel.levels.count - 1, (g.stars[lv.id] ?? 0) > 0 {
                Button { g.select(g.levelIndex + 1) } label: { Label("Наступний рівень", systemImage: "arrow.right.circle.fill") }.tint(.green)
            }
        }
    }

    func hintBox(_ lv: GameLevel) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lightbulb.fill").foregroundStyle(.yellow)
            Text(LocalizedStringKey(lv.hint)).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.yellow.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder func result(_ lv: GameLevel) -> some View {
        if let r = g.run, let e = g.evaluated {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    HStack(spacing: 3) { ForEach(0..<3, id: \.self) { Image(systemName: $0 < e.stars ? "star.fill" : "star").foregroundStyle($0 < e.stars ? Color.yellow : Color.secondary.opacity(0.4)) } }.font(.title3)
                    Text(lk(e.stars > 0 ? (e.stars == 3 ? "Відмінно!" : "Рівень пройдено") : "Ще не зараховано")).font(.headline).foregroundStyle(e.stars > 0 ? Color.green : Color.primary)
                    Spacer()
                    Text("Спроб: \(g.attempts)").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(Array(e.notes.enumerated()), id: \.offset) { _, n in
                    Label(LocalizedStringKey(n.1), systemImage: n.0 ? "checkmark.circle.fill" : "xmark.circle.fill").font(.callout).foregroundStyle(n.0 ? Color.green : Color.secondary)
                }
                Label(lk(GameSim.advice(lv, g.gains, r)), systemImage: "arrow.turn.down.right").font(.callout)
                if e.stars > 0 {
                    Divider()
                    Label(LocalizedStringKey(lv.learned), systemImage: "graduationcap.fill").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}

// MARK: - Сцена: дрон, що нахиляється

struct GameScene: View {
    let model: PIDGameModel
    let speed: Double

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: model.started == nil)) { tl in
            let lv = model.level
            let (i, t) = position(tl.date)
            Canvas { ctx, size in
                let c = CGPoint(x: size.width / 2, y: size.height / 2 - 4)
                let run = model.run
                let target = run.map { $0.target[min(i, $0.target.count - 1)] } ?? 0
                let angle = run.map { $0.angle[min(i, $0.angle.count - 1)] } ?? 0
                let wind = run.map { $0.wind[min(i, $0.wind.count - 1)] } ?? 0
                // Горизонт
                var h = Path(); h.move(to: CGPoint(x: 8, y: c.y + 56)); h.addLine(to: CGPoint(x: size.width - 8, y: c.y + 56))
                ctx.stroke(h, with: .color(.secondary.opacity(0.3)), lineWidth: 1)
                // Ціль
                var g1 = ctx; g1.translateBy(x: c.x, y: c.y); g1.rotate(by: .degrees(target))
                var tl = Path(); tl.move(to: CGPoint(x: -92, y: 0)); tl.addLine(to: CGPoint(x: 92, y: 0))
                g1.stroke(tl, with: .color(.green.opacity(0.7)), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                // Дрон
                var g2 = ctx; g2.translateBy(x: c.x, y: c.y); g2.rotate(by: .degrees(max(-80, min(80, angle))))
                g2.fill(Path(roundedRect: CGRect(x: -80, y: -3, width: 160, height: 6), cornerRadius: 3), with: .color(.primary.opacity(0.55)))
                g2.fill(Path(roundedRect: CGRect(x: -17, y: -11, width: 34, height: 22), cornerRadius: 7), with: .color(.primary.opacity(0.85)))
                let jitter = lv.noise > 0 ? min(3, (run?.heat ?? 0) / 14) : 0
                for sx in [-1.0, 1.0] {
                    let jy = jitter * sin(t * 90 + sx * 3)
                    g2.fill(Path(roundedRect: CGRect(x: sx * 80 - 26, y: -13 + jy, width: 52, height: 4), cornerRadius: 2), with: .color(.accentColor.opacity(0.85)))
                    g2.fill(Path(ellipseIn: CGRect(x: sx * 80 - 5, y: -9, width: 10, height: 13)), with: .color(.primary.opacity(0.65)))
                }
                // Вітер
                if abs(wind) > 1 {
                    let dir: CGFloat = wind < 0 ? 1 : -1
                    for k in 0..<3 {
                        let y = c.y - 70 + CGFloat(k) * 12
                        var a = Path(); a.move(to: CGPoint(x: c.x - 40 * dir, y: y)); a.addLine(to: CGPoint(x: c.x + 40 * dir, y: y))
                        a.move(to: CGPoint(x: c.x + 40 * dir, y: y)); a.addLine(to: CGPoint(x: c.x + 30 * dir, y: y - 5)); a.move(to: CGPoint(x: c.x + 40 * dir, y: y)); a.addLine(to: CGPoint(x: c.x + 30 * dir, y: y + 5))
                        ctx.stroke(a, with: .color(.cyan.opacity(0.7)), lineWidth: 1.5)
                    }
                }
                ctx.draw(Text(lk(model.run == nil ? "Налаштуйте й запустіть політ" : String(format: loc("кут %.0f°   ціль %.0f°"), angle, target))).font(.caption2.monospacedDigit()).foregroundColor(.secondary), at: CGPoint(x: size.width / 2, y: size.height - 10))
            }
        }
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// Поточний індекс кадру симуляції (за часом і швидкістю відтворення).
    func position(_ date: Date) -> (Int, Double) {
        guard let r = model.run, let s = model.started, r.t.count > 1 else { return (0, 0) }
        let t = min(date.timeIntervalSince(s) * speed, r.t.last ?? 0)
        let i = min(r.t.count - 1, Int(t / (r.t.last ?? 1) * Double(r.t.count - 1)))
        return (i, t)
    }
}

// MARK: - Графік політу (малюється поступово)

struct GameChart: View {
    let model: PIDGameModel
    let speed: Double

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: model.started == nil)) { tl in
            Canvas { ctx, size in
                let lv = model.level
                let pad = EdgeInsets(top: 8, leading: 36, bottom: 20, trailing: 8)
                let plot = CGRect(x: pad.leading, y: pad.top, width: size.width - pad.leading - pad.trailing, height: size.height - pad.top - pad.bottom)
                let ymax: Double = { if case .step = lv.target { return 40 } else { return 30 } }()
                let ymin: Double = -ymax * 0.35
                func X(_ t: Double) -> CGFloat { plot.minX + CGFloat(t / lv.duration) * plot.width }
                func Y(_ v: Double) -> CGFloat { plot.maxY - CGFloat((v - ymin) / (ymax - ymin)) * plot.height }
                ctx.fill(Path(roundedRect: plot, cornerRadius: 6), with: .color(.primary.opacity(0.04)))
                // Сітка й підписи
                for v in stride(from: -10.0, through: ymax, by: 10) {
                    var l = Path(); l.move(to: CGPoint(x: plot.minX, y: Y(v))); l.addLine(to: CGPoint(x: plot.maxX, y: Y(v)))
                    ctx.stroke(l, with: .color(.secondary.opacity(v == 0 ? 0.4 : 0.15)), lineWidth: v == 0 ? 1 : 0.5)
                    ctx.draw(Text("\(Int(v))°").font(.system(size: 9, design: .monospaced)).foregroundColor(.secondary), at: CGPoint(x: plot.minX - 16, y: Y(v)))
                }
                for s in stride(from: 0.0, through: lv.duration, by: lv.duration > 5 ? 2 : 1) {
                    ctx.draw(Text("\(Int(s)) с").font(.system(size: 9, design: .monospaced)).foregroundColor(.secondary), at: CGPoint(x: X(s), y: plot.maxY + 11))
                }
                if case .step(let a, _) = lv.target {   // смуга допуску ±5 %
                    ctx.fill(Path(CGRect(x: plot.minX, y: Y(a * 1.05), width: plot.width, height: Y(a * 0.95) - Y(a * 1.05))), with: .color(.green.opacity(0.08)))
                }
                guard let r = model.run, let s = model.started else {
                    ctx.draw(Text("Тут з'явиться графік польоту").font(.callout).foregroundColor(.secondary), at: CGPoint(x: plot.midX, y: plot.midY))
                    return
                }
                let t = min(tl.date.timeIntervalSince(s) * speed, r.t.last ?? 0)
                let n = min(r.t.count, Int(t / lv.duration * Double(r.t.count)) + 1)
                func line(_ vals: [Double], _ color: Color, _ w: CGFloat, dash: [CGFloat] = []) {
                    guard n > 1 else { return }
                    var p = Path(); p.move(to: CGPoint(x: X(r.t[0]), y: Y(vals[0])))
                    for k in stride(from: 1, to: n, by: 1) { p.addLine(to: CGPoint(x: X(r.t[k]), y: Y(max(ymin, min(ymax, vals[k]))))) }
                    ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: w, lineCap: .round, lineJoin: .round, dash: dash))
                }
                line(r.target, .green.opacity(0.8), 1.4, dash: [5, 4])
                line(r.angle, .accentColor, 2.2)
                ctx.draw(Text("ціль").font(.system(size: 9)).foregroundColor(.green), at: CGPoint(x: plot.maxX - 20, y: plot.minY + 8))
                ctx.draw(Text("дрон").font(.system(size: 9)).foregroundColor(.accentColor), at: CGPoint(x: plot.maxX - 20, y: plot.minY + 20))
            }
        }
    }
}
