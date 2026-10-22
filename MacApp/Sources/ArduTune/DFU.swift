import Foundation
import Observation
import IOKit
import IOKit.usb
import IOKit.usb.IOUSBLib

// MARK: - Intel HEX

/// Щільний образ пам'яті з Intel HEX: адреса початку й байти (прогалини заповнені 0xFF).
struct HexImage {
    var base: UInt32
    var data: [UInt8]
    var end: UInt32 { base + UInt32(data.count) }
}

enum IntelHex {
    struct Failure: Error { let message: String }

    static func parse(_ text: String) throws -> HexImage {
        var ext: UInt32 = 0                       // розширена лінійна/сегментна адреса
        var chunks: [(addr: UInt32, bytes: [UInt8])] = []
        var lineNo = 0
        for raw in text.split(whereSeparator: \.isNewline) {
            lineNo += 1
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            guard line.hasPrefix(":"), line.count >= 11 else { throw Failure(message: String(localized: "Рядок \(lineNo): це не Intel HEX")) }
            let hex = Array(line.dropFirst())
            var b: [UInt8] = []
            var i = 0
            while i + 1 < hex.count {
                guard let v = UInt8(String(hex[i...i + 1]), radix: 16) else { throw Failure(message: String(localized: "Рядок \(lineNo): некоректний символ")) }
                b.append(v); i += 2
            }
            let n = Int(b[0])
            guard b.count == n + 5 else { throw Failure(message: String(localized: "Рядок \(lineNo): неправильна довжина")) }
            guard b.reduce(0, { $0 &+ Int($1) }) & 0xFF == 0 else { throw Failure(message: String(localized: "Рядок \(lineNo): помилка контрольної суми")) }
            let off = UInt32(b[1]) << 8 | UInt32(b[2])
            switch b[3] {
            case 0x00: chunks.append((ext &+ off, Array(b[4..<4 + n])))
            case 0x01: break
            case 0x02: ext = (UInt32(b[4]) << 8 | UInt32(b[5])) << 4
            case 0x04: ext = (UInt32(b[4]) << 8 | UInt32(b[5])) << 16
            default: break                                  // 03/05: адреса запуску, не потрібна
            }
        }
        guard let lo = chunks.map(\.addr).min(), let hi = chunks.map({ $0.addr + UInt32($0.bytes.count) }).max(), hi > lo else { throw Failure(message: String(localized: "У файлі немає даних")) }
        guard hi - lo < 64 << 20 else { throw Failure(message: String(localized: "Образ завеликий")) }
        var img = [UInt8](repeating: 0xFF, count: Int(hi - lo))
        for c in chunks { img.replaceSubrange(Int(c.addr - lo)..<Int(c.addr - lo) + c.bytes.count, with: c.bytes) }
        return HexImage(base: lo, data: img)
    }
}

// MARK: - USB DFU (STM32 DfuSe) через IOKit

struct DFUError: Error, LocalizedError { let message: String; var errorDescription: String? { message } }

/// Пристрій у режимі DFU вбудованого завантажувача STM32 (VID 0x0483, PID 0xDF11).
final class DFUDevice {
    static let vid = 0x0483, pid = 0xDF11

    // UUID-и з IOKit/usb/IOUSBLib.h (макроси не імпортуються в Swift)
    private static let pluginType = CFUUIDGetConstantUUIDWithBytes(nil, 0xC2, 0x44, 0xE8, 0x58, 0x10, 0x9C, 0x11, 0xD4, 0x91, 0xD4, 0x00, 0x50, 0xE4, 0xC6, 0x42, 0x6F)
    private static let userClient = CFUUIDGetConstantUUIDWithBytes(nil, 0x9d, 0xc7, 0xb7, 0x80, 0x9e, 0xc0, 0x11, 0xD4, 0xa5, 0x4f, 0x00, 0x0a, 0x27, 0x05, 0x28, 0x61)
    private static let deviceInterface = CFUUIDGetConstantUUIDWithBytes(nil, 0x5c, 0x81, 0x87, 0xd0, 0x9e, 0xf3, 0x11, 0xD4, 0x8b, 0x45, 0x00, 0x0a, 0x27, 0x05, 0x28, 0x61)

    typealias Dev = UnsafeMutablePointer<UnsafeMutablePointer<IOUSBDeviceInterface>?>
    typealias Transport = (_ type: UInt8, _ request: UInt8, _ value: UInt16, _ index: UInt16, _ data: inout [UInt8], _ length: Int) throws -> Int
    private var dev: Dev?
    private var opened = false
    private var transport: Transport?

    /// Підміна транспорту для перевірки протоколу без USB-пристрою.
    init(transport: @escaping Transport) { self.transport = transport }

    /// Чи підключено пристрій у режимі DFU (без відкриття).
    static func isPresent(vid: Int = DFUDevice.vid, pid: Int = DFUDevice.pid) -> Bool {
        guard let m = IOServiceMatching("IOUSBHostDevice") as NSMutableDictionary? else { return false }
        m["idVendor"] = vid; m["idProduct"] = pid
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, m, &it) == KERN_SUCCESS else { return false }
        defer { IOObjectRelease(it) }
        let s = IOIteratorNext(it)
        if s != 0 { IOObjectRelease(s); return true }
        return false
    }

    init(vid: Int = DFUDevice.vid, pid: Int = DFUDevice.pid) throws {
        guard let m = IOServiceMatching("IOUSBHostDevice") as NSMutableDictionary? else { throw DFUError(message: String(localized: "IOKit недоступний")) }
        m["idVendor"] = vid; m["idProduct"] = pid
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, m, &it) == KERN_SUCCESS else { throw DFUError(message: String(localized: "Не вдалося опитати USB")) }
        defer { IOObjectRelease(it) }
        let svc = IOIteratorNext(it)
        guard svc != 0 else { throw DFUError(message: String(localized: "DFU-пристрій не знайдено")) }
        defer { IOObjectRelease(svc) }
        var plug: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>?
        var score: Int32 = 0
        guard IOCreatePlugInInterfaceForService(svc, Self.userClient, Self.pluginType, &plug, &score) == KERN_SUCCESS, let p = plug else {
            throw DFUError(message: String(localized: "Не вдалося створити USB-інтерфейс (немає доступу?)"))
        }
        defer { _ = p.pointee?.pointee.Release(p) }
        var raw: LPVOID?
        let hr = p.pointee?.pointee.QueryInterface(p, CFUUIDGetUUIDBytes(Self.deviceInterface), &raw) ?? -1
        guard hr == 0, let r = raw else { throw DFUError(message: String(localized: "USB-інтерфейс пристрою недоступний (код \(hr))")) }
        dev = r.assumingMemoryBound(to: UnsafeMutablePointer<IOUSBDeviceInterface>?.self)
    }

    deinit { close(); if let d = dev { _ = d.pointee?.pointee.Release(d) } }

    var ids: (vid: UInt16, pid: UInt16) {
        var v: UInt16 = 0, p: UInt16 = 0
        guard let dev else { return (0, 0) }
        _ = dev.pointee?.pointee.GetDeviceVendor(dev, &v); _ = dev.pointee?.pointee.GetDeviceProduct(dev, &p)
        return (v, p)
    }

    func open() throws {
        guard let dev else { opened = true; return }
        var r = dev.pointee?.pointee.USBDeviceOpen(dev) ?? kIOReturnError
        if r == kIOReturnExclusiveAccess { r = dev.pointee?.pointee.USBDeviceOpenSeize(dev) ?? kIOReturnError }
        guard r == kIOReturnSuccess else { throw DFUError(message: String(format: loc("Не вдалося відкрити USB-пристрій (0x%08X)"), UInt32(bitPattern: r))) }
        opened = true
    }
    func close() { if opened, let dev { _ = dev.pointee?.pointee.USBDeviceClose(dev) }; opened = false }

    /// Керівна передача. Для DFU: клас, інтерфейс 0.
    @discardableResult
    func control(_ type: UInt8, _ request: UInt8, value: UInt16, index: UInt16 = 0, data: inout [UInt8], length: Int? = nil) throws -> Int {
        let len = length ?? data.count
        if data.count < len { data += [UInt8](repeating: 0, count: len - data.count) }
        if let transport { return try transport(type, request, value, index, &data, len) }
        guard let dev else { throw DFUError(message: String(localized: "USB-пристрій не відкрито")) }
        return try data.withUnsafeMutableBytes { buf in
            var req = IOUSBDevRequest(bmRequestType: type, bRequest: request, wValue: value, wIndex: index, wLength: UInt16(len), pData: len > 0 ? buf.baseAddress : nil, wLenDone: 0)
            let r = dev.pointee?.pointee.DeviceRequest(dev, &req) ?? kIOReturnError
            guard r == kIOReturnSuccess else { throw DFUError(message: String(format: loc("USB-передача не вдалась (0x%08X)"), UInt32(bitPattern: r))) }
            return Int(req.wLenDone)
        }
    }

    // MARK: DFU / DfuSe
    struct Status { let status: UInt8; let pollMs: Int; let state: UInt8 }
    static let stateIdle: UInt8 = 2, stateDnBusy: UInt8 = 4, stateDnIdle: UInt8 = 5, stateError: UInt8 = 10

    func getStatus() throws -> Status {
        var b = [UInt8](repeating: 0, count: 6)
        _ = try control(0xA1, 3, value: 0, data: &b)
        return Status(status: b[0], pollMs: Int(b[1]) | Int(b[2]) << 8 | Int(b[3]) << 16, state: b[4])
    }
    func clearStatus() throws { var d: [UInt8] = []; try control(0x21, 4, value: 0, data: &d) }
    func abort() throws { var d: [UInt8] = []; try control(0x21, 6, value: 0, data: &d) }

    /// Привести пристрій у dfuIDLE.
    func toIdle() throws {
        for _ in 0..<6 {
            let s = try getStatus()
            if s.state == Self.stateIdle { return }
            if s.state == Self.stateError { try clearStatus() } else { try abort() }
        }
        throw DFUError(message: String(localized: "Пристрій DFU не переходить у стан очікування"))
    }

    /// Дочекатись завершення команди (dfuDNBUSY → dfuDNLOAD-IDLE). Під час стирання пристрій може відповідати на USB-запити
    /// помилками (затримка, STALL): це не збій, тому передавальні помилки повторюємо до кінця часу.
    func wait(timeout: TimeInterval = 120) throws {
        let until = Date().addingTimeInterval(timeout)
        var lastError: Error?
        while true {
            if Date() > until { throw lastError ?? DFUError(message: String(localized: "Перевищено час очікування DFU")) }
            let s: Status
            do { s = try getStatus(); lastError = nil }
            catch { lastError = error; usleep(300_000); continue }
            if s.state == Self.stateError || s.status != 0 { throw DFUError(message: String(localized: "Помилка DFU (статус \(loc(s.status)), стан \(s.state))")) }
            if s.state != Self.stateDnBusy { return }
            usleep(UInt32(max(min(s.pollMs, 5000), 1)) * 1000)
        }
    }

    /// Розмір блоку передачі з функціонального дескриптора DFU (STM32: 1024 або 2048).
    func transferSize() -> Int {
        var cfg = [UInt8](repeating: 0, count: 255)
        guard let n = try? control(0x80, 6, value: 0x0200, data: &cfg), n >= 9 else { return 1024 }
        var i = 0
        while i + 9 <= n {
            let len = Int(cfg[i])
            if len == 0 { break }
            if len == 9, cfg[i + 1] == 0x21 { let ts = Int(cfg[i + 5]) | Int(cfg[i + 6]) << 8; return ts >= 64 && ts <= 4096 ? ts : 1024 }
            i += len
        }
        return 1024
    }

    func dnload(block: UInt16, _ payload: [UInt8], timeout: TimeInterval = 120) throws {
        var d = payload
        try control(0x21, 1, value: block, data: &d)
        try wait(timeout: timeout)
    }
    func setAddress(_ a: UInt32) throws {
        let cmd: [UInt8] = [0x21, UInt8(a & 0xFF), UInt8(a >> 8 & 0xFF), UInt8(a >> 16 & 0xFF), UInt8(a >> 24)]
        do { try dnload(block: 0, cmd) }
        catch { try waitAlive(timeout: 60); try? toIdle(); try dnload(block: 0, cmd) }        // команда адреси безпечна для повтору
    }
    /// Дочекатись, коли пристрій знову стабільно відповідає на запити (після стирання він деякий час «глухий»).
    func waitAlive(timeout: TimeInterval = 240) throws {
        let until = Date().addingTimeInterval(timeout)
        var ok = 0
        while ok < 3 {
            if Date() > until { throw DFUError(message: String(localized: "Пристрій DFU не відповідає після стирання")) }
            if let s = try? getStatus(), s.state != Self.stateDnBusy, s.status == 0 { ok += 1; usleep(200_000) } else { ok = 0; usleep(500_000) }
        }
    }

    /// Стирання всієї флеш-пам'яті. Команда повертається одразу, а саме стирання триває десятки секунд,
    /// і весь цей час пристрій може не відповідати на USB-запити.
    func massErase() throws {
        try toIdle()
        var d: [UInt8] = [0x41]
        try control(0x21, 1, value: 0, data: &d)
        sleep(2)
        try waitAlive()
        try? wait(timeout: 60)
        try waitAlive()
        try toIdle()            // без ABORT після стирання ROM відхиляє перший запис (USB-тайм-аут): перевірено на STM32H7
    }
    func upload(block: UInt16, length: Int) throws -> [UInt8] {
        var d = [UInt8](repeating: 0, count: length)
        let n = try control(0xA1, 2, value: block, data: &d)
        return Array(d.prefix(n))
    }
    /// Вийти з DFU і запустити програму.
    func leave(at addr: UInt32) {
        try? toIdle()                                       // після читання пристрій у dfuUPLOAD-IDLE: DNLOAD там неприпустимий
        try? setAddress(addr)
        try? abort()
        var d: [UInt8] = []
        _ = try? control(0x21, 1, value: 0, data: &d)       // DNLOAD нульової довжини = manifestation
        _ = try? getStatus()                                // пристрій перезавантажується: помилку ігноруємо
    }
}


extension DFUDevice {
    /// Стирання, запис блоками по 1 КБ і перевірка зчитуванням. progress(стадія, частка, чи писати в журнал).
    func program(_ img: HexImage, progress: (String, Double, Bool) -> Void) throws {
        let T = transferSize()
        progress(String(localized: "Розмір блоку DFU: \(T) Б"), 0.07, true)
        // Адреса задається один раз, далі блоки 2, 3, …: адреса = початок + (блок − 2) × T
        try setAddress(img.base)
        var off = 0, block = 2
        while off < img.data.count {
            let n = min(T, img.data.count - off)
            var part = Array(img.data[off..<off + n])
            while part.count % 32 != 0 { part.append(0xFF) }
            try dnload(block: UInt16(block), part)
            off += n; block += 1
            if (block - 2) % 16 == 0 { progress(String(localized: "Запис: \(off / 1024) з \(img.data.count / 1024) КБ"), 0.08 + 0.55 * Double(off) / Double(img.data.count), false) }
        }
        progress("Перевірка запису…", 0.65, true)
        try abort()
        try setAddress(img.base)
        try abort()
        var vo = 0; block = 2
        while vo < img.data.count {
            let n = min(T, img.data.count - vo)
            let got = try upload(block: UInt16(block), length: T)
            if got.count < n || Array(got.prefix(n)) != Array(img.data[vo..<vo + n]) { throw DFUError(message: String(format: loc("Помилка перевірки на адресі 0x%08X. Повторіть прошивання."), img.base + UInt32(vo))) }
            vo += n; block += 1
            if (block - 2) % 16 == 0 { progress(String(localized: "Перевірка: \(vo / 1024) з \(img.data.count / 1024) КБ"), 0.65 + 0.32 * Double(vo) / Double(img.data.count), false) }
        }
        try toIdle()
    }
}

// MARK: - Модель прошивання

@Observable
final class DFUModel {
    var present = false
    var state = "idle"                // idle | running | done | error
    var stage = ""
    var progress = 0.0
    var error: String?
    var log: [String] = []
    @ObservationIgnored private var watching = false

    var running: Bool { state == "running" }

    /// Стежить за появою DFU-пристрою (для підказки на сторінці).
    @MainActor func watch() async {
        guard !watching else { return }
        watching = true; defer { watching = false }
        while !Task.isCancelled {
            present = DFUDevice.isPresent()
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    @MainActor private func set(_ stage: String, _ p: Double? = nil, log l: Bool = true) {
        self.stage = stage; if let p { progress = p }
        if l { log.append(stage); if log.count > 200 { log.removeFirst() } }
    }

    /// Прошивання hex-файлу: стирання всієї флеш-пам'яті, запис, перевірка зчитуванням, запуск.
    @MainActor func flash(hexPath: String) async {
        guard !running else { return }
        state = "running"; error = nil; progress = 0; log = []
        let result: Result<Void, Error> = await Task.detached(priority: .userInitiated) { [self] () -> Result<Void, Error> in
            do {
                await MainActor.run { set("Читання файлу…", 0.01) }
                let text = try String(contentsOfFile: hexPath, encoding: .utf8)
                let img = try IntelHex.parse(text)
                guard img.base >= 0x0800_0000, img.end <= 0x0820_0000 else { throw DFUError(message: String(format: loc("Образ поза межами флеш-пам'яті STM32 (0x%08X…0x%08X). Прошивання скасовано."), img.base, img.end)) }
                await MainActor.run { set(String(format: loc("Образ: %d КБ, адреси 0x%08X…0x%08X"), img.data.count / 1024, img.base, img.end), 0.02) }
                let dev = try DFUDevice()
                try dev.open()
                defer { dev.close() }
                await MainActor.run { set("DFU-пристрій відкрито", 0.03) }
                try dev.toIdle()
                await MainActor.run { set("Стирання флеш-пам'яті (до 1–2 хв)…", 0.05) }
                try dev.massErase()
                try dev.program(img) { stage, p, log in Task { @MainActor in self.set(stage, p, log: log) } }
                await MainActor.run { set("Запуск програми…", 0.98) }
                dev.leave(at: img.base)
                return .success(())
            } catch { return .failure(error) }
        }.value
        switch result {
        case .success: state = "done"; progress = 1; set("Готово: прошивку встановлено, плата перезавантажується")
        case .failure(let e): state = "error"; error = (e as? DFUError)?.message ?? (e as? IntelHex.Failure)?.message ?? e.localizedDescription; log.append(loc("Помилка: ") + (error ?? ""))
        }
    }
}
