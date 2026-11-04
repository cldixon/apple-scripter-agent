import Foundation
@testable import Shared
import Testing

/// The bundled notes in `Reference/` (copied into the runner's resources) all chunk cleanly.
struct ReferenceFilesTests {
    private static let folder = URL(filePath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "Reference", directoryHint: .isDirectory)

    private func markdownFiles() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    @Test func expectedFilesExist() throws {
        let names = Set(try markdownFiles().map { $0.lastPathComponent })
        let expected: Set<String> = [
            "applescript-essentials.md", "jxa-essentials.md", "shell-automation.md",
            "shortcuts-and-intents.md", "permissions-and-errors.md", "recipes.md"
        ]
        #expect(expected.isSubset(of: names))
    }

    @Test func everyFileChunks() throws {
        var ids: Set<String> = []
        for file in try markdownFiles() {
            let markdown = try String(contentsOf: file, encoding: .utf8)
            let entries = ReferenceDocuments.bundledEntries(fileName: file.lastPathComponent, markdown: markdown)
            #expect(!entries.isEmpty, "\(file.lastPathComponent) produced no chunks")
            for entry in entries {
                #expect(!entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                #expect(ReferenceChunker.wordCount(entry.text) <= ReferenceChunker.defaultMaxWords)
                #expect(!entry.source.isEmpty)
                #expect(ids.insert(entry.id).inserted, "duplicate id \(entry.id)")
            }
        }
    }
}
