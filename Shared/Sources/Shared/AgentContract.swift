import Foundation

// Types the agent's tools exchange with the runner (M5). The main app's tools send
// `RunnerCommand`s; the runner answers with these payloads inside `RunnerReply`.

/// One search hit in the reference library.
public struct ReferenceHit: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    /// Where the chunk came from, e.g. "AppleScript Language Guide", "sdef: Finder", "man: pmset", "recipes".
    public var source: String
    public var snippet: String

    public init(id: String, title: String, source: String, snippet: String) {
        self.id = id
        self.title = title
        self.source = source
        self.snippet = snippet
    }
}

/// One chunk of the reference library, read in full (capped in size).
public struct ReferenceChunk: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var source: String
    public var text: String
    /// True when `text` was cut to the size cap.
    public var truncated: Bool

    public init(id: String, title: String, source: String, text: String, truncated: Bool) {
        self.id = id
        self.title = title
        self.source = source
        self.text = text
        self.truncated = truncated
    }
}

/// An installed app as `list_apps` reports it.
public struct AppInfo: Codable, Sendable, Equatable, Identifiable {
    public var id: String { bundleID }
    public var name: String
    public var bundleID: String
    public var path: String
    /// Has a scripting dictionary (sdef).
    public var scriptable: Bool
    public var running: Bool

    public init(name: String, bundleID: String, path: String, scriptable: Bool, running: Bool) {
        self.name = name
        self.bundleID = bundleID
        self.path = path
        self.scriptable = scriptable
        self.running = running
    }
}

/// A compact summary of an app's scripting dictionary (classes, properties, elements,
/// commands with parameters), optionally filtered to entries matching a query.
public struct AppDictionarySummary: Codable, Sendable, Equatable {
    public var app: String
    public var bundleID: String?
    public var text: String
    public var truncated: Bool

    public init(app: String, bundleID: String?, text: String, truncated: Bool) {
        self.app = app
        self.bundleID = bundleID
        self.text = text
        self.truncated = truncated
    }
}

/// The runner's privacy permission state for one permission.
public struct PermissionStatus: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable {
        case granted, denied, notDetermined, unknown
    }

    public var permission: Permission
    public var state: State
    /// Human-readable detail, e.g. where to change it.
    public var detail: String

    public init(permission: Permission, state: State, detail: String) {
        self.permission = permission
        self.state = state
        self.detail = detail
    }
}

/// An installed automation in full: its summary, manifest and the text of its other files.
public struct AutomationDetail: Codable, Sendable, Equatable {
    public var summary: AutomationSummary
    public var manifestJSON: String
    /// Relative path → contents, for text files beside the manifest (scripts, fixtures).
    public var files: [String: String]

    public init(summary: AutomationSummary, manifestJSON: String, files: [String: String]) {
        self.summary = summary
        self.manifestJSON = manifestJSON
        self.files = files
    }
}

/// A file the agent writes into a draft folder, relative to it (e.g. "scripts/run.applescript").
public struct DraftFile: Codable, Sendable, Equatable {
    public var path: String
    public var contents: String

    public init(path: String, contents: String) {
        self.path = path
        self.contents = contents
    }
}
