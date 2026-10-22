import SwiftUI

struct LessonQuiz { let question: String; let options: [String]; let correct: Int; let explanation: String }

enum LogQuizzes {
    static let all: [String: LessonQuiz] = [
        "intro": LessonQuiz(question: "Що означає мітка TimeUS у повідомленні?", options: ["Час доби UTC", "Мікросекунди від увімкнення автопілота", "Час від моменту ARM"], correct: 1, explanation: "TimeUS рахується від увімкнення автопілота, тому початок графіка не збігається з моментом зльоту. Орієнтуйтеся на події ARM."),
        "graphs": LessonQuiz(question: "Фактичний кут повторює бажаний, але з помітним запізненням. Що це означає?", options: ["Регулятор надто агресивний", "Регулятор млявий", "Вібрація"], correct: 1, explanation: "Запізнення без коливань означає млявий відгук: збільшуйте P/FF. Коливання навколо цілі означали б надто агресивний регулятор."),
        "vibe": LessonQuiz(question: "Лічильник Clip у VIBE дорівнює 4000, але не змінювався останні 10 хвилин польоту. Це проблема?", options: ["Так, критична", "Ні: важливе зростання лічильника під час польоту", "Так, потрібно замінити плату"], correct: 1, explanation: "Clip тільки накопичується. Старі події не страшні, небезпечне швидке зростання під час польоту."),
        "gps": LessonQuiz(question: "NSats = 14, але HDop = 4.5. Чи довіряти позиції?", options: ["Так, супутників багато", "Обережно: погана геометрія супутників", "Ні, GPS зламаний"], correct: 1, explanation: "Висока кількість супутників не гарантує точність. HDOP понад 2 означає погану геометрію чи завади, довіряти позиції варто обережно."),
        "battery": LessonQuiz(question: "Напруга падає на 2 В при струмі 40 А і одразу відновлюється при зменшенні струму. Що це?", options: ["Нормальна поведінка опору батареї", "Витік заряду", "Помилка датчика"], correct: 0, explanation: "Просідання під навантаженням і швидке відновлення це внутрішній опір. Якщо опір сильно росте від польоту до польоту, батарея старіє."),
        "ekf": LessonQuiz(question: "Тест SH (висота) тримається близько 1.5 тривалий час. Що це вказує?", options: ["Барометр і інші датчики висоти розходяться", "GPS не підключено", "Все добре"], correct: 0, explanation: "Значення понад 1 означає відхилення сенсора від оцінки фільтра. SH пов'язаний з висотою: перевірте барометр, його укриття від протягів і вібрацію."),
        "pid": LessonQuiz(question: "ROut постійно близько 100 %. Що це означає?", options: ["Ідеальне налаштування", "Насичення: мотори на межі", "Шум у D"], correct: 1, explanation: "Вихід біля меж означає насичення: регулятору бракує потужності. Перевірте масу, пропелери та мотори."),
        "events": LessonQuiz(question: "У ERR підсистема «Radio failsafe», ECode = 0. Що це?", options: ["Failsafe виник", "Failsafe усунуто", "Помилка приймача"], correct: 1, explanation: "Для failsafe код 1 означає «виник», код 0 «усунуто». Знайдіть запис із кодом 1, щоб побачити початок."),
        "method": LessonQuiz(question: "З чого починати пошук причини проблеми в лозі?", options: ["З налаштувань PID", "З хронології й повідомлень про помилки", "З карти польоту"], correct: 1, explanation: "Спочатку знайдіть момент проблеми й прочитайте повідомлення та помилки поруч із ним. PID розглядають останніми."),
        "pitfalls": LessonQuiz(question: "Напруга впала одночасно зі збоєм. Чи завжди це його причина?", options: ["Так", "Ні: важливо, що було першим за часом", "Тільки при великому струмі"], correct: 1, explanation: "Кореляція не причина. Збій міг викликати різкий газ, який просадив напругу. Шукайте, що трапилося першим."),
    ]
}

// MARK: - Вкладка «Навчання»

struct LogLearnView: View {
    let log: DFLog?
    let openGraph: (GraphRequest) -> Void
    @State private var lessonID = "intro"
    @State private var glossary = false
    @State private var answers: [String: Int] = [:]
    @State private var search = ""

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 260).frame(maxHeight: .infinity, alignment: .top)
            Divider()
            Group { glossary ? AnyView(glossaryView) : AnyView(lessonView) }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                Text("УРОКИ").font(.caption2.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.top, 8)
                ForEach(Array(LogLessons.all.enumerated()), id: \.element.id) { i, l in
                    let on = !glossary && lessonID == l.id
                    Button { lessonID = l.id; glossary = false } label: {
                        HStack(spacing: 10) {
                            Image(systemName: l.icon).font(.system(size: 13)).frame(width: 20).foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 0) {
                                Text("\(i + 1). \(loc(l.title))").font(.callout.weight(on ? .semibold : .regular)).lineLimit(2).multilineTextAlignment(.leading)
                                Text(lk(l.subtitle)).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            if let a = answers[l.id], let q = LogQuizzes.all[l.id] { Image(systemName: a == q.correct ? "checkmark.circle.fill" : "circle.dotted").foregroundStyle(a == q.correct ? .green : .secondary).font(.caption) }
                        }
                        .padding(.horizontal, 8).padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading)
                        .background(on ? Color.primary.opacity(0.11) : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
                Text("ДОВІДНИК").font(.caption2.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.top, 12)
                Button { glossary = true } label: {
                    Label("Словник повідомлень і полів", systemImage: "character.book.closed").frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .background(glossary ? Color.primary.opacity(0.11) : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous)).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }.padding(8)
        }
    }

    // MARK: Урок
    var lessonView: some View {
        let l = LogLessons.all.first { $0.id == lessonID } ?? LogLessons.all[0]
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(lk(l.title)).font(.title2.weight(.semibold))
                    Text(lk(l.subtitle)).font(.callout).foregroundStyle(.secondary)
                }
                LessonFigure(id: l.figure).frame(height: 190)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                ForEach(Array(l.sections.enumerated()), id: \.offset) { _, s in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(lk(s.0)).font(.headline)
                        Text(lk(s.1)).font(.callout).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let t = l.tryIt {
                    HStack {
                        Button {
                            if let log, !t.keys.isEmpty { openGraph(GraphRequest(keys: t.keys.filter { k in let p = k.split(separator: ".").map(String.init); return p.count == 2 && log.fields(of: p[0]).contains(p[1]) }, from: 0, to: log.duration)) }
                        } label: { Label("Спробувати на моєму лозі: \(loc(t.title))", systemImage: "chart.xyaxis.line") }.disabled(log == nil)
                        if log == nil { Text("Відкрийте лог, щоб побачити живий приклад.").font(.caption).foregroundStyle(.secondary) }
                    }
                }
                if let q = LogQuizzes.all[l.id] { quiz(l.id, q) }
                HStack {
                    if let i = LogLessons.all.firstIndex(where: { $0.id == lessonID }), i + 1 < LogLessons.all.count {
                        Spacer(); Button { lessonID = LogLessons.all[i + 1].id } label: { Label("Наступний урок", systemImage: "arrow.right.circle.fill") }
                    }
                }
            }.padding(18)
        }
    }

    func quiz(_ id: String, _ q: LessonQuiz) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Перевірте себе", systemImage: "questionmark.bubble").font(.headline)
            Text(lk(q.question)).font(.callout.weight(.medium))
            ForEach(Array(q.options.enumerated()), id: \.offset) { i, o in
                let chosen = answers[id]
                Button { answers[id] = i } label: {
                    HStack {
                        Image(systemName: chosen == i ? (i == q.correct ? "checkmark.circle.fill" : "xmark.circle.fill") : "circle").foregroundStyle(chosen == i ? (i == q.correct ? Color.green : Color.red) : Color.secondary)
                        Text(lk(o)).multilineTextAlignment(.leading)
                        Spacer()
                    }
                    .padding(8).background(Color.primary.opacity(chosen == i ? 0.1 : 0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous)).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            if let a = answers[id] {
                Label(lk(a == q.correct ? loc("Правильно. ") + q.explanation : loc("Не зовсім. ") + q.explanation), systemImage: a == q.correct ? "checkmark.seal.fill" : "lightbulb.fill")
                    .font(.callout).foregroundStyle(a == q.correct ? Color.green : Color.primary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14).background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: Словник
    var glossaryView: some View {
        let names = LogKnowledge.messages.keys.sorted().filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) || (LogKnowledge.messages[$0]?.title.localizedCaseInsensitiveContains(search) ?? false) }
        return VStack(spacing: 0) {
            HStack {
                TextField("Пошук повідомлення", text: $search).textFieldStyle(.roundedBorder).frame(width: 260)
                Spacer()
                Text("\(names.count) повідомлень").font(.caption).foregroundStyle(.secondary)
            }.padding(10)
            Divider()
            List(names, id: \.self) { n in
                let info = LogKnowledge.messages[n]!
                let count = log?.count(n) ?? 0
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(lk(info.text)).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        ForEach(info.fields.keys.sorted(), id: \.self) { f in
                            HStack(alignment: .top) { Text(lk(f)).font(.system(.caption, design: .monospaced).weight(.semibold)).frame(width: 90, alignment: .leading); Text(lk(info.fields[f] ?? "")).font(.caption).foregroundStyle(.secondary) }
                        }
                        if count > 0, let log, let first = info.fields.keys.sorted().first(where: { log.fields(of: n).contains($0) }) {
                            Button("Показати \(n).\(first) на графіку") { openGraph(GraphRequest(keys: ["\(n).\(first)"], from: 0, to: log.duration)) }.controlSize(.small).padding(.top, 2)
                        }
                    }.padding(.vertical, 4)
                } label: {
                    HStack {
                        Text(lk(n)).font(.system(.callout, design: .monospaced).weight(.semibold)).frame(width: 60, alignment: .leading)
                        Text(lk(info.title)).font(.callout)
                        Spacer()
                        if count > 0 { Text("\(count) у лозі").font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
        }
    }
}

// MARK: - Ілюстрації уроків

struct LessonFigure: View {
    let id: String
    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            let ink = Color.primary, soft = Color.primary.opacity(0.35), accent = Color.accentColor
            func text(_ s: String, _ p: CGPoint, size: CGFloat = 11, weight: Font.Weight = .regular, color: Color = .primary, anchor: UnitPoint = .center) {
                ctx.draw(Text(lk(s)).font(.system(size: size, weight: weight, design: .rounded)).foregroundColor(color), at: p, anchor: anchor)
            }
            func line(_ pts: [CGPoint], color: Color, width: CGFloat = 2, dash: [CGFloat] = []) {
                guard pts.count > 1 else { return }
                var p = Path(); p.move(to: pts[0]); for q in pts.dropFirst() { p.addLine(to: q) }
                ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round, dash: dash))
            }
            func box(_ r: CGRect, _ fill: Color, _ label: String, _ sub: String? = nil) {
                ctx.fill(Path(roundedRect: r, cornerRadius: 7), with: .color(fill))
                ctx.stroke(Path(roundedRect: r, cornerRadius: 7), with: .color(soft), lineWidth: 1)
                text(label, CGPoint(x: r.midX, y: r.midY - (sub == nil ? 0 : 7)), size: 11, weight: .semibold)
                if let sub { text(sub, CGPoint(x: r.midX, y: r.midY + 8), size: 9, color: .secondary) }
            }
            func series(_ f: (Double) -> Double, x0: CGFloat, x1: CGFloat, y0: CGFloat, y1: CGFloat, n: Int = 120) -> [CGPoint] {
                (0...n).map { i in let t = Double(i) / Double(n); return CGPoint(x: x0 + (x1 - x0) * CGFloat(t), y: y1 - (y1 - y0) * CGFloat(f(t))) }
            }
            switch id {
            case "anatomy":
                text("Повідомлення в лозі", CGPoint(x: 20, y: 18), size: 12, weight: .semibold, anchor: .leading)
                let bx: CGFloat = 20, by: CGFloat = 40
                box(CGRect(x: bx, y: by, width: 56, height: 46), accent.opacity(0.15), "A3 95", "заголовок")
                box(CGRect(x: bx + 62, y: by, width: 56, height: 46), accent.opacity(0.15), "тип", "ATT")
                box(CGRect(x: bx + 124, y: by, width: 80, height: 46), Color.orange.opacity(0.18), "TimeUS", "мікросекунди")
                for (i, n) in ["DesRoll", "Roll", "DesPitch", "Pitch"].enumerated() { box(CGRect(x: bx + 210 + CGFloat(i) * 78, y: by, width: 72, height: 46), Color.primary.opacity(0.06), n, "поле") }
                text("Структуру кожного типу описує запис FMT на початку логу:", CGPoint(x: 20, y: 112), size: 11, color: .secondary, anchor: .leading)
                box(CGRect(x: 20, y: 128, width: w - 40, height: 40), Color.primary.opacity(0.05), "FMT: ATT = Q ccCCCC | TimeUS, DesRoll, Roll, DesPitch, Pitch…", nil)
            case "desired":
                let r = CGRect(x: 40, y: 20, width: w - 70, height: h - 50)
                line([CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)], color: soft, width: 1)
                line(series({ $0 < 0.2 ? 0 : 1 }, x0: r.minX, x1: r.maxX, y0: r.minY + 10, y1: r.maxY - 6), color: .green, width: 2, dash: [5, 4])
                line(series({ t in t < 0.25 ? 0 : max(0, 1 - exp(-(t - 0.25) * 10) * cos((t - 0.25) * 30) * 1.0) }, x0: r.minX, x1: r.maxX, y0: r.minY + 10, y1: r.maxY - 6), color: accent, width: 2.4)
                text("бажане", CGPoint(x: r.maxX - 38, y: r.minY + 6), size: 10, color: .green); text("фактичне", CGPoint(x: r.maxX - 38, y: r.minY + 20), size: 10, color: accent)
                text("затримка", CGPoint(x: r.minX + r.width * 0.32, y: r.maxY - 14), size: 10, color: .secondary)
                text("перерегулювання", CGPoint(x: r.minX + r.width * 0.47, y: r.minY + 4), size: 10, color: .orange)
            case "vibe":
                let zones: [(Double, Color, String)] = [(15, .green, "0–15 добре"), (30, .yellow, "15–30 норма"), (60, .orange, "30–60 погано"), (90, .red, "60+ критично")]
                var x: CGFloat = 30; var prev = 0.0
                for z in zones { let wd = CGFloat(z.0 - prev) / 90 * (w - 60); ctx.fill(Path(CGRect(x: x, y: 40, width: wd, height: 26)), with: .color(z.1.opacity(0.6))); text(z.2, CGPoint(x: x + wd / 2, y: 53), size: 9, weight: .medium); x += wd; prev = z.0 }
                text("Вібрація, м/с²", CGPoint(x: 30, y: 24), size: 11, weight: .semibold, anchor: .leading)
                text("Кліппінг: пік обрізається межею діапазону датчика", CGPoint(x: 30, y: 96), size: 11, weight: .semibold, anchor: .leading)
                let top = CGPoint(x: 30, y: 112)
                line(series({ sin($0 * 6 * .pi) * 0.5 + 0.5 }, x0: top.x, x1: w / 2 - 15, y0: top.y, y1: top.y + 60), color: soft, width: 1.5, dash: [3, 3])
                line(series({ min(0.85, max(0.15, sin($0 * 6 * .pi) * 0.9 * 0.5 + 0.5)) }, x0: top.x, x1: w / 2 - 15, y0: top.y, y1: top.y + 60), color: accent, width: 2)
                text("норма", CGPoint(x: w / 4, y: h - 8), size: 9, color: .secondary)
                line(series({ min(0.78, max(0.22, sin($0 * 6 * .pi) * 1.6 * 0.5 + 0.5)) }, x0: w / 2 + 15, x1: w - 30, y0: top.y, y1: top.y + 60), color: .red, width: 2)
                text("кліппінг: пласкі вершини", CGPoint(x: 3 * w / 4, y: h - 8), size: 9, color: .red)
            case "gps":
                text("Супутники й точність", CGPoint(x: 30, y: 20), size: 12, weight: .semibold, anchor: .leading)
                for (i, (n, hd, ok)) in [(14, 0.8, true), (7, 1.8, true), (4, 4.5, false)].enumerated() {
                    let y = 46 + CGFloat(i) * 46
                    for k in 0..<n { ctx.fill(Path(ellipseIn: CGRect(x: 30 + CGFloat(k) * 15, y: y, width: 10, height: 10)), with: .color(ok ? accent : .red.opacity(0.7))) }
                    text("NSats \(n)", CGPoint(x: 30, y: y + 22), size: 10, color: .secondary, anchor: .leading)
                    text(String(format: "HDOP %.1f", hd), CGPoint(x: 100, y: y + 22), size: 10, weight: .semibold, color: hd < 1.5 ? .green : (hd < 2.5 ? .orange : .red), anchor: .leading)
                    text(hd < 1.5 ? "відмінно" : (hd < 2.5 ? "допустимо" : "погано: не довіряйте позиції"), CGPoint(x: 180, y: y + 22), size: 10, color: .secondary, anchor: .leading)
                }
            case "battery":
                let r = CGRect(x: 40, y: 20, width: w - 70, height: h - 50)
                line([CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)], color: soft, width: 1)
                line(series({ 0.85 - $0 * 0.25 - (($0 > 0.35 && $0 < 0.5) || ($0 > 0.7 && $0 < 0.78) ? 0.22 : 0) }, x0: r.minX, x1: r.maxX, y0: r.minY, y1: r.maxY), color: accent, width: 2.4)
                line(series({ (($0 > 0.35 && $0 < 0.5) || ($0 > 0.7 && $0 < 0.78)) ? 0.45 : 0.12 }, x0: r.minX, x1: r.maxX, y0: r.minY, y1: r.maxY), color: .orange, width: 1.6, dash: [4, 3])
                text("напруга", CGPoint(x: r.minX + 8, y: r.minY + 6), size: 10, color: accent, anchor: .leading); text("струм", CGPoint(x: r.minX + 8, y: r.minY + 20), size: 10, color: .orange, anchor: .leading)
                text("просідання під струмом (ΔU)", CGPoint(x: r.minX + r.width * 0.5, y: r.maxY - 10), size: 10, color: .secondary)
                text("опір ≈ ΔU / ΔI", CGPoint(x: r.maxX - 60, y: r.minY + 14), size: 11, weight: .semibold)
            case "ekf":
                text("Тести інновацій EKF (норма < 1)", CGPoint(x: 30, y: 20), size: 12, weight: .semibold, anchor: .leading)
                let vals: [(String, Double)] = [("SV", 0.3), ("SP", 0.5), ("SH", 1.5), ("SM", 0.4)]
                let base = h - 30, unit: CGFloat = 90
                for (i, v) in vals.enumerated() {
                    let x = 50 + CGFloat(i) * 80
                    ctx.fill(Path(roundedRect: CGRect(x: x, y: base - unit * CGFloat(v.1), width: 40, height: unit * CGFloat(v.1)), cornerRadius: 4), with: .color(v.1 > 1 ? .red.opacity(0.75) : accent.opacity(0.7)))
                    text(v.0, CGPoint(x: x + 20, y: base + 12), size: 11, weight: .semibold)
                }
                line([CGPoint(x: 30, y: base - unit), CGPoint(x: w - 30, y: base - unit)], color: .orange, width: 1.5, dash: [5, 4])
                text("поріг = 1", CGPoint(x: w - 70, y: base - unit - 9), size: 10, color: .orange)
            case "pid":
                let r = CGRect(x: 40, y: 24, width: w - 70, height: h - 48)
                text("Вихід = P + I + D", CGPoint(x: 40, y: 12), size: 12, weight: .semibold, anchor: .leading)
                line([CGPoint(x: r.minX, y: r.midY), CGPoint(x: r.maxX, y: r.midY)], color: soft, width: 1)
                line(series({ t in 0.5 + 0.3 * sin(t * 4 * .pi) * exp(-t * 1.5) }, x0: r.minX, x1: r.maxX, y0: r.minY, y1: r.maxY), color: accent, width: 2)
                line(series({ t in 0.5 + 0.12 * cos(t * 4 * .pi) * exp(-t * 1.5) }, x0: r.minX, x1: r.maxX, y0: r.minY, y1: r.maxY), color: .orange, width: 1.6)
                line(series({ t in 0.5 + 0.08 * min(1, t * 3) }, x0: r.minX, x1: r.maxX, y0: r.minY, y1: r.maxY), color: .green, width: 1.6)
                text("P: реакція на помилку", CGPoint(x: r.maxX - 4, y: r.minY + 2), size: 10, color: accent, anchor: .trailing)
                text("D: гасить коливання", CGPoint(x: r.maxX - 4, y: r.minY + 16), size: 10, color: .orange, anchor: .trailing)
                text("I: накопичує зсув", CGPoint(x: r.maxX - 4, y: r.minY + 30), size: 10, color: .green, anchor: .trailing)
            case "timeline":
                let modes: [(Double, Color, String)] = [(0.12, .blue, "Stabilize"), (0.34, .teal, "Loiter"), (0.26, .purple, "Auto"), (0.14, .orange, "RTL"), (0.14, .gray, "Land")]
                var x: CGFloat = 30; let total = w - 60
                text("Хронологія польоту", CGPoint(x: 30, y: 20), size: 12, weight: .semibold, anchor: .leading)
                for m in modes { let wd = CGFloat(m.0) * total; ctx.fill(Path(roundedRect: CGRect(x: x, y: 44, width: wd - 2, height: 30), cornerRadius: 5), with: .color(m.1.opacity(0.55))); text(m.2, CGPoint(x: x + wd / 2, y: 59), size: 10, weight: .medium); x += wd }
                text("MODE", CGPoint(x: 30, y: 86), size: 10, color: .secondary, anchor: .leading)
                for (p, label, col) in [(0.06, "ARM", Color.green), (0.5, "ERR", Color.red), (0.62, "MSG", Color.orange), (0.95, "DISARM", Color.green)] {
                    let xx = 30 + CGFloat(p) * total
                    line([CGPoint(x: xx, y: 96), CGPoint(x: xx, y: 150)], color: col, width: 1.6)
                    ctx.fill(Path(ellipseIn: CGRect(x: xx - 4, y: 92, width: 8, height: 8)), with: .color(col))
                    text(label, CGPoint(x: xx, y: 162), size: 10, weight: .semibold, color: col)
                }
            case "method":
                let steps = ["Хронологія", "Помилки", "Живлення", "Навігація", "Керування"]
                let sw = (w - 40) / CGFloat(steps.count)
                for (i, s) in steps.enumerated() {
                    let x = 20 + CGFloat(i) * sw
                    var p = Path(); p.move(to: CGPoint(x: x, y: 50)); p.addLine(to: CGPoint(x: x + sw - 14, y: 50)); p.addLine(to: CGPoint(x: x + sw, y: 85)); p.addLine(to: CGPoint(x: x + sw - 14, y: 120)); p.addLine(to: CGPoint(x: x, y: 120)); p.addLine(to: CGPoint(x: x + 14, y: 85)); p.closeSubpath()
                    ctx.fill(p, with: .color(accent.opacity(0.10 + 0.07 * Double(i)))); ctx.stroke(p, with: .color(soft), lineWidth: 1)
                    text("\(i + 1)", CGPoint(x: x + sw / 2, y: 72), size: 15, weight: .bold, color: accent); text(s, CGPoint(x: x + sw / 2, y: 98), size: 11, weight: .semibold)
                }
                text("від причини до наслідків: спершу загальне, потім деталі", CGPoint(x: w / 2, y: 150), size: 11, color: .secondary)
            default:
                let r = CGRect(x: 40, y: 24, width: w - 70, height: h - 50)
                text("Причина й наслідок у часі", CGPoint(x: 40, y: 12), size: 12, weight: .semibold, anchor: .leading)
                line(series({ $0 < 0.5 ? 0.2 : 0.7 }, x0: r.minX, x1: r.maxX, y0: r.minY, y1: r.maxY), color: accent, width: 2.2)
                line(series({ $0 < 0.4 ? 0.8 : 0.2 }, x0: r.minX, x1: r.maxX, y0: r.minY, y1: r.maxY), color: .orange, width: 2.2)
                line([CGPoint(x: r.minX + r.width * 0.4, y: r.minY), CGPoint(x: r.minX + r.width * 0.4, y: r.maxY)], color: .orange.opacity(0.6), width: 1, dash: [4, 3])
                line([CGPoint(x: r.minX + r.width * 0.5, y: r.minY), CGPoint(x: r.minX + r.width * 0.5, y: r.maxY)], color: accent.opacity(0.6), width: 1, dash: [4, 3])
                text("перше: різкий газ", CGPoint(x: r.minX + r.width * 0.4 - 6, y: r.maxY - 6), size: 10, color: .orange, anchor: .trailing)
                text("потім: просідання", CGPoint(x: r.minX + r.width * 0.5 + 6, y: r.maxY - 6), size: 10, color: accent, anchor: .leading)
            }
            _ = ink
        }
    }
}
