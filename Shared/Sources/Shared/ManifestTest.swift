import Foundation

/// A test declared in a manifest.
public enum ManifestTest: Codable, Sendable, Equatable {
    /// Runs steps `0...step` against a fake environment and compares step `step`'s output.
    case unit(UnitTest)
    /// Runs the automation in the runner's own harness window and compares the window's text.
    case harness(HarnessTest)
    /// Really runs one script step, in a sandbox, with fixed inputs and copied fixture files.
    case script(ScriptTest)

    public struct UnitTest: Codable, Sendable, Equatable {
        public var step: Int
        /// Fixed "now" for the run, ISO 8601. Defaults to the real time. With a fixed clock,
        /// dates are formatted in UTC so expectations do not depend on the Mac's time zone.
        public var clock: Date?
        /// Starting clipboard contents for the fake environment.
        public var clipboard: String?
        /// Expected output; may use `{{today:<pattern>}}`, resolved against `clock`.
        public var expect: String

        public init(step: Int, clock: Date? = nil, clipboard: String? = nil, expect: String) {
            self.step = step
            self.clock = clock
            self.clipboard = clipboard
            self.expect = expect
        }
    }

    public struct HarnessTest: Codable, Sendable, Equatable {
        public enum Fire: String, Codable, Sendable {
            /// Call the automation directly, then also post its real hotkey.
            case trigger
            /// Only call the automation directly.
            case handler
        }

        /// What is selected in the harness window before the automation runs.
        public enum Selection: String, Codable, Sendable {
            /// All of `setupText` is selected.
            case all
            /// Nothing is selected; the insertion point is after `setupText`.
            case atEnd = "none"
        }

        public var fire: Fire
        /// Text the harness window starts with (empty when nil).
        public var setupText: String?
        public var select: Selection
        /// Text the harness window should contain afterwards; may use `{{today:<pattern>}}`.
        public var expectText: String

        public init(
            fire: Fire = .trigger,
            setupText: String? = nil,
            select: Selection = .atEnd,
            expectText: String
        ) {
            self.fire = fire
            self.setupText = setupText
            self.select = select
            self.expectText = expectText
        }
    }

    /// Runs step `step` (applescript, jxa or shell) for real under `sandbox-exec`: no network,
    /// no Apple Events, and file writes only inside a temporary copy of `fixtures`.
    public struct ScriptTest: Codable, Sendable, Equatable {
        public var step: Int
        /// Earlier outputs by name, passed exactly as in a normal run. The runner adds
        /// `fixtures_dir`, the path of the fixture copy.
        public var inputs: [String: String]
        /// Folder inside the automation folder, copied to a temporary folder that becomes the
        /// script's working directory and `HOME`. Without it the script starts in an empty folder.
        public var fixtures: String?
        /// Exact expected output; may use `{{today:<pattern>}}`.
        public var expect: String?
        /// Text the output must contain.
        public var expectContains: String?
        /// Paths relative to the fixture copy that must exist afterwards.
        public var expectFiles: [String]
        /// Paths relative to the fixture copy that must not exist afterwards.
        public var expectMissing: [String]

        public init(
            step: Int,
            inputs: [String: String] = [:],
            fixtures: String? = nil,
            expect: String? = nil,
            expectContains: String? = nil,
            expectFiles: [String] = [],
            expectMissing: [String] = []
        ) {
            self.step = step
            self.inputs = inputs
            self.fixtures = fixtures
            self.expect = expect
            self.expectContains = expectContains
            self.expectFiles = expectFiles
            self.expectMissing = expectMissing
        }

        /// The test checks at least one thing.
        public var hasExpectation: Bool {
            expect != nil || expectContains != nil || !expectFiles.isEmpty || !expectMissing.isEmpty
        }
    }

    private enum CodingKeys: String, CodingKey {
        case kind, step, clock, clipboard, expect, fire, expectText, setupText, select
        case inputs, fixtures, expectContains, expectFiles, expectMissing
    }

    private typealias Container = KeyedDecodingContainer<CodingKeys>

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "unit":
            self = .unit(try Self.decodeUnit(container))
        case "harness":
            self = .harness(HarnessTest(
                fire: try container.decodeIfPresent(HarnessTest.Fire.self, forKey: .fire) ?? .trigger,
                setupText: try container.decodeIfPresent(String.self, forKey: .setupText),
                select: try container.decodeIfPresent(HarnessTest.Selection.self, forKey: .select) ?? .atEnd,
                expectText: try container.decode(String.self, forKey: .expectText)
            ))
        case "script":
            self = .script(try Self.decodeScript(container))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "Unknown test kind \"\(kind)\". Supported: unit, harness, script."
            )
        }
    }

    private static func decodeUnit(_ container: Container) throws -> UnitTest {
        var clock: Date?
        if let clockText = try container.decodeIfPresent(String.self, forKey: .clock) {
            guard let parsed = try? Date(clockText, strategy: .iso8601) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .clock,
                    in: container,
                    debugDescription: "\"clock\" must be an ISO 8601 date such as 2024-12-30T12:00:00Z."
                )
            }
            clock = parsed
        }
        return UnitTest(
            step: try container.decode(Int.self, forKey: .step),
            clock: clock,
            clipboard: try container.decodeIfPresent(String.self, forKey: .clipboard),
            expect: try container.decode(String.self, forKey: .expect)
        )
    }

    private static func decodeScript(_ container: Container) throws -> ScriptTest {
        ScriptTest(
            step: try container.decode(Int.self, forKey: .step),
            inputs: try container.decodeIfPresent([String: String].self, forKey: .inputs) ?? [:],
            fixtures: try container.decodeIfPresent(String.self, forKey: .fixtures),
            expect: try container.decodeIfPresent(String.self, forKey: .expect),
            expectContains: try container.decodeIfPresent(String.self, forKey: .expectContains),
            expectFiles: try container.decodeIfPresent([String].self, forKey: .expectFiles) ?? [],
            expectMissing: try container.decodeIfPresent([String].self, forKey: .expectMissing) ?? []
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kindName, forKey: .kind)
        switch self {
        case .unit(let test):
            try container.encode(test.step, forKey: .step)
            try container.encodeIfPresent(test.clock?.formatted(.iso8601), forKey: .clock)
            try container.encodeIfPresent(test.clipboard, forKey: .clipboard)
            try container.encode(test.expect, forKey: .expect)
        case .harness(let test):
            try container.encode(test.fire, forKey: .fire)
            try container.encodeIfPresent(test.setupText, forKey: .setupText)
            if test.select != .atEnd { try container.encode(test.select, forKey: .select) }
            try container.encode(test.expectText, forKey: .expectText)
        case .script(let test):
            try container.encode(test.step, forKey: .step)
            if !test.inputs.isEmpty { try container.encode(test.inputs, forKey: .inputs) }
            try container.encodeIfPresent(test.fixtures, forKey: .fixtures)
            try container.encodeIfPresent(test.expect, forKey: .expect)
            try container.encodeIfPresent(test.expectContains, forKey: .expectContains)
            if !test.expectFiles.isEmpty { try container.encode(test.expectFiles, forKey: .expectFiles) }
            if !test.expectMissing.isEmpty { try container.encode(test.expectMissing, forKey: .expectMissing) }
        }
    }

    public var kindName: String {
        switch self {
        case .unit: "unit"
        case .harness: "harness"
        case .script: "script"
        }
    }
}
