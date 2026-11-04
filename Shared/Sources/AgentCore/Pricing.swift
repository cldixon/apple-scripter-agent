import Foundation

/// Token counts from a response's `usage`. `inputTokens` excludes cached tokens, which are
/// reported separately as cache reads and cache writes.
public struct TokenUsage: Sendable, Equatable, Codable {
    public var inputTokens = 0
    public var outputTokens = 0
    public var cacheReadInputTokens = 0
    public var cacheCreationInputTokens = 0

    public init(input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheCreation: Int = 0) {
        inputTokens = input
        outputTokens = output
        cacheReadInputTokens = cacheRead
        cacheCreationInputTokens = cacheCreation
    }

    /// Every input token, cached or not.
    public var totalInputTokens: Int {
        inputTokens + cacheReadInputTokens + cacheCreationInputTokens
    }

    /// Overwrites the fields present in a `usage` object. `message_start` carries the input
    /// counts; `message_delta` carries cumulative counts, so later values replace earlier ones.
    public mutating func apply(_ json: JSONValue) {
        if let value = json["input_tokens"]?.intValue { inputTokens = value }
        if let value = json["output_tokens"]?.intValue { outputTokens = value }
        if let value = json["cache_read_input_tokens"]?.intValue { cacheReadInputTokens = value }
        if let value = json["cache_creation_input_tokens"]?.intValue { cacheCreationInputTokens = value }
    }

    public static func += (lhs: inout TokenUsage, rhs: TokenUsage) {
        lhs = lhs + rhs
    }

    public static func + (lhs: TokenUsage, rhs: TokenUsage) -> TokenUsage {
        TokenUsage(
            input: lhs.inputTokens + rhs.inputTokens,
            output: lhs.outputTokens + rhs.outputTokens,
            cacheRead: lhs.cacheReadInputTokens + rhs.cacheReadInputTokens,
            cacheCreation: lhs.cacheCreationInputTokens + rhs.cacheCreationInputTokens
        )
    }
}

/// US dollars per million tokens.
public struct ModelPricing: Sendable, Equatable {
    public var input: Double
    public var output: Double
    public var cacheRead: Double
    /// 5-minute cache writes cost 1.25x the input price.
    public var cacheWrite: Double

    public init(input: Double, output: Double, cacheRead: Double, cacheWrite: Double? = nil) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite ?? input * 1.25
    }

    public func cost(of usage: TokenUsage) -> Double {
        let total = Double(usage.inputTokens) * input
            + Double(usage.outputTokens) * output
            + Double(usage.cacheReadInputTokens) * cacheRead
            + Double(usage.cacheCreationInputTokens) * cacheWrite
        return total / 1_000_000
    }
}

/// The models offered in Settings.
public enum ClaudeModel: String, CaseIterable, Sendable, Identifiable {
    case opus55 = "claude-opus-5-5"
    case sonnet55 = "claude-sonnet-5-5"

    public static let defaultModel = ClaudeModel.opus55

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .opus55: "Claude Opus 5.5"
        case .sonnet55: "Claude Sonnet 5.5"
        }
    }

    public var pricing: ModelPricing {
        switch self {
        case .opus55: ModelPricing(input: 4, output: 20, cacheRead: 0.20)
        case .sonnet55: ModelPricing(input: 2, output: 10, cacheRead: 0.20)
        }
    }

    /// Pricing for a model id from a response, which can name a fallback model.
    /// Unknown ids are priced as the most expensive known model, so estimates err high.
    public static func pricing(forModelID id: String?) -> ModelPricing {
        if let id, let model = ClaudeModel(rawValue: id) {
            return model.pricing
        }
        return ClaudeModel.opus55.pricing
    }
}

/// `output_config.effort`. Thinking is always adaptive on these models; effort controls how much.
public enum Effort: String, CaseIterable, Sendable, Identifiable {
    case low
    case medium
    case high
    case xhigh
    case max

    public static let defaultEffort = Effort.high

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .xhigh: "Extra high"
        case .max: "Max"
        }
    }
}
