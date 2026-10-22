import SwiftUI
import Charts

struct MsgStatDTO: Decodable, Identifiable { let name: String; let id: Int; let sys: Int; let comp: Int; let count: Int; let hz: Double; let age: Double }

/// MAVLink Inspector: усі повідомлення, що надходять від польотника, їхня частота, лічильники й поля; вибрані поля можна виводити на графік.
struct MavInspectorTab: View {
    @Environment(Store.self) var s
    @Environment(FlightStore.self) var fs
    @State private var stats: [MsgStatDTO] = []
    @State private var selected: String?
    @State private var search = ""
    @State private var plotted: [String] = []
    @State private var history: [String: [(t: Date, v: Double)]] = [:]
    @State private var normalize = false
    @State private var pollTask: Task<Void, Never>?

    var shown: [MsgStatDTO] { stats.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) } }
    var fields: [FieldDTO] {
        guard let sel = selected else { return [] }
        let pre = sel + "."
        return fs.fields.filter { $0.k.hasPrefix(pre) }
    }

    var body: some View {
        HStack(spacing: 0) {
            messageList.frame(width: 300)
            Divider()
            fieldList.frame(width: 330)
            Divider()
            chart.frame(maxWidth: .infinity)
        }
        .onAppear { fs.startFields(); start() }
        .onDisappear { fs.stop("fields"); pollTask?.cancel() }
        .onChange(of: fs.fields) { _, new in record(new) }
    }

    func start() {
        pollTask?.cancel()
        pollTask = Task { @MainActor in
            while !Task.isCancelled {
                if let l = await EngineAPI.get("/msgstats", as: [MsgStatDTO].self) { stats = l }
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
        }
    }

    func record(_ f: [FieldDTO]) {
        guard !plotted.isEmpty else { return }
        let now = Date()
        for k in plotted { if let x = f.first(where: { $0.k == k }), let v = Double(x.v) { var h = history[k] ?? []; h.append((now, v)); if h.count > 400 { h.removeFirst(h.count - 400) }; history[k] = h } }
    }

    // MARK: Повідомлення

    var messageList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Пошук повідомлення", text: $search).textFieldStyle(.plain)
                Button { EngineAPI.post("/msgstats/reset") } label: { Image(systemName: "arrow.counterclockwise") }.buttonStyle(.borderless).help("Скинути лічильники")
            }.padding(8)
            HStack {
                Text("Повідомлення").frame(maxWidth: .infinity, alignment: .leading)
                Text("Гц").frame(width: 42, alignment: .trailing)
                Text("Кількість").frame(width: 62, alignment: .trailing)
            }.font(.caption2.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.bottom, 3)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(shown) { m in
                        HStack {
                            VStack(alignment: .leading, spacing: 0) {
                                Text(LocalizedStringKey(m.name)).font(.system(.caption, design: .monospaced)).lineLimit(1)
                                Text("ID \(m.id) · \(m.sys):\(m.comp)").font(.caption2).foregroundStyle(.tertiary)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Text(lk(m.hz < 0.05 ? "—" : String(format: "%.1f", m.hz))).font(.caption.monospacedDigit()).foregroundStyle(m.age > 2.5 ? Color.secondary : Color.primary).frame(width: 42, alignment: .trailing)
                            Text("\(m.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 62, alignment: .trailing)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 3)
                        .background(selected == m.name ? Color.accentColor.opacity(0.18) : .clear)
                        .contentShape(Rectangle())
                        .onTapGesture { selected = m.name }
                    }
                }
            }
            Divider()
            HStack {
                Text("Типів: \(stats.count)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(String(format: loc("%.0f пак./с"), s.t.msgRate)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }.padding(.horizontal, 10).padding(.vertical, 4)
        }
    }

    // MARK: Поля

    var fieldList: some View {
        VStack(spacing: 0) {
            HStack {
                Text(lk(selected ?? "Оберіть повідомлення")).font(.system(.callout, design: .monospaced).weight(.semibold))
                Spacer()
                if let sel = selected, let m = stats.first(where: { $0.name == sel }) { Text(lk(m.hz < 0.05 ? "" : String(format: loc("%.1f Гц"), m.hz))).font(.caption).foregroundStyle(.secondary) }
            }.padding(10)
            Divider()
            if selected == nil {
                ContentUnavailableView("Оберіть повідомлення ліворуч", systemImage: "list.bullet.rectangle", description: Text("Поля з'являться тут, а числові можна вивести на графік."))
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(fields, id: \.k) { f in
                            let name = String(f.k.drop(while: { $0 != "." }).dropFirst())
                            let numeric = Double(f.v) != nil
                            let on = plotted.contains(f.k)
                            HStack(spacing: 8) {
                                Button { toggle(f.k) } label: { Image(systemName: on ? "chart.xyaxis.line" : "chart.xyaxis.line").foregroundStyle(on ? Color.accentColor : Color.secondary.opacity(numeric ? 0.7 : 0.2)) }
                                    .buttonStyle(.borderless).disabled(!numeric).help(lk(numeric ? "Додати на графік" : "Не числове поле"))
                                Text(LocalizedStringKey(name)).font(.system(.caption, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading)
                                Text(LocalizedStringKey(f.v)).font(.system(.caption, design: .monospaced).monospacedDigit()).lineLimit(1).truncationMode(.middle).frame(maxWidth: 140, alignment: .trailing)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 3)
                            Divider().opacity(0.3)
                        }
                    }
                }
            }
        }
    }

    func toggle(_ k: String) {
        if let i = plotted.firstIndex(of: k) { plotted.remove(at: i); history[k] = nil }
        else { if plotted.count >= 6 { plotted.removeFirst() }; plotted.append(k); if let f = fs.fields.first(where: { $0.k == k }), let v = Double(f.v) { history[k] = [(Date(), v)] } }
    }

    // MARK: Графік

    static let palette: [Color] = [.blue, .orange, .green, .pink, .purple, .teal]

    var chart: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Графік").font(.callout.weight(.semibold))
                Spacer()
                if plotted.count > 1 { Toggle("Нормалізувати", isOn: $normalize).toggleStyle(.checkbox).font(.caption) }
                Button("Очистити") { plotted = []; history = [:] }.controlSize(.small).disabled(plotted.isEmpty)
            }.padding(10)
            Divider()
            if plotted.isEmpty {
                ContentUnavailableView("Графік порожній", systemImage: "chart.xyaxis.line", description: Text("Натисніть значок графіка біля числового поля, щоб побачити його зміну в часі."))
            } else {
                let now = Date()
                Chart {
                    ForEach(Array(plotted.enumerated()), id: \.element) { i, k in
                        let h = history[k] ?? []
                        let lo = h.map(\.v).min() ?? 0, hi = h.map(\.v).max() ?? 1
                        ForEach(Array(h.enumerated()), id: \.offset) { _, p in
                            LineMark(x: .value("t", p.t.timeIntervalSince(now)), y: .value("v", normalize && hi > lo ? (p.v - lo) / (hi - lo) : p.v), series: .value("s", k))
                                .foregroundStyle(Self.palette[i % Self.palette.count])
                        }
                    }
                }
                .chartXAxis { AxisMarks { v in AxisGridLine(); AxisValueLabel { if let d = v.as(Double.self) { Text(String(format: loc("%.0f с"), d)).font(.caption2) } } } }
                .chartLegend(.hidden)
                .padding(10)
                HStack(spacing: 10) {
                    ForEach(Array(plotted.enumerated()), id: \.element) { i, k in
                        HStack(spacing: 4) { Circle().fill(Self.palette[i % Self.palette.count]).frame(width: 7, height: 7); Text(LocalizedStringKey(k)).font(.system(.caption2, design: .monospaced)) }
                    }
                    Spacer()
                }.padding(.horizontal, 10).padding(.bottom, 6)
            }
        }
    }
}
