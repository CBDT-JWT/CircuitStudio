// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CircuitStudio",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [.library(name: "CircuitCore", targets: ["CircuitCore"])],
    targets: [
        .binaryTarget(name: "NgSpice", path: "Vendor/ngspice/NgSpice.xcframework"),
        .target(name: "CircuitCore", dependencies: ["NgSpice"], linkerSettings: [.linkedLibrary("c++")]),
        .testTarget(name: "CircuitCoreTests", dependencies: ["CircuitCore"])
    ]
)
