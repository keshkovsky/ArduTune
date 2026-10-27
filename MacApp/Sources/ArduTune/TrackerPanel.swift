import SwiftUI
import MapKit

/// Вкладка Tracker у Flight Data: наведення антени на апарат (азимут, кут місця, відстань від станції) і дані реального трекера AntennaTracker.
struct TrackerPanel: View {
    @Environment(Store.self) var s
    private var station: StationStore { StationStore.shared }

    var body: some View {
        let t = s.t
        let isTracker = t.vehicle == "ANTENNA_TRACKER"
        ScrollView {
            HStack(alignment: .top, spacing: 14) {
                aimSection(t, isTracker: isTracker)
                trackerSection(t, isTracker: isTracker)
            }.padding(14)
        }
    }

    // MARK: Наведення на апарат

    @ViewBuilder func aimSection(_ t: Telemetry, isTracker: Bool) -> some View {
        let homeC: CLLocationCoordinate2D? = t.homeSet ? .init(latitude: t.homeLat, longitude: t.homeLon) : s.mission.home.map { .init(latitude: $0.lat, longitude: $0.lon) }
        let st = station.coordinate(home: homeC)
        let hasFix = t.gpsFix >= 3
        let aim: AimResult? = (st != nil && hasFix && !isTracker) ? Aim.compute(from: st!, to: .init(latitude: t.lat, longitude: t.lon), height: t.altRel) : nil
        StatusSection(title: "Наведення на апарат") {
            if let a = aim {
                HStack(spacing: 22) {
                    big("Азимут", String(format: "%03.0f°", a.azimuth))
                    big("Кут місця", String(format: "%+.0f°", a.elevation))
                    big("Відстань", Units.dist(a.distance))
                }
            } else {
                Text(lk(isTracker ? "Підключено трекер: наведення на апарат рахує він сам (див. праворуч)." : (!hasFix ? "Немає GPS-позиції апарата." : "Немає позиції станції: оберіть джерело нижче.")))
                    .font(.callout).foregroundStyle(.secondary)
            }
            Divider().opacity(0.5)
            Text("Позиція станції (антени)").font(.caption).foregroundStyle(.secondary)
            Picker("", selection: Binding(get: { station.source }, set: { station.source = $0 })) {
                Text("Home апарата").tag("home"); Text("Цей Mac").tag("mac"); Text("Вручну").tag("manual")
            }.pickerStyle(.segmented).labelsHidden()
            switch station.source {
            case "mac": Text(lk(station.macStatus.isEmpty ? "Вмикається геолокація Mac." : station.macStatus)).font(.caption).foregroundStyle(.secondary)
            case "manual":
                Text(lk(station.hasManual ? Coords.pair(station.manualLat, station.manualLon, decimals: 5) : "Не задано: правий клік по мапі → «Поставити станцію антени тут».")).font(.caption).foregroundStyle(.secondary)
            default: Text(lk(homeC == nil ? "Home ще не встановлено." : "Береться Home польотника або плану місії.")).font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Лінія наведення на мапі", isOn: Binding(get: { station.aimLine }, set: { station.aimLine = $0 })).toggleStyle(.checkbox).font(.callout)
            Text("Кут місця рахується відносно висоти станції над Home апарата; для наземної станції біля Home це точно.").font(.caption2).foregroundStyle(.secondary)
        }
        .frame(minWidth: 320)
    }

    private func big(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(lk(title)).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 24, weight: .semibold, design: .rounded)).monospacedDigit()
        }
    }

    // MARK: Реальний трекер

    @ViewBuilder func trackerSection(_ t: Telemetry, isTracker: Bool) -> some View {
        if isTracker {
            StatusSection(title: "Антенний трекер", badge: (t.mode ?? "—", .accentColor)) {
                HStack(alignment: .top, spacing: 18) {
                    TrackerDial(heading: t.heading, target: t.navBearing).frame(width: 150, height: 150)
                    VStack(alignment: .leading, spacing: 6) {
                        row("Курс антени", String(format: "%03.0f°", t.heading))
                        row("Ціль: азимут", String(format: "%03.0f°", t.navBearing))
                        row("Ціль: нахил", String(format: "%+.0f°", t.navPitch))
                        row("Відстань до цілі", Units.dist(t.wpDist))
                        Divider().opacity(0.5)
                        row("GPS трекера", t.gpsFix >= 3 ? String(format: loc("3D, %lld сат."), t.sats) : String(format: loc("немає фіксу (%lld сат.)"), t.sats))
                        row("Позиція", t.gpsFix >= 2 ? Coords.pair(t.lat, t.lon, decimals: 5) : "—")
                    }
                }
                Text("Дані трекера: режим, напрям на ціль і положення антени. Керування (режими, ручна ціль на мапі, клавіші, сектор антени): піктограма радара у правому куті мапи Flight Data.").font(.caption2).foregroundStyle(.secondary)
            }
            .frame(minWidth: 380)
        } else {
            StatusSection(title: "Антенний трекер") {
                Text("Підключіть плату з прошивкою AntennaTracker, і тут з'являться її режим, напрям на ціль, позиція та GPS. Налаштування трекера: Optional Hardware → Антенний трекер.").font(.callout).foregroundStyle(.secondary)
            }
            .frame(minWidth: 320)
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack { Text(lk(title)).font(.callout); Spacer(minLength: 12); Text(lk(value)).font(.callout.monospacedDigit().weight(.medium)) }.frame(width: 220)
    }
}

/// Компасне коло: помаранчева стрілка — поточний курс антени, бірюзова лінія — напрям на ціль.
struct TrackerDial: View {
    let heading: Double
    let target: Double
    var body: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2), R = min(size.width, size.height) / 2 - 14
            ctx.stroke(Path(ellipseIn: CGRect(x: c.x - R, y: c.y - R, width: 2 * R, height: 2 * R)), with: .color(.secondary.opacity(0.6)), lineWidth: 1.2)
            for d in stride(from: 0, to: 360, by: 15) {
                let a = (Double(d) - 90) * .pi / 180, len: CGFloat = d % 90 == 0 ? 9 : (d % 45 == 0 ? 6 : 3)
                var p = Path(); p.move(to: CGPoint(x: c.x + R * cos(a), y: c.y + R * sin(a))); p.addLine(to: CGPoint(x: c.x + (R - len) * cos(a), y: c.y + (R - len) * sin(a)))
                ctx.stroke(p, with: .color(.secondary.opacity(0.7)), lineWidth: 1)
            }
            for (d, l) in [(0, "N"), (90, "E"), (180, "S"), (270, "W")] {
                let a = (Double(d) - 90) * .pi / 180
                ctx.draw(Text(l).font(.caption2.weight(.semibold)).foregroundColor(d == 0 ? .red : .secondary), at: CGPoint(x: c.x + (R + 9) * cos(a), y: c.y + (R + 9) * sin(a)))
            }
            // ціль
            let ta = (target - 90) * .pi / 180
            var tp = Path(); tp.move(to: c); tp.addLine(to: CGPoint(x: c.x + R * cos(ta), y: c.y + R * sin(ta)))
            ctx.stroke(tp, with: .color(.teal), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            // поточний курс
            let ha = (heading - 90) * .pi / 180
            var hp = Path()
            hp.move(to: CGPoint(x: c.x + (R - 4) * cos(ha), y: c.y + (R - 4) * sin(ha)))
            hp.addLine(to: CGPoint(x: c.x + 12 * cos(ha + 2.6), y: c.y + 12 * sin(ha + 2.6)))
            hp.addLine(to: CGPoint(x: c.x + 12 * cos(ha - 2.6), y: c.y + 12 * sin(ha - 2.6)))
            hp.closeSubpath()
            ctx.fill(hp, with: .color(.orange))
        }
    }
}
