import AppKit
import Combine
import Foundation
@preconcurrency import Sparkle

struct UpdateConfiguration: Equatable {
    let primaryFeed: URL
    let fallbackFeed: URL?

    static func resolve(info: [String: Any], bundleURL: URL) -> Result<Self, UpdateConfigurationError> {
        guard info["AnotherYouUpdatesEnabled"] as? Bool == true,
              bundleURL.pathExtension == "app" else { return .failure(.disabled) }
        guard let primary = feedURL(info["SUFeedURL"]),
              let key = info["SUPublicEDKey"] as? String,
              Data(base64Encoded: key)?.count == 32 else { return .failure(.invalid) }
        var fallback: URL?
        if let value = info["AnotherYouFallbackFeedURL"] {
            guard let url = feedURL(value), url != primary else { return .failure(.invalid) }
            fallback = url
        }
        return .success(Self(primaryFeed: primary, fallbackFeed: fallback))
    }

    private static func feedURL(_ value: Any?) -> URL? {
        guard let value = value as? String, let url = URL(string: value),
              url.scheme == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.fragment == nil else { return nil }
        return url
    }
}

enum UpdateConfigurationError: Error {
    case disabled, invalid
    var message: String { self == .disabled ? "当前版本不支持自动更新" : "更新配置不可用" }
}

struct UpdatePreferences: Equatable {
    var checks: Bool
    var downloads: Bool
    var installs: Bool

    init(checks: Bool, downloads: Bool, installs: Bool) {
        self.checks = checks
        self.downloads = checks && downloads
        self.installs = checks && downloads && installs
    }

    init(defaults: UserDefaults) {
        self.init(checks: defaults.bool(forKey: "SUEnableAutomaticChecks"),
                  downloads: defaults.bool(forKey: "SUAutomaticallyUpdate"),
                  installs: defaults.bool(forKey: "AnotherYouAutomaticallyInstallsUpdates"))
    }

    func save(to defaults: UserDefaults) {
        defaults.set(checks, forKey: "SUEnableAutomaticChecks")
        defaults.set(downloads, forKey: "SUAutomaticallyUpdate")
        defaults.set(installs, forKey: "AnotherYouAutomaticallyInstallsUpdates")
    }
}

struct UpdateFallbackState {
    private(set) var usingFallback = false
    private(set) var loadedAppcast = false
    private var downloadFailed = false
    private var userCancelled = false

    mutating func begin() { self = Self() }
    mutating func didLoadAppcast() { loadedAppcast = true }
    mutating func didFailDownload() { downloadFailed = true }
    mutating func didCancel() { userCancelled = true }

    func canRetry(error: Error?, hasFallback: Bool) -> Bool {
        guard hasFallback, !usingFallback, !userCancelled, let error else { return false }
        let failure = error as NSError
        if failure.domain == NSURLErrorDomain && failure.code == NSURLErrorCancelled { return false }
        if failure.domain == SUSparkleErrorDomain && [
            Int(SUError.noUpdateError.rawValue), Int(SUError.installationCanceledError.rawValue)
        ].contains(failure.code) { return false }
        return !loadedAppcast || downloadFailed
    }

    mutating func finish(error: Error?, hasFallback: Bool) -> Bool {
        guard canRetry(error: error, hasFallback: hasFallback) else { return false }
        usingFallback = true
        loadedAppcast = false
        downloadFailed = false
        return true
    }
}

@MainActor
protocol UpdateDriving: AnyObject {
    var checksAutomatically: Bool { get set }
    var downloadsAutomatically: Bool { get set }
    var canCheck: Bool { get }
    var allowsAutomaticUpdates: Bool { get }
    var onChange: (() -> Void)? { get set }
    var onStatus: ((String?) -> Void)? { get set }
    var onInstallReady: ((@escaping () -> Void) -> Bool)? { get set }
    var onCycleFinished: (() -> Void)? { get set }
    func start() throws
    func checkForUpdates()
}

@MainActor
public final class UpdateController: ObservableObject {
    @Published public private(set) var automaticallyChecks = false
    @Published public private(set) var automaticallyDownloads = false
    @Published public private(set) var automaticallyInstalls = false
    @Published public private(set) var canCheck = false
    @Published public private(set) var allowsAutomaticUpdates = false
    @Published public private(set) var isInstalling = false
    @Published public private(set) var status: String?
    public let version: String
    public var isIdle: () -> Bool = { false }

    private let defaults: UserDefaults
    private let driver: (any UpdateDriving)?
    private var applyingPreferences = false
    private var pendingInstallation: (() -> Void)?
    private var started = false

    public convenience init(bundle: Bundle = .main, defaults: UserDefaults = .standard) {
        let result = UpdateConfiguration.resolve(info: bundle.infoDictionary ?? [:], bundleURL: bundle.bundleURL)
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版"
        switch result {
        case .success(let configuration):
            self.init(configuration: configuration, bundle: bundle, defaults: defaults)
        case .failure(let error):
            self.init(driver: nil, defaults: defaults, version: version, unavailableMessage: error.message)
        }
    }

    convenience init(configuration: UpdateConfiguration, bundle: Bundle, defaults: UserDefaults, userDriver: SPUStandardUserDriver? = nil) {
        self.init(driver: SparkleUpdateDriver(configuration: configuration, bundle: bundle, userDriver: userDriver), defaults: defaults,
                  version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版")
    }

    init(driver: (any UpdateDriving)?, defaults: UserDefaults, version: String = "测试版", unavailableMessage: String? = nil) {
        self.driver = driver
        self.defaults = defaults
        self.version = version
        status = unavailableMessage
        let preferences = UpdatePreferences(defaults: defaults)
        automaticallyChecks = preferences.checks
        automaticallyDownloads = preferences.downloads
        automaticallyInstalls = preferences.installs
        driver?.onChange = { [weak self] in self?.synchronize() }
        driver?.onStatus = { [weak self] in self?.status = $0 }
        driver?.onInstallReady = { [weak self] handler in self?.scheduleInstallation(handler) ?? false }
        driver?.onCycleFinished = { [weak self] in
            self?.pendingInstallation = nil
            self?.isInstalling = false
        }
    }

    public func start() {
        guard !started, let driver else { return }
        apply(UpdatePreferences(checks: automaticallyChecks, downloads: automaticallyDownloads, installs: automaticallyInstalls))
        do {
            try driver.start()
            started = true
            synchronize()
        } catch {
            status = "无法启动更新检查"
            canCheck = false
        }
    }

    public func checkForUpdates() {
        start()
        guard canCheck else { return }
        status = "正在检查更新…"
        driver?.checkForUpdates()
    }

    public func setAutomaticChecks(_ enabled: Bool) {
        apply(UpdatePreferences(checks: enabled, downloads: automaticallyDownloads, installs: automaticallyInstalls))
    }

    public func setAutomaticDownloads(_ enabled: Bool) {
        apply(UpdatePreferences(checks: automaticallyChecks, downloads: enabled, installs: automaticallyInstalls))
    }

    public func setAutomaticInstalls(_ enabled: Bool) {
        apply(UpdatePreferences(checks: automaticallyChecks, downloads: automaticallyDownloads, installs: enabled))
        installWhenIdle()
    }

    public func installWhenIdle() {
        guard automaticallyChecks, automaticallyDownloads, automaticallyInstalls,
              isIdle(), let install = pendingInstallation else { return }
        pendingInstallation = nil
        isInstalling = true
        status = "正在安装更新…"
        // Sparkle initiates the normal application termination path, which saves the sidecar first.
        install()
    }

    private func scheduleInstallation(_ handler: @escaping () -> Void) -> Bool {
        guard automaticallyChecks, automaticallyDownloads, automaticallyInstalls else {
            status = "更新已下载，退出时安装"
            return false
        }
        pendingInstallation = handler
        status = "更新已下载，等待当前任务完成"
        // Allow Sparkle to finish registering its installation session before invoking its handler.
        Task { [weak self] in self?.installWhenIdle() }
        return true
    }

    private func apply(_ preferences: UpdatePreferences) {
        applyingPreferences = true
        driver?.checksAutomatically = preferences.checks
        driver?.downloadsAutomatically = preferences.downloads
        automaticallyChecks = preferences.checks
        automaticallyDownloads = preferences.downloads
        automaticallyInstalls = preferences.installs
        preferences.save(to: defaults)
        applyingPreferences = false
        cancelInstallationIfDisabled()
        if started { synchronize() }
    }

    private func synchronize() {
        guard !applyingPreferences, let driver else { return }
        canCheck = started && driver.canCheck
        allowsAutomaticUpdates = started && driver.allowsAutomaticUpdates
        let preferences = UpdatePreferences(checks: driver.checksAutomatically, downloads: driver.downloadsAutomatically,
                                            installs: automaticallyInstalls)
        automaticallyChecks = preferences.checks
        automaticallyDownloads = preferences.downloads
        automaticallyInstalls = preferences.installs
        preferences.save(to: defaults)
        cancelInstallationIfDisabled()
    }

    private func cancelInstallationIfDisabled() {
        guard !automaticallyInstalls, pendingInstallation != nil else { return }
        pendingInstallation = nil
        status = "更新已下载，退出时安装"
    }
}

@MainActor
private final class UpdateUserDriver: SPUStandardUserDriver {
    var shouldSuppressError: (Error) -> Bool = { _ in false }

    override func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        if shouldSuppressError(error) { acknowledgement() }
        else { super.showUpdaterError(error, acknowledgement: acknowledgement) }
    }
}

@MainActor
private final class SparkleUpdateDriver: NSObject, UpdateDriving, SPUUpdaterDelegate {
    var onChange: (() -> Void)?
    var onStatus: ((String?) -> Void)?
    var onInstallReady: ((@escaping () -> Void) -> Bool)?
    var onCycleFinished: (() -> Void)?
    private var updater: SPUUpdater!
    private let userDriver: SPUStandardUserDriver
    private let configuration: UpdateConfiguration
    private var fallback = UpdateFallbackState()
    private var retryCheck: SPUUpdateCheck?
    private var observations: Set<AnyCancellable> = []

    var checksAutomatically: Bool {
        get { updater.automaticallyChecksForUpdates }
        set { updater.automaticallyChecksForUpdates = newValue }
    }
    var downloadsAutomatically: Bool {
        get { updater.automaticallyDownloadsUpdates }
        set { updater.automaticallyDownloadsUpdates = newValue }
    }
    var canCheck: Bool { updater.canCheckForUpdates && !updater.sessionInProgress }
    var allowsAutomaticUpdates: Bool { updater.allowsAutomaticUpdates }

    init(configuration: UpdateConfiguration, bundle: Bundle, userDriver: SPUStandardUserDriver? = nil) {
        self.configuration = configuration
        self.userDriver = userDriver ?? UpdateUserDriver(hostBundle: bundle, delegate: nil)
        super.init()
        updater = SPUUpdater(hostBundle: bundle, applicationBundle: bundle, userDriver: self.userDriver, delegate: self)
        (self.userDriver as? UpdateUserDriver)?.shouldSuppressError = { [weak self] error in
            guard let self else { return false }
            return self.fallback.canRetry(error: error, hasFallback: self.configuration.fallbackFeed != nil)
        }
        for keyPath in [\SPUUpdater.automaticallyChecksForUpdates, \.automaticallyDownloadsUpdates,
                        \.canCheckForUpdates, \.allowsAutomaticUpdates, \.sessionInProgress] {
            updater.publisher(for: keyPath).sink { [weak self] _ in
                self?.onChange?()
                self?.scheduleRetry()
            }.store(in: &observations)
        }
    }

    func start() throws { try updater.start() }
    func checkForUpdates() { updater.checkForUpdates() }

    func feedURLString(for updater: SPUUpdater) -> String? {
        (fallback.usingFallback ? configuration.fallbackFeed ?? configuration.primaryFeed : configuration.primaryFeed).absoluteString
    }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        if updateCheck != .updates && !checksAutomatically {
            fallback.didCancel()
            throw NSError(domain: SUSparkleErrorDomain, code: Int(SUError.installationCanceledError.rawValue))
        }
        if retryCheck == updateCheck { retryCheck = nil }
        else { fallback.begin() }
        onStatus?("正在检查更新…")
    }

    func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) { fallback.didLoadAppcast() }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        onStatus?("发现新版本 \(item.displayVersionString)")
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) { onStatus?("已是最新版本") }

    func updater(_ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: Error) {
        fallback.didFailDownload()
    }

    func updater(_ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice,
                 forUpdate item: SUAppcastItem, state: SPUUserUpdateState) {
        if choice == .skip || choice == .dismiss { fallback.didCancel() }
    }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        onInstallReady?(immediateInstallHandler) ?? false
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        onCycleFinished?()
        guard updateCheck == .updates || checksAutomatically else {
            retryCheck = nil
            fallback.begin()
            return
        }
        if fallback.finish(error: error, hasFallback: configuration.fallbackFeed != nil) {
            retryCheck = updateCheck
            scheduleRetry()
        } else {
            if let error {
                let error = error as NSError
                if error.domain != SUSparkleErrorDomain || ![Int(SUError.noUpdateError.rawValue), Int(SUError.installationCanceledError.rawValue)].contains(error.code) {
                    onStatus?("更新检查未完成，请稍后重试")
                }
            }
            retryCheck = nil
            fallback.begin()
        }
    }

    private func scheduleRetry() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.canCheck, let check = self.retryCheck else { return }
            guard check == .updates || self.checksAutomatically else {
                self.retryCheck = nil
                self.fallback.begin()
                return
            }
            switch check {
            case .updates: self.updater.checkForUpdates()
            case .updatesInBackground: self.updater.checkForUpdatesInBackground()
            case .updateInformation: self.updater.checkForUpdateInformation()
            @unknown default: self.updater.checkForUpdatesInBackground()
            }
        }
    }
}
