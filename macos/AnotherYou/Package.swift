// swift-tools-version: 6.0
import Foundation
import PackageDescription

let minimumMacOSVersion = "14.0"

// Xcode 27's SwiftPM can otherwise record the package deployment target as the
// linked SDK version, which makes macOS 26+ use legacy window chrome. Resolve
// the active SDK through xcrun and pass it to the executable link step.
let linkedSDKVersion: String = {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = ["--sdk", "macosx", "--show-sdk-version"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    do {
        try process.run()
    } catch {
        fatalError("无法启动 xcrun 解析 macOS SDK 版本：\(error)")
    }
    process.waitUntilExit()
    let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard process.terminationStatus == 0, !output.isEmpty else {
        fatalError("无法通过 xcrun 解析 macOS SDK 版本；应用可能使用旧窗口兼容模式")
    }
    return output
}()

let package = Package(
    name: "AnotherYou",
    defaultLocalization: "en",
    platforms: [
        .macOS(minimumMacOSVersion)
    ],
    products: [
        .executable(name: "AnotherYou", targets: ["AnotherYou"])
    ],
    targets: [
        .binaryTarget(
            name: "Sparkle",
            url: "https://github.com/sparkle-project/Sparkle/releases/download/2.9.4/Sparkle-for-Swift-Package-Manager.zip",
            checksum: "cb6fdbdc8884f15d62a616e79face92b08322410fd2d425edc6596ccbf4ba3b0"
        ),
        .target(
            name: "AnotherYouCore",
            dependencies: ["Sparkle"],
            path: "Sources/AnotherYouCore",
            resources: [.process("Resources"), .copy("Markdown")]
        ),
        .executableTarget(
            name: "AnotherYou",
            dependencies: ["AnotherYouCore"],
            path: "Sources/AnotherYou",
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-platform_version",
                    "-Xlinker", "macos",
                    "-Xlinker", minimumMacOSVersion,
                    "-Xlinker", linkedSDKVersion,
                ])
            ]
        ),
        .testTarget(
            name: "AnotherYouTests",
            dependencies: ["AnotherYouCore"],
            path: "Tests/AnotherYouTests"
        )
    ]
)
