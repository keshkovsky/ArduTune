import Foundation
import AVFoundation

/// Голосові й звукові сповіщення (вимкнені за замовчуванням, налаштовуються в «ArduTune → Голосові сповіщення»).
/// Подій: зміна режиму, ARM/DISARM, низький заряд, GPS, зв'язок, важливі повідомлення польотника (STATUSTEXT); окремо звуковий варіометр.
@MainActor
final class VoiceAlerts: NSObject {
    static let shared = VoiceAlerts()
    private let synth = AVSpeechSynthesizer()
    private var started = false
    private weak var store: Store?
    // стан для виявлення подій
    private var lastMode: String?
    private var lastArmed: Bool?
    private var lastConnected: Bool?
    private var lastFix = false, hadFix = false
    private var spokenBattery: Set<Int> = []
    private var lastSeq = -1
    private var recent: [String: Date] = [:]
    private var logPoll = Date.distantPast
    private let vario = VarioTone()

    static var d: UserDefaults { .standard }
    static var enabled: Bool { d.bool(forKey: "voice.on") }
    static func flag(_ k: String, _ def: Bool = true) -> Bool { (d.object(forKey: "voice." + k) as? Bool) ?? def }

    func start(_ s: Store) {
        guard !started else { return }
        started = true; store = s
        Task { @MainActor in
            while true {
                try? await Task.sleep(nanoseconds: 400_000_000)
                tick()
            }
        }
    }

    // MARK: Мовлення

    /// Мова озвучення відповідає мові інтерфейсу.
    static var voiceLanguage: String { (d.string(forKey: "app.lang") ?? "uk") == "en" ? "en-US" : "uk-UA" }
    static func voices() -> [AVSpeechSynthesisVoice] {
        let pre = String(voiceLanguage.prefix(2))
        return AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(pre) }.sorted { $0.name < $1.name }
    }

    func say(_ text: String, urgent: Bool = false) {
        guard !text.isEmpty else { return }
        let u = AVSpeechUtterance(string: text)
        if let id = Self.d.string(forKey: "voice.voice"), let v = AVSpeechSynthesisVoice(identifier: id) { u.voice = v }
        else { u.voice = AVSpeechSynthesisVoice(language: Self.voiceLanguage) ?? AVSpeechSynthesisVoice(language: "en-US") }
        let rate = (Self.d.object(forKey: "voice.rate") as? Double) ?? 0.5
        u.rate = Float(min(max(rate, 0.3), 0.7))
        u.volume = Float((Self.d.object(forKey: "voice.volume") as? Double) ?? 1.0)
        if urgent { synth.stopSpeaking(at: .word) }
        synth.speak(u)
    }
    /// Перевірка голосу з налаштувань.
    func test() { say(String(localized: "Голосові сповіщення працюють")) }

    // MARK: Події

    private func tick() {
        guard let s = store else { return }
        let on = Self.enabled
        let t = s.t
        // варіометр
        vario.update(enabled: on && Self.flag("vario", false) && s.connected && s.armedLive, climb: t.climb)
        guard on else { lastMode = t.mode; lastArmed = s.connected ? t.armed : nil; lastConnected = s.connected; return }

        if let c = lastConnected, c != s.connected, Self.flag("link") {
            say(s.connected ? String(localized: "Зв'язок з польотником встановлено") : String(localized: "Зв'язок з польотником втрачено"), urgent: !s.connected)
        }
        lastConnected = s.connected
        guard s.connected else { lastMode = nil; lastArmed = nil; spokenBattery = []; return }

        if let m = t.mode, !m.isEmpty, m != lastMode {
            if lastMode != nil, Self.flag("mode") { say(String(localized: "Режим \(m)")) }
            lastMode = m
        }
        if let a = lastArmed, a != t.armed, Self.flag("arm") { say(t.armed ? String(localized: "Мотори увімкнено") : String(localized: "Мотори вимкнено"), urgent: true) }
        lastArmed = t.armed

        if t.batteryPct > 0 {
            for lvl in [30, 20, 10] where t.batteryPct <= lvl && !spokenBattery.contains(lvl) {
                spokenBattery.insert(lvl)
                if Self.flag("battery") { say(String(localized: "Заряд батареї \(t.batteryPct) відсотків"), urgent: lvl <= 20) }
                break
            }
            for lvl in spokenBattery where t.batteryPct > lvl + 5 { spokenBattery.remove(lvl) }
        }

        let fix = t.gpsFix >= 3
        if fix { hadFix = true }
        if hadFix, fix != lastFix, Self.flag("gps") { say(fix ? String(localized: "GPS з'явився") : String(localized: "GPS втрачено"), urgent: !fix) }
        lastFix = fix

        // повідомлення польотника
        if Self.flag("messages"), Date().timeIntervalSince(logPoll) > 1.5 {
            logPoll = Date()
            Task { @MainActor in await pollMessages() }
        }
    }

    private func pollMessages() async {
        guard let d = await EngineAPI.get("/log", as: LogDTO.self) else { return }
        defer { lastSeq = d.seq }
        guard lastSeq >= 0 else { return }
        let fresh = max(0, d.seq - lastSeq)
        let limit = (Self.d.object(forKey: "voice.severity") as? Int) ?? 4
        for m in d.items.suffix(min(fresh, d.items.count)) where m.sev <= limit {
            if let at = recent[m.text], Date().timeIntervalSince(at) < 20 { continue }
            recent[m.text] = Date()
            say(m.text, urgent: m.sev <= 2)
        }
        recent = recent.filter { Date().timeIntervalSince($0.value) < 60 }
    }
}

/// Звуковий варіометр: тон, що змінюється від швидкості набору/зниження (піки частіше й вищі при наборі).
@MainActor
final class VarioTone {
    private let engine = AVAudioEngine()
    private var node: AVAudioSourceNode?
    private var phase = 0.0, gate = 0.0
    private var freq = 0.0, beepHz = 0.0, level = 0.0
    private var running = false
    private var tNow = 0.0

    func update(enabled: Bool, climb: Double) {
        if !enabled { stop(); return }
        if !running { start() }
        let c = max(-6, min(6, climb))
        if c > 0.3 { freq = 600 + 120 * c; beepHz = 1.5 + 1.2 * c; level = 0.25 }
        else if c < -1.5 { freq = 280 + 15 * c; beepHz = 0; level = 0.2 }         // зниження: низький безперервний тон
        else { level = 0 }
        vols = (freq, beepHz, level)
    }
    private nonisolated(unsafe) var vols: (Double, Double, Double) = (0, 0, 0)

    private func start() {
        let sr = engine.outputNode.outputFormat(forBus: 0).sampleRate
        guard sr > 0 else { return }
        let src = AVAudioSourceNode { [weak self] _, _, frames, abl in
            guard let self else { return noErr }
            let (f, b, lv) = self.vols
            let buf = UnsafeMutableAudioBufferListPointer(abl)
            for i in 0..<Int(frames) {
                self.phase += 2 * .pi * f / sr
                if self.phase > 2 * .pi { self.phase -= 2 * .pi }
                self.tNow += 1 / sr
                var g = 1.0
                if b > 0 { let x = (self.tNow * b).truncatingRemainder(dividingBy: 1); g = x < 0.5 ? 1 : 0; g *= min(1, min(x, 0.5 - x < 0 ? 0 : 0.5 - x) * 40) }   // короткий писк із м'якими краями
                let v = Float(sin(self.phase) * lv * g)
                for ch in 0..<buf.count { buf[ch].mData?.assumingMemoryBound(to: Float.self)[i] = lv > 0 ? v : 0 }
            }
            return noErr
        }
        node = src
        engine.attach(src)
        engine.connect(src, to: engine.mainMixerNode, format: AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1))
        do { try engine.start(); running = true } catch { node = nil }
    }
    private func stop() {
        guard running else { return }
        engine.stop(); if let n = node { engine.detach(n) }; node = nil; running = false
    }
}
