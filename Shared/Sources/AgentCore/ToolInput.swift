import Foundation

/// Reading tool input. `SchemaValidator` has already checked types, so these mostly turn
/// missing or empty values into clear errors and clamp numbers to sane ranges.
extension JSONValue {
    /// Any JSON number as a Double.
    public var numberValue: Double? {
        switch self {
        case .int(let value): Double(value)
        case .double(let value): value
        default: nil
        }
    }

    /// A string property that must be present and not blank.
    public func requiredString(_ key: String) throws -> String {
        guard let value = self[key]?.stringValue,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ToolError("\"\(key)\" is required and must be a non-empty string.")
        }
        return value
    }

    /// A string property, or nil when it is missing or blank.
    public func optionalString(_ key: String) -> String? {
        guard let value = self[key]?.stringValue,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }

    /// An integer property clamped to `range`, or `defaultValue` when missing.
    public func clampedInt(_ key: String, default defaultValue: Int, range: ClosedRange<Int>) -> Int {
        let value = self[key]?.intValue ?? defaultValue
        return min(max(value, range.lowerBound), range.upperBound)
    }

    /// A number property clamped to `range`, or `defaultValue` when missing.
    public func clampedNumber(_ key: String, default defaultValue: Double, range: ClosedRange<Double>) -> Double {
        let value = self[key]?.numberValue ?? defaultValue
        return min(max(value, range.lowerBound), range.upperBound)
    }

    /// The strings in an array property (non-strings are skipped), or [] when missing.
    public func stringArray(_ key: String) -> [String] {
        self[key]?.arrayValue?.compactMap(\.stringValue) ?? []
    }
}

/// Matching a free-text query against a few fields, as `search_catalog` does.
public enum TextSearch {
    /// True when every word of `query` appears (case- and diacritic-insensitively) in at
    /// least one of `fields`. A blank query matches everything.
    public static func matches(_ query: String, fields: [String?]) -> Bool {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return true }
        let haystack = fields.compactMap(\.self).map(normalized)
        return words.allSatisfy { word in
            let needle = normalized(word)
            return haystack.contains { $0.contains(needle) }
        }
    }

    private static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
    }
}

/// Shortening text for tool results.
public enum ToolText {
    /// `text` cut to at most `limit` characters, with a note saying how much was dropped.
    public static func capped(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "\n[Truncated: \(text.count - limit) more characters not shown.]"
    }

    /// Compact JSON for an Encodable value (sorted keys, ISO 8601 dates), for tool results.
    public static func json(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        return String(bytes: data, encoding: .utf8) ?? "{}"
    }
}
