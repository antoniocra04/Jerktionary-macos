// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "JerktionaryMac",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "Jerktionary",
            path: "Sources/Jerktionary"
        ),
        .testTarget(
            name: "JerktionaryTests",
            dependencies: ["Jerktionary"],
            path: "Tests/JerktionaryTests"
        )
    ]
)
