import Foundation

/// Every source-race outcome must preserve the same recovery and cancellation policy.
enum PlaybackSourceRecovery {
    static func value<Value: Sendable>(
        of task: Task<Value, Error>,
        recover: (Error) async throws -> Value
    ) async throws -> Value {
        do {
            let value = try await task.value
            try Task.checkCancellation()
            return value
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            let value = try await recover(error)
            try Task.checkCancellation()
            return value
        }
    }
}
