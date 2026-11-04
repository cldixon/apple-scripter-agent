// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Shared",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "Shared", targets: ["Shared"]),
        .library(name: "AgentCore", targets: ["AgentCore"])
    ],
    targets: [
        .target(name: "Shared"),
        .target(name: "AgentCore"),
        .testTarget(name: "SharedTests", dependencies: ["Shared"]),
        .testTarget(name: "AgentCoreTests", dependencies: ["AgentCore"])
    ]
)
