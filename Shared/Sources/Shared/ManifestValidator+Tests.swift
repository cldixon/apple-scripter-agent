import Foundation

/// Checks of a manifest's `tests`.
extension ManifestValidator {
    static func checkTests(_ manifest: AutomationManifest, folder: URL?) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        for (index, test) in manifest.tests.enumerated() {
            let location = "tests[\(index)]"
            switch test {
            case .unit(let unit):
                if !manifest.steps.indices.contains(unit.step) {
                    issues.append(ValidationIssue(.error, location, "Step \(unit.step) does not exist."))
                }
            case .harness(let harness):
                if harness.select == .all, (harness.setupText ?? "").isEmpty {
                    issues.append(ValidationIssue(
                        .warning, location, "\"select\": \"all\" has nothing to select without \"setupText\"."
                    ))
                }
            case .script(let script):
                issues += checkScriptTest(script, location: location, manifest: manifest, folder: folder)
            }
        }
        if manifest.tests.isEmpty {
            issues.append(ValidationIssue(.warning, "tests", "No tests declared."))
        }
        return issues
    }

    /// A script test must name an existing applescript/jxa/shell step that sends no Apple
    /// Events, check at least one thing, and use safe relative paths.
    static func checkScriptTest(
        _ test: ManifestTest.ScriptTest,
        location: String,
        manifest: AutomationManifest,
        folder: URL?
    ) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        if !manifest.steps.indices.contains(test.step) {
            issues.append(ValidationIssue(.error, location, "Step \(test.step) does not exist."))
        } else if let scriptStep = ScriptTestStep(manifest.steps[test.step]) {
            let targets = scriptStep.targetApplications(folder: folder) ?? []
            if !targets.isEmpty {
                let message = ScriptTestError.sendsAppleEvents(step: test.step, targets: targets).errorDescription
                issues.append(ValidationIssue(.error, location, message ?? "Script tests block Apple Events."))
            }
        } else {
            issues.append(ValidationIssue(
                .error,
                location,
                "Step \(test.step) is a \(manifest.steps[test.step].body.typeName) step; "
                    + "script tests run applescript, jxa or shell steps."
            ))
        }
        if !test.hasExpectation {
            issues.append(ValidationIssue(
                .error, location, "Add at least one of expect, expectContains, expectFiles or expectMissing."
            ))
        }
        if let expect = test.expect, let names = try? Template.references(in: expect), !names.isEmpty {
            issues.append(ValidationIssue(
                .error, location, "\"expect\" can only use {{today:<pattern>}}, not {{\(names[0])}}."
            ))
        }
        issues += checkScriptTestPaths(test, location: location, folder: folder)
        return issues
    }

    private static func checkScriptTestPaths(
        _ test: ManifestTest.ScriptTest,
        location: String,
        folder: URL?
    ) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        if let fixtures = test.fixtures {
            if !ScriptTestPaths.isSafeRelative(fixtures) {
                issues.append(ValidationIssue(
                    .error, location, "\"fixtures\" must be a relative folder inside the automation folder."
                ))
            } else if let folder {
                do {
                    _ = try ScriptTestWorkspace.fixturesFolder(fixtures, in: folder)
                } catch {
                    issues.append(ValidationIssue(.error, location, error.localizedDescription))
                }
            }
        }
        for path in test.expectFiles + test.expectMissing where !ScriptTestPaths.isSafeRelative(path) {
            issues.append(ValidationIssue(
                .error, location, "\"\(path)\" must be a path relative to the fixture folder."
            ))
        }
        return issues
    }
}
