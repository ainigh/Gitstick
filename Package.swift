// swift-tools-version:5.9
import PackageDescription

var products: [Product] = [
    .library(name: "GitstickCore", targets: ["GitstickCore"]),
    .executable(name: "gitstick", targets: ["gitstick-cli"]),
]
var targets: [Target] = [
    .target(name: "GitstickCore"),
    .executableTarget(name: "gitstick-cli", dependencies: ["GitstickCore"]),
    .testTarget(name: "GitstickCoreTests", dependencies: ["GitstickCore"]),
]

#if os(macOS)
// The menubar app only builds on macOS. The engine + CLI also build on Linux (for CI/tests).
products.append(.executable(name: "Gitstick", targets: ["Gitstick"]))
targets.append(.executableTarget(name: "Gitstick", dependencies: ["GitstickCore"]))
#endif

let package = Package(
    name: "Gitstick",
    platforms: [.macOS(.v13)],
    products: products,
    targets: targets
)
