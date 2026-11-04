import Foundation

/// Renders a scripting dictionary as compact markdown for the agent: one `##` section per
/// suite, one `###` entry per class, command and enumeration.
public enum SdefSummarizer {
    /// `introspect_app` returns at most this many characters.
    public static let textLimit = 12_000

    /// The whole dictionary (or the entries matching `query`) as markdown.
    public static func markdown(_ dictionary: SdefDictionary, appName: String, query: String? = nil) -> String {
        let trimmed = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let shown = trimmed.isEmpty ? dictionary : dictionary.filtered(trimmed)
        var lines = ["# \(appName) scripting dictionary", ""]
        lines.append("Use with `tell application \"\(appName)\"` (AppleScript) or `Application(\"\(appName)\")` (JXA).")
        if !trimmed.isEmpty {
            lines.append("Showing entries that mention \"\(trimmed)\".")
        }
        if shown.isEmpty {
            lines.append("")
            lines.append("Nothing matches \"\(trimmed)\". Classes and commands in this dictionary:")
            lines.append(index(dictionary))
            return lines.joined(separator: "\n")
        }
        for suite in shown.suites {
            lines.append("")
            lines += render(suite, appName: appName)
        }
        return lines.joined(separator: "\n")
    }

    /// `text` cut at a line boundary to at most `limit` characters.
    public static func capped(_ text: String, limit: Int = textLimit) -> (text: String, truncated: Bool) {
        guard text.count > limit else { return (text, false) }
        var cut = String(text.prefix(limit))
        if let newline = cut.lastIndex(of: "\n") {
            cut = String(cut[..<newline])
        }
        return (cut + "\n…", true)
    }

    /// Names of every class and command, for when a query matched nothing.
    static func index(_ dictionary: SdefDictionary) -> String {
        let classes = dictionary.suites.flatMap { $0.classes.map(\.name) }
        let commands = dictionary.suites.flatMap { $0.commands.map(\.name) }
        return "- classes: " + (classes.isEmpty ? "none" : classes.joined(separator: ", "))
            + "\n- commands: " + (commands.isEmpty ? "none" : commands.joined(separator: ", "))
    }

    static func render(_ suite: SdefDictionary.Suite, appName: String) -> [String] {
        var lines = ["## \(appName) — \(suite.name)"]
        if !suite.description.isEmpty { lines += ["", suite.description] }
        for entry in suite.classes {
            lines += [""] + render(entry)
        }
        for command in suite.commands {
            lines += [""] + render(command)
        }
        for enumeration in suite.enumerations {
            lines += ["", "### enumeration \(enumeration.name)", enumeration.values.joined(separator: ", ")]
        }
        return lines
    }

    static func render(_ entry: SdefDictionary.ClassEntry) -> [String] {
        var details: [String] = []
        if let plural = entry.plural { details.append("plural: \(plural)") }
        if let inherits = entry.inherits { details.append("inherits: \(inherits)") }
        let kind: String
        switch entry.kind {
        case .classDefinition: kind = "class"
        case .classExtension: kind = "class extension"
        case .recordType: kind = "record"
        }
        var lines = ["### \(kind) \(entry.name)" + (details.isEmpty ? "" : " (\(details.joined(separator: "; ")))")]
        if !entry.description.isEmpty { lines.append(entry.description) }
        for property in entry.properties {
            let access = property.readOnly ? ", read-only" : ""
            let about = property.description.isEmpty ? "" : " — \(property.description)"
            lines.append("- property `\(property.name)`: \(property.type)\(access)\(about)")
        }
        if !entry.elements.isEmpty {
            lines.append("- elements: " + entry.elements.joined(separator: ", "))
        }
        if !entry.respondsTo.isEmpty {
            lines.append("- responds to: " + entry.respondsTo.joined(separator: ", "))
        }
        return lines
    }

    static func render(_ command: SdefDictionary.Command) -> [String] {
        var lines = ["### command \(command.name)"]
        if !command.description.isEmpty { lines.append(command.description) }
        var parameters = command.parameters
        if let direct = command.directParameter { parameters.insert(direct, at: 0) }
        for parameter in parameters {
            let optional = parameter.optional ? ", optional" : ""
            let about = parameter.description.isEmpty ? "" : " — \(parameter.description)"
            let name = parameter.name == "direct parameter" ? parameter.name : "`\(parameter.name)`"
            lines.append("- \(name): \(parameter.type)\(optional)\(about)")
        }
        if let result = command.result {
            lines.append("- returns: \(result)")
        }
        return lines
    }
}

// MARK: - Filtering

extension SdefDictionary {
    /// Suites, classes, commands and enumerations whose names or descriptions contain `query`
    /// (case-insensitive). A matching suite is kept whole; a class also matches on its
    /// property names, a command on its parameter names.
    public func filtered(_ query: String) -> SdefDictionary {
        let needle = query.lowercased()
        func matches(_ texts: [String]) -> Bool {
            texts.contains { $0.lowercased().contains(needle) }
        }
        var result = SdefDictionary(title: title, suites: [], includes: includes)
        for suite in suites {
            if matches([suite.name, suite.description]) {
                result.suites.append(suite)
                continue
            }
            var kept = suite
            kept.classes = suite.classes.filter { entry in
                matches([entry.name, entry.description, entry.plural ?? ""] + entry.properties.map(\.name))
            }
            kept.commands = suite.commands.filter { command in
                matches([command.name, command.description] + command.parameters.map(\.name))
            }
            kept.enumerations = suite.enumerations.filter { enumeration in
                matches([enumeration.name] + enumeration.values)
            }
            if !kept.classes.isEmpty || !kept.commands.isEmpty || !kept.enumerations.isEmpty {
                result.suites.append(kept)
            }
        }
        return result
    }
}
