import Foundation

/// Marketing version and build number read from a bundle's Info.plist.
public struct BundleVersion: Sendable, Equatable, CustomStringConvertible {
    public var version: String
    public var build: String

    public init(version: String, build: String) {
        self.version = version
        self.build = build
    }

    public init(infoDictionary: [String: Any]?) {
        version = infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        build = infoDictionary?["CFBundleVersion"] as? String ?? "0"
    }

    public static func of(_ bundle: Bundle) -> BundleVersion {
        BundleVersion(infoDictionary: bundle.infoDictionary)
    }

    public var description: String { "\(version) (\(build))" }
}
