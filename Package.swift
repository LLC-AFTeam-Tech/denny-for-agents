// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DennyForAgents",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "AgentCore", targets: ["AgentCore"]),
        .executable(name: "denny-hook", targets: ["DennyHook"]),
        .executable(name: "DennyForAgents", targets: ["DennyForAgents"])
    ],
    targets: [
        .target(name: "AgentCore"),
        .executableTarget(name: "DennyHook", dependencies: ["AgentCore"]),
        .executableTarget(
            name: "DennyForAgents",
            dependencies: ["AgentCore"],
            resources: [.copy("Resources/DennyMotion"), .copy("Resources/DennyActivities")]
        ),
        .testTarget(name: "AgentCoreTests", dependencies: ["AgentCore"])
    ]
)
