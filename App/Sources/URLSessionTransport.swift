import AgentCore
import Foundation

/// Sends Messages requests over URLSession and yields the streamed response line by line.
/// It holds the API key only for the request headers; the key never goes into a log or error.
struct URLSessionTransport: MessagesTransport {
    let apiKey: String
    var session: URLSession = .shared

    func lines(for request: MessagesRequest) -> AsyncThrowingStream<String, any Error> {
        let urlSession = session
        let key = apiKey
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let urlRequest = try Self.urlRequest(for: request, apiKey: key)
                    let (bytes, response) = try await urlSession.bytes(for: urlRequest)
                    try await Self.checkStatus(of: response, bytes: bytes)
                    var buffer = LineBuffer()
                    for try await byte in bytes {
                        if let line = buffer.append(byte) {
                            continuation.yield(line)
                        }
                    }
                    if let line = buffer.finish() {
                        continuation.yield(line)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func urlRequest(for request: MessagesRequest, apiKey: String) throws -> URLRequest {
        var urlRequest = URLRequest(url: try ClaudeAPI.messagesURL())
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = request.body
        // Long agentic turns can stream for minutes; this is the gap allowed between bytes.
        urlRequest.timeoutInterval = 300
        for (name, value) in ClaudeAPI.headers(apiKey: apiKey, betas: request.betas) {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        return urlRequest
    }

    /// Throws the API's error for a non-2xx response, after reading its JSON body.
    private static func checkStatus(of response: URLResponse, bytes: URLSession.AsyncBytes) async throws {
        guard let http = response as? HTTPURLResponse else { throw ClaudeAPIError.invalidResponse }
        guard !(200..<300).contains(http.statusCode) else { return }
        var body = Data()
        for try await byte in bytes {
            body.append(byte)
        }
        throw ClaudeAPIError.fromHTTP(status: http.statusCode, body: body)
    }
}

/// Checks an API key with `GET /v1/models`, which costs nothing.
enum APIKeyValidator {
    static func validate(_ apiKey: String) async throws {
        var request = URLRequest(url: try ClaudeAPI.modelsURL())
        request.timeoutInterval = 20
        for (name, value) in ClaudeAPI.headers(apiKey: apiKey) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClaudeAPIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw ClaudeAPIError.fromHTTP(status: http.statusCode, body: data)
        }
    }
}
