// swift-tools-version: 6.0
import PackageDescription

// No XCTest / swift-testing in the Command Line Tools toolchain, so `swift test`
// is unavailable. AwakeTests is a plain executable: `swift run AwakeTests`.
let package = Package(
    name: "Awake",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "AwakeCore", path: "Sources/AwakeCore"),
        .executableTarget(name: "Awake", dependencies: ["AwakeCore"], path: "Sources/Awake"),
        .executableTarget(name: "AwakeTests", dependencies: ["AwakeCore"], path: "Tests/AwakeTests"),
    ]
)
