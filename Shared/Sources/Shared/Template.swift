import Foundation

/// `{{name}}` substitution between steps, plus `{{today:<pattern>}}` for tests.
public enum Template {
    public enum Failure: Error, Equatable, LocalizedError {
        case undefined(String)
        case unterminated(String)

        public var errorDescription: String? {
            switch self {
            case .undefined(let name): "Template variable {{\(name)}} is not defined by an earlier step."
            case .unterminated(let text): "Unterminated {{ in \"\(text)\"."
            }
        }
    }

    private enum Token {
        case literal(Substring)
        case variable(String)
    }

    /// Replaces every `{{name}}` with `variables[name]` and `{{today:pattern}}` with `now` formatted.
    public static func render(
        _ text: String,
        variables: [String: String],
        now: Date,
        timeZone: TimeZone = .current
    ) throws -> String {
        var result = ""
        for token in try tokenize(text) {
            switch token {
            case .literal(let literal):
                result += literal
            case .variable(let name):
                if let pattern = todayPattern(name) {
                    result += DateText.format(now, pattern: pattern, timeZone: timeZone)
                } else if let value = variables[name] {
                    result += value
                } else {
                    throw Failure.undefined(name)
                }
            }
        }
        return result
    }

    /// Variable names referenced in `text`, excluding `today:` placeholders.
    public static func references(in text: String) throws -> [String] {
        try tokenize(text).compactMap { token in
            if case .variable(let name) = token, todayPattern(name) == nil { return name }
            return nil
        }
    }

    private static func todayPattern(_ name: String) -> String? {
        name.hasPrefix("today:") ? String(name.dropFirst("today:".count)) : nil
    }

    private static func tokenize(_ text: String) throws -> [Token] {
        var tokens: [Token] = []
        var rest = text[...]
        while let open = rest.range(of: "{{") {
            tokens.append(.literal(rest[..<open.lowerBound]))
            let afterOpen = rest[open.upperBound...]
            guard let close = afterOpen.range(of: "}}") else { throw Failure.unterminated(text) }
            let name = afterOpen[..<close.lowerBound].trimmingCharacters(in: .whitespaces)
            tokens.append(.variable(name))
            rest = afterOpen[close.upperBound...]
        }
        tokens.append(.literal(rest))
        return tokens
    }
}

/// Date formatting shared by `formatDate` and `{{today:...}}`: fixed POSIX locale so
/// patterns mean the same thing on every Mac.
public enum DateText {
    public static func format(_ date: Date, pattern: String, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}
