import Foundation
import Observation
import CoreLocation

struct Telemetry: Decodable {
    var connected = false
    var port: String? = nil
    var vehicle: String? = nil
    var mode: String? = nil
    var armed = false
    var roll = 0.0, pitch = 0.0, yaw = 0.0
    var lat = 0.0, lon = 0.0, altRel = 0.0
    var groundSpeed = 0.0, airSpeed = 0.0, heading = 0.0, climb = 0.0
    var batteryV = 0.0, batteryA = 0.0, batteryPct = 0
    var gpsFix = 0, sats = 0
    var lastText: String? = nil
    var msgRate = 0.0
    var customMode = 0
    var altMsl = 0.0, throttle = 0.0, navRoll = 0.0, navPitch = 0.0, wpDist = 0.0, navBearing = 0.0, targetBearing = 0.0
    var wpSeq = 0, wpTotal = 0, wpReached = -1
    var vibeX = 0.0, vibeY = 0.0, vibeZ = 0.0, hdop = 0.0, rssi = 0.0, mahUsed = 0.0
    var homeLat = 0.0, homeLon = 0.0, homeSet = false
    var timeInAir = 0.0, distTraveled = 0.0
    var ekfFlags = 0
    var gpsHealthy = false, visoPresent = false, visoHealthy = false
    var ekfVelVar = 0.0, ekfPosHVar = 0.0, ekfPosVVar = 0.0, ekfCompassVar = 0.0, ekfTerrainVar = 0.0
    var vibeClip0 = 0.0, vibeClip1 = 0.0, vibeClip2 = 0.0
    var linkType: String? = nil
    var linkState: String? = nil
    var booting: Bool? = nil
    var cog: Double? = nil
    var magHdg: Double? = nil
    var linkError: String? = nil
    var recording = false
    var recordFile: String? = nil
    var metaSource: String? = nil
    var replaying = false
    var replayProgress = 0.0, replaySpeed = 1.0
}

@Observable
final class Store {
    var t = Telemetry()
    var engineUp = false
    private(set) var armedLive = false
    /// Блокування редагування: апарат ARMED або перегляд параметрів без підключення (лише читання).
    var armed: Bool { armedLive || viewOnly }
    var viewOnly: Bool { !connected && ps.offline != nil }
    /// Є що показувати на сторінках налаштувань: підключений польотник або завантажені параметри.
    var canView: Bool { connected || ps.offline != nil }
    var track: [CLLocationCoordinate2D] = []
    private(set) var connected = false
    let ps = ParamStore()
    let joy = JoystickStore()
    let poi = POIStore()
    let video = VideoStore()
    let wizard = MotorWizardStore()
    let tune = TuneStore()
    let mission = MissionStore()
    let firmware = FirmwareModel()
    let dfu = DFUModel()
    var flightTabRequest: String?
    var navigate: String?
    private var task: URLSessionWebSocketTask?
    private var engine: Process?

    func start() {
        ps.start()
        launchEngine()
        connect()
        Task { @MainActor in VoiceAlerts.shared.start(self); AddonManager.shared.attach(self) }
        // налаштування застосунку: GCS ID і (за бажанням) без автопідключення при запуску
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            AppSettings.pushGcsID()
            AppSettings.pushLogDir()
            if !AppSettings.autoConnectOnLaunch { EngineAPI.post("/disconnect") }
        }
    }

    /// Перезапуск двигуна (з налаштувань): старий завершується, новий стартує з тим самим токеном.
    func restartEngine() {
        engine?.terminate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.launchEngine()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { AppSettings.pushGcsID() }
        }
    }

    private func launchEngine() {
        // Якщо двигун вже запущений вручну — не дублюємо.
        let p = Process()
        let candidates = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Engine/Engine").path,
            NSHomeDirectory() + "/Developer/ArduTune/Engine/bin/Release/net8.0/osx-arm64/Engine",
        ]
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return }
        // Залишений від попереднього запуску двигун не знає нового токена: завершуємо його (збіг лише за повним шляхом нашого виконуваного файлу).
        let kill = Process()
        kill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        kill.arguments = ["-f", path]
        try? kill.run(); kill.waitUntilExit()
        Thread.sleep(forTimeInterval: 0.3)
        p.executableURL = URL(fileURLWithPath: path)
        p.environment = ["DOTNET_ROOT": NSHomeDirectory() + "/.dotnet", "ARDUTUNE_TOKEN": EngineAPI.token, "ARDUTUNE_LOGDIR": AppSettings.logDir]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        engine = p
    }

    func stop() { engine?.terminate(); video.stopAll() }

    private func connect() {
        let ws = URLSession.shared.webSocketTask(with: EngineAPI.request(URL(string: "ws://127.0.0.1:14560/ws")!))
        task = ws
        ws.resume()
        receive(ws)
    }

    private func receive(_ ws: URLSessionWebSocketTask) {
        ws.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(.string(let s)):
                if let d = s.data(using: .utf8), let tel = try? JSONDecoder().decode(Telemetry.self, from: d) {
                    DispatchQueue.main.async {
                        self.t = tel
                        if tel.gpsFix >= 3, abs(tel.lat) > 0.0001 {
                            let c = CLLocationCoordinate2D(latitude: tel.lat, longitude: tel.lon)
                            if let l = self.track.last {
                                if abs(l.latitude - c.latitude) > 0.00002 || abs(l.longitude - c.longitude) > 0.00002 { self.track.append(c) }
                            } else { self.track.append(c) }
                            let cap = max(100, (UserDefaults.standard.object(forKey: "map.trackLen") as? Int) ?? 5000)
                            if self.track.count > cap { self.track.removeFirst(self.track.count - cap + max(1, cap / 10)) }
                        }
                        if !self.engineUp { self.engineUp = true }
                        if self.armedLive != tel.armed { self.armedLive = tel.armed }
                        if self.connected != tel.connected {
                            self.connected = tel.connected
                            if tel.connected {
                                self.ps.closeOffline()                          // справжній польотник: його параметри замінюють перегляд
                                if AppSettings.customRates { DispatchQueue.main.asyncAfter(deadline: .now() + 2) { AppSettings.applyRates() } }
                                if AppSettings.loadMissionOnConnect { DispatchQueue.main.asyncAfter(deadline: .now() + 3) { Task { @MainActor in await self.mission.readFromVehicle() } } }
                            }
                            else { self.ps.captureOffline() }                  // зв'язок зник: останні параметри лишаються для перегляду
                        }
                        if let v = tel.vehicle, v != self.ps.metaVehicle { self.ps.reloadMeta(for: v) }
                        else if let src = tel.metaSource, !src.isEmpty, src != self.ps.metaSource { self.ps.reloadMeta(source: src) }
                    }
                }
                self.receive(ws)
            case .success:
                self.receive(ws)
            case .failure:
                DispatchQueue.main.async { self.engineUp = false }
                DispatchQueue.global().asyncAfter(deadline: .now() + 1) { self.connect() }
            }
        }
    }
}
