import Foundation
import Security
import Shared

/// Who may talk to the runner over XPC.
enum CodeSigning {
    /// The Apple Developer team that signed this process, or nil for unsigned/ad hoc builds.
    static func currentTeamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &info) == errSecSuccess,
              let dictionary = info as? [String: Any] else { return nil }
        return dictionary[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// Only the main app, signed by the same team as the runner, may connect.
    /// Without a team (a build that is not properly signed) only the bundle id is checked.
    static func clientRequirement() -> String {
        let identifier = "identifier \"\(Identifiers.appBundleID)\""
        guard let team = currentTeamIdentifier() else { return identifier }
        return "\(identifier) and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
    }
}
