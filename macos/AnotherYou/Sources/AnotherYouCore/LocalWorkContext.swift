import AppKit
import Darwin
import Foundation
import PDFKit

struct WorkContextItem: Sendable {
    var fields: [String: JSONValue]

    init(id: String, source: String, title: String, text: String? = nil, observedAt: Date,
         contentStatus: String = "complete", details: [String: JSONValue] = [:]) {
        fields = details.merging(["id": .string(id), "source": .string(source), "title": .string(boundedWorkText(title, limit: 500)),
            "observedAt": .string(ISO8601DateFormatter().string(from: observedAt)), "contentStatus": .string(contentStatus)]) { _, new in new }
        if let text { fields["text"] = .string(text) }
    }
}

struct WorkContextSourceResult: Sendable {
    var items: [WorkContextItem] = []
    var coverage: [[String: JSONValue]] = []
    var nextOffset = 0

    mutating func note(_ source: String, status: String, message: String) {
        coverage.append(["source": .string(source), "status": .string(status), "message": .string(message)])
    }

    static func snapshot(_ results: [Self], lookbackHours: Int) -> ContextSnapshot {
        var items: [JSONValue] = []
        var coverage = results.flatMap(\.coverage)
        var remaining = 480_000
        var omitted = 0
        var seen = Set<String>()
        // 先保留每种来源的记录，再给正文分配预算，避免一个长文档挤掉其他应用。
        let groups = Dictionary(grouping: results.flatMap(\.items)) { $0.fields["source"]?.string ?? "" }
        let sources = groups.keys.sorted()
        let rows = (0..<(groups.values.map(\.count).max() ?? 0)).flatMap { index in
            sources.compactMap { source in groups[source].flatMap { index < $0.count ? $0[index] : nil } }
        }
        for row in rows {
            guard let id = row.fields["id"]?.string, seen.insert(id).inserted else { continue }
            var fields = row.fields
            fields.removeValue(forKey: "text")
            guard let data = try? JSONEncoder().encode(fields), let json = String(data: data, encoding: .utf8),
                  items.count < 512, json.utf16.count < remaining else { omitted += 1; continue }
            remaining -= json.utf16.count + 2
            if row.fields["text"] != nil { fields["contentStatus"] = .string("metadata-only") }
            items.append(.object(fields))
        }
        let texts = Dictionary(rows.compactMap { row -> (String, String)? in
            guard let id = row.fields["id"]?.string, let text = row.fields["text"]?.string else { return nil }
            return (id, text)
        }, uniquingKeysWith: { first, _ in first })
        let statuses = Dictionary(rows.compactMap { row -> (String, JSONValue)? in
            guard let id = row.fields["id"]?.string, let status = row.fields["contentStatus"] else { return nil }
            return (id, status)
        }, uniquingKeysWith: { first, _ in first })
        for index in items.indices {
            guard var fields = items[index].object, let id = fields["id"]?.string, let raw = texts[id], remaining > 200 else { continue }
            let unread = items[index...].filter { $0.object?["id"]?.string.flatMap { texts[$0] } != nil }.count
            let share = max(100, remaining / max(1, unread) - 20)
            var budget = min(24_000, share)
            var text = boundedWorkText(raw, limit: budget)
            func encodedCount(_ value: String) -> Int { (try? JSONEncoder().encode(value)).flatMap { String(data: $0, encoding: .utf8)?.utf16.count } ?? Int.max }
            var size = encodedCount(text)
            while size > share, budget > 50 {
                budget = max(50, budget * share / size - 10)
                text = boundedWorkText(raw, limit: budget)
                size = encodedCount(text)
            }
            guard size + 20 < remaining else { continue }
            fields["text"] = .string(text)
            fields["contentStatus"] = text == raw ? statuses[id] ?? .string("complete") : .string("truncated")
            remaining -= size + 20
            items[index] = .object(fields)
        }
        if omitted > 0 { coverage.append(["source": .string("collection"), "status": .string("partial"), "message": .string("本轮达到记录预算，另有 \(omitted) 条记录未纳入。")]) }
        return ContextSnapshot(status: items.isEmpty ? "unavailable" : "ok", content: [
            "scope": .string("local-work-context"), "lookbackHours": .number(Double(lookbackHours)),
            "items": .array(items), "coverage": .array(coverage.map(JSONValue.object))
        ], message: items.isEmpty ? "当前没有可访问的本机工作上下文" : "已读取本机应用、进程及近期工作来源；具体覆盖范围见各来源状态")
    }
}

func workContextPage<Element>(_ values: [Element], offset: Int, limit: Int) -> [Element] {
    guard !values.isEmpty, limit > 0 else { return [] }
    let start = max(0, offset) % values.count
    return Array((values.dropFirst(start) + values.prefix(start)).prefix(limit))
}

struct WorkContextCursor: Sendable {
    private var offsets: [String: Int] = [:]

    func page<Element>(_ values: [Element], source: String, limit: Int) -> [Element] {
        workContextPage(values, offset: offsets[source] ?? 0, limit: limit)
    }

    mutating func advance(source: String, visited: Int, total: Int) {
        guard visited > 0, total > 0 else { return }
        if offsets[source] == nil, offsets.count >= 512, let evicted = offsets.keys.sorted().first { offsets.removeValue(forKey: evicted) }
        offsets[source] = ((offsets[source] ?? 0) % total + visited) % total
    }
}

func boundedWorkText(_ text: String, limit: Int) -> String {
    guard text.utf16.count > limit else { return text }
    let marker = "\n[…中间内容超出本轮读取预算…]\n"
    let available = max(0, limit - marker.utf16.count)
    let units = Array(text.utf16)
    func decode(_ values: ArraySlice<UInt16>) -> String {
        var values = values
        if let first = values.first, (0xDC00...0xDFFF).contains(first) { values = values.dropFirst() }
        if let last = values.last, (0xD800...0xDBFF).contains(last) { values = values.dropLast() }
        return String(decoding: values, as: UTF16.self)
    }
    if available == 0 { return decode(units.prefix(max(0, limit))) }
    return decode(units.prefix(available * 2 / 3)) + marker + decode(units.suffix(available / 3))
}

struct LocalContextCommandResult: Sendable {
    let data: Data
    let complete: Bool
}

func runLocalContextCommand(_ executable: String, arguments: [String], timeout: TimeInterval = 2,
                            maximumBytes: Int = 256_000) async -> LocalContextCommandResult? {
    guard !Task.isCancelled else { return nil }
    let output = FileManager.default.temporaryDirectory.appendingPathComponent("another-you-context-\(UUID().uuidString)")
    let descriptor = open(output.path, O_CREAT | O_EXCL | O_RDWR, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else { return nil }
    let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = file
    process.standardError = FileHandle.nullDevice
    var environment = ProcessInfo.processInfo.environment
    environment["GIT_OPTIONAL_LOCKS"] = "0"
    environment["GIT_TERMINAL_PROMPT"] = "0"
    environment["GIT_PAGER"] = "cat"
    process.environment = environment
    defer {
        if process.isRunning { kill(process.processIdentifier, SIGKILL); process.waitUntilExit() }
        try? file.close()
        try? FileManager.default.removeItem(at: output)
    }
    do {
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline, !Task.isCancelled {
            if (try? file.offset()) ?? 0 > maximumBytes { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let stopped = process.isRunning
        if stopped { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
        guard !Task.isCancelled else { return nil }
        try file.seek(toOffset: 0)
        let data = try file.read(upToCount: maximumBytes + 1) ?? Data()
        guard process.terminationStatus == 0 || stopped else { return nil }
        return LocalContextCommandResult(data: data.prefix(maximumBytes), complete: !stopped && data.count <= maximumBytes)
    } catch { return nil }
}

struct WorkProcess: Sendable {
    let pid: pid_t
    let parentPID: pid_t
    let name: String
    let executable: String
    let directory: String?
    let startedAt: Date
}

enum WorkProcessReader {
    static func processes(pids selected: [pid_t]? = nil, excluding collector: pid_t = getpid()) -> [WorkProcess] {
        let capacity = 4096
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = pids.withUnsafeMutableBytes { proc_listpids(UInt32(PROC_UID_ONLY), getuid(), $0.baseAddress, Int32($0.count)) }
        let candidates = selected ?? Array(pids.prefix(max(0, Int(count) / MemoryLayout<pid_t>.size)))
        var values: [WorkProcess] = []
        for pid in candidates where pid > 0 && pid != collector {
            guard !Task.isCancelled else { break }
            var info = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info))) > 0, info.pbi_uid == getuid() else { continue }
            var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { continue }
            let executable = String(cString: path)
            let name = URL(fileURLWithPath: executable).lastPathComponent
            var vnode = proc_vnodepathinfo()
            let hasDirectory = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vnode, Int32(MemoryLayout.size(ofValue: vnode))) > 0
            let directory = hasDirectory ? withUnsafeBytes(of: &vnode.pvi_cdir.vip_path) { raw in
                String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
            } : nil
            values.append(WorkProcess(pid: pid, parentPID: pid_t(info.pbi_ppid), name: name, executable: executable,
                directory: directory, startedAt: Date(timeIntervalSince1970: Double(info.pbi_start_tvsec))))
        }
        // 采集器及其 sidecar 的产物不能反过来成为“用户正在做的工作”。
        var excluded: Set<pid_t> = [collector]
        for _ in 0..<8 {
            let children = values.filter { excluded.contains($0.parentPID) || $0.executable.contains("/Another You.app/") || $0.executable.contains("/AnotherYou.app/") }.map(\.pid)
            let previous = excluded.count
            excluded.formUnion(children)
            if excluded.count == previous { break }
        }
        return values.filter { !excluded.contains($0.pid) }.sorted { $0.pid < $1.pid }
    }

    static func openFiles(pid: pid_t, limit: Int = 48) -> [URL] {
        let size = MemoryLayout<proc_fdinfo>.stride
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: 256)
        let bytes = descriptors.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        guard bytes > 0 else { return [] }
        var paths = Set<String>()
        for descriptor in descriptors.prefix(Int(bytes) / size) where descriptor.proc_fdtype == PROX_FDTYPE_VNODE {
            guard paths.count < limit, !Task.isCancelled else { break }
            var info = vnode_fdinfowithpath()
            guard proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, Int32(MemoryLayout.size(ofValue: info))) > 0 else { continue }
            let path = withUnsafeBytes(of: &info.pvip.vip_path) { String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self)) }
            if WorkDocumentReader.eligible(URL(fileURLWithPath: path)) { paths.insert(path) }
        }
        return paths.sorted().map { URL(fileURLWithPath: $0) }
    }
}

enum WorkDocumentReader {
    static let extensions: Set<String> = ["txt", "md", "markdown", "rtf", "pdf", "doc", "docx", "odt", "csv", "tsv", "json", "yaml", "yml", "toml", "mod", "xml", "log", "swift", "ts", "tsx", "js", "jsx", "py", "go", "rs", "java", "kt", "c", "cc", "cpp", "h", "hpp", "sh", "tex", "sql"]
    static let excludedComponents: Set<String> = ["node_modules", "vendor", "pods", "build", "dist", "target", "__pycache__", "caches"]

    static func eligible(_ url: URL) -> Bool {
        let components = url.standardizedFileURL.pathComponents
        guard url.isFileURL, extensions.contains(url.pathExtension.lowercased()),
              !components.contains(where: { $0.hasPrefix(".") || excludedComponents.contains($0.lowercased()) }),
              !url.path.hasPrefix("/System/"), !url.path.hasPrefix("/Applications/"),
              !url.lastPathComponent.lowercased().contains("credentials"), !url.lastPathComponent.lowercased().contains("secret") else { return false }
        if components.contains("Library"), !components.contains("CloudStorage"), !components.contains("Mobile Documents") { return false }
        return true
    }

    static func item(_ url: URL, source: String = "document", observedAt: Date, details: [String: JSONValue] = [:], limit: Int = 24_000) -> WorkContextItem? {
        guard eligible(url), !Task.isCancelled else { return nil }
        var metadata = details
        metadata["path"] = .string(url.path)
        var item = WorkContextItem(id: "file:\(url.standardizedFileURL.path)", source: source, title: url.lastPathComponent,
            observedAt: observedAt, contentStatus: "metadata-only", details: metadata)
        var status = stat()
        guard lstat(url.path, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG, status.st_flags & UInt32(SF_DATALESS) == 0 else { return item }
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW)
        guard descriptor >= 0 else { return item }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        guard fstat(descriptor, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG else { return item }
        let rich = ["pdf", "rtf", "doc", "docx", "odt"].contains(url.pathExtension.lowercased())
        let maximumBytes = rich ? 12_000_000 : 1_000_000
        guard status.st_size <= maximumBytes, let data = try? handle.read(upToCount: maximumBytes + 1), !data.isEmpty else { return item }
        var text: String?
        var complete = data.count <= maximumBytes
        switch url.pathExtension.lowercased() {
        case "pdf":
            if let document = PDFDocument(data: data), !document.isLocked {
                let deadline = Date().addingTimeInterval(1)
                var pages: [String] = []
                var characters = 0
                for index in 0..<document.pageCount {
                    guard !Task.isCancelled, Date() < deadline, characters < 160_000 else { complete = false; break }
                    let page = document.page(at: index)?.string ?? ""
                    pages.append(page); characters += page.utf16.count
                }
                text = pages.joined(separator: "\n")
            }
        case "rtf", "doc", "docx", "odt":
            let type: NSAttributedString.DocumentType = switch url.pathExtension.lowercased() {
            case "rtf": .rtf
            case "doc": .docFormat
            case "docx": .officeOpenXML
            default: .openDocument
            }
            text = try? NSAttributedString(data: data, options: [.documentType: type], documentAttributes: nil).string
        default:
            if data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff]) { text = String(data: data, encoding: .utf16) }
            else if !data.contains(0) { text = String(data: data, encoding: .utf8) }
        }
        guard !Task.isCancelled, let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return item }
        let bounded = boundedWorkText(text, limit: limit)
        item.fields["text"] = .string(bounded)
        item.fields["contentStatus"] = .string(complete && bounded == text ? "complete" : "truncated")
        return item
    }
}

actor LocalWorkContextCollector {
    let home: URL
    private let browserHistory: BrowserHistoryContext
    private var cursor = WorkContextCursor()

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
        browserHistory = BrowserHistoryContext(home: home)
    }

    func collect(lookbackHours: Int, applicationPIDs: [pid_t] = [], now: Date = Date(), samplingRound: Int = 0) async -> [WorkContextSourceResult] {
        let since = now.addingTimeInterval(-Double(lookbackHours) * 3600)
        async let processes = processContext(since: since, now: now, applicationPIDs: Set(applicationPIDs))
        async let documents = recentDocuments(since: since, now: now)
        async let browsing = browserHistory.collect(since: since, now: now, samplingRound: samplingRound)
        return await [processes, documents, browsing]
    }

    func processContext(since: Date, now: Date, applicationPIDs: Set<pid_t> = []) async -> WorkContextSourceResult {
        let deadline = Date().addingTimeInterval(5)
        let processes = WorkProcessReader.processes()
        var result = WorkContextSourceResult()
        var directories = Set<String>()
        var documents = Set<URL>()
        var visitedProcesses = 0
        for process in cursor.page(processes, source: "process", limit: 240) {
            guard !Task.isCancelled, Date() < deadline else { break }
            visitedProcesses += 1
            var details: [String: JSONValue] = ["pid": .number(Double(process.pid)), "parentPID": .number(Double(process.parentPID)),
                "executable": .string(process.executable), "appName": .string(process.name),
                "startedAt": .string(ISO8601DateFormatter().string(from: process.startedAt))]
            if let directory = process.directory { details["workingDirectory"] = .string(directory) }
            result.items.append(WorkContextItem(id: "process:\(process.pid):\(process.startedAt.timeIntervalSince1970)", source: "process",
                title: process.name, observedAt: now, contentStatus: "metadata-only", details: details))
            if let directory = process.directory, directory != home.path, directory != "/", !directory.contains(".app/"),
               !["/System/", "/usr/", "/bin/", "/sbin/", "/Library/"].contains(where: directory.hasPrefix),
               !directory.contains("/Library/"), !directory.contains("/.") {
                directories.insert(directory)
                documents.formUnion(WorkProcessReader.openFiles(pid: process.pid, limit: 12))
            }
            if applicationPIDs.contains(process.pid) { documents.formUnion(WorkProcessReader.openFiles(pid: process.pid, limit: 12)) }
        }
        cursor.advance(source: "process", visited: visitedProcesses, total: processes.count)
        result.note("process", status: processes.count > 240 || Date() >= deadline ? "partial" : "ok", message: "当前用户进程的名称、父进程、启动时间、可访问的工作目录与打开文件；不读取进程内存或环境变量。")
        var roots = Set<URL>()
        for path in directories.sorted() {
            if let root = Self.workspaceRoot(URL(fileURLWithPath: path), home: home) { roots.insert(root) }
        }
        for document in documents {
            if let root = Self.workspaceRoot(document.deletingLastPathComponent(), home: home) { roots.insert(root) }
        }
        var limited = roots.count > 12 || documents.count > 32
        let workspaceDeadline = deadline.addingTimeInterval(-1)
        var visitedRoots = 0
        for root in cursor.page(roots.sorted(by: { $0.path < $1.path }), source: "workspace", limit: 12) {
            guard !Task.isCancelled, Date() < workspaceDeadline else { limited = true; break }
            visitedRoots += 1
            let files = Self.workspaceFiles(root, since: since)
            if files.count > 12 { limited = true }
            var visitedFiles = 0
            let source = "workspace-files:\(root.path)"
            for file in cursor.page(files, source: source, limit: 12) {
                guard !Task.isCancelled, Date() < workspaceDeadline else { limited = true; break }
                visitedFiles += 1
                let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? now
                if let item = WorkDocumentReader.item(file, source: "workspace", observedAt: now,
                    details: ["workingDirectory": .string(root.path), "modifiedAt": .string(ISO8601DateFormatter().string(from: date))], limit: 16_000) { result.items.append(item) }
            }
            cursor.advance(source: source, visited: visitedFiles, total: files.count)
            if Date() < workspaceDeadline, FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path),
               let git = await runLocalContextCommand("/usr/bin/git", arguments: ["--no-pager", "-c", "core.fsmonitor=false", "-C", root.path, "status", "--short", "--untracked-files=normal"], timeout: 0.7, maximumBytes: 12_000),
               let text = String(data: git.data, encoding: .utf8) {
                result.items.append(WorkContextItem(id: "workspace:\(root.path):git", source: "workspace", title: root.lastPathComponent,
                    text: text.isEmpty ? "工作目录没有未提交改动" : text, observedAt: now,
                    contentStatus: git.complete ? "complete" : "truncated", details: ["workingDirectory": .string(root.path), "format": .string("git-status")]))
            }
        }
        cursor.advance(source: "workspace", visited: visitedRoots, total: roots.count)
        var visitedDocuments = 0
        for url in cursor.page(documents.sorted(by: { $0.path < $1.path }), source: "open-document", limit: 32) {
            guard !Task.isCancelled, Date() < deadline else { break }
            visitedDocuments += 1
            if let item = WorkDocumentReader.item(url, observedAt: now, details: ["activity": .string("open-file")]) { result.items.append(item) }
        }
        cursor.advance(source: "open-document", visited: visitedDocuments, total: documents.count)
        result.note("workspace", status: limited || Date() >= deadline ? "partial" : "ok", message: "从运行进程工作目录关联项目，读取项目说明、配置、近期修改文件及 Git 状态；受读取预算与系统权限限制。")
        return result
    }

    static func workspaceRoot(_ directory: URL, home: URL) -> URL? {
        var candidate = directory.standardizedFileURL
        for _ in 0..<8 {
            guard candidate.path != home.path, candidate.path != "/" else { return nil }
            if [".git", "package.json", "pyproject.toml", "Cargo.toml", "go.mod", "Package.swift"].contains(where: {
                FileManager.default.fileExists(atPath: candidate.appendingPathComponent($0).path)
            }) { return candidate }
            candidate.deleteLastPathComponent()
        }
        return nil
    }

    static func workspaceFiles(_ root: URL, since: Date) -> [URL] {
        let directory = root.resolvingSymlinksInPath()
        let names = ["README.md", "README.zh-CN.md", "AGENTS.md", "package.json", "pyproject.toml", "Cargo.toml", "go.mod", "Package.swift"]
        let existing = names.map { directory.appendingPathComponent($0) }.filter { FileManager.default.fileExists(atPath: $0.path) && WorkDocumentReader.eligible($0) }
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return existing }
        var recent: [(URL, Date)] = []
        var scanned = 0
        for case let file as URL in enumerator {
            scanned += 1
            if scanned > 500 || Task.isCancelled { break }
            let values = try? file.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey])
            if values?.isDirectory == true {
                if enumerator.level > 2 || WorkDocumentReader.excludedComponents.contains(file.lastPathComponent.lowercased()) { enumerator.skipDescendants() }
                continue
            }
            if values?.isSymbolicLink != true, WorkDocumentReader.eligible(file), let date = values?.contentModificationDate, date >= since { recent.append((file, date)) }
        }
        let known = Set(existing.map(\.path))
        return existing + recent.sorted { $0.1 > $1.1 }.map(\.0).filter { !known.contains($0.path) }
    }

    func recentDocuments(since: Date, now: Date) async -> WorkContextSourceResult {
        let deadline = Date().addingTimeInterval(5)
        var result = WorkContextSourceResult()
        let date = ISO8601DateFormatter().string(from: since)
        let query = "(kMDItemLastUsedDate >= $time.iso(\(date)) || kMDItemFSContentChangeDate >= $time.iso(\(date))) && kMDItemContentTypeTree == 'public.data'"
        guard let command = await runLocalContextCommand("/usr/bin/mdfind", arguments: ["-0", "-onlyin", home.path, query], maximumBytes: 512_000) else {
            result.note("document", status: "unavailable", message: "本机近期文件索引当前不可访问。")
            return result
        }
        let paths = command.data.split(separator: 0).prefix(command.complete ? Int.max : max(0, command.data.split(separator: 0).count - 1))
        var candidates: [(URL, Date)] = []
        let metadataDeadline = min(deadline, Date().addingTimeInterval(2))
        var visitedPaths = 0
        for path in cursor.page(Array(paths), source: "recent-path", limit: 4000) {
            guard !Task.isCancelled, Date() < metadataDeadline else { break }
            visitedPaths += 1
            let url = URL(fileURLWithPath: String(decoding: path, as: UTF8.self))
            guard WorkDocumentReader.eligible(url) else { continue }
            let metadata = NSMetadataItem(url: url)
            let used = metadata?.value(forAttribute: "kMDItemLastUsedDate") as? Date
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            guard let observed = [used, modified].compactMap({ $0 }).max(), observed >= since, observed <= now else { continue }
            candidates.append((url, observed))
        }
        cursor.advance(source: "recent-path", visited: visitedPaths, total: paths.count)
        var visitedDocuments = 0
        for (url, date) in cursor.page(candidates.sorted(by: { $0.1 > $1.1 }), source: "recent-document", limit: 64) {
            guard !Task.isCancelled, Date() < deadline else { break }
            visitedDocuments += 1
            if let item = WorkDocumentReader.item(url, observedAt: date, details: ["activity": .string("recent-open-or-edit")]) { result.items.append(item) }
        }
        cursor.advance(source: "recent-document", visited: visitedDocuments, total: candidates.count)
        result.note("document", status: !command.complete || visitedPaths < paths.count || visitedDocuments < candidates.count ? "partial" : "ok",
                    message: "系统索引中所选时间内打开或修改的本机文件，最多 64 个；只读取已下载、可提取文本的文件，其他记录仅含元数据。")
        return result
    }
}
