// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AgentPulse",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "agentpulse", targets: ["AgentPulse"])
    ],
    targets: [
        .executableTarget(
            name: "AgentPulse",
            path: "Sources/AgentPulse"
        ),
        .testTarget(
            name: "AgentPulseTests",
            dependencies: ["AgentPulse"],
            path: "Tests/AgentPulseTests"
        )
    ]
)
