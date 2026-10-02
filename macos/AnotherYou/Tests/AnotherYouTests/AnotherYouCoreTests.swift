import Foundation
import XCTest
@testable import AnotherYouCore

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("another-you-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func event(_ kind: String, id: String = UUID().uuidString, payload: [String: JSONValue] = [:]) -> AgentEvent {
    AgentEvent(id: id, occurredAt: "2026-10-01T10:00:00.123Z", kind: kind, source: "system", payload: payload)
}

final class JSONLTests: XCTestCase {
    func testSplitUTF8AndMultipleLinesPreserveEvents() throws {
        let first = event("proactive.suggestion", payload: ["title": .string("离开屏幕走走"), "unknown": .array([.bool(true), .number(5), .null])])
        let second = event("agent.status", payload: ["paused": .bool(false)])
        let encoder = JSONEncoder()
        let firstData = try encoder.encode(first)
        let secondData = try encoder.encode(second)
        var bytes = firstData
        bytes.append(contentsOf: [13, 10, 10])
        bytes.append(secondData)
        bytes.append(10)
        var framer = JSONLFramer()
        var frames: [Data] = []
        for byte in bytes { frames += try framer.append(Data([byte])) }
        XCTAssertEqual(try frames.map { try JSONDecoder().decode(AgentEvent.self, from: $0) }, [first, second])
        XCTAssertNil(try framer.finish())
    }

    func testUnterminatedFinalEventIsRetained() throws {
        let expected = event("agent.error", payload: ["message": .string("模型不可用")])
        var framer = JSONLFramer()
        XCTAssertTrue(try framer.append(JSONEncoder().encode(expected)).isEmpty)
        let remaining = try XCTUnwrap(framer.finish())
        XCTAssertEqual(try JSONDecoder().decode(AgentEvent.self, from: remaining), expected)
    }

    func testOversizedAndMalformedMessagesFail() throws {
        var framer = JSONLFramer(maximumLineBytes: 8)
        XCTAssertThrowsError(try framer.append(Data("123456789".utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(AgentEvent.self, from: Data("{\"kind\":42}".utf8)))
    }
}

final class SettingsTests: XCTestCase {
    func testApplicationConfigDoesNotDefineModels() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = AgentSettingsRepository(dataDirectory: directory)
        try repository.ensureConfig()
        let data = try Data(contentsOf: repository.configURL)
        let config = try JSONDecoder().decode([String: JSONValue].self, from: data)
        XCTAssertNil(config["model"])
        XCTAssertEqual(config["permissionMode"], .string("full-access"))
        let attributes = try FileManager.default.attributesOfItem(atPath: repository.configURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testExistingApplicationConfigIsNotOverwritten() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = AgentSettingsRepository(dataDirectory: directory)
        let contents = Data("{\"scheduler\":{\"enabled\":false},\"model\":{\"model\":\"legacy\"}}".utf8)
        try contents.write(to: repository.configURL)
        try repository.ensureConfig()
        XCTAssertEqual(try Data(contentsOf: repository.configURL), contents)
    }

    func testInvalidExistingConfigIsReportedRatherThanOverwritten() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = AgentSettingsRepository(dataDirectory: directory)
        let contents = Data("not valid JSON".utf8)
        try contents.write(to: repository.configURL)
        XCTAssertThrowsError(try repository.ensureConfig())
        XCTAssertEqual(try Data(contentsOf: repository.configURL), contents)
    }

    func testBundleAndExplicitRuntimePaths() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("agent-core", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("src/cli.ts"))
        let runtime = directory.appendingPathComponent("runtime", isDirectory: true)
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        try Data().write(to: directory.appendingPathComponent("runtime-required"))
        try Data("{\"schemaVersion\":1}".utf8).write(to: runtime.appendingPathComponent("manifest.json"))
        let node = runtime.appendingPathComponent("node")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: node)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: node.path)
        let config = directory.appendingPathComponent("config.json")
        let bundled = try SidecarLaunchConfiguration.resolve(configURL: config, environment: [:], resourceDirectory: directory, workingDirectory: directory, executableURL: nil)
        XCTAssertEqual(bundled.executable, node)
        XCTAssertEqual(bundled.arguments.suffix(2), ["--config", config.path])
        let overridden = try SidecarLaunchConfiguration.resolve(configURL: config, environment: ["ANOTHER_YOU_NODE": "/missing/node", "ANOTHER_YOU_AGENT_ROOT": "/missing/agent"], resourceDirectory: directory, workingDirectory: directory, executableURL: nil)
        XCTAssertEqual(overridden.executable, node)
        XCTAssertEqual(overridden.workingDirectory, root)
        let environment = bundled.processEnvironment(["PATH": "/private/tools", "NODE_OPTIONS": "--require /private/config.js", "NODE_PATH": "/private/modules", "DYLD_LIBRARY_PATH": "/private/lib", "HOME": directory.path])
        XCTAssertEqual(environment["PATH"], runtime.path + ":/private/tools")
        XCTAssertEqual(environment["HOME"], directory.path)
        XCTAssertNil(environment["NODE_OPTIONS"])
        XCTAssertNil(environment["NODE_PATH"])
        XCTAssertNil(environment["DYLD_LIBRARY_PATH"])
        try FileManager.default.removeItem(at: node)
        XCTAssertThrowsError(try SidecarLaunchConfiguration.resolve(configURL: config, environment: ["ANOTHER_YOU_NODE": "/bin/sh"], resourceDirectory: directory, workingDirectory: directory, executableURL: nil))
        try FileManager.default.removeItem(at: runtime)
        XCTAssertThrowsError(try SidecarLaunchConfiguration.resolve(configURL: config, environment: ["ANOTHER_YOU_NODE": "/bin/sh"], resourceDirectory: directory, workingDirectory: directory, executableURL: nil))
    }
}

@MainActor
private final class TestAgentClient: AgentClient {
    var onMessage: (@MainActor @Sendable (AgentClientMessage) -> Void)?
    var commands: [[String: JSONValue]] = []
    var startCount = 0
    var sendError: Error?
    func start(configURL: URL) throws { startCount += 1; onMessage?(.connection(.starting)) }
    func send(_ command: [String: JSONValue]) throws {
        if let sendError { throw sendError }
        commands.append(command)
    }
    func stop() async { onMessage?(.connection(.stopped)) }
    func emit(_ event: AgentEvent) { onMessage?(.event(event)) }
    func connected(modelConfigured: Bool = true) {
        onMessage?(.connection(.connected))
        emit(event("agent.status", payload: ["paused": .bool(false), "model": .object(["configured": .bool(modelConfigured), "model": .string("test-model")])]))
    }
}

@MainActor
final class AssistantStoreTests: XCTestCase {
    func testModelPageUsesPiStatusAndRefreshDoesNotWriteConfiguration() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = AgentSettingsRepository(dataDirectory: directory)
        try repository.ensureConfig()
        let original = try Data(contentsOf: repository.configURL)
        let client = TestAgentClient()
        let store = AssistantStore(client: client, repository: repository)
        client.connected()
        client.emit(event("agent.status", payload: ["model": .object([
            "configured": .bool(true), "model": .string("pi-selected"),
            "provider": .string("pi-provider"), "reasoningEffort": .string("high"),
            "message": .string("Pi 配置已读取")
        ])]))
        XCTAssertEqual(store.modelName, "pi-selected")
        XCTAssertEqual(store.modelProvider, "pi-provider")
        XCTAssertEqual(store.reasoningEffort, "high")
        store.refresh()
        XCTAssertEqual(client.commands.last?["op"], .string("status"))
        XCTAssertEqual(try Data(contentsOf: repository.configURL), original)
        await store.shutdown()
    }

    func testUpdateInstallationWaitsForBackgroundAnalysisAndResetsOnDisconnect() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = TestAgentClient()
        let store = AssistantStore(client: client, repository: AgentSettingsRepository(dataDirectory: directory))
        store.connect()
        client.connected()
        XCTAssertTrue(store.canInstallUpdate)
        client.emit(event("proactive.status", payload: ["running": .bool(true)]))
        XCTAssertFalse(store.canInstallUpdate)
        client.emit(event("proactive.status", payload: ["running": .bool(false)]))
        XCTAssertTrue(store.canInstallUpdate)
        client.emit(event("agent.status", payload: ["proactive": .object(["running": .bool(true)])]))
        XCTAssertFalse(store.canInstallUpdate)
        await client.stop()
        XCTAssertTrue(store.canInstallUpdate)
        await store.shutdown()
    }

    func testUpdateInstallationWaitsForPromptsCardsAndShutdown() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = TestAgentClient()
        let store = AssistantStore(client: client, repository: AgentSettingsRepository(dataDirectory: directory))
        store.connect()
        XCTAssertFalse(store.canInstallUpdate)
        client.connected()
        XCTAssertTrue(store.canInstallUpdate)
        XCTAssertTrue(store.ask("生成草稿"))
        XCTAssertFalse(store.canInstallUpdate)
        let requestID = try XCTUnwrap(store.conversation.last?.id)
        client.emit(event("agent.response", payload: ["requestId": .string(requestID), "text": .string("已生成")]))
        XCTAssertTrue(store.canInstallUpdate)
        client.emit(event("proactive.suggestion", id: "s-update", payload: ["title": .string("草稿")]))
        store.apply(.execute, to: try XCTUnwrap(store.cards.first))
        XCTAssertFalse(store.canInstallUpdate)
        client.emit(event("proposal.updated", payload: ["suggestionId": .string("s-update"), "state": .string("running")]))
        XCTAssertFalse(store.canInstallUpdate)
        client.emit(event("proposal.updated", payload: ["suggestionId": .string("s-update"), "state": .string("completed")]))
        XCTAssertTrue(store.canInstallUpdate)
        await store.shutdown()
        XCTAssertFalse(store.canInstallUpdate)
    }

    func testStartsEmptyAndOnlyUpdatesDecisionsAfterAgentAcknowledges() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = TestAgentClient()
        let store = AssistantStore(client: client, repository: AgentSettingsRepository(dataDirectory: directory))
        XCTAssertTrue(store.cards.isEmpty)
        XCTAssertFalse(store.isConnected)
        store.connect()
        client.connected()
        client.emit(event("proactive.suggestion", id: "s1", payload: ["title": .string("整理今天的重点"), "message": .string("创建一个草稿"), "trigger": .string("event")]))
        let card = try XCTUnwrap(store.cards.first)
        store.apply(.execute, to: card)
        XCTAssertEqual(store.cards[0].state, .pending)
        XCTAssertTrue(store.pendingActions.contains("s1"))
        XCTAssertEqual(client.commands.last?["suggestionId"], .string("s1"))
        client.emit(event("proposal.updated", payload: ["suggestionId": .string("s1"), "state": .string("completed"), "text": .string("真实草稿")]))
        XCTAssertEqual(store.cards[0].state, .completed)
        XCTAssertEqual(store.cards[0].text, "真实草稿")
        XCTAssertEqual(store.completedCount, 1)
        XCTAssertFalse(store.pendingActions.contains("s1"))
        store.refresh()
        XCTAssertEqual(store.cards[0].state, .completed)
        await store.shutdown()
    }

    func testPauseAndResumeRequireStatusAcknowledgement() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = TestAgentClient()
        let store = AssistantStore(client: client, repository: AgentSettingsRepository(dataDirectory: directory))
        client.connected()
        store.togglePause()
        XCTAssertFalse(store.paused)
        XCTAssertTrue(store.isChangingPause)
        XCTAssertEqual(client.commands.last?["op"], .string("pause"))
        client.emit(event("agent.status", payload: ["paused": .bool(true)]))
        XCTAssertTrue(store.paused)
        XCTAssertFalse(store.isChangingPause)
        store.togglePause()
        XCTAssertTrue(store.paused)
        XCTAssertEqual(client.commands.last?["op"], .string("resume"))
        client.emit(event("agent.status", payload: ["paused": .bool(false)]))
        XCTAssertFalse(store.paused)
        await store.shutdown()
    }

    func testPromptResponsesCorrelateAndDisconnectDoesNotLeavePendingMessages() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = TestAgentClient()
        let store = AssistantStore(client: client, repository: AgentSettingsRepository(dataDirectory: directory))
        client.connected(modelConfigured: false)
        XCTAssertFalse(store.ask("帮我整理计划"))
        client.connected()
        XCTAssertTrue(store.ask("帮我整理计划"))
        let id = try XCTUnwrap(store.conversation.last?.id)
        client.emit(event("agent.response", payload: ["requestId": .string("another-request"), "text": .string("不属于本次请求")]))
        XCTAssertTrue(store.hasPendingPrompt)
        client.emit(event("agent.response", payload: ["requestId": .string(id), "text": .string("先完成第一项")]))
        XCTAssertEqual(store.conversation.last?.response, "先完成第一项")
        XCTAssertFalse(store.hasPendingPrompt)
        XCTAssertTrue(store.ask("下一步呢"))
        client.onMessage?(.connection(.failed("进程退出")))
        XCTAssertFalse(store.hasPendingPrompt)
        XCTAssertNotNil(store.conversation.last?.error)
        store.connect()
        XCTAssertEqual(client.startCount, 1)
        await store.shutdown()
    }

    func testStatusRestoresRealProposalsAndDeduplicatesHistory() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = TestAgentClient()
        let store = AssistantStore(client: client, repository: AgentSettingsRepository(dataDirectory: directory))
        let suggestion = AgentEvent(id: "s1", occurredAt: ISO8601DateFormatter().string(from: Date()), kind: "proactive.suggestion",
                                    source: "system", payload: ["title": .string("实际建议")])
        client.emit(suggestion)
        let historyValue = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(suggestion))
        client.emit(event("agent.status", payload: [
            "paused": .bool(true),
            "proposals": .array([.object(["id": .string("s1"), "title": .string("实际建议"), "state": .string("snoozed"), "createdAt": .string(suggestion.occurredAt), "snoozedUntil": .string("2026-10-01T10:15:00Z")])]),
            "history": .array([historyValue])
        ]))
        XCTAssertEqual(store.cards.count, 1)
        XCTAssertEqual(store.cards[0].state, .snoozed)
        XCTAssertNotNil(store.nextDueDate)
        XCTAssertEqual(store.activityHistory.count, 1)
        XCTAssertTrue(store.paused)
        await store.shutdown()
    }

    func testSendFailurePreservesCardAndAllowsRetry() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = TestAgentClient()
        let store = AssistantStore(client: client, repository: AgentSettingsRepository(dataDirectory: directory))
        client.connected()
        client.emit(event("proactive.suggestion", id: "s1", payload: ["title": .string("实际建议")]))
        client.sendError = AgentClientError.message("broken pipe")
        store.apply(.later, to: store.cards[0])
        XCTAssertEqual(store.cards[0].state, .pending)
        XCTAssertTrue(store.pendingActions.isEmpty)
        XCTAssertEqual(store.statusMessage, "broken pipe")
        await store.shutdown()
    }
}

@MainActor
final class ProcessAgentClientTests: XCTestCase {
    private func fixture(_ script: String, directory: URL) -> ProcessAgentClient {
        ProcessAgentClient(launchConfiguration: SidecarLaunchConfiguration(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script], workingDirectory: directory))
    }

    func testProcessRoundTripAndSplitJSONL() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = fixture("""
        read -r command
        printf '%s' '{"id":"ready","occurredAt":"2026-10-01T10:00:00Z","kind":"agent.'
        printf '%s\\n' 'status","source":"system","payload":{"paused":false}}'
        while read -r command; do
          case "$command" in
            *prompt*) printf '%s\\n' '{"id":"response","occurredAt":"2026-10-01T10:00:01Z","kind":"agent.response","source":"agent","payload":{"requestId":"r1","text":"真实进程回复"}}' ;;
            *shutdown*) exit 0 ;;
          esac
        done
        """, directory: directory)
        let connected = expectation(description: "status decoded")
        let response = expectation(description: "response correlated")
        client.onMessage = { message in
            if case .connection(.connected) = message { connected.fulfill() }
            if case .event(let event) = message, event.kind == "agent.response" {
                XCTAssertEqual(event.payload["requestId"], .string("r1"))
                XCTAssertEqual(event.payload["text"], .string("真实进程回复"))
                response.fulfill()
            }
        }
        try client.start(configURL: directory.appendingPathComponent("config.json"))
        await fulfillment(of: [connected], timeout: 3)
        try client.send(["op": .string("prompt"), "requestId": .string("r1"), "prompt": .string("你好")])
        await fulfillment(of: [response], timeout: 3)
        await client.stop()
    }

    func testEarlyClosedInputThrowsWithoutTerminatingApp() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = fixture("""
        read -r command
        exec 0<&-
        printf '%s\\n' '{"id":"ready","occurredAt":"2026-10-01T10:00:00Z","kind":"agent.status","source":"system","payload":{}}'
        sleep 1
        """, directory: directory)
        let ready = expectation(description: "closed input is ready")
        client.onMessage = { message in if case .connection(.connected) = message { ready.fulfill() } }
        try client.start(configURL: directory.appendingPathComponent("config.json"))
        await fulfillment(of: [ready], timeout: 3)
        XCTAssertThrowsError(try client.send(["op": .string("status")]))
        await client.stop()
    }

    func testAbnormalExitCanReconnect() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = fixture("read -r command\nexit 7", directory: directory)
        let failed = expectation(description: "exit detected twice")
        failed.expectedFulfillmentCount = 2
        var failureCount = 0
        client.onMessage = { message in
            if case .connection(.failed(let error)) = message {
                XCTAssertTrue(error.contains("7"))
                failureCount += 1
                failed.fulfill()
            }
        }
        let config = directory.appendingPathComponent("config.json")
        try client.start(configURL: config)
        for _ in 0..<100 {
            if failureCount > 0 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(failureCount, 1)
        try client.start(configURL: config)
        await fulfillment(of: [failed], timeout: 3)
        await client.stop()
    }
}

@MainActor
final class NodeSidecarIntegrationTests: XCTestCase {
    func testRealNodeSidecarProposalDecisionPauseAndRestart() async throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let agentRoot = root.appendingPathComponent("agent-core", isDirectory: true)
        guard FileManager.default.fileExists(atPath: agentRoot.appendingPathComponent("node_modules/@earendil-works/pi-agent-core/package.json").path) else {
            throw XCTSkip("真实 sidecar 集成测试需要先运行 npm ci --prefix agent-core --ignore-scripts")
        }
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = AgentSettingsRepository(dataDirectory: directory)
        try repository.ensureConfig()
        var environment = ProcessInfo.processInfo.environment
        environment["ANOTHER_YOU_AGENT_ROOT"] = agentRoot.path
        environment["PI_CODING_AGENT_DIR"] = directory.appendingPathComponent("pi").path
        let launch = try SidecarLaunchConfiguration.resolve(configURL: repository.configURL, environment: environment, resourceDirectory: nil, workingDirectory: root, executableURL: nil)
        let client = ProcessAgentClient(launchConfiguration: launch)
        let store = AssistantStore(client: client, repository: repository)
        store.connect()
        for _ in 0..<200 {
            if store.isConnected && !store.cards.isEmpty { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(store.isConnected, store.statusMessage)
        guard let first = store.cards.first else {
            await store.shutdown()
            XCTFail("真实 Node sidecar 没有生成启动建议：\(store.statusMessage)")
            return
        }
        XCTAssertEqual(first.state, .pending)
        store.apply(.later, to: first)
        for _ in 0..<100 {
            if store.cards.first(where: { $0.id == first.id })?.state == .snoozed { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(store.cards.first(where: { $0.id == first.id })?.state, .snoozed)
        XCTAssertNotNil(store.cards.first(where: { $0.id == first.id })?.snoozedUntil)
        store.togglePause()
        for _ in 0..<100 {
            if store.paused { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(store.paused)
        await store.shutdown()

        let restored = AssistantStore(client: ProcessAgentClient(launchConfiguration: launch), repository: repository)
        restored.connect()
        for _ in 0..<200 {
            if restored.isConnected && restored.paused { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(restored.isConnected, restored.statusMessage)
        XCTAssertTrue(restored.paused)
        XCTAssertEqual(restored.cards.first(where: { $0.id == first.id })?.state, .snoozed)
        XCTAssertEqual(restored.cards.filter { $0.id == first.id }.count, 1)
        XCTAssertFalse(restored.activityHistory.isEmpty)
        await restored.shutdown()
    }
}
