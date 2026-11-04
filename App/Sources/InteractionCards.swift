import Shared
import SwiftUI

/// An approval or question card in the chat transcript. Plain and structural on purpose.
struct InteractionCardView: View {
    @Environment(ChatController.self) private var chat
    let cardID: UUID

    var body: some View {
        if let card = chat.interactions.card(cardID) {
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    content(for: card, center: chat.interactions)
                    if let resolution = card.resolution {
                        Label(resolution, systemImage: "checkmark.seal")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func content(for card: InteractionCard, center: InteractionCenter) -> some View {
        let pending = card.resolution == nil
        switch card.request {
        case .runSnippet(let approval):
            SnippetCard(approval: approval, cardID: card.id, pending: pending, center: center)
        case .install(let approval):
            InstallCard(approval: approval, cardID: card.id, pending: pending, center: center)
        case .setStatus(let approval):
            StatusCard(approval: approval, cardID: card.id, pending: pending, center: center)
        case .question(let question):
            QuestionCard(question: question, cardID: card.id, pending: pending, center: center)
        }
    }
}

/// Script text in a monospaced, selectable block.
struct ScriptBlock: View {
    let text: String

    var body: some View {
        Text(text.isEmpty ? " " : text)
            .font(.system(.callout, design: .monospaced))
            .textSelection(.enabled)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }
}

/// A Decline button with an optional reason.
struct DeclineRow: View {
    let center: InteractionCenter
    let cardID: UUID
    @State private var note = ""

    var body: some View {
        HStack {
            TextField("Reason (optional)", text: $note)
                .textFieldStyle(.roundedBorder)
            Button("Decline") { center.decline(cardID, note: note) }
        }
    }
}

struct SnippetCard: View {
    let approval: SnippetApproval
    let cardID: UUID
    let pending: Bool
    let center: InteractionCenter

    private var languageName: String {
        switch approval.language {
        case .applescript: "AppleScript"
        case .jxa: "JavaScript (JXA)"
        case .shell: "shell (zsh)"
        case .shortcut: "shortcut"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Claude wants to run this \(languageName) snippet").font(.headline)
            Text("Timeout: \(approval.timeout.formatted()) s").font(.caption).foregroundStyle(.secondary)
            ScriptBlock(text: approval.source)
            if pending {
                HStack {
                    Button("Run Once") { center.approve(cardID, label: "Approved") }
                    Button("Run and Trust This Conversation") { center.approveAndTrustConversation(cardID) }
                        .help("Later snippets in this conversation run without asking.")
                }
                DeclineRow(center: center, cardID: cardID)
            }
        }
    }
}

struct StatusCard: View {
    let approval: StatusApproval
    let cardID: UUID
    let pending: Bool
    let center: InteractionCenter

    private var title: String {
        switch approval.action {
        case "enable": "Enable \"\(approval.automationID)\"?"
        case "disable": "Disable \"\(approval.automationID)\"?"
        default: "Roll back \"\(approval.automationID)\" to commit \(approval.commit ?? "?")?"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            if approval.action == "rollback" {
                Text("The automation's folder is restored as it was at that commit, and the change is committed.")
                    .font(.callout)
            }
            if pending {
                Button("Approve") { center.approve(cardID) }
                DeclineRow(center: center, cardID: cardID)
            }
        }
    }
}

struct QuestionCard: View {
    let question: UserQuestion
    let cardID: UUID
    let pending: Bool
    let center: InteractionCenter
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(question.kind == .test ? "Please test" : "Question").font(.headline)
            Text(question.question).textSelection(.enabled)
            if pending {
                controls
            }
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch question.kind {
        case .test:
            TextField("Notes (optional): what happened?", text: $text, axis: .vertical)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Works") { center.answer(cardID, with: withNotes("Works.")) }
                Button("Didn't Work") { center.answer(cardID, with: withNotes("Didn't work.")) }
            }
        case .choice:
            HStack {
                ForEach(question.options, id: \.self) { option in
                    Button(option) { center.answer(cardID, with: option) }
                }
            }
        case .text:
            TextField("Your answer", text: $text, axis: .vertical)
                .textFieldStyle(.roundedBorder)
            Button("Send Answer") { center.answer(cardID, with: text) }
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func withNotes(_ verdict: String) -> String {
        let notes = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return notes.isEmpty ? verdict : "\(verdict) Notes: \(notes)"
    }
}
