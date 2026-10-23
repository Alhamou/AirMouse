// swift-tools-version:5.9
// AirMouse — native macOS menu bar app. Build the .app with ./build.sh
import PackageDescription

let package = Package(
    name: "AirMouse",
    platforms: [.macOS(.v13)],  // SMAppService (start at login) needs macOS 13
    targets: [
        .executableTarget(name: "AirMouse", path: "Sources/AirMouse"),
    ]
)
