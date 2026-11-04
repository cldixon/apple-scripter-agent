import AgentCore
import SwiftUI

/// The chat screen: transcript, composer, and a footer with this conversation's usage.
struct ChatView: View {
    @Environment(ChatController.self) private var chat

    var body: some View {
        VStack(spacing: 0) {
            ChatTranscript(items: chat.items, revision: chat.revision)
            Divider()
            ChatComposer(chat: chat)
            ChatUsageFooter(usage: chat.usage, costUSD: chat.costUSD, capUSD: chat.spendCapUSD)
        }
        .navigationTitle("Chat")
        .toolbar {
            ToolbarItem {
                Button("New Conversation", systemImage: "square.and.pencil") {
                    chat.newConversation()
                }
                .help("Start a new conversation")
            }
        }
    }
}

struct ChatTranscript: View {
    let items: [ChatItem]
    let revision: Int

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if items.isEmpty {
                        Text("Describe an automation you want, or ask what is installed.")
                            .foregroundStyle(.secondary)
                            .padding(.top, 40)
                            .frame(maxWidth: .infinity)
                    }
                    ForEach(items) { item in
                        ChatItemRow(item: item)
                            .id(item.id)
                    }
                }
                .padding(16)
            }
            .onChange(of: revision) {
                if let last = items.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }
}

struct ChatItemRow: View {
    let item: ChatItem

    var body: some View {
        switch item.kind {
        case .user:
            HStack {
                Spacer(minLength: 60)
                Text(item.text)
                    .textSelection(.enabled)
                    .padding(10)
                    .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
            }
        case .assistant:
            VStack(alignment: .leading, spacing: 4) {
                Text(item.text)
                    .textSelection(.enabled)
                    .foregroundStyle(item.discarded ? .secondary : .primary)
                if item.discarded {
                    Text("Discarded: not part of the conversation.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .tool:
            ToolCallRow(item: item)
        case .notice:
            Label(item.text, systemImage: "info.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

/// One line per tool call, expandable to show the full input and result.
struct ToolCallRow: View {
    let item: ChatItem

    private var statusImage: String {
        guard item.toolOutput != nil else { return "hourglass" }
        return item.isError ? "exclamationmark.triangle" : "checkmark.circle"
    }

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                Text("Input").font(.caption).bold()
                Text(item.text)
                Text(item.isError ? "Error" : "Result").font(.caption).bold()
                Text(item.toolOutput ?? "Running…")
            }
            .font(.caption.monospaced())
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: statusImage)
                    .foregroundStyle(item.isError ? Color.orange : Color.secondary)
                Text("\(item.toolName) \(item.text)")
                    .font(.callout.monospaced())
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }
}

struct ChatComposer: View {
    @Bindable var chat: ChatController

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message Claude", text: $chat.draft, axis: .vertical)
                .lineLimit(1...8)
                .textFieldStyle(.roundedBorder)
                .onSubmit { chat.send() }
                .disabled(chat.isRunning)
            if chat.isRunning {
                ProgressView()
                    .controlSize(.small)
                Button("Stop", systemImage: "stop.fill") { chat.stop() }
                    .keyboardShortcut(".", modifiers: .command)
            } else {
                Button("Send", systemImage: "paperplane.fill") { chat.send() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!chat.canSend)
            }
        }
        .padding(12)
    }
}

struct ChatUsageFooter: View {
    let usage: TokenUsage
    let costUSD: Double
    let capUSD: Double

    var body: some View {
        HStack {
            Text(
                "Tokens: \(usage.totalInputTokens.formatted()) in "
                    + "(\(usage.cacheReadInputTokens.formatted()) cached), "
                    + "\(usage.outputTokens.formatted()) out"
            )
            Spacer()
            Text("Cost: \(Self.dollars(costUSD)) of \(Self.dollars(capUSD)) cap")
                .foregroundStyle(costUSD >= capUSD ? Color.orange : Color.secondary)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private static func dollars(_ amount: Double) -> String {
        amount.formatted(.currency(code: "USD").precision(.fractionLength(amount < 1 ? 4 : 2)))
    }
}
