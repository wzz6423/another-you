import Foundation
import Testing
import UniformTypeIdentifiers
@testable import AnotherYouCore

struct ExportTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func record(_ id: String, secondsAgo: Double = 0, model: String = "model-a", tokens: Int? = 100, outcome: String = "completed", effort: String = "high") -> UsageRecord {
        UsageRecord(id: id, occurredAt: ISO8601DateFormatter().string(from: now.addingTimeInterval(-secondsAgo)), source: "prompt", model: model, outcome: outcome,
                    usage: tokens.map { .init(inputTokens: $0, outputTokens: 2, cacheReadTokens: 3, cacheWriteTokens: 4, totalTokens: $0 + 9) }, reasoningEffort: effort,
                    toolCalls: [.init(name: "读取,\"文档\"\n下一行", kind: "tool")])
    }

    private func export(_ records: [UsageRecord], period: UsagePeriod = .day) -> String {
        UsageExport.csv(summary: UsageSummary(records: records, period: period, now: now), period: period, now: now)
    }

    @Test func exportFormatsAreDeclaredWritableDocumentTypes() throws {
        let markdown = try #require(UTType(filenameExtension: "md"))
        #expect(markdown.preferredFilenameExtension == "md")
        #expect(TextExportDocument.writableContentTypes.contains(markdown))
        #expect(TextExportDocument.writableContentTypes.contains(.commaSeparatedText))
        #expect(!markdown.isDynamic)
    }

    @Test func usageIncludesEveryPeriodBoundaryAndExcludesFutureAndDuplicates() {
        for period in UsagePeriod.allCases {
            let recent = record("recent")
            let rows = parsed(export([recent, recent, record("boundary", secondsAgo: period.seconds), record("old", secondsAgo: period.seconds + 1), record("future", secondsAgo: -1)], period: period))
            let requests = rows.filter { $0["row_type"] == "request" }
            #expect(requests.count == 2)
            #expect(Set(requests.compactMap { $0["record_id"] }) == ["recent", "boundary"])
            #expect(rows.allSatisfy { $0["period"] == period.rawValue })
            #expect(rows.allSatisfy { $0["period_end"] == "2027-01-15T08:00:00Z" })
        }
    }

    @Test func usagePreservesUnknownFailedZeroAndAllBreakdowns() {
        let rows = parsed(export([record("failed", outcome: "failed"), record("unknown", model: "unreported-model", tokens: nil, effort: "unknown"), record("zero", tokens: 0)]))
        let summary = rows.first { $0["row_type"] == "summary" }!
        #expect(summary["requests"] == "3")
        #expect(summary["reported_requests"] == "2")
        #expect(summary["unreported_requests"] == "1")
        #expect(summary["failed_requests"] == "1")
        #expect(summary["total_tokens"] == "118")
        #expect(summary["usage_status"] == "partial")
        #expect(rows.first { $0["row_type"] == "model" && $0["model"] == "unreported-model" }?["total_tokens"] == "")
        #expect(rows.first { $0["row_type"] == "request" && $0["record_id"] == "unknown" }?["input_tokens"] == "")
        #expect(rows.first { $0["row_type"] == "request" && $0["record_id"] == "zero" }?["input_tokens"] == "0")
        #expect(rows.first { $0["row_type"] == "reasoning" && $0["reasoning_effort"] == "unknown" }?["requests"] == "1")
        #expect(rows.first { $0["row_type"] == "tool" }?["calls"] == "3")
        #expect(rows.filter { $0["row_type"] == "tool_call" }.count == 3)
    }

    @Test func usageEmptyAndEntirelyUnreportedPeriodsDoNotInventTokenZeros() {
        let empty = parsed(export([]))
        #expect(empty.count == 1)
        #expect(empty[0]["requests"] == "0")
        #expect(empty[0]["total_tokens"] == "")
        #expect(empty[0]["usage_status"] == "no_requests")
        let unknown = parsed(export([record("unknown", tokens: nil)]))
        #expect(unknown[0]["total_tokens"] == "")
        #expect(unknown[0]["usage_status"] == "unreported")
    }

    @Test func usageCSVQuotesMultilineUnicodeAndNeutralizesFormulas() {
        let dangerous = " \t=HYPERLINK(\"https://example.invalid\",\"中文\")\n第二行"
        let csv = export([record("=1+1", model: dangerous)])
        #expect(csv.hasSuffix("\r\n"))
        let rows = parsed(csv)
        #expect(rows.first { $0["row_type"] == "request" }?["model"] == "'" + dangerous)
        #expect(rows.first { $0["row_type"] == "request" }?["record_id"] == "'=1+1")
        #expect(rows.first { $0["row_type"] == "tool" }?["tool_name"] == "读取,\"文档\"\n下一行")
        #expect(rows.allSatisfy { $0.count == UsageExport.columns.count })
    }

    @Test func conversationKeepsFullOrderedMessagesErrorsAndExplicitActivityOnly() throws {
        let session = try #require(ConversationSession(payload: ["id": .string("session"), "title": .string("中文标题\n第二行"), "updatedAt": .string("2026-10-02T08:00:00Z"), "state": .string("failed"), "appName": .string("编辑器")]))
        let messages = (0..<101).map { index in ConversationMessage(id: "request-\(index)", prompt: "问题 \(index)\n```\n四个````", response: index == 100 ? nil : "回复 \(index)", error: index == 100 ? "错误：\"无法连接\"\n请重试" : nil) }
        let history = [
            event("last", kind: "agent.error", at: "2026-10-02T08:00:02Z", payload: ["requestId": .string("request-100"), "message": .string("错误记录")]),
            event("first", kind: "agent.activity", at: "2026-10-02T08:00:00Z", payload: ["conversationId": .string("session"), "category": .string("thinking"), "phase": .string("started"), "text": .string("RAW_REASONING_NOT_EXPORTED")]),
            event("wrong", kind: "agent.response", payload: ["conversationId": .string("another-session"), "requestId": .string("request-1"), "text": .string("OTHER_SESSION_NOT_EXPORTED")]),
            event("no-id", kind: "agent.activity", payload: ["category": .string("execution"), "text": .string("UNLINKED_NOT_EXPORTED")])
        ]
        let text = ConversationExport.markdown(session: session, messages: messages, history: history, now: now)
        #expect(text.contains("\"messageCount\" : 101"))
        #expect(text.contains("\"appName\" : \"编辑器\""))
        #expect(text.contains("### 101\n"))
        #expect(text.contains("`````text\n问题 0\n```\n四个````\n`````"))
        #expect(text.contains("错误：\"无法连接\"\n请重试"))
        #expect(text.contains("错误记录"))
        #expect(!text.contains("RAW_REASONING_NOT_EXPORTED"))
        #expect(!text.contains("OTHER_SESSION_NOT_EXPORTED"))
        #expect(!text.contains("UNLINKED_NOT_EXPORTED"))
        #expect(text.range(of: "\"id\" : \"first\"")!.lowerBound < text.range(of: "\"id\" : \"last\"")!.lowerBound)
    }

    @Test func conversationExportsSnapshotMetadataWithoutImagesTreesOrArbitraryPayload() throws {
        let session = try #require(ConversationSession(payload: ["id": .string("session"), "title": .string("Snapshot")]))
        let attachment = ScreenAttachment(capture: DesktopCapture(imageData: Data("PRIVATE_IMAGE".utf8), mimeType: "image/png", context: ["appName": .string("ChatGPT"), "title": .string("我的窗口"), "tree": .string("PRIVATE_TREE"), "apiKey": .string("PRIVATE_KEY")], mode: .window))
        let message = ConversationMessage(id: "m", prompt: "查看窗口", attachments: [attachment], response: "完成")
        let text = ConversationExport.markdown(session: session, messages: [message], history: [], now: now)
        #expect(text.contains("ChatGPT"))
        #expect(text.contains("我的窗口"))
        for excluded in ["PRIVATE_IMAGE", "PRIVATE_TREE", "PRIVATE_KEY"] { #expect(!text.contains(excluded)) }
        #expect(!ConversationExport.filename(id: "../../secret\n:文件").contains("/"))
    }

    @Test func conversationPreservesForkOriginAndStoredTimestamps() throws {
        let session = try #require(ConversationSession(payload: ["id": .string("branch"), "title": .string("分支"), "createdAt": .string("2026-10-01T08:00:00Z"), "updatedAt": .string("2026-10-02T08:00:00Z"),
                                                               "forkedFrom": .object(["conversationId": .string("parent"), "messageId": .string("fork-point")])]))
        let text = ConversationExport.markdown(session: session, messages: [], history: [], now: now)
        #expect(text.contains("\"createdAt\" : \"2026-10-01T08:00:00Z\""))
        #expect(text.contains("\"updatedAt\" : \"2026-10-02T08:00:00Z\""))
        #expect(text.contains("\"conversationId\" : \"parent\""))
        #expect(text.contains("\"messageId\" : \"fork-point\""))
        #expect(text.contains("\"messageCount\" : 0"))
    }

    @Test func textDocumentsWriteActualUTF8FilesAndPreserveContent() throws {
        let csv = export([record("中文")])
        let session = try #require(ConversationSession(payload: ["id": .string("session"), "title": .string("实际文件")]))
        let markdown = ConversationExport.markdown(session: session, messages: [ConversationMessage(id: "id", prompt: "第一行\n第二行", response: "完整回复")], history: [], now: now)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("another-you-export-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for (filename, text) in [("usage.csv", csv), ("conversation.md", markdown)] {
            let file = directory.appendingPathComponent(filename)
            try TextExportDocument(text: text).data.write(to: file, options: .atomic)
            let read = try String(contentsOf: file, encoding: .utf8)
            #expect(read == text)
        }
        #expect(parsed(try String(contentsOf: directory.appendingPathComponent("usage.csv"), encoding: .utf8)).first { $0["row_type"] == "request" }?["record_id"] == "中文")
    }

    private func event(_ id: String, kind: String, at: String = "2026-10-02T08:00:01Z", payload: [String: JSONValue]) -> AgentEvent {
        AgentEvent(id: id, occurredAt: at, kind: kind, source: "agent", payload: payload)
    }

    private func parsed(_ text: String) -> [[String: String]] {
        var result: [[String]] = [], row: [String] = [], cell = "", quoted = false
        let characters = Array(text)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "\"" {
                if quoted && index + 1 < characters.count && characters[index + 1] == "\"" { cell.append("\""); index += 1 }
                else { quoted.toggle() }
            } else if !quoted && character == "," { row.append(cell); cell = "" }
            else if !quoted && (character == "\n" || character == "\r\n") { row.append(cell); result.append(row); row = []; cell = "" }
            else if !quoted && character == "\r" { }
            else { cell.append(character) }
            index += 1
        }
        guard let header = result.first else { return [] }
        return result.dropFirst().map { Dictionary(uniqueKeysWithValues: zip(header, $0)) }
    }
}
