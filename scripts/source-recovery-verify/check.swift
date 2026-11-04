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
        try await checkCatalogueSearch()
        print("5 source recovery scenarios and catalogue routing regressions passed")
    }
}

private func checkCatalogueSearch() async throws {
    func run(_ direct: Bool, _ include: Bool,
             youtube: @escaping () async throws -> [String],
             jio: @escaping () async throws -> [String]) async throws -> [String] {
        try await CatalogueSearch.run(directJio: direct, includeJio: include,
            youtube: youtube, jio: jio, makePage: { $0 }, prepend: { $0 + $1 })
    }
    let direct = try await run(true, true,
        youtube: { fatalError("Direct Jio search called YouTube") }, jio: { ["saavn:one"] })
    precondition(direct == ["saavn:one"])
    let empty = try await run(true, true,
        youtube: { fatalError("Empty Jio catalogue fell back to YouTube") }, jio: { [] })
    precondition(empty.isEmpty)
    do {
        _ = try await run(true, true, youtube: { fatalError("Jio refusal fell back to YouTube") },
            jio: { throw Refusal.unavailable })
        fatalError("Jio refusal hidden")
    } catch Refusal.unavailable { }
    let mixed = try await run(false, true, youtube: { ["video"] }, jio: { ["saavn:one"] })
    precondition(mixed == ["saavn:one", "video"])
    let fallback = try await run(false, true, youtube: { throw Refusal.bot }, jio: { ["saavn:one"] })
    precondition(fallback == ["saavn:one"])
    let disabled = try await run(false, false, youtube: { ["video"] }, jio: { fatalError("Disabled source queried") })
    precondition(disabled == ["video"])
    do {
        _ = try await run(false, true, youtube: { throw CancellationError() },
            jio: { fatalError("Cancelled search started fallback") })
        fatalError("Cancellation hidden")
    } catch is CancellationError { }
    for key in ["saavn:one", "src:provider:one"] {
        let entry = QueueEntry.catalogue(key: key, title: "Song", artist: "Artist")
        precondition(entry.source == key && entry.id == key)
        precondition(entry.videoId == nil, "Provider key leaked into YouTube background requests")
    }
    let youtube = QueueEntry.catalogue(key: "yt:video", title: "Song", artist: "Artist")
    precondition(youtube.source == "yt:video" && youtube.videoId == "video")
}
