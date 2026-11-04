import Foundation
@testable import Shared
import Testing

struct RunnerMessagesTests {
    @Test func pingRequestRoundTrips() throws {
        let request = PingRequest(sentAt: Date(timeIntervalSince1970: 1_700_000_000.123), clientVersion: "0.1.0 (1)")
        let decoded = try XPCCoding.decode(PingRequest.self, from: XPCCoding.encode(request))
        #expect(decoded == request)
    }

    @Test func pingResponseRoundTrips() throws {
        let response = PingResponse(
            runnerVersion: "0.1.0 (1)",
            processID: 4242,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            receivedAt: Date(timeIntervalSince1970: 1_700_000_042.5),
            bundlePath: "/Applications/AutomationAgent.app/Contents/Library/LoginItems/AutomationAgentRunner.app",
            pingsServed: 7
        )
        let decoded = try XPCCoding.decode(PingResponse.self, from: XPCCoding.encode(response))
        #expect(decoded == response)
    }

    @Test func decodingGarbageThrows() {
        #expect(throws: (any Error).self) {
            try XPCCoding.decode(PingResponse.self, from: Data("not json".utf8))
        }
    }
}

struct BundleVersionTests {
    @Test func readsVersionAndBuild() {
        let version = BundleVersion(infoDictionary: [
            "CFBundleShortVersionString": "1.2.3",
            "CFBundleVersion": "45"
        ])
        #expect(version == BundleVersion(version: "1.2.3", build: "45"))
        #expect(version.description == "1.2.3 (45)")
    }

    @Test func fallsBackWhenMissing() {
        #expect(BundleVersion(infoDictionary: nil) == BundleVersion(version: "0", build: "0"))
    }
}
