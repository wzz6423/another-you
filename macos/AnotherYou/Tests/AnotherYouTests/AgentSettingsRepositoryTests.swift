import XCTest
@testable import AnotherYouCore

final class AgentSettingsRepositoryTests: XCTestCase {
    func testDebugBundleUsesSeparateDataDirectory() {
        let debug = AgentSettingsRepository(environment: [:], bundleIdentifier: "com.anotheryou.mac.debug")
        let release = AgentSettingsRepository(environment: [:], bundleIdentifier: "com.anotheryou.mac")
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        XCTAssertEqual(debug.dataDirectory, support.appendingPathComponent("AnotherYouDebug", isDirectory: true))
        XCTAssertEqual(release.dataDirectory, support.appendingPathComponent("AnotherYou", isDirectory: true))
        XCTAssertNotEqual(debug.configURL, release.configURL)
        XCTAssertNotEqual(debug.piDirectory, release.piDirectory)
    }

    func testUnbundledLaunchPreservesExistingDataDirectory() {
        let repository = AgentSettingsRepository(environment: [:], bundleIdentifier: nil)
        XCTAssertEqual(repository.dataDirectory.lastPathComponent, "AnotherYou")
    }

    func testEnvironmentOverridesBothBundleDefaults() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("中文 data", isDirectory: true)
        for identifier in ["com.anotheryou.mac", "com.anotheryou.mac.debug"] {
            let repository = AgentSettingsRepository(environment: ["ANOTHER_YOU_DATA_DIR": directory.path], bundleIdentifier: identifier)
            XCTAssertEqual(repository.dataDirectory, directory)
        }
    }

    func testExplicitDirectoryTakesPriorityOverEnvironment() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("explicit", isDirectory: true)
        let repository = AgentSettingsRepository(dataDirectory: directory, environment: ["ANOTHER_YOU_DATA_DIR": "/unused"], bundleIdentifier: "com.anotheryou.mac.debug")
        XCTAssertEqual(repository.dataDirectory, directory)
    }
}
