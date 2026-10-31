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
    /// The storefront the track's own name is searched in, lowercased ("au").
    private let country: String

    init(
        directory: URL = LyricsCache.defaultDirectory, now: @escaping @Sendable () -> Date = { .now },
        fetch: @escaping Fetch = Self.live,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = {
            try await Task.sleep(for: .seconds($0))
        },
        country: String = Locale.current.region?.identifier.lowercased() ?? "us",
        version: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    ) {
        cache = LyricsCache(directory: directory, now: now)
        self.fetch = fetch
        self.sleep = sleep
        self.country = country.isEmpty ? "us" : country
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

    typealias Found = (lrc: String, lyrics: SyncedLyrics)

    /// LRCLIB under the name the player gives; failing that, under the names Apple's catalog has for
    /// the same song in other storefronts, since a Chinese song arrives as "Sunny Day" in Australia
    /// and LRCLIB holds it under its Chinese title.
    private func find(_ track: LyricsTrack, artist: String, retries: inout Int) async throws -> Found? {
        if let found = try await lrclib(track, artist: artist, retries: &retries) { return found }
        return try await localized(track, artist: artist, retries: &retries)
    }

    private func lrclib(_ track: LyricsTrack, artist: String, retries: inout Int) async throws -> Found? {
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

    // MARK: Local names

    /// How many other names of a song are tried at LRCLIB.
    static let localNameLimit = 3
    /// Storefronts asked for a song's own name, in order.
    static let storefronts = ["hk", "jp", "cn", "tw"]

    struct ITunesResult: Decodable {
        var trackId: Int?
        var trackName: String?
        var artistName: String?
        var trackTimeMillis: Double?
    }

    private struct ITunesResponse: Decodable {
        var results: [ITunesResult]
    }

    private func localized(_ track: LyricsTrack, artist: String, retries: inout Int) async throws -> Found? {
        let search = [
            URLQueryItem(name: "term", value: "\(track.title) \(artist)"),
            URLQueryItem(name: "country", value: country),
            URLQueryItem(name: "entity", value: "song"), URLQueryItem(name: "limit", value: "10"),
        ]
        guard let data = try await get("search", search, &retries, base: Self.itunes),
            let id = Self.itunesMatch(try decode(ITunesResponse.self, data).results, for: track)?.trackId
        else { return nil }
        var tried: Set<String> = [Self.pairKey(track.title, artist)]
        for storefront in Self.storefronts {
            let lookup = [
                URLQueryItem(name: "id", value: String(id)), URLQueryItem(name: "country", value: storefront),
            ]
            guard let data = try await get("lookup", lookup, &retries, base: Self.itunes),
                let named = try decode(ITunesResponse.self, data).results.first,
                let title = named.trackName, let name = named.artistName,
                tried.insert(Self.pairKey(title, name)).inserted
            else { continue }
            let other = LyricsTrack(title: title, artist: name, duration: track.duration)
            if let found = try await lrclib(other, artist: name, retries: &retries) { return found }
            // LRCLIB matches the text it's sent, and Hong Kong writes Traditional where it often holds Simplified.
            let (simpleTitle, simpleName) = (Self.simplified(title), Self.simplified(name))
            if simpleTitle != title || simpleName != name {
                let simple = LyricsTrack(title: simpleTitle, artist: simpleName, duration: track.duration)
                if let found = try await lrclib(simple, artist: simpleName, retries: &retries) { return found }
            }
            if tried.count > Self.localNameLimit { break }  // the original and three others
        }
        return nil
    }

    private static let itunes = "https://itunes.apple.com/"

    private static func simplified(_ text: String) -> String {
        text.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? text
    }

    private static func pairKey(_ title: String, _ artist: String) -> String {
        normalized(title) + "\u{1F}" + normalized(artist)
    }

    /// The catalog entry that is this track: equal title and artist, else an equal title and one artist
    /// inside the other, and within 2 seconds. The closest length wins.
    static func itunesMatch(_ results: [ITunesResult], for track: LyricsTrack) -> ITunesResult? {
        let title = normalized(track.title)
        let artist = normalized(track.artist ?? "")
        var best: (rank: Int, gap: Double, result: ITunesResult)?
        for result in results {
            guard let name = result.trackName, normalized(name) == title, result.trackId != nil,
                let millis = result.trackTimeMillis, abs(millis / 1000 - track.duration) <= 2
            else { continue }
            let other = normalized(result.artistName ?? "")
            guard !other.isEmpty, !artist.isEmpty else { continue }
            let rank = other == artist ? 0 : (other.contains(artist) || artist.contains(other) ? 1 : 2)
            guard rank < 2 else { continue }
            let gap = abs(millis / 1000 - track.duration)
            if best.map({ (rank, gap) < ($0.rank, $0.gap) }) ?? true { best = (rank, gap, result) }
        }
        return best?.result
    }

    /// The body of a 200, nil for a 404. Retries 503, 429 and network errors, three times per track in all.
    private func get(
        _ path: String, _ query: [URLQueryItem], _ retries: inout Int, base: String = "https://lrclib.net/api/"
    ) async throws -> Data? {
        var components = URLComponents(string: base + path)!
        components.queryItems = query
        var request = URLRequest(url: components.url!, timeoutInterval: 10)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        while true {
            var wait: TimeInterval = 0
            var reason = ""
            do {
                let (data, response) = try await fetch(request)
                switch response.statusCode {
                case 200: return data
                case 404: return nil
                case 429:
                    wait = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init) ?? 0
                    reason = "HTTP 429"
                case 502, 503, 504: reason = "HTTP \(response.statusCode)"
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
        simplified(text).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
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
        // "v2": entries from before names were tried in other storefronts said "not found" too early.
        let text = [
            "v2", LyricsClient.normalized(track.title), LyricsClient.normalized(track.artist ?? ""),
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
