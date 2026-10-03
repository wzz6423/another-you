import Foundation

public struct AgentSettingsRepository: Sendable {
    public let dataDirectory: URL
    public var configURL: URL { dataDirectory.appendingPathComponent("config.json") }
    public var piDirectory: URL { dataDirectory.appendingPathComponent("pi", isDirectory: true) }

    public init(
        dataDirectory: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) {
        self.dataDirectory = dataDirectory ?? environment["ANOTHER_YOU_DATA_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(bundleIdentifier == "com.anotheryou.mac.debug" ? "AnotherYouDebug" : "AnotherYou", isDirectory: true)
    }

    public func ensureConfig() throws {
        if FileManager.default.fileExists(atPath: configURL.path) {
            _ = try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: configURL))
            return
        }
        let config: [String: JSONValue] = [
            "version": .number(1), "permissionMode": .string("full-access"),
            "dataDir": .string(dataDirectory.path),
            "privacy": .object(["mode": .string("local-first"), "allowNetwork": .bool(true)]),
            "tools": .object(["filesystem": .bool(true), "shell": .bool(true), "network": .bool(true)])
        ]
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(config).write(to: configURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
    }
}
