import AgentCore
import Foundation
import Observation

/// One row in the chat transcript.
struct ChatItem: Identifiable {
    enum Kind {
        case user
        case assistant
        case tool
        case notice
        /// An approval or question card; `cardID` names it in `InteractionCenter`.
        case card
    }

    let id = UUID()
    let kind: Kind
    var text: String
    var toolName = ""
    var toolUseID = ""
    var toolOutput: String?
    var isError = false
    var cardID: UUID?
    /// Streamed output that was dropped (a refusal or Stop) and is not part of the conversation.
    var discarded = false
}

/// Runs the agent for the chat screen. The conversation lives in memory only.
@MainActor
@Observable
final class ChatController {
    private(set) var items: [ChatItem] = []
    private(set) var isRunning = false
    private(set) var usage = TokenUsage()
    private(set) var costUSD: Double = 0
    /// Changes whenever the transcript does, so the view can scroll to the bottom.
    private(set) var revision = 0
    var draft = ""
    /// Approval and question cards the tools wait on.
    let interactions = InteractionCenter()

    @ObservationIgnored private let settings: AgentSettings
    @ObservationIgnored private let drafts = ChatDrafts()
    @ObservationIgnored private weak var catalog: CatalogController?
    @ObservationIgnored private var conversation = Conversation()
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Bumped by New Conversation so a stopped run's late events are ignored.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var responseStart = 0
    @ObservationIgnored private var openAssistantIndex: Int?

    init(settings: AgentSettings, catalog: CatalogController? = nil) {
        self.settings = settings
        self.catalog = catalog
        interactions.onPost = { [weak self] id in
            self?.appendCard(id)
        }
    }

    var spendCapUSD: Double { settings.spendCapUSD }

    var canSend: Bool {
        !isRunning && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isRunning else { return }
        guard let apiKey = KeychainStore.readAPIKey() else {
            appendNotice("No API key is stored. Add one in Settings.")
            return
        }
        draft = ""
        items.append(ChatItem(kind: .user, text: text))
        conversation.appendUserText(text)
        revision += 1

        var configuration = settings.configuration
        configuration.systemPrompt = AgentToolbox.systemPrompt
        let context = ToolContext(interactions: interactions, drafts: drafts, catalog: catalog)
        let runner = AgentRunner(
            transport: URLSessionTransport(apiKey: apiKey),
            tools: AgentToolbox.registry(context: context),
            configuration: configuration
        )
        let start = conversation
        let runGeneration = generation
        isRunning = true
        task = Task {
            let result = await runner.run(start) { [weak self] event in
                await self?.handle(event, generation: runGeneration)
            }
            finish(result, generation: runGeneration)
        }
    }

    /// Stops the current run. The conversation keeps everything up to the stop.
    func stop() {
        task?.cancel()
        // Resume any card a tool is waiting on, so the loop can end.
        interactions.cancelAll()
    }

    /// Starts a fresh conversation and sends `message` as its first turn (Fix with Agent).
    func startConversation(with message: String) {
        newConversation()
        draft = message
        send()
    }

    func newConversation() {
        task?.cancel()
        task = nil
        interactions.reset()
        drafts.reset()
        generation += 1
        isRunning = false
        conversation = Conversation()
        items = []
        usage = TokenUsage()
        costUSD = 0
        draft = ""
        openAssistantIndex = nil
        revision += 1
    }

    private func handle(_ event: AgentEvent, generation: Int) {
        guard generation == self.generation else { return }
        switch event {
        case .responseStarted:
            responseStart = items.count
            openAssistantIndex = nil
        case .textDelta(let text):
            appendAssistantText(text)
        case .responseDiscarded:
            for index in items.indices where index >= responseStart && items[index].kind == .assistant {
                items[index].discarded = true
            }
            openAssistantIndex = nil
        case .toolCall(let id, let name, let input):
            items.append(ChatItem(kind: .tool, text: input, toolName: name, toolUseID: id))
            openAssistantIndex = nil
        case .toolResult(let id, let output, let isError):
            if let index = items.lastIndex(where: { $0.kind == .tool && $0.toolUseID == id }) {
                items[index].toolOutput = output
                items[index].isError = isError
            }
        case .usageUpdated(let usage, let costUSD):
            self.usage = usage
            self.costUSD = costUSD
        }
        revision += 1
    }

    private func appendAssistantText(_ text: String) {
        if let index = openAssistantIndex, items.indices.contains(index) {
            items[index].text += text
        } else {
            items.append(ChatItem(kind: .assistant, text: text))
            openAssistantIndex = items.count - 1
        }
    }

    private func finish(_ result: AgentRunResult, generation: Int) {
        guard generation == self.generation else { return }
        conversation = result.conversation
        usage = result.conversation.usage
        costUSD = result.conversation.costUSD
        isRunning = false
        task = nil
        openAssistantIndex = nil
        if let notice = Self.notice(for: result.stop) {
            appendNotice(notice)
        }
        revision += 1
    }

    private func appendCard(_ id: UUID) {
        var item = ChatItem(kind: .card, text: "")
        item.cardID = id
        items.append(item)
        openAssistantIndex = nil
        revision += 1
    }

    private func appendNotice(_ text: String) {
        items.append(ChatItem(kind: .notice, text: text))
        revision += 1
    }

    private static func notice(for stop: AgentStop) -> String? {
        switch stop {
        case .completed:
            nil
        case .cancelled:
            "Stopped."
        case .refused(let category):
            "Claude declined this request\(category.map { " (\($0))" } ?? ""). "
                + "Try rephrasing it, or start a new conversation."
        case .maxTokens:
            "The reply reached the output limit and was cut off."
        case .spendCapReached(let cap):
            "Stopped: this conversation reached its spend cap of \(cap.formatted(.currency(code: "USD"))). "
                + "Raise the cap in Settings or start a new conversation."
        case .maxToolRoundsReached(let rounds):
            "Stopped after \(rounds) tool rounds for one message. Send another message to continue."
        case .failed(let message):
            "Error: \(message)"
        }
    }
}
