// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DennyForAgents",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "AgentCore", targets: ["AgentCore"]),
        .executable(name: "denny-hook", targets: ["DennyHook"])
    ],
    targets: [
        .target(name: "AgentCore"),
        .executableTarget(name: "DennyHook", dependencies: ["AgentCore"]),
        .testTarget(name: "AgentCoreTests", dependencies: ["AgentCore"])
    ]
)
