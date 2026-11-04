import Foundation

/// Script languages a step can run.
public enum ScriptLanguage: String, Codable, Sendable, CaseIterable {
    case applescript, jxa, shell, shortcut

    /// The `osacompile`/`osascript -l` language name, for OSA languages.
    public var osaLanguage: String? {
        switch self {
        case .applescript: "AppleScript"
        case .jxa: "JavaScript"
        case .shell, .shortcut: nil
        }
    }
}

/// What a script step asks the environment to run.
///
/// Contract: the script receives `inputJSON`, an object of every named output so far.
/// AppleScript gets it as the first item of `on run argv`, JXA as `run(argv)[0]`, shell as
/// the `AUTOMATION_INPUT` environment variable (plus `AUTOMATION_VAR_<name>` per value).
/// For a shortcut, `shortcutInput` is passed as its input. Whatever the script prints (or
/// returns) is the step's output, with one trailing newline removed.
public struct ScriptRequest: Sendable, Equatable {
    public var language: ScriptLanguage
    /// Inline source, or nil when `file` is set.
    public var source: String?
    /// Absolute path of the script file.
    public var file: URL?
    /// For `shortcut`: the shortcut's name.
    public var shortcutName: String?
    public var shortcutInput: String?
    public var variables: [String: String]
    /// Folder the script runs in (the automation's folder), if known.
    public var workingDirectory: URL?
    /// Permissions the manifest declares; the runner refuses scripts that need others.
    public var declaredPermissions: [Permission]
    public var timeout: Double

    public init(
        language: ScriptLanguage,
        source: String? = nil,
        file: URL? = nil,
        shortcutName: String? = nil,
        shortcutInput: String? = nil,
        variables: [String: String] = [:],
        workingDirectory: URL? = nil,
        declaredPermissions: [Permission] = [],
        timeout: Double = Step.defaultTimeout
    ) {
        self.language = language
        self.source = source
        self.file = file
        self.shortcutName = shortcutName
        self.shortcutInput = shortcutInput
        self.variables = variables
        self.workingDirectory = workingDirectory
        self.declaredPermissions = declaredPermissions
        self.timeout = timeout
    }

    /// `variables` as a JSON object with sorted keys.
    public var inputJSON: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(variables)) ?? Data("{}".utf8)
        return String(bytes: data, encoding: .utf8) ?? "{}"
    }
}

/// The outcome of running a script, as `run_snippet` reports it.
public struct ScriptResult: Codable, Sendable, Equatable {
    public var output: String
    public var errorOutput: String
    public var exitCode: Int32
    /// Seconds.
    public var duration: Double
    public var timedOut: Bool

    public init(output: String, errorOutput: String, exitCode: Int32, duration: Double, timedOut: Bool) {
        self.output = output
        self.errorOutput = errorOutput
        self.exitCode = exitCode
        self.duration = duration
        self.timedOut = timedOut
    }

    public var succeeded: Bool { exitCode == 0 && !timedOut }
}

/// Reads a script's text for the apps it controls, so permissions can be checked.
public enum ScriptAnalysis {
    /// App names or bundle ids named in `tell application "…"` (AppleScript) or
    /// `Application("…")` (JXA). `System Events` is included: it needs its own permission.
    public static func targetApplications(in source: String, language: ScriptLanguage) -> [String] {
        let patterns: [String]
        switch language {
        case .applescript:
            patterns = [#"(?i)\btell\s+application\s+(?:id\s+)?"([^"]+)""#, #"(?i)\bapplication\s+id\s+"([^"]+)""#]
        case .jxa:
            patterns = [#"\bApplication\(\s*['"]([^'"]+)['"]\s*\)"#]
        case .shell, .shortcut:
            return []
        }
        var names: [String] = []
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(source.startIndex..., in: source)
            for match in regex.matches(in: source, range: range) {
                guard let captured = Range(match.range(at: 1), in: source) else { continue }
                let name = String(source[captured])
                if !names.contains(name) { names.append(name) }
            }
        }
        return names
    }

    /// Bundle ids of apps whose scripting needs no Automation permission.
    public static let exemptTargets: Set<String> = ["Script Editor", "com.apple.ScriptEditor2"]
}
