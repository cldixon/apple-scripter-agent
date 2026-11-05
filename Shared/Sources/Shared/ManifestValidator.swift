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
    /// Step types the runner can execute in this build. Accessibility (`ax`) steps come later.
    public static let supportedStepTypes: Set<String> = ["primitive", "applescript", "jxa", "shell", "shortcut"]

    /// Static checks. With `folder` (the automation's folder), script files are also checked
    /// to exist and are read for the apps they control.
    public static func validate(
        _ manifest: AutomationManifest,
        supportedStepTypes: Set<String> = supportedStepTypes,
        folder: URL? = nil
    ) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        issues += checkIdentity(manifest)
        issues += checkSteps(manifest, supportedStepTypes: supportedStepTypes)
        issues += checkPermissions(manifest)
        issues += checkScripts(manifest, folder: folder)
        issues += checkTests(manifest, folder: folder)
        return issues
    }

    /// The source of a script step: inline, or read from `folder`. Nil when it cannot be read.
    public static func scriptText(_ source: ScriptSource, folder: URL?) -> String? {
        if let inline = source.source { return inline }
        guard let path = source.file, let folder else { return nil }
        return try? String(contentsOf: folder.appending(path: path), encoding: .utf8)
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
            if case .primitive(let primitive) = step.body {
                issues += checkPrimitive(primitive, location: location)
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

    /// Arguments of primitives that can be checked before running.
    private static func checkPrimitive(_ primitive: Primitive, location: String) -> [ValidationIssue] {
        switch primitive {
        case .pressKeys(let keys):
            do {
                _ = try KeyCombo.parse(keys)
            } catch {
                return [ValidationIssue(.error, location, "pressKeys: \(error.localizedDescription)")]
            }
        case .askText(let prompt, _):
            if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return [ValidationIssue(.error, location, "askText needs a prompt to show the user.")]
            }
        default:
            break
        }
        return []
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

    private static func checkScripts(_ manifest: AutomationManifest, folder: URL?) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        let declaredTargets = Set(manifest.permissions.compactMap(\.automationTarget))
        for (index, step) in manifest.steps.enumerated() {
            let location = "steps[\(index)]"
            let language: ScriptLanguage
            let source: ScriptSource
            switch step.body {
            case .applescript(let script): (language, source) = (.applescript, script)
            case .jxa(let script): (language, source) = (.jxa, script)
            case .shell(let script): (language, source) = (.shell, script)
            default: continue
            }
            if let path = source.file {
                if path.hasPrefix("/") || path.split(separator: "/").contains("..") {
                    issues.append(ValidationIssue(
                        .error, location, "Script file must be inside the automation folder."
                    ))
                } else if let folder, !FileManager.default.fileExists(atPath: folder.appending(path: path).path) {
                    issues.append(ValidationIssue(.error, location, "Script file \(path) is missing."))
                }
            }
            guard let text = scriptText(source, folder: folder) else { continue }
            let targets = ScriptAnalysis.targetApplications(in: text, language: language)
                .filter { !ScriptAnalysis.exemptTargets.contains($0) }
            if !targets.isEmpty, declaredTargets.isEmpty {
                issues.append(ValidationIssue(
                    .error,
                    location,
                    "The script controls \(targets.joined(separator: ", ")); declare an "
                        + "automation:<bundle id> permission for each, e.g. automation:com.apple.finder."
                ))
            }
        }
        return issues
    }
}
