import Foundation

/// Endpoints, headers and versions for the Claude API, used over raw HTTP.
public enum ClaudeAPI {
    /// API version `2026-10-21`: sampling parameters are gone, so requests never send
    /// `temperature`, `top_p` or `top_k`.
    public static let version = "2026-10-21"
    /// Beta for `"fallbacks": "default"`: a request a safety classifier declines is re-run on
    /// Anthropic's recommended fallback model, server side, in the same call.
    public static let serverSideFallbackBeta = "server-side-fallback-2026-07-01"
    public static let host = "api.anthropic.com"

    public static func url(path: String, query: [URLQueryItem] = []) throws -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = path
        if !query.isEmpty {
            components.queryItems = query
        }
        guard let url = components.url else { throw ClaudeAPIError.invalidResponse }
        return url
    }

    public static func messagesURL() throws -> URL {
        try url(path: "/v1/messages")
    }

    /// `GET /v1/models?limit=1`: a free request that checks an API key.
    public static func modelsURL() throws -> URL {
        try url(path: "/v1/models", query: [URLQueryItem(name: "limit", value: "1")])
    }

    /// Request headers. The key goes only into `x-api-key`; never log these.
    public static func headers(apiKey: String, betas: [String] = []) -> [String: String] {
        var headers = [
            "x-api-key": apiKey,
            "anthropic-version": version,
            "content-type": "application/json",
            "accept": "application/json"
        ]
        if !betas.isEmpty {
            headers["anthropic-beta"] = betas.joined(separator: ",")
        }
        return headers
    }
}

public enum ClaudeAPIError: Error, Sendable, Equatable, LocalizedError {
    /// A non-2xx response. `type` and `message` come from the API's error body.
    case http(status: Int, type: String?, message: String)
    /// An `error` event in the middle of a stream (for example `overloaded_error`).
    case stream(type: String, message: String)
    /// The stream closed before `message_stop`.
    case incompleteStream
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .http(let status, let type, let message):
            Self.describe(status: status, type: type, message: message)
        case .stream(let type, let message):
            "Claude stopped with \(type): \(message)"
        case .incompleteStream:
            "The connection to Claude closed before the reply finished."
        case .invalidResponse:
            "Claude's API returned a response this app could not read."
        }
    }

    /// Reads `{"type": "error", "error": {"type": ..., "message": ...}}`.
    public static func fromHTTP(status: Int, body: Data) -> ClaudeAPIError {
        let json = try? JSONValue.parse(body)
        let type = json?["error"]?["type"]?.stringValue
        let message = json?["error"]?["message"]?.stringValue
            ?? HTTPURLResponse.localizedString(forStatusCode: status)
        return .http(status: status, type: type, message: message)
    }

    private static func describe(status: Int, type: String?, message: String) -> String {
        switch status {
        case 401:
            "The API key was rejected (\(message)). Check it in Settings."
        case 403:
            "This API key is not allowed to do that (\(message))."
        case 429:
            "Rate limited by the Claude API (\(message)). Try again shortly."
        case 529:
            "The Claude API is overloaded (\(message)). Try again shortly."
        default:
            "Claude API error \(status)\(type.map { " \($0)" } ?? ""): \(message)"
        }
    }
}
