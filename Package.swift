// swift-tools-version: 6.2
import PackageDescription

// Hot-path code (the emulator core) is built with bounds checks off in release.
let fast: [SwiftSetting] = [.unsafeFlags(["-Ounchecked"], .when(configuration: .release))]
// UI/AppKit/Metal glue stays in Swift 5 language mode (AppKit isolation rules are noisy in 6).
let glue: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "SwiftGB",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "SwiftGB", targets: ["GBAApp"]),
        .executable(name: "gba-harness", targets: ["gba-harness"]),
        .executable(name: "gbaui-harness", targets: ["gbaui-harness"]),
    ],
    targets: [
        .target(name: "GBACore", swiftSettings: fast),
        .target(name: "GBARender", dependencies: ["GBACore"], swiftSettings: glue),
        .target(name: "GBAUI", dependencies: ["GBACore", "GBARender"], swiftSettings: glue),
        .executableTarget(name: "GBAApp", dependencies: ["GBAUI", "GBARender"], swiftSettings: glue),
        .executableTarget(name: "gba-harness", dependencies: ["GBACore"], swiftSettings: fast),
        // Headless tests of the UI layer's engine (session pacing, autosave, rendering); creates no windows and plays no sound.
        .executableTarget(name: "gbaui-harness", dependencies: ["GBACore", "GBARender", "GBAUI"], swiftSettings: glue),
    ]
)
