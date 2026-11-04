import Foundation

/// A problem found by static validation. Errors block install; warnings are shown.
public struct ValidationIssue: Codable, Sendable, Equatable, Hashable, CustomStringConvertible {
    public enum Severity: String, Codable, Sendable {
        case error, warning
    }

    public var severity: Severity
    /// Where in the manifest, e.g. `steps[1]` or `tests[0]`.
    public var location: String
    public var message: String

    public init(_ severity: Severity, _ location: String, _ message: String) {
        self.severity = severity
        self.location = location
        self.message = message
    }

    public var description: String { "\(severity.rawValue): \(location): \(message)" }
}

/// Static checks that need no runner: shape, variable flow, declared permissions.
public enum ManifestValidator {
    /// Step types the runner can execute in this build. Script steps arrive in M2.
    public static let supportedStepTypes: Set<String> = ["primitive"]

    public static func validate(
        _ manifest: AutomationManifest,
        supportedStepTypes: Set<String> = supportedStepTypes
    ) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        issues += checkIdentity(manifest)
        issues += checkSteps(manifest, supportedStepTypes: supportedStepTypes)
        issues += checkPermissions(manifest)
        issues += checkTests(manifest)
        return issues
    }

    public static func hasErrors(_ issues: [ValidationIssue]) -> Bool {
        issues.contains { $0.severity == .error }
    }

    private static func checkIdentity(_ manifest: AutomationManifest) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        if manifest.id.isEmpty || manifest.id.unicodeScalars.contains(where: { !allowed.contains($0) }) {
            issues.append(ValidationIssue(
                .error, "id", "Use lowercase letters, digits and hyphens, like insert-iso-date."
            ))
        }
        if manifest.name.trimmingCharacters(in: .whitespaces).isEmpty {
            issues.append(ValidationIssue(.error, "name", "Name is empty."))
        }
        if manifest.version < 1 {
            issues.append(ValidationIssue(.error, "version", "Version starts at 1."))
        }
        if case .hotkey(let hotkey) = manifest.trigger {
            if KeyCodes.virtualKeyCode(for: hotkey.key) == nil {
                issues.append(ValidationIssue(.error, "trigger.key", "Unknown key \"\(hotkey.key)\"."))
            }
            if hotkey.modifiers.isEmpty {
                issues.append(ValidationIssue(
                    .warning, "trigger.modifiers", "A hotkey without modifiers captures that key everywhere."
                ))
            }
        }
        return issues
    }

    private static func checkSteps(
        _ manifest: AutomationManifest,
        supportedStepTypes: Set<String>
    ) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        if manifest.steps.isEmpty {
            issues.append(ValidationIssue(.error, "steps", "An automation needs at least one step."))
        }
        var defined: Set<String> = []
        for (index, step) in manifest.steps.enumerated() {
            let location = "steps[\(index)]"
            if !supportedStepTypes.contains(step.body.typeName) {
                issues.append(ValidationIssue(
                    .error, location, "Step type \"\(step.body.typeName)\" is not supported by this runner yet."
                ))
            }
            for text in step.templateStrings {
                do {
                    for name in try Template.references(in: text) where !defined.contains(name) {
                        issues.append(ValidationIssue(
                            .error, location, "{{\(name)}} is not defined by an earlier step."
                        ))
                    }
                } catch {
                    issues.append(ValidationIssue(.error, location, error.localizedDescription))
                }
            }
            if step.effectiveTimeout <= 0 {
                issues.append(ValidationIssue(.error, location, "Timeout must be positive."))
            }
            if let output = step.output {
                if defined.contains(output) {
                    issues.append(ValidationIssue(.warning, location, "Output name \"\(output)\" is reused."))
                }
                defined.insert(output)
            }
        }
        return issues
    }

    private static func checkPermissions(_ manifest: AutomationManifest) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        let declared = Set(manifest.permissions)
        for (index, step) in manifest.steps.enumerated() {
            guard case .primitive(let primitive) = step.body else { continue }
            for permission in primitive.requiredPermissions where !declared.contains(permission) {
                issues.append(ValidationIssue(
                    .error,
                    "steps[\(index)]",
                    "\(primitive.actionName) needs the \"\(permission)\" permission; declare it."
                ))
            }
        }
        return issues
    }

    private static func checkTests(_ manifest: AutomationManifest) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        for (index, test) in manifest.tests.enumerated() {
            if case .unit(let unit) = test, !manifest.steps.indices.contains(unit.step) {
                issues.append(ValidationIssue(.error, "tests[\(index)]", "Step \(unit.step) does not exist."))
            }
        }
        if manifest.tests.isEmpty {
            issues.append(ValidationIssue(.warning, "tests", "No tests declared."))
        }
        return issues
    }
}
