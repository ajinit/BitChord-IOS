import Foundation

/// Explicit catalogue search must never invoke the YouTube resolver or search.
enum CatalogueSearch {
    static func run<Hit, Page>(
        directJio: Bool, includeJio: Bool,
        youtube: () async throws -> Page,
        jio: () async throws -> [Hit],
        makePage: ([Hit]) -> Page,
        prepend: ([Hit], Page) -> Page
    ) async throws -> Page {
        try Task.checkCancellation()
        if directJio { return makePage(try await jio()) }
        let page: Page
        do { page = try await youtube() }
        catch {
            try Task.checkCancellation()
            if error is CancellationError { throw error }
            guard includeJio else { throw error }
            let extra = (try? await jio()) ?? []
            try Task.checkCancellation()
            guard !extra.isEmpty else { throw error }
            return makePage(extra)
        }
        guard includeJio else { return page }
        let extra = (try? await jio()) ?? []
        try Task.checkCancellation()
        return prepend(extra, page)
    }
}
