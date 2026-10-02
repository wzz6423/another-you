import Foundation

struct AgentEventDecoder {
    private let maximumBytes: Int
    private var eventID: String?
    private var nextIndex = 0
    private var expectedCount = 0
    private var buffer = Data()

    init(maximumBytes: Int = 64 * 1024 * 1024) { self.maximumBytes = maximumBytes }

    mutating func decode(_ data: Data) throws -> AgentEvent? {
        do { return try consume(data) }
        catch { reset(); throw error }
    }

    mutating func finish() throws {
        let incomplete = eventID != nil
        reset()
        if incomplete { throw AgentClientError.message("Agent 分块消息不完整。") }
    }

    private mutating func reset() { self = AgentEventDecoder(maximumBytes: maximumBytes) }

    private mutating func consume(_ data: Data) throws -> AgentEvent? {
        let event = try JSONDecoder().decode(AgentEvent.self, from: data)
        guard event.kind == "protocol.chunk" else {
            // 新的完整消息作为恢复边界，不能把之前缺块的内容混入后续事件。
            reset()
            return event
        }
        guard let id = event.payload["eventId"]?.string,
              case .number(let indexValue) = event.payload["index"], let index = Int(exactly: indexValue),
              case .number(let countValue) = event.payload["total"], let count = Int(exactly: countValue),
              count > 0, index >= 0, index < count,
              let encoded = event.payload["data"]?.string, let part = Data(base64Encoded: encoded) else {
            throw AgentClientError.message("Agent 分块消息无效。")
        }
        if index == 0, let eventID, eventID != id { reset() }
        if eventID == nil {
            guard index == 0 else { throw AgentClientError.message("Agent 分块消息顺序无效。") }
            eventID = id
            expectedCount = count
        }
        guard eventID == id, index == nextIndex, count == expectedCount,
              buffer.count + part.count <= maximumBytes else {
            throw AgentClientError.message("Agent 分块消息顺序或大小无效。")
        }
        buffer.append(part)
        nextIndex += 1
        guard nextIndex == expectedCount else { return nil }
        defer { reset() }
        let decoded = try JSONDecoder().decode(AgentEvent.self, from: buffer)
        guard decoded.id == id, decoded.kind != "protocol.chunk" else { throw AgentClientError.message("Agent 分块消息无效。") }
        return decoded
    }
}
