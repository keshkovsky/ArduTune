import SwiftUI

/// Каркас сторінки налаштувань: перевіряє підключення та завантаження параметрів.
struct ConfigGate<Content: View>: View {
    @Environment(Store.self) var s
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                OfflineBanner()
                if !s.canView {
                    ContentUnavailableView("Польотник не підключений", systemImage: "cable.connector", description: Text("Підключіть плату по USB"))
                } else if s.ps.params.isEmpty {
                    ProgressView("Завантаження параметрів…")
                } else {
                    if s.armedLive { Label("Апарат ARMED: редагування заблоковано", systemImage: "lock.fill").foregroundStyle(.red) }
                    content
                }
            }
            .padding()
        }
    }
}

/// Картка з параметрами: показує лише ті, що є в прошивці; якщо жодного немає, не малюється.
struct ParamsCard: View {
    @Environment(Store.self) var s
    let title: String; let icon: String; var text: String? = nil
    let params: [String]
    var describe = true
    var body: some View {
        let present = params.filter { s.ps.has($0) }
        if !present.isEmpty {
            Card(title: title, icon: icon, text: text) {
                VStack(spacing: 0) {
                    ForEach(present, id: \.self) { p in AdvParamRow(name: p, describe: describe); if p != present.last { Divider().opacity(0.4) } }
                }
            }
        }
    }
}

struct PageTitle: View {
    let title: String; let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(LocalizedStringKey(title)).font(.title3.weight(.semibold))
            Text(LocalizedStringKey(subtitle)).font(.caption).foregroundStyle(.secondary)
        }.padding(.top, 6)
    }
}

struct StepTitle: View {
    let n: Int; let title: String
    var body: some View {
        HStack(spacing: 8) {
            Text("\(n)").font(.caption.weight(.bold)).foregroundStyle(.white).frame(width: 20, height: 20).background(Color.accentColor, in: Circle())
            Text(LocalizedStringKey(title)).font(.headline)
        }.padding(.top, 4)
    }
}

/// Блок «Додаткові налаштування», що згортається; стан зберігається за ключем.
struct AdvancedSection<Content: View>: View {
    let title: String; let subtitle: String
    @AppStorage private var open: Bool
    @ViewBuilder var content: Content
    init(key: String, title: String = "Додаткові налаштування", subtitle: String, @ViewBuilder content: () -> Content) {
        self.title = title; self.subtitle = subtitle; self.content = content()
        _open = AppStorage(wrappedValue: true, key)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button { withAnimation(.snappy(duration: 0.2)) { open.toggle() } } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right").rotationEffect(.degrees(open ? 90 : 0)).font(.system(size: 11, weight: .bold)).frame(width: 12)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(LocalizedStringKey(title)).font(.title3.weight(.semibold))
                        Text(LocalizedStringKey(subtitle)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).padding(.top, 10)
            if open { content }
        }
    }
}

struct RebootRow: View {
    @Environment(Store.self) var s
    var text = "Деякі зміни застосовуються після перезавантаження автопілота."
    var body: some View {
        HStack {
            Label(LocalizedStringKey(text), systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button { EngineAPI.post("/reboot") } label: { Label("Перезавантажити автопілот", systemImage: "restart") }.disabled(s.armed)
        }
    }
}

func paramNames(_ ps: ParamStore, prefix: String, excluding: Set<String>) -> [String] {
    ps.params.map(\.name).filter { $0.hasPrefix(prefix) && !excluding.contains($0) }.sorted()
}

// MARK: - GPS і навігація

struct GPSNavView: View {
    @Environment(Store.self) var s
    var ps: ParamStore { s.ps }

    static let gps1 = ["GPS1_TYPE", "GPS_TYPE", "GPS1_GNSS_MODE", "GPS_GNSS_MODE", "GPS1_RATE_MS", "GPS_RATE_MS", "GPS1_COM_PORT", "GPS1_DELAY_MS", "GPS_DELAY_MS",
                       "GPS1_POS_X", "GPS1_POS_Y", "GPS1_POS_Z", "GPS_POS1_X", "GPS_POS1_Y", "GPS_POS1_Z", "GPS1_CAN_OVRIDE", "GPS1_CAN_NODEID", "GPS1_MB_TYPE", "GPS1_OPT_RNG"]
    static let gps2 = ["GPS2_TYPE", "GPS_TYPE2", "GPS2_GNSS_MODE", "GPS_GNSS_MODE2", "GPS2_RATE_MS", "GPS_RATE_MS2", "GPS2_COM_PORT", "GPS2_DELAY_MS", "GPS_DELAY_MS2",
                       "GPS2_POS_X", "GPS2_POS_Y", "GPS2_POS_Z", "GPS_POS2_X", "GPS_POS2_Y", "GPS_POS2_Z", "GPS2_CAN_OVRIDE", "GPS2_CAN_NODEID", "GPS2_MB_TYPE", "GPS2_OPT_RNG"]
    static let general = ["GPS_AUTO_CONFIG", "GPS_AUTO_SWITCH", "GPS_PRIMARY", "GPS_BLEND_MASK", "GPS_BLEND_TC", "GPS_MIN_ELEV", "GPS_NAVFILTER", "GPS_SBAS_MODE",
                          "GPS_HDOP_GOOD", "GPS_HDOP_ON", "GPS_HDOP_OFF", "GPS_NS_ON", "GPS_NS_OFF", "GPS_T_ON", "GPS_T_OFF", "GPS_SAVE_CFG", "GPS_RAW_DATA", "GPS_DRV_OPTIONS", "GPS_INJECT_TO", "GPS_SBP_LOGMASK"]
    static let ahrs = ["AHRS_GPS_USE", "AHRS_GPS_GAIN", "AHRS_GPS_MINSATS", "AHRS_EKF_TYPE", "AHRS_ORIENTATION", "AHRS_WIND_MAX"]
    static let ekf = ["EK3_ENABLE", "EK2_ENABLE", "EK3_SRC1_POSXY", "EK3_SRC1_VELXY", "EK3_SRC1_POSZ", "EK3_SRC1_VELZ", "EK3_SRC1_YAW",
                      "EK3_SRC2_POSXY", "EK3_SRC2_VELXY", "EK3_SRC2_POSZ", "EK3_SRC2_VELZ", "EK3_SRC2_YAW",
                      "EK3_SRC3_POSXY", "EK3_SRC3_VELXY", "EK3_SRC3_POSZ", "EK3_SRC3_VELZ", "EK3_SRC3_YAW", "EK3_SRC_OPTIONS"]
    static let ekfQuality = ["EK3_GPS_CHECK", "EK3_GPS_VACC_MAX", "EK3_POSNE_M_NSE", "EK3_VELNE_M_NSE", "EK3_VELD_M_NSE", "EK3_ALT_M_NSE", "EK3_POS_I_GATE", "EK3_VEL_I_GATE", "EK3_HGT_I_GATE", "EK3_GLITCH_RAD", "EK3_GPS_TYPE"]
    static let fs = ["FS_EKF_ACTION", "FS_EKF_THRESH", "FS_GCS_ENABLE", "FS_GCS_ENABL", "FS_GCS_TIMEOUT", "EK3_CHECK_SCALE"]
    static let wpnav = ["WPNAV_SPEED", "WPNAV_SPEED_UP", "WPNAV_SPEED_DN", "WPNAV_ACCEL", "WPNAV_ACCEL_Z", "WPNAV_JERK", "WPNAV_RADIUS", "WPNAV_TER_MARGIN", "WP_YAW_BEHAVIOR", "WP_NAVALT_MIN"]
    static let psc = ["PSC_POSXY_P", "PSC_NE_POS_P", "PSC_VELXY_P", "PSC_NE_VEL_P", "PSC_VELXY_I", "PSC_NE_VEL_I", "PSC_VELXY_D", "PSC_NE_VEL_D", "PSC_POSZ_P", "PSC_D_POS_P", "PSC_VELZ_P", "PSC_D_VEL_P", "PSC_ACCZ_P", "PSC_D_ACC_P"]

    /// Короткий опис поточних джерел навігації EKF.
    var sourcesSummary: String {
        func label(_ n: String) -> String? { ps.val(n).flatMap { v in ps.options(n).first { $0.0 == Int(v) }?.1 } }
        let parts = [("позиція", "EK3_SRC1_POSXY"), ("швидкість", "EK3_SRC1_VELXY"), ("висота", "EK3_SRC1_POSZ"), ("курс", "EK3_SRC1_YAW")].compactMap { t in label(t.1).map { "\(t.0): \($0)" } }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        ConfigGate {
            liveCard
            PageTitle(title: String(localized: "Основні налаштування"), subtitle: String(localized: "Приймач, його використання в навігації та джерела даних для фільтра положення."))
            StepTitle(n: 1, title: String(localized: "GPS-приймач"))
            ParamsCard(title: String(localized: "Приймач"), icon: "location.fill", text: String(localized: "Тип приймача, системи супутників і частота оновлення."), params: ["GPS1_TYPE", "GPS_TYPE", "GPS1_GNSS_MODE", "GPS_GNSS_MODE", "GPS1_RATE_MS", "GPS_RATE_MS"])
            StepTitle(n: 2, title: String(localized: "Використання GPS"))
            ParamsCard(title: String(localized: "GPS у навігації"), icon: "scope", text: String(localized: "Чи користується автопілот GPS і за якої мінімальної кількості супутників."), params: ["AHRS_GPS_USE", "AHRS_GPS_MINSATS", "GPS_AUTO_CONFIG"])
            StepTitle(n: 3, title: String(localized: "Джерела навігації (EKF3, набір 1)"))
            ParamsCard(title: String(localized: "Звідки брати дані"), icon: "point.3.connected.trianglepath.dotted", text: sourcesSummary.isEmpty ? "Звідки фільтр бере позицію, швидкість, висоту й курс." : loc("Зараз: ") + sourcesSummary,
                       params: ["EK3_SRC1_POSXY", "EK3_SRC1_VELXY", "EK3_SRC1_POSZ", "EK3_SRC1_VELZ", "EK3_SRC1_YAW"])

            AdvancedSection(key: "gps.advanced", subtitle: String(localized: "Антена, другий GPS, змішування, перевірки якості, резервні джерела, захист і політ за точками.")) {
                ParamsCard(title: String(localized: "Антена GPS 1"), icon: "antenna.radiowaves.left.and.right", text: String(localized: "Положення антени відносно центру апарата (X вперед, Y вправо, Z вниз) і підключення."),
                           params: ["GPS1_POS_X", "GPS1_POS_Y", "GPS1_POS_Z", "GPS_POS1_X", "GPS_POS1_Y", "GPS_POS1_Z", "GPS1_DELAY_MS", "GPS_DELAY_MS", "GPS1_COM_PORT", "GPS1_CAN_OVRIDE", "GPS1_CAN_NODEID", "GPS1_MB_TYPE", "GPS1_OPT_RNG"])
                ParamsCard(title: "GPS 2", icon: "location", text: String(localized: "Другий приймач (необов'язково)."), params: Self.gps2)
                ParamsCard(title: String(localized: "Вибір і змішування GPS"), icon: "arrow.triangle.merge", params: ["GPS_PRIMARY", "GPS_AUTO_SWITCH", "GPS_BLEND_MASK", "GPS_BLEND_TC"])
                ParamsCard(title: String(localized: "Якість сигналу"), icon: "waveform.path", params: ["GPS_MIN_ELEV", "GPS_NAVFILTER", "GPS_SBAS_MODE", "GPS_HDOP_GOOD", "GPS_HDOP_ON", "GPS_HDOP_OFF", "GPS_NS_ON", "GPS_NS_OFF", "GPS_T_ON", "GPS_T_OFF"])
                ParamsCard(title: String(localized: "Служові параметри приймача"), icon: "gearshape", params: ["GPS_SAVE_CFG", "GPS_RAW_DATA", "GPS_DRV_OPTIONS", "GPS_INJECT_TO", "GPS_SBP_LOGMASK"])
                ParamsCard(title: String(localized: "AHRS і фільтр положення"), icon: "safari", params: ["AHRS_GPS_GAIN", "AHRS_EKF_TYPE", "AHRS_WIND_MAX", "EK3_ENABLE", "EK2_ENABLE", "EK3_SRC_OPTIONS"])
                ParamsCard(title: String(localized: "Резервні набори джерел (SRC2, SRC3)"), icon: "square.stack.3d.up", text: String(localized: "Для перемикання джерел навігації в польоті (функція каналу пульта)."),
                           params: ["EK3_SRC2_POSXY", "EK3_SRC2_VELXY", "EK3_SRC2_POSZ", "EK3_SRC2_VELZ", "EK3_SRC2_YAW", "EK3_SRC3_POSXY", "EK3_SRC3_VELXY", "EK3_SRC3_POSZ", "EK3_SRC3_VELZ", "EK3_SRC3_YAW"])
                ParamsCard(title: String(localized: "Перевірки й шуми EKF3"), icon: "checkmark.shield", text: String(localized: "Тонке налаштування довіри до GPS і барометра. Змінюйте обережно."), params: Self.ekfQuality)
                ParamsCard(title: String(localized: "Захист навігації (failsafe)"), icon: "exclamationmark.shield", params: Self.fs)
                ParamsCard(title: String(localized: "Політ за точками"), icon: "point.topleft.down.to.point.bottomright.curvepath", params: Self.wpnav)
                ParamsCard(title: String(localized: "Контролер позиції"), icon: "slider.horizontal.3", text: String(localized: "Коефіцієнти утримання позиції й швидкості. Змінюйте обережно."), params: Self.psc)
                let known = Set(Self.gps1 + Self.gps2 + Self.general + ["GPS_BLEND_TC", "GPS_HDOP_GOOD"])
                ParamsCard(title: String(localized: "Інші параметри GPS"), icon: "ellipsis.circle", params: paramNames(ps, prefix: "GPS", excluding: known))
            }
            RebootRow()
        }
    }

    var liveCard: some View {
        let t = s.t
        let fix = ["Немає GPS", "Немає фіксації", "2D", "3D", "DGPS", "RTK float", "RTK fixed"][min(max(t.gpsFix, 0), 6)]
        return Card(title: String(localized: "Стан GPS"), icon: "satellite", text: nil) {
            HStack(spacing: 24) {
                stat("Фіксація", fix, t.gpsFix >= 3 ? .green : .orange)
                stat("Супутники", "\(t.sats)", t.sats >= 10 ? .green : (t.sats >= 6 ? .orange : .red))
                stat("HDOP", t.hdop > 99 ? "—" : String(format: "%.2f", t.hdop), t.hdop > 0 && t.hdop < 1.5 ? .green : .orange)
                stat("Висота MSL", String(format: loc("%.1f м"), t.altMsl), .primary)
                stat("Швидкість", String(format: loc("%.1f м/с"), t.groundSpeed), .primary)
                if t.gpsFix >= 2 { stat("Координати", String(format: "%.6f, %.6f", t.lat, t.lon), .primary) }
                Spacer()
            }
        }
    }
    func stat(_ title: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(LocalizedStringKey(title)).font(.caption).foregroundStyle(.secondary)
            Text(LocalizedStringKey(value)).font(.system(.title3, design: .rounded).weight(.semibold)).foregroundStyle(color).monospacedDigit()
        }
    }
}

// MARK: - Датчик повітряної швидкості

struct AirspeedView: View {
    @Environment(Store.self) var s
    @State private var note: String?
    var ps: ParamStore { s.ps }

    static let sensor1 = ["ARSPD_TYPE", "ARSPD_ENABLE", "ARSPD_USE", "ARSPD_PRIMARY", "ARSPD_PIN", "ARSPD_BUS", "ARSPD_DEVID", "ARSPD_AUTOCAL", "ARSPD_RATIO", "ARSPD_OFFSET", "ARSPD_OFF_PCNT",
                          "ARSPD_PSI_RANGE", "ARSPD_SKIP_CAL", "ARSPD_TUBE_ORDR", "ARSPD_TUBE_ORDER"]
    static let sensor2 = ["ARSPD2_TYPE", "ARSPD2_USE", "ARSPD2_PIN", "ARSPD2_BUS", "ARSPD2_DEVID", "ARSPD2_AUTOCAL", "ARSPD2_RATIO", "ARSPD2_OFFSET", "ARSPD2_PSI_RANGE", "ARSPD2_SKIP_CAL", "ARSPD2_TUBE_ORDR"]
    static let safety = ["ARSPD_WIND_MAX", "ARSPD_WIND_WARN", "ARSPD_WIND_GATE", "ARSPD_OPTIONS", "ARSPD_FBW_MIN", "ARSPD_FBW_MAX", "AIRSPEED_MIN", "AIRSPEED_MAX", "AIRSPEED_CRUISE", "TRIM_ARSPD_CM"]

    /// Спосіб підключення за назвою типу датчика з метаданих.
    var connection: (String, String, [String])? {
        guard let v = ps.val("ARSPD_TYPE"), Int(v) != 0 else { return nil }
        let label = (ps.options("ARSPD_TYPE").first { $0.0 == Int(v) }?.1 ?? "").lowercased()
        if label.contains("analog") { return ("Аналоговий вхід (АЦП)", "waveform.path", ["ARSPD_PIN"]) }
        if label.contains("i2c") { return ("Шина I²C", "cpu", ["ARSPD_BUS"]) }
        if label.contains("dronecan") || label.contains("uavcan") { return ("DroneCAN", "point.3.connected.trianglepath.dotted", []) }
        if label.contains("msp") { return ("MSP (послідовний порт)", "cable.connector", []) }
        return ("Інше підключення", "questionmark.circle", ["ARSPD_PIN", "ARSPD_BUS"])
    }

    var body: some View {
        let any = ps.params.contains { $0.name.hasPrefix("ARSPD") }
        ConfigGate {
            liveCard
            if !any {
                Card(title: String(localized: "Датчик повітряної швидкості недоступний"), icon: "nosign", text: String(localized: "У прошивці немає параметрів ARSPD_*. Їх надають збірки з підтримкою датчика повітряної швидкості (літаки, VTOL).")) { EmptyView() }
            } else {
                PageTitle(title: String(localized: "Основні налаштування"), subtitle: String(localized: "Оберіть датчик, вкажіть де він підключений і чи використовувати його в польоті."))
                StepTitle(n: 1, title: String(localized: "Датчик і підключення"))
                Card(title: String(localized: "Тип датчика"), icon: "wind", text: String(localized: "Модель трубки Піто й спосіб підключення до плати.")) {
                    VStack(spacing: 0) { AdvParamRow(name: "ARSPD_TYPE", describe: true) }
                    if let c = connection {
                        HStack(spacing: 8) { Label(LocalizedStringKey(c.0), systemImage: c.1).font(.callout).foregroundStyle(.secondary); Spacer() }
                        ForEach(c.2.filter { ps.has($0) }, id: \.self) { Divider().opacity(0.4); AdvParamRow(name: $0, describe: true) }
                        if c.0 == "DroneCAN" { Text("Датчик на вузлі DroneCAN: додаткових налаштувань тут немає, переконайтеся, що CAN-порт увімкнено.").font(.caption).foregroundStyle(.secondary) }
                    } else if ps.has("ARSPD_TYPE") {
                        Label("Тип None: датчик вимкнено. Оберіть модель, щоб почати.", systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                    }
                }
                StepTitle(n: 2, title: String(localized: "Використання в польоті"))
                ParamsCard(title: String(localized: "Поведінка"), icon: "slider.horizontal.3", text: String(localized: "Чи враховувати швидкість у керуванні та чи дозволити автопілоту уточнювати коефіцієнт."), params: ["ARSPD_USE", "ARSPD_ENABLE", "ARSPD_AUTOCAL"])
                StepTitle(n: 3, title: String(localized: "Калібрування"))
                ParamsCard(title: String(localized: "Коефіцієнти"), icon: "scope", text: String(localized: "Нуль калібрується кнопкою нагорі, коефіцієнт зазвичай не чіпають: його уточнює автокалібрування в польоті."), params: ["ARSPD_OFFSET", "ARSPD_RATIO"])

                AdvancedSection(key: "airspeed.advanced", subtitle: String(localized: "Другий датчик, тонкі параметри, захист від розбіжності швидкостей та інше.")) {
                    ParamsCard(title: String(localized: "Тонкі параметри датчика"), icon: "gearshape", params: ["ARSPD_PRIMARY", "ARSPD_PSI_RANGE", "ARSPD_TUBE_ORDR", "ARSPD_TUBE_ORDER", "ARSPD_OFF_PCNT", "ARSPD_SKIP_CAL", "ARSPD_DEVID"])
                    ParamsCard(title: String(localized: "Захист від розбіжності швидкостей"), icon: "exclamationmark.shield", text: String(localized: "Порівняння швидкості датчика з оцінкою за GPS і вітром виявляє засмічену трубку Піто."), params: ["ARSPD_WIND_MAX", "ARSPD_WIND_WARN", "ARSPD_WIND_GATE", "ARSPD_OPTIONS"])
                    ParamsCard(title: String(localized: "Датчик 2"), icon: "wind", text: String(localized: "Другий датчик (необов'язково)."), params: Self.sensor2)
                    ParamsCard(title: String(localized: "Польотні швидкості"), icon: "speedometer", params: ["AIRSPEED_MIN", "AIRSPEED_MAX", "AIRSPEED_CRUISE", "TRIM_ARSPD_CM", "ARSPD_FBW_MIN", "ARSPD_FBW_MAX"])
                    let known = Set(Self.sensor1 + Self.sensor2 + Self.safety)
                    ParamsCard(title: String(localized: "Інші параметри ARSPD"), icon: "ellipsis.circle", params: paramNames(ps, prefix: "ARSPD", excluding: known))
                }
                RebootRow(text: String(localized: "Тип датчика, шина та пін застосовуються після перезавантаження автопілота."))
            }
        }
    }

    var liveCard: some View {
        Card(title: String(localized: "Повітряна швидкість"), icon: "speedometer", text: String(localized: "Показник має бути близьким до нуля при нерухомому датчику. Перед калібруванням закрийте трубку Піто від вітру.")) {
            HStack(alignment: .center, spacing: 30) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("AirSpeed").font(.caption).foregroundStyle(.secondary)
                    Text(String(format: loc("%.1f м/с"), s.t.airSpeed)).font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(.cyan)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Наземна").font(.caption).foregroundStyle(.secondary)
                    Text(String(format: loc("%.1f м/с"), s.t.groundSpeed)).font(.system(size: 24, weight: .medium, design: .rounded)).monospacedDigit()
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    Button { EngineAPI.post("/cal/baro") { ok, e in note = ok ? "Калібрування нуля виконано (бародатчик і датчик швидкості)" : (e == "armed" ? "ARMED: недоступно" : "Помилка") } } label: { Label("Калібрувати нуль датчика", systemImage: "scope") }.disabled(s.armed)
                    if let n = note { Text(LocalizedStringKey(n)).font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
    }
}

// MARK: - Спеціальні конфігурації (перемикачі наборів параметрів)

struct PresetParam: Identifiable {
    let names: [String]          // варіанти імені (для різних версій прошивки)
    let on: Double
    let off: Double              // типове значення при вимкненні, якщо немає збереженої копії
    let note: String
    var id: String { names[0] }
}

/// Оптична одометрія: позиціонування без GPS за зовнішнім джерелом (VISION_POSITION_ESTIMATE / ODOMETRY по MAVLink).
enum OpticalOdometryPreset {
    static func params(hasCompass: Bool) -> [PresetParam] {
        [
            PresetParam(names: ["GPS1_TYPE", "GPS_TYPE"], on: 0, off: 1, note: "GPS вимкнено"),
            PresetParam(names: ["AHRS_GPS_USE"], on: 0, off: 1, note: "AHRS не використовує GPS"),
            PresetParam(names: ["AHRS_GPS_GAIN"], on: 0, off: 1, note: "Вплив GPS на AHRS = 0"),
            PresetParam(names: ["FS_GCS_ENABLE", "FS_GCS_ENABL"], on: 0, off: 0, note: "Failsafe втрати зв'язку з GCS вимкнено"),
            PresetParam(names: ["VISO_TYPE"], on: 1, off: 0, note: "Візуальна одометрія: MAVLink"),
            PresetParam(names: ["EK3_SRC1_POSXY"], on: 6, off: 3, note: "Позиція XY: ExternalNav"),
            PresetParam(names: ["EK3_SRC1_POSZ"], on: 1, off: 1, note: "Висота: барометр"),
            PresetParam(names: ["EK3_SRC1_VELXY"], on: 6, off: 3, note: "Швидкість XY: ExternalNav"),
            PresetParam(names: ["EK3_SRC1_VELZ"], on: 0, off: 3, note: "Вертикальна швидкість: None"),
            PresetParam(names: ["EK3_SRC1_YAW"], on: hasCompass ? 1 : 6, off: 1, note: hasCompass ? "Курс: компас" : "Курс: ExternalNav"),
            PresetParam(names: ["COMPASS_ENABLE"], on: hasCompass ? 1 : 0, off: 1, note: hasCompass ? "Компас увімкнено" : "Компас вимкнено"),
        ]
    }
}

struct FeaturesView: View {
    @Environment(Store.self) var s
    @AppStorage("preset.viso.compass") private var compassMode = "auto"      // auto | yes | no
    @AppStorage("preset.viso.snapshot") private var snapshotJSON = ""
    @State private var note: String?
    var ps: ParamStore { s.ps }

    var detectedCompass: Bool { !compasses(ps).isEmpty }
    var hasCompass: Bool { compassMode == "yes" ? true : (compassMode == "no" ? false : detectedCompass) }
    func name(_ p: PresetParam) -> String? { p.names.first { ps.has($0) } }
    var items: [PresetParam] { OpticalOdometryPreset.params(hasCompass: hasCompass) }
    var applicable: [PresetParam] { items.filter { name($0) != nil } }
    var missing: [PresetParam] { items.filter { name($0) == nil } }
    var isOn: Bool { !applicable.isEmpty && applicable.allSatisfy { name($0).flatMap { ps.val($0) } == $0.on } }
    var snapshot: [String: Double] {
        guard let d = snapshotJSON.data(using: .utf8), let m = try? JSONDecoder().decode([String: Double].self, from: d) else { return [:] }
        return m
    }

    var body: some View {
        ConfigGate {
            Card(title: String(localized: "Спеціальні конфігурації"), icon: "switch.2", text: String(localized: "Швидке вмикання й вимикання наборів параметрів. Перед увімкненням поточні значення зберігаються, щоб їх можна було відновити при вимкненні.")) { EmptyView() }
            opticalCard
            quickTuneCards
            RebootRow(text: String(localized: "Після зміни набору параметрів перезавантажте автопілот."))
        }
    }

    static let quickParams = ["QUIK_ENABLE", "QUIK_AXES", "QUIK_RC_FUNC", "QUIK_OPTIONS", "QUIK_AUTO_SAVE", "QUIK_DOUBLE_TIME", "QUIK_GAIN_MARGIN", "QUIK_MAX_REDUCE", "QUIK_OSC_SMAX", "QUIK_ANGLE_MAX", "QUIK_RP_PI_RATIO", "QUIK_Y_PI_RATIO", "QUIK_YAW_P_MAX", "QUIK_YAW_D_MAX", "QUIK_AUTO_FILTER"]

    /// Quick tune (скрипт VTOL-quicktune.lua): параметри з'являються, лише коли скрипт є в прошивці й увімкнений (SCR_ENABLE) .
    @ViewBuilder var quickTuneCards: some View {
        if Self.quickParams.contains(where: { ps.has($0) }) {
            ParamsCard(title: String(localized: "Quick tune"), icon: "dial.medium", text: String(localized: "Автоматичне налаштування PID скриптом VTOL-quicktune.lua: вмикається перемикачем на пульті (RCn_OPTION = QUIK_RC_FUNC, типово 300), перемикайте положення й тримайте апарат у повітрі, поки налаштування триває. Робіть це лише в безпечних умовах."), params: Self.quickParams)
        } else if ps.has("SCR_ENABLE") {
            Card(title: String(localized: "Quick tune"), icon: "dial.medium", text: String(localized: "Параметрів Quick tune (QUIK_*) немає на польотнику. Вони з'являються, коли скрипт VTOL-quicktune.lua лежить у папці скриптів на SD-картці і скриптинг увімкнено (SCR_ENABLE = 1); після цього перезавантажте автопілот.")) { EmptyView() }
        }
    }

    var opticalCard: some View {
        Card(title: String(localized: "Оптична одометрія"), icon: "viewfinder", text: String(localized: "Навігація без GPS за зовнішньою системою позиціонування (камера або трекер), що передає дані по MAVLink. EKF3 бере позицію й швидкість з ExternalNav.")) {
            HStack(spacing: 16) {
                Toggle(isOn: Binding(get: { isOn }, set: { $0 ? enable() : disable() })) {
                    Text(lk(isOn ? "Увімкнено" : "Вимкнено")).font(.headline)
                }.toggleStyle(.switch).disabled(s.armed)
                Spacer()
                Picker("Компас", selection: $compassMode) {
                    Text("Автоматично (\(detectedCompass ? "є" : "немає"))").tag("auto")
                    Text("Є компас").tag("yes")
                    Text("Немає компаса").tag("no")
                }.frame(width: 260)
            }
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                GridRow {
                    ForEach(["Параметр", "Зараз", "У режимі одометрії", "Опис", ""], id: \.self) { Text(lk($0)).font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
                }
                Divider().gridCellColumns(5)
                ForEach(items) { p in
                    let n = name(p)
                    let cur = n.flatMap { ps.val($0) }
                    GridRow {
                        Text(lk(n ?? p.names[0])).font(.system(.callout, design: .monospaced)).foregroundStyle(n == nil ? .secondary : .primary)
                        Text(lk(cur.map { fmt($0, isInt: true) } ?? "—")).font(.system(.callout, design: .monospaced))
                        Text(lk(fmt(p.on, isInt: true))).font(.system(.callout, design: .monospaced)).foregroundStyle(.blue)
                        Text(LocalizedStringKey(p.note)).font(.callout).foregroundStyle(.secondary)
                        if n == nil { Text("немає в прошивці").font(.caption).foregroundStyle(.orange) }
                        else { Image(systemName: cur == p.on ? "checkmark.circle.fill" : "circle").foregroundStyle(cur == p.on ? .green : .secondary) }
                    }
                }
            }
            if !missing.isEmpty { Text("Параметри, яких немає в прошивці, пропускаються.").font(.caption).foregroundStyle(.secondary) }
            HStack {
                if !snapshot.isEmpty { Label("Є збережена копія попередніх значень (\(snapshot.count))", systemImage: "clock.arrow.circlepath").font(.caption).foregroundStyle(.secondary) }
                Spacer()
            }
            if let n = note { Label(LocalizedStringKey(n), systemImage: "info.circle.fill").font(.callout).foregroundStyle(.orange) }
        }
    }

    func enable() {
        guard !s.armed else { return }
        if !isOn {      // зберігаємо поточні значення лише якщо набір ще не застосований
            var snap: [String: Double] = [:]
            for p in applicable { if let n = name(p), let v = ps.val(n) { snap[n] = v } }
            if let d = try? JSONEncoder().encode(snap), let str = String(data: d, encoding: .utf8) { snapshotJSON = str }
        }
        for p in applicable { if let n = name(p) { ps.write(n, p.on) } }
        note = String(localized: "Оптичну одометрію ввімкнено. Перезавантажте автопілот, щоб застосувати.")
    }

    func disable() {
        guard !s.armed else { return }
        let snap = snapshot
        for p in applicable {
            guard let n = name(p) else { continue }
            ps.write(n, snap[n] ?? p.off)
        }
        snapshotJSON = ""
        note = (snap.isEmpty ? "Оптичну одометрію вимкнено: встановлено типові значення. " : "Оптичну одометрію вимкнено: відновлено збережені значення. ") + loc("Перезавантажте автопілот.")
    }
}
