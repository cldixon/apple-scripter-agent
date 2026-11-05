import AgentCore
import Foundation
import Shared

// Tools for making an automation: try a snippet, write and validate a draft, install it with
// the user's approval, and ask the user to test it.

struct RunSnippetTool: AgentTool {
    let name = "run_snippet"
    let description = """
        Runs a short AppleScript, JXA or shell snippet on this Mac and returns its output. Call \
        it to check an assumption against the real app before writing the draft (e.g. what \
        Finder's selection returns). The user approves each snippet unless they chose to trust \
        this conversation. Keep snippets read-only and quick; never change user data with them.
        """

    let context: ToolContext

    var inputSchema: JSONValue {
        objectSchema([
            "language": ["type": "string", "enum": ["applescript", "jxa", "shell"]],
            "source": ["type": "string", "description": "The script source."],
            "timeout": ["type": "number", "description": "Seconds, 1-60 (default 10)."]
        ], required: ["language", "source"])
    }

    func run(input: JSONValue) async throws -> String {
        let languageName = try input.requiredString("language")
        guard let language = ScriptLanguage(rawValue: languageName), language != .shortcut else {
            throw ToolError("language must be applescript, jxa or shell.")
        }
        let source = try input.requiredString("source")
        let timeout = input.clampedNumber("timeout", default: 10, range: 1...60)
        let trusted = await context.interactions.isSnippetTrusted()
        if !trusted {
            let approval = SnippetApproval(language: language, source: source, timeout: timeout)
            switch await context.interactions.ask(.runSnippet(approval)) {
            case .approved, .answered:
                break
            case .declined(let note):
                return "The user declined to run this snippet." + (note.isEmpty ? "" : " Their note: \(note)")
            case .cancelled:
                throw RunnerTool.cancelled
            }
        }
        let reply = try await RunnerTool.send(
            .runSnippet(language: language, source: source, timeout: timeout),
            timeout: timeout + 15
        )
        guard case .snippet(let result) = reply else { throw RunnerTool.unexpected(reply) }
        return ToolFormatting.snippetResult(result)
    }
}

struct WriteDraftTool: AgentTool {
    let name = "write_draft"
    let description = """
        Creates or replaces the draft automation with the manifest's id, with its script and \
        fixture files. Call it once research is done, and again after every fix. Returns static \
        validation issues; then call validate. Writing a draft never installs it.
        """

    let context: ToolContext

    var inputSchema: JSONValue {
        objectSchema([
            "manifest": ["type": "object", "description": "The manifest, following the Manifest JSON Schema."],
            "files": [
                "type": "array",
                "description": "Files beside the manifest, e.g. scripts/run.applescript, with their contents.",
                "items": objectSchema([
                    "path": ["type": "string", "description": "Relative path inside the draft folder."],
                    "contents": ["type": "string"]
                ], required: ["path", "contents"])
            ]
        ], required: ["manifest"])
    }

    func run(input: JSONValue) async throws -> String {
        guard let manifest = input["manifest"], manifest.objectValue != nil else {
            throw ToolError("\"manifest\" must be a JSON object.")
        }
        let id = try manifest.requiredString("id")
        let files = try Self.files(from: input)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(manifest)
        let reply = try await RunnerTool.send(.writeDraft(manifest: data, files: files))
        guard case .draftWritten(let writtenID, let issues) = reply else { throw RunnerTool.unexpected(reply) }
        await context.drafts.recordWrite(
            id: writtenID,
            manifestJSON: String(bytes: data, encoding: .utf8) ?? "",
            files: files
        )
        let note = writtenID == id ? "" : " (the runner stored it as \"\(writtenID)\")"
        return "Draft \"\(writtenID)\" written with \(files.count) file(s)\(note).\n"
            + ToolFormatting.issues(issues)
            + "\nNext: fix any errors with write_draft, otherwise call validate."
    }

    private static func files(from input: JSONValue) throws -> [DraftFile] {
        var files: [DraftFile] = []
        for (index, item) in (input["files"]?.arrayValue ?? []).enumerated() {
            guard let path = item["path"]?.stringValue, let contents = item["contents"]?.stringValue else {
                throw ToolError("files[\(index)] needs string \"path\" and \"contents\".")
            }
            guard !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else {
                throw ToolError("files[\(index)].path must be relative and stay inside the draft folder.")
            }
            files.append(DraftFile(path: path, contents: contents))
        }
        return files
    }
}

struct ValidateTool: AgentTool {
    let name = "validate"
    let description = """
        Validates a draft: static checks, script compilation, unit tests and harness tests (the \
        runner's test window may appear briefly). Call it after every write_draft. A draft must \
        pass, with no errors and every test passing, before request_install; the one exception \
        is a draft whose only failures are harness tests (see request_install).
        """

    let context: ToolContext

    var inputSchema: JSONValue {
        objectSchema(["id": ["type": "string", "description": "The draft's id."]], required: ["id"])
    }

    func run(input: JSONValue) async throws -> String {
        let id = try input.requiredString("id")
        let reply = try await RunnerTool.send(.validateDraft(id: id), timeout: 180)
        guard case .draftValidated(let report) = reply else { throw RunnerTool.unexpected(reply) }
        await context.drafts.recordReport(report, for: id)
        return ToolFormatting.testReport(report)
    }
}

struct RequestInstallTool: AgentTool {
    let name = "request_install"
    let description = """
        Asks the user to approve installing a validated draft, showing them its trigger, every \
        step and script, permissions and the validation report, and waits for their answer. On \
        approval the draft is installed and the install report returned; otherwise their reason. \
        Call it only after validate passed for the draft as last written, or when the only \
        failures are harness tests and you have evidence the automation itself is right (its \
        step outputs are correct and permissions are granted). Then say in the summary that the \
        harness test failed and why you think the automation still works; the person can choose \
        Install Anyway. Not allowed for a destructive automation.
        """

    let context: ToolContext

    var inputSchema: JSONValue {
        objectSchema([
            "id": ["type": "string", "description": "The draft's id."],
            "summary": ["type": "string", "description": "One short paragraph: what it does and how to trigger it."]
        ], required: ["id", "summary"])
    }

    func run(input: JSONValue) async throws -> String {
        let id = try input.requiredString("id")
        let summary = try input.requiredString("summary")
        guard let draft = await context.drafts.draft(id) else {
            throw ToolError("No draft \"\(id)\" was written in this conversation. Call write_draft, then validate.")
        }
        guard let report = draft.report else {
            throw ToolError("Draft \"\(id)\" has not been validated since it was last written. Call validate first.")
        }
        let approval = InstallPreview.make(draftID: id, summary: summary, draft: draft)
        guard approval.canApprove || approval.canInstallAnyway else {
            throw ToolError("Draft \"\(id)\" failed its last validation. Fix it, write it again and validate.")
        }
        switch await context.interactions.ask(.install(approval)) {
        case .approved, .answered:
            break
        case .declined(let note):
            return "The user declined the install." + (note.isEmpty ? " They gave no reason." : " Their note: \(note)")
        case .cancelled:
            throw RunnerTool.cancelled
        }
        let reply = try await RunnerTool.send(.installDraft(id: id), timeout: 60)
        guard case .installed(let installReport) = reply else { throw RunnerTool.unexpected(reply) }
        if let catalog = context.catalog {
            await catalog.refresh()
        }
        return ToolFormatting.installReport(installReport)
    }
}

struct AskUserTool: AgentTool {
    let name = "ask_user"
    let description = """
        Shows the user a question card and waits for the answer. Use kind "test" after an \
        install, with concrete steps to try the automation (the user answers Works or Didn't \
        work, plus notes); "choice" to pick between options; "text" for a free answer. Prefer it \
        to a plain chat question when you need the answer to continue.
        """

    let context: ToolContext

    var inputSchema: JSONValue {
        objectSchema([
            "question": ["type": "string", "description": "The question, or the test instructions."],
            "kind": ["type": "string", "enum": ["test", "choice", "text"]],
            "options": ["type": "array", "items": ["type": "string"], "description": "For choice: the options."]
        ], required: ["question", "kind"])
    }

    func run(input: JSONValue) async throws -> String {
        let question = try input.requiredString("question")
        let kindName = try input.requiredString("kind")
        guard let kind = UserQuestion.Kind(rawValue: kindName) else {
            throw ToolError("kind must be test, choice or text.")
        }
        let options = input.stringArray("options").filter { !$0.isEmpty }
        if kind == .choice && options.count < 2 {
            throw ToolError("A choice question needs at least two options.")
        }
        let request = UserQuestion(question: question, kind: kind, options: options)
        switch await context.interactions.ask(.question(request)) {
        case .answered(let answer):
            return "The user answered: \(answer)"
        case .approved:
            return "The user acknowledged."
        case .declined(let note):
            return "The user skipped the question." + (note.isEmpty ? "" : " Their note: \(note)")
        case .cancelled:
            throw RunnerTool.cancelled
        }
    }
}
