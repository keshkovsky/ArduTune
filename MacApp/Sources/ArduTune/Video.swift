import SwiftUI
import AVFoundation
import AppKit
import Observation

/// Відео: локальні камери (AVFoundation) та GStreamer (gst-launch-1.0 → JPEG-кадри).
@Observable
final class VideoStore: NSObject {
    struct Cam: Identifiable, Hashable { let id: String; let name: String }
    struct Fmt: Identifiable, Hashable { let id: Int; let title: String }
    enum Active { case none, camera, gstreamer }

    static let gstPath = "/Library/Frameworks/GStreamer.framework/Versions/1.0/bin/gst-launch-1.0"
    static var gstAvailable: Bool { FileManager.default.isExecutableFile(atPath: gstPath) }

    static let presets: [(String, String)] = [
        ("Тестове відео", "videotestsrc ! video/x-raw, width=1280, height=720, framerate=30/1"),
        ("UDP H.264 (порт 5600)", "udpsrc port=5600 buffer-size=90000 ! application/x-rtp, payload=96 ! rtph264depay ! h264parse ! avdec_h264"),
        ("UDP H.265 (порт 5600)", "udpsrc port=5600 ! application/x-rtp, encoding-name=H265 ! rtph265depay ! h265parse ! avdec_h265"),
        ("RTSP", "rtspsrc location=rtsp://192.168.0.10:8554/stream latency=0 ! rtph264depay ! h264parse ! avdec_h264"),
        ("Herelink", "rtspsrc location=rtsp://192.168.0.10:8554/fpv_stream latency=0 ! rtph264depay ! h264parse ! avdec_h264"),
        ("Камера через GStreamer", "avfvideosrc device-index=0 ! video/x-raw, width=1280, height=720"),
    ]

    var cameras: [Cam] = []
    var selectedCamera: String? { didSet { loadFormats() } }
    var formats: [Fmt] = []
    var selectedFormat = 0
    var active: Active = .none
    var status = ""
    var frame: NSImage?
    var fps = 0.0
    var showInHUD = false
    var showStats = UserDefaults.standard.bool(forKey: "video.stats") { didSet { UserDefaults.standard.set(showStats, forKey: "video.stats"); updateStatsTimer() } }
    var pingMs: Double?                 // nil: немає відповіді або адреса потоку невідома
    var pingHost: String?
    var frameAge = 0.0                  // секунд від останнього кадру
    var pipeline: String {
        get { StreamSettings.shared.pipeline }
        set { StreamSettings.shared.pipeline = newValue }
    }

    @ObservationIgnored let session = AVCaptureSession()
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var buffer = Data()
    @ObservationIgnored private var frames = 0
    @ObservationIgnored private var fpsStamp = Date()
    @ObservationIgnored private var pending = 0
    // Автоперепідключення GStreamer: якщо кадрів немає або процес завершився, а користувач не зупиняв відео.
    @ObservationIgnored private var wantGst = false
    @ObservationIgnored private var launchedAt = Date()
    @ObservationIgnored private var lastFrameAt = Date()
    @ObservationIgnored private var attempts = 0
    @ObservationIgnored private var gotFrame = false
    @ObservationIgnored private var nextRetry = Date.distantPast
    @ObservationIgnored private var watchdog: Timer?
    @ObservationIgnored private var statsTimer: Timer?
    @ObservationIgnored private var pinging = false

    var running: Bool { active != .none }

    // MARK: Камери
    func refreshCameras() {
        let types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .external, .continuityCamera]
        let devs = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified).devices
        cameras = devs.map { Cam(id: $0.uniqueID, name: $0.localizedName) }
        if selectedCamera == nil || !cameras.contains(where: { $0.id == selectedCamera }) { selectedCamera = cameras.first?.id }
    }

    private func device() -> AVCaptureDevice? { selectedCamera.flatMap { AVCaptureDevice(uniqueID: $0) } }

    func loadFormats() {
        guard let d = device() else { formats = []; return }
        formats = d.formats.enumerated().map { i, f in
            let dim = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            let fps = f.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
            return Fmt(id: i, title: "\(dim.width)×\(dim.height)  ·  \(Int(fps)) fps")
        }
        // Типовий вибір: найбільший 30 fps
        selectedFormat = formats.indices.last(where: { formats[$0].title.contains("30 fps") }) ?? max(0, formats.count - 1)
    }

    func startCamera() {
        guard Bundle.main.object(forInfoDictionaryKey: "NSCameraUsageDescription") != nil else {
            status = String(localized: "Камера доступна лише в зібраному ArduTune.app"); return
        }
        stopAll()
        AVCaptureDevice.requestAccess(for: .video) { ok in
            DispatchQueue.main.async {
                guard ok, let d = self.device() else { self.status = String(localized: "Немає доступу до камери (Системні налаштування → Конфіденційність → Камера)"); return }
                do {
                    self.session.beginConfiguration()
                    self.session.inputs.forEach { self.session.removeInput($0) }
                    let input = try AVCaptureDeviceInput(device: d)
                    if self.session.canAddInput(input) { self.session.addInput(input) }
                    self.session.commitConfiguration()
                    if d.formats.indices.contains(self.selectedFormat) {
                        try d.lockForConfiguration(); d.activeFormat = d.formats[self.selectedFormat]; d.unlockForConfiguration()
                    }
                    DispatchQueue.global().async { self.session.startRunning() }
                    self.active = .camera
                    self.status = String(localized: "Камера: \(d.localizedName)")
                } catch { self.status = String(localized: "Помилка камери: \(error.localizedDescription)") }
            }
        }
    }

    // MARK: GStreamer
    func startGStreamer(_ pipe: String? = nil) {
        if let p = pipe { pipeline = p }
        guard Self.gstAvailable else { status = String(localized: "GStreamer не знайдено (потрібен GStreamer.framework)"); return }
        wantGst = true; attempts = 0
        launchGStreamer()
        updateStatsTimer()
        if watchdog == nil {
            watchdog = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.checkStream() }
        }
    }

    /// Якщо потік завис або процес завершився без дії користувача: перезапуск із наростаючою паузою.
    private func checkStream() {
        guard wantGst, Self.gstAvailable else { return }
        let now = Date()
        let stale = active == .gstreamer && now.timeIntervalSince(max(lastFrameAt, launchedAt)) > (gotFrame ? 6 : 20)
        let dead = active == .none
        guard stale || dead, now >= nextRetry else { return }
        attempts += 1
        nextRetry = now.addingTimeInterval(min(30, Double(attempts) * 3))
        launchGStreamer()
        status = String(localized: "Відео зникло, перепідключення (спроба \(attempts))…")
    }

    // MARK: Пінг і затримка (віджет)
    /// Адреса хоста з pipeline: rtsp://[user:pass@]host[:port]/… або host=… (udpsink/srtsrc тощо).
    var streamHost: String? {
        let p = pipeline
        if let r = p.range(of: #"rtsps?://(?:[^@/\s]*@)?([^:/\s]+)"#, options: .regularExpression) {
            let m = String(p[r]); return m.components(separatedBy: "@").last.map { String($0.split(whereSeparator: { $0 == ":" || $0 == "/" }).first(where: { !$0.hasPrefix("rtsp") }) ?? "") } ?? nil
        }
        if let r = p.range(of: #"host=([^\s]+)"#, options: .regularExpression) { return String(p[r].dropFirst(5)) }
        return nil
    }

    func updateStatsTimer() {
        statsTimer?.invalidate(); statsTimer = nil
        guard showStats else { return }
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.statsTick() }
    }

    private func statsTick() {
        frameAge = active == .gstreamer ? Date().timeIntervalSince(lastFrameAt) : 0
        guard running, let host = streamHost else { pingMs = nil; pingHost = nil; return }
        pingHost = host
        guard !pinging else { return }
        pinging = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/sbin/ping")
            p.arguments = ["-c", "1", "-t", "2", host]
            let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
            var ms: Double?
            if (try? p.run()) != nil {
                let d = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
                let s = String(decoding: d, as: UTF8.self)
                if let r = s.range(of: #"time=([0-9.]+)"#, options: .regularExpression) { ms = Double(s[r].dropFirst(5)) }
            }
            DispatchQueue.main.async { self?.pingMs = ms; self?.pinging = false }
        }
    }

    private func launchGStreamer() {
        if let p = process, p.isRunning { p.terminate() }
        process = nil
        active = .none; frame = nil; fps = 0
        launchedAt = Date(); lastFrameAt = Date(); gotFrame = false
        // Прибираємо appsink з кінця (формат Mission Planner) і виводимо JPEG-кадри в stdout
        var src = pipeline.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = src.range(of: #"!\s*appsink[^!]*$"#, options: .regularExpression) { src.removeSubrange(r) }
        let full = src + " ! videoconvert ! jpegenc quality=80 ! fdsink fd=1"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Self.gstPath)
        // gst-launch трактує кожен аргумент як окремий елемент, тому pipeline треба передати словами
        p.arguments = ["-q"] + full.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).map(String.init)
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        buffer = Data(); frames = 0; fpsStamp = Date(); pending = 0
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            self?.consume(d)
        }
        err.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            if let s = String(data: d, encoding: .utf8)?.split(separator: "\n").filter({ !$0.contains("pxbackend-WARNING") }).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
                DispatchQueue.main.async { self?.status = String(s.suffix(200)) }
            }
        }
        p.terminationHandler = { [weak self] _ in DispatchQueue.main.async { if self?.active == .gstreamer { self?.active = .none; self?.frame = nil; if self?.status == String(localized: "GStreamer працює") { self?.status = String(localized: "GStreamer зупинено") } } } }
        do { try p.run(); process = p; active = .gstreamer; status = String(localized: "GStreamer працює") }
        catch { status = String(localized: "Не вдалося запустити GStreamer: \(error.localizedDescription)") }
    }

    /// Виділяє JPEG-кадри (SOI FFD8 … EOI FFD9) з потоку stdout.
    private func consume(_ d: Data) {
        buffer.append(d)
        while true {
            guard let s = buffer.firstRange(of: Data([0xFF, 0xD8])) else { buffer.removeAll(keepingCapacity: true); return }
            guard let e = buffer.range(of: Data([0xFF, 0xD9]), in: s.upperBound..<buffer.endIndex) else {
                if s.lowerBound > 0 { buffer.removeSubrange(0..<s.lowerBound) }
                if buffer.count > 8_000_000 { buffer.removeAll() }
                return
            }
            let jpeg = buffer.subdata(in: s.lowerBound..<e.upperBound)
            buffer.removeSubrange(0..<e.upperBound)
            if pending < 2 {
                pending += 1
                DispatchQueue.main.async {
                    self.pending -= 1
                    if let img = NSImage(data: jpeg) { self.frame = img }
                    self.frames += 1; self.lastFrameAt = Date(); self.gotFrame = true; self.attempts = 0
                    let dt = Date().timeIntervalSince(self.fpsStamp)
                    if dt >= 1 { self.fps = Double(self.frames) / dt; self.frames = 0; self.fpsStamp = Date() }
                }
            }
        }
    }

    func stopAll() {
        wantGst = false
        if let p = process, p.isRunning { p.terminate() }
        process = nil
        if session.isRunning { DispatchQueue.global().async { self.session.stopRunning() } }
        active = .none; frame = nil; fps = 0
    }
}

// MARK: - Перегляд

struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    func makeNSView(context: Context) -> NSView {
        let v = NSView(); v.wantsLayer = true
        let l = AVCaptureVideoPreviewLayer(session: session); l.videoGravity = .resizeAspect
        l.frame = v.bounds; l.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        v.layer = l
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {}
}

/// Поверхня відео: камера або кадри GStreamer, з необов'язковим оверлеєм HUD.
struct VideoSurface: View {
    let video: VideoStore
    let t: Telemetry

    var body: some View {
        ZStack {
            Color.black
            switch video.active {
            case .camera: CameraPreview(session: video.session)
            case .gstreamer:
                if let img = video.frame { Image(nsImage: img).resizable().aspectRatio(contentMode: .fit) }
                else { ProgressView("Очікування кадрів…").controlSize(.large) }
            case .none: ContentUnavailableView("Відео не запущено", systemImage: "video.slash")
            }
            if video.showStats && video.active == .gstreamer { VideoStatsBadge(video: video).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(10) }
        }
    }
}

/// Віджет якості відео: пінг до джерела, кадри/с і час без кадрів. Це не повна затримка «скло-скло», а мережева затримка й стан потоку.
struct VideoStatsBadge: View {
    let video: VideoStore
    var body: some View {
        let ping = video.pingMs
        let color: Color = ping == nil ? .gray : (ping! < 100 ? .green : (ping! < 250 ? .yellow : .red))
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(ping.map { String(format: loc("Пінг %.0f мс"), $0) } ?? (video.pingHost == nil ? loc("Пінг: немає адреси") : loc("Пінг: немає відповіді")))
            if video.fps > 0 { Text(String(format: "%.0f fps", video.fps)) }
            if video.frameAge > 2 { Text(String(format: loc("немає кадрів %.0f с"), video.frameAge)).foregroundStyle(.orange) }
        }
        .font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(.white)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(.black.opacity(0.55), in: Capsule())
    }
}


/// Вкладка Video у Flight Data.
struct VideoTab: View {
    @Environment(Store.self) var s
    @Environment(\.openWindow) private var openWindow
    private var st: StreamSettings { StreamSettings.shared }
    private var herelinkIP: String { st.ip }
    private var herelinkPort: Int { st.port }
    private var herelinkPath: String { st.path }
    var v: VideoStore { s.video }
    var herelinkURL: String { "rtsp://\(herelinkIP):\(herelinkPort)/\(herelinkPath)" }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 14) {
                        Button { openWindow(id: "video") } label: { Label("Відкрити у вікні", systemImage: "rectangle.on.rectangle") }
                        Toggle("Показувати на HUD", isOn: Binding(get: { v.showInHUD }, set: { v.showInHUD = $0 })).toggleStyle(.checkbox)
                        Toggle("Пінг і FPS на відео", isOn: Binding(get: { v.showStats }, set: { v.showStats = $0 })).toggleStyle(.checkbox)
                    }
                    GroupBox("Камера") {
                        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                            GridRow {
                                Text("Video Device")
                                Picker("", selection: Binding(get: { v.selectedCamera ?? "" }, set: { v.selectedCamera = $0 })) {
                                    if v.cameras.isEmpty { Text("— немає камер —").tag("") }
                                    ForEach(v.cameras) { Text(lk($0.name)).tag($0.id) }
                                }.labelsHidden().frame(width: 280)
                                Button("Start") { v.startCamera() }.disabled(v.cameras.isEmpty)
                                Button("Stop") { v.stopAll() }
                            }
                            GridRow {
                                Text("Video Format")
                                Picker("", selection: Binding(get: { v.selectedFormat }, set: { v.selectedFormat = $0 })) {
                                    ForEach(v.formats) { Text(lk($0.title)).tag($0.id) }
                                }.labelsHidden().frame(width: 280)
                            }
                        }.padding(6)
                    }
                    GroupBox("GStreamer") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Menu("Шаблони") { ForEach(Array(VideoStore.presets.enumerated()), id: \.offset) { _, p in Button(lk(p.0)) { v.pipeline = p.1 } } }.frame(width: 110)
                                Button("Start") { v.startGStreamer() }.disabled(!VideoStore.gstAvailable)
                                Button("Stop") { v.stopAll() }
                                GStreamerMissingNote()
                            }
                            TextEditor(text: Binding(get: { v.pipeline }, set: { v.pipeline = $0 }))
                                .font(.system(.callout, design: .monospaced)).frame(height: 84)
                                .overlay(RoundedRectangle(cornerRadius: 5).stroke(.gray.opacity(0.4)))
                            Text("Кінцівку «! appsink name=outsink» можна залишити або прибрати: відео виводиться автоматично.").font(.caption2).foregroundStyle(.secondary)
                        }.padding(6)
                    }
                    GroupBox("Herelink") {
                        VStack(alignment: .leading, spacing: 8) {
                            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                                GridRow {
                                    Text("IP-адреса")
                                    TextField("192.168.0.10", text: Binding(get: { st.ip }, set: { st.ip = $0 })).textFieldStyle(.roundedBorder).frame(width: 160)
                                    Text("Порт"); TextField("8554", value: Binding(get: { st.port }, set: { st.port = $0 }), format: .number.grouping(.never)).textFieldStyle(.roundedBorder).frame(width: 70)
                                }
                                GridRow {
                                    Text("Потік")
                                    TextField("fpv_stream", text: Binding(get: { st.path }, set: { st.path = $0 })).textFieldStyle(.roundedBorder).frame(width: 160)
                                    Color.clear.frame(width: 1, height: 1); Color.clear.frame(width: 1, height: 1)
                                }
                            }
                            HStack {
                                Button("Start") {
                                    v.startGStreamer("rtspsrc location=\(herelinkURL) latency=0 ! rtph264depay ! h264parse ! avdec_h264"); v.showInHUD = true
                                }.disabled(!VideoStore.gstAvailable)
                                Button("Stop") { v.stopAll() }
                                Button("Типові значення") { st.resetHerelink() }.controlSize(.small)
                            }
                            GStreamerMissingNote()
                            Text("Потік Herelink / Cube Controller по RTSP (H.264, мінімальна затримка). Потрібні GStreamer.framework і з'єднання з мережею Herelink.").font(.caption2).foregroundStyle(.secondary)
                        }.padding(6)
                    }
                    if !v.status.isEmpty { Text(LocalizedStringKey(v.status)).font(.caption).foregroundStyle(.secondary) }
                    if v.fps > 0 { Text(String(format: loc("%.0f кадрів/с"), v.fps)).font(.caption).foregroundStyle(.secondary) }
                }
                .padding(10)
            }
            .frame(width: 520)
            VideoSurface(video: v, t: s.t).clipShape(RoundedRectangle(cornerRadius: 8)).padding(10)
        }
        .onAppear { v.refreshCameras() }
    }
}

struct VideoWindow: View {
    @Environment(Store.self) var s
    @AppStorage("vhud.on") private var hudOn = false
    @AppStorage("vhud.hidden") private var hidden = ""
    @AppStorage("vhud.user") private var user = ""
    @AppStorage("vhud.opacity") private var opacity = 1.0
    @AppStorage("vhud.scale") private var scale = 1.0
    @AppStorage("hud.theme") private var themeID = "classic"
    @AppStorage("hud.sky") private var sky = ""
    @AppStorage("hud.ground") private var ground = ""
    @AppStorage("hud.ink") private var ink = ""
    @AppStorage("hud.accent") private var accent = ""
    @AppStorage("vmap.on") private var mapOn = false
    @State private var showSettings = false
    @Environment(\.openWindow) private var openWindow

    var config: HUDConfig {
        var c = HUDConfig()
        c.videoBackground = true
        c.scale = scale
        c.hidden = Set(hidden.split(separator: ",").map(String.init))
        c.userItems = user.split(separator: ",").map(String.init)
        c.theme = HUDTheme.make(id: themeID, sky: sky, ground: ground, ink: ink, accent: accent)
        return c
    }

    var body: some View {
        VideoSurface(video: s.video, t: s.t)
            .overlay {
                if hudOn { HUDView(t: s.t, navSource: s.ps.navSource, alerts: [], config: config).opacity(opacity).allowsHitTesting(false) }
            }
            .overlay(alignment: .topLeading) {
                if mapOn { GeometryReader { g in MiniMapPanel(area: g.size).padding(10) } }
            }
            .frame(minWidth: 480, minHeight: 300)
            .toolbar {
                ToolbarItem {
                    Button { s.video.running ? s.video.stopAll() : s.video.startGStreamer() } label: { Image(systemName: s.video.running ? "stop.fill" : "play.fill") }
                        .help(lk(s.video.running ? "Зупинити відео" : "Запустити відео"))
                }
                ToolbarItem {
                    Toggle(isOn: $mapOn) { Label("Мінікарта", systemImage: "map") }.toggleStyle(.button).help("Мінікарта з центром на апараті")
                }
                ToolbarItem {
                    Toggle(isOn: $hudOn) { Label("HUD", systemImage: "gauge.with.dots.needle.67percent") }.toggleStyle(.button).help("Дублювати HUD поверх відео")
                }
                ToolbarItem {
                    Button { showSettings.toggle() } label: { Label("Налаштувати HUD", systemImage: "slider.horizontal.3") }.disabled(!hudOn)
                        .popover(isPresented: $showSettings, arrowEdge: .bottom) { settings }
                }
            }
    }

    func toggle(_ raw: Binding<String>, _ key: String) {
        var l = raw.wrappedValue.split(separator: ",").map(String.init)
        if let i = l.firstIndex(of: key) { l.remove(at: i) } else { l.append(key) }
        raw.wrappedValue = l.joined(separator: ",")
    }

    var settings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("HUD поверх відео").font(.headline)
                HStack { Text("Прозорість"); Slider(value: $opacity, in: 0.2...1) ; Text("\(Int(opacity * 100))%").monospacedDigit().frame(width: 44, alignment: .trailing) }
                HStack { Text("Масштаб"); Slider(value: $scale, in: 0.6...1.6, step: 0.05); Text("\(Int((scale * 100).rounded()))%").monospacedDigit().frame(width: 44, alignment: .trailing) }
                Text("ЕЛЕМЕНТИ").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(HUDConfig.elements, id: \.0) { e in
                    Toggle(lk(e.1), isOn: Binding(get: { !hidden.split(separator: ",").contains(Substring(e.0)) }, set: { _ in toggle($hidden, e.0) })).toggleStyle(.checkbox)
                }
                Text("ТЕКСТОВІ ПАРАМЕТРИ").font(.caption2.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 4)
                ForEach(HUDConfig.userDefs, id: \.0) { e in
                    Toggle(lk(e.1), isOn: Binding(get: { user.split(separator: ",").contains(Substring(e.0)) }, set: { _ in toggle($user, e.0) })).toggleStyle(.checkbox)
                }
                Divider()
                HStack {
                    Button("Тема й кольори…") { openWindow(id: "hudtheme") }
                    Spacer()
                    Button("Скинути") { hidden = ""; user = ""; opacity = 1; scale = 1 }
                }
            }
            .padding(14)
        }
        .frame(width: 300, height: 460)
    }
}

/// Підказка з посиланням на встановлення, якщо GStreamer.framework не знайдено.
struct GStreamerMissingNote: View {
    var body: some View {
        if !VideoStore.gstAvailable {
            HStack(spacing: 6) {
                Label("GStreamer.framework не знайдено", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                Link("Завантажити GStreamer", destination: URL(string: "https://gstreamer.freedesktop.org/download/#macos")!)
            }.font(.caption)
        }
    }
}
