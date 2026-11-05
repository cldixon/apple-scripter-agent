import AgentCore
import Foundation
import Observation
import os
import Shared

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

/// Runs the agent for the chat screen. The conversation lives in memory; a complete record of
/// it is written to a `ConversationLog` file as it happens (see `ConversationLogs`).
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
    /// The current conversation's log, created with its first message.
    @ObservationIgnored private var log: ConversationLog?
    @ObservationIgnored private let logger = Logger(subsystem: Identifiers.logSubsystem, category: "chat")

    init(settings: AgentSettings, catalog: CatalogController? = nil) {
        self.settings = settings
        self.catalog = catalog
        interactions.onPost = { [weak self] id in
            self?.appendCard(id)
        }
        interactions.onResolve = { [weak self] id, answer, label in
            var fields = answer.logJSON.objectValue ?? [:]
            fields["cardID"] = .string(id.uuidString)
            fields["label"] = .string(label)
            self?.log?.record("card_resolved", fields)
        }
    }

    /// The current conversation's log file, if one has been started.
    var logFileURL: URL? { log?.fileURL }

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
        let log = currentLog()
        log?.record("user_message", ["text": .string(text)])

        var configuration = settings.configuration
        configuration.systemPrompt = AgentToolbox.systemPrompt
        let context = ToolContext(interactions: interactions, drafts: drafts, catalog: catalog)
        let runner = AgentRunner(
            transport: URLSessionTransport(apiKey: apiKey),
            tools: AgentToolbox.registry(context: context),
            configuration: configuration,
            log: log
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
        log?.record("user_stopped")
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
        log?.record("conversation_ended", ["reason": "new_conversation"])
        log?.close()
        log = nil
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

    /// Opens the log for this conversation on its first message.
    private func currentLog() -> ConversationLog? {
        if let log { return log }
        do {
            let log = try ConversationLog(directory: ConversationLogs.directory)
            var fields = ConversationLogs.environment
            fields["conversationID"] = .string(log.id.uuidString)
            log.record("conversation_started", fields)
            logger.info("Conversation log: \(log.fileURL.path, privacy: .public)")
            self.log = log
            return log
        } catch {
            logger.error("Could not create the conversation log: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func appendCard(_ id: UUID) {
        log?.record("card_posted", [
            "cardID": .string(id.uuidString),
            "request": interactions.card(id)?.request.logJSON ?? .null
        ])
        var item = ChatItem(kind: .card, text: "")
        item.cardID = id
        items.append(item)
        openAssistantIndex = nil
        revision += 1
    }

    private func appendNotice(_ text: String) {
        log?.record("notice", ["text": .string(text)])
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
