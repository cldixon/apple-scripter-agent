import AppIntents
import Foundation
import Shared

/// An installed automation as Shortcuts, Spotlight and Siri see it. The runner owns the
/// catalog, so every lookup asks it over XPC; nothing is cached in the app.
struct AutomationEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Automation")
    }

    static var defaultQuery: AutomationEntityQuery {
        AutomationEntityQuery()
    }

    /// The automation's manifest id.
    let id: String
    let name: String
    /// The trigger in words, as the Catalog shows it.
    let triggerSummary: String

    init(id: String, name: String, triggerSummary: String) {
        self.id = id
        self.name = name
        self.triggerSummary = triggerSummary
    }

    init(summary: AutomationSummary) {
        self.init(id: summary.id, name: summary.name, triggerSummary: summary.trigger)
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(triggerSummary)")
    }
}

/// Finds automations by id (Shortcuts resolving a saved action), lists them (the picker and
/// App Shortcut parameters) and searches them by name.
struct AutomationEntityQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [AutomationEntity] {
        let wanted = Set(identifiers)
        return try await AutomationDirectory.all().filter { wanted.contains($0.id) }
    }

    func suggestedEntities() async throws -> [AutomationEntity] {
        try await AutomationDirectory.all()
    }

    func entities(matching string: String) async throws -> [AutomationEntity] {
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let all = try await AutomationDirectory.all()
        guard !query.isEmpty else { return all }
        return all.filter { entity in
            entity.name.localizedCaseInsensitiveContains(query)
                || entity.id.localizedCaseInsensitiveContains(query)
        }
    }
}

/// The runner's list of installed automations, as entities.
enum AutomationDirectory {
    static func all() async throws -> [AutomationEntity] {
        let reply: RunnerReply
        do {
            reply = try await RunnerClient().send(.listAutomations, timeout: 10)
        } catch {
            throw AutomationIntentError.runner(error.localizedDescription)
        }
        switch reply {
        case .automations(let list, _):
            return list.map { AutomationEntity(summary: $0) }
        case .failure(let text):
            throw AutomationIntentError.runner(text)
        default:
            throw AutomationIntentError.unexpectedReply
        }
    }
}

/// Errors Shortcuts and Siri show when an automation cannot be listed or run.
enum AutomationIntentError: Error, CustomLocalizedStringResourceConvertible {
    case runner(String)
    case unexpectedReply
    case failed(name: String, reason: String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .runner(let text):
            "The Automation Agent runner could not do that: \(text)"
        case .unexpectedReply:
            "The runner sent a reply this version of Automation Agent does not understand."
        case .failed(let name, let reason):
            "\(name) failed: \(reason)"
        }
    }
}
