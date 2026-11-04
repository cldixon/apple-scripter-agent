import Foundation
@testable import Shared
import Testing

struct ResumeOnceTests {
    private struct SampleError: Error {}

    @Test func onlyFirstResumeWins() async throws {
        let value: Int = try await withCheckedThrowingContinuation { continuation in
            let once = ResumeOnce(continuation)
            #expect(once.resume(with: .success(1)))
            #expect(!once.resume(with: .success(2)))
            #expect(!once.resume(with: .failure(SampleError())))
        }
        #expect(value == 1)
    }

    @Test func firstFailureWins() async {
        await #expect(throws: SampleError.self) {
            let _: Int = try await withCheckedThrowingContinuation { continuation in
                let once = ResumeOnce(continuation)
                once.resume(with: .failure(SampleError()))
                once.resume(with: .success(1))
            }
        }
    }

    @Test func concurrentResumesResumeExactlyOnce() async throws {
        let winners: Int = try await withCheckedThrowingContinuation { continuation in
            let once = ResumeOnce(continuation)
            DispatchQueue.concurrentPerform(iterations: 64) { index in
                once.resume(with: .success(index))
            }
        }
        #expect((0..<64).contains(winners))
    }
}
