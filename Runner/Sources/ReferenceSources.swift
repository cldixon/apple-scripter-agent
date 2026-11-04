import Foundation
import Shared

enum ReferenceSourceError: LocalizedError {
    case toolFailed(String)

    var errorDescription: String? {
        switch self {
        case .toolFailed(let message): message
        }
    }
}

/// Reads the generated parts of the reference library from the system: scripting
/// dictionaries through `/usr/bin/sdef` and man pages through `/usr/bin/man`.
enum ReferenceSources {
    /// Runs `sdef` on an app or scripting addition and parses the result, including the
    /// standard suites it pulls in with `xi:include`. An app without a dictionary throws.
    static func dictionary(at url: URL) async throws -> SdefDictionary {
        let result = try await ScriptRunner.runTool("/usr/bin/sdef", arguments: [url.path], timeout: 30)
        guard result.exitCode == 0, !result.timedOut, !result.output.isEmpty else {
            let reason = result.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ReferenceSourceError.toolFailed(
                result.timedOut ? "sdef timed out" : reason.isEmpty ? "no scripting dictionary" : reason
            )
        }
        var dictionary = try SdefDictionary.parse(Data(result.output.utf8))
        for href in dictionary.includes {
            guard let included = URL(string: href), included.isFileURL,
                  let data = try? Data(contentsOf: included),
                  let parsed = try? SdefDictionary.parse(data) else { continue }
            dictionary.merge(parsed)
        }
        return dictionary
    }

    /// `man -P cat <name>`, plain text (overstrikes are removed later).
    static func manPage(_ name: String) async throws -> String {
        let result = try await ScriptRunner.runTool(
            "/usr/bin/man",
            arguments: ["-P", "cat", name],
            environment: ["MANPAGER": "cat", "PAGER": "cat", "MANWIDTH": "100"],
            timeout: 20
        )
        guard result.exitCode == 0, !result.timedOut, !result.output.isEmpty else {
            let reason = result.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ReferenceSourceError.toolFailed(reason.isEmpty ? "no manual entry" : reason)
        }
        return result.output
    }
}
