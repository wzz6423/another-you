import Foundation
import XCTest
@testable import AnotherYouCore

final class ProtocolChunkTests: XCTestCase {
    private func frame(id: String = "large", index: Int, total: Int, bytes: Data) throws -> Data {
        try JSONEncoder().encode(AgentEvent(id: "\(id):\(index)", occurredAt: "2026-10-02T04:00:00Z", kind: "protocol.chunk", source: "system",
                                          payload: ["eventId": .string(id), "index": .number(Double(index)), "total": .number(Double(total)), "data": .string(bytes.base64EncodedString())]))
    }

    func testLargeUTF8EventDecodesAcrossBoundedJSONLFrames() throws {
        let expected = AgentEvent(id: "large", occurredAt: "2026-10-02T04:00:00Z", kind: "agent.status", source: "system",
                                  payload: ["text": .string(String(repeating: "边界🧪", count: 500_000))])
        let raw = try JSONEncoder().encode(expected)
        XCTAssertGreaterThan(raw.count, 4 * 1024 * 1024)
        let size = 128 * 1024
        let count = (raw.count + size - 1) / size
        var decoder = AgentEventDecoder()
        var framer = JSONLFramer()
        var actual: AgentEvent?
        for index in 0..<count {
            var data = try frame(index: index, total: count, bytes: raw.subdata(in: (index * size)..<min((index + 1) * size, raw.count)))
            data.append(10)
            XCTAssertLessThan(data.count, 4 * 1024 * 1024)
            for line in try framer.append(data) {
                if let result = try decoder.decode(line) { actual = result }
            }
        }
        XCTAssertEqual(actual, expected)
        XCTAssertEqual(try decoder.decode(JSONEncoder().encode(expected)), expected)
    }

    func testOutOfOrderAndMismatchedEventsAreRejected() throws {
        var decoder = AgentEventDecoder()
        XCTAssertThrowsError(try decoder.decode(frame(index: 1, total: 2, bytes: Data("{}".utf8))))
        decoder = AgentEventDecoder()
        XCTAssertNil(try decoder.decode(frame(index: 0, total: 2, bytes: Data("{".utf8))))
        XCTAssertThrowsError(try decoder.decode(frame(id: "other", index: 1, total: 2, bytes: Data("}".utf8))))
    }
    func testMissingDuplicateAndOversizedChunksCannotPoisonLaterMessages() throws {
        let event = AgentEvent(id: "plain", occurredAt: "2026-10-02T04:00:00Z", kind: "agent.status", source: "system", payload: [:])
        let plain = try JSONEncoder().encode(event)
        var decoder = AgentEventDecoder(maximumBytes: 16)
        XCTAssertNil(try decoder.decode(frame(index: 0, total: 2, bytes: Data("{".utf8))))
        XCTAssertThrowsError(try decoder.decode(frame(index: 0, total: 2, bytes: Data("{".utf8))))
        XCTAssertEqual(try decoder.decode(plain), event)
        XCTAssertThrowsError(try decoder.decode(frame(index: 0, total: 1, bytes: Data(repeating: 32, count: 17))))
        XCTAssertEqual(try decoder.decode(plain), event)
        XCTAssertNil(try decoder.decode(frame(index: 0, total: 2, bytes: Data("{".utf8))))
        XCTAssertThrowsError(try decoder.finish())
        XCTAssertEqual(try decoder.decode(plain), event)
        XCTAssertNil(try decoder.decode(frame(index: 0, total: 2, bytes: Data("{".utf8))))
        XCTAssertEqual(try decoder.decode(plain), event)
    }

}

@MainActor
final class ChunkedProcessIntegrationTests: XCTestCase {
    func testRealNodeEncoderAndSwiftClientRestoreLargeStatusBeforeConnecting() async throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("another-you-chunk-process-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("fixture.mjs")
        try """
        import { createInterface } from 'node:readline';
        const { createAgentEvent, encodeEvent } = await import(process.argv[2]);
        const input = createInterface({ input: process.stdin });
        for await (const line of input) {
          const command = JSON.parse(line);
          if (command.op === 'shutdown') break;
          if (command.op === 'status') process.stdout.write(encodeEvent(createAgentEvent({ kind: 'agent.status', source: 'system', payload: { text: '边界🧪'.repeat(500000) } })));
        }
        input.close();
        """.write(to: script, atomically: true, encoding: .utf8)
        var environment = ProcessInfo.processInfo.environment
        environment["ANOTHER_YOU_AGENT_ROOT"] = root.appendingPathComponent("agent-core").path
        let configuration = try SidecarLaunchConfiguration.resolve(configURL: directory.appendingPathComponent("config.json"), environment: environment,
                                                                  resourceDirectory: nil, workingDirectory: root, executableURL: nil)
        let client = ProcessAgentClient(launchConfiguration: SidecarLaunchConfiguration(executable: configuration.executable,
            arguments: ["--experimental-strip-types", script.path, root.appendingPathComponent("agent-core/src/events.ts").absoluteString], workingDirectory: root))
        let connected = expectation(description: "large status connects")
        let restored = expectation(description: "large status restores")
        client.onMessage = { message in
            switch message {
            case .connection(.connected): connected.fulfill()
            case .event(let event):
                XCTAssertEqual(event.kind, "agent.status")
                XCTAssertEqual(event.payload["text"], .string(String(repeating: "边界🧪", count: 500_000)))
                restored.fulfill()
            case .protocolError(let error): XCTFail(error)
            default: break
            }
        }
        try client.start(configURL: directory.appendingPathComponent("config.json"))
        await fulfillment(of: [connected, restored], timeout: 5)
        await client.stop()
    }
}
