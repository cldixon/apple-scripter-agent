import Foundation

/// One automation: a trigger, ordered steps, declared permissions and tests.
///
/// Stored as `manifest.json` in the automation's folder; script steps point at files
/// beside it. The JSON shape is documented by `ManifestSchema.json`.
public struct AutomationManifest: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var description: String?
    /// The user's original words.
    public var request: String?
    public var trigger: Trigger
    public var steps: [Step]
    public var permissions: [Permission]
    /// Deletes, moves or overwrites user data, or sends messages. Shown in red at approval.
    public var destructive: Bool
    public var tests: [ManifestTest]
    public var version: Int

    public init(
        id: String,
        name: String,
        description: String? = nil,
        request: String? = nil,
        trigger: Trigger,
        steps: [Step],
        permissions: [Permission] = [],
        destructive: Bool = false,
        tests: [ManifestTest] = [],
        version: Int = 1
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.request = request
        self.trigger = trigger
        self.steps = steps
        self.permissions = permissions
        self.destructive = destructive
        self.tests = tests
        self.version = version
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, description, request, trigger, steps, permissions, destructive, tests, version
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? id
        description = try container.decodeIfPresent(String.self, forKey: .description)
        request = try container.decodeIfPresent(String.self, forKey: .request)
        trigger = try container.decode(Trigger.self, forKey: .trigger)
        steps = try container.decode([Step].self, forKey: .steps)
        permissions = try container.decodeIfPresent([Permission].self, forKey: .permissions) ?? []
        destructive = try container.decodeIfPresent(Bool.self, forKey: .destructive) ?? false
        tests = try container.decodeIfPresent([ManifestTest].self, forKey: .tests) ?? []
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
    }

    public static func decode(from data: Data) throws -> AutomationManifest {
        try JSONDecoder().decode(AutomationManifest.self, from: data)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

// MARK: - Permissions

/// A privacy permission the automation needs: `accessibility`, `automation:<bundle id>`,
/// `fullDiskAccess` or `screenRecording`.
public struct Permission: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static let accessibility = Permission(rawValue: "accessibility")
    public static let fullDiskAccess = Permission(rawValue: "fullDiskAccess")
    public static let screenRecording = Permission(rawValue: "screenRecording")

    public static func automation(_ bundleID: String) -> Permission {
        Permission(rawValue: "automation:\(bundleID)")
    }

    /// The target bundle id for an `automation:` permission.
    public var automationTarget: String? {
        rawValue.hasPrefix("automation:") ? String(rawValue.dropFirst("automation:".count)) : nil
    }

    public var description: String { rawValue }
}

// MARK: - Triggers

public enum Trigger: Codable, Sendable, Equatable {
    case hotkey(Hotkey)
    case manual

    private enum CodingKeys: String, CodingKey {
        case type, key, modifiers
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "hotkey":
            let key = try container.decode(String.self, forKey: .key)
            let modifiers = try container.decodeIfPresent([Hotkey.Modifier].self, forKey: .modifiers) ?? []
            self = .hotkey(Hotkey(key: key, modifiers: modifiers))
        case "manual":
            self = .manual
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown trigger type \"\(type)\". Supported: hotkey, manual."
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .hotkey(let hotkey):
            try container.encode("hotkey", forKey: .type)
            try container.encode(hotkey.key, forKey: .key)
            try container.encode(hotkey.modifiers, forKey: .modifiers)
        case .manual:
            try container.encode("manual", forKey: .type)
        }
    }

    public var summary: String {
        switch self {
        case .hotkey(let hotkey): "Hotkey \(hotkey.displayString)"
        case .manual: "Manual"
        }
    }
}

public struct Hotkey: Codable, Sendable, Hashable {
    public enum Modifier: String, Codable, Sendable, CaseIterable {
        case ctrl, opt, cmd, shift

        /// Display order used by macOS menus: ⌃⌥⇧⌘.
        var sortOrder: Int {
            switch self {
            case .ctrl: 0
            case .opt: 1
            case .shift: 2
            case .cmd: 3
            }
        }

        public var symbol: String {
            switch self {
            case .ctrl: "⌃"
            case .opt: "⌥"
            case .shift: "⇧"
            case .cmd: "⌘"
            }
        }
    }

    public var key: String
    public var modifiers: [Modifier]

    public init(key: String, modifiers: [Modifier]) {
        self.key = key
        self.modifiers = modifiers
    }

    public var displayString: String {
        let symbols = Set(modifiers).sorted { $0.sortOrder < $1.sortOrder }.map(\.symbol).joined()
        return symbols + key.uppercased()
    }
}
