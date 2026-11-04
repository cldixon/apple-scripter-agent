import Foundation

/// Everything a primitive step can do to the outside world. The runner supplies the real
/// implementation; tests and unit-test runs use `RecordingEnvironment`.
public protocol AutomationEnvironment: Sendable {
    func now() -> Date
    /// Time zone for `formatDate` and `{{today:...}}`.
    func timeZone() -> TimeZone
    func typeText(_ text: String) async throws
    func pasteText(_ text: String) async throws
    func readClipboard() async throws -> String
    func writeClipboard(_ text: String) async throws
    func notify(title: String, text: String) async throws
    func openURL(_ url: URL) async throws
    func launchApp(_ app: String) async throws
    func sleep(seconds: Double) async throws
    /// Runs a script step. Must stop the script when the task is cancelled (timeout).
    func runScript(_ request: ScriptRequest) async throws -> String
}

extension AutomationEnvironment {
    public func timeZone() -> TimeZone { .current }
}

/// Errors raised while running an automation.
public enum AutomationError: Error, Equatable, LocalizedError {
    case permissionMissing(Permission)
    case unsupportedStep(String)
    case timedOut(seconds: Double)
    case invalidArgument(String)
    case system(String)
    case scriptFailed(String)

    public var errorDescription: String? {
        switch self {
        case .permissionMissing(let permission):
            "The runner does not have the \(permission) permission."
        case .unsupportedStep(let type):
            "Step type \"\(type)\" is not supported by this runner yet."
        case .timedOut(let seconds):
            "Step did not finish within \(seconds.formatted()) seconds."
        case .invalidArgument(let message):
            message
        case .system(let message):
            message
        case .scriptFailed(let message):
            message
        }
    }
}

/// A fake environment with a fixed clock that records what steps did instead of doing it.
public actor RecordingEnvironment: AutomationEnvironment {
    nonisolated public let fixedNow: Date
    nonisolated public let fixedTimeZone: TimeZone
    public private(set) var typed: [String] = []
    public private(set) var pasted: [String] = []
    public private(set) var clipboard: String
    public private(set) var notifications: [(title: String, text: String)] = []
    public private(set) var openedURLs: [URL] = []
    public private(set) var launchedApps: [String] = []
    public private(set) var slept: [Double] = []
    public private(set) var scripts: [ScriptRequest] = []
    /// Canned script outputs, keyed by inline source or file name. Missing keys return "".
    private let scriptOutputs: [String: String]

    public init(
        now: Date = Date(),
        clipboard: String = "",
        timeZone: TimeZone = .current,
        scriptOutputs: [String: String] = [:]
    ) {
        fixedNow = now
        fixedTimeZone = timeZone
        self.scriptOutputs = scriptOutputs
        self.clipboard = clipboard
    }

    nonisolated public func now() -> Date { fixedNow }
    nonisolated public func timeZone() -> TimeZone { fixedTimeZone }
    public func typeText(_ text: String) { typed.append(text) }
    public func pasteText(_ text: String) { pasted.append(text) }
    public func readClipboard() -> String { clipboard }
    public func writeClipboard(_ text: String) { clipboard = text }
    public func notify(title: String, text: String) { notifications.append((title, text)) }
    public func openURL(_ url: URL) { openedURLs.append(url) }
    public func launchApp(_ app: String) { launchedApps.append(app) }
    public func sleep(seconds: Double) { slept.append(seconds) }

    public func runScript(_ request: ScriptRequest) -> String {
        scripts.append(request)
        let key = request.source ?? request.file?.lastPathComponent ?? request.shortcutName ?? ""
        return scriptOutputs[key] ?? ""
    }
}
