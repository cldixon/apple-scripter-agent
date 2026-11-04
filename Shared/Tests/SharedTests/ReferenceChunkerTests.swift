import Foundation
@testable import Shared
import Testing

struct ReferenceChunkerTests {
    private static let sample = """
    # AppleScript essentials

    Short notes on the language.

    ## Text item delimiters

    Set `AppleScript's text item delimiters` to split and join text.

    ### Restoring them

    Always restore the old value.

    ## Empty section

    ## Lists

    ```applescript
    # not a heading inside a fence
    set theList to {1, 2, 3}
    ```
    """

    @Test func chunksOneSectionPerHeading() {
        let entries = ReferenceChunker.chunk(markdown: Self.sample, idPrefix: "essentials", source: "Essentials")
        #expect(entries.map { $0.id } == [
            "essentials/applescript-essentials",
            "essentials/text-item-delimiters",
            "essentials/lists"
        ])
        #expect(entries.map { $0.title } == ["AppleScript essentials", "Text item delimiters", "Lists"])
        #expect(entries.allSatisfy { $0.source == "Essentials" })
        #expect(entries[1].text.hasPrefix("## Text item delimiters"))
        #expect(entries[1].text.contains("### Restoring them"))
        #expect(entries[2].text.contains("# not a heading inside a fence"))
    }

    @Test func idsAreStable() {
        let first = ReferenceChunker.chunk(markdown: Self.sample, idPrefix: "doc", source: "Doc")
        let second = ReferenceChunker.chunk(markdown: Self.sample, idPrefix: "doc", source: "Doc")
        #expect(first == second)
    }

    @Test func repeatedHeadingsGetSuffixes() {
        let markdown = "## Example\n\none\n\n## Example\n\ntwo\n\n## Example\n\nthree"
        let entries = ReferenceChunker.chunk(markdown: markdown, idPrefix: "doc", source: "Doc")
        #expect(entries.map { $0.id } == ["doc/example", "doc/example-2", "doc/example-3"])
    }

    @Test func textBeforeAnyHeadingUsesTheSourceAsTitle() {
        let entries = ReferenceChunker.chunk(markdown: "Just text.", idPrefix: "doc", source: "Loose notes")
        #expect(entries.count == 1)
        #expect(entries.first?.id == "doc/loose-notes")
    }

    @Test func longSectionsAreSplitWithinTheLimit() {
        let paragraph = Array(repeating: "word", count: 90).joined(separator: " ")
        var body: [String] = []
        for index in 0..<20 {
            if index % 5 == 0 { body.append("### Part \(index)") }
            body.append(paragraph)
        }
        let markdown = "## Long section\n\n" + body.joined(separator: "\n\n")
        let entries = ReferenceChunker.chunk(markdown: markdown, idPrefix: "doc", source: "Doc", maxWords: 400)
        #expect(entries.count > 3)
        #expect(entries.first?.id == "doc/long-section")
        #expect(entries.dropFirst().first?.id == "doc/long-section-part2")
        #expect(entries.dropFirst().first?.title == "Long section (part 2)")
        #expect(entries.allSatisfy { ReferenceChunker.wordCount($0.text) <= 400 })
        #expect(entries.allSatisfy { !$0.text.isEmpty })
        let words = entries.map { $0.text.components(separatedBy: "word").count - 1 }.reduce(0, +)
        #expect(words == 20 * 90)
    }

    @Test func oversizedSingleBlockIsSplitByLines() {
        let lines = (0..<300).map { "line \($0) has five words" }.joined(separator: "\n")
        let entries = ReferenceChunker.chunk(
            markdown: "## Big\n\n```\n\(lines)\n```", idPrefix: "doc", source: "Doc", maxWords: 200
        )
        #expect(entries.count > 1)
        #expect(entries.allSatisfy { ReferenceChunker.wordCount($0.text) <= 200 })
    }

    @Test func slugs() {
        #expect(ReferenceChunker.slug("Text item delimiters") == "text-item-delimiters")
        #expect(ReferenceChunker.slug("  POSIX path ↔ alias (files)!  ") == "posix-path-alias-files")
        #expect(ReferenceChunker.slug("-1743: not authorized") == "1743-not-authorized")
        #expect(ReferenceChunker.slug("→") == "section")
    }

    @Test func manPagesBecomeSections() {
        let raw = "PMSET(1)  General Commands Manual  PMSET(1)\n\nN\u{8}NA\u{8}AM\u{8}ME\u{8}E\n"
            + "     pmset -- manipulate power management settings\n\nDESCRIPTION\n     pmset changes settings.\n"
            + "# not a heading\n"
        #expect(ReferenceDocuments.stripOverstrikes("N\u{8}NA\u{8}A") == "NA")
        let entries = ReferenceDocuments.manPageEntries(name: "pmset", raw: raw)
        #expect(entries.contains { $0.id == "man/pmset/pmset-name" })
        #expect(entries.contains { $0.id == "man/pmset/pmset-description" })
        #expect(entries.allSatisfy { $0.source == "man: pmset" })
        #expect(entries.contains { $0.text.contains(" # not a heading") })
    }
}
