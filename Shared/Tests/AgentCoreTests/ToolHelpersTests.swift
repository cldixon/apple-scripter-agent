@testable import AgentCore
import Foundation
import Testing

struct HTMLTextTests {
    @Test func dropsScriptsStylesAndCommentsAndKeepsText() {
        let html = """
            <html><head><title>T</title><style>p { color: red }</style></head>
            <body><!-- note --><script>alert("x")</script>
            <h1>Title</h1><p>First   paragraph.</p><p>Second<br>line</p>
            </body></html>
            """
        let text = HTMLText.plainText(fromHTML: html)
        #expect(text == "Title\n\nFirst paragraph.\n\nSecond\nline")
        #expect(!text.contains("alert"))
        #expect(!text.contains("color"))
        #expect(!text.contains("note"))
    }

    @Test func decodesEntities() {
        #expect(HTMLText.decodingEntities("a &lt;b&gt; &amp; &quot;c&quot;") == "a <b> & \"c\"")
        #expect(HTMLText.decodingEntities("&#65;&#x42;") == "AB")
        #expect(HTMLText.decodingEntities("&amp;lt;") == "&lt;")
    }

    @Test func collapsesWhitespaceAndBlankLines() {
        let text = HTMLText.collapsingWhitespace("  a \t b  \n\n\n\n c \n\n")
        #expect(text == "a b\n\nc")
    }

    @Test func stripsInlineTags() {
        let text = HTMLText.plainText(fromHTML: "<p>Use <code>tell</code> <a href=\"x\">blocks</a>.</p>")
        #expect(text == "Use tell blocks .")
    }
}

struct FetchPolicyTests {
    @Test func allowsHTTPSOnListedHosts() throws {
        let url = try FetchPolicy.validatedURL("https://ss64.com/mac/pmset.html")
        #expect(url.host == "ss64.com")
        #expect(throws: Never.self) { try FetchPolicy.validatedURL("https://Developer.Apple.com/documentation") }
    }

    @Test func rejectsOtherSchemesHostsAndCredentials() {
        #expect(throws: ToolError.self) { try FetchPolicy.validatedURL("http://ss64.com/") }
        #expect(throws: ToolError.self) { try FetchPolicy.validatedURL("https://example.com/") }
        #expect(throws: ToolError.self) { try FetchPolicy.validatedURL("https://evil.ss64.com.example/") }
        #expect(throws: ToolError.self) { try FetchPolicy.validatedURL("https://user:pw@ss64.com/") }
        #expect(throws: ToolError.self) { try FetchPolicy.validatedURL("file:///etc/passwd") }
        #expect(throws: ToolError.self) { try FetchPolicy.validatedURL("not a url") }
    }

    @Test func resultStartsWithTheUntrustedNoticeAndIsCapped() {
        let long = String(repeating: "x", count: FetchPolicy.maxCharacters + 50)
        let result = FetchPolicy.result(url: "https://ss64.com/", text: long)
        #expect(result.hasPrefix("[Untrusted web content"))
        #expect(result.contains("URL: https://ss64.com/"))
        #expect(result.contains("[Truncated: 50 more characters not shown.]"))
    }
}

struct ToolInputTests {
    @Test func readsRequiredAndOptionalStrings() throws {
        let input: JSONValue = ["id": "abc", "blank": "  ", "count": 3]
        #expect(try input.requiredString("id") == "abc")
        #expect(throws: ToolError.self) { try input.requiredString("blank") }
        #expect(throws: ToolError.self) { try input.requiredString("missing") }
        #expect(input.optionalString("blank") == nil)
        #expect(input.optionalString("id") == "abc")
    }

    @Test func clampsNumbers() {
        let input: JSONValue = ["limit": 500, "low": -2, "timeout": .double(2.5)]
        #expect(input.clampedInt("limit", default: 10, range: 1...50) == 50)
        #expect(input.clampedInt("low", default: 10, range: 1...50) == 1)
        #expect(input.clampedInt("missing", default: 10, range: 1...50) == 10)
        #expect(input.clampedNumber("timeout", default: 10, range: 1...60) == 2.5)
        #expect(input.clampedNumber("limit", default: 10, range: 1...60) == 60)
    }

    @Test func readsStringArrays() {
        let input: JSONValue = ["items": ["a", 1, "b"]]
        #expect(input.stringArray("items") == ["a", "b"])
        #expect(input.stringArray("missing").isEmpty)
    }
}

struct TextSearchTests {
    @Test func matchesEveryWordInAnyField() {
        let fields: [String?] = ["insert-iso-date", "Insert ISO date", nil]
        #expect(TextSearch.matches("", fields: fields))
        #expect(TextSearch.matches("iso DATE", fields: fields))
        #expect(!TextSearch.matches("iso finder", fields: fields))
        #expect(TextSearch.matches("café", fields: ["Cafe menu"]))
    }

    @Test func capsText() {
        #expect(ToolText.capped("abc", limit: 5) == "abc")
        #expect(ToolText.capped("abcdef", limit: 4) == "abcd\n[Truncated: 2 more characters not shown.]")
    }
}

struct AgentPromptTests {
    @Test func assembledPromptCarriesTheSchemaAndTheWorkflow() {
        let prompt = AgentPrompt.assembled(manifestSchema: "\n{ \"title\": \"Automation manifest\" }\n")
        #expect(prompt.hasPrefix(AgentPrompt.system))
        #expect(prompt.hasSuffix("```json\n{ \"title\": \"Automation manifest\" }\n```"))
        for tool in ["search_catalog", "introspect_app", "write_draft", "validate", "request_install", "ask_user"] {
            #expect(prompt.contains(tool))
        }
        // Stable across calls, so it caches.
        #expect(prompt == AgentPrompt.assembled(manifestSchema: "\n{ \"title\": \"Automation manifest\" }\n"))
    }
}
