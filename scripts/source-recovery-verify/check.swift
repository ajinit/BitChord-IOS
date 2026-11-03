import Foundation

private enum Refusal: Error { case bot, unavailable }
private actor Calls {
    var count = 0
    func hit() { count += 1 }
    func value() -> Int { count }
}

@main struct VerifySourceRecovery {
    static func main() async throws {
        let calls = Calls()
        let success = try await PlaybackSourceRecovery.value(of: Task<String, Error> { "audio" }) { _ in
            await calls.hit(); return "recovered"
        }
        precondition(success == "audio")
        let successes = await calls.value()
        precondition(successes == 0)

        let recovered = try await PlaybackSourceRecovery.value(of: Task<String, Error> { throw Refusal.bot }) { error in
            guard case Refusal.bot = error else { fatalError("Original failure lost") }
            await calls.hit(); return "explained"
        }
        precondition(recovered == "explained")
        let recoveries = await calls.value()
        precondition(recoveries == 1)

        do {
            _ = try await PlaybackSourceRecovery.value(of: Task<String, Error> { throw Refusal.bot }) { _ in
                throw Refusal.unavailable
            }
            fatalError("Recovery failure was swallowed")
        } catch Refusal.unavailable { }

        do {
            _ = try await PlaybackSourceRecovery.value(of: Task<String, Error> { throw CancellationError() }) { _ in
                fatalError("Cancellation must never trigger recovery")
            }
            fatalError("Cancellation was swallowed")
        } catch is CancellationError { }

        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await PlaybackSourceRecovery.value(of: Task<String, Error> { throw Refusal.bot }) { _ in
                    fatalError("A cancelled caller must not start recovery")
                }
                fatalError("Caller cancellation was swallowed")
            } catch is CancellationError { }
        }
        try await cancelled.value
        print("5 source recovery scenarios passed")
    }
}
