import Foundation

public enum DraftError: LocalizedError, Equatable {
    case invalidPath(String)
    case notFound(String)

    public var errorDescription: String? {
        switch self {
        case .invalidPath(let path):
            "\"\(path)\" is not a safe relative path inside the draft folder (no absolute paths, \"..\", "
                + "hidden names or manifest.json)."
        case .notFound(let id): "There is no draft named \(id)."
        }
    }
}

/// The agent's working area: `drafts/<id>/manifest.json` plus script and fixture files.
/// Drafts are not versioned; installing one goes through the normal install path.
public struct DraftStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public func folder(for id: String) -> URL {
        directory.appending(path: id, directoryHint: .isDirectory)
    }

    public func manifestURL(for id: String) -> URL {
        folder(for: id).appending(path: "manifest.json")
    }

    public func exists(id: String) -> Bool {
        (try? CatalogRepository.checkID(id)) != nil
            && FileManager.default.fileExists(atPath: manifestURL(for: id).path)
    }

    /// `path` normalized, or nil if it is absolute, empty, contains `..`, `.` or hidden
    /// components, backslashes or NUL, or names the manifest itself.
    public static func safeRelativePath(_ path: String) -> String? {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("~"),
              !path.contains("\\"), !path.contains("\u{0}") else { return nil }
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map { String($0) }
        guard !components.contains(where: { $0.isEmpty || $0.hasPrefix(".") }) else { return nil }
        let normalized = components.joined(separator: "/")
        return normalized == "manifest.json" ? nil : normalized
    }

    /// Writes the draft, replacing any earlier draft with the same id. Every path is checked
    /// before anything is written. Returns the draft's folder.
    @discardableResult
    public func write(_ manifest: AutomationManifest, files: [DraftFile]) throws -> URL {
        try CatalogRepository.checkID(manifest.id)
        var checked: [(String, String)] = []
        for file in files {
            guard let path = Self.safeRelativePath(file.path) else { throw DraftError.invalidPath(file.path) }
            checked.append((path, file.contents))
        }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let staging = directory.appending(path: ".staging-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            try manifest.encoded().write(to: staging.appending(path: "manifest.json"), options: .atomic)
            let stagingPath = staging.standardizedFileURL.path + "/"
            for (path, contents) in checked {
                let target = staging.appending(path: path).standardizedFileURL
                guard target.path.hasPrefix(stagingPath) else { throw DraftError.invalidPath(path) }
                try fileManager.createDirectory(
                    at: target.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                try Data(contents.utf8).write(to: target, options: .atomic)
            }
            let destination = folder(for: manifest.id)
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: staging, to: destination)
            return destination
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
    }

    /// The draft's `manifest.json` as written.
    public func manifestData(id: String) throws -> Data {
        guard exists(id: id) else { throw DraftError.notFound(id) }
        return try Data(contentsOf: manifestURL(for: id))
    }

    public func manifest(id: String) throws -> AutomationManifest {
        try AutomationManifest.decode(from: manifestData(id: id))
    }

    /// Deletes the draft. Throws `notFound` when there is none.
    public func remove(id: String) throws {
        try CatalogRepository.checkID(id)
        let draftFolder = folder(for: id)
        guard FileManager.default.fileExists(atPath: draftFolder.path) else { throw DraftError.notFound(id) }
        try FileManager.default.removeItem(at: draftFolder)
    }
}

/// Reads the text files of an automation folder for `read_automation`.
public enum FolderText {
    public static let maxFileBytes = 64 * 1_024

    /// Relative path → contents for UTF-8 files of at most `maxBytes`, skipping hidden files,
    /// binaries (anything with a NUL byte) and the names in `excluding`.
    public static func textFiles(
        in folder: URL,
        maxBytes: Int = maxFileBytes,
        excluding: Set<String> = ["manifest.json"]
    ) -> [String: String] {
        let root = folder.resolvingSymlinksInPath().standardizedFileURL
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return [:] }
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        var files: [String: String] = [:]
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  (values.fileSize ?? 0) <= maxBytes else { continue }
            let path = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard path.hasPrefix(prefix) else { continue }
            let relative = String(path.dropFirst(prefix.count))
            guard !excluding.contains(relative),
                  let data = try? Data(contentsOf: url),
                  !data.contains(0),
                  let text = String(bytes: data, encoding: .utf8) else { continue }
            files[relative] = text
        }
        return files
    }
}
