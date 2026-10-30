// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MeshKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "MeshCore", targets: ["MeshCore"]),
        .library(name: "BLETransport", targets: ["BLETransport"]),
        .executable(name: "meshsim", targets: ["meshsim"]),
    ],
    targets: [
        // Platform-independent mesh logic: packets, crypto, routing. No Bluetooth here.
        .target(name: "MeshCore"),
        // CoreBluetooth implementation of MeshTransport (iOS + macOS).
        .target(name: "BLETransport", dependencies: ["MeshCore"]),
        // Command-line experiment: delivery rate vs. TTL on a simulated network.
        .executableTarget(name: "meshsim", dependencies: ["MeshCore"]),
        .testTarget(name: "MeshCoreTests", dependencies: ["MeshCore"]),
    ]
)
