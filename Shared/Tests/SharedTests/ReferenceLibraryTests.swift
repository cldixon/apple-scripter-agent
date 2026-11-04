import Foundation
@testable import Shared
import Testing

struct ReferenceLibraryTests {
    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
            .appending(path: "library.sqlite")
    }

    private func makeLibrary() throws -> ReferenceLibrary {
        let library = try ReferenceLibrary(url: temporaryURL())
        try library.replace(origin: "bundled:recipes.md", fingerprint: "v1", entries: Self.entries)
        return library
    }

    private static let entries = [
        ReferenceEntry(
            id: "recipes/text-item-delimiters", title: "Text item delimiters", source: "Recipes",
            text: "## Text item delimiters\n\nSplit text by setting AppleScript's text item delimiters, then restore."
        ),
        ReferenceEntry(
            id: "recipes/clipboard", title: "Clipboard", source: "Recipes",
            text: "## Clipboard\n\nUse `the clipboard` to read and `set the clipboard to` to write."
        ),
        ReferenceEntry(
            id: "recipes/errors", title: "Errors", source: "Recipes",
            text: "## Errors\n\nError -1743 means the user denied Automation permission."
        )
    ]

    @Test func insertSearchAndRead() throws {
        let library = try makeLibrary()
        #expect(try library.count() == 3)

        let hits = try library.search("delimiters", limit: 5)
        #expect(hits.first?.id == "recipes/text-item-delimiters")
        #expect(hits.first?.title == "Text item delimiters")
        #expect(hits.first?.source == "Recipes")
        #expect(hits.first?.snippet.contains("**") == true)

        let chunk = try library.read(id: "recipes/clipboard")
        #expect(chunk?.title == "Clipboard")
        #expect(chunk?.text.contains("set the clipboard to") == true)
        #expect(chunk?.truncated == false)
        #expect(try library.read(id: "missing") == nil)
    }

    @Test func stemmingAndFallbackToAnyTerm() throws {
        let library = try makeLibrary()
        #expect(try library.search("splitting texts", limit: 5).first?.id == "recipes/text-item-delimiters")
        // "zebra" matches nothing, so the search falls back to any term.
        #expect(try library.search("clipboard zebra", limit: 5).first?.id == "recipes/clipboard")
    }

    @Test func hostileQueriesDoNotThrow() throws {
        let library = try makeLibrary()
        let queries = [
            "\"unbalanced", "AND OR NOT", "text-item-delimiters", "NEAR(a b)", "*", "^start", "col:value",
            "-1743", "a'b\"c", "(((", "title: clipboard", "a + b - c", "{x}"
        ]
        for query in queries {
            _ = try library.search(query, limit: 5)
        }
        #expect(try library.search("-1743", limit: 5).first?.id == "recipes/errors")
        #expect(try library.search("text-item-delimiters", limit: 5).first?.id == "recipes/text-item-delimiters")
    }

    @Test func emptyQueryFindsNothing() throws {
        let library = try makeLibrary()
        #expect(try library.search("", limit: 5).isEmpty)
        #expect(try library.search("  -- \"\" ", limit: 5).isEmpty)
    }

    @Test func replacingAnOriginReplacesItsChunks() throws {
        let library = try makeLibrary()
        let finder = ReferenceEntry(
            id: "sdef/com.apple.finder/finder", title: "Finder", source: "sdef: Finder",
            text: "## Finder\n\nclass window"
        )
        try library.replace(origin: "sdef:com.apple.finder", fingerprint: "com.apple.finder@15", entries: [finder])
        #expect(try library.fingerprint(origin: "bundled:recipes.md") == "v1")
        #expect(try library.fingerprint(origin: "sdef:com.apple.finder") == "com.apple.finder@15")
        #expect(try library.fingerprint(origin: "sdef:other") == nil)
        #expect(try library.origins(prefix: "sdef:") == ["sdef:com.apple.finder"])

        try library.replace(origin: "bundled:recipes.md", fingerprint: "v2", entries: [Self.entries[1]])
        #expect(try library.count() == 2)
        #expect(try library.search("delimiters", limit: 5).isEmpty)
        #expect(try library.fingerprint(origin: "bundled:recipes.md") == "v2")

        try library.removeOrigin("sdef:com.apple.finder")
        #expect(try library.count() == 1)
        #expect(try library.search("window", limit: 5).isEmpty)
    }

    @Test func readIsCapped() throws {
        let library = try makeLibrary()
        let chunk = try library.read(id: "recipes/errors", limit: 10)
        #expect(chunk?.text.count == 10)
        #expect(chunk?.truncated == true)
    }

    @Test func reopeningKeepsChunks() throws {
        let url = temporaryURL()
        do {
            let library = try ReferenceLibrary(url: url)
            try library.replace(origin: "bundled:recipes.md", fingerprint: "v1", entries: Self.entries)
        }
        let reopened = try #require(ReferenceLibrary.open(at: url))
        #expect(try reopened.count() == 3)
        #expect(try reopened.search("clipboard", limit: 5).count == 1)
    }

    @Test func queryTerms() {
        #expect(ReferenceQuery.terms("How do I split text-item-delimiters?") == ["split", "text", "item", "delimiters"])
        #expect(ReferenceQuery.terms("the the") == ["the"])
        #expect(ReferenceQuery.terms("\"quoted\" AND (x)") == ["quoted", "x"])
        #expect(ReferenceQuery.expression("Finder window", joiner: "AND") == "\"finder\" AND \"window\"")
        #expect(ReferenceQuery.expression("--", joiner: "OR") == nil)
    }
}
