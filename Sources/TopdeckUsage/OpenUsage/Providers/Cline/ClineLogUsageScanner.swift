// SPDX-License-Identifier: MIT
// swift-format-ignore-file

import Foundation

/// Cline's own record of its turns: `~/.cline/data/sessions/<id>/<id>.messages.json`. A session file holds the
/// whole conversation, so it is read as a stream of lines and only a message's id, role, time, model and
/// token counts are kept; the text of the conversation is never held. A file that has not changed since the
/// last scan is not read again.
struct ClineLogUsageScanner: Sendable {
    /// One answer of the model.
    struct Entry: Hashable, Sendable {
        var id: String
        var timestamp: Date
        var model: String
        /// The provider's own counts; input already holds the cache slices.
        var input: Int
        var output: Int
        var cacheRead: Int
        var cacheWrite: Int
        /// What Cline recorded as the cost, when it did.
        var cost: Double?
    }

    private let sessionsRoot: @Sendable () -> URL
    private let cache: ClineScanCache

    init(
        sessionsRoot: @escaping @Sendable () -> URL = {
            FileManager.default.homeDirectoryForCurrentUser.appending(path: ".cline/data/sessions", directoryHint: .isDirectory)
        },
        cache: ClineScanCache = .shared
    ) {
        self.sessionsRoot = sessionsRoot
        self.cache = cache
    }

    /// Whether Cline has kept any session on this Mac.
    func hasSessions() -> Bool {
        (try? FileManager.default.contentsOfDirectory(atPath: sessionsRoot().path))?.isEmpty == false
    }

    /// The usage of the last `daysBack` days, priced through the shared pricing store. Nil when there is no
    /// sessions folder.
    func scan(daysBack: Int = 30, now: Date = Date(), pricing: ModelPricing) async -> LogUsageScan? {
        let root = sessionsRoot()
        guard FileManager.default.fileExists(atPath: root.path) else { return nil }
        let since = JSONLScanning.sinceDate(daysBack: daysBack, now: now)
        let entries = await Task.detached(priority: .utility) { collect(root: root, since: since) }.value
        return Self.aggregate(entries: entries, since: since, pricing: pricing)
    }

    /// Every file's entries, from the cache while the file is as it was.
    private func collect(root: URL, since: Date) -> [Entry] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        var all: [Entry] = []
        var seen: Set<String> = []
        for folder in folders {
            let file = folder.appending(path: "\(folder.lastPathComponent).messages.json")
            guard let values = try? file.resourceValues(forKeys: Set(keys)), let modified = values.contentModificationDate,
                modified >= since
            else { continue }
            let signature = ClineScanCache.Signature(size: values.fileSize ?? 0, modified: modified)
            seen.insert(file.path)
            if let kept = cache.entries(for: file.path, signature: signature) {
                all += kept
                continue
            }
            let parsed = Self.parse(file: file)
            cache.store(parsed, for: file.path, signature: signature)
            all += parsed
        }
        cache.forget(except: seen)
        return all
    }

    // MARK: Reading

    /// The entries of one session file, read a chunk at a time.
    static func parse(file: URL) -> [Entry] {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return [] }
        defer { try? handle.close() }
        var reader = ClineMessageReader()
        while let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty { reader.feed(chunk) }
        return reader.finish()
    }

    // MARK: Pricing

    /// The bare model id, and the vendor-qualified one the public price lists use for it: Cline names a
    /// subscription model `cline-pass/<id>` or `cline-free/<id>`.
    static func pricingNames(for model: String) -> [String] {
        var bare = model.lowercased()
        for tier in ["cline-pass/", "cline-free/"] where bare.hasPrefix(tier) { bare.removeFirst(tier.count) }
        let vendors: [(prefix: String, vendor: String)] = [
            ("deepseek-", "deepseek/"), ("kimi-", "moonshot/"), ("glm-", "zai/"), ("mimo-", "xiaomi_mimo/"),
            ("minimax-", "minimax/"), ("muse-spark-", "meta/"), ("qwen", "dashscope/"),
        ]
        let qualified = vendors.first { bare.hasPrefix($0.prefix) }.map { $0.vendor + bare }
        return [bare] + (qualified.map { [$0] } ?? [])
    }

    static func aggregate(entries: [Entry], since: Date, pricing: ModelPricing) -> LogUsageScan {
        var accumulator = DailyUsageAccumulator()
        for entry in entries where entry.timestamp >= since {
            let day = DailyUsageAccumulator.dayKey(from: entry.timestamp)
            let names = pricingNames(for: entry.model)
            let tokens = TokenBreakdown(
                input: max(0, entry.input - entry.cacheRead - entry.cacheWrite), cacheWrite5m: entry.cacheWrite,
                cacheRead: entry.cacheRead, output: entry.output)
            let model = names[0]
            let cost = entry.cost ?? names.lazy.compactMap { pricing.estimatedCostDollars(model: $0, tokens: tokens) }.first
            if let cost {
                accumulator.add(day: day, tokens: tokens.totalTokens, cost: cost, model: model)
            } else if tokens.totalTokens > 0 {
                accumulator.addUnpriced(day: day, tokens: tokens.totalTokens, model: model)
            }
        }
        return accumulator.build()
    }
}

/// What was read from each session file, kept while the file is the same size and was last changed at the
/// same time. Held in memory for the life of the app.
final class ClineScanCache: @unchecked Sendable {
    struct Signature: Equatable, Sendable {
        var size: Int
        var modified: Date
    }

    static let shared = ClineScanCache()

    private let lock = NSLock()
    private var files: [String: (signature: Signature, entries: [ClineLogUsageScanner.Entry])] = [:]

    func entries(for path: String, signature: Signature) -> [ClineLogUsageScanner.Entry]? {
        lock.withLock { files[path].flatMap { $0.signature == signature ? $0.entries : nil } }
    }

    func store(_ entries: [ClineLogUsageScanner.Entry], for path: String, signature: Signature) {
        lock.withLock { files[path] = (signature, entries) }
    }

    /// Drops the files that are no longer there or no longer in the window.
    func forget(except paths: Set<String>) {
        lock.withLock { files = files.filter { paths.contains($0.key) } }
    }
}

/// Reads a session file's lines as they arrive and keeps the usage fields of each assistant message. The file
/// is indented two spaces a level, so a message's own keys are six spaces in and its model and counts eight;
/// everything deeper, the conversation itself, is skipped without being copied. A line longer than a few
/// hundred bytes can only be conversation and is dropped as it streams past.
struct ClineMessageReader {
    private static let longestLine = 512

    private var pending = Data()
    private var skipping = false
    private var message = Message()
    private var section = Section.none
    private var entries: [ClineLogUsageScanner.Entry] = []

    private enum Section { case none, modelInfo, metrics }

    private struct Message {
        var id: String?
        var role: String?
        var timestamp: Double?
        var model: String?
        var input: Int?
        var output: Int?
        var cacheRead = 0
        var cacheWrite = 0
        var cost: Double?
    }

    mutating func feed(_ chunk: Data) {
        var start = chunk.startIndex
        while let end = chunk[start...].firstIndex(of: 0x0A) {
            let piece = chunk[start..<end]
            if skipping {
                skipping = false
            } else if pending.isEmpty {
                handle(piece)
            } else {
                pending.append(piece)
                handle(pending)
                pending.removeAll(keepingCapacity: true)
            }
            start = chunk.index(after: end)
        }
        guard !skipping else { return }
        pending.append(chunk[start...])
        if pending.count > Self.longestLine {
            pending.removeAll(keepingCapacity: true)
            skipping = true
        }
    }

    /// The entries found, once everything has been fed.
    mutating func finish() -> [ClineLogUsageScanner.Entry] {
        if !pending.isEmpty, !skipping { handle(pending) }
        pending.removeAll()
        return entries
    }

    private mutating func handle(_ line: some Collection<UInt8>) {
        var indent = 0
        var body = line.makeIterator()
        var first: UInt8?
        while let byte = body.next() {
            if byte == 0x20 { indent += 1 } else { first = byte; break }
        }
        guard indent >= 4, indent <= 8, line.count <= Self.longestLine, first != nil else { return }
        let text = String(decoding: line.dropFirst(indent), as: UTF8.self)
        switch indent {
        case 4:
            if text.hasPrefix("{") { message = Message(); section = .none } else if text.hasPrefix("}") { flush() }
        case 6:
            section = .none
            guard let (key, value) = Self.pair(text) else { return }
            switch key {
            case "id": message.id = Self.string(value)
            case "role": message.role = Self.string(value)
            case "ts": message.timestamp = Self.number(value)
            case "modelInfo": section = value.hasPrefix("{") ? .modelInfo : .none
            case "metrics": section = value.hasPrefix("{") ? .metrics : .none
            default: break
            }
        default:
            guard let (key, value) = Self.pair(text) else { return }
            switch (section, key) {
            case (.modelInfo, "id"): message.model = Self.string(value)
            case (.metrics, "inputTokens"): message.input = Self.count(value)
            case (.metrics, "outputTokens"): message.output = Self.count(value)
            case (.metrics, "cacheReadTokens"): message.cacheRead = Self.count(value) ?? 0
            case (.metrics, "cacheWriteTokens"): message.cacheWrite = Self.count(value) ?? 0
            case (.metrics, "cost"): message.cost = Self.number(value).flatMap { $0 >= 0 && $0.isFinite ? $0 : nil }
            default: break
            }
        }
    }

    private mutating func flush() {
        defer { message = Message(); section = .none }
        guard message.role == "assistant", let id = message.id, !id.isEmpty, let stamp = message.timestamp,
            let model = message.model, !model.isEmpty, message.input != nil || message.output != nil
        else { return }
        entries.append(
            ClineLogUsageScanner.Entry(
                id: id, timestamp: Date(timeIntervalSince1970: stamp / 1000), model: model, input: message.input ?? 0,
                output: message.output ?? 0, cacheRead: message.cacheRead, cacheWrite: message.cacheWrite,
                cost: message.cost))
    }

    /// `"key": value,` as the key and the value without its trailing comma.
    private static func pair(_ text: String) -> (String, String)? {
        guard text.hasPrefix("\""), let close = text.dropFirst().firstIndex(of: "\"") else { return nil }
        let key = String(text[text.index(after: text.startIndex)..<close])
        var rest = text[text.index(after: close)...].drop { $0 == " " }
        guard rest.hasPrefix(":") else { return nil }
        rest = rest.dropFirst().drop { $0 == " " }
        if rest.hasSuffix(",") { rest = rest.dropLast() }
        return (key, String(rest))
    }

    private static func string(_ value: String) -> String? {
        guard value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 else { return nil }
        return String(value.dropFirst().dropLast())
    }

    private static func number(_ value: String) -> Double? { Double(value) }

    /// A whole, non-negative count.
    private static func count(_ value: String) -> Int? {
        guard let number = Double(value), number >= 0, number == number.rounded(), number < 1e15 else { return nil }
        return Int(number)
    }
}
