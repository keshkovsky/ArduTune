import SwiftUI

/// Розширені параметри ArduCopter для кожного режиму польоту. Показуються лише ті параметри, що є в прошивці.
struct ModeGroup { let title: String; let params: [String] }
struct ModeInfo { let icon: String; let note: String; let groups: [ModeGroup] }

enum ModeSettings {
    static let wpnav = ModeGroup(title: String(localized: "Швидкості польоту за точками"), params: ["WPNAV_SPEED", "WPNAV_SPEED_UP", "WPNAV_SPEED_DN", "WPNAV_ACCEL", "WPNAV_ACCEL_Z", "WPNAV_JERK", "WPNAV_RADIUS"])
    static let land = ModeGroup(title: String(localized: "Посадка"), params: ["LAND_SPEED", "LAND_SPEED_HIGH", "LAND_ALT_LOW", "LAND_REPOSITION"])
    static let pilotZ = ModeGroup(title: String(localized: "Вертикаль під керуванням пілота"), params: ["PILOT_SPEED_UP", "PILOT_SPEED_DN", "PILOT_ACCEL_Z", "PILOT_THR_BHV", "THR_DZ"])
    static let yaw = ModeGroup(title: String(localized: "Рискання (Yaw)"), params: ["PILOT_Y_RATE", "PILOT_Y_EXPO"])
    static let rtl = [
        ModeGroup(title: String(localized: "Висота повернення"), params: ["RTL_ALT", "RTL_ALT_FINAL", "RTL_CLIMB_MIN", "RTL_CONE_SLOPE"]),
        ModeGroup(title: String(localized: "Швидкість і поведінка"), params: ["RTL_SPEED", "RTL_LOIT_TIME", "RTL_OPTIONS"]),
        land,
    ]

    static let info: [Int: ModeInfo] = [
        0: ModeInfo(icon: "hand.raised", note: "Ручне керування кутом нахилу. Автоматично тримає горизонт, висоту тримає пілот газом.", groups: [
            ModeGroup(title: String(localized: "Кути"), params: ["ANGLE_MAX", "ATC_ANG_RLL_P", "ATC_ANG_PIT_P", "ATC_ANG_YAW_P", "ATC_INPUT_TC"]),
            yaw,
            ModeGroup(title: String(localized: "Газ"), params: ["PILOT_THR_FILT", "PILOT_THR_BHV"]),
        ]),
        1: ModeInfo(icon: "arrow.triangle.2.circlepath", note: "Керування кутовою швидкістю без самовирівнювання (для просунутих пілотів).", groups: [
            ModeGroup(title: String(localized: "Швидкості обертання"), params: ["ACRO_RP_RATE", "ACRO_Y_RATE", "ACRO_RP_RATE_TC", "ACRO_Y_RATE_TC", "ACRO_RP_P", "ACRO_YAW_P"]),
            ModeGroup(title: String(localized: "Експоненти"), params: ["ACRO_RP_EXPO", "ACRO_Y_EXPO"]),
            ModeGroup(title: String(localized: "Баланс і тренер"), params: ["ACRO_BAL_ROLL", "ACRO_BAL_PITCH", "ACRO_TRAINER"]),
            ModeGroup(title: String(localized: "Газ і опції"), params: ["ACRO_THR_MID", "ACRO_OPTIONS"]),
        ]),
        2: ModeInfo(icon: "arrow.up.and.down", note: "Тримає висоту, кут нахилу задає пілот.", groups: [
            pilotZ,
            ModeGroup(title: String(localized: "Кути й рискання"), params: ["ANGLE_MAX", "PILOT_Y_RATE", "PILOT_Y_EXPO"]),
            ModeGroup(title: String(localized: "Зліт"), params: ["PILOT_TKOFF_ALT"]),
        ]),
        3: ModeInfo(icon: "point.topleft.down.to.point.bottomright.curvepath", note: "Виконує місію із Mission Planner.", groups: [
            wpnav,
            ModeGroup(title: String(localized: "Поведінка"), params: ["WP_YAW_BEHAVIOR", "AUTO_OPTIONS", "MIS_RESTART", "MIS_OPTIONS", "WP_NAVALT_MIN"]),
            land,
        ]),
        4: ModeInfo(icon: "location.viewfinder", note: "Керування з наземної станції: Fly To, зліт, ROI.", groups: [
            ModeGroup(title: "Guided", params: ["GUID_OPTIONS", "GUID_TIMEOUT"]),
            wpnav,
        ]),
        5: ModeInfo(icon: "scope", note: "Тримає позицію за GPS; пілот рухає апарат стіками.", groups: [
            ModeGroup(title: String(localized: "Швидкість і гальмування"), params: ["LOIT_SPEED", "LOIT_ACC_MAX", "LOIT_BRK_ACCEL", "LOIT_BRK_JERK", "LOIT_BRK_DELAY", "LOIT_ANG_MAX"]),
            pilotZ,
        ]),
        6: ModeInfo(icon: "house", note: "Повертається додому, піднімається на безпечну висоту й сідає.", groups: rtl),
        7: ModeInfo(icon: "circle.dashed", note: "Кружляє навколо точки перед апаратом, носом до центру.", groups: [
            ModeGroup(title: String(localized: "Коло"), params: ["CIRCLE_RADIUS", "CIRCLE_RATE", "CIRCLE_OPTIONS"]),
        ]),
        9: ModeInfo(icon: "arrow.down.to.line", note: "Автоматична посадка.", groups: [land]),
        11: ModeInfo(icon: "wind", note: "Ковзання як у літака: крен керує розворотом, тангаж швидкістю.", groups: [
            ModeGroup(title: "Drift", params: ["DRIFT_SPEEDGAIN", "DRIFT_SPEEDLIMIT", "DRIFT_THR"]),
            yaw,
        ]),
        13: ModeInfo(icon: "bolt", note: "Як Stabilize/Acro: швидке керування з висотою за пілотом.", groups: [
            ModeGroup(title: String(localized: "Швидкості"), params: ["ACRO_RP_RATE", "ACRO_Y_RATE", "ACRO_RP_EXPO", "ACRO_Y_EXPO"]),
            pilotZ,
        ]),
        14: ModeInfo(icon: "arrow.2.circlepath", note: "Автоматичний фліп. Окремих параметрів немає; швидкість обертання задають ATC-параметри.", groups: [
            ModeGroup(title: String(localized: "Кути"), params: ["ANGLE_MAX"]),
        ]),
        15: ModeInfo(icon: "tuningfork", note: "Автоматичне налаштування PID. Виконуйте в безвітряну погоду над відкритим майданчиком.", groups: [
            ModeGroup(title: "AutoTune", params: ["AUTOTUNE_AXES", "AUTOTUNE_AGGR", "AUTOTUNE_MIN_D", "AUTOTUNE_GMBK"]),
        ]),
        16: ModeInfo(icon: "mappin.and.ellipse", note: "Як Loiter, але стіки напряму керують кутом, а гальмування автоматичне.", groups: [
            ModeGroup(title: "PosHold", params: ["PHLD_BRAKE_RATE", "PHLD_BRAKE_ANGLE"]),
            pilotZ,
        ]),
        17: ModeInfo(icon: "hand.raised.slash", note: "Різко зупиняє апарат і тримає позицію. Налаштовується контролером позиції.", groups: [
            ModeGroup(title: String(localized: "Контролер позиції"), params: ["PSC_POSXY_P", "PSC_VELXY_P", "PSC_VELXY_I", "PSC_VELXY_D", "PSC_NE_POS_P", "PSC_NE_VEL_P", "PSC_NE_VEL_I", "PSC_NE_VEL_D"]),
        ]),
        18: ModeInfo(icon: "arrow.up.right", note: "Запуск кидком: після кидка мотори вмикаються й апарат стабілізується.", groups: [
            ModeGroup(title: "Throw", params: ["THROW_TYPE", "THROW_MOT_START", "THROW_NEXTMODE", "THROW_ALT_MIN", "THROW_ALT_MAX"]),
        ]),
        19: ModeInfo(icon: "airplane.arrival", note: "Уникнення літаків за ADS-B.", groups: [
            ModeGroup(title: "ADS-B", params: ["AVD_ENABLE", "AVD_F_ACTION", "AVD_F_DIST_XY", "AVD_F_DIST_Z", "AVD_F_TIME", "AVD_W_ACTION", "AVD_W_DIST_XY", "AVD_W_DIST_Z", "AVD_W_TIME"]),
        ]),
        20: ModeInfo(icon: "location.slash", note: "Guided без GPS: керування кутами й тягою.", groups: [
            ModeGroup(title: "Guided NoGPS", params: ["GUID_OPTIONS", "GUID_TIMEOUT", "ANGLE_MAX"]),
        ]),
        21: ModeInfo(icon: "arrow.uturn.backward", note: "Повертається по пройденому шляху.", groups: [
            ModeGroup(title: "Smart RTL", params: ["SRTL_ACCURACY", "SRTL_POINTS", "SRTL_OPTIONS"]),
            ModeGroup(title: String(localized: "Швидкість"), params: ["RTL_SPEED"]),
            land,
        ]),
        22: ModeInfo(icon: "camera.metering.center.weighted", note: "Тримає позицію за оптичним потоком (потрібен датчик потоку й далекомір).", groups: [
            ModeGroup(title: "FlowHold", params: ["FHLD_XY_P", "FHLD_XY_I", "FHLD_XY_IMAX", "FHLD_FILT_HZ", "FHLD_QUAL_MIN", "FHLD_FLOW_MAX", "FHLD_BRAKE_RATE"]),
            pilotZ,
        ]),
        23: ModeInfo(icon: "figure.walk", note: "Летить за іншим апаратом чи цілью.", groups: [
            ModeGroup(title: String(localized: "Ціль"), params: ["FOLL_ENABLE", "FOLL_SYSID", "FOLL_DIST_MAX"]),
            ModeGroup(title: String(localized: "Позиція відносно цілі"), params: ["FOLL_OFS_TYPE", "FOLL_OFS_X", "FOLL_OFS_Y", "FOLL_OFS_Z", "FOLL_ALT_TYPE", "FOLL_YAW_BEHAVE", "FOLL_POS_P"]),
        ]),
        24: ModeInfo(icon: "rectangle.split.3x1", note: "Прольоти паралельними лініями (обприскування, зйомка).", groups: [
            ModeGroup(title: "ZigZag", params: ["ZIGZAG_SIDE_DIST", "ZIGZAG_LINE_NUM", "ZIGZAG_DIRECTION", "ZIGZAG_WP_DELAY", "ZIGZAG_SPRAYER", "ZIGZAG_AUTO_ENABLE"]),
        ]),
        25: ModeInfo(icon: "waveform.path", note: "Ідентифікація системи: збуджує вісь і записує відгук для аналізу.", groups: [
            ModeGroup(title: "System ID", params: ["SID_AXIS", "SID_MAGNITUDE", "SID_F_START_HZ", "SID_F_STOP_HZ", "SID_T_FADE_IN", "SID_T_REC", "SID_T_FADE_OUT"]),
        ]),
        27: ModeInfo(icon: "house.and.flag", note: "Auto RTL: повернення за місійним маршрутом.", groups: rtl),
    ]
}

/// Один рядок параметра з описом: підпис, код, поле або вибір, одиниці й діапазон.
struct AdvParamRow: View {
    @Environment(Store.self) var s
    let name: String
    var describe = false

    var body: some View {
        let ps = s.ps
        let m = ps.meta[name]
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                let ua = ParamTexts.info(name)
                Text(lk(ua?.title ?? ps.tr[m?.label ?? ""] ?? m?.label ?? name)).font(.callout).lineLimit(2)
                if describe, let d = ua?.text ?? ParamTexts.shortDoc(ps.tr[m?.doc ?? ""] ?? m?.doc) {
                    Text(LocalizedStringKey(d)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).frame(maxWidth: 440, alignment: .leading)
                }
                Text(LocalizedStringKey(name)).font(.system(.caption2, design: .monospaced)).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            if let m, let bits = m.bits, !bits.isEmpty {
                BitsMenu(name: name, bits: bits)
            } else if let m, let v = m.values, !v.isEmpty, v.count <= 30 {
                OptionPicker(name: name, width: 210)
            } else {
                HStack(spacing: 6) {
                    ParamField(name: name, width: 90)
                    Text(lk(m?.units ?? "")).font(.caption).foregroundStyle(.secondary).frame(width: 48, alignment: .leading)
                }
            }
        }
        .padding(.vertical, describe ? 6 : 3)
        .help(lk(helpText(m)))
    }

    func helpText(_ m: ParamMeta?) -> String {
        var t = s.ps.tr[m?.doc ?? ""] ?? m?.doc ?? ""
        if let lo = m?.min, let hi = m?.max { t += (t.isEmpty ? "" : "\n") + String(localized: "Діапазон: \(fmt(lo, isInt: false)) … \(fmt(hi, isInt: false))") }
        if m?.reboot == true { t += "\nПотрібне перезавантаження автопілота." }
        return t
    }
}

/// Бітова маска параметра: меню з прапорцями.
struct BitsMenu: View {
    @Environment(Store.self) var s
    let name: String
    let bits: [[String]]
    var body: some View {
        let cur = Int(s.ps.val(name) ?? 0)
        let n = bits.filter { (cur >> (Int($0[0]) ?? 0)) & 1 == 1 }.count
        Menu {
            ForEach(bits, id: \.self) { kv in
                let b = Int(kv[0]) ?? 0
                Toggle(lk(kv.count > 1 ? kv[1] : String(localized: "біт \(b)")), isOn: Binding(get: { (cur >> b) & 1 == 1 }, set: { _ in s.ps.write(name, Double(cur ^ (1 << b))) }))
            }
        } label: { Text(lk(n == 0 ? "нічого не вибрано" : String(localized: "вибрано: \(n)"))).frame(width: 180, alignment: .leading) }
        .menuStyle(.borderlessButton).disabled(s.armed)
        .padding(.horizontal, 8).padding(.vertical, 3).background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
    }
}

/// Блок «Розширені налаштування режимів» для сторінки Flight Modes.
struct ModeAdvancedCard: View {
    @Environment(Store.self) var s
    let slots: [Int]            // коди режимів у слотах 1…6
    let activeSlot: Int?
    @State private var selected: Int?

    func name(_ code: Int) -> String { s.ps.options("FLTMODE1").first { $0.0 == code }?.1 ?? DFLog.copterMode(code) }
    var unique: [(mode: Int, slots: [Int])] {
        var res: [(Int, [Int])] = []
        for (i, m) in slots.enumerated() {
            if let k = res.firstIndex(where: { $0.0 == m }) { res[k].1.append(i + 1) } else { res.append((m, [i + 1])) }
        }
        return res
    }
    var current: Int { selected.flatMap { sel in unique.contains { $0.mode == sel } ? sel : nil } ?? (activeSlot.map { slots[$0 - 1] } ?? unique.first?.mode ?? 0) }

    /// Поле, список або бітова маска залежно від типу параметра.
    @ViewBuilder func paramControl(_ n: String) -> some View {
        let m = s.ps.meta[n]
        if let m, let bits = m.bits, !bits.isEmpty { BitsMenu(name: n, bits: bits) }
        else if let m, let v = m.values, !v.isEmpty, v.count <= 30, m.min == nil || m.max == nil { OptionPicker(name: n, width: 210) }
        else {
            HStack(spacing: 6) {
                ParamField(name: n, width: 84)
                Text(lk(m?.units ?? "")).font(.caption).foregroundStyle(.secondary).frame(width: 40, alignment: .leading)
            }
        }
    }

    func helpText(_ m: ParamMeta?) -> String {
        var t = s.ps.tr[m?.doc ?? ""] ?? m?.doc ?? ""
        if let lo = m?.min, let hi = m?.max { t += (t.isEmpty ? "" : "\n") + String(localized: "Діапазон: \(fmt(lo, isInt: false)) … \(fmt(hi, isInt: false))") }
        if m?.reboot == true { t += "\nПотрібне перезавантаження автопілота." }
        return t
    }

    /// Опис параметра: назва українською й пояснення; якщо власного тексту немає, переклад опису з метаданих.
    func paramDesc(_ n: String) -> some View {
        let m = s.ps.meta[n]
        let ua = ParamTexts.info(n)
        let title = ua?.title ?? s.ps.tr[m?.label ?? ""] ?? m?.label ?? n
        let text = ua?.text ?? ParamTexts.shortDoc(s.ps.tr[m?.doc ?? ""] ?? m?.doc)
        return VStack(alignment: .leading, spacing: 2) {
            Text(LocalizedStringKey(title)).font(.callout.weight(.medium))
            if let t = text { Text(LocalizedStringKey(t)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(lk(helpText(m)))
    }

    var body: some View {
        let mode = current
        let info = ModeSettings.info[mode]
        Card(title: String(localized: "Розширені налаштування режимів"), icon: "slider.horizontal.3", text: String(localized: "Параметри окремо для кожного обраного режиму. Показано лише те, що є у вашій прошивці; праворуч пояснення українською, а діапазон видно у підказці при наведенні.")) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(unique, id: \.mode) { u in
                        let on = u.mode == mode
                        Button { selected = u.mode } label: {
                            HStack(spacing: 6) {
                                if activeSlot != nil && slots[(activeSlot ?? 1) - 1] == u.mode { Circle().fill(.green).frame(width: 7, height: 7) }
                                Text(lk(name(u.mode))).font(.callout.weight(on ? .semibold : .regular))
                                Text(lk(u.slots.map(String.init).joined(separator: ","))).font(.caption2).foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(on ? Color.accentColor.opacity(0.22) : Color.secondary.opacity(0.1), in: Capsule())
                        }.buttonStyle(.plain)
                    }
                }
            }
            if let info {
                Label(LocalizedStringKey(info.note), systemImage: info.icon).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                let groups = info.groups.map { g in ModeGroup(title: g.title, params: g.params.filter { s.ps.has($0) }) }.filter { !$0.params.isEmpty }
                if groups.isEmpty { Text("Для цього режиму в поточній прошивці немає окремих параметрів.").font(.callout).foregroundStyle(.secondary) }
                ForEach(groups, id: \.title) { g in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(verbatim: loc(g.title).uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 8)
                        // три колонки, як в ESC Calibration: параметр | значення | опис українською
                        Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 10) {
                            ForEach(g.params, id: \.self) { p in
                                GridRow {
                                    Text(LocalizedStringKey(p)).font(.system(.callout, design: .monospaced)).gridColumnAlignment(.leading)
                                    paramControl(p).gridColumnAlignment(.leading)
                                    paramDesc(p)
                                }
                            }
                        }
                    }
                }
            } else {
                Text("Для режиму «\(name(mode))» окремих налаштувань немає.").font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}
