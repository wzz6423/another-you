// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AnotherYou",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "AnotherYou", targets: ["AnotherYou"])
    ],
    targets: [
        .target(
            name: "AnotherYouCore",
            path: "Sources/AnotherYouCore"
        ),
        .executableTarget(
            name: "AnotherYou",
            dependencies: ["AnotherYouCore"],
            path: "Sources/AnotherYou"
        ),
        .testTarget(
            name: "AnotherYouTests",
            dependencies: ["AnotherYouCore"],
            path: "Tests/AnotherYouTests"
        )
    ]
)
