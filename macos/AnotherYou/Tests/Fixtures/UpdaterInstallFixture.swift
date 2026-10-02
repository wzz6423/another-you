import AppKit
import Combine
import CryptoKit
import Foundation
import Sparkle

@MainActor
private final class FixtureLog {
    let root: URL
    init(root: URL) { self.root = root }

    func record(_ stage: String, _ detail: String = "") {
        let value: [String: Any] = ["stage": stage, "detail": detail, "pid": getpid(), "time": Date().timeIntervalSince1970]
        guard let data = try? JSONSerialization.data(withJSONObject: value) else { return }
        let url = root.appendingPathComponent("events.jsonl")
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        try? handle.seekToEnd()
        try? handle.write(contentsOf: data + Data([10]))
    }
}

@MainActor
private final class FixtureUserDriver: SPUStandardUserDriver {
    let log: FixtureLog
    init(log: FixtureLog) {
        self.log = log
        super.init(hostBundle: .main, delegate: nil)
    }

    override func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        let error = error as NSError
        log.record("sparkle-error", "\(error.domain):\(error.code):\(error.localizedDescription)")
        acknowledgement()
    }

    override func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
                                  reply: @escaping (SPUUserUpdateChoice) -> Void) {
        log.record("unexpected-prompt", appcastItem.versionString)
        reply(.dismiss)
    }
}

@MainActor
private final class FixtureDelegate: NSObject, NSApplicationDelegate {
    let log: FixtureLog
    var terminating = false
    init(log: FixtureLog) { self.log = log }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateNow }
        terminating = true
        log.record("shutdown-began")
        Task {
            try? await Task.sleep(for: .milliseconds(100))
            log.record("shutdown-complete")
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
@MainActor
struct UpdaterInstallFixture {
    static func main() throws {
        let arguments = CommandLine.arguments
        if arguments.count == 3, arguments[1] == "--generate-key" {
            let key = Curve25519.Signing.PrivateKey()
            try key.rawRepresentation.write(to: URL(fileURLWithPath: arguments[2]))
            print(key.publicKey.rawRepresentation.base64EncodedString())
            return
        }
        if arguments.count == 4, arguments[1] == "--sign" {
            let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(contentsOf: URL(fileURLWithPath: arguments[2])))
            print(try key.signature(for: Data(contentsOf: URL(fileURLWithPath: arguments[3]))).base64EncodedString())
            return
        }
        guard let rootPath = Bundle.main.object(forInfoDictionaryKey: "AnotherYouFixtureRoot") as? String,
              let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              let feedURL = URL(string: feed), feedURL.host == "127.0.0.1", feedURL.scheme == "http" else { return }
        let root = URL(fileURLWithPath: rootPath)
        let log = FixtureLog(root: root)
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        log.record("launch", build)
        if build == "2" {
            let marker: [String: Any] = ["build": build, "pid": getpid(), "bundle": Bundle.main.bundleURL.path]
            try JSONSerialization.data(withJSONObject: marker).write(to: root.appendingPathComponent("relaunched.json"), options: .atomic)
            return
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let delegate = FixtureDelegate(log: log)
        app.delegate = delegate
        let userDriver = FixtureUserDriver(log: log)
        // Only this disposable test host bypasses HTTPS validation; release entry points validate Bundle configuration.
        let fallback = (Bundle.main.object(forInfoDictionaryKey: "AnotherYouFixtureFallbackFeed") as? String).flatMap(URL.init(string:))
        let updater = UpdateController(configuration: UpdateConfiguration(primaryFeed: feedURL, fallbackFeed: fallback),
                                       bundle: .main, defaults: .standard, userDriver: userDriver)
        updater.isIdle = { !FileManager.default.fileExists(atPath: root.appendingPathComponent("busy").path) }
        let status = updater.$status.compactMap { $0 }.sink { log.record("status", $0) }
        updater.setAutomaticChecks(true)
        updater.setAutomaticDownloads(true)
        updater.setAutomaticInstalls(Bundle.main.object(forInfoDictionaryKey: "AnotherYouFixtureAutoInstall") as? Bool == true)
        updater.start()
        let timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated {
                updater.installWhenIdle()
                let quit = root.appendingPathComponent("quit")
                if FileManager.default.fileExists(atPath: quit.path) {
                    try? FileManager.default.removeItem(at: quit)
                    app.terminate(nil)
                }
            }
        }
        withExtendedLifetime((delegate, updater, userDriver, status, timer)) { app.run() }
    }
}
