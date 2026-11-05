import Foundation

/// The `sandbox-exec` profile and command line for `script` tests. Script tests run during
/// `validate`, without the person's approval, so they get no network, cannot send Apple
/// Events or write preferences, and can write files only inside their own temporary folder.
public enum ScriptTestSandbox {
    public static let executable = "/usr/bin/sandbox-exec"

    /// Whether this Mac has `sandbox-exec` (every macOS release so far does).
    public static var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: executable)
    }

    /// Device files a script may still write to (`> /dev/null`, `/dev/stdout`, ...).
    static let writableDeviceLiterals = [
        "/dev/null", "/dev/zero", "/dev/tty", "/dev/dtracehelper", "/dev/stdout", "/dev/stderr"
    ]

    /// An SBPL profile: everything is allowed except network access, sending Apple Events,
    /// writing preferences through cfprefsd, and writing files outside `writablePaths` (and a
    /// few device files). Later rules win in SBPL, so the final `allow` re-opens those paths.
    /// Each path is added as given and, when different, with symlinks resolved, because the
    /// sandbox checks resolved paths (`/var` is `/private/var`).
    public static func profile(writablePaths: [String]) -> String {
        var paths: [String] = []
        for path in writablePaths {
            for candidate in [path, canonicalPath(path)] where !paths.contains(candidate) {
                paths.append(candidate)
            }
        }
        var lines = [
            "(version 1)",
            "(allow default)",
            "(deny network*)",
            "(deny appleevent-send)",
            "(deny user-preference-write)",
            "(deny file-write*)",
            "(allow file-write*"
        ]
        lines += paths.map { "    (subpath \(quoted($0)))" }
        lines += writableDeviceLiterals.map { "    (literal \(quoted($0)))" }
        lines.append("    (subpath \"/dev/fd\"))")
        return lines.joined(separator: "\n") + "\n"
    }

    /// `text` as an SBPL (Scheme) string literal: backslashes and quotes escaped, line
    /// breaks and tabs written as escapes.
    public static func quoted(_ text: String) -> String {
        var result = "\""
        for character in text {
            switch character {
            case "\\": result += "\\\\"
            case "\"": result += "\\\""
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default: result.append(character)
            }
        }
        return result + "\""
    }

    /// `path` with every symlink resolved (keeping `/private`). For a path that does not exist,
    /// the nearest existing ancestor is resolved and the rest appended, so `/var/...` and
    /// `/private/var/...` still compare equal. Unlike `URL.resolvingSymlinksInPath()`, this
    /// does not strip `/private`.
    public static func canonicalPath(_ path: String) -> String {
        if let resolved = realpath(path, nil) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        let url = URL(filePath: path)
        let parent = url.deletingLastPathComponent().path
        guard !parent.isEmpty, parent != path, parent != "/" else { return path }
        let base = canonicalPath(parent)
        return (base.hasSuffix("/") ? base : base + "/") + url.lastPathComponent
    }

    /// The per-user cache folder in `/private/var/folders` (`.../C/`), which system tools such
    /// as `osascript` write to. Nil if it cannot be found.
    public static func userCacheDirectory() -> String? {
        let size = confstr(_CS_DARWIN_USER_CACHE_DIR, nil, 0)
        guard size > 1 else { return nil }
        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: size)
        defer { buffer.deallocate() }
        guard confstr(_CS_DARWIN_USER_CACHE_DIR, buffer, size) > 0 else { return nil }
        let path = String(cString: buffer)
        return path.isEmpty ? nil : path
    }

    /// Arguments for `sandbox-exec` that apply `profile`, change to `directory`, then replace
    /// themselves with `tool arguments...` (same process, so a timeout kill reaches the tool).
    public static func arguments(
        profile: String,
        directory: String,
        tool: String,
        toolArguments: [String]
    ) -> [String] {
        let launcher = "cd -- \"$1\" || exit 125; shift; exec \"$@\""
        return ["-p", profile, "/bin/zsh", "-f", "-c", launcher, "zsh", directory, tool] + toolArguments
    }
}

/// Relative paths in script tests (`fixtures`, `expectFiles`, `expectMissing`).
public enum ScriptTestPaths {
    /// Whether `path` is relative and stays inside its base folder: not empty, not absolute,
    /// no `~`, `.` or `..` components, no backslashes or NUL.
    public static func isSafeRelative(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("~"),
              !path.contains("\\"), !path.contains("\u{0}") else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.isEmpty else { return false }
        return !components.contains { $0 == "." || $0 == ".." }
    }

    /// Whether `url`, with symlinks resolved, is `base` or inside it.
    public static func isInside(_ url: URL, base: URL) -> Bool {
        let resolved = ScriptTestSandbox.canonicalPath(url.path)
        let root = ScriptTestSandbox.canonicalPath(base.path)
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return resolved == root || resolved.hasPrefix(prefix)
    }
}
