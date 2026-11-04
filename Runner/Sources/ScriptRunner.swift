import Foundation
import Shared
import Synchronization

/// Runs scripts as child processes (`osascript`, `zsh`, `shortcuts`) so a hung script can
/// be killed. Because the runner launches them, macOS attributes their Apple Events to the
/// runner: its Automation permissions apply and its name appears in the prompts.
enum ScriptRunner {
    /// Runs `request` and returns its output, or throws with the script's error text.
    static func run(_ request: ScriptRequest) async throws -> String {
        let result = try await execute(request)
        if result.timedOut { throw AutomationError.timedOut(seconds: request.timeout) }
        guard result.exitCode == 0 else {
            throw AutomationError.scriptFailed(explain(result.errorOutput, exitCode: result.exitCode))
        }
        return result.output
    }

    /// Runs `request` and reports everything, without throwing for a failing script.
    static func execute(_ request: ScriptRequest) async throws -> ScriptResult {
        let invocation = try Invocation(request)
        defer { invocation.cleanUp() }
        return try await launch(invocation, timeout: request.timeout)
    }

    /// Runs a command-line tool (`sdef`, `man`, `shortcuts list`) with a timeout and returns
    /// what it printed. `environment` is added to the runner's own.
    static func runTool(
        _ executable: String,
        arguments: [String],
        environment: [String: String] = [:],
        timeout: Double
    ) async throws -> ScriptResult {
        let invocation = Invocation(
            executable: executable, arguments: arguments, environment: environment, directory: nil
        )
        return try await launch(invocation, timeout: timeout)
    }

    /// Compiles AppleScript or JXA without running it, or syntax-checks shell. Returns the
    /// compiler's error text, empty when the script is valid.
    static func compile(_ language: ScriptLanguage, source: String) async throws -> String {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let input = try scratch.write(source, name: "script.\(language.rawValue)")
        let arguments: (String, [String])
        switch language {
        case .applescript, .jxa:
            let osaLanguage = language.osaLanguage ?? "AppleScript"
            let output = scratch.url.appending(path: "compiled.scpt").path
            arguments = ("/usr/bin/osacompile", ["-l", osaLanguage, "-o", output, input.path])
        case .shell:
            arguments = ("/bin/zsh", ["-n", input.path])
        case .shortcut:
            return ""
        }
        let invocation = Invocation(executable: arguments.0, arguments: arguments.1, environment: [:], directory: nil)
        let result = try await launch(invocation, timeout: 15)
        return result.exitCode == 0 ? "" : result.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Adds advice to errors whose cause is a permission, not the script.
    static func explain(_ errorOutput: String, exitCode: Int32) -> String {
        let text = errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.contains("-1743") {
            return "\(text)\nThe runner is not allowed to control that app. Allow it in System Settings > "
                + "Privacy & Security > Automation > Automation Agent Runner."
        }
        if text.contains("-1719") || text.contains("-25211") {
            return "\(text)\nUI scripting needs Accessibility permission for the runner."
        }
        return text.isEmpty ? "The script exited with status \(exitCode)." : text
    }

    // MARK: Process handling

    private static func launch(_ invocation: Invocation, timeout: Double) async throws -> ScriptResult {
        let process = Process()
        process.executableURL = URL(filePath: invocation.executable)
        process.arguments = invocation.arguments
        var environment = ProcessInfo.processInfo.environment
        environment.merge(invocation.environment) { _, new in new }
        process.environment = environment
        if let directory = invocation.directory { process.currentDirectoryURL = directory }

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice

        let output = PipeCollector(stdout.fileHandleForReading)
        let errors = PipeCollector(stderr.fileHandleForReading)
        let state = ProcessState()
        let clock = ContinuousClock()
        let start = clock.now

        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, any Error>) in
                process.terminationHandler = { finished in
                    state.markFinished()
                    continuation.resume(returning: finished.terminationStatus)
                }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                    return
                }
                state.started(pid: process.processIdentifier)
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    if state.terminate(becauseOfTimeout: true) { terminate(state) }
                }
            }
        } onCancel: {
            if state.terminate(becauseOfTimeout: false) { terminate(state) }
        }

        return ScriptResult(
            output: trimmed(output.finish()),
            errorOutput: errors.finish(),
            exitCode: status,
            duration: (clock.now - start).inSeconds,
            timedOut: state.timedOut
        )
    }

    /// SIGTERM, then SIGKILL if it is still running a second later.
    private static func terminate(_ state: ProcessState) {
        state.signal(SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            state.signal(SIGKILL)
        }
    }

    private static func trimmed(_ text: String) -> String {
        text.hasSuffix("\n") ? String(text.dropLast()) : text
    }
}

/// The command line for one script request, plus any temporary files it needs.
private struct Invocation {
    var executable: String
    var arguments: [String]
    var environment: [String: String]
    var directory: URL?
    var scratch: Scratch?

    init(executable: String, arguments: [String], environment: [String: String], directory: URL?) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.directory = directory
    }

    init(_ request: ScriptRequest) throws {
        directory = request.workingDirectory
        environment = [:]
        switch request.language {
        case .applescript, .jxa:
            let file = try Self.scriptFile(request, scratch: &scratch)
            executable = "/usr/bin/osascript"
            arguments = ["-l", request.language.osaLanguage ?? "AppleScript", file.path, request.inputJSON]
        case .shell:
            let file = try Self.scriptFile(request, scratch: &scratch)
            executable = "/bin/zsh"
            arguments = [file.path]
            environment["AUTOMATION_INPUT"] = request.inputJSON
            for (name, value) in request.variables {
                environment["AUTOMATION_VAR_\(name)"] = value
            }
        case .shortcut:
            guard let name = request.shortcutName else {
                throw AutomationError.invalidArgument("A shortcut step needs the shortcut's name.")
            }
            let scratch = try Scratch()
            self.scratch = scratch
            let outputPath = scratch.url.appending(path: "output").path
            executable = "/bin/zsh"
            // `shortcuts run` writes its result to a file; print it so it becomes the output.
            var command = "/usr/bin/shortcuts run \"$SHORTCUT_NAME\" --output-path \"$OUTPUT_PATH\""
            if let input = request.shortcutInput {
                let inputFile = try scratch.write(input, name: "input.txt")
                environment["INPUT_PATH"] = inputFile.path
                command += " --input-path \"$INPUT_PATH\""
            }
            command += " && { [ -f \"$OUTPUT_PATH\" ] && cat \"$OUTPUT_PATH\"; true; }"
            arguments = ["-c", command]
            environment["SHORTCUT_NAME"] = name
            environment["OUTPUT_PATH"] = outputPath
        }
    }

    private static func scriptFile(_ request: ScriptRequest, scratch: inout Scratch?) throws -> URL {
        if let file = request.file {
            guard FileManager.default.fileExists(atPath: file.path) else {
                throw AutomationError.invalidArgument("Script file \(file.lastPathComponent) is missing.")
            }
            return file
        }
        guard let source = request.source else {
            throw AutomationError.invalidArgument("A script step needs \"file\" or \"source\".")
        }
        let created = try Scratch()
        scratch = created
        return try created.write(source, name: "script.\(request.language.rawValue)")
    }

    func cleanUp() {
        scratch?.remove()
    }
}

/// A private temporary folder, removed when done.
private struct Scratch {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appending(path: "AutomationAgentRunner-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func write(_ text: String, name: String) throws -> URL {
        let file = url.appending(path: name)
        try text.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Tracks a child process across the termination handler, the timeout and cancellation,
/// and only signals it while it is known to be running (never a reused pid).
private final class ProcessState: Sendable {
    private struct Values {
        var pid: pid_t = 0
        var finished = false
        var timedOut = false
    }

    private let values = Mutex(Values())

    var timedOut: Bool { values.withLock { $0.timedOut } }

    func started(pid: pid_t) {
        values.withLock { $0.pid = pid }
    }

    func markFinished() {
        values.withLock { $0.finished = true }
    }

    /// Returns true if the process is still running and should be stopped.
    func terminate(becauseOfTimeout: Bool) -> Bool {
        values.withLock { values in
            guard values.pid > 0, !values.finished else { return false }
            if becauseOfTimeout { values.timedOut = true }
            return true
        }
    }

    func signal(_ signal: Int32) {
        values.withLock { values in
            if values.pid > 0, !values.finished { kill(values.pid, signal) }
        }
    }
}

/// Reads a pipe on a background thread so a chatty script cannot fill it and block.
private final class PipeCollector: Sendable {
    private let data = Mutex(Data())
    private let done = DispatchSemaphore(value: 0)

    init(_ handle: FileHandle) {
        DispatchQueue.global().async { [self] in
            let all = handle.readDataToEndOfFile()
            data.withLock { $0 = all }
            done.signal()
        }
    }

    /// Waits (briefly) for the pipe to close and returns what was read.
    func finish() -> String {
        _ = done.wait(timeout: .now() + 2)
        return String(bytes: data.withLock { $0 }, encoding: .utf8) ?? ""
    }
}
