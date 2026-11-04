import Foundation

/// An app (or scripting addition) found on disk, read from its Info.plist.
struct FoundApp: Sendable, Equatable {
    var name: String
    var bundleID: String
    var url: URL
    var version: String
    var scriptable: Bool
    /// `OSAScriptingDefinition` is "dynamic": reading the dictionary launches the app.
    var dynamicDictionary = false

    /// Changes whenever the app is updated, so its dictionary is read again.
    var fingerprint: String { "\(bundleID)@\(version)" }
}

/// Finds installed apps. Reads Info.plist files directly (not through `Bundle`, which caches
/// them for the life of the process) so updates are noticed.
enum AppScanner {
    static var folders: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            URL(filePath: "/Applications", directoryHint: .isDirectory),
            URL(filePath: "/Applications/Utilities", directoryHint: .isDirectory),
            URL(filePath: "/System/Applications", directoryHint: .isDirectory),
            URL(filePath: "/System/Applications/Utilities", directoryHint: .isDirectory),
            home.appending(path: "Applications", directoryHint: .isDirectory)
        ]
    }

    /// Scriptable apps that live outside the usual folders.
    static let coreServicesApps = [
        URL(filePath: "/System/Library/CoreServices/Finder.app", directoryHint: .isDirectory),
        URL(filePath: "/System/Library/CoreServices/System Events.app", directoryHint: .isDirectory)
    ]

    static let standardAdditions = URL(
        filePath: "/System/Library/ScriptingAdditions/StandardAdditions.osax", directoryHint: .isDirectory
    )

    /// Every app in the app folders (and `.app`s one folder deeper), plus Finder and System
    /// Events, sorted by name, one entry per bundle id.
    static func scan() -> [FoundApp] {
        let fileManager = FileManager.default
        var candidates: [URL] = []
        for folder in folders {
            let items = (try? fileManager.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
            )) ?? []
            for item in items {
                if item.pathExtension == "app" {
                    candidates.append(item)
                } else if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    let nested = (try? fileManager.contentsOfDirectory(
                        at: item, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
                    )) ?? []
                    candidates += nested.filter { $0.pathExtension == "app" }
                }
            }
        }
        candidates += coreServicesApps
        var seen: Set<String> = []
        return candidates
            .compactMap { info(at: $0) }
            .filter { seen.insert($0.bundleID).inserted }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Reads a bundle's Info.plist. Nil when it has none or no bundle id.
    static func info(at url: URL) -> FoundApp? {
        let plistURL = url.appending(path: "Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let info = plist as? [String: Any],
              let bundleID = info["CFBundleIdentifier"] as? String else { return nil }
        let short = info["CFBundleShortVersionString"] as? String ?? ""
        let build = info["CFBundleVersion"] as? String ?? ""
        let enabled = (info["NSAppleScriptEnabled"] as? Bool) == true
            || ["yes", "true"].contains((info["NSAppleScriptEnabled"] as? String)?.lowercased() ?? "")
        let isAddition = url.pathExtension == "osax"
        return FoundApp(
            name: isAddition ? "Standard Additions" : url.deletingPathExtension().lastPathComponent,
            bundleID: bundleID,
            url: url,
            version: "\(short) (\(build))",
            scriptable: enabled || info["OSAScriptingDefinition"] != nil || isAddition,
            dynamicDictionary: (info["OSAScriptingDefinition"] as? String) == "dynamic"
        )
    }

    /// Finds `app` by name ("Mail", "Mail.app"), bundle id or path. `hint` is the URL Launch
    /// Services gave for the text as a bundle id, if any.
    static func resolve(_ app: String, in apps: [FoundApp], hint: URL?) -> FoundApp? {
        var text = app.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasSuffix(".app") { text = String(text.dropLast(4)) }
        let lowered = text.lowercased()
        if ["standard additions", "standardadditions", "scripting additions", "osax"].contains(lowered)
            || lowered == "com.apple.osax.standardadditions" {
            return info(at: standardAdditions)
        }
        if text.hasPrefix("/") {
            return info(at: URL(filePath: app.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        if let match = apps.first(where: { $0.bundleID.lowercased() == lowered || $0.name.lowercased() == lowered }) {
            return match
        }
        return hint.flatMap { info(at: $0) }
    }
}
