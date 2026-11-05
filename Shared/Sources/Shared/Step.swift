import Foundation

/// One step of an automation. Steps run in order; a step can name its output with `as`
/// and later steps reference it as `{{name}}`.
public struct Step: Codable, Sendable, Equatable {
    public enum Body: Sendable, Equatable {
        case primitive(Primitive)
        case applescript(ScriptSource)
        case jxa(ScriptSource)
        case shell(ScriptSource)
        case shortcut(name: String, input: String?)
        case accessibility(action: String)

        /// The manifest's `type` value.
        public var typeName: String {
            switch self {
            case .primitive: "primitive"
            case .applescript: "applescript"
            case .jxa: "jxa"
            case .shell: "shell"
            case .shortcut: "shortcut"
            case .accessibility: "ax"
            }
        }
    }

    public var body: Body
    /// Name under which later steps can reference this step's output (`"as"` in JSON).
    public var output: String?
    /// Seconds before the step is abandoned. Defaults to `Step.defaultTimeout(for:)`.
    public var timeout: Double?

    /// The default timeout of a primitive step. Other step types default to more; see
    /// `defaultTimeout(for:)`.
    public static let defaultTimeout: Double = 10

    /// Default seconds before a step is abandoned, by step type: primitives 10 (askText 300,
    /// because a person is typing), AppleScript, JXA and shell 30, shortcuts 60.
    public static func defaultTimeout(for body: Body) -> Double {
        switch body {
        case .primitive(.askText): 300
        case .primitive, .accessibility: defaultTimeout
        case .applescript, .jxa, .shell: 30
        case .shortcut: 60
        }
    }

    public init(_ body: Body, output: String? = nil, timeout: Double? = nil) {
        self.body = body
        self.output = output
        self.timeout = timeout
    }

    public var effectiveTimeout: Double { timeout ?? Self.defaultTimeout(for: body) }

    /// Template strings this step's arguments contain, for static checks.
    public var templateStrings: [String] {
        switch body {
        case .primitive(let primitive): primitive.templateStrings
        case .shortcut(_, let input): input.map { [$0] } ?? []
        case .applescript, .jxa, .shell, .accessibility: []
        }
    }

    // MARK: Coding

    fileprivate enum CodingKeys: String, CodingKey {
        case type, action, output = "as", timeout
        case pattern, text, title, url, app, seconds
        case file, source, name, input
        case keys, prompt, defaultValue = "default"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        output = try container.decodeIfPresent(String.self, forKey: .output)
        timeout = try container.decodeIfPresent(Double.self, forKey: .timeout)

        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "primitive":
            body = .primitive(try Primitive(from: container))
        case "applescript":
            body = .applescript(try ScriptSource(from: container))
        case "jxa":
            body = .jxa(try ScriptSource(from: container))
        case "shell":
            body = .shell(try ScriptSource(from: container))
        case "shortcut":
            body = .shortcut(
                name: try container.decode(String.self, forKey: .name),
                input: try container.decodeIfPresent(String.self, forKey: .input)
            )
        case "ax":
            body = .accessibility(action: try container.decode(String.self, forKey: .action))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown step type \"\(type)\". "
                    + "Supported: primitive, applescript, jxa, shell, shortcut, ax."
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(body.typeName, forKey: .type)
        try container.encodeIfPresent(output, forKey: .output)
        try container.encodeIfPresent(timeout, forKey: .timeout)
        switch body {
        case .primitive(let primitive):
            try primitive.encode(to: &container)
        case .applescript(let source), .jxa(let source), .shell(let source):
            try container.encodeIfPresent(source.file, forKey: .file)
            try container.encodeIfPresent(source.source, forKey: .source)
        case .shortcut(let name, let input):
            try container.encode(name, forKey: .name)
            try container.encodeIfPresent(input, forKey: .input)
        case .accessibility(let action):
            try container.encode(action, forKey: .action)
        }
    }

    fileprivate typealias Container = KeyedDecodingContainer<CodingKeys>
    fileprivate typealias EncodingContainer = KeyedEncodingContainer<CodingKeys>
}

/// Where a script step's code comes from: a file beside the manifest, or inline source.
public struct ScriptSource: Sendable, Equatable {
    public var file: String?
    public var source: String?

    public init(file: String? = nil, source: String? = nil) {
        self.file = file
        self.source = source
    }

    fileprivate init(from container: Step.Container) throws {
        file = try container.decodeIfPresent(String.self, forKey: .file)
        source = try container.decodeIfPresent(String.self, forKey: .source)
        if file == nil && source == nil {
            throw DecodingError.dataCorruptedError(
                forKey: .file,
                in: container,
                debugDescription: "A script step needs either \"file\" or \"source\"."
            )
        }
    }
}

/// Building blocks built into the runner.
public enum Primitive: Sendable, Equatable {
    case formatDate(pattern: String)
    case typeText(String)
    case pasteText(String)
    case readClipboard
    case writeClipboard(String)
    case notify(title: String?, text: String)
    case openURL(String)
    case launchApp(String)
    case delay(seconds: Double)
    /// Copies the frontmost app's selection (⌘C) and returns it as text.
    case copySelection
    /// Presses a key combination such as `cmd+shift+4` (see `KeyCombo`).
    case pressKeys(String)
    /// Asks the user for text in the runner's own panel. Cancel stops the run as skipped.
    case askText(prompt: String, defaultValue: String?)

    public static let actionNames = [
        "formatDate", "typeText", "pasteText", "readClipboard", "writeClipboard",
        "notify", "openURL", "launchApp", "delay", "copySelection", "pressKeys", "askText"
    ]

    public var actionName: String {
        switch self {
        case .formatDate: "formatDate"
        case .typeText: "typeText"
        case .pasteText: "pasteText"
        case .readClipboard: "readClipboard"
        case .writeClipboard: "writeClipboard"
        case .notify: "notify"
        case .openURL: "openURL"
        case .launchApp: "launchApp"
        case .delay: "delay"
        case .copySelection: "copySelection"
        case .pressKeys: "pressKeys"
        case .askText: "askText"
        }
    }

    /// Permissions this primitive needs to run.
    public var requiredPermissions: [Permission] {
        switch self {
        case .typeText, .pasteText, .copySelection, .pressKeys: [.accessibility]
        default: []
        }
    }

    var templateStrings: [String] {
        switch self {
        case .formatDate(let pattern): [pattern]
        case .typeText(let text), .pasteText(let text), .writeClipboard(let text): [text]
        case .notify(let title, let text): [title, text].compactMap(\.self)
        case .openURL(let url): [url]
        case .launchApp(let app): [app]
        case .askText(let prompt, let defaultValue): [prompt, defaultValue].compactMap(\.self)
        case .readClipboard, .delay, .copySelection, .pressKeys: []
        }
    }

    fileprivate init(from container: Step.Container) throws {
        let action = try container.decode(String.self, forKey: .action)
        if let interactive = try Self.decodeInteractive(action, from: container) {
            self = interactive
            return
        }
        switch action {
        case "formatDate":
            self = .formatDate(pattern: try container.decode(String.self, forKey: .pattern))
        case "typeText":
            self = .typeText(try container.decode(String.self, forKey: .text))
        case "pasteText":
            self = .pasteText(try container.decode(String.self, forKey: .text))
        case "readClipboard":
            self = .readClipboard
        case "writeClipboard":
            self = .writeClipboard(try container.decode(String.self, forKey: .text))
        case "notify":
            self = .notify(
                title: try container.decodeIfPresent(String.self, forKey: .title),
                text: try container.decode(String.self, forKey: .text)
            )
        case "openURL":
            self = .openURL(try container.decode(String.self, forKey: .url))
        case "launchApp":
            self = .launchApp(try container.decode(String.self, forKey: .app))
        case "delay":
            self = .delay(seconds: try container.decode(Double.self, forKey: .seconds))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .action,
                in: container,
                debugDescription: "Unknown primitive action \"\(action)\". "
                    + "Supported: \(Primitive.actionNames.joined(separator: ", "))."
            )
        }
    }

    /// The primitives that work with the frontmost app or the user, or nil for other actions.
    private static func decodeInteractive(_ action: String, from container: Step.Container) throws -> Primitive? {
        switch action {
        case "copySelection":
            return .copySelection
        case "pressKeys":
            return .pressKeys(try container.decode(String.self, forKey: .keys))
        case "askText":
            return .askText(
                prompt: try container.decode(String.self, forKey: .prompt),
                defaultValue: try container.decodeIfPresent(String.self, forKey: .defaultValue)
            )
        default:
            return nil
        }
    }

    fileprivate func encode(to container: inout Step.EncodingContainer) throws {
        try container.encode(actionName, forKey: .action)
        switch self {
        case .formatDate(let pattern):
            try container.encode(pattern, forKey: .pattern)
        case .typeText(let text), .pasteText(let text), .writeClipboard(let text):
            try container.encode(text, forKey: .text)
        case .notify(let title, let text):
            try container.encodeIfPresent(title, forKey: .title)
            try container.encode(text, forKey: .text)
        case .openURL(let url):
            try container.encode(url, forKey: .url)
        case .launchApp(let app):
            try container.encode(app, forKey: .app)
        case .delay(let seconds):
            try container.encode(seconds, forKey: .seconds)
        case .pressKeys(let keys):
            try container.encode(keys, forKey: .keys)
        case .askText(let prompt, let defaultValue):
            try container.encode(prompt, forKey: .prompt)
            try container.encodeIfPresent(defaultValue, forKey: .defaultValue)
        case .readClipboard, .copySelection:
            break
        }
    }
}
