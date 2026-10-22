import SwiftUI

/// Визначення й компенсація магнітних завад від моторів (CompassMot): вимірює вплив струму/газу на компас і зберігає COMPASS_MOT_X/Y/Z.
struct CompassMotCard: View {
    @Environment(Store.self) var s
    let cs: CalStore
    @State private var peak = 0
    @State private var note: String?
    var ps: ParamStore { s.ps }
    var mot: CompassMotDTO? { cs.cal?.compassMot }
    var active: Bool { mot?.active == true }
    var live: Bool { (mot?.age ?? -1) >= 0 && (mot?.age ?? 99) < 2 }
    var intf: Int { mot?.interference ?? 0 }

    var verdict: (String, Color) {
        if intf == 0 && !live { return ("немає даних", .secondary) }
        if intf < 30 { return ("добре: завади малі, компенсація не потрібна", .green) }
        if intf < 60 { return ("допустимо: компенсація покращить курс", .orange) }
        return ("високі завади: перенесіть компас далі від силових проводів", .red)
    }

    var body: some View {
        Card(title: String(localized: "Завади від двигунів (CompassMot)"), icon: "bolt.horizontal.circle", text: String(localized: "Моторі й силові дроти створюють магнітне поле, що спотворює показники компаса. Тест вимірює цей вплив залежно від струму й зберігає компенсацію (COMPASS_MOT_X/Y/Z).")) {
            VStack(alignment: .leading, spacing: 4) {
                Label("Потрібні встановлені пропелери, надійно закріплений апарат і працюючий датчик струму батареї.", systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                Label("Старт → плавно підніміть газ до половини й утримуйте 10–20 с → поверніть газ у нуль → «Завершити». Компенсація запишеться автоматично.", systemImage: "list.number").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                if !active {
                    Button { cs.run("/cal/compassmot/start"); peak = 0 } label: { Label("Старт тесту", systemImage: "play.fill") }
                        .buttonStyle(.borderedProminent).disabled(s.armed || !s.connected)
                } else {
                    Button(role: .destructive) { cs.run("/cal/compassmot/stop") } label: { Label("Завершити", systemImage: "stop.fill") }.buttonStyle(.borderedProminent).tint(.red)
                }
                Button("Скинути компенсацію") { reset() }.disabled(s.armed || active)
                Spacer()
                if active { Label(lk(live ? "тест іде" : "очікування даних від польотника…"), systemImage: "waveform").foregroundStyle(live ? .green : .secondary).font(.callout) }
            }
            if active || live || (mot?.seq ?? 0) > 0 {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                    GridRow {
                        Text("Газ").font(.callout)
                        ProgressView(value: Double(min(mot?.throttle ?? 0, 100)), total: 100).frame(width: 260)
                        Text("\(mot?.throttle ?? 0) %").font(.callout.monospacedDigit())
                    }
                    GridRow {
                        Text("Струм").font(.callout)
                        ProgressView(value: min(mot?.current ?? 0, 100), total: 100).frame(width: 260)
                        Text(String(format: loc("%.1f А"), mot?.current ?? 0)).font(.callout.monospacedDigit())
                    }
                    GridRow {
                        Text("Завади").font(.callout)
                        ProgressView(value: Double(min(intf, 100)), total: 100).tint(verdict.1).frame(width: 260)
                        Text("\(intf) %").font(.callout.monospacedDigit().weight(.semibold)).foregroundStyle(verdict.1)
                    }
                    GridRow {
                        Text("Компенсація").font(.callout)
                        Text(String(format: "X %.0f   Y %.0f   Z %.0f", mot?.x ?? 0, mot?.y ?? 0, mot?.z ?? 0)).font(.system(.callout, design: .monospaced))
                        Color.clear.frame(width: 1, height: 1)
                    }
                }
                Label(lk(loc("Оцінка: ") + verdict.0), systemImage: "checkmark.seal").font(.callout).foregroundStyle(verdict.1)
            }
            Divider()
            Text("ПАРАМЕТРИ КОМПЕНСАЦІЇ").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(["COMPASS_MOTCT", "COMPASS_MOT_X", "COMPASS_MOT_Y", "COMPASS_MOT_Z", "COMPASS_MOT2_X", "COMPASS_MOT2_Y", "COMPASS_MOT2_Z", "COMPASS_MOT3_X", "COMPASS_MOT3_Y", "COMPASS_MOT3_Z"].filter { ps.has($0) }, id: \.self) { AdvParamRow(name: $0) }
            if let n = note { Text(LocalizedStringKey(n)).font(.caption).foregroundStyle(.secondary) }
        }
    }

    func reset() {
        for n in ["COMPASS_MOTCT", "COMPASS_MOT_X", "COMPASS_MOT_Y", "COMPASS_MOT_Z", "COMPASS_MOT2_X", "COMPASS_MOT2_Y", "COMPASS_MOT2_Z", "COMPASS_MOT3_X", "COMPASS_MOT3_Y", "COMPASS_MOT3_Z"] where ps.has(n) { ps.write(n, 0) }
        note = String(localized: "Компенсацію вимкнено й обнулено")
    }
}
