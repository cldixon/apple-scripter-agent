import Foundation

/// A test declared in a manifest.
public enum ManifestTest: Codable, Sendable, Equatable {
    /// Runs steps `0...step` against a fake environment and compares step `step`'s output.
    case unit(UnitTest)
    /// Runs the automation in the runner's own harness window and compares the window's text.
    case harness(HarnessTest)

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

        public var fire: Fire
        /// Text the harness window should contain afterwards; may use `{{today:<pattern>}}`.
        public var expectText: String

        public init(fire: Fire = .trigger, expectText: String) {
            self.fire = fire
            self.expectText = expectText
        }
    }

    private enum CodingKeys: String, CodingKey {
        case kind, step, clock, clipboard, expect, fire, expectText
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "unit":
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
            self = .unit(UnitTest(
                step: try container.decode(Int.self, forKey: .step),
                clock: clock,
                clipboard: try container.decodeIfPresent(String.self, forKey: .clipboard),
                expect: try container.decode(String.self, forKey: .expect)
            ))
        case "harness":
            self = .harness(HarnessTest(
                fire: try container.decodeIfPresent(HarnessTest.Fire.self, forKey: .fire) ?? .trigger,
                expectText: try container.decode(String.self, forKey: .expectText)
            ))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "Unknown test kind \"\(kind)\". Supported: unit, harness."
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .unit(let test):
            try container.encode("unit", forKey: .kind)
            try container.encode(test.step, forKey: .step)
            try container.encodeIfPresent(test.clock?.formatted(.iso8601), forKey: .clock)
            try container.encodeIfPresent(test.clipboard, forKey: .clipboard)
            try container.encode(test.expect, forKey: .expect)
        case .harness(let test):
            try container.encode("harness", forKey: .kind)
            try container.encode(test.fire, forKey: .fire)
            try container.encode(test.expectText, forKey: .expectText)
        }
    }

    public var kindName: String {
        switch self {
        case .unit: "unit"
        case .harness: "harness"
        }
    }
}
