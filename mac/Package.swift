// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OmniFlowMac",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "OmniFlowMac",
            path: "Sources/OmniFlowMac"
        )
    ]
)
