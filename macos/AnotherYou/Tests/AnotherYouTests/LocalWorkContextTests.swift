import Foundation
import SQLite3
import XCTest
@testable import AnotherYouCore

final class LocalWorkContextTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("another-you-work-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testReadableDocumentIncludesLongTextAndTruncationRetainsTheEnd() throws {
        let root = try directory()
        let file = root.appendingPathComponent("document.md")
        let text = "开始\n" + String(repeating: "正文😀", count: 9000) + "\n末尾任务"
        try text.write(to: file, atomically: true, encoding: .utf8)
        let item = try XCTUnwrap(WorkDocumentReader.item(file, observedAt: Date()))
        let body = try XCTUnwrap(item.fields["text"]?.string)
        XCTAssertTrue(body.hasPrefix("开始"))
        XCTAssertTrue(body.hasSuffix("末尾任务"))
        XCTAssertFalse(body.contains("�"))
        XCTAssertLessThanOrEqual(body.utf16.count, 24_000)
        XCTAssertEqual(item.fields["contentStatus"], .string("truncated"))
        let small = root.appendingPathComponent("plain.txt")
        try "已完整读取".write(to: small, atomically: true, encoding: .utf8)
        XCTAssertEqual(WorkDocumentReader.item(small, observedAt: Date())?.fields["text"], .string("已完整读取"))
        XCTAssertEqual(WorkDocumentReader.item(small, observedAt: Date())?.fields["contentStatus"], .string("complete"))
    }

    func testGeneratedSecretSymlinkAndNonTextContentAreNotReadAsDocuments() throws {
        let root = try directory()
        for path in [".env", "credentials.json", "secrets.yaml", "node_modules/index.js", ".git/config", "dist/bundle.js"] {
            XCTAssertFalse(WorkDocumentReader.eligible(root.appendingPathComponent(path)), path)
        }
        let file = root.appendingPathComponent("original.md")
        try "原文".write(to: file, atomically: true, encoding: .utf8)
        let link = root.appendingPathComponent("link.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertNil(WorkDocumentReader.item(link, observedAt: Date())?.fields["text"])
        let binary = root.appendingPathComponent("binary.txt")
        try Data([0, 1, 2, 0xff]).write(to: binary)
        XCTAssertEqual(WorkDocumentReader.item(binary, observedAt: Date())?.fields["contentStatus"], .string("metadata-only"))
    }

    func testWorkspaceDiscoveryReadsProjectContextAndUsesSelectedRecency() throws {
        let root = try directory()
        let project = root.appendingPathComponent("project")
        let source = project.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let readme = project.appendingPathComponent("README.md")
        let package = project.appendingPathComponent("package.json")
        let code = source.appendingPathComponent("main.ts")
        for file in [readme, package, code] { try "fixture".write(to: file, atomically: true, encoding: .utf8) }
        let old = Date().addingTimeInterval(-3 * 86400)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: code.path)
        XCTAssertEqual(LocalWorkContextCollector.workspaceRoot(source, home: root)?.path, project.path)
        let daily = LocalWorkContextCollector.workspaceFiles(project, since: Date().addingTimeInterval(-86400))
        XCTAssertTrue(daily.map { $0.resolvingSymlinksInPath().path }.contains(readme.resolvingSymlinksInPath().path))
        XCTAssertFalse(daily.map { $0.resolvingSymlinksInPath().path }.contains(code.resolvingSymlinksInPath().path))
        let weekly = LocalWorkContextCollector.workspaceFiles(project, since: Date().addingTimeInterval(-7 * 86400))
        XCTAssertTrue(weekly.map { $0.resolvingSymlinksInPath().path }.contains(code.resolvingSymlinksInPath().path))
        XCTAssertEqual(weekly.map(\.path).filter { $0 == readme.resolvingSymlinksInPath().path }.count, 1)
    }

    @MainActor
    func testNativeProcessContextReadsFixtureWorkingDirectoryAndOpenDocument() async throws {
        let root = try directory()
        let file = root.appendingPathComponent("open-document.txt")
        try "进程打开的工作文档".write(to: file, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tail")
        process.arguments = ["-f", file.path]
        process.currentDirectoryURL = root
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        let records = WorkProcessReader.processes(pids: [process.processIdentifier], excluding: -1)
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.name, "tail")
        XCTAssertEqual(record.parentPID, ProcessInfo.processInfo.processIdentifier)
        XCTAssertEqual(URL(fileURLWithPath: try XCTUnwrap(record.directory)).resolvingSymlinksInPath(), root.resolvingSymlinksInPath())
        var files: [URL] = []
        for _ in 0..<50 {
            files = WorkProcessReader.openFiles(pid: process.processIdentifier)
            if !files.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(files.map { $0.resolvingSymlinksInPath() }.contains(file.resolvingSymlinksInPath()))
        XCTAssertTrue(WorkProcessReader.processes(pids: [process.processIdentifier]).isEmpty)
    }

    func testSnapshotKeepsMultipleSourcesWithinWireBudgetAndMarksShortenedBodies() throws {
        let now = Date()
        let rows = (0..<100).map { index in
            WorkContextItem(id: "file-\(index)", source: index % 2 == 0 ? "document" : "application", title: "😀\(index)",
                text: String(repeating: "\"\\😀内容\n", count: 6000), observedAt: now)
        }
        let snapshot = WorkContextSourceResult.snapshot([WorkContextSourceResult(items: rows)], lookbackHours: 720)
        let json = try XCTUnwrap(String(data: JSONEncoder().encode(snapshot.content), encoding: .utf8))
        XCTAssertLessThanOrEqual(json.utf16.count, 512_000)
        let items = try XCTUnwrap(snapshot.content["items"]?.array)
        XCTAssertEqual(items.count, 100)
        XCTAssertTrue(items.contains { $0.object?["source"] == .string("application") })
        XCTAssertTrue(items.contains { $0.object?["source"] == .string("document") })
        XCTAssertTrue(items.allSatisfy { $0.object?["contentStatus"] != .string("complete") })
        XCTAssertEqual(snapshot.content["lookbackHours"], .number(720))
        for item in items { XCTAssertLessThanOrEqual(item.object?["text"]?.string?.utf16.count ?? 0, 24_000) }
    }

    func testSamplingRoundsReachRecordsBeyondTheFirstPage() {
        for limit in [12, 32, 64, 240] {
            let records = Array(0..<(limit * 2 + 5))
            let pages = (0..<3).map { workContextPage(records, offset: $0 * limit, limit: limit) }
            XCTAssertTrue(pages.allSatisfy { $0.count == limit })
            XCTAssertEqual(Set(pages.flatMap { $0 }), Set(records))
            XCTAssertEqual(pages[0], Array(records.prefix(limit)))
        }
        XCTAssertTrue(workContextPage([Int](), offset: 12, limit: 12).isEmpty)
        XCTAssertTrue(workContextPage([1], offset: 0, limit: 0).isEmpty)
    }

    func testSourcesResumeIndependentlyAndAdvanceOnlyPastVisitedRecords() {
        var cursor = WorkContextCursor()
        let records = Array(0..<24)
        var visited: [String: Set<Int>] = [:]
        for round in 0..<12 {
            let source = round % 2 == 0 ? "first-app" : "second-app"
            let page = cursor.page(records, source: source, limit: 12)
            let completed = Array(page.prefix(4))
            visited[source, default: []].formUnion(completed)
            cursor.advance(source: source, visited: completed.count, total: records.count)
        }
        XCTAssertEqual(visited["first-app"], Set(records))
        XCTAssertEqual(visited["second-app"], Set(records))
        cursor.advance(source: "first-app", visited: 0, total: records.count)
        XCTAssertEqual(cursor.page(records, source: "first-app", limit: 12), Array(records.prefix(12)))
    }

    func testSnapshotPreservesEverySourceWhenApplicationRecordsExceedTheWireLimit() throws {
        let now = Date()
        let windows = (0..<600).map { WorkContextItem(id: "window-\($0)", source: "application", title: "Window", observedAt: now) }
        let sources = ["process", "workspace", "document", "browser-history"]
        let other = sources.map { WorkContextItem(id: $0, source: $0, title: $0, observedAt: now) }
        let snapshot = WorkContextSourceResult.snapshot([WorkContextSourceResult(items: windows), WorkContextSourceResult(items: other)], lookbackHours: 24)
        let items = try XCTUnwrap(snapshot.content["items"]?.array)
        XCTAssertEqual(items.count, 512)
        XCTAssertEqual(Set(items.compactMap { $0.object?["source"]?.string }), Set(sources + ["application"]))
        XCTAssertTrue(snapshot.content["coverage"]?.array?.contains { $0.object?["status"] == .string("partial") } == true)
    }

    func testBrowserHistoryContinuesBeyondTheFirstPageAndResetsWhenLookbackChanges() async throws {
        let root = try directory()
        let now = Date(timeIntervalSince1970: 1_791_374_400)
        let file = try chromiumHistory(in: root, profile: "Default", now: now, count: 85)
        let before = try Data(contentsOf: file)
        let collector = BrowserHistoryContext(home: root)
        let daily = await collector.collect(since: now.addingTimeInterval(-86400), now: now)
        XCTAssertEqual(daily.items.count, 40)
        XCTAssertTrue(daily.coverage.contains { $0["status"] == .string("partial") })
        var titles = Set<String>()
        for round in 0..<3 {
            let page = await collector.collect(since: now.addingTimeInterval(-7 * 86400), now: now, samplingRound: round)
            XCTAssertLessThanOrEqual(page.items.count, 40)
            if round == 0 { XCTAssertTrue(page.items.contains { $0.fields["title"] == .string("Default-0") }) }
            titles.formUnion(page.items.compactMap { $0.fields["title"]?.string })
        }
        XCTAssertEqual(titles.count, 85)
        XCTAssertEqual(try Data(contentsOf: file), before)
    }

    func testBrowserProfileRotationIncludesProfilesBeyondTheRoundBudget() async throws {
        let root = try directory()
        let now = Date(timeIntervalSince1970: 1_791_374_400)
        for profile in ["Default", "Profile 1", "Profile 2", "Profile 3", "Profile 4"] {
            _ = try chromiumHistory(in: root, profile: profile, now: now, count: 40)
        }
        let collector = BrowserHistoryContext(home: root)
        var titles = Set<String>()
        for round in 0..<2 {
            let page = await collector.collect(since: now.addingTimeInterval(-86400), now: now, samplingRound: round)
            XCTAssertLessThanOrEqual(page.items.count, 160)
            titles.formUnion(page.items.compactMap { $0.fields["title"]?.string })
        }
        XCTAssertEqual(titles.count, 200)
    }

    func testBrowserHistoriesUseCorrectEpochsFilterRecencyAndRemainReadOnly() throws {
        let root = try directory()
        let now = Date(timeIntervalSince1970: 1_791_374_400)
        for (index, format) in [BrowserHistoryContext.Format.chromium, .firefox, .safari].enumerated() {
            let file = root.appendingPathComponent("history-\(index).sqlite")
            var database: OpaquePointer?
            XCTAssertEqual(sqlite3_open(file.path, &database), SQLITE_OK)
            let offset = index == 0 ? 11_644_473_600.0 : index == 2 ? -978_307_200.0 : 0
            let multiplier = index == 2 ? 1.0 : 1_000_000.0
            let current = (now.timeIntervalSince1970 - 60 + offset) * multiplier
            let old = (now.timeIntervalSince1970 - 3 * 86400 + offset) * multiplier
            let sql: String
            if index == 2 {
                sql = "CREATE TABLE history_items(id INTEGER, url TEXT); CREATE TABLE history_visits(history_item INTEGER, title TEXT, visit_time REAL); INSERT INTO history_items VALUES(1,'https://example.test/current?token=private&query=work'),(2,'https://example.test/old'); INSERT INTO history_visits VALUES(1,'Current',\(current)),(2,'Old',\(old));"
            } else {
                let table = index == 0 ? "urls" : "moz_places"
                let date = index == 0 ? "last_visit_time" : "last_visit_date"
                sql = "CREATE TABLE \(table)(url TEXT, title TEXT, \(date) REAL); INSERT INTO \(table) VALUES('https://example.test/current?token=private&query=work','Current',\(current)),('https://example.test/old','Old',\(old));"
            }
            XCTAssertEqual(sqlite3_exec(database, sql, nil, nil, nil), SQLITE_OK)
            sqlite3_close(database)
            let before = try Data(contentsOf: file)
            let location = BrowserHistoryContext.Location(url: file, name: "Fixture", format: format)
            let daily = BrowserHistoryContext.read(location, since: now.addingTimeInterval(-86400), now: now)
            XCTAssertEqual(daily.items.count, 1)
            XCTAssertEqual(daily.items.first?.fields["title"], .string("Current"))
            XCTAssertEqual(daily.items.first?.fields["contentStatus"], .string("metadata-only"))
            XCTAssertNil(daily.items.first?.fields["text"])
            XCTAssertEqual(daily.items.first?.fields["url"], .string("https://example.test/current?query=work"))
            XCTAssertEqual(BrowserHistoryContext.read(location, since: now.addingTimeInterval(-7 * 86400), now: now).items.count, 2)
            XCTAssertEqual(try Data(contentsOf: file), before)
        }
    }

    func testLocalCommandTimeoutAndCancellationCleanUpTheirOwnOutput() async throws {
        let timeout = await runLocalContextCommand("/bin/sleep", arguments: ["10"], timeout: 0.05)
        XCTAssertEqual(timeout?.complete, false)
        let task = Task { await runLocalContextCommand("/bin/sleep", arguments: ["10"]) }
        task.cancel()
        let cancelled = await task.value
        XCTAssertNil(cancelled)
        let root = try directory()
        let query = "kMDItemLastUsedDate >= $time.iso(2026-10-06T00:00:00Z)"
        let spotlight = await runLocalContextCommand("/usr/bin/mdfind", arguments: ["-0", "-onlyin", root.path, query])
        XCTAssertNotNil(spotlight)
    }

    private func chromiumHistory(in home: URL, profile: String, now: Date, count: Int) throws -> URL {
        let file = home.appendingPathComponent("Library/Application Support/Google/Chrome/\(profile)/History")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(file.path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        XCTAssertEqual(sqlite3_exec(database, "CREATE TABLE urls(url TEXT, title TEXT, last_visit_time REAL)", nil, nil, nil), SQLITE_OK)
        for index in 0..<count {
            let age = index < 45 ? Double(index + 1) : Double(3 * 86400 + index)
            let date = (now.timeIntervalSince1970 - age + 11_644_473_600) * 1_000_000
            let sql = "INSERT INTO urls VALUES('https://example.test/\(index)', '\(profile)-\(index)', \(date))"
            XCTAssertEqual(sqlite3_exec(database, sql, nil, nil, nil), SQLITE_OK)
        }
        return file
    }
}
