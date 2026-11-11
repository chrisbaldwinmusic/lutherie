// swift-tools-version:5.9
import PackageDescription

// Lutherie: a circuit-level guitar pedal and amp simulator.
// PedalCore  - the circuit solver, device models, amp profiles (NAM), cabinets, DSP chain
// PedalUI    - the SwiftUI editor (schematic, knobs, plots) and the Audio Unit
// Lutherie   - the standalone Mac app (also carries the plugin)
// LutherieAU - the Audio Unit v3 extension executable
// PedalCheck - a command-line self-test of the engine
let fast: [SwiftSetting] = [.unsafeFlags(["-Ounchecked", "-wmo"])]

let package = Package(
    name: "Lutherie",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Lutherie", targets: ["Lutherie"]),
        .executable(name: "LutherieAU", targets: ["LutherieAU"]),
        .executable(name: "PedalCheck", targets: ["PedalCheck"]),
        .library(name: "PedalVSTBridge", type: .dynamic, targets: ["PedalVSTBridge"]),
    ],
    targets: [
        .target(name: "PedalCore", swiftSettings: fast),
        .target(name: "PedalUI", dependencies: ["PedalCore"]),
        .executableTarget(name: "Lutherie", dependencies: ["PedalUI", "PedalCore"]),
        .executableTarget(
            name: "LutherieAU",
            dependencies: ["PedalUI", "PedalCore"],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"])]
        ),
        .executableTarget(name: "PedalCheck", dependencies: ["PedalCore"]),
        .target(name: "PedalVSTBridge", dependencies: ["PedalUI", "PedalCore"]),
    ],
    swiftLanguageVersions: [.v5]
)
