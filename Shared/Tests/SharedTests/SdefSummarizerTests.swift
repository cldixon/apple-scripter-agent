import Foundation
@testable import Shared
import Testing

struct SdefSummarizerTests {
    private static let fixture = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE dictionary SYSTEM "file://localhost/System/Library/DTDs/sdef.dtd">
    <dictionary title="Notes Terminology" xmlns:xi="http://www.w3.org/2003/XInclude">
      <xi:include href="file:///System/Library/ScriptingDefinitions/CocoaStandard.sdef"
                  xpointer="xpointer(/dictionary/suite)"/>
      <suite name="Notes Suite" code="note" description="Terms and Events for controlling the Notes application">
        <class name="note" code="note" description="a note in the Notes application" plural="notes"
               inherits="item">
          <property name="name" code="pnam" type="text" description="the name of the note"/>
          <property name="id" code="ID  " type="text" access="r" description="the unique identifier"/>
          <property name="tags" code="tags">
            <type type="text" list="yes"/>
          </property>
          <property name="secret" code="secr" type="text" hidden="yes"/>
          <element type="attachment"/>
          <responds-to command="show"/>
        </class>
        <class name="internal thing" code="intl" hidden="yes">
          <property name="junk" code="junk" type="text"/>
        </class>
        <command name="show" code="notesshw" description="Show an object in the UI">
          <direct-parameter type="specifier" description="the object to show"/>
          <parameter name="separately" code="sepa" type="boolean" optional="yes"
                     description="Show in a separate window"/>
          <result type="specifier"/>
        </command>
        <enumeration name="save options" code="savo">
          <enumerator name="yes" code="yes "/>
          <enumerator name="no" code="no  "/>
          <enumerator name="ask" code="ask "/>
        </enumeration>
        <event name="note added" code="evntadd"/>
      </suite>
      <suite name="Text Suite" code="TEXT" description="A set of basic classes for text processing.">
        <class-extension extends="application" description="Notes additions">
          <property name="selection" code="sele">
            <type type="note" list="yes"/>
          </property>
        </class-extension>
      </suite>
    </dictionary>
    """

    private func parsed() throws -> SdefDictionary {
        try SdefDictionary.parse(Data(Self.fixture.utf8))
    }

    @Test func parsesSuitesClassesAndCommands() throws {
        let dictionary = try parsed()
        #expect(dictionary.title == "Notes Terminology")
        #expect(dictionary.includes == ["file:///System/Library/ScriptingDefinitions/CocoaStandard.sdef"])
        #expect(dictionary.suites.map { $0.name } == ["Notes Suite", "Text Suite"])

        let notes = try #require(dictionary.suites.first)
        #expect(notes.classes.map { $0.name } == ["note"])
        let note = try #require(notes.classes.first)
        #expect(note.plural == "notes")
        #expect(note.inherits == "item")
        #expect(note.properties.map { $0.name } == ["name", "id", "tags"])
        #expect(note.properties[1].readOnly)
        #expect(note.properties[2].type == "list of text")
        #expect(note.elements == ["attachment"])
        #expect(note.respondsTo == ["show"])

        let show = try #require(notes.commands.first)
        #expect(show.directParameter?.type == "specifier")
        #expect(show.parameters.map { $0.name } == ["separately"])
        #expect(show.parameters.first?.optional == true)
        #expect(show.result == "specifier")
        #expect(notes.enumerations.first?.values == ["yes", "no", "ask"])
        #expect(notes.commands.count == 1)

        let textSuite = try #require(dictionary.suites.last)
        #expect(textSuite.classes.first?.kind == .classExtension)
        #expect(textSuite.classes.first?.name == "application")
        #expect(textSuite.classes.first?.properties.first?.type == "list of note")
    }

    @Test func rendersMarkdown() throws {
        let text = SdefSummarizer.markdown(try parsed(), appName: "Notes")
        #expect(text.hasPrefix("# Notes scripting dictionary"))
        #expect(text.contains("## Notes — Notes Suite"))
        #expect(text.contains("### class note (plural: notes; inherits: item)"))
        #expect(text.contains("- property `id`: text, read-only — the unique identifier"))
        #expect(text.contains("### command show"))
        #expect(text.contains("- direct parameter: specifier — the object to show"))
        #expect(text.contains("- `separately`: boolean, optional — Show in a separate window"))
        #expect(text.contains("- returns: specifier"))
        #expect(text.contains("### enumeration save options"))
        #expect(text.contains("### class extension application"))
        #expect(!text.contains("secret"))
        #expect(!text.contains("internal thing"))
        #expect(!text.contains("note added"))
    }

    @Test func filtersByQuery() throws {
        let dictionary = try parsed()
        let filtered = SdefSummarizer.markdown(dictionary, appName: "Notes", query: "SEPARATE")
        #expect(filtered.contains("### command show"))
        #expect(!filtered.contains("### class note"))

        let byProperty = dictionary.filtered("tags")
        #expect(byProperty.suites.first?.classes.map { $0.name } == ["note"])
        #expect(byProperty.suites.first?.commands.isEmpty == true)

        let bySuite = dictionary.filtered("text processing")
        #expect(bySuite.suites.map { $0.name } == ["Text Suite"])

        let nothing = SdefSummarizer.markdown(dictionary, appName: "Notes", query: "zebra")
        #expect(nothing.contains("Nothing matches \"zebra\""))
        #expect(nothing.contains("- commands: show"))
    }

    @Test func mergesIncludedSuitesOnce() throws {
        var dictionary = try parsed()
        let included = SdefDictionary(title: "Standard", suites: [
            SdefDictionary.Suite(name: "Standard Suite", description: "Common terms"),
            SdefDictionary.Suite(name: "Text Suite", description: "duplicate")
        ])
        dictionary.merge(included)
        #expect(dictionary.suites.map { $0.name } == ["Notes Suite", "Text Suite", "Standard Suite"])
    }

    @Test func capsLongText() {
        let text = (0..<1_000).map { "line \($0)" }.joined(separator: "\n")
        let capped = SdefSummarizer.capped(text, limit: 100)
        #expect(capped.truncated)
        #expect(capped.text.count <= 102)
        let short = SdefSummarizer.capped("short", limit: 100)
        #expect(short.text == "short")
        #expect(!short.truncated)
    }

    @Test func malformedXMLThrows() {
        #expect(throws: SdefError.self) {
            try SdefDictionary.parse(Data("<dictionary><suite>".utf8))
        }
    }

    @Test func emptyDictionaryIsEmpty() throws {
        let dictionary = try SdefDictionary.parse(Data("<dictionary title=\"x\"/>".utf8))
        #expect(dictionary.isEmpty)
        let full = try parsed()
        #expect(!full.isEmpty)
    }

    @Test func dictionaryEntriesUseBundleIDs() throws {
        let entries = ReferenceDocuments.dictionaryEntries(try parsed(), appName: "Notes", bundleID: "com.apple.Notes")
        #expect(entries.contains { $0.id == "sdef/com.apple.Notes/notes-notes-suite" })
        #expect(entries.allSatisfy { $0.source == "sdef: Notes" })
    }
}
