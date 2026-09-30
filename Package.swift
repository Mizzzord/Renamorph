// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Renamorph",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "RenamorphCore", targets: ["RenamorphCore"]),
        .executable(name: "Renamorph", targets: ["RenamorphApp"]),
        .executable(name: "RenamorphWorker", targets: ["RenamorphWorker"])
    ],
    targets: [
        .target(name: "RenamorphCore"),
        .executableTarget(name: "RenamorphWorker", dependencies: ["RenamorphCore"]),
        .executableTarget(name: "RenamorphApp", dependencies: ["RenamorphCore"]),
        .testTarget(name: "RenamorphCoreTests", dependencies: ["RenamorphCore"]),
        .executableTarget(name: "RenamorphRecoveryProbe", dependencies: ["RenamorphCore"], path: "Tests/RecoveryProbe")
    ]
)
