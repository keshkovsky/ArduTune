import SwiftUI
import MapKit

@main
struct ArduTuneApp: App {
    @State private var store = Store()
    @Environment(\.openWindow) private var openWindow
    init() {
        AppLanguage.applyAtLaunch()
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        ReturnCommit.install()
    }
    var body: some Scene {
        WindowGroup("ArduTune") {
            ContentView()
                .environment(store)
                .frame(minWidth: 980, minHeight: 620)
                .onAppear { store.start(); AppSettings.applyTheme(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { AppSettings.applyFullscreen() } }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in store.stop() }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("Про ArduTune") { openWindow(id: "about") }
            }
            CommandGroup(replacing: .help) {
                Button("Про ArduTune і ліцензія") { openWindow(id: "about") }
            }
        }

        WindowGroup("Розділ", id: "page", for: String.self) { $page in
            PageWindow(id: page ?? "Flight").environment(store)
        }
        .defaultSize(width: 1100, height: 760)

        WindowGroup("Вкладка Flight Data", id: "fdtab", for: String.self) { $tab in
            FDTabWindow(raw: tab ?? "Dashboard").environment(store)
        }
        .defaultSize(width: 980, height: 520)

        WindowGroup("Перегляд запису", id: "tlogview", for: String.self) { $path in
            TlogWindow(path: path ?? "").environment(store)
        }
        .defaultSize(width: 1100, height: 740)

        Window("Про ArduTune", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)

        Window("Майстер визначення моторів", id: "motorwizard") {
            MotorWizardWindow().environment(store)
        }
        .windowResizability(.contentSize)

        Window("Тренажер PID", id: "pidgame") {
            ScrollView { PIDGameCard().padding(16) }
                .frame(minWidth: 760, minHeight: 560)
        }
        .defaultSize(width: 860, height: 700)

        Window("Тема HUD", id: "hudtheme") {
            HUDThemeWindow()
        }
        .windowResizability(.contentSize)

        Window("Joystick", id: "joystick") {
            JoystickSheet().environment(store)
        }
        .defaultSize(width: 980, height: 780)

        Window("Video", id: "video") {
            VideoWindow().environment(store)
        }
        .defaultSize(width: 960, height: 600)

        Window("EKF Status", id: "ekf") {
            EKFStatusView().environment(store)
        }
        .windowResizability(.contentSize)

        Window("Vibration", id: "vibration") {
            VibrationView().environment(store)
        }
        .windowResizability(.contentSize)
    }
}

/// Вміст розділу за ідентифікатором: використовується і в головному вікні, і в окремих вікнах розділів.
struct PageView: View {
    let id: String
    var body: some View {
        Group {
            switch id {
            case "Flight": FlightView()
            case "Params": ParamsView()
            case "Accel": CalibrationView()
            case "Compass": CompassView()
            case "Radio": RadioView()
            case "Joystick": ScrollView([.horizontal, .vertical]) { JoystickSheet() }
            case "MAVFtp": MavFtpView()
            case "Modes": FlightModesView()
            case "FailSafe": FailSafeView()
            case "Frame": FrameMotorsView()
            case "Servo": ServoView()
            case "Esc": EscView()
            case "Serial": SerialView()
            case "Battery": BatteryView()
            case "Tune": TuneView()
            case "OSD": OSDView()
            case "Initial": InitialParamsView()
            case "Logs": LogsPage()
            case "Mission": MissionPage()
            case "GPS": GPSNavView()
            case "Airspeed": AirspeedView()
            case "Features": FeaturesView()
            case "Optional": OptionalHardwareView()
            case "DroneCAN": DroneCANView()
            case "ADSB": ADSBView()
            case "HWID": HWIDView()
            case "Firmware": FirmwareView()
            case "Settings": SettingsView()
            default: ContentUnavailableView("Скоро", systemImage: "hammer", description: Text("Цей розділ ще не реалізований"))
            }
        }
    }
}

struct PageWindow: View {
    let id: String
    @Environment(Store.self) var s
    var title: String { id == "Settings" ? "ArduTune" : (ContentView.groups.flatMap(\.items).first { $0.id == id }?.title ?? id) }
    var body: some View {
        VStack(spacing: 0) { ConnectionBanner(); PageView(id: id).frame(maxWidth: .infinity, maxHeight: .infinity) }
            .navigationTitle("ArduTune · " + title)
            .frame(minWidth: 760, minHeight: 520)
    }
}

struct NavItem { let id: String; let title: String; let icon: String }
struct NavGroup { let id: String; let title: String; let icon: String; let items: [NavItem] }

struct ContentView: View {
    @Environment(Store.self) var s
    @Environment(\.openWindow) private var openWindow
    @State private var tab = "Flight"
    @AppStorage("side.compact") private var compact = false
    @AppStorage("side.collapsed") private var collapsedCSV = ""

    /// Порядок за логікою роботи: політ → початкове налаштування → датчики → керування → система.
    static let groups: [NavGroup] = [
        NavGroup(id: "fly", title: String(localized: "Політ"), icon: "paperplane.fill", items: [
            NavItem(id: "Flight", title: "Flight Data", icon: "gauge.with.dots.needle.67percent"),
            NavItem(id: "Mission", title: "Mission", icon: "map"),
            NavItem(id: "Logs", title: "Logs", icon: "doc.text.magnifyingglass"),
        ]),
        NavGroup(id: "setup", title: String(localized: "Налаштування"), icon: "wrench.and.screwdriver.fill", items: [
            NavItem(id: "Initial", title: "Initial Parameters", icon: "wand.and.stars"),
            NavItem(id: "Frame", title: "Frame & Motors", icon: "fanblades"),
            NavItem(id: "Servo", title: "Servo Output", icon: "slider.horizontal.below.rectangle"),
            NavItem(id: "Esc", title: "ESC Calibration", icon: "bolt.fill"),
            NavItem(id: "Serial", title: "Serial Ports", icon: "cable.connector.horizontal"),
            NavItem(id: "Tune", title: "PID & Filters", icon: "dial.medium"),
            NavItem(id: "OSD", title: "OSD", icon: "display"),
            NavItem(id: "Optional", title: "Optional Hardware", icon: "puzzlepiece.extension"),
            NavItem(id: "DroneCAN", title: "DroneCAN", icon: "point.3.filled.connected.trianglepath.dotted"),
        ]),
        NavGroup(id: "sensors", title: String(localized: "Датчики"), icon: "sensor.fill", items: [
            NavItem(id: "Accel", title: "Accel Calibration", icon: "move.3d"),
            NavItem(id: "Compass", title: "Compass", icon: "safari"),
            NavItem(id: "Battery", title: "Battery Monitor", icon: "battery.100"),
            NavItem(id: "GPS", title: "GPS & Navigation", icon: "location.circle"),
            NavItem(id: "Airspeed", title: "Airspeed", icon: "wind"),
            NavItem(id: "ADSB", title: "ADSB", icon: "airplane.circle"),
        ]),
        NavGroup(id: "control", title: String(localized: "Керування"), icon: "gamecontroller.fill", items: [
            NavItem(id: "Radio", title: "Radio Calibration", icon: "dot.radiowaves.left.and.right"),
            NavItem(id: "Modes", title: "Flight Modes", icon: "airplane"),
            NavItem(id: "Joystick", title: "Joystick", icon: "gamecontroller"),
            NavItem(id: "FailSafe", title: "FailSafe", icon: "exclamationmark.shield"),
        ]),
        NavGroup(id: "system", title: String(localized: "Система"), icon: "gearshape.2.fill", items: [
            NavItem(id: "Params", title: "Parameters", icon: "slider.horizontal.3"),
            NavItem(id: "Features", title: "Special", icon: "switch.2"),
            NavItem(id: "HWID", title: "HW ID", icon: "cpu"),
            NavItem(id: "MAVFtp", title: "MAVFtp", icon: "externaldrive"),
            NavItem(id: "Firmware", title: "Install Firmware", icon: "square.and.arrow.down.on.square"),
        ]),
    ]

    var collapsed: Set<String> { Set(collapsedCSV.split(separator: ",").map(String.init)) }
    func toggleGroup(_ id: String) {
        var c = collapsed
        if c.contains(id) { c.remove(id) } else { c.insert(id) }
        collapsedCSV = c.sorted().joined(separator: ",")
    }
    func reveal(_ tabID: String) {
        guard let g = Self.groups.first(where: { $0.items.contains { $0.id == tabID } }), collapsed.contains(g.id) else { return }
        toggleGroup(g.id)
    }

    var body: some View {
        content
            .onChange(of: s.navigate) { _, v in if let v { tab = v; reveal(v); s.navigate = nil } }
    }

    // MARK: Бічна панель
    var sidebar: some View {
        VStack(spacing: 0) {
            HStack {
                if !compact {
                    Button { openWindow(id: "about") } label: { AppWordmark(size: 23).contentShape(Rectangle()) }
                        .buttonStyle(.plain).help("Про ArduTune").padding(.leading, 6)
                }
                Spacer(minLength: 0)
                Button { withAnimation(.snappy(duration: 0.2)) { compact.toggle() } } label: {
                    Image(systemName: compact ? "sidebar.left" : "sidebar.squares.left").font(.system(size: 14))
                        .frame(width: 28, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain).help(lk(compact ? "Розгорнути панель" : "Згорнути до іконок"))
            }
            .padding(.horizontal, compact ? 0 : 8).padding(.top, 8).padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: compact ? .center : .leading)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: compact ? 8 : 9) {
                    ForEach(Self.groups, id: \.id) { g in
                        let isCollapsed = collapsed.contains(g.id)
                        VStack(alignment: .leading, spacing: 1) {
                            if !compact {
                                GroupHeader(title: g.title, icon: g.icon, count: g.items.count, collapsed: isCollapsed, hasSelection: g.items.contains { $0.id == tab }) { toggleGroup(g.id) }
                            }
                            if compact || !isCollapsed {
                                ForEach(g.items, id: \.id) { it in itemButton(it) }
                            }
                        }
                        .padding(compact ? 3 : 4)
                        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5))
                    }
                }
                .padding(.horizontal, compact ? 5 : 8).padding(.top, 2).padding(.bottom, 8)
            }

            // «ArduTune»: налаштування застосунку, у такій самій картці й вигляді пункту, як групи вище
            VStack(spacing: 1) {
                itemButton(NavItem(id: "Settings", title: "ArduTune", icon: "gearshape"))
            }
                .padding(compact ? 3 : 4)
                .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5))
                .padding(.horizontal, compact ? 5 : 8).padding(.top, 2).padding(.bottom, 8)
        }
        .frame(width: compact ? 56 : 224)
        .clipped()
        .animation(.snappy(duration: 0.2), value: compact)
        .background(.regularMaterial)
        .animation(.snappy(duration: 0.2), value: collapsedCSV)
    }

    func itemButton(_ it: NavItem) -> some View {
        let selected = tab == it.id
        return Button { tab = it.id } label: {
            Group {
                if compact { Image(systemName: it.icon).font(.system(size: 15)).frame(maxWidth: .infinity) }
                else {
                    HStack(spacing: 9) {
                        Image(systemName: it.icon).font(.system(size: 13)).frame(width: 18)
                        Text(LocalizedStringKey(it.title)).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                }
            }
            .font(.system(size: 13, weight: .regular))
            .foregroundStyle(selected ? Color.primary : Color.primary.opacity(0.7))
            .padding(.horizontal, compact ? 0 : 8).padding(.vertical, compact ? 8 : 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(selected ? Color.primary.opacity(0.11) : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(lk(it.title))
        .contextMenu {
            Button { openWindow(id: "page", value: it.id) } label: { Label("Відкрити в окремому вікні", systemImage: "macwindow.badge.plus") }
            Button { tab = it.id } label: { Label("Відкрити тут", systemImage: "arrow.right.circle") }
        }
    }

    var content: some View {
        VStack(spacing: 0) {
        ConnectionBanner()
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(spacing: 0) {
                TopBar(full: tab == "Flight" || tab == "Mission")
                PageView(id: tab).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .transaction { $0.animation = nil }     // згортання панелі не повинно «смикати» елементи праворуч (кнопки карти тощо)
        }
        }
    }
}

struct Pill: View {
    let text: String; let tint: Color
    var body: some View {
        Text(LocalizedStringKey(text)).font(.caption.weight(.semibold)).padding(.horizontal, 8).padding(.vertical, 3)
            .background(tint.opacity(0.18), in: Capsule()).foregroundStyle(tint)
    }
}

struct Tile: View {
    let title: String; let value: String
    init(_ t: String, _ v: String) { title = t; value = v }
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(LocalizedStringKey(title)).font(.caption).foregroundStyle(.secondary)
            Text(LocalizedStringKey(value)).font(.title3.monospacedDigit().weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}


/// Заголовок групи: іконка, назва, кількість розділів (у згорнутому стані) і шеврон. Група оформлена як м'яка картка.
struct GroupHeader: View {
    let title: String
    let icon: String
    let count: Int
    let collapsed: Bool
    let hasSelection: Bool
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Color.primary.opacity(0.9))
                    .frame(width: 24, height: 24)
                    .background(Color.primary.opacity(0.14), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
                Text(LocalizedStringKey(title)).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Color.primary).lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 4)
                if collapsed {
                    if hasSelection { Circle().fill(Color.primary.opacity(0.55)).frame(width: 6, height: 6) }
                    Text("\(count)").font(.system(size: 10.5, weight: .medium).monospacedDigit()).foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 1).background(Color.primary.opacity(0.08), in: Capsule())
                }
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary).rotationEffect(.degrees(collapsed ? 0 : 90))
            }
            .padding(.horizontal, 8).padding(.vertical, 7)
            .background(hover ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
