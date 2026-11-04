import Foundation

/// Turns the reference library's sources into markdown and chunks: bundled notes, man
/// pages, scripting dictionaries and installed automations.
public enum ReferenceDocuments {
    /// Man pages indexed by the runner.
    public static let manPages = [
        "osascript", "shortcuts", "defaults", "launchctl", "pmset", "networksetup", "scutil", "mdfind", "plutil"
    ]

    // MARK: Bundled notes

    /// Chunks of one bundled markdown file. The source is its `#` title; ids start with the
    /// file name without extension.
    public static func bundledEntries(fileName: String, markdown: String) -> [ReferenceEntry] {
        let stem = (fileName as NSString).deletingPathExtension
        let title = markdown.split(separator: "\n", omittingEmptySubsequences: true)
            .lazy
            .compactMap { ReferenceChunker.heading(String($0)) }
            .first { $0.level == 1 }?
            .title ?? stem
        return ReferenceChunker.chunk(markdown: markdown, idPrefix: stem, source: title)
    }

    // MARK: Man pages

    /// `man -P cat` output as markdown: backspace overstrikes removed, section names
    /// (uppercase lines at column 0) as `##` headings.
    public static func manPageMarkdown(name: String, raw: String) -> String {
        let plain = stripOverstrikes(raw)
        var lines = ["# man \(name)"]
        var blankRun = 0
        for line in plain.split(separator: "\n", omittingEmptySubsequences: false).map({ String($0) }) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                blankRun += 1
                if blankRun == 1 { lines.append("") }
                continue
            }
            blankRun = 0
            if isSectionName(line) {
                lines += ["", "## \(name) — \(trimmed)", ""]
            } else if line.hasPrefix("#") {
                lines.append(" " + line)
            } else {
                lines.append(line)
            }
        }
        return lines.joined(separator: "\n")
    }

    public static func manPageEntries(name: String, raw: String) -> [ReferenceEntry] {
        ReferenceChunker.chunk(
            markdown: manPageMarkdown(name: name, raw: raw), idPrefix: "man/\(name)", source: "man: \(name)"
        )
    }

    /// Removes `x\bx` (bold) and `_\bx` (underline) sequences.
    public static func stripOverstrikes(_ text: String) -> String {
        var scalars: [Unicode.Scalar] = []
        for scalar in text.unicodeScalars {
            if scalar == "\u{8}" {
                if !scalars.isEmpty { scalars.removeLast() }
            } else {
                scalars.append(scalar)
            }
        }
        var result = ""
        result.unicodeScalars.append(contentsOf: scalars)
        return result
    }

    static func isSectionName(_ line: String) -> Bool {
        guard let first = line.first, first.isLetter, first.isUppercase, line.count <= 40 else { return false }
        return line == line.uppercased() && !line.contains("(")
    }

    // MARK: Scripting dictionaries

    public static func dictionaryEntries(
        _ dictionary: SdefDictionary,
        appName: String,
        bundleID: String
    ) -> [ReferenceEntry] {
        ReferenceChunker.chunk(
            markdown: SdefSummarizer.markdown(dictionary, appName: appName),
            idPrefix: "sdef/\(bundleID)",
            source: "sdef: \(appName)"
        )
    }

    // MARK: Installed automations

    /// An installed automation as a worked example: its manifest and script files.
    public static func automationMarkdown(
        _ manifest: AutomationManifest,
        manifestJSON: String,
        files: [String: String]
    ) -> String {
        var lines = ["# Example automation: \(manifest.name)", ""]
        lines.append("## \(manifest.name) (\(manifest.id))")
        lines.append("")
        if let description = manifest.description { lines += [description, ""] }
        lines.append("Trigger: \(manifest.trigger.summary). Steps: "
            + manifest.steps.map(\.body.typeName).joined(separator: ", ") + ".")
        lines += ["", "### manifest.json", "", "```json", manifestJSON, "```"]
        for path in files.keys.sorted() {
            lines += ["", "### \(path)", "", "```\(fenceLanguage(path))", files[path] ?? "", "```"]
        }
        return lines.joined(separator: "\n")
    }

    public static func automationEntries(
        _ manifest: AutomationManifest,
        manifestJSON: String,
        files: [String: String]
    ) -> [ReferenceEntry] {
        ReferenceChunker.chunk(
            markdown: automationMarkdown(manifest, manifestJSON: manifestJSON, files: files),
            idPrefix: "example/\(manifest.id)",
            source: "installed automation: \(manifest.id)",
            maxWords: 1_200
        )
    }

    static func fenceLanguage(_ path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "applescript": "applescript"
        case "js", "jxa": "javascript"
        case "sh", "zsh", "bash", "shell": "sh"
        case "json": "json"
        default: ""
        }
    }
}
