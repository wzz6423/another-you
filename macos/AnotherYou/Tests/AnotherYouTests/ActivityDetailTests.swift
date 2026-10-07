import Foundation
import XCTest
@testable import AnotherYouCore

final class ActivityDetailTests: XCTestCase {
    private func event(_ id: String, _ fields: [String: JSONValue], at: String = "2026-10-05T01:52:50.000Z") -> AgentEvent {
        AgentEvent(id: id, occurredAt: at, kind: "agent.activity", source: "agent", payload: fields)
    }

    private func usage(_ id: String, run: String? = nil, request: String? = nil, suggestion: String? = nil) -> UsageRecord {
        UsageRecord(id: id, occurredAt: "2026-10-05T01:52:50.000Z", source: "prompt", model: "test-model", outcome: "completed",
            usage: nil, reasoningEffort: "high", toolCalls: [], runId: run, requestId: request, suggestionId: suggestion)
    }

    func testRunIDPreventsMixingLocalAndRemoteExecutionsAtSameTime() {
        let selected = event("selected", ["runId": .string("local"), "requestId": .string("request")])
        let wrong = event("remote", ["runId": .string("remote"), "requestId": .string("request"), "result": .string("wrong")])
        let right = event("local", ["runId": .string("local"), "result": .string("correct"), "appName": .string("Terminal")])
        let detail = ActivityDetail(event: selected, history: [wrong, right], records: [usage("remote", run: "remote", request: "request"), usage("local", run: "local")])
        XCTAssertEqual(detail.usage?.id, "local")
        XCTAssertEqual(detail.value("result"), "correct")
        XCTAssertEqual(detail.application, "Terminal")
        let noMatch = ActivityDetail(event: selected, history: [wrong], records: [usage("remote", run: "remote", request: "request")])
        XCTAssertNil(noMatch.usage)
    }

    func testLegacyRecordsDoNotGuessUsageAndAmbiguousRetriesAreUnknown() throws {
        let legacy = event("old", [:])
        XCTAssertNil(ActivityDetail(event: legacy, history: [], records: [usage("same-time")]).usage)
        let request = event("request", ["requestId": .string("exact")])
        XCTAssertEqual(ActivityDetail(event: request, history: [], records: [usage("record", request: "exact")]).usage?.id, "record")
        let proposal = event("proposal", ["suggestionId": .string("repeat")])
        XCTAssertNil(ActivityDetail(event: proposal, history: [], records: [usage("one", suggestion: "repeat"), usage("two", suggestion: "repeat")]).usage)
        let oldData = Data(#"{"id":"old","occurredAt":"2026-10-05T01:52:50Z","source":"prompt","model":"fixture","outcome":"completed","reasoningEffort":"off","toolCalls":[]}"#.utf8)
        let decoded = try JSONDecoder().decode(UsageRecord.self, from: oldData)
        XCTAssertNil(decoded.runId)
        XCTAssertNil(decoded.durationMs)
    }

    func testToolInputAndResultStayWithTheSelectedToolCall() {
        let selected = event("one-start", ["runId": .string("run"), "toolCallId": .string("one"), "input": .string("ls")])
        let first = event("one-end", ["runId": .string("run"), "toolCallId": .string("one"), "result": .string("files")])
        let second = event("two-end", ["runId": .string("run"), "toolCallId": .string("two"), "result": .string("unrelated")])
        let detail = ActivityDetail(event: selected, history: [second, first], records: [])
        XCTAssertEqual(detail.value("input"), "ls")
        XCTAssertEqual(detail.value("result"), "files")
        let run = event("run-start", ["runId": .string("run")])
        XCTAssertNil(ActivityDetail(event: run, history: [selected], records: []).value("input"))
    }

    func testToolAndContextDurationsUseTheirOwnExecution() {
        let start = event("tool-start", ["runId": .string("run"), "toolCallId": .string("tool"), "phase": .string("started")])
        let end = event("tool-end", ["runId": .string("run"), "toolCallId": .string("tool"), "phase": .string("completed")], at: "2026-10-05T01:52:50.250Z")
        XCTAssertEqual(ActivityDetail(event: start, history: [start, end], records: []).duration, 250)
        XCTAssertNil(ActivityDetail(event: start, history: [start], records: []).duration)
        let context = event("context-start", ["runId": .string("run"), "requestId": .string("context"), "category": .string("context")])
        let contextEnd = event("context-end", ["runId": .string("run"), "requestId": .string("context"), "durationMs": .number(80)])
        XCTAssertEqual(ActivityDetail(event: context, history: [context, contextEnd], records: []).duration, 80)
    }

    func testStructuredAnalysisShowsTheReadableDraftInsteadOfProtocolJSON() {
        XCTAssertEqual(ActivityDetail.readable(#"{"suggest":true,"draft":"First line\nSecond line"}"#), "First line\nSecond line")
        XCTAssertEqual(ActivityDetail.readable(#"{"summary":"Work is blocked","actionable":true}"#), "Work is blocked")
        XCTAssertEqual(ActivityDetail.readable(#"{"content":[{"type":"text","text":"Command output"}]}"#), "Command output")
        XCTAssertEqual(ActivityDetail.readable("plain text"), "plain text")
    }

    func testComputerActionUsesTheActualTargetApplication() {
        let start = event("tool-start", ["runId": .string("run"), "toolCallId": .string("tool"), "toolName": .string("computer_use"), "appName": .string("Terminal")])
        let end = event("tool-end", ["runId": .string("run"), "toolCallId": .string("tool"), "toolName": .string("computer_use"),
            "targetAppName": .string("Preview"), "targetBundleId": .string("com.apple.Preview"), "targetWindowTitle": .string("report.pdf")])
        let detail = ActivityDetail(event: start, history: [start, end], records: [])
        XCTAssertEqual(detail.application, "Preview")
        XCTAssertEqual(detail.bundleID, "com.apple.Preview")
        XCTAssertEqual(detail.windowTitle, "report.pdf")
        XCTAssertNil(ActivityDetail(event: start, history: [start], records: []).application)
    }
}
