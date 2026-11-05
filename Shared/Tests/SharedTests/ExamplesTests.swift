import Foundation
@testable import Shared
import Testing

/// Every folder in the repository's `Examples/` is a valid automation: its manifest decodes,
/// its id matches the folder, and validation with the folder (script files, permissions,
/// variable flow) finds no errors.
struct ExamplesTests {
    private static let examplesFolder = URL(filePath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "Examples", directoryHint: .isDirectory)

    private func exampleFolders() throws -> [URL] {
        try FileManager.default
            .contentsOfDirectory(
                at: Self.examplesFolder,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    @Test func examplesAreDiscovered() throws {
        let names = Set(try exampleFolders().map { $0.lastPathComponent })
        let backlog: Set<String> = [
            "paste-plain-text", "copy-safari-link", "copy-finder-paths", "quick-reminder", "today-events",
            "archive-downloads", "meeting-mode", "toggle-dark-mode", "window-left-half", "title-case-selection"
        ]
        #expect(backlog.isSubset(of: names), "missing: \(backlog.subtracting(names).sorted())")
    }

    @Test func everyExampleDecodesAndValidates() throws {
        let folders = try exampleFolders()
        #expect(!folders.isEmpty)
        for folder in folders {
            let name = folder.lastPathComponent
            let data = try Data(contentsOf: folder.appending(path: "manifest.json"))
            let manifest = try AutomationManifest.decode(from: data)
            #expect(manifest.id == name, "\(name): id is \(manifest.id)")
            let issues = ManifestValidator.validate(manifest, folder: folder)
            let errors = issues.filter { $0.severity == .error }
            #expect(errors.isEmpty, "\(name): \(errors)")
        }
    }

    @Test func fixtureCasesArePaired() throws {
        let fileManager = FileManager.default
        for folder in try exampleFolders() {
            let fixtures = folder.appending(path: "tests/fixtures", directoryHint: .isDirectory)
            guard let cases = try? fileManager.contentsOfDirectory(at: fixtures, includingPropertiesForKeys: nil)
            else { continue }
            for caseFolder in cases {
                let input = caseFolder.appending(path: "input.json")
                guard fileManager.fileExists(atPath: input.path) else { continue }
                let expected = caseFolder.appending(path: "expected.txt")
                let label = "\(folder.lastPathComponent)/\(caseFolder.lastPathComponent)"
                #expect(fileManager.fileExists(atPath: expected.path), "\(label) has no expected.txt")
                let object = try JSONSerialization.jsonObject(with: Data(contentsOf: input))
                #expect(object is [String: Any], "\(label): input.json must be a JSON object")
            }
        }
    }
}
