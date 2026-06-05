// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SleepModeSwitcher",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "SleepModeSwitcher",
            path: "Sources/SleepModeSwitcher"
        )
    ]
)
