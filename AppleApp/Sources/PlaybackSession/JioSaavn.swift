import Foundation
import BitChordShared

/// JioSaavn catalogue search. Playback uses the shared provider resolver.
enum JioSaavn {
    private static let base = "https://www.jiosaavn.com/api.php"
    private static let ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36"

    static func search(_ query: String) async -> [SearchHitDTO] {
        (try? await searchChecked(query)) ?? []
    }

    static func searchChecked(_ query: String) async throws -> [SearchHitDTO] {
        guard enabled else { throw SearchFailure.disabled }
        try Task.checkCancellation()
        var comps = URLComponents(string: base)!
        comps.queryItems = [
            .init(name: "__call", value: "search.getResults"),
            .init(name: "_format", value: "json"),
            .init(name: "_marker", value: "0"),
            .init(name: "api_version", value: "4"),
            .init(name: "ctx", value: "android"),
            .init(name: "q", value: query),
            .init(name: "p", value: "1"),
            .init(name: "n", value: "8"),
        ]
        guard let url = comps.url else { return [] }
        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: req)
        try Task.checkCancellation()
        guard enabled else { throw SearchFailure.disabled }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw SearchFailure.unavailable }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = obj["results"] as? [[String: Any]] else { throw SearchFailure.unavailable }
        return results.compactMap { raw in
            guard let id = raw["id"] as? String, let title = raw["title"] as? String else { return nil }
            let info = raw["more_info"] as? [String: Any]
            let artistNames = ((info?["artistMap"] as? [String: Any])?["primary_artists"] as? [[String: Any]]) ?? []
            let artists = artistNames.compactMap { $0["name"] as? String }.joined(separator: ", ")
            let image: String?
            if let rawImage = raw["image"] as? String {
                image = rawImage
                    .replacingOccurrences(of: "150x150", with: "500x500")
                    .replacingOccurrences(of: "http://", with: "https://")
            } else {
                image = nil
            }
            let seconds = Int(info?["duration"] as? String ?? "") ?? 0
            let dur = seconds > 0 ? String(format: "%d:%02d", seconds / 60, seconds % 60) : nil
            return SearchHitDTO(
                kind: "track",
                videoId: "saavn:\(id)",
                title: title,
                subtitle: artists,
                thumbnailUrl: image,
                durationText: dur,
                albumName: info?["album"] as? String,
                browseId: nil,
                browseType: nil,
                artistId: nil,
                albumId: nil,
                isVideo: false,
                setVideoId: nil
            )
        }
    }

    private enum SearchFailure: LocalizedError {
        case disabled, unavailable
        var errorDescription: String? {
            switch self {
            case .disabled: return "Enable JioSaavn in Settings → Sources."
            case .unavailable: return "JioSaavn did not return a search response. Please try again later."
            }
        }
    }

    static var enabled: Bool { SourceResolverBridge.shared.jioSaavnEnabled() }

    static func streamURL(for trackId: String, downloadQuality: String? = nil) async -> (url: String, kbps: Int)? {
        let stream: SourceSubstitution.Stream? = await withCheckedContinuation { continuation in
            SourceResolverBridge.shared.resolveJioSaavnTrack(
                trackId: trackId,
                downloadQuality: downloadQuality,
                callback: JioStreamAdapter { json, _ in
                    continuation.resume(returning: json.flatMap(SourceSubstitution.decode))
                }
            )
        }
        guard !Task.isCancelled, let stream else { return nil }
        return (stream.url, stream.kbps ?? 0)
    }

    /// Upstream `matchAndStream` for this catalogue: search, score, then open
    /// the best row that is the same recording. Nil means fall through to YouTube.
    static func matchedStream(
        for entry: QueueEntry, playingDurationSec: Int? = nil
    ) async -> (url: String, kbps: Int, durationSec: Int?)? {
        let target = TrackMatch.Target(
            title: entry.title,
            artist: entry.artist,
            durationSec: playingDurationSec ?? {
                let s = Int(entry.durationSeconds.rounded())
                return s > 0 ? s : nil
            }()
        )
        if target.title.trimmingCharacters(in: .whitespaces).isEmpty { return nil }
        let query = [target.title, target.artist].filter { !$0.isEmpty }.joined(separator: " ")
        let hits = await search(query)
        let candidates = hits.map {
            TrackMatch.Candidate(title: $0.title, artist: $0.subtitle ?? "", durationText: $0.durationText)
        }
        guard let index = TrackMatch.bestIndex(in: candidates, target: target),
              let sid = hits[index].videoId else { return nil }
        guard let stream = await streamURL(for: sid) else { return nil }
        return (stream.url, stream.kbps, TrackMatch.seconds(of: hits[index].durationText))
    }

}

private final class JioStreamAdapter: SourceResolverBridgeStreamCallback {
    private let handler: (String?, String?) -> Void
    init(_ handler: @escaping (String?, String?) -> Void) { self.handler = handler }
    func onResult(json: String?, message: String?) { handler(json, message) }
}
