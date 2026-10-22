import SwiftUI
import MapKit
import AppKit

// MARK: - Модель ділянки

/// Ділянка обліту: багатокутник і параметри, з яких автоматично будуються галси («змійка») у плані місії.
struct SurveyArea: Identifiable, Codable, Equatable {
    var id = UUID()
    var pts: [GeoPt] = []
    var angle = 0.0                 // напрям галсів, ° від півночі за годинниковою
    var alt = 80.0
    var frame = 3
    var autoSpacing = true          // відстань між галсами з камери й перекриття
    var spacing = 40.0
    var fov = 60.0                  // горизонтальне поле зору камери, °
    var sideOverlap = 70.0          // бічне перекриття, %
    var fwdOverlap = 80.0           // поздовжнє перекриття, %
    var leadIn = 20.0               // виліт за межі ділянки на розворот, м
    var trigger = true              // команда «фото кожні N м»
    var speed = 0.0                 // 0: не змінювати швидкість
    var reverseLines = false
    var reverseFirst = false

    var footprintW: Double { 2 * alt * tan(fov / 2 * .pi / 180) }       // ширина кадру на землі, м
    var footprintH: Double { footprintW * 2 / 3 }                        // висота кадру (3:2), м
    var lineSpacing: Double { autoSpacing ? max(2, footprintW * (1 - sideOverlap / 100)) : max(2, spacing) }
    var triggerDist: Double { max(1, footprintH * (1 - fwdOverlap / 100)) }
}

struct SurveyResult {
    var points: [CLLocationCoordinate2D] = []
    var lines = 0
    var length = 0.0
    var area = 0.0                  // м²
    var items: [MissionItem] = []
}

enum SurveyGen {
    /// Будує галси: площина навколо першої вершини, лінії паралельні напрямку `angle`, перетин із багатокутником (з урахуванням увігнутих).
    static func plan(_ s: SurveyArea) -> SurveyResult {
        var r = SurveyResult()
        guard s.pts.count >= 3 else { return r }
        let lat0 = s.pts[0].lat, lon0 = s.pts[0].lon
        let mLat = 111_320.0, mLon = 111_320.0 * cos(lat0 * .pi / 180)
        let th = s.angle * .pi / 180
        let u = (x: sin(th), y: cos(th))             // вздовж галса (схід, північ)
        let v = (x: cos(th), y: -sin(th))            // впоперек галсів
        func local(_ p: GeoPt) -> (Double, Double) { ((p.lon - lon0) * mLon, (p.lat - lat0) * mLat) }
        let loc = s.pts.map(local)
        let poly: [(a: Double, b: Double)] = loc.map { ($0.0 * u.x + $0.1 * u.y, $0.0 * v.x + $0.1 * v.y) }
        // площа (формула шнурівки)
        var ar = 0.0
        for i in loc.indices { let j = (i + 1) % loc.count; ar += loc[i].0 * loc[j].1 - loc[j].0 * loc[i].1 }
        r.area = abs(ar) / 2
        let bmin = poly.map(\.b).min()!, bmax = poly.map(\.b).max()!
        let sp = s.lineSpacing
        var levels: [Double] = []
        var y = bmin + sp / 2
        while y < bmax { levels.append(y); y += sp }
        if levels.isEmpty { levels = [(bmin + bmax) / 2] }
        if s.reverseLines { levels.reverse() }

        var segsPerLine: [[(Double, Double, Double)]] = []     // (a1, a2, b)
        for lv in levels {
            var xs: [Double] = []
            for i in poly.indices {
                let p = poly[i], q = poly[(i + 1) % poly.count]
                if (p.b <= lv) != (q.b <= lv) { xs.append(p.a + (lv - p.b) * (q.a - p.a) / (q.b - p.b)) }
            }
            xs.sort()
            var segs: [(Double, Double, Double)] = []
            var k = 0
            while k + 1 < xs.count { segs.append((xs[k] - s.leadIn, xs[k + 1] + s.leadIn, lv)); k += 2 }
            if !segs.isEmpty { segsPerLine.append(segs) }
        }
        var pts: [(Double, Double)] = []        // (a, b)
        for (i, segs) in segsPerLine.enumerated() {
            let forward = (i % 2 == 0) != s.reverseFirst
            let ordered = forward ? segs : segs.reversed()
            for g in ordered {
                if forward { pts.append((g.0, g.2)); pts.append((g.1, g.2)) } else { pts.append((g.1, g.2)); pts.append((g.0, g.2)) }
            }
        }
        r.lines = segsPerLine.count
        r.points = pts.map { a, b in
            let east = a * u.x + b * v.x, north = a * u.y + b * v.y
            return CLLocationCoordinate2D(latitude: lat0 + north / mLat, longitude: lon0 + east / mLon)
        }
        for i in 1..<max(1, r.points.count) {
            r.length += CLLocation(latitude: r.points[i - 1].latitude, longitude: r.points[i - 1].longitude).distance(from: CLLocation(latitude: r.points[i].latitude, longitude: r.points[i].longitude))
        }
        // елементи місії
        func mk(_ cmd: Int) -> MissionItem { var it = MissionItem(); it.cmd = cmd; it.group = s.id; it.alt = 0; return it }
        if s.speed > 0 { var it = mk(178); it.p1 = 1; it.p2 = s.speed; it.p3 = -1; r.items.append(it) }
        if s.trigger, !r.points.isEmpty { var it = mk(206); it.p1 = s.triggerDist; r.items.append(it) }
        for c in r.points { var it = mk(16); it.frame = s.frame; it.alt = s.alt; it.lat = c.latitude; it.lon = c.longitude; r.items.append(it) }
        if s.trigger, !r.points.isEmpty { var it = mk(206); it.p1 = 0; r.items.append(it) }
        return r
    }
}

// MARK: - Операції в сховищі

extension MissionStore {
    var survey: SurveyArea? { surveys.first { $0.id == selectedSurvey } }

    /// Зміна ділянки з одночасною перебудовою галсів: один крок скасування.
    func mutateSurvey(_ id: UUID, _ f: (inout SurveyArea) -> Void) {
        guard let i = surveys.firstIndex(where: { $0.id == id }) else { return }
        let before = currentSnap
        withoutRecording {
            var s = surveys[i]; f(&s)
            if s != surveys[i] { surveys[i] = s }
            regenerate(s)
        }
        recordSnap("survey", before)
    }

    func regenerate(_ s: SurveyArea) {
        let res = SurveyGen.plan(s)
        let idx = items.firstIndex { $0.group == s.id }
        var rest = items.filter { $0.group != s.id }
        var at: Int
        if let idx { at = min(idx, rest.count) }
        else {
            at = rest.count
            while at > 0, [20, 21, 85].contains(rest[at - 1].cmd) { at -= 1 }        // перед завершальним RTL/посадкою
        }
        rest.insert(contentsOf: res.items, at: at)
        items = rest
    }

    func addSurveyVertex(at c: CLLocationCoordinate2D) {
        let v = GeoPt(lat: c.latitude, lon: c.longitude)
        if let id = selectedSurvey, surveys.contains(where: { $0.id == id }) {
            mutateSurvey(id) { $0.pts.append(v) }
        } else {
            var s = SurveyArea(); s.pts = [v]; s.alt = defaultAlt; s.frame = defaultFrame
            s.fov = UserDefaults.standard.object(forKey: "cam.fov") as? Double ?? 60
            let before = currentSnap
            withoutRecording { surveys.append(s) }
            recordSnap("survey", before)
            selectedSurvey = s.id
        }
        selected = v.id
    }
    func surveyOf(vertex id: UUID) -> SurveyArea? { surveys.first { $0.pts.contains { $0.id == id } } }
    func removeSurveyVertex(_ id: UUID) {
        guard let s = surveyOf(vertex: id) else { return }
        mutateSurvey(s.id) { $0.pts.removeAll { $0.id == id } }
        selected = nil
    }
    func removeSurvey(_ id: UUID) {
        let before = currentSnap
        withoutRecording { surveys.removeAll { $0.id == id }; items.removeAll { $0.group == id } }
        recordSnap("survey", before)
        if selectedSurvey == id { selectedSurvey = nil }
        selected = nil
    }

    /// Підсумок за поточними параметрами (для панелі).
    func surveyResult(_ s: SurveyArea) -> SurveyResult { SurveyGen.plan(s) }
}

// MARK: - Панель «Ділянка»

struct SurveyPanel: View {
    @Bindable var m: MissionStore
    @Environment(Store.self) var s

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Обліт ділянки").font(.headline)
                    Spacer()
                    Text(lk(m.surveys.isEmpty ? "ділянок немає" : String(localized: "ділянок: \(m.surveys.count)"))).font(.caption).foregroundStyle(.secondary)
                }
                Card(title: String(localized: "1. Позначте межі"), icon: "square.on.square.dashed", text: String(localized: "Клацайте по карті, щоб поставити вершини ділянки. Галси (змійка) будуються автоматично й потрапляють у маршрут.")) {
                    ToolChoice(cmd: 5200, title: String(localized: "Намалювати ділянку"), hint: String(localized: "Клік по карті ставить вершини"), active: m.addMode && m.tool == 5200) {
                        if m.addMode && m.tool == 5200 { m.addMode = false } else { m.tool = 5200; m.addMode = true }
                    }
                    hint
                }
                if !m.surveys.isEmpty {
                    Card(title: String(localized: "Ділянки"), icon: "list.bullet", text: nil) {
                        ForEach(Array(m.surveys.enumerated()), id: \.element.id) { i, sv in row(i, sv) }
                    }
                }
                if let sv = m.survey {
                    params(sv)
                    result(sv)
                }
                MissionStatusView(m: m, issues: issues).padding(-10)
            }.padding(12)
        }
    }

    var issues: [MissionIssue] {
        var l: [MissionIssue] = []
        for (i, sv) in m.surveys.enumerated() {
            if sv.pts.count < 3 { l.append(.init(level: 1, text: String(localized: "Ділянка \(i + 1): потрібно щонайменше 3 вершини."))) }
            else if m.surveyResult(sv).items.filter({ $0.cmd == 16 }).count > 600 { l.append(.init(level: 1, text: String(localized: "Ділянка \(i + 1): понад 600 точок, це може не вміститись у пам'ять польотника. Збільшіть відстань між галсами."))) }
        }
        if !m.surveys.isEmpty { l.append(.init(level: 0, text: String(localized: "Додайте зліт на початку й RTL чи посадку в кінці маршруту, а потім запишіть місію у вкладці «Маршрут»."))) }
        return l
    }

    @ViewBuilder var hint: some View {
        if m.addMode, m.tool == 5200 {
            let n = m.survey?.pts.count ?? 0
            VStack(alignment: .leading, spacing: 6) {
                Label(lk(n == 0 ? "Клацайте по карті: потрібно щонайменше 3 вершини." : String(localized: "Вершин: \(n)\(n < 3 ? String(localized: " (ще треба \(3 - n))") : ""). Вершини можна перетягувати.")), systemImage: "hand.tap").font(.caption).foregroundStyle(.secondary)
                if n > 0 { Button { m.selectedSurvey = nil } label: { Label("Завершити ділянку, почати нову", systemImage: "checkmark.circle") }.controlSize(.small) }
            }
        } else {
            Label("Натисніть кнопку вище, щоб ставити вершини кліком по карті.", systemImage: "hand.tap").font(.caption).foregroundStyle(.secondary)
        }
    }

    func row(_ i: Int, _ sv: SurveyArea) -> some View {
        let sel = m.selectedSurvey == sv.id
        let r = m.surveyResult(sv)
        return HStack(spacing: 8) {
            Image(systemName: "square.grid.3x3").font(.system(size: 9, weight: .bold)).foregroundStyle(.white).frame(width: 20, height: 20).background(Color.purple, in: Circle())
            VStack(alignment: .leading, spacing: 0) {
                Text("Ділянка \(i + 1)").font(.callout)
                Text(lk(sv.pts.count < 3 ? String(localized: "вершин: \(sv.pts.count) (треба ≥ 3)") : String(format: loc("%.1f га · %d галсів"), r.area / 10_000, r.lines))).font(.caption2).foregroundStyle(sv.pts.count < 3 ? Color.orange : Color.secondary)
            }
            Spacer()
            Button(role: .destructive) { m.removeSurvey(sv.id) } label: { Image(systemName: "trash") }.buttonStyle(.borderless).help("Видалити ділянку й її точки")
        }
        .padding(6)
        .background(sel ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture { m.selectedSurvey = sel ? nil : sv.id; m.selected = nil }
    }

    func bind<T>(_ id: UUID, _ kp: WritableKeyPath<SurveyArea, T>) -> Binding<T> {
        Binding(get: { m.surveys.first { $0.id == id }![keyPath: kp] }, set: { v in m.mutateSurvey(id) { $0[keyPath: kp] = v } })
    }
    func num(_ title: String, _ unit: String, _ b: Binding<Double>) -> some View {
        HStack {
            Text(LocalizedStringKey(title)).font(.callout)
            Spacer()
            TextField("", value: b, format: .number.precision(.fractionLength(0...2))).textFieldStyle(.roundedBorder).frame(width: 74).multilineTextAlignment(.trailing)
            Text(LocalizedStringKey(unit)).font(.caption).foregroundStyle(.secondary).frame(width: 24, alignment: .leading)
        }
    }

    func params(_ sv: SurveyArea) -> some View {
        let id = sv.id
        return Card(title: String(localized: "2. Параметри"), icon: "slider.horizontal.3", text: nil) {
            num("Висота польоту", "м", bind(id, \.alt))
            HStack {
                Text("Система висоти").font(.callout); Spacer()
                Picker("", selection: bind(id, \.frame)) { ForEach(MissionCatalog.frames, id: \.0) { Text(lk($0.1)).tag($0.0) } }.labelsHidden().frame(width: 190)
            }
            HStack {
                Text("Напрям галсів").font(.callout)
                Spacer()
                Stepper(value: bind(id, \.angle), in: 0...359, step: 5) { Text(String(format: "%.0f°", sv.angle)).monospacedDigit() }.frame(width: 120)
            }
            Divider()
            Toggle("Відстань між галсами за камерою", isOn: bind(id, \.autoSpacing)).toggleStyle(.switch).controlSize(.small)
            if sv.autoSpacing {
                num("Поле зору камери", "°", bind(id, \.fov))
                num("Бічне перекриття", "%", bind(id, \.sideOverlap))
                num("Поздовжнє перекриття", "%", bind(id, \.fwdOverlap))
                Label(lk(String(format: loc("Кадр на землі ≈ %.0f × %.0f м; відстань між галсами %.0f м"), sv.footprintW, sv.footprintH, sv.lineSpacing)), systemImage: "camera.metering.matrix").font(.caption).foregroundStyle(.secondary)
            } else {
                num("Відстань між галсами", "м", bind(id, \.spacing))
            }
            Divider()
            num("Виліт на розворот", "м", bind(id, \.leadIn))
            num("Швидкість (0 = без змін)", "м/с", bind(id, \.speed))
            Toggle("Фото кожні N метрів (DO_SET_CAM_TRIGG_DIST)", isOn: bind(id, \.trigger)).toggleStyle(.switch).controlSize(.small)
            HStack(spacing: 14) {
                Toggle("Почати з іншого боку", isOn: bind(id, \.reverseLines)).controlSize(.small)
                Toggle("Інший напрям першого галса", isOn: bind(id, \.reverseFirst)).controlSize(.small)
            }.font(.caption)
        }
    }

    func result(_ sv: SurveyArea) -> some View {
        let r = m.surveyResult(sv)
        let speed = sv.speed > 0 ? sv.speed : m.cruise
        let eta = r.length / max(speed, 1)
        return Card(title: String(localized: "3. Результат"), icon: "checkmark.seal", text: nil) {
            if sv.pts.count < 3 { Text("Додайте ще вершини, щоб побудувати галси.").font(.callout).foregroundStyle(.secondary) }
            else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 8)], spacing: 8) {
                    Tile("Площа", String(format: loc("%.1f га"), r.area / 10_000))
                    Tile("Галсів", "\(r.lines)")
                    Tile("Точок", "\(r.points.count)")
                    Tile("Довжина", r.length >= 1000 ? String(format: loc("%.2f км"), r.length / 1000) : String(format: loc("%.0f м"), r.length))
                    Tile("Час", String(format: loc("≈ %d хв %d с"), Int(eta) / 60, Int(eta) % 60))
                    Tile("Фото", sv.trigger ? "≈ \(Int(r.length / sv.triggerDist))" : "—")
                }
            }
        }
    }
}
