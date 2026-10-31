// SPDX-License-Identifier: MIT
import Foundation
import Testing

@testable import TopdeckFeatures

/// Every lyric in here is made up.
struct SyncedLyricsParsingTests {
    private func texts(_ lyrics: SyncedLyrics) -> [String] { lyrics.lines.map(\.text) }

    @Test func everyTimestampFormIsReadAsADecimal() throws {
        let lyrics = try #require(
            SyncedLyrics(
                lrc: """
                    [00:01]a
                    [00:02.5]b
                    [00:03.25]c
                    [00:04.125]d
                    [01:05.5]e
                    """))
        #expect(lyrics.lines.map(\.time) == [1, 2.5, 3.25, 4.125, 65.5])
    }

    @Test func severalTimestampsOnALineEachBecomeAnEntryInOrder() throws {
        let lyrics = try #require(SyncedLyrics(lrc: "[00:30.00][00:10.00] refrain\n[00:20.00]verse"))
        #expect(lyrics.lines.map(\.time) == [10, 20, 30])
        #expect(texts(lyrics) == ["refrain", "verse", "refrain"])
    }

    @Test func tagsAreSkippedAndOffsetIsApplied() throws {
        let lyrics = try #require(
            SyncedLyrics(lrc: "[ar:Someone]\n[ti:Made up]\n[offset:+500]\n[00:10.00]first\n[00:00.20]early"))
        #expect(lyrics.lines.map(\.time) == [0, 9.5], "a positive offset is sooner, and never before zero")
        #expect(texts(lyrics) == ["early", "first"])
        let later = try #require(SyncedLyrics(lrc: "[offset:-1500]\n[00:10.00]first"))
        #expect(later.lines.map(\.time) == [11.5])
    }

    @Test func equalTimesKeepTheirOrder() throws {
        let lyrics = try #require(SyncedLyrics(lrc: "[00:05.00]one\n[00:05.00]two\n[00:05.00]three"))
        #expect(texts(lyrics) == ["one", "two", "three"])
    }

    @Test func aTimestampWithNoTextIsAGap() throws {
        let lyrics = try #require(SyncedLyrics(lrc: "[00:05.00]one\n[00:08.00]\n[00:12.00]two"))
        #expect(lyrics.lines.count == 3 && lyrics.lines[1].text.isEmpty)
    }

    @Test(arguments: ["", "no stamps here", "[ar:Someone]", "[00:05.00]\n[00:09.00]  ", "[xx:yy]word", "[1:2:3]word"])
    func textWithoutWordsIsNoLyrics(lrc: String) {
        #expect(SyncedLyrics(lrc: lrc) == nil)
    }

    @Test func crlfAndBlankLinesAreFine() throws {
        let lyrics = try #require(SyncedLyrics(lrc: "[00:01.00]a\r\n\r\n[00:02.00]b\r\n"))
        #expect(texts(lyrics) == ["a", "b"])
    }
}

struct SyncedLyricsCursorTests {
    private let lyrics = SyncedLyrics(
        lines: [
            .init(time: 10, text: "one"), .init(time: 20, text: "two"), .init(time: 25, text: ""),
            .init(time: 40, text: "three"),
        ])

    @Test func beforeTheFirstLineThereIsOnlyANext() {
        #expect(lyrics.cursor(at: 0) == .init(current: nil, next: "one"))
        #expect(lyrics.cursor(at: 9.99) == .init(current: nil, next: "one"))
    }

    @Test func aLineStartsExactlyAtItsTime() {
        #expect(lyrics.cursor(at: 10) == .init(current: "one", next: "two"))
        #expect(lyrics.cursor(at: 22) == .init(current: "two", next: "three"))
    }

    @Test func inAGapThereIsNoCurrentAndNextSkipsToWords() {
        #expect(lyrics.cursor(at: 25) == .init(current: nil, next: "three"))
        #expect(lyrics.cursor(at: 39.9) == .init(current: nil, next: "three"))
    }

    @Test func afterTheLastLineItStaysAndHasNoNext() {
        #expect(lyrics.cursor(at: 40) == .init(current: "three", next: nil))
        #expect(lyrics.cursor(at: 9999) == .init(current: "three", next: nil))
    }
}

struct LyricsMatchingTests {
    private func record(
        _ title: String, _ artist: String = "Artist", duration: Double? = 200, synced: String? = "[00:01.00]made up",
        instrumental: Bool = false
    ) -> LyricsClient.Record {
        LyricsClient.Record(
            trackName: title, artistName: artist, duration: duration, instrumental: instrumental, syncedLyrics: synced)
    }

    private let track = LyricsTrack(title: "Made Up", artist: "Artist", duration: 200)

    private func best(_ records: [LyricsClient.Record], for track: LyricsTrack? = nil) -> String? {
        LyricsClient.best(records, for: track ?? self.track)?.lrc
    }

    @Test func aDurationThreeSecondsOffIsRejectedAndTwoIsKept() {
        #expect(best([record("Made Up", duration: 203)]) == nil)
        #expect(best([record("Made Up", duration: 197.5)]) == nil)
        #expect(best([record("Made Up", duration: 202)]) != nil)
    }

    @Test func noDurationIsRejected() {
        #expect(best([record("Made Up", duration: nil)]) == nil)
    }

    @Test func instrumentalAndUnsyncedAreRejected() {
        #expect(best([record("Made Up", instrumental: true)]) == nil)
        #expect(best([record("Made Up", synced: nil)]) == nil)
        #expect(best([record("Made Up", synced: "")]) == nil)
        #expect(best([record("Made Up", synced: "[00:01.00]")]) == nil)
    }

    @Test func titlesMustMatchOrContainEachOther() {
        #expect(best([record("Something Else")]) == nil)
        #expect(best([record("Made Up (Remastered)")]) != nil)
        #expect(best([record("Made")]) != nil)
        #expect(best([record("")]) == nil)
    }

    @Test func aContainedTitleNeedsTheArtistToo() {
        let love = LyricsTrack(title: "Love", artist: "Ana Vale", duration: 200)
        #expect(best([record("Love Story", "Someone Else")], for: love) == nil)
        #expect(best([record("Love Story", "Ana Vale")], for: love) != nil)
        #expect(best([record("Love Story", "Ana Vale & Friends")], for: love) != nil)
        #expect(best([record("Love Story", "")], for: love) == nil)
    }

    @Test func anEqualTitleByAnotherArtistIsStillAccepted() {
        #expect(best([record("Made Up", "Someone Else")]) != nil)
    }

    @Test func caseAndAccentsDontMatter() {
        #expect(best([record("MADE ÚP")]) != nil)
    }

    @Test func simplifiedAndTraditionalChineseMatch() {
        let simplified = LyricsTrack(title: "爱的故事", artist: "歌手", duration: 200)
        #expect(best([record("愛的故事", "歌手")], for: simplified) != nil)
        let traditional = LyricsTrack(title: "愛的故事", artist: "歌手", duration: 200)
        #expect(best([record("爱的故事", "歌手")], for: traditional) != nil)
    }

    @Test func anEqualTitleAndArtistBeatsACloserLength() {
        let covers = [
            record("Made Up", "Other", duration: 200, synced: "[00:01.00]cover"),
            record("Made Up", "Artist", duration: 201.5, synced: "[00:01.00]original"),
        ]
        #expect(best(covers) == "[00:01.00]original")
    }

    @Test func otherwiseTheClosestLengthWins() {
        let both = [
            record("Made Up", "Other", duration: 201.5, synced: "[00:01.00]far"),
            record("Made Up", "Another", duration: 200.5, synced: "[00:01.00]near"),
        ]
        #expect(best(both) == "[00:01.00]near")
    }

    @Test func strippingTheSuffix() {
        #expect(LyricsClient.stripped("Made Up (Live at Somewhere)") == "Made Up")
        #expect(LyricsClient.stripped("Made Up - 2011 Remaster") == "Made Up")
        #expect(LyricsClient.stripped("Made Up [Deluxe] - Single Version") == "Made Up")
        #expect(LyricsClient.stripped("Made Up") == nil)
        #expect(LyricsClient.stripped("(Only Parens)") == nil)
    }
}

/// The client against a scripted network, with no waiting and a cache folder of its own.
struct LyricsClientTests {
    /// A scripted answer.
    struct Reply {
        var status = 200
        var body = Data("{}".utf8)
        var headers: [String: String] = [:]
        var fails = false

        static func lyrics(_ lrc: String, title: String = "Made Up", duration: Double = 200) -> Reply {
            Reply(
                body: Self.json(["trackName": title, "artistName": "Artist", "duration": duration, "syncedLyrics": lrc])
            )
        }
        static func list(_ records: [[String: Any]]) -> Reply { Reply(body: json(records)) }
        static func status(_ code: Int, headers: [String: String] = [:]) -> Reply {
            Reply(status: code, headers: headers)
        }
        static let offline = Reply(fails: true)

        private static func json(_ value: Any) -> Data {
            (try? JSONSerialization.data(withJSONObject: value)) ?? Data()
        }
    }

    /// Hands out replies in order and keeps what was asked and how long it waited.
    final class Network: @unchecked Sendable {
        private let lock = NSLock()
        private var replies: [Reply]
        private(set) var requests: [URLRequest] = []
        private(set) var waits: [TimeInterval] = []

        init(_ replies: [Reply]) { self.replies = replies }

        var paths: [String] { requests.map { $0.url!.path } }

        func fetch(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
            lock.lock()
            defer { lock.unlock() }
            requests.append(request)
            let reply = replies.isEmpty ? Reply.status(500) : replies.removeFirst()
            if reply.fails { throw URLError(.notConnectedToInternet) }
            let response = HTTPURLResponse(
                url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: reply.headers)!
            return (reply.body, response)
        }

        func wait(_ seconds: TimeInterval) {
            lock.lock()
            waits.append(seconds)
            lock.unlock()
        }
    }

    private let track = LyricsTrack(title: "Made Up", artist: "Artist", duration: 200.4)
    private let lrc = "[00:01.00]made up line\n[00:05.00]another made up line"

    private func makeClient(
        _ network: Network, directory: URL? = nil, now: @escaping @Sendable () -> Date = { .now }
    ) -> (LyricsClient, URL) {
        let directory = directory ?? FileManager.default.temporaryDirectory.appending(path: "Lyrics-\(UUID())")
        let client = LyricsClient(
            directory: directory, now: now, fetch: { try network.fetch($0) }, sleep: { network.wait($0) },
            version: "1.2.3")
        return (client, directory)
    }

    private func files(_ directory: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
    }

    @Test func getHasTheTrackAndTheFieldsLRCLIBWants() async throws {
        let network = Network([.lyrics(lrc)])
        let (client, directory) = makeClient(network)
        defer { try? FileManager.default.removeItem(at: directory) }
        let lyrics = try await client.lyrics(for: track)
        #expect(lyrics?.lines.count == 2)
        let request = try #require(network.requests.first)
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(request.url?.host == "lrclib.net" && request.url?.path == "/api/get")
        #expect(
            Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
                == ["track_name": "Made Up", "artist_name": "Artist", "duration": "200"])
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "Topdeck/1.2.3 (https://github.com/fredcu/Topdeck)")
        #expect(request.timeoutInterval == 10)
    }

    @Test func noAlbumIsSentEvenWhenKnown() async throws {
        let network = Network([.status(404), .list([])])
        let (client, directory) = makeClient(network)
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await client.lyrics(for: track)
        for request in network.requests {
            #expect(request.url?.query?.contains("album") == false)
        }
    }

    @Test func a404GoesToSearchAndAGoodResultWins() async throws {
        let hit: [String: Any] = [
            "trackName": "Made Up", "artistName": "Artist", "duration": 201.0, "syncedLyrics": lrc,
        ]
        let network = Network([.status(404), .list([hit])])
        let (client, directory) = makeClient(network)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(try await client.lyrics(for: track) != nil)
        #expect(network.paths == ["/api/get", "/api/search"])
        let search = URLComponents(url: network.requests[1].url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(search.map(\.name) == ["track_name", "artist_name"])
    }

    @Test func aStrippedTitleIsSearchedWhenTheFullOneFindsNothing() async throws {
        let hit: [String: Any] = [
            "trackName": "Made Up", "artistName": "Artist", "duration": 200.0, "syncedLyrics": lrc,
        ]
        let network = Network([.status(404), .list([]), .list([hit])])
        let (client, directory) = makeClient(network)
        defer { try? FileManager.default.removeItem(at: directory) }
        let live = LyricsTrack(title: "Made Up (Live)", artist: "Artist", duration: 200)
        #expect(try await client.lyrics(for: live) != nil)
        #expect(network.paths == ["/api/get", "/api/search", "/api/search"])
        let last = URLComponents(url: network.requests[2].url!, resolvingAgainstBaseURL: false)?.queryItems
        #expect(last?.first?.value == "Made Up")
    }

    @Test func aTrackWithoutAnArtistIsNeverLookedUp() async throws {
        let network = Network([])
        let (client, directory) = makeClient(network)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(try await client.lyrics(for: LyricsTrack(title: "Made Up", duration: 200)) == nil)
        #expect(network.requests.isEmpty)
    }

    @Test func a503IsRetriedWaitingOneThreeThenEightSecondsAndNotCached() async throws {
        let network = Network([.status(503), .status(503), .status(503), .status(503)])
        let (client, directory) = makeClient(network)
        defer { try? FileManager.default.removeItem(at: directory) }
        await #expect(throws: LyricsClient.Failure.self) { try await client.lyrics(for: track) }
        #expect(network.requests.count == 4, "the first try and three retries")
        #expect(network.waits == [1, 3, 8])
        #expect(files(directory).isEmpty, "a failure is not remembered")
        // The next lookup asks again and succeeds after one retry.
        let again = Network([.status(503), .lyrics(lrc)])
        let (second, _) = makeClient(again, directory: directory)
        #expect(try await second.lyrics(for: track) != nil)
        #expect(files(directory).count == 1)
    }

    @Test func networkErrorsAreRetriedLikeA503() async throws {
        let network = Network([.offline, .lyrics(lrc)])
        let (client, directory) = makeClient(network)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(try await client.lyrics(for: track) != nil)
        #expect(network.waits == [1])
    }

    @Test func a429HonoursRetryAfter() async throws {
        let network = Network([.status(429, headers: ["Retry-After": "7"]), .lyrics(lrc)])
        let (client, directory) = makeClient(network)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(try await client.lyrics(for: track) != nil)
        #expect(network.waits == [7])
    }

    @Test func theRetriesAreSharedByTheWholeLookup() async throws {
        let network = Network([.status(503), .status(404), .status(503), .status(503), .status(503)])
        let (client, directory) = makeClient(network)
        defer { try? FileManager.default.removeItem(at: directory) }
        await #expect(throws: LyricsClient.Failure.self) { try await client.lyrics(for: track) }
        #expect(network.paths == ["/api/get", "/api/get", "/api/search", "/api/search", "/api/search"])
    }

    @Test func aNotFoundIsCachedForAWeekAndThenAsksAgain() async throws {
        let network = Network([.status(404), .list([])])
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let (client, directory) = makeClient(network, now: { clock.date })
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(try await client.lyrics(for: track) == nil)
        let asked = network.requests.count
        clock.date += 6 * 24 * 3600
        #expect(try await client.lyrics(for: track) == nil)
        #expect(network.requests.count == asked, "served from the cache")
        clock.date += 2 * 24 * 3600
        _ = try? await client.lyrics(for: track)
        #expect(network.requests.count > asked, "expired")
    }

    @Test func foundLyricsAreServedFromTheCacheForGood() async throws {
        let network = Network([.lyrics(lrc)])
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let (client, directory) = makeClient(network, now: { clock.date })
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try await client.lyrics(for: track)
        clock.date += 3650 * 24 * 3600
        #expect(try await client.lyrics(for: track) == first)
        #expect(network.requests.count == 1)
    }

    @Test func theCacheKeepsTheNewestFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "Lyrics-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = LyricsCache(directory: directory, now: { .now })
        for index in 0..<(LyricsClient.keptFiles + 5) { cache.write("key\(index)", lrc: "[00:01.00]x") }
        #expect(files(directory).count == LyricsClient.keptFiles)
    }

    @Test func theKeyIgnoresCaseAccentsAndSubSecondLength() {
        let one = LyricsCache.key(for: LyricsTrack(title: "Made Úp", artist: "ARTIST", duration: 200.2))
        let two = LyricsCache.key(for: LyricsTrack(title: "made up", artist: "artist", duration: 199.8))
        #expect(one == two && one.count == 64)
    }

    final class Clock: @unchecked Sendable {
        var date: Date
        init(_ date: Date) { self.date = date }
    }
}

/// What MediaFeature asks for, when, and what it keeps.
@MainActor
struct MediaSyncedLyricsTests {
    private final class Marker {}

    private final class SleepLog: @unchecked Sendable {
        private let lock = NSLock()
        private var _all: [TimeInterval] = []
        var all: [TimeInterval] { lock.withLock { _all } }
        func add(_ seconds: TimeInterval) { lock.withLock { _all.append(seconds) } }
    }

    /// Counts asks and can hold an answer back.
    private final class Source: @unchecked Sendable {
        private let lock = NSLock()
        private var _asked: [String] = []
        private var held: [String: CheckedContinuation<Void, Never>] = [:]
        private let holds: Set<String>

        init(holds: Set<String> = []) { self.holds = holds }

        var asked: [String] { lock.withLock { _asked } }
        func isHolding(_ title: String) -> Bool { lock.withLock { held[title] != nil } }

        func answer(_ track: LyricsTrack) async -> SyncedLyrics? {
            lock.withLock { _asked.append(track.title) }
            if holds.contains(track.title) {
                await withCheckedContinuation { continuation in lock.withLock { held[track.title] = continuation } }
            }
            return SyncedLyrics(lrc: "[00:01.00]line for \(track.title)")
        }

        func release(_ title: String) { lock.withLock { held.removeValue(forKey: title) }?.resume() }
    }

    /// Fails with a 503 a set number of times, then answers; counts every try.
    private final class Flaky: @unchecked Sendable {
        private let lock = NSLock()
        private var _tries = 0
        let failures: Int
        let answer: SyncedLyrics?
        init(failures: Int, answer: SyncedLyrics?) {
            self.failures = failures
            self.answer = answer
        }
        var tries: Int { lock.withLock { _tries } }
        func ask() throws -> SyncedLyrics? {
            let n = lock.withLock { () -> Int in
                _tries += 1
                return _tries
            }
            if n <= failures { throw LyricsClient.Failure(reason: "HTTP 503") }
            return answer
        }
    }

    private func feature(_ source: Source, enabled: Bool = true) -> MediaFeature {
        let defaults = UserDefaults(suiteName: "MediaSynced-\(UUID())")!
        let media = MediaFeature(bundle: Bundle(for: Marker.self), defaults: defaults)
        media.lyricsSource = { await source.answer($0) }
        media.syncedLyrics = enabled
        return media
    }

    private func track(_ title: String, duration: Double? = 200) -> NowPlaying {
        NowPlaying(title: title, artist: "Artist", isPlaying: true, duration: duration, elapsed: 0, timestamp: .now)
    }

    @Test func itIsOffByDefault() {
        let media = MediaFeature(
            bundle: Bundle(for: Marker.self), defaults: UserDefaults(suiteName: "MediaSynced-\(UUID())")!)
        #expect(!media.syncedLyrics)
    }

    @Test func offMeansNoLookupEvenOnScreen() async {
        let source = Source()
        let media = feature(source, enabled: false)
        media.phase = .foreground
        media.receive(track("A"))
        try? await Task.sleep(for: .milliseconds(100))
        #expect(source.asked.isEmpty && media.synced == nil)
        media.phase = .stopped
    }

    @Test func onLooksUpTheTrackOnScreenOnlyOnce() async {
        let source = Source()
        let media = feature(source)
        media.phase = .foreground
        media.receive(track("A"))
        #expect(await eventually { media.synced != nil })
        var moved = track("A")
        moved.elapsed = 50
        media.receive(moved)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(source.asked == ["A"])
        media.phase = .stopped
    }

    @Test func nothingIsAskedInTheBackgroundOrWithoutALength() async {
        let source = Source()
        let media = feature(source)
        media.phase = .background
        media.receive(track("A"))
        media.receive(track("B", duration: nil))
        media.phase = .foreground
        try? await Task.sleep(for: .milliseconds(100))
        #expect(source.asked.isEmpty && media.synced == nil)
        media.phase = .stopped
    }

    @Test func subSecondDurationJitterIsTheSameTrack() async {
        let source = Source()
        let media = feature(source)
        media.phase = .foreground
        media.receive(track("A", duration: 200.2))
        #expect(await eventually { media.synced != nil })
        media.receive(track("A", duration: 199.8))
        #expect(media.synced != nil)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(source.asked == ["A"])
        media.phase = .stopped
    }

    @Test func turningItOnLooksUpTheCurrentTrackAndOffDropsIt() async {
        let source = Source()
        let media = feature(source, enabled: false)
        media.phase = .foreground
        media.receive(track("A"))
        media.syncedLyrics = true
        #expect(await eventually { media.synced != nil })
        media.syncedLyrics = false
        #expect(media.synced == nil)
        media.phase = .stopped
    }

    @Test func aFailedLookupIsTriedAgainWhileTheTrackStaysAndThenLands() async {
        let flaky = Flaky(failures: 2, answer: SyncedLyrics(lrc: "[00:01.00]made up"))
        let media = feature(Source())
        let slept = SleepLog()
        media.lyricsSource = { _ in try flaky.ask() }
        media.syncedSleep = { slept.add($0) }
        media.phase = .foreground
        media.receive(track("A"))
        #expect(await eventually { media.synced != nil })
        #expect(flaky.tries == 3 && slept.all == [30, 60])
        media.phase = .stopped
    }

    @Test func nothingFoundIsAnAnswerAndIsNotRetried() async {
        let flaky = Flaky(failures: 0, answer: nil)
        let media = feature(Source())
        let slept = SleepLog()
        media.lyricsSource = { _ in try flaky.ask() }
        media.syncedSleep = { slept.add($0) }
        media.phase = .foreground
        media.receive(track("A"))
        try? await Task.sleep(for: .milliseconds(100))
        #expect(flaky.tries == 1 && slept.all.isEmpty && media.synced == nil)
        media.phase = .stopped
    }

    @Test func givingUpAfterTheLastDelayStops() async {
        let flaky = Flaky(failures: 100, answer: nil)
        let media = feature(Source())
        media.lyricsSource = { _ in try flaky.ask() }
        media.syncedSleep = { _ in }
        media.phase = .foreground
        media.receive(track("A"))
        #expect(await eventually { flaky.tries == 5 })
        try? await Task.sleep(for: .milliseconds(100))
        #expect(flaky.tries == 5, "the first try and four retries")
        media.phase = .stopped
    }

    @Test func cancellationStopsTheRetriesAtOnce() async {
        let flaky = Flaky(failures: 100, answer: nil)
        let media = feature(Source())
        media.lyricsSource = { _ in try flaky.ask() }
        media.syncedSleep = { _ in try await Task.sleep(for: .seconds(1000)) }
        media.phase = .foreground
        media.receive(track("A"))
        #expect(await eventually { flaky.tries == 1 })
        media.phase = .background  // closing the notch
        try? await Task.sleep(for: .milliseconds(100))
        #expect(flaky.tries == 1)
        media.phase = .foreground  // opening it looks up again
        #expect(await eventually { flaky.tries == 2 })
        media.syncedLyrics = false  // turning the setting off
        try? await Task.sleep(for: .milliseconds(100))
        #expect(flaky.tries == 2)
        media.phase = .stopped
    }

    @Test func aLateAnswerForThePreviousTrackIsIgnored() async {
        let source = Source(holds: ["A"])
        let media = feature(source)
        media.phase = .foreground
        media.receive(track("A"))
        #expect(await eventually { source.isHolding("A") })
        media.receive(track("B"))
        #expect(await eventually { media.synced?.lines.first?.text == "line for B" })
        source.release("A")
        try? await Task.sleep(for: .milliseconds(100))
        #expect(media.synced?.lines.first?.text == "line for B")
        media.phase = .stopped
    }
}
