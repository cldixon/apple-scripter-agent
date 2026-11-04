import Foundation
@testable import Shared
import Testing

struct TemplateTests {
    /// 2024-12-30T12:00:00Z
    private static let fixedDate = Date(timeIntervalSince1970: 1_735_560_000)

    @Test func substitutesVariables() throws {
        let rendered = try Template.render(
            "Hello {{name}}, you are {{age}}.",
            variables: ["name": "Ada", "age": "36"],
            now: Self.fixedDate
        )
        #expect(rendered == "Hello Ada, you are 36.")
    }

    @Test func trimsSpacesInsideBraces() throws {
        let rendered = try Template.render("[{{ spaced }}]", variables: ["spaced": "ok"], now: Self.fixedDate)
        #expect(rendered == "[ok]")
    }

    @Test func rendersToday() throws {
        let utc = try #require(TimeZone(identifier: "UTC"))
        let rendered = try Template.render(
            "Date: {{today:yyyy-MM-dd}}",
            variables: [:],
            now: Self.fixedDate,
            timeZone: utc
        )
        #expect(rendered == "Date: 2024-12-30")
    }

    @Test func unknownVariableThrows() {
        #expect(throws: Template.Failure.undefined("nope")) {
            try Template.render("{{nope}}", variables: ["yes": "1"], now: Self.fixedDate)
        }
    }

    @Test func unterminatedThrows() {
        #expect(throws: Template.Failure.unterminated("{{oops")) {
            try Template.render("{{oops", variables: [:], now: Self.fixedDate)
        }
    }

    @Test func plainTextIsUnchanged() throws {
        let text = "No braces here, just } and { alone."
        #expect(try Template.render(text, variables: [:], now: Self.fixedDate) == text)
        #expect(try Template.references(in: text).isEmpty)
    }

    @Test func referencesExcludeToday() throws {
        let names = try Template.references(in: "{{a}} on {{today:yyyy}} then {{ b }}")
        #expect(names == ["a", "b"])
    }

    @Test func referencesThrowOnUnterminated() {
        #expect(throws: Template.Failure.self) { try Template.references(in: "{{a}} {{b") }
    }

    @Test func dateTextFormatsInGivenTimeZone() throws {
        let utc = try #require(TimeZone(identifier: "UTC"))
        #expect(DateText.format(Self.fixedDate, pattern: "yyyy-MM-dd", timeZone: utc) == "2024-12-30")
        #expect(DateText.format(Self.fixedDate, pattern: "yyyy-MM-dd'T'HH:mm", timeZone: utc) == "2024-12-30T12:00")
        let tokyo = try #require(TimeZone(identifier: "Asia/Tokyo"))
        #expect(DateText.format(Self.fixedDate, pattern: "HH:mm", timeZone: tokyo) == "21:00")
    }
}
