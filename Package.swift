// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "clawdmeter",
    platforms: [.macOS(.v26)],
    targets: [
        .target(name: "ClawdmeterCore"),
        .executableTarget(name: "clawdmeter", dependencies: ["ClawdmeterCore"]),
        .executableTarget(name: "ClawdmeterApp", dependencies: ["ClawdmeterCore"]),
        .testTarget(name: "ClawdmeterCoreTests", dependencies: ["ClawdmeterCore"]),
    ]
)
