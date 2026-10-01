import Foundation

public struct AgentSettings: Equatable, Sendable {
    public var endpoint: String
    public var model: String

    public init(endpoint: String = "http://127.0.0.1:11434/v1", model: String = "") {
        self.endpoint = endpoint
        self.model = model
    }

    public func validated() throws -> AgentSettings {
        let endpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URLComponents(string: endpoint),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host?.lowercased(),
              ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw AgentClientError.message("请填写本机模型服务地址，例如 http://127.0.0.1:11434/v1。当前界面仅允许回环地址。")
        }
        guard !model.isEmpty else { throw AgentClientError.message("请填写本地服务中已安装的模型名称。") }
        return AgentSettings(endpoint: endpoint, model: model)
    }
}

public struct AgentSettingsRepository: Sendable {
    public let dataDirectory: URL
    public var configURL: URL { dataDirectory.appendingPathComponent("config.json") }

    public init(dataDirectory: URL? = nil) {
        self.dataDirectory = dataDirectory ?? ProcessInfo.processInfo.environment["ANOTHER_YOU_DATA_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AnotherYou", isDirectory: true)
    }

    public func load() throws -> AgentSettings {
        let config = try existingConfig()
        let model = config["model"]?.object ?? [:]
        let name = model["model"]?.string ?? ""
        return AgentSettings(endpoint: model["endpoint"]?.string ?? "http://127.0.0.1:11434/v1", model: name == "local-default" ? "" : name)
    }

    public func ensureConfig() throws {
        guard !FileManager.default.fileExists(atPath: configURL.path) else { return }
        try writeConfig(settings: nil)
    }

    public func save(_ settings: AgentSettings) throws {
        try writeConfig(settings: settings.validated())
    }

    private func existingConfig() throws -> [String: JSONValue] {
        guard FileManager.default.fileExists(atPath: configURL.path) else { return [:] }
        return try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: configURL))
    }

    private func writeConfig(settings: AgentSettings?) throws {
        var config = try existingConfig()
        config["version"] = .number(1)
        config["dataDir"] = .string(dataDirectory.path)
        if let settings {
            config["model"] = .object([
                "provider": .string("local"), "model": .string(settings.model),
                "endpoint": .string(settings.endpoint), "temperature": .number(0.2)
            ])
            // 本地模型设置不能沿用旧配置中曾授予的远程网络权限。
            var privacy = config["privacy"]?.object ?? [:]
            privacy["mode"] = .string("strict-local")
            privacy["allowNetwork"] = .bool(false)
            privacy["allowedNetworkHosts"] = .array([])
            config["privacy"] = .object(privacy)
            var tools = config["tools"]?.object ?? [:]
            tools["network"] = .bool(false)
            config["tools"] = .object(tools)
        }
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(config).write(to: configURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
    }
}
