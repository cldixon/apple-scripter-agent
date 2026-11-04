import Foundation

/// Results of running an automation's declared tests (and static validation).
public struct TestReport: Codable, Sendable, Equatable {
    public struct Result: Codable, Sendable, Equatable, Identifiable {
        public var id: String { name }
        public var name: String
        public var passed: Bool
        public var message: String

        public init(name: String, passed: Bool, message: String) {
            self.name = name
            self.passed = passed
            self.message = message
        }
    }

    public var automationID: String
    public var ranAt: Date
    public var issues: [ValidationIssue]
    public var results: [Result]

    public init(automationID: String, ranAt: Date, issues: [ValidationIssue], results: [Result]) {
        self.automationID = automationID
        self.ranAt = ranAt
        self.issues = issues
        self.results = results
    }

    public var passed: Bool {
        !ManifestValidator.hasErrors(issues) && results.allSatisfy(\.passed)
    }
}

/// Runs a manifest's unit tests against `RecordingEnvironment`. Harness tests need the
/// runner's window and are run there.
public enum UnitTestRunner {
    public static func run(_ manifest: AutomationManifest) async -> [TestReport.Result] {
        var results: [TestReport.Result] = []
        for (index, test) in manifest.tests.enumerated() {
            guard case .unit(let unit) = test else { continue }
            let name = "tests[\(index)] unit, step \(unit.step)"
            let now = unit.clock ?? Date()
            // A fixed clock is written in UTC ("...Z"), so read it in UTC too; otherwise a
            // test's expected date would depend on the Mac's time zone.
            let timeZone = unit.clock == nil ? TimeZone.current : TimeZone(identifier: "UTC") ?? .current
            let environment = RecordingEnvironment(now: now, clipboard: unit.clipboard ?? "", timeZone: timeZone)
            let engine = AutomationEngine(environment: environment)
            do {
                let expected = try Template.render(unit.expect, variables: [:], now: now, timeZone: timeZone)
                let actual = try await engine.output(ofStep: unit.step, in: manifest)
                results.append(.init(
                    name: name,
                    passed: actual == expected,
                    message: actual == expected ? "Got \"\(actual)\"" : "Expected \"\(expected)\", got \"\(actual)\""
                ))
            } catch {
                results.append(.init(name: name, passed: false, message: error.localizedDescription))
            }
        }
        return results
    }
}
