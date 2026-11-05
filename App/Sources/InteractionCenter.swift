import Foundation
import Observation
import Shared

/// Running a script for exploration (`run_snippet`).
struct SnippetApproval: Sendable {
    var language: ScriptLanguage
    var source: String
    var timeout: Double
}

/// Enabling, disabling or rolling back an installed automation (`set_status`).
struct StatusApproval: Sendable {
    var automationID: String
    var action: String
    var commit: String?
}

/// A question for the user (`ask_user`).
struct UserQuestion: Sendable {
    enum Kind: String, Sendable {
        case test, choice, text
    }

    var question: String
    var kind: Kind
    var options: [String]
}

/// One step of a draft as the install card shows it.
struct StepPreview: Sendable, Identifiable {
    var id: Int
    var type: String
    var details: [String]
    var scriptLabel: String?
    var script: String?
}

/// Everything the install card shows, captured when `request_install` is called.
struct InstallApproval: Sendable {
    var draftID: String
    var summary: String
    var name: String
    var trigger: String
    var steps: [StepPreview]
    var otherFiles: [DraftFile]
    var permissions: [String]
    var destructive: Bool
    /// Set when the manifest could not be read; the card then shows `rawManifest`.
    var parseProblem: String?
    var rawManifest: String
    var report: TestReport?

    /// Approve needs a validation report that passed (no errors, every test passing).
    var canApprove: Bool {
        report?.passed == true
    }
}

/// What a card asks.
enum InteractionRequest: Sendable {
    case runSnippet(SnippetApproval)
    case install(InstallApproval)
    case setStatus(StatusApproval)
    case question(UserQuestion)
}

/// How the user answered a card.
enum InteractionAnswer: Sendable, Equatable {
    case approved
    case declined(note: String)
    case answered(String)
    /// Stop or New Conversation was pressed while the card waited.
    case cancelled
}

/// A card in the transcript. `resolution` is nil while it waits for the user.
struct InteractionCard: Identifiable {
    let id: UUID
    let request: InteractionRequest
    var resolution: String?
}

/// Approval and question cards that tools wait on. A tool calls `ask(_:)`, which posts a card
/// to the transcript and suspends until the user answers, or until Stop or New Conversation
/// resumes every waiting card with `.cancelled` so the agent loop can end.
@MainActor
@Observable
final class InteractionCenter {
    private(set) var cards: [UUID: InteractionCard] = [:]
    /// The user chose "Trust this conversation" on a snippet card: later snippets run
    /// without asking until New Conversation.
    private(set) var trustsSnippets = false

    /// Called when a card is posted, so the chat can place it in the transcript.
    @ObservationIgnored var onPost: (@MainActor (UUID) -> Void)?
    /// Called when a card is answered, with the answer and the label the card shows.
    @ObservationIgnored var onResolve: (@MainActor (UUID, InteractionAnswer, String) -> Void)?
    @ObservationIgnored private var waiting: [UUID: CheckedContinuation<InteractionAnswer, Never>] = [:]

    func card(_ id: UUID) -> InteractionCard? {
        cards[id]
    }

    func isSnippetTrusted() -> Bool {
        trustsSnippets
    }

    /// Posts a card and waits for the answer.
    func ask(_ request: InteractionRequest) async -> InteractionAnswer {
        if Task.isCancelled { return .cancelled }
        let id = UUID()
        cards[id] = InteractionCard(id: id, request: request)
        onPost?(id)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiting[id] = continuation
            }
        } onCancel: {
            Task { @MainActor in
                self.resolve(id, with: .cancelled, label: "Cancelled")
            }
        }
    }

    func approve(_ id: UUID, label: String = "Approved") {
        resolve(id, with: .approved, label: label)
    }

    /// Approves a snippet card and skips the question for later snippets in this conversation.
    func approveAndTrustConversation(_ id: UUID) {
        trustsSnippets = true
        resolve(id, with: .approved, label: "Approved; snippets in this conversation run without asking")
    }

    func decline(_ id: UUID, note: String) {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        resolve(id, with: .declined(note: trimmed), label: trimmed.isEmpty ? "Declined" : "Declined: \(trimmed)")
    }

    func answer(_ id: UUID, with text: String) {
        resolve(id, with: .answered(text), label: "Answered: \(text)")
    }

    /// Resumes every waiting card with `.cancelled` (Stop).
    func cancelAll() {
        for id in Array(waiting.keys) {
            resolve(id, with: .cancelled, label: "Cancelled")
        }
    }

    /// Cancels waiting cards and forgets everything (New Conversation).
    func reset() {
        cancelAll()
        cards = [:]
        trustsSnippets = false
    }

    private func resolve(_ id: UUID, with answer: InteractionAnswer, label: String) {
        guard let continuation = waiting.removeValue(forKey: id) else { return }
        cards[id]?.resolution = label
        onResolve?(id, answer, label)
        continuation.resume(returning: answer)
    }
}

/// The drafts written in this conversation, with their files and last validation report, so
/// `request_install` can show the user exactly what will be installed. Memory only.
@MainActor
final class ChatDrafts {
    struct Draft: Sendable {
        var manifestJSON: String
        var files: [DraftFile]
        var report: TestReport?
    }

    private var drafts: [String: Draft] = [:]

    func draft(_ id: String) -> Draft? {
        drafts[id]
    }

    /// Records a newly written draft. A rewrite clears the last report: it must be validated again.
    func recordWrite(id: String, manifestJSON: String, files: [DraftFile]) {
        drafts[id] = Draft(manifestJSON: manifestJSON, files: files, report: nil)
    }

    func recordReport(_ report: TestReport, for id: String) {
        drafts[id]?.report = report
    }

    func reset() {
        drafts = [:]
    }
}
