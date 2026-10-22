// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "ArduTune",
    platforms: [.macOS("15.0")],
    targets: [ .executableTarget(name: "ArduTune", path: "Sources/ArduTune") ]
)
