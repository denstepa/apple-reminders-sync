// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MyRemindersSync",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "MyRemindersSync",
            path: "Sources"
        )
    ]
)
