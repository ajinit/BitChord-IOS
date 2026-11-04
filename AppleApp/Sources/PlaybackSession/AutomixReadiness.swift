import Foundation

enum AutomixReadiness {
    static func canPrepare(currentID: String?, loadedID: String?, source: String?, transportReady: Bool) -> Bool {
        guard transportReady, let currentID, !currentID.isEmpty,
              loadedID == currentID, let source, !source.isEmpty else { return false }
        return true
    }
}

/// An explicit user action opens the selected recording in the official service.
/// Never accept a provider key or an arbitrary URL as a YouTube video ID.
enum YouTubePlaybackLink {
    static func url(source: String) -> URL? {
        guard source.hasPrefix("yt:") else { return nil }
        let id = String(source.dropFirst(3))
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        guard id.count == 11, id.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        var url = URLComponents(string: "https://music.youtube.com/watch")!
        url.queryItems = [URLQueryItem(name: "v", value: id)]
        return url.url
    }
}
