// SPDX-License-Identifier: MIT
import CryptoKit
import Foundation

/// The track lyrics are looked up for.
public struct LyricsTrack: Hashable, Sendable {
    public var title: String
    public var artist: String?
    /// Seconds.
    public var duration: TimeInterval

    public init(title: String, artist: String? = nil, duration: TimeInterval) {
        self.title = title
        self.artist = artist
        self.duration = duration
    }
}

/// Synced lyrics for a track from LRCLIB (lrclib.net), kept on disk so a track is asked for once.
/// Everything LRCLIB-specific stays in here: callers ask for a track and get lyrics, nil when there
/// are none, or an error when the service couldn't be reached.
struct LyricsClient: Sendable {
    typealias Fetch = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    /// The service couldn't be asked or answered badly; `reason` is the HTTP status or kind, for the log.
    struct Failure: Error {
        var reason: String
    }

    /// How long "not found" is believed.
    static let notFoundLifetime: TimeInterval = 7 * 24 * 3600
    static let keptFiles = 500
    /// Seconds to wait before each retry.
    static let retryDelays: [TimeInterval] = [1, 3, 8]
    static let maxRetryAfter: TimeInterval = 30

    private let cache: LyricsCache
    private let fetch: Fetch
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private let userAgent: String

    init(
        directory: URL = LyricsCache.defaultDirectory, now: @escaping @Sendable () -> Date = { .now },
        fetch: @escaping Fetch = Self.live,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = {
            try await Task.sleep(for: .seconds($0))
        },
        version: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    ) {
        cache = LyricsCache(directory: directory, now: now)
        self.fetch = fetch
        self.sleep = sleep
        userAgent = "Topdeck/\(version) (https://github.com/fredcu/Topdeck)"
    }

    /// No cookies and no cache on disk: a request carries the track and nothing else.
    private static let session = URLSession(configuration: .ephemeral)

    static let live: Fetch = { request in
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }

    /// The lyrics for `track`, nil when LRCLIB has none worth showing. Throws when it couldn't be
    /// asked, which isn't remembered, so the next lookup tries again.
    func lyrics(for track: LyricsTrack) async throws -> SyncedLyrics? {
        // Without an artist the best match would rest on the title alone.
        guard let artist = track.artist, !artist.isEmpty, track.duration > 0 else { return nil }
        let key = LyricsCache.key(for: track)
        switch cache.read(key) {
        case .found(let lrc): if let lyrics = SyncedLyrics(lrc: lrc) { return lyrics }
        case .notFound: return nil
        case nil: break
        }
        var retries = 0
        let found = try await find(track, artist: artist, retries: &retries)
        cache.write(key, lrc: found.map(\.lrc))
        return found.map(\.lyrics)
    }

    // MARK: Lookup

    /// A 200 that isn't the JSON we expect is a failure, not "no lyrics".
    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        guard let value = try? JSONDecoder().decode(type, from: data) else { throw Failure(reason: "bad response") }
        return value
    }

    private func find(_ track: LyricsTrack, artist: String, retries: inout Int) async throws
        -> (lrc: String, lyrics: SyncedLyrics)?
    {
        var query = [
            URLQueryItem(name: "track_name", value: track.title), URLQueryItem(name: "artist_name", value: artist),
        ]
        // No album_name: Apple's album names carry suffixes such as "- EP" that LRCLIB doesn't have.
        query.append(URLQueryItem(name: "duration", value: String(Int(track.duration.rounded()))))
        if let data = try await get("get", query, &retries) {
            if let found = try decode(Record.self, data).synced { return found }
        }
        for title in [track.title, Self.stripped(track.title)] {
            guard let title else { continue }
            let query = [
                URLQueryItem(name: "track_name", value: title), URLQueryItem(name: "artist_name", value: artist),
            ]
            if let data = try await get("search", query, &retries),
                let best = Self.best(try decode([Record].self, data), for: track)
            {
                return best
            }
        }
        return nil
    }

    /// The body of a 200, nil for a 404. Retries 503, 429 and network errors, three times per track in all.
    private func get(_ path: String, _ query: [URLQueryItem], _ retries: inout Int) async throws -> Data? {
        var components = URLComponents(string: "https://lrclib.net/api/\(path)")!
        components.queryItems = query
        var request = URLRequest(url: components.url!, timeoutInterval: 10)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        while true {
            var wait: TimeInterval = 0
            var reason = "HTTP 503"
            do {
                let (data, response) = try await fetch(request)
                switch response.statusCode {
                case 200: return data
                case 404: return nil
                case 429:
                    wait = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init) ?? 0
                    reason = "HTTP 429"
                case 503: break
                default: throw Failure(reason: "HTTP \(response.statusCode)")
                }
            } catch let failure as Failure {
                throw failure
            } catch {
                try Task.checkCancellation()  // a network error, which is retried like a 503
                reason = "network \((error as? URLError)?.code.rawValue ?? 0)"
            }
            guard retries < Self.retryDelays.count else { throw Failure(reason: reason) }
            try await sleep(min(max(wait, Self.retryDelays[retries]), Self.maxRetryAfter))
            retries += 1
        }
    }

    // MARK: Matching

    /// What LRCLIB returns for a track, in the fields we use.
    struct Record: Decodable {
        var trackName: String?
        var artistName: String?
        var duration: Double?
        var instrumental: Bool?
        var syncedLyrics: String?

        var synced: (lrc: String, lyrics: SyncedLyrics)? {
            guard instrumental != true, let lrc = syncedLyrics, let lyrics = SyncedLyrics(lrc: lrc) else { return nil }
            return (lrc, lyrics)
        }
    }

    /// The result that is this track and has synced lyrics: titles equal or one inside the other,
    /// within 2 seconds, and unless the titles are equal the artists too. An equal title and artist wins, then the closest length. Nil beats the wrong song.
    static func best(_ records: [Record], for track: LyricsTrack) -> (lrc: String, lyrics: SyncedLyrics)? {
        let title = normalized(track.title)
        let artist = normalized(track.artist ?? "")
        guard !title.isEmpty else { return nil }
        var best: (rank: Int, gap: Double, found: (lrc: String, lyrics: SyncedLyrics))?
        for record in records {
            guard let found = record.synced, let duration = record.duration,
                abs(duration - track.duration) <= 2
            else { continue }
            let other = normalized(record.trackName ?? "")
            guard !other.isEmpty, other.contains(title) || title.contains(other) else { continue }
            let otherArtist = normalized(record.artistName ?? "")
            let sameArtist = otherArtist == artist
            // A title that only contains the other ("Love" in "Love Story") must come with the artist.
            if other != title, !sameArtist,
                otherArtist.isEmpty || !(otherArtist.contains(artist) || artist.contains(otherArtist))
            {
                continue
            }
            let rank = other == title && sameArtist ? 0 : 1
            let gap = abs(duration - track.duration)
            if best.map({ (rank, gap) < ($0.rank, $0.gap) }) ?? true { best = (rank, gap, found) }
        }
        return best?.found
    }

    /// Lowercased, without accents, trimmed, and in Simplified Chinese.
    static func normalized(_ text: String) -> String {
        let simplified = text.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? text
        return simplified.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The title without a trailing "(...)", "[...]" or " - Something", nil when there's none to remove.
    static func stripped(_ title: String) -> String? {
        var result = title.trimmingCharacters(in: .whitespaces)
        while true {
            let before = result
            if let last = result.last, let open = Self.pairs[last], let start = result.lastIndex(of: open) {
                result = String(result[..<start]).trimmingCharacters(in: .whitespaces)
            } else if let dash = result.range(of: " - ", options: .backwards) {
                result = String(result[..<dash.lowerBound]).trimmingCharacters(in: .whitespaces)
            }
            if result == before { break }
        }
        return result.isEmpty || result == title.trimmingCharacters(in: .whitespaces) ? nil : result
    }

    private static let pairs: [Character: Character] = [")": "(", "]": "[", "）": "（", "】": "【"]
}

/// One JSON file per track in the Caches folder.
struct LyricsCache: Sendable {
    enum Entry: Equatable {
        case found(String)
        case notFound
    }

    private struct File: Codable {
        var lrc: String?
        var expires: Date?
    }

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "net.icuai.topdeck/lyrics", directoryHint: .isDirectory)
    }

    let directory: URL
    let now: @Sendable () -> Date

    /// A SHA-256 of the normalized title and artist and the length in whole seconds.
    static func key(for track: LyricsTrack) -> String {
        let text = [
            LyricsClient.normalized(track.title), LyricsClient.normalized(track.artist ?? ""),
            String(Int(track.duration.rounded())),
        ].joined(separator: "\u{1F}")
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func read(_ key: String) -> Entry? {
        guard let data = try? Data(contentsOf: url(key)), let file = try? JSONDecoder().decode(File.self, from: data)
        else { return nil }
        if let lrc = file.lrc { return .found(lrc) }
        guard let expires = file.expires, expires > now() else { return nil }
        return .notFound
    }

    /// Lyrics are kept for good, "not found" for a week. A failed write only means asking again.
    func write(_ key: String, lrc: String?) {
        let file = File(lrc: lrc, expires: lrc == nil ? now().addingTimeInterval(LyricsClient.notFoundLifetime) : nil)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(file).write(to: url(key), options: .atomic)
        } catch {
            return
        }
        prune()
    }

    private func url(_ key: String) -> URL { directory.appending(path: "\(key).json") }

    /// Keeps the newest files.
    private func prune() {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard
            let files = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: keys, options: .skipsHiddenFiles),
            files.count > LyricsClient.keptFiles
        else { return }
        let dated = files.map {
            ($0, (try? $0.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast)
        }
        for (file, _) in dated.sorted(by: { $0.1 > $1.1 }).dropFirst(LyricsClient.keptFiles) {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
