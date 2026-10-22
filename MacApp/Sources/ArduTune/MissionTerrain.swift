import SwiftUI
import MapKit
import Charts

// MARK: - Висоти рельєфу вздовж маршруту

/// Висота рельєфу з відкритого API Open-Meteo (Copernicus DEM, ~90 м). Кеш у пам'яті за координатами з точністю ~1 м.
@Observable
final class MissionTerrain {
    struct Sample { let d: Double; let lat: Double; let lon: Double; var elev: Double?; let vertex: Int? }
    var samples: [Sample] = []
    var status = ""
    @ObservationIgnored private var cache: [String: Double] = [:]
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var lastSig = ""

    private static func key(_ la: Double, _ lo: Double) -> String { String(format: "%.5f,%.5f", la, lo) }

    /// Точки вздовж маршруту: усі вершини + проміжні кожні ≈ step метрів.
    static func sample(_ route: [CLLocationCoordinate2D]) -> [Sample] {
        guard route.count > 1 else { return [] }
        let legs = zip(route, route.dropFirst()).map { CLLocation(latitude: $0.latitude, longitude: $0.longitude).distance(from: CLLocation(latitude: $1.latitude, longitude: $1.longitude)) }
        let total = legs.reduce(0, +)
        let step = max(30, total / 160)
        var out: [Sample] = []; var cum = 0.0
        for (i, len) in legs.enumerated() {
            let a = route[i], b = route[i + 1]
            let n = max(1, Int((len / step).rounded(.up)))
            for j in 0..<n {
                let f = Double(j) / Double(n)
                out.append(Sample(d: cum + len * f, lat: a.latitude + (b.latitude - a.latitude) * f, lon: a.longitude + (b.longitude - a.longitude) * f, elev: nil, vertex: j == 0 ? i : nil))
            }
            cum += len
        }
        out.append(Sample(d: cum, lat: route.last!.latitude, lon: route.last!.longitude, elev: nil, vertex: route.count - 1))
        return out
    }

    func update(route: [CLLocationCoordinate2D]) {
        let sig = route.map { Self.key($0.latitude, $0.longitude) }.joined(separator: ";")
        guard sig != lastSig else { return }
        lastSig = sig
        task?.cancel()
        if route.count < 2 { samples = []; status = ""; return }
        task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)            // не запитуємо під час перетягування
            guard !Task.isCancelled, let self else { return }
            var s = Self.sample(route)
            let missing = Array(Set(s.map { Self.key($0.lat, $0.lon) }.filter { self.cache[$0] == nil }))
            if !missing.isEmpty { await MainActor.run { self.status = String(localized: "Завантаження рельєфу…") } }
            var failed = false
            for chunk in stride(from: 0, to: missing.count, by: 100).map({ Array(missing[$0..<min($0 + 100, missing.count)]) }) {
                if Task.isCancelled { return }
                let lat = chunk.map { String($0.split(separator: ",")[0]) }.joined(separator: ",")
                let lon = chunk.map { String($0.split(separator: ",")[1]) }.joined(separator: ",")
                guard let url = URL(string: "https://api.open-meteo.com/v1/elevation?latitude=\(lat)&longitude=\(lon)") else { failed = true; break }
                var req = URLRequest(url: url); req.timeoutInterval = 20
                if let (d, resp) = try? await URLSession.shared.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200,
                   let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let e = j["elevation"] as? [Double], e.count == chunk.count {
                    for (k, v) in zip(chunk, e) { self.cache[k] = v }
                } else { failed = true; break }
            }
            for i in s.indices { s[i].elev = self.cache[Self.key(s[i].lat, s[i].lon)] }
            let ok = !failed && s.allSatisfy { $0.elev != nil }
            let done = s
            await MainActor.run {
                if Task.isCancelled { return }
                self.samples = done
                self.status = ok ? "" : "Рельєф недоступний (немає мережі?): показано лише планову висоту"
            }
        }
    }
}

// MARK: - Профіль висоти: рельєф і планова висота

struct MissionProfile: View {
    let m: MissionStore
    @State private var terrain = MissionTerrain()
    @State private var hoverD: Double?
    @AppStorage("mission.minAGL") private var minAGL = 30.0

    struct RP { let id: UUID?; let n: Int?; let item: MissionItem? }      // вершина маршруту: Home або точка плану

    var route: ([CLLocationCoordinate2D], [RP]) {
        var c: [CLLocationCoordinate2D] = [], r: [RP] = []
        if let h = m.home { c.append(.init(latitude: h.lat, longitude: h.lon)); r.append(RP(id: nil, n: nil, item: nil)) }
        for (i, it) in m.items.enumerated() where it.def.nav && it.hasPos { c.append(it.coord); r.append(RP(id: it.id, n: i + 1, item: it)) }
        return (c, r)
    }

    struct Pt: Identifiable { let id = UUID(); let d: Double; let v: Double }
    struct Mark: Identifiable { let id: UUID; let n: Int; let d: Double; let v: Double; let low: Bool }
    struct Calc {
        var terrain: [Pt] = [], plan: [Pt] = [], marks: [Mark] = []
        var lo = 0.0, hi = 10.0, minClear: Double?, minAt = 0.0, hasTerrain = false
        var detail: [(d: Double, ground: Double?, plan: Double)] = []
    }

    func calc(_ rp: [RP]) -> Calc {
        var c = Calc()
        let s = terrain.samples
        let have = s.count > 1 && s.allSatisfy { $0.elev != nil } && rp.count == (s.compactMap(\.vertex).max() ?? -1) + 1
        c.hasTerrain = have
        // вершини: відстань і висота
        var vd: [Double] = [], vplan: [Double] = [], vframe10: [Bool] = [], valt: [Double] = []
        if have {
            let homeElev = s.first(where: { $0.vertex == 0 })?.elev ?? 0
            for (k, r) in rp.enumerated() {
                let sm = s.first { $0.vertex == k }!
                vd.append(sm.d)
                let g = sm.elev ?? 0
                if let it = r.item {
                    valt.append(it.alt)
                    switch it.frame { case 0: vplan.append(it.alt); vframe10.append(false); case 10: vplan.append(g + it.alt); vframe10.append(true); default: vplan.append(homeElev + it.alt); vframe10.append(false) }
                } else { valt.append(0); vplan.append(g); vframe10.append(false) }
            }
            for sm in s {
                let g = sm.elev ?? 0
                // сегмент між сусідніми вершинами
                var k = 0; while k + 1 < vd.count - 0 && vd[k + 1] <= sm.d + 0.001 && k + 1 < vd.count - 1 { k += 1 }
                let k2 = min(k + 1, vd.count - 1)
                let span = max(vd[k2] - vd[k], 0.001); let f = min(max((sm.d - vd[k]) / span, 0), 1)
                let plan: Double
                if vframe10[k] && vframe10[k2] { plan = g + valt[k] + (valt[k2] - valt[k]) * f }
                else { plan = vplan[k] + (vplan[k2] - vplan[k]) * f }
                c.terrain.append(Pt(d: sm.d, v: g)); c.plan.append(Pt(d: sm.d, v: plan))
                c.detail.append((sm.d, g, plan))
                let clear = plan - g
                if clear >= 0, c.minClear == nil || clear < c.minClear! { c.minClear = clear; c.minAt = sm.d }
            }
            for (k, r) in rp.enumerated() { if let id = r.id, let n = r.n { c.marks.append(Mark(id: id, n: n, d: vd[k], v: vplan[k], low: false)) } }
        } else {
            // без рельєфу: планова висота над точкою старту
            var dist = 0.0; var prev: MissionItem?
            for r in rp {
                guard let it = r.item else { continue }
                if let p = prev { dist += CLLocation(latitude: p.lat, longitude: p.lon).distance(from: CLLocation(latitude: it.lat, longitude: it.lon)) }
                c.plan.append(Pt(d: dist, v: it.alt)); c.marks.append(Mark(id: it.id, n: r.n ?? 0, d: dist, v: it.alt, low: false)); c.detail.append((dist, nil, it.alt)); prev = it
            }
        }
        let all = c.terrain.map(\.v) + c.plan.map(\.v)
        c.lo = (all.min() ?? 0) - 6; c.hi = (all.max() ?? 10) + 12
        if c.lo > 0 && !have { c.lo = 0 }
        return c
    }

    var body: some View {
        let (coords, rp) = route
        let sig = coords.map { String(format: "%.5f,%.5f", $0.latitude, $0.longitude) }.joined(separator: ";")
        let c = calc(rp)
        VStack(alignment: .leading, spacing: 2) {
            if c.plan.count < 2 {
                Spacer()
                Label("Профіль висоти з'явиться, коли в плані буде щонайменше дві точки з координатами", systemImage: "chart.line.uptrend.xyaxis").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                Spacer()
            } else {
                header(c)
                chart(c)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .task(id: sig) { terrain.update(route: coords) }
    }

    func header(_ c: Calc) -> some View {
        HStack(spacing: 12) {
            legend(.accentColor, "Планова висота польоту")
            if c.hasTerrain { legend(.brown, "Рельєф (фактична висота землі)") }
            Spacer()
            if let h = hoverD, let n = c.detail.min(by: { abs($0.d - h) < abs($1.d - h) }) {
                Text(String(format: loc("%@ · політ %.0f м%@%@"), n.d >= 1000 ? String(format: loc("%.2f км"), n.d / 1000) : String(format: loc("%.0f м"), n.d), n.plan,
                            n.ground.map { String(format: loc(" · земля %.0f м"), $0) } ?? "", n.ground.map { String(format: loc(" · над землею %.0f м"), n.plan - $0) } ?? ""))
                    .font(.caption.monospacedDigit())
            } else if let mc = c.minClear {
                Label(lk(String(format: loc("мін. над землею %.0f м"), mc)), systemImage: mc < minAGL ? "exclamationmark.triangle.fill" : "checkmark.circle")
                    .font(.caption).foregroundStyle(mc < minAGL ? Color.orange : Color.secondary)
                if mc < minAGL - 0.5 {
                    Button("Підняти до \(Int(minAGL)) м") { raise(route.1) }.controlSize(.mini).help("Підняти точки, де апарат опиняється нижче безпечної висоти над землею")
                }
            }
            if c.hasTerrain {
                HStack(spacing: 2) {
                    Text("безпечно").font(.caption2).foregroundStyle(.tertiary)
                    TextField("", value: $minAGL, format: .number).textFieldStyle(.roundedBorder).controlSize(.mini).frame(width: 40).multilineTextAlignment(.trailing)
                    Text("м").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            if !terrain.status.isEmpty { Text(LocalizedStringKey(terrain.status)).font(.caption2).foregroundStyle(.secondary) }
            else if c.hasTerrain { Text("Рельєф: Open-Meteo").font(.caption2).foregroundStyle(.tertiary) }
        }
    }
    /// Піднімає висоту навігаційних точок так, щоб над землею завжди було не менше minAGL (точки в системі «над рельєфом», посадка, зліт і точки ділянок не чіпаємо).
    func raise(_ rp: [RP]) {
        let vdist: [Int: Double] = Dictionary(uniqueKeysWithValues: terrain.samples.compactMap { s in s.vertex.map { ($0, s.d) } })
        for _ in 0..<12 {
            let rp = route.1            // свіжі висоти після попередніх піднять
            let c = calc(rp)
            guard c.hasTerrain else { return }
            let clear = c.detail.enumerated().compactMap { i, d in d.ground.map { (i, d.plan - $0) } }
            guard let worst = clear.min(by: { $0.1 < $1.1 }), worst.1 < minAGL - 0.5 else { return }
            let deficit = (minAGL - worst.1).rounded(.up)
            let d = c.detail[worst.0].d
            let ks = vdist.sorted { $0.key < $1.key }
            guard let lo = ks.last(where: { $0.value <= d + 0.001 })?.key else { return }
            let hi = min(lo + 1, ks.count - 1)
            var moved = false
            for k in Set([lo, hi]) {
                guard let it = rp[k].item, it.frame != 10, it.group == nil, ![20, 21, 22].contains(it.cmd), let id = rp[k].id else { continue }
                m.update(id) { $0.alt += deficit }; moved = true
            }
            if !moved { return }
        }
    }

    func legend(_ col: Color, _ t: String) -> some View { HStack(spacing: 4) { Circle().fill(col).frame(width: 7, height: 7); Text(LocalizedStringKey(t)).font(.caption).foregroundStyle(.secondary) } }

    func chart(_ c: Calc) -> some View {
        Chart {
            if c.hasTerrain {
                ForEach(c.terrain) { p in
                    AreaMark(x: .value("d", p.d), yStart: .value("lo", c.lo), yEnd: .value("Рельєф", p.v)).foregroundStyle(Color.brown.opacity(0.28))
                    LineMark(x: .value("d", p.d), y: .value("Рельєф", p.v), series: .value("s", "g")).foregroundStyle(Color.brown).lineStyle(StrokeStyle(lineWidth: 1.5))
                }
            }
            ForEach(c.plan) { p in
                LineMark(x: .value("d", p.d), y: .value("Політ", p.v), series: .value("s", "p")).foregroundStyle(Color.accentColor).lineStyle(StrokeStyle(lineWidth: 2.5))
            }
            ForEach(c.marks) { k in
                PointMark(x: .value("d", k.d), y: .value("Політ", k.v)).foregroundStyle(k.id == m.selected ? Color.orange : Color.accentColor).symbolSize(k.id == m.selected ? 90 : 42)
                    .annotation(position: .top, spacing: 1) { Text("\(k.n)").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary) }
            }
            if let h = hoverD { RuleMark(x: .value("d", h)).foregroundStyle(.secondary.opacity(0.5)) }
        }
        .chartYScale(domain: c.lo...c.hi)
        .chartXAxis { AxisMarks { v in AxisGridLine(); AxisValueLabel { if let d = v.as(Double.self) { Text(lk(d >= 1000 ? String(format: loc("%.1f км"), d / 1000) : String(format: loc("%.0f м"), d))).font(.caption2) } } } }
        .chartYAxis { AxisMarks { v in AxisGridLine(); AxisValueLabel { if let a = v.as(Double.self) { Text(String(format: "%.0f", a)).font(.caption2) } } } }
        .chartOverlay { proxy in
            GeometryReader { g in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let pt):
                            let x = pt.x - g[proxy.plotAreaFrame].origin.x
                            hoverD = proxy.value(atX: x, as: Double.self)
                        case .ended: hoverD = nil
                        }
                    }
            }
        }
    }
}
