import Foundation
import XCTest
@testable import AnotherYouCore

@MainActor
final class ConversationSearchTests: XCTestCase {
    private func session(_ id: String, title: String, appName: String = "Fixture", archived: Bool = false,
                         pinned: Bool = false, updatedAt: String = "2026-10-02T04:00:00Z") throws -> BoardEntry {
        let session = try XCTUnwrap(ConversationSession(payload: [
            "id": .string(id), "title": .string(title), "appName": .string(appName),
            "state": .string("completed"), "archived": .bool(archived), "pinned": .bool(pinned),
            "updatedAt": .string(updatedAt),
            "messages": .array([.object(["id": .string("turn"), "prompt": .string("message-only input"), "response": .string("message-only reply")])])
        ]))
        return BoardEntry(session: session)
    }

    private func proposal(_ id: String, title: String, appName: String = "Fixture", archived: Bool = false,
                          pinned: Bool = false, createdAt: String = "2026-10-02T04:00:00Z") throws -> BoardEntry {
        let proposal = try XCTUnwrap(ProactiveCard(payload: [
            "id": .string(id), "title": .string(title), "state": .string("pending"),
            "archived": .bool(archived), "pinned": .bool(pinned), "createdAt": .string(createdAt),
            "context": .object(["appName": .string(appName)]),
            "summary": .string("message-only summary"), "text": .string("message-only draft")
        ]))
        return BoardEntry(proposal: proposal)
    }

    func testChineseTitleSearchIncludesSessionsAndSuggestions() throws {
        let entries = try [session("session", title: "整理会议记录"), proposal("proposal", title: "准备会议议程"),
                           session("other", title: "周末安排")]
        XCTAssertEqual(BoardEntry.filtered(entries, query: "会议").map(\.id), ["session", "proposal"])
        XCTAssertEqual(BoardEntry.filtered(entries, query: "议程").map(\.id), ["proposal"])
    }

    func testSearchMatchesTitlesAndApplicationNamesIgnoringCaseAndOuterWhitespace() throws {
        let entries = try [session("session", title: "Release checklist", appName: "Visual Studio Code"),
                           proposal("proposal", title: "准备周报", appName: "MAIL"),
                           session("chinese-app", title: "采购清单", appName: "备忘录")]
        XCTAssertEqual(BoardEntry.filtered(entries, query: " \n rElEaSe\t ").map(\.id), ["session"])
        XCTAssertEqual(BoardEntry.filtered(entries, query: " STUDIO ").map(\.id), ["session"])
        XCTAssertEqual(BoardEntry.filtered(entries, query: "mail").map(\.id), ["proposal"])
        XCTAssertEqual(BoardEntry.filtered(entries, query: "备忘录").map(\.id), ["chinese-app"])
    }

    func testEmptyAndWhitespaceQueryRestoreAllEntriesInPinnedOrder() throws {
        let entries = try [session("new", title: "Latest", updatedAt: "2026-10-05T04:00:00Z"),
                           proposal("pinned", title: "Review", pinned: true, createdAt: "2026-10-01T04:00:00Z"),
                           session("old", title: "Earlier", updatedAt: "2026-09-30T04:00:00Z")]
        XCTAssertEqual(BoardEntry.filtered(entries, query: "Review").map(\.id), ["pinned"])
        for query in ["", " \t\n "] {
            XCTAssertEqual(BoardEntry.filtered(entries, query: query).sorted(by: BoardEntry.ordered).map(\.id), ["pinned", "new", "old"])
        }
    }

    func testNoMatchDoesNotSearchMessageOrSuggestionBodies() throws {
        let entries = try [session("session", title: "会话标题"), proposal("proposal", title: "建议标题")]
        XCTAssertTrue(BoardEntry.filtered(entries, query: "不存在").isEmpty)
        XCTAssertTrue(BoardEntry.filtered(entries, query: "message-only").isEmpty)
    }

    func testArchivedMatchesRemainAvailableWithoutChangingArchiveStatus() throws {
        let entries = try [session("active", title: "项目会议"),
                           session("archive", title: "项目总结", archived: true),
                           proposal("archive-proposal", title: "项目建议", archived: true, pinned: true),
                           session("other-archive", title: "阅读笔记", archived: true)]
        let matches = BoardEntry.filtered(entries, query: "项目").sorted(by: BoardEntry.ordered)
        XCTAssertEqual(matches.filter { !$0.archived }.map(\.id), ["active"])
        XCTAssertEqual(matches.filter(\.archived).map(\.id), ["archive-proposal", "archive"])
        XCTAssertEqual(entries.filter(\.archived).map(\.id), ["archive", "archive-proposal", "other-archive"])
    }

    func testFilteredEntriesKeepPinnedOrderWithinColumnsAndApplicationGroups() throws {
        let entries = try [session("new", title: "Project update", appName: "Mail", updatedAt: "2026-10-05T04:00:00Z"),
                           session("pinned-old", title: "Project plan", appName: "Mail", pinned: true, updatedAt: "2026-10-01T04:00:00Z"),
                           proposal("pinned-proposal", title: "Project review", appName: "Notes", pinned: true, createdAt: "2026-10-03T04:00:00Z"),
                           proposal("other", title: "Lunch", appName: "Notes", createdAt: "2026-10-06T04:00:00Z")]
        let matches = BoardEntry.filtered(entries, query: "project").sorted(by: BoardEntry.ordered)
        XCTAssertEqual(matches.map(\.id), ["pinned-proposal", "pinned-old", "new"])
        XCTAssertEqual(matches.filter(\.completed).map(\.id), ["pinned-old", "new"])
        XCTAssertEqual(matches.filter { !$0.completed }.map(\.id), ["pinned-proposal"])
        XCTAssertEqual(matches.filter { $0.appName == "Mail" }.map(\.id), ["pinned-old", "new"])
    }
}
