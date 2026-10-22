import SwiftUI

/// Рядок налаштування параметра: підпис з метаданих + елемент керування (перелік або число з одиницями).
struct ParamEditRow: View {
    @Environment(Store.self) var s
    let name: String
    var title: String? = nil
    var body: some View {
        let ps = s.ps
        if ps.has(name) {
            let meta = ps.meta[name]
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(lk(title ?? meta?.label ?? name)).font(.callout)
                    Text(LocalizedStringKey(name)).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if meta?.values?.isEmpty == false {
                    OptionPicker(name: name, width: 240)
                } else {
                    ParamField(name: name, width: 90)
                    Text(lk(meta?.units ?? "")).font(.caption).foregroundStyle(.secondary).frame(width: 40, alignment: .leading)
                }
            }
            .padding(.vertical, 3)
            Divider().opacity(0.4)
        }
    }
}

/// FailSafe: батарея, радіо, GCS, EKF, краш, вібрація, геозона.
struct FailSafeView: View {
    @Environment(Store.self) var s
    var ps: ParamStore { s.ps }

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
                    HStack(alignment: .top, spacing: 16) {
                        VStack(spacing: 14) { battery; radio }
                        VStack(spacing: 14) { gcs; ekf; fence }
                    }
                }
            }
            .padding()
        }
    }

    var battery: some View {
        Card(title: String(localized: "Батарея"), icon: "battery.50", text: String(localized: "Дія при низькому й критичному заряді.")) {
            ParamEditRow(name: "BATT_LOW_VOLT"); ParamEditRow(name: "BATT_LOW_MAH"); ParamEditRow(name: "BATT_FS_LOW_ACT")
            ParamEditRow(name: "BATT_CRT_VOLT"); ParamEditRow(name: "BATT_CRT_MAH"); ParamEditRow(name: "BATT_FS_CRT_ACT")
            ParamEditRow(name: "BATT_LOW_TIMER"); ParamEditRow(name: "BATT_FS_VOLTSRC")
        }
    }

    var radio: some View {
        Card(title: String(localized: "Радіо (газ)"), icon: "antenna.radiowaves.left.and.right", text: String(localized: "Втрата сигналу приймача.")) {
            ParamEditRow(name: "FS_THR_ENABLE"); ParamEditRow(name: "FS_THR_VALUE")
            ParamEditRow(name: "FS_OPTIONS")
        }
    }

    var gcs: some View {
        Card(title: String(localized: "Наземна станція (GCS)"), icon: "laptopcomputer", text: String(localized: "Втрата зв'язку з GCS.")) {
            ParamEditRow(name: "FS_GCS_ENABLE"); ParamEditRow(name: "FS_GCS_TIMEOUT")
        }
    }

    var ekf: some View {
        Card(title: String(localized: "EKF, краш, вібрація"), icon: "waveform.path.ecg", text: nil) {
            ParamEditRow(name: "FS_EKF_ACTION"); ParamEditRow(name: "FS_EKF_THRESH"); ParamEditRow(name: "FS_EKF_FILT")
            ParamEditRow(name: "FS_CRASH_CHECK"); ParamEditRow(name: "FS_VIBE_ENABLE")
            ParamEditRow(name: "FS_DR_ENABLE"); ParamEditRow(name: "FS_DR_TIMEOUT")
        }
    }

    var fence: some View {
        Card(title: String(localized: "Геозона"), icon: "square.dashed", text: nil) {
            ParamEditRow(name: "FENCE_ENABLE"); ParamEditRow(name: "FENCE_TYPE"); ParamEditRow(name: "FENCE_ACTION")
            ParamEditRow(name: "FENCE_ALT_MAX"); ParamEditRow(name: "FENCE_ALT_MIN"); ParamEditRow(name: "FENCE_RADIUS"); ParamEditRow(name: "FENCE_MARGIN")
        }
    }
}
