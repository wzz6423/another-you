import Darwin
import Foundation

public enum AgentClientError: LocalizedError, Sendable {
    case message(String)
    public var errorDescription: String? { if case .message(let message) = self { message } else { nil } }
}

public enum AgentClientMessage: Sendable {
    case event(AgentEvent)
    case connection(ConnectionState)
    case protocolError(String)
}

@MainActor
public protocol AgentClient: AnyObject {
    var onMessage: (@MainActor @Sendable (AgentClientMessage) -> Void)? { get set }
    func start(configURL: URL) throws
    func send(_ command: [String: JSONValue]) throws
    func stop() async
}

public struct JSONLFramer: Sendable {
    private var buffer = Data()
    private let maximumLineBytes: Int

    public init(maximumLineBytes: Int = 4 * 1024 * 1024) { self.maximumLineBytes = maximumLineBytes }

    public mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            guard line.count <= maximumLineBytes else { throw AgentClientError.message("Agent 消息超过大小限制。") }
            if !line.allSatisfy({ $0 == 13 || $0 == 32 || $0 == 9 }) { lines.append(line) }
        }
        guard buffer.count <= maximumLineBytes else { throw AgentClientError.message("Agent 消息超过大小限制。") }
        return lines
    }

    public mutating func finish() throws -> Data? {
        defer { buffer.removeAll() }
        guard !buffer.isEmpty else { return nil }
        return buffer
    }
}

public struct SidecarLaunchConfiguration: Sendable {
    public let executable: URL
    public let arguments: [String]
    public let workingDirectory: URL

    public init(executable: URL, arguments: [String], workingDirectory: URL) {
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
    }

    public static func resolve(
        configURL: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        resourceDirectory: URL? = Bundle.main.resourceURL,
        workingDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        executableURL: URL? = Bundle.main.executableURL
    ) throws -> SidecarLaunchConfiguration {
        let fileManager = FileManager.default
        var roots: [URL] = []
        if let override = environment["ANOTHER_YOU_AGENT_ROOT"] {
            roots = [URL(fileURLWithPath: override, isDirectory: true)]
        } else {
            if let resourceDirectory { roots.append(resourceDirectory.appendingPathComponent("agent-core", isDirectory: true)) }
            for origin in [workingDirectory, executableURL?.deletingLastPathComponent()].compactMap({ $0 }) {
                var parent = origin
                for _ in 0..<8 {
                    roots.append(parent.appendingPathComponent("agent-core", isDirectory: true))
                    parent.deleteLastPathComponent()
                }
            }
        }
        guard let root = roots.first(where: { fileManager.fileExists(atPath: $0.appendingPathComponent("src/cli.ts").path) }) else {
            throw AgentClientError.message("未找到 Agent 运行文件。请使用完整应用，或将 ANOTHER_YOU_AGENT_ROOT 指向 agent-core 目录。")
        }

        var nodePaths: [URL] = []
        if let override = environment["ANOTHER_YOU_NODE"] {
            nodePaths = [URL(fileURLWithPath: override)]
        } else {
            if let resourceDirectory {
                nodePaths += ["runtime/node", "node/bin/node", "node"].map { resourceDirectory.appendingPathComponent($0) }
            }
            nodePaths += (environment["PATH"] ?? "").split(separator: ":").map { URL(fileURLWithPath: String($0)).appendingPathComponent("node") }
            nodePaths += ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"].map { URL(fileURLWithPath: $0) }
        }
        guard let node = nodePaths.first(where: { fileManager.isExecutableFile(atPath: $0.path) && !$0.hasDirectoryPath }) else {
            throw AgentClientError.message("未找到 Node.js 运行时。请使用完整应用，或将 ANOTHER_YOU_NODE 指向 Node.js 22.19 以上版本。")
        }
        return SidecarLaunchConfiguration(
            executable: node,
            arguments: ["--experimental-strip-types", root.appendingPathComponent("src/cli.ts").path, "--stdio", "--config", configURL.path],
            workingDirectory: root
        )
    }
}

private enum SidecarOutput: Sendable {
    case stdout(Data), stderr(Data), stdoutClosed, exited(Int32)
}

@MainActor
public final class ProcessAgentClient: AgentClient {
    public var onMessage: (@MainActor @Sendable (AgentClientMessage) -> Void)?
    private let launchOverride: SidecarLaunchConfiguration?
    private var process: Process?
    private var input: FileHandle?
    private var readerTask: Task<Void, Never>?
    private var startupTask: Task<Void, Never>?
    private var generation = UUID()
    private var framer = JSONLFramer()
    private var stderr = Data()
    private var stdoutClosed = false
    private var exitCode: Int32?
    private var expectedExit = false
    private var receivedStatus = false

    public init(launchConfiguration: SidecarLaunchConfiguration? = nil) { launchOverride = launchConfiguration }

    public func start(configURL: URL) throws {
        guard process == nil else { return }
        let configuration = try launchOverride ?? SidecarLaunchConfiguration.resolve(configURL: configURL)
        let process = Process()
        let inputPipe = Pipe(), outputPipe = Pipe(), errorPipe = Pipe()
        process.executableURL = configuration.executable
        process.arguments = configuration.arguments
        process.currentDirectoryURL = configuration.workingDirectory
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        self.process = process
        input = inputPipe.fileHandleForWriting
        // 子进程可能在输入写入前退出，禁用该管道的 SIGPIPE 可保留应用恢复入口。
        _ = fcntl(inputPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        framer = JSONLFramer()
        stderr = Data()
        exitCode = nil
        stdoutClosed = false
        expectedExit = false
        receivedStatus = false
        generation = UUID()
        let currentGeneration = generation
        let (stream, continuation) = AsyncStream<SidecarOutput>.makeStream()
        process.terminationHandler = { terminated in continuation.yield(.exited(terminated.terminationStatus)) }
        onMessage?(.connection(.starting))
        do { try process.run() }
        catch {
            self.process = nil
            input = nil
            throw AgentClientError.message("无法启动 Agent：\(error.localizedDescription)")
        }
        // 每条管道只有一个读取者，避免跨线程读取将 JSONL 切片乱序。
        Task.detached {
            let handle = outputPipe.fileHandleForReading
            while true {
                let data = handle.availableData
                if data.isEmpty { break }
                continuation.yield(.stdout(data))
            }
            continuation.yield(.stdoutClosed)
            try? handle.close()
        }
        Task.detached {
            let handle = errorPipe.fileHandleForReading
            while true {
                let data = handle.availableData
                if data.isEmpty { break }
                continuation.yield(.stderr(data))
            }
            try? handle.close()
        }
        readerTask = Task { [weak self] in
            for await output in stream {
                guard let self, self.generation == currentGeneration else { break }
                if self.receive(output) { continuation.finish(); break }
            }
        }
        startupTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard !Task.isCancelled, let self, self.generation == currentGeneration, !self.receivedStatus else { return }
            self.onMessage?(.connection(.failed("Agent 在 12 秒内没有回应。请检查 Node.js 版本和运行依赖。")))
            await self.stop(notify: false)
        }
        try send(["op": .string("status")])
    }

    public func send(_ command: [String: JSONValue]) throws {
        guard let process, process.isRunning, let input, !expectedExit else {
            throw AgentClientError.message("Agent 尚未连接，请先重新连接。")
        }
        var data = try JSONEncoder().encode(command)
        data.append(10)
        try input.write(contentsOf: data)
    }

    public func stop() async { await stop(notify: true) }

    private func stop(notify: Bool) async {
        guard let process else { return }
        expectedExit = true
        startupTask?.cancel()
        if process.isRunning {
            try? input?.write(contentsOf: Data("{\"op\":\"shutdown\"}\n".utf8))
        }
        try? input?.close()
        input = nil
        for _ in 0..<40 {
            if !process.isRunning { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        if process.isRunning { process.terminate() }
        for _ in 0..<20 {
            if !process.isRunning { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        readerTask?.cancel()
        self.process = nil
        generation = UUID()
        if notify { onMessage?(.connection(.stopped)) }
    }

    private func receive(_ output: SidecarOutput) -> Bool {
        switch output {
        case .stdout(let data):
            do { for line in try framer.append(data) { decode(line) } }
            catch {
                framer = JSONLFramer()
                onMessage?(.protocolError(error.localizedDescription))
            }
        case .stderr(let data):
            stderr.append(data)
            if stderr.count > 4096 { stderr = Data(stderr.suffix(4096)) }
        case .stdoutClosed:
            if let remaining = try? framer.finish() { decode(remaining) }
            stdoutClosed = true
        case .exited(let code): exitCode = code
        }
        if let exitCode, stdoutClosed {
            startupTask?.cancel()
            process = nil
            input = nil
            if !expectedExit {
                let detail = String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                let message = detail.isEmpty ? "Agent 已退出（\(exitCode)）。可重新连接。" : "Agent 已退出（\(exitCode)）：\(detail)"
                onMessage?(.connection(.failed(message)))
            }
            return true
        }
        return false
    }

    private func decode(_ data: Data) {
        do {
            let event = try JSONDecoder().decode(AgentEvent.self, from: data)
            guard !event.id.isEmpty, event.date != nil else { throw AgentClientError.message("Agent 返回了无效事件。") }
            if event.kind == "agent.status" && !receivedStatus {
                receivedStatus = true
                startupTask?.cancel()
                onMessage?(.connection(.connected))
            }
            onMessage?(.event(event))
        } catch { onMessage?(.protocolError("无法读取 Agent 消息：\(error.localizedDescription)")) }
    }
}
