import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct TextExportDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.plainText, .commaSeparatedText, UTType(filenameExtension: "md") ?? .plainText]
    var text: String
    var data: Data { Data(text.utf8) }

    init(text: String) { self.text = text }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        self.text = text
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

enum ConversationExport {
    static func markdown(session: ConversationSession, messages: [ConversationMessage], history: [AgentEvent], now: Date) -> String {
        let messageIDs = Set(messages.map(\.id))
        var seen = Set<String>()
        let events = history.filter { event in
            guard event.activityCategory != nil, seen.insert(event.id).inserted else { return false }
            if let id = event.payload["conversationId"]?.string { return id == session.id }
            return event.payload["requestId"]?.string.map { messageIDs.contains($0) } ?? false
        }.sorted { $0.occurredAt == $1.occurredAt ? $0.id < $1.id : $0.occurredAt < $1.occurredAt }
        var metadata: [String: Any] = [
            "id": session.id, "title": session.title, "state": session.state, "archived": session.archived,
            "createdAt": timestamp(session.createdAt), "updatedAt": timestamp(session.updatedAt), "exportedAt": timestamp(now),
            "eventSources": Array(Set(events.map(\.source))).sorted(), "messageCount": messages.count
        ]
        if let appName = session.appName { metadata["appName"] = appName }
        if let origin = session.forkedFrom {
            metadata["forkedFrom"] = ["conversationId": origin.conversationID, "messageId": origin.messageID]
        }
        var sections = ["# Conversation", "## Metadata", jsonBlock(metadata), "## Messages"]
        for (index, message) in messages.enumerated() {
            sections += ["### \(index + 1)", jsonBlock(["requestId": message.id]), "#### User", block(message.prompt)]
            for (attachmentIndex, attachment) in message.attachments.enumerated() {
                var details: [String: Any] = ["mode": attachment.capture.mode.rawValue, "mimeType": attachment.capture.mimeType]
                for key in ["appName", "bundleId", "title"] {
                    if let value = attachment.capture.context[key]?.string { details[key] = value }
                }
                sections += ["#### Snapshot \(attachmentIndex + 1)", jsonBlock(details)]
            }
            if let response = message.response { sections += ["#### Assistant", block(response)] }
            if let error = message.error { sections += ["#### Error", block(error)] }
            if message.isPending { sections += ["Status: pending"] }
        }
        sections += ["## Linked activity", "Only retained events with a matching conversation or request ID are included. Snapshot images and raw reasoning are not exported."]
        for event in events {
            var details: [String: Any] = ["id": event.id, "occurredAt": event.occurredAt, "kind": event.kind, "source": event.source]
            for key in ["requestId", "conversationId", "category", "phase", "toolName", "model"] {
                if let value = event.payload[key]?.string { details[key] = value }
            }
            sections += ["### Activity", jsonBlock(details)]
            // Thinking events expose phases only; never copy arbitrary payloads into a shared export.
            if event.activityCategory != .thinking {
                for key in ["message", "text", "prompt"] {
                    if let value = event.payload[key]?.string { sections += ["#### \(key)", block(value)] }
                }
            }
        }
        return sections.joined(separator: "\n\n") + "\n"
    }

    static func filename(id: String) -> String {
        let safeID = id.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }
        return "conversation-\(String(String.UnicodeScalarView(safeID)).prefix(64)).md"
    }

    private static func jsonBlock(_ value: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return block(String(decoding: data, as: UTF8.self), language: "json")
    }

    private static func block(_ value: String, language: String = "text") -> String {
        let longestRun = value.split(whereSeparator: { $0 != "`" }).map(\.count).max() ?? 0
        let fence = String(repeating: "`", count: max(3, longestRun + 1))
        return "\(fence)\(language)\n\(value)\n\(fence)"
    }

    fileprivate static func timestamp(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
}

enum UsageExport {
    static let columns = [
        "row_type", "period", "period_start", "period_end", "record_id", "occurred_at", "source", "model", "outcome", "usage_status",
        "requests", "reported_requests", "unreported_requests", "failed_requests", "input_tokens", "output_tokens", "cache_read_tokens", "cache_write_tokens", "cache_tokens", "total_tokens", "calls", "tool_kind", "tool_name", "reasoning_effort"
    ]

    static func csv(summary: UsageSummary, period: UsagePeriod, now: Date) -> String {
        let range = ["period": period.rawValue, "period_start": ConversationExport.timestamp(now.addingTimeInterval(-period.seconds)), "period_end": ConversationExport.timestamp(now)]
        var rows: [[String: String]] = []
        func add(_ type: String, _ values: [String: String]) {
            rows.append(range.merging(values) { _, next in next }.merging(["row_type": type]) { _, next in next })
        }
        func totals(_ group: UsageSummary) -> [String: String] {
            var result = ["requests": "\(group.records.count)", "reported_requests": "\(group.knownCount)", "unreported_requests": "\(group.unknownCount)", "failed_requests": "\(group.failedCount)",
                          "usage_status": group.knownCount == 0 ? (group.records.isEmpty ? "no_requests" : "unreported") : (group.unknownCount > 0 ? "partial" : "reported")]
            if group.knownCount > 0 {
                result.merge(["input_tokens": "\(group.inputTokens)", "output_tokens": "\(group.outputTokens)", "cache_tokens": "\(group.cacheTokens)", "total_tokens": "\(group.totalTokens)",
                              "cache_read_tokens": "\(group.records.compactMap(\.usage).reduce(0) { $0 + $1.cacheReadTokens })", "cache_write_tokens": "\(group.records.compactMap(\.usage).reduce(0) { $0 + $1.cacheWriteTokens })"]) { _, next in next }
            }
            return result
        }
        add("summary", totals(summary))
        for (model, records) in Dictionary(grouping: summary.records, by: \.model).sorted(by: { $0.key < $1.key }) {
            var values = totals(UsageSummary(records: records, period: period, now: now))
            values["model"] = model
            add("model", values)
        }
        for (effort, records) in Dictionary(grouping: summary.records, by: \.reasoningEffort).sorted(by: { $0.key < $1.key }) {
            add("reasoning", ["reasoning_effort": effort, "requests": "\(records.count)"])
        }
        let tools = summary.records.flatMap(\.toolCalls)
        for kind in Set(tools.map(\.kind)).sorted() {
            for (name, calls) in Dictionary(grouping: tools.filter { $0.kind == kind }, by: \.name).sorted(by: { $0.key < $1.key }) {
                add("tool", ["tool_kind": kind, "tool_name": name, "calls": "\(calls.count)"])
            }
        }
        for record in summary.records.sorted(by: { $0.occurredAt == $1.occurredAt ? $0.id < $1.id : $0.occurredAt < $1.occurredAt }) {
            var values = ["record_id": record.id, "occurred_at": record.occurredAt, "source": record.source, "model": record.model, "outcome": record.outcome,
                          "reasoning_effort": record.reasoningEffort, "usage_status": record.usage == nil ? "unreported" : "reported", "calls": "\(record.toolCalls.count)"]
            if let usage = record.usage {
                values.merge(["input_tokens": "\(usage.inputTokens)", "output_tokens": "\(usage.outputTokens)", "cache_read_tokens": "\(usage.cacheReadTokens)", "cache_write_tokens": "\(usage.cacheWriteTokens)",
                              "cache_tokens": "\(usage.cacheReadTokens + usage.cacheWriteTokens)", "total_tokens": "\(usage.totalTokens)"]) { _, next in next }
            }
            add("request", values)
            for tool in record.toolCalls {
                add("tool_call", ["record_id": record.id, "occurred_at": record.occurredAt, "tool_kind": tool.kind, "tool_name": tool.name, "calls": "1"])
            }
        }
        return ([columns.map(cell).joined(separator: ",")] + rows.map { row in columns.map { cell(row[$0] ?? "") }.joined(separator: ",") }).joined(separator: "\r\n") + "\r\n"
    }

    private static func cell(_ value: String) -> String {
        let start = value.trimmingCharacters(in: .whitespacesAndNewlines).first
        let protected = start.map { "=+-@".contains($0) } == true || value.first.map { "\t\r\n".contains($0) } == true ? "'" + value : value
        return "\"" + protected.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

@MainActor
struct ConversationExportButton: View {
    @Environment(\.locale) private var locale
    @ObservedObject var store: AssistantStore

    private var session: ConversationSession? {
        store.sessions.first { $0.id == store.selectedConversationID }
    }

    var body: some View {
        LocalExportButton(title: AppLocalization.string("导出会话", locale: locale), contentType: UTType(filenameExtension: "md") ?? .plainText,
                          filename: ConversationExport.filename(id: store.selectedConversationID ?? "")) {
            guard let session else { return "" }
            return ConversationExport.markdown(session: session, messages: store.conversation, history: store.history, now: Date())
        }
        .disabled(session == nil || store.conversation.isEmpty || store.isLoadingConversation || store.hasPendingPrompt || store.conversationActionError != nil)
    }
}

@MainActor
struct UsageExportButton: View {
    @Environment(\.locale) private var locale
    let summary: UsageSummary
    let period: UsagePeriod
    let now: Date

    var body: some View {
        LocalExportButton(title: AppLocalization.string("导出用量", locale: locale), contentType: .commaSeparatedText,
                          filename: "usage-\(period.rawValue)-\(ConversationExport.timestamp(now).prefix(10)).csv") {
            UsageExport.csv(summary: summary, period: period, now: now)
        }
    }
}

@MainActor
private struct LocalExportButton: View {
    @Environment(\.locale) private var locale
    let title: String
    let contentType: UTType
    let filename: String
    let content: () -> String
    // The save panel reads the document while presentation begins, before a nil-to-value state update may be applied.
    @State private var document = TextExportDocument(text: "")
    @State private var presented = false
    @State private var errorMessage: String?

    var body: some View {
        Button(title, systemImage: "square.and.arrow.up") {
            document = TextExportDocument(text: content())
            presented = true
        }
        .fileExporter(isPresented: $presented, document: document, contentType: contentType, defaultFilename: filename) { result in
            if case .failure(let error) = result { errorMessage = error.localizedDescription }
        }
        .alert(AppLocalization.string("导出失败", locale: locale), isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }
}
