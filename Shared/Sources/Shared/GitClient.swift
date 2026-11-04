import Foundation

/// A failed git invocation.
public enum GitError: LocalizedError, Equatable {
    case unavailable(String)
    case failed(arguments: [String], status: Int32, output: String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let reason):
            "Version history is unavailable: \(reason)"
        case .failed(let arguments, let status, let output):
            "git \(arguments.first ?? "") failed (exit \(status)): "
                + output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

/// Runs `/usr/bin/git` (from the Xcode command line tools) in one repository.
///
/// Synchronous: catalog operations are small and rare. Standard error goes to a temporary
/// file so a chatty command can never fill a pipe and block.
public struct GitClient: Sendable {
    public static let defaultExecutable = URL(filePath: "/usr/bin/git")

    public let executable: URL
    public let repository: URL

    public init(repository: URL, executable: URL = GitClient.defaultExecutable) {
        self.repository = repository
        self.executable = executable
    }

    /// Whether git is installed and answers `git --version`.
    public var isAvailable: Bool {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { return false }
        return (try? run(["--version"])) != nil
    }

    /// Runs git with `arguments` in the repository and returns standard output.
    @discardableResult
    public func run(_ arguments: [String]) throws -> String {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw GitError.unavailable("\(executable.path) was not found. Install the Xcode command line tools.")
        }
        let errorURL = FileManager.default.temporaryDirectory.appending(path: "git-\(UUID().uuidString).err")
        FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: errorURL) }
        let errorHandle = try FileHandle(forWritingTo: errorURL)
        defer { try? errorHandle.close() }

        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = repository
        process.standardOutput = output
        process.standardError = errorHandle
        process.standardInput = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["LC_ALL"] = "C"
        process.environment = environment

        // A semaphore rather than waitUntilExit(), which spins the current run loop and could
        // run other main-actor work in the middle of a catalog change.
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        exited.wait()

        let text = String(bytes: data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            let errorText = (try? String(contentsOf: errorURL, encoding: .utf8)) ?? ""
            throw GitError.failed(
                arguments: arguments,
                status: process.terminationStatus,
                output: errorText.isEmpty ? text : errorText
            )
        }
        return text
    }

    /// Whether `value` looks like a commit hash (so it can never be read as an option).
    public static func isCommitHash(_ value: String) -> Bool {
        let hex = CharacterSet(charactersIn: "0123456789abcdef")
        return (4...64).contains(value.count) && value.unicodeScalars.allSatisfy { hex.contains($0) }
    }
}
