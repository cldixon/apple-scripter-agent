import Foundation
@testable import Shared
import Testing

struct DraftStoreTests {
    private func makeStore() -> DraftStore {
        DraftStore(directory: FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
            .appending(path: "drafts", directoryHint: .isDirectory))
    }

    private static let manifest = AutomationManifest(
        id: "word-count",
        name: "Word count",
        trigger: .manual,
        steps: [Step(.shell(ScriptSource(file: "scripts/count.sh")), output: "count")]
    )

    @Test func safeRelativePaths() {
        #expect(DraftStore.safeRelativePath("scripts/run.applescript") == "scripts/run.applescript")
        #expect(DraftStore.safeRelativePath("tests/fixtures/input.txt") == "tests/fixtures/input.txt")
        let unsafe = [
            "", "/etc/passwd", "~/x", "../x", "scripts/../../x", "./x", "scripts//x", "scripts/",
            ".hidden", "scripts/.git/config", "a\\b", "a\u{0}b", "manifest.json", ".."
        ]
        for path in unsafe {
            #expect(DraftStore.safeRelativePath(path) == nil, "\(path) should be rejected")
        }
        #expect(DraftStore.safeRelativePath("scripts/manifest.json") == "scripts/manifest.json")
    }

    @Test func writesAndReplacesDrafts() throws {
        let store = makeStore()
        let folder = try store.write(Self.manifest, files: [
            DraftFile(path: "scripts/count.sh", contents: "echo hi"),
            DraftFile(path: "notes.txt", contents: "old")
        ])
        #expect(folder == store.folder(for: "word-count"))
        #expect(store.exists(id: "word-count"))
        #expect(try store.manifest(id: "word-count") == Self.manifest)
        let script = try String(contentsOf: folder.appending(path: "scripts/count.sh"), encoding: .utf8)
        #expect(script == "echo hi")

        try store.write(Self.manifest, files: [DraftFile(path: "scripts/count.sh", contents: "echo new")])
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "notes.txt").path))
        let replaced = try String(contentsOf: folder.appending(path: "scripts/count.sh"), encoding: .utf8)
        #expect(replaced == "echo new")

        let leftovers = try FileManager.default.contentsOfDirectory(atPath: store.directory.path)
        #expect(leftovers == ["word-count"])
    }

    @Test func unsafePathsWriteNothing() throws {
        let store = makeStore()
        #expect(throws: DraftError.invalidPath("../escape.sh")) {
            try store.write(Self.manifest, files: [
                DraftFile(path: "scripts/count.sh", contents: "echo hi"),
                DraftFile(path: "../escape.sh", contents: "rm -rf ~")
            ])
        }
        #expect(!store.exists(id: "word-count"))
    }

    @Test func invalidIDsAreRejected() {
        let store = makeStore()
        var manifest = Self.manifest
        manifest.id = "../escape"
        #expect(throws: CatalogError.self) { try store.write(manifest, files: []) }
        #expect(!store.exists(id: "../escape"))
    }

    @Test func removeDeletesTheDraft() throws {
        let store = makeStore()
        try store.write(Self.manifest, files: [])
        try store.remove(id: "word-count")
        #expect(!store.exists(id: "word-count"))
        #expect(throws: DraftError.notFound("word-count")) { try store.remove(id: "word-count") }
        #expect(throws: DraftError.notFound("word-count")) { try store.manifestData(id: "word-count") }
    }

    @Test func folderTextSkipsBinariesLargeAndHiddenFiles() throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let scripts = folder.appending(path: "scripts", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: folder.appending(path: "manifest.json"))
        try Data("say hi".utf8).write(to: scripts.appending(path: "run.applescript"))
        try Data([0x00, 0x01, 0x02]).write(to: scripts.appending(path: "compiled.scpt"))
        try Data(repeating: 0x61, count: 100).write(to: folder.appending(path: "big.txt"))
        try Data("secret".utf8).write(to: folder.appending(path: ".hidden"))

        let files = FolderText.textFiles(in: folder, maxBytes: 50)
        #expect(files == ["scripts/run.applescript": "say hi"])
    }
}
