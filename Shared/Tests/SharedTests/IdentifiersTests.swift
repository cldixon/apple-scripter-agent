import Foundation
@testable import Shared
import Testing

/// Checks that the names hard-coded in `Identifiers` match the plist and project files
/// that ship in the app bundle. A mismatch here means launchd or XPC lookups fail at runtime.
struct IdentifiersTests {
    private static let repoRoot = URL(filePath: #filePath)
        .deletingLastPathComponent() // SharedTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // Shared
        .deletingLastPathComponent() // repo root

    private func plist(_ relativePath: String) throws -> [String: Any] {
        let data = try Data(contentsOf: Self.repoRoot.appending(path: relativePath))
        let object = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try #require(object as? [String: Any])
    }

    @Test func launchAgentPlistMatchesIdentifiers() throws {
        let agent = try plist("App/LaunchAgents/\(Identifiers.runnerLaunchAgentPlistName)")
        #expect(agent["Label"] as? String == Identifiers.runnerLaunchAgentLabel)
        #expect(agent["BundleProgram"] as? String == Identifiers.runnerBundleProgram)

        let machServices = try #require(agent["MachServices"] as? [String: Bool])
        #expect(machServices == [Identifiers.runnerMachServiceName: true])

        let associated = try #require(agent["AssociatedBundleIdentifiers"] as? [String])
        #expect(associated == [Identifiers.appBundleID])
    }

    @Test func runnerIsABackgroundApp() throws {
        let info = try plist("Runner/Info.plist")
        #expect(info["LSUIElement"] as? Bool == true)
        #expect(info["NSAppleEventsUsageDescription"] is String)
    }

    @Test func runnerHasAppleEventsEntitlement() throws {
        let entitlements = try plist("Runner/Runner.entitlements")
        #expect(entitlements["com.apple.security.automation.apple-events"] as? Bool == true)
    }

    @Test func projectUsesTheSameBundleIdentifiers() throws {
        let project = try String(contentsOf: Self.repoRoot.appending(path: "project.yml"), encoding: .utf8)
        #expect(project.contains("PRODUCT_BUNDLE_IDENTIFIER: \(Identifiers.appBundleID)\n"))
        #expect(project.contains("PRODUCT_BUNDLE_IDENTIFIER: \(Identifiers.runnerBundleID)\n"))
        #expect(project.contains("PRODUCT_NAME: \(Identifiers.runnerProductName)\n"))
    }
}
