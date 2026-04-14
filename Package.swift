// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AgentPulse",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "agentpulse", targets: ["AgentPulse"])
    ],
    dependencies: [
        .package(url: "https://github.com/MrKai77/DynamicNotchKit.git", from: "1.1.0")
    ],
    targets: [
        .executableTarget(
            name: "AgentPulse",
            dependencies: [
                .product(name: "DynamicNotchKit", package: "DynamicNotchKit")
            ],
            path: "Sources/AgentPulse"
        ),
        .testTarget(
            name: "AgentPulseTests",
            dependencies: ["AgentPulse"],
            path: "Tests/AgentPulseTests"
        )
    ]
)
