// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MyRemindersSync",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .target(
            name: "SyncLib",
            path: "Sources"
        ),
        .executableTarget(
            name: "MyRemindersSync",
            dependencies: ["SyncLib"],
            path: "App"
        ),
        .testTarget(
            name: "SyncTests",
            dependencies: ["SyncLib"],
            path: "Tests/SyncTests"
        )
    ]
)
