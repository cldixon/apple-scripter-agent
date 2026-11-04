import AgentCore
import Foundation
import Observation

/// Agent settings, stored in UserDefaults. The API key is not here: it lives in the Keychain.
@MainActor
@Observable
final class AgentSettings {
    private enum Keys {
        static let model = "agent.model"
        static let effort = "agent.effort"
        static let spendCap = "agent.spendCapUSD"
        static let maxToolRounds = "agent.maxToolRounds"
        static let serverSideFallback = "agent.serverSideFallback"
    }

    static let defaultSpendCapUSD = 2.0
    static let defaultMaxToolRounds = 40

    var model: ClaudeModel {
        didSet { defaults.set(model.rawValue, forKey: Keys.model) }
    }

    var effort: Effort {
        didSet { defaults.set(effort.rawValue, forKey: Keys.effort) }
    }

    /// Per-conversation cap on estimated spend, in US dollars.
    var spendCapUSD: Double {
        didSet { defaults.set(spendCapUSD, forKey: Keys.spendCap) }
    }

    var maxToolRounds: Int {
        didSet { defaults.set(maxToolRounds, forKey: Keys.maxToolRounds) }
    }

    /// Re-run requests a safety classifier declines on a fallback model, server side.
    var serverSideFallback: Bool {
        didSet { defaults.set(serverSideFallback, forKey: Keys.serverSideFallback) }
    }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        model = defaults.string(forKey: Keys.model).flatMap { ClaudeModel(rawValue: $0) } ?? .defaultModel
        effort = defaults.string(forKey: Keys.effort).flatMap { Effort(rawValue: $0) } ?? .defaultEffort
        let cap = defaults.double(forKey: Keys.spendCap)
        spendCapUSD = cap > 0 ? cap : Self.defaultSpendCapUSD
        let rounds = defaults.integer(forKey: Keys.maxToolRounds)
        maxToolRounds = rounds > 0 ? rounds : Self.defaultMaxToolRounds
        serverSideFallback = defaults.object(forKey: Keys.serverSideFallback) as? Bool ?? true
    }

    var configuration: AgentConfiguration {
        AgentConfiguration(
            model: model.rawValue,
            effort: effort,
            maxToolRounds: max(1, maxToolRounds),
            spendCapUSD: max(0, spendCapUSD),
            serverSideFallback: serverSideFallback
        )
    }
}

/// Whether an API key is stored, and checking a new one before it is saved.
@MainActor
@Observable
final class APIKeyController {
    private(set) var hasKey: Bool
    private(set) var isValidating = false
    private(set) var errorMessage: String?

    init() {
        hasKey = KeychainStore.readAPIKey() != nil
    }

    /// Checks the key against the API, then stores it. Returns whether it was saved.
    func validateAndSave(_ input: String) async -> Bool {
        let key = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            errorMessage = "Paste an API key first."
            return false
        }
        isValidating = true
        errorMessage = nil
        defer { isValidating = false }
        do {
            try await APIKeyValidator.validate(key)
            try KeychainStore.saveAPIKey(key)
            hasKey = true
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func remove() {
        do {
            try KeychainStore.deleteAPIKey()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        hasKey = KeychainStore.readAPIKey() != nil
    }
}
