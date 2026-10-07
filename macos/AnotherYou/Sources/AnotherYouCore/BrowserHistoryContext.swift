import CryptoKit
import Foundation
import SQLite3

actor BrowserHistoryContext {
    enum Format: Sendable { case chromium, firefox, safari }
    struct Location: Sendable {
        let url: URL
        let name: String
        let format: Format
    }
    let home: URL
    private var offsets: [String: Int] = [:]
    private var lookbackHours: Int?

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) { self.home = home }

    func collect(since: Date, now: Date, samplingRound: Int = 0) async -> WorkContextSourceResult {
        var result = WorkContextSourceResult()
        let deadline = Date().addingTimeInterval(2)
        let locations = locations()
        let hours = Int(now.timeIntervalSince(since) / 3600)
        let paths = Set(locations.map { $0.url.path })
        offsets = hours == lookbackHours ? offsets.filter { paths.contains($0.key) } : [:]
        lookbackHours = hours
        for location in workContextPage(locations, offset: samplingRound, limit: locations.count) {
            guard !Task.isCancelled, Date() < deadline, result.items.count < 160 else {
                result.note("browser-history", status: "partial", message: "浏览记录达到本轮读取预算，部分浏览器或配置目录未纳入。")
                break
            }
            let batch = Self.read(location, since: since, now: now, limit: min(40, 160 - result.items.count), deadline: deadline,
                                  offset: offsets[location.url.path] ?? 0)
            offsets[location.url.path] = batch.nextOffset
            result.items += batch.items
            result.coverage += batch.coverage
        }
        if locations.isEmpty { result.note("browser-history", status: "unavailable", message: "未找到可访问的浏览器历史；未读取网页正文。") }
        return result
    }

    func locations() -> [Location] {
        let manager = FileManager.default
        var result: [Location] = []
        let safari = home.appendingPathComponent("Library/Safari/History.db")
        if manager.fileExists(atPath: safari.path) { result.append(Location(url: safari, name: "Safari", format: .safari)) }
        let safariProfiles = home.appendingPathComponent("Library/Containers/com.apple.Safari/Data/Library/Safari/Profiles")
        for directory in (try? manager.contentsOfDirectory(at: safariProfiles, includingPropertiesForKeys: nil)) ?? [] {
            let file = directory.appendingPathComponent("History.db")
            if manager.fileExists(atPath: file.path) { result.append(Location(url: file, name: "Safari", format: .safari)) }
        }
        let roots = [("Google Chrome", "Google/Chrome"), ("Microsoft Edge", "Microsoft Edge"),
                     ("Brave", "BraveSoftware/Brave-Browser"), ("Chromium", "Chromium"),
                     ("Arc", "Arc/User Data"), ("Vivaldi", "Vivaldi")]
        for (name, path) in roots {
            let root = home.appendingPathComponent("Library/Application Support/" + path)
            let profiles = ((try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.lastPathComponent == "Default" || $0.lastPathComponent.hasPrefix("Profile ") }.sorted { $0.path < $1.path }
            for profile in profiles {
                let file = profile.appendingPathComponent("History")
                if manager.fileExists(atPath: file.path) { result.append(Location(url: file, name: name, format: .chromium)) }
            }
        }
        let firefox = home.appendingPathComponent("Library/Application Support/Firefox/Profiles")
        for profile in ((try? manager.contentsOfDirectory(at: firefox, includingPropertiesForKeys: nil)) ?? []).sorted(by: { $0.path < $1.path }) {
            let file = profile.appendingPathComponent("places.sqlite")
            if manager.fileExists(atPath: file.path) { result.append(Location(url: file, name: "Firefox", format: .firefox)) }
        }
        return result
    }

    static func read(_ location: Location, since: Date, now: Date, limit: Int = 40, deadline: Date = Date().addingTimeInterval(1), offset: Int = 0) -> WorkContextSourceResult {
        var result = WorkContextSourceResult()
        var database: OpaquePointer?
        let opened = sqlite3_open_v2(location.url.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
        defer { if let database { sqlite3_close(database) } }
        guard opened == SQLITE_OK, let database else {
            result.note("browser-history", status: "unavailable", message: "\(location.name) 历史不可访问，可能缺少文件权限或数据库正忙；未推断浏览内容。")
            return result
        }
        sqlite3_busy_timeout(database, 50)
        let budget = HistoryReadBudget(deadline: deadline)
        sqlite3_progress_handler(database, 1000, { context in
            guard let context else { return 1 }
            let budget = Unmanaged<HistoryReadBudget>.fromOpaque(context).takeUnretainedValue()
            return Date() >= budget.deadline || Task.isCancelled ? 1 : 0
        }, Unmanaged.passUnretained(budget).toOpaque())
        defer { sqlite3_progress_handler(database, 0, nil, nil) }
        let table: String
        let dateExpression: String
        switch location.format {
        case .chromium:
            table = "SELECT url, title, last_visit_time FROM urls WHERE last_visit_time BETWEEN ? AND ? ORDER BY last_visit_time DESC LIMIT ? OFFSET ?"
            dateExpression = "chromium"
        case .firefox:
            table = "SELECT url, title, last_visit_date FROM moz_places WHERE last_visit_date BETWEEN ? AND ? ORDER BY last_visit_date DESC LIMIT ? OFFSET ?"
            dateExpression = "firefox"
        case .safari:
            table = "SELECT i.url, v.title, v.visit_time FROM history_visits v JOIN history_items i ON i.id = v.history_item WHERE v.visit_time BETWEEN ? AND ? ORDER BY v.visit_time DESC LIMIT ? OFFSET ?"
            dateExpression = "safari"
        }
        let epochOffset = dateExpression == "chromium" ? 11_644_473_600.0 : dateExpression == "safari" ? -978_307_200.0 : 0
        let multiplier = dateExpression == "safari" ? 1.0 : 1_000_000.0
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, table, -1, &statement, nil) == SQLITE_OK, let statement else {
            result.note("browser-history", status: "unavailable", message: "\(location.name) 历史格式当前不受支持。")
            return result
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, (since.timeIntervalSince1970 + epochOffset) * multiplier)
        sqlite3_bind_double(statement, 2, (now.timeIntervalSince1970 + epochOffset) * multiplier)
        sqlite3_bind_int(statement, 3, Int32(limit + 1))
        sqlite3_bind_int64(statement, 4, Int64(max(0, offset)))
        var seen = Set<String>()
        var visited = 0
        var code = sqlite3_step(statement)
        while code == SQLITE_ROW, !Task.isCancelled, Date() < deadline, visited < limit {
            visited += 1
            let rawURL = sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? ""
            let title = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
            let date = Date(timeIntervalSince1970: sqlite3_column_double(statement, 2) / multiplier - epochOffset)
            if var url = URLComponents(string: rawURL), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
               url.user == nil, url.password == nil, rawURL.utf16.count < 4000, date >= since, date <= now {
                url.fragment = nil
                url.queryItems = url.queryItems?.filter { !["token", "access_token", "api_key", "password", "secret", "code"].contains($0.name.lowercased()) }
                if let address = url.string, seen.insert(address).inserted {
                    let hash = SHA256.hash(data: Data((location.url.path + "\n" + address).utf8)).map { String(format: "%02x", $0) }.joined()
                    result.items.append(WorkContextItem(id: "browser:\(hash)", source: "browser-history",
                        title: title.isEmpty ? address : title, observedAt: date, contentStatus: "metadata-only", details: [
                            "url": .string(address), "appName": .string(location.name), "activity": .string("visited"),
                            "profile": .string(location.url.deletingLastPathComponent().lastPathComponent)
                        ]))
                }
            }
            code = sqlite3_step(statement)
        }
        result.nextOffset = code == SQLITE_DONE ? 0 : offset + visited
        result.note("browser-history", status: code == SQLITE_DONE ? "ok" : "partial",
                    message: "\(location.name)：所选时间内的本机访问记录，仅含标题、网址与访问时间，不包含网页正文或无痕浏览记录。")
        return result
    }
}

private final class HistoryReadBudget {
    let deadline: Date
    init(deadline: Date) { self.deadline = deadline }
}
