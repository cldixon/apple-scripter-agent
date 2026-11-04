import Foundation

/// Runs an automation's steps in order against an environment, threading named outputs
/// through `{{templates}}` and enforcing each step's timeout.
public struct AutomationEngine: Sendable {
    public let environment: any AutomationEnvironment

    public init(environment: any AutomationEnvironment) {
        self.environment = environment
    }

    /// Runs all steps, or stops at the first failure. Never throws: failures are in the record.
    public func run(_ manifest: AutomationManifest, cause: RunRecord.Cause) async -> RunRecord {
        let startedAt = Date()
        let clock = ContinuousClock()
        let runStart = clock.now
        var variables: [String: String] = [:]
        var results: [RunRecord.StepResult] = []
        var failure: String?

        for (index, step) in manifest.steps.enumerated() {
            let stepStart = clock.now
            do {
                let output = try await runStep(step, variables: variables)
                if let name = step.output { variables[name] = output }
                results.append(.init(
                    index: index, type: step.body.typeName, outcome: .succeeded,
                    output: Self.excerpt(output), error: nil, duration: (clock.now - stepStart).inSeconds
                ))
            } catch {
                failure = "Step \(index) (\(step.body.typeName)): \(error.localizedDescription)"
                results.append(.init(
                    index: index, type: step.body.typeName, outcome: .failed,
                    output: nil, error: error.localizedDescription, duration: (clock.now - stepStart).inSeconds
                ))
                break
            }
        }

        return RunRecord(
            automationID: manifest.id,
            version: manifest.version,
            cause: cause,
            startedAt: startedAt,
            duration: (clock.now - runStart).inSeconds,
            outcome: failure == nil ? .succeeded : .failed,
            error: failure,
            steps: results
        )
    }

    /// Runs steps `0...index` and returns step `index`'s output. Used by unit tests.
    public func output(ofStep index: Int, in manifest: AutomationManifest) async throws -> String {
        guard manifest.steps.indices.contains(index) else {
            throw AutomationError.invalidArgument("Step \(index) does not exist.")
        }
        var variables: [String: String] = [:]
        var last = ""
        for step in manifest.steps.prefix(index + 1) {
            last = try await runStep(step, variables: variables)
            if let name = step.output { variables[name] = last }
        }
        return last
    }

    /// Runs one step with a timeout. Every primitive returns a string: the value it produced
    /// or the text it acted on.
    public func runStep(_ step: Step, variables: [String: String]) async throws -> String {
        let environment = environment
        let now = environment.now()
        let timeZone = environment.timeZone()
        let seconds = step.effectiveTimeout
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await Self.perform(
                    step.body, variables: variables, now: now, timeZone: timeZone, environment: environment
                )
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

    private static func perform(
        _ body: Step.Body,
        variables: [String: String],
        now: Date,
        timeZone: TimeZone,
        environment: any AutomationEnvironment
    ) async throws -> String {
        func render(_ text: String) throws -> String {
            try Template.render(text, variables: variables, now: now, timeZone: timeZone)
        }

        switch body {
        case .primitive(let primitive):
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
            }
        case .applescript, .jxa, .shell, .shortcut, .accessibility:
            throw AutomationError.unsupportedStep(body.typeName)
        }
    }

    static func excerpt(_ text: String) -> String {
        text.count > RunRecord.outputExcerptLimit
            ? String(text.prefix(RunRecord.outputExcerptLimit)) + "…"
            : text
    }
}

extension Duration {
    /// Seconds as a `Double`.
    public var inSeconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
