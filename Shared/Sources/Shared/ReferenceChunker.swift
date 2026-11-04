import Foundation

/// One searchable piece of the reference library: a heading section of a markdown document.
public struct ReferenceEntry: Sendable, Equatable {
    /// Stable id: `<prefix>/<heading slug>`, with `-2`, `-3` for repeated headings and
    /// `-part2`, `-part3` for the later pieces of a long section.
    public var id: String
    public var title: String
    public var source: String
    public var text: String

    public init(id: String, title: String, source: String, text: String) {
        self.id = id
        self.title = title
        self.source = source
        self.text = text
    }
}

/// Splits markdown into chunks of one heading section each (`#` and `##` start a section).
/// A section longer than `maxWords` is split at its `###` subheadings and paragraphs; code
/// fences are never split unless one fence alone is too long.
public enum ReferenceChunker {
    public static let defaultMaxWords = 800

    public static func chunk(
        markdown: String,
        idPrefix: String,
        source: String,
        maxWords: Int = defaultMaxWords
    ) -> [ReferenceEntry] {
        var entries: [ReferenceEntry] = []
        var usedIDs: Set<String> = []
        for section in sections(of: markdown, fallbackTitle: source) {
            let body = section.lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            let base = uniqueID("\(idPrefix)/\(slug(section.title))", used: &usedIDs)

            let headingLine = String(repeating: "#", count: section.level) + " " + section.title
            let whole = headingLine + "\n\n" + body
            guard wordCount(whole) > maxWords else {
                entries.append(ReferenceEntry(id: base, title: section.title, source: source, text: whole))
                continue
            }
            let pieces = split(section.lines, maxWords: max(maxWords - wordCount(headingLine) - 1, 50))
            for (offset, piece) in pieces.enumerated() {
                let part = offset + 1
                if part > 1 { usedIDs.insert("\(base)-part\(part)") }
                let header = part == 1 ? headingLine : headingLine + " (continued)"
                entries.append(ReferenceEntry(
                    id: part == 1 ? base : "\(base)-part\(part)",
                    title: part == 1 ? section.title : "\(section.title) (part \(part))",
                    source: source,
                    text: header + "\n\n" + piece
                ))
            }
        }
        return entries
    }

    /// `base`, or `base-2`, `base-3`, … when it is taken. Records the result in `used`.
    static func uniqueID(_ base: String, used: inout Set<String>) -> String {
        var candidate = base
        var number = 2
        while used.contains(candidate) {
            candidate = "\(base)-\(number)"
            number += 1
        }
        used.insert(candidate)
        return candidate
    }

    /// Lowercase ASCII letters and digits joined by single hyphens; "section" if none.
    public static func slug(_ text: String) -> String {
        var result = ""
        var pendingHyphen = false
        for scalar in text.lowercased().unicodeScalars {
            let isWordCharacter = (scalar >= "a" && scalar <= "z") || (scalar >= "0" && scalar <= "9")
            if isWordCharacter {
                if pendingHyphen, !result.isEmpty { result += "-" }
                result.unicodeScalars.append(scalar)
                pendingHyphen = false
            } else {
                pendingHyphen = true
            }
        }
        return result.isEmpty ? "section" : String(result.prefix(80))
    }

    public static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }

    // MARK: Sections

    struct Section {
        var title: String
        var level: Int
        var lines: [String]
    }

    /// `(level, title)` for an ATX heading at column 0, e.g. `## Title`.
    static func heading(_ line: String) -> (level: Int, title: String)? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = line.dropFirst(hashes)
        guard let first = rest.first, first == " " else { return nil }
        let title = rest.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
            .trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? nil : (hashes, title)
    }

    static func isFence(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~")
    }

    static func sections(of markdown: String, fallbackTitle: String) -> [Section] {
        var sections: [Section] = []
        var current: Section?
        var inFence = false
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0) }
        for line in lines {
            if isFence(line) { inFence.toggle() }
            if !inFence, let found = heading(line), found.level <= 2 {
                if let current { sections.append(current) }
                current = Section(title: found.title, level: found.level, lines: [])
                continue
            }
            if current == nil {
                current = Section(title: fallbackTitle, level: 1, lines: [])
            }
            current?.lines.append(line)
        }
        if let current { sections.append(current) }
        return sections
    }

    // MARK: Splitting long sections

    /// Blocks are paragraphs (separated by blank lines) with code fences kept whole; a
    /// subheading always starts a new block.
    static func blocks(_ lines: [String]) -> [[String]] {
        var blocks: [[String]] = []
        var current: [String] = []
        var inFence = false
        for line in lines {
            let fence = isFence(line)
            if !inFence, !fence, heading(line) != nil, !current.isEmpty {
                blocks.append(current)
                current = []
            }
            if !inFence, !fence, line.trimmingCharacters(in: .whitespaces).isEmpty {
                if !current.isEmpty { blocks.append(current) }
                current = []
                continue
            }
            if fence { inFence.toggle() }
            current.append(line)
        }
        if !current.isEmpty { blocks.append(current) }
        return blocks
    }

    /// Packs blocks into pieces of at most `maxWords`, preferring to break before a subheading.
    static func split(_ lines: [String], maxWords: Int) -> [String] {
        var pieces: [String] = []
        var current: [String] = []
        var currentWords = 0

        func flush() {
            let text = current.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { pieces.append(text) }
            current = []
            currentWords = 0
        }

        for block in blocks(lines) {
            let text = block.joined(separator: "\n")
            let words = wordCount(text)
            let startsWithHeading = block.first.map { heading($0) != nil } ?? false
            let full = currentWords + words > maxWords
            let goodBreak = startsWithHeading && currentWords >= maxWords / 2
            if !current.isEmpty, full || goodBreak {
                flush()
            }
            if words > maxWords {
                for part in hardSplit(block, maxWords: maxWords) {
                    current = [part]
                    flush()
                }
                continue
            }
            current.append(text)
            currentWords += words
        }
        flush()
        return pieces
    }

    /// Splits one oversized block by lines.
    static func hardSplit(_ block: [String], maxWords: Int) -> [String] {
        var parts: [String] = []
        var current: [String] = []
        var words = 0
        for line in block {
            let count = wordCount(line)
            if !current.isEmpty, words + count > maxWords {
                parts.append(current.joined(separator: "\n"))
                current = []
                words = 0
            }
            current.append(line)
            words += count
        }
        if !current.isEmpty { parts.append(current.joined(separator: "\n")) }
        return parts
    }
}
