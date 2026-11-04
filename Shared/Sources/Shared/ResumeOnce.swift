import Foundation

/// Wraps a continuation so it is resumed at most once.
///
/// XPC calls can finish three ways (reply, connection error, timeout), any of which may
/// race the others; only the first one wins.
public final class ResumeOnce<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, any Error>?

    public init(_ continuation: CheckedContinuation<Value, any Error>) {
        self.continuation = continuation
    }

    /// Resumes the continuation if nothing has yet. Returns `true` if this call resumed it.
    @discardableResult
    public func resume(with result: Result<Value, any Error>) -> Bool {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()

        guard let pending else { return false }
        pending.resume(with: result)
        return true
    }
}
