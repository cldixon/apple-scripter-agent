import Foundation

/// Runs an automation's steps in order against an environment, threading named outputs
/// through `{{templates}}` and enforcing each step's timeout.
public struct AutomationEngine: Sendable {
    public let environment: any AutomationEnvironment

    public init(environment: any AutomationEnvironment) {
        self.environment = environment
    }

    /// Runs all steps, or stops at the first failure. Never throws: failures are in the record.
    /// When the user cancels a step (`AutomationError.cancelledByUser`), the run stops with
    /// outcome `.skipped`, which does not count toward a failure streak.
    /// `folder` is the automation's folder, which script `file` paths are relative to.
    public func run(_ manifest: AutomationManifest, cause: RunRecord.Cause, folder: URL? = nil) async -> RunRecord {
        let startedAt = Date()
        let clock = ContinuousClock()
        let runStart = clock.now
        var variables: [String: String] = [:]
        var results: [RunRecord.StepResult] = []
        var outcome = RunRecord.Outcome.succeeded
        var failure: String?

        for (index, step) in manifest.steps.enumerated() {
            let result = await attempt(
                step, index: index, variables: &variables, permissions: manifest.permissions, folder: folder
            )
            results.append(result)
            guard result.outcome == .succeeded else {
                outcome = result.outcome
                let message = result.error ?? "Unknown error"
                failure = result.outcome == .skipped ? message : "Step \(index) (\(step.body.typeName)): \(message)"
                break
            }
        }

        return RunRecord(
            automationID: manifest.id,
            version: manifest.version,
            cause: cause,
            startedAt: startedAt,
            duration: (clock.now - runStart).inSeconds,
            outcome: outcome,
            error: failure,
            steps: results
        )
    }

    /// Runs one step of a run and reports how it went; a named output goes into `variables`.
    private func attempt(
        _ step: Step,
        index: Int,
        variables: inout [String: String],
        permissions: [Permission],
        folder: URL?
    ) async -> RunRecord.StepResult {
        let clock = ContinuousClock()
        let start = clock.now
        let outcome: RunRecord.Outcome
        var output: String?
        var message: String?
        do {
            let value = try await runStep(step, variables: variables, permissions: permissions, folder: folder)
            if let name = step.output { variables[name] = value }
            outcome = .succeeded
            output = Self.excerpt(value)
        } catch AutomationError.cancelledByUser {
            outcome = .skipped
            message = AutomationError.cancelledByUser.localizedDescription
        } catch {
            outcome = .failed
            message = error.localizedDescription
        }
        return RunRecord.StepResult(
            index: index, type: step.body.typeName, outcome: outcome,
            output: output, error: message, duration: (clock.now - start).inSeconds
        )
    }

    /// Runs steps `0...index` and returns step `index`'s output. Used by unit tests.
    public func output(
        ofStep index: Int,
        in manifest: AutomationManifest,
        folder: URL? = nil
    ) async throws -> String {
        guard manifest.steps.indices.contains(index) else {
            throw AutomationError.invalidArgument("Step \(index) does not exist.")
        }
        var variables: [String: String] = [:]
        var last = ""
        for step in manifest.steps.prefix(index + 1) {
            last = try await runStep(step, variables: variables, permissions: manifest.permissions, folder: folder)
            if let name = step.output { variables[name] = last }
        }
        return last
    }

    /// Runs one step with a timeout. Every primitive returns a string: the value it produced
    /// or the text it acted on.
    public func runStep(
        _ step: Step,
        variables: [String: String],
        permissions: [Permission] = [],
        folder: URL? = nil
    ) async throws -> String {
        let environment = environment
        let seconds = step.effectiveTimeout
        let context = StepContext(
            variables: variables,
            now: environment.now(),
            timeZone: environment.timeZone(),
            folder: folder,
            permissions: permissions,
            timeout: seconds
        )
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await Self.perform(step.body, context: context, environment: environment)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw AutomationError.timedOut(seconds: seconds)
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw AutomationError.timedOut(seconds: seconds) }
            return first
        }
    }

    /// Everything a step needs besides its own body.
    fileprivate struct StepContext: Sendable {
        var variables: [String: String]
        var now: Date
        var timeZone: TimeZone
        var folder: URL?
        var permissions: [Permission]
        var timeout: Double

        func render(_ text: String) throws -> String {
            try Template.render(text, variables: variables, now: now, timeZone: timeZone)
        }

        func scriptRequest(_ language: ScriptLanguage, _ source: ScriptSource) throws -> ScriptRequest {
            var file: URL?
            if let path = source.file {
                guard let folder else {
                    throw AutomationError.invalidArgument("Script file \(path) needs the automation's folder.")
                }
                file = folder.appending(path: path)
            }
            return ScriptRequest(
                language: language,
                source: source.source,
                file: file,
                variables: variables,
                workingDirectory: folder,
                declaredPermissions: permissions,
                timeout: timeout
            )
        }
    }

    private static func perform(
        _ body: Step.Body,
        context: StepContext,
        environment: any AutomationEnvironment
    ) async throws -> String {
        switch body {
        case .primitive(let primitive):
            return try await perform(primitive, context: context, environment: environment)
        case .applescript(let source):
            return try await environment.runScript(context.scriptRequest(.applescript, source))
        case .jxa(let source):
            return try await environment.runScript(context.scriptRequest(.jxa, source))
        case .shell(let source):
            return try await environment.runScript(context.scriptRequest(.shell, source))
        case .shortcut(let name, let input):
            return try await environment.runScript(ScriptRequest(
                language: .shortcut,
                shortcutName: name,
                shortcutInput: try input.map(context.render),
                variables: context.variables,
                workingDirectory: context.folder,
                declaredPermissions: context.permissions,
                timeout: context.timeout
            ))
        case .accessibility:
            throw AutomationError.unsupportedStep(body.typeName)
        }
    }

    private static func perform(
        _ primitive: Primitive,
        context: StepContext,
        environment: any AutomationEnvironment
    ) async throws -> String {
        let now = context.now
        let timeZone = context.timeZone
        func render(_ text: String) throws -> String {
            try context.render(text)
        }

        switch primitive {
        case .formatDate(let pattern):
            return DateText.format(now, pattern: try render(pattern), timeZone: timeZone)
        case .typeText(let text):
            let rendered = try render(text)
            try await environment.typeText(rendered)
            return rendered
        case .pasteText(let text):
            let rendered = try render(text)
            try await environment.pasteText(rendered)
            return rendered
        case .readClipboard:
            return try await environment.readClipboard()
        case .writeClipboard(let text):
            let rendered = try render(text)
            try await environment.writeClipboard(rendered)
            return rendered
        case .notify(let title, let text):
            let rendered = try render(text)
            try await environment.notify(title: try title.map(render) ?? "Automation Agent", text: rendered)
            return rendered
        case .openURL(let text):
            let rendered = try render(text)
            guard let url = URL(string: rendered), url.scheme != nil else {
                throw AutomationError.invalidArgument("\"\(rendered)\" is not a URL.")
            }
            try await environment.openURL(url)
            return rendered
        case .launchApp(let app):
            let rendered = try render(app)
            try await environment.launchApp(rendered)
            return rendered
        case .delay(let seconds):
            try await environment.sleep(seconds: seconds)
            return ""
        case .copySelection, .pressKeys, .askText:
            return try await performInteractive(primitive, context: context, environment: environment)
        }
    }

    static func excerpt(_ text: String) -> String {
        text.count > RunRecord.outputExcerptLimit
            ? String(text.prefix(RunRecord.outputExcerptLimit)) + "…"
            : text
    }
}

extension AutomationEngine {
    /// The primitives that work with the frontmost app or the user.
    private static func performInteractive(
        _ primitive: Primitive,
        context: StepContext,
        environment: any AutomationEnvironment
    ) async throws -> String {
        switch primitive {
        case .copySelection:
            let text = try await environment.copySelection()
            guard !text.isEmpty else {
                throw AutomationError.system(
                    "Nothing is selected: copying in the frontmost app produced no text. "
                        + "Select some text first."
                )
            }
            return text
        case .pressKeys(let keys):
            let combo: KeyCombo
            do {
                combo = try KeyCombo.parse(keys)
            } catch {
                throw AutomationError.invalidArgument(error.localizedDescription)
            }
            try await environment.pressKeys(combo)
            return keys
        case .askText(let prompt, let defaultValue):
            let answer = try await environment.askText(
                prompt: try context.render(prompt),
                defaultValue: try defaultValue.map { try context.render($0) } ?? ""
            )
            guard let answer else { throw AutomationError.cancelledByUser }
            return answer
        default:
            throw AutomationError.unsupportedStep("primitive \(primitive.actionName)")
        }
    }
}

extension Duration {
    /// Seconds as a `Double`.
    public var inSeconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
