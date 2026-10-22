import Foundation

/// Розбір device ID ArduPilot: bus_type (3 біти) | bus (5) | address (8) | devtype (8).
struct DevID {
    let raw: Int
    var busType: Int { raw & 0x7 }
    var bus: Int { (raw >> 3) & 0x1F }
    var address: Int { (raw >> 8) & 0xFF }
    var devType: Int { (raw >> 16) & 0xFF }
    var present: Bool { raw != 0 }
    var busName: String {
        switch busType {
        case 1: return "I²C"
        case 2: return "SPI"
        case 3: return "DroneCAN"
        case 4: return "SITL"
        case 5: return "MSP"
        case 6: return "Serial"
        case 7: return "QSPI"
        default: return "?"
        }
    }
    var detail: String {
        busType == 1 ? String(localized: "\(busName), шина \(bus), адреса 0x\(String(address, radix: 16, uppercase: true))") :
        busType == 2 ? String(localized: "\(busName), шина \(bus)") :
        busType == 3 ? String(localized: "\(busName), вузол \(address)") : busName
    }
}

// Таблиці з ArduPilot 4.6 (AP_Compass_Backend.h, AP_Baro_Backend.h, AP_InertialSensor_Backend.h)
let compassTypes: [Int: String] = [
    0x01: "HMC5883", 0x07: "HMC5883", 0x02: "LSM303D", 0x04: "AK8963", 0x05: "BMM150", 0x06: "LSM9DS1",
    0x08: "LIS3MDL", 0x09: "AK09916", 0x0A: "IST8310", 0x0B: "ICM20948", 0x0C: "MMC3416", 0x0D: "QMC5883L",
    0x0E: "MAG3110", 0x0F: "SITL", 0x10: "IST8308", 0x11: "RM3100", 0x12: "RM3100", 0x13: "MMC5983",
    0x14: "AK09918", 0x15: "AK09915", 0x16: "QMC5883P", 0x17: "BMM350", 0x18: "IIS2MDC",
]
let baroTypes: [Int: String] = [
    0x01: "SITL", 0x02: "BMP085", 0x03: "BMP280", 0x04: "BMP388", 0x05: "DPS280", 0x06: "DPS310",
    0x07: "FBM320", 0x08: "ICM20789", 0x09: "KellerLD", 0x0A: "LPS2xH", 0x0B: "MS5611", 0x0C: "SPL06",
    0x0D: "DroneCAN", 0x0E: "MSP", 0x0F: "ICP101XX", 0x10: "ICP201XX", 0x11: "MS5607", 0x12: "MS5837",
    0x13: "MS5637", 0x14: "BMP390", 0x15: "BMP581", 0x16: "SPA06",
]
let imuTypes: [Int: String] = [
    0x09: "BMI160", 0x10: "L3G4200D", 0x11: "LSM303D", 0x12: "BMA180", 0x13: "MPU6000", 0x16: "MPU9250",
    0x17: "IIS328DQ", 0x18: "LSM9DS1", 0x21: "MPU6000", 0x22: "L3GD20", 0x24: "MPU9250", 0x25: "I3G4250D",
    0x26: "LSM9DS1", 0x27: "ICM20789", 0x28: "ICM20689", 0x29: "BMI055", 0x2A: "SITL", 0x2B: "BMI088",
    0x2C: "ICM20948", 0x2D: "ICM20648", 0x2E: "ICM20649", 0x2F: "ICM20602", 0x30: "ICM20601", 0x31: "ADIS1647x",
    0x32: "Serial", 0x33: "ICM40609", 0x34: "ICM42688", 0x35: "ICM42605", 0x36: "ICM40605", 0x37: "IIM42652",
    0x38: "BMI270", 0x39: "BMI085", 0x3A: "ICM42670", 0x3B: "ICM45686", 0x3C: "SCHA63T", 0x3D: "IIM42653",
]

enum SensorKind { case accel, gyro, baro, compass }

struct SensorRow: Identifiable {
    let id: String
    let slot: String
    let name: String       // назва чипа
    let detail: String     // шина/адреса
}

func sensorName(_ id: DevID, _ kind: SensorKind) -> String {
    let table: [Int: String] = kind == .baro ? baroTypes : (kind == .compass ? compassTypes : imuTypes)
    return table[id.devType] ?? String(format: loc("тип 0x%02X"), id.devType)
}

func sensorRows(_ ps: ParamStore, _ kind: SensorKind) -> [SensorRow] {
    let names: [String]
    switch kind {
    case .accel: names = ["INS_ACC_ID", "INS_ACC2_ID", "INS_ACC3_ID"]
    case .gyro: names = ["INS_GYR_ID", "INS_GYR2_ID", "INS_GYR3_ID"]
    case .baro: names = ["BARO1_DEVID", "BARO2_DEVID", "BARO3_DEVID"]
    case .compass: names = ["COMPASS_DEV_ID", "COMPASS_DEV_ID2", "COMPASS_DEV_ID3"]
    }
    return names.enumerated().compactMap { i, n in
        guard let p = ps.params.first(where: { $0.name == n }), Int(p.value) != 0 else { return nil }
        let d = DevID(raw: Int(p.value))
        return SensorRow(id: n, slot: "\(i + 1)", name: sensorName(d, kind), detail: d.detail)
    }
}

/// Дані компаса за слотом (1…3).
struct CompassInfo: Identifiable {
    var id: Int { slot }
    let slot: Int
    let name: String
    let external: Bool
    let orient: Int
    let used: Bool
}

func compasses(_ ps: ParamStore) -> [CompassInfo] {
    func val(_ n: String) -> Double? { ps.params.first { $0.name == n }?.value }
    let ids = ["COMPASS_DEV_ID", "COMPASS_DEV_ID2", "COMPASS_DEV_ID3"]
    let ext = ["COMPASS_EXTERNAL", "COMPASS_EXTERN2", "COMPASS_EXTERN3"]
    let ori = ["COMPASS_ORIENT", "COMPASS_ORIENT2", "COMPASS_ORIENT3"]
    let use = ["COMPASS_USE", "COMPASS_USE2", "COMPASS_USE3"]
    return (0..<3).compactMap { i in
        guard let v = val(ids[i]), Int(v) != 0 else { return nil }
        let d = DevID(raw: Int(v))
        let isExt = (val(ext[i]) ?? 0) != 0 || d.busType == 3
        return CompassInfo(slot: i + 1, name: sensorName(d, .compass), external: isExt, orient: Int(val(ori[i]) ?? 0), used: (val(use[i]) ?? 1) != 0)
    }
}

/// Скільки двигунів на мультикоптері за FRAME_CLASS.
func motorCount(frameClass: Int, vehicle: String?) -> Int {
    switch vehicle ?? "" {
    case "HEXAROTOR": return 6
    case "OCTOROTOR": return 8
    case "TRICOPTER": return 3
    case "DODECAROTOR": return 12
    default: break
    }
    switch frameClass {
    case 2, 5: return 6
    case 3, 4: return 8
    case 7: return 3
    case 12: return 12
    case 14: return 10
    default: return 4
    }
}

enum VehicleKind { case copter(Int), plane, other }
func vehicleKind(_ vehicle: String?, frameClass: Int) -> VehicleKind {
    if (vehicle ?? "").hasPrefix("VTOL") { return .plane }
    switch vehicle ?? "" {
    case "FIXED_WING", "FLAPPING_WING": return .plane
    case "QUADROTOR", "HEXAROTOR", "OCTOROTOR", "TRICOPTER", "COAXIAL", "HELICOPTER", "DODECAROTOR", "DECAROTOR": return .copter(motorCount(frameClass: frameClass, vehicle: vehicle))
    case "": return .other
    default: return .copter(motorCount(frameClass: frameClass, vehicle: vehicle))
    }
}
