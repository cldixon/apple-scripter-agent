import Foundation

public enum ScriptTestError: LocalizedError, Equatable {
    case notAScriptStep(Int)
    case sendsAppleEvents(step: Int, targets: [String])
    case unsafePath(String)
    case fixturesMissing(String)
    case scriptUnreadable(Int)

    public var errorDescription: String? {
        switch self {
        case .notAScriptStep(let step):
            "Step \(step) is not an applescript, jxa or shell step, so a script test cannot run it."
        case .sendsAppleEvents(let step, let targets):
            "Step \(step) controls \(targets.joined(separator: ", ")) through Apple Events, which script "
                + "tests block. Try it with run_snippet, or test it with a harness test instead."
        case .unsafePath(let path):
            "\"\(path)\" must be a relative path inside the automation folder (no absolute paths, ~ or \"..\")."
        case .fixturesMissing(let path):
            "The fixtures folder \(path) does not exist in the automation folder."
        case .scriptUnreadable(let step):
            "The script of step \(step) could not be read."
        }
    }
}

/// A script step as a script test sees it.
public struct ScriptTestStep: Sendable, Equatable {
    public var language: ScriptLanguage
    public var source: ScriptSource

    /// The step's language and source, or nil when it is not an applescript, jxa or shell step.
    public init?(_ step: Step) {
        switch step.body {
        case .applescript(let script):
            language = .applescript
            source = script
        case .jxa(let script):
            language = .jxa
            source = script
        case .shell(let script):
            language = .shell
            source = script
        default:
            return nil
        }
    }

    /// Apps the script sends Apple Events to (any `tell application`/`Application(...)`).
    public func targetApplications(folder: URL?) -> [String]? {
        guard let text = ManifestValidator.scriptText(source, folder: folder) else { return nil }
        return ScriptAnalysis.targetApplications(in: text, language: language)
    }
}

/// The temporary folder one script test runs in: `root` is the only writable place;
/// `work` (the fixture copy) is the working directory, `HOME` and `fixtures_dir`;
/// `temporary` is `TMPDIR`.
public struct ScriptTestWorkspace: Sendable {
    public let root: URL
    public let work: URL
    public let temporary: URL

    /// Creates the folder and copies `fixtures` (relative to `folder`) into `work`.
    public static func create(fixtures: String?, folder: URL?) throws -> ScriptTestWorkspace {
        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory
            .appending(path: "AutomationAgentScriptTest-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: base, withIntermediateDirectories: true)
        let root = URL(filePath: ScriptTestSandbox.canonicalPath(base.path), directoryHint: .isDirectory)
        let work = root.appending(path: "work", directoryHint: .isDirectory)
        let temporary = root.appending(path: "tmp", directoryHint: .isDirectory)
        let workspace = ScriptTestWorkspace(root: root, work: work, temporary: temporary)
        do {
            try fileManager.createDirectory(at: temporary, withIntermediateDirectories: true)
            if let fixtures {
                let source = try fixturesFolder(fixtures, in: folder)
                try fileManager.copyItem(at: source, to: work)
            } else {
                try fileManager.createDirectory(at: work, withIntermediateDirectories: true)
            }
        } catch {
            workspace.remove()
            throw error
        }
        return workspace
    }

    /// The fixtures folder inside `folder`, after checking it is safe and exists.
    static func fixturesFolder(_ path: String, in folder: URL?) throws -> URL {
        guard ScriptTestPaths.isSafeRelative(path), let folder else { throw ScriptTestError.unsafePath(path) }
        let source = folder.appending(path: path, directoryHint: .isDirectory)
        guard ScriptTestPaths.isInside(source, base: folder) else { throw ScriptTestError.unsafePath(path) }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { throw ScriptTestError.fixturesMissing(path) }
        return source
    }

    public func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

/// An interpreter and its arguments, before sandboxing.
public struct ScriptTestInvocation: Sendable, Equatable {
    public var tool: String
    public var arguments: [String]
    public var environment: [String: String]
}

/// The process to launch for one script test.
public struct ScriptTestCommand: Sendable, Equatable {
    public var executable: String
    public var arguments: [String]
    /// Added to the runner's own environment.
    public var environment: [String: String]
    public var timeout: Double
}

/// Builds the sandboxed command line for a script test, with the same input contract as a
/// normal run: AppleScript/JXA get the JSON object of inputs as `argv[1]`; shell gets
/// `AUTOMATION_INPUT` and `AUTOMATION_VAR_<name>`.
public enum ScriptTestPlanner {
    public static func command(
        _ test: ManifestTest.ScriptTest,
        manifest: AutomationManifest,
        folder: URL?,
        workspace: ScriptTestWorkspace
    ) throws -> ScriptTestCommand {
        guard manifest.steps.indices.contains(test.step),
              let scriptStep = ScriptTestStep(manifest.steps[test.step]) else {
            throw ScriptTestError.notAScriptStep(test.step)
        }
        guard let targets = scriptStep.targetApplications(folder: folder) else {
            throw ScriptTestError.scriptUnreadable(test.step)
        }
        guard targets.isEmpty else { throw ScriptTestError.sendsAppleEvents(step: test.step, targets: targets) }

        let scriptPath = try scriptFile(scriptStep, step: test.step, folder: folder, workspace: workspace)
        var inputs = test.inputs
        inputs["fixtures_dir"] = workspace.work.path
        let invocation = toolInvocation(scriptStep.language, scriptPath: scriptPath, inputs: inputs)

        var environment = [
            "HOME": workspace.work.path,
            "TMPDIR": workspace.temporary.path + "/"
        ]
        environment.merge(invocation.environment) { _, new in new }
        let profile = ScriptTestSandbox.profile(writablePaths: writablePaths(workspace))
        return ScriptTestCommand(
            executable: ScriptTestSandbox.executable,
            arguments: ScriptTestSandbox.arguments(
                profile: profile,
                directory: workspace.work.path,
                tool: invocation.tool,
                toolArguments: invocation.arguments
            ),
            environment: environment,
            timeout: manifest.steps[test.step].effectiveTimeout
        )
    }

    /// The interpreter command line, unsandboxed: the same contract `ScriptRunner` uses.
    static func toolInvocation(
        _ language: ScriptLanguage,
        scriptPath: String,
        inputs: [String: String]
    ) -> ScriptTestInvocation {
        let inputJSON = ScriptRequest(language: language, variables: inputs).inputJSON
        switch language {
        case .applescript, .jxa:
            let osaLanguage = language.osaLanguage ?? "AppleScript"
            return ScriptTestInvocation(
                tool: "/usr/bin/osascript", arguments: ["-l", osaLanguage, scriptPath, inputJSON], environment: [:]
            )
        default:
            var environment = ["AUTOMATION_INPUT": inputJSON]
            for (name, value) in inputs {
                environment["AUTOMATION_VAR_\(name)"] = value
            }
            return ScriptTestInvocation(tool: "/bin/zsh", arguments: [scriptPath], environment: environment)
        }
    }

    /// The test's own folder, plus the per-user cache folder system tools write to.
    public static func writablePaths(_ workspace: ScriptTestWorkspace) -> [String] {
        [workspace.root.path] + (ScriptTestSandbox.userCacheDirectory().map { [$0] } ?? [])
    }

    /// The script's file in the automation folder, or inline source written into the workspace
    /// (outside `work`, so it does not show up among the fixtures).
    private static func scriptFile(
        _ scriptStep: ScriptTestStep,
        step: Int,
        folder: URL?,
        workspace: ScriptTestWorkspace
    ) throws -> String {
        if let source = scriptStep.source.source {
            let file = workspace.root.appending(path: "script.\(scriptStep.language.rawValue)")
            try source.write(to: file, atomically: true, encoding: .utf8)
            return file.path
        }
        guard let path = scriptStep.source.file, let folder else { throw ScriptTestError.scriptUnreadable(step) }
        guard ScriptTestPaths.isSafeRelative(path) else { throw ScriptTestError.unsafePath(path) }
        return folder.appending(path: path).path
    }
}
