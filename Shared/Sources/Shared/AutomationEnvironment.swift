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
    /// Copies the frontmost app's selection and returns it as text; empty when nothing was copied.
    func copySelection() async throws -> String
    /// Presses a key combination in the frontmost app.
    func pressKeys(_ combo: KeyCombo) async throws
    /// Asks the user for text. Returns nil when the user cancels.
    func askText(prompt: String, defaultValue: String) async throws -> String?
}

extension AutomationEnvironment {
    public func timeZone() -> TimeZone { .current }

    public func copySelection() async throws -> String {
        throw AutomationError.unsupportedStep("primitive copySelection")
    }

    public func pressKeys(_ combo: KeyCombo) async throws {
        throw AutomationError.unsupportedStep("primitive pressKeys")
    }

    public func askText(prompt: String, defaultValue: String) async throws -> String? {
        throw AutomationError.unsupportedStep("primitive askText")
    }
}

/// Errors raised while running an automation.
public enum AutomationError: Error, Equatable, LocalizedError {
    case permissionMissing(Permission)
    case unsupportedStep(String)
    case timedOut(seconds: Double)
    case invalidArgument(String)
    case system(String)
    case scriptFailed(String)
    /// The user cancelled (a Cancel button, or AppleScript error -128). The run stops as
    /// skipped, not failed.
    case cancelledByUser

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
        case .cancelledByUser:
            "Cancelled by the user"
        }
    }

    /// True when a script's error output says the user cancelled: AppleScript error -128,
    /// for example the Cancel button of `display dialog` or `choose file`.
    public static func isUserCancel(scriptError text: String) -> Bool {
        text.contains("(-128)") || text.localizedCaseInsensitiveContains("User canceled")
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
    /// How many times `copySelection` ran.
    public private(set) var selectionCopies = 0
    public private(set) var pressedKeys: [KeyCombo] = []
    /// Prompts shown by `askText`, in order.
    public private(set) var prompts: [String] = []
    /// Canned script outputs, keyed by inline source or file name. Missing keys return "".
    private let scriptOutputs: [String: String]
    /// Text `copySelection` returns (and puts on the clipboard). Empty means nothing is selected.
    private let selection: String
    /// What `askText` answers; nil answers with the step's default text.
    private let answer: String?
    /// When true, `askText` behaves as if the user pressed Cancel.
    private let cancelsPrompts: Bool

    public init(
        now: Date = Date(),
        clipboard: String = "",
        timeZone: TimeZone = .current,
        scriptOutputs: [String: String] = [:],
        selection: String = "",
        answer: String? = nil,
        cancelsPrompts: Bool = false
    ) {
        fixedNow = now
        fixedTimeZone = timeZone
        self.scriptOutputs = scriptOutputs
        self.clipboard = clipboard
        self.selection = selection
        self.answer = answer
        self.cancelsPrompts = cancelsPrompts
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

    public func copySelection() -> String {
        selectionCopies += 1
        if !selection.isEmpty { clipboard = selection }
        return selection
    }

    public func pressKeys(_ combo: KeyCombo) { pressedKeys.append(combo) }

    public func askText(prompt: String, defaultValue: String) -> String? {
        prompts.append(prompt)
        if cancelsPrompts { return nil }
        return answer ?? defaultValue
    }
}
