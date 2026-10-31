// SPDX-License-Identifier: MIT
import Foundation
import Testing

@testable import TopdeckUsage

/// A session file as Cline writes it: two spaces a level.
private func session(_ messages: [String]) -> Data {
    Data(
        """
        {
          "version": 1,
          "system_prompt": "\(String(repeating: "x", count: 4000))",
          "messages": [
        \(messages.joined(separator: ",\n"))
          ]
        }
        """.utf8)
}

private func assistant(
    id: String, ts: Int, model: String = "cline-pass/deepseek-v4.1-flash", input: Int, output: Int, cacheRead: Int = 0,
    cost: String? = nil
) -> String {
    """
        {
          "id": "\(id)",
          "role": "assistant",
          "content": [
            {
              "type": "text",
              "text": "SECRET conversation text, \(String(repeating: "y", count: 2000))"
            }
          ],
          "ts": \(ts),
          "modelInfo": {
            "id": "\(model)",
            "provider": "cline-pass"
          },
          "metrics": {
            "inputTokens": \(input),
            "outputTokens": \(output),
            "cacheReadTokens": \(cacheRead),
            "cacheWriteTokens": 0\(cost.map { ",\n        \"cost\": \($0)" } ?? "")
          }
        }
    """
}

private let user = """
        {
          "id": "u1",
          "role": "user",
          "content": [
            {
              "type": "text",
              "text": "hello"
            }
          ],
          "ts": 1791434860000
        }
    """

struct ClineUsageTests {
    private func entries(_ data: Data, chunk: Int) -> [ClineLogUsageScanner.Entry] {
        var reader = ClineMessageReader()
        var offset = 0
        while offset < data.count {
            reader.feed(data.subdata(in: offset..<min(offset + chunk, data.count)))
            offset += chunk
        }
        return reader.finish()
    }

    @Test func onlyAssistantMessagesWithCountsAreKeptWhateverTheChunking() {
        let data = session([
            user, assistant(id: "a1", ts: 1_791_434_860_233, input: 10_090, output: 182, cacheRead: 112),
            assistant(id: "a2", ts: 1_791_434_900_000, model: "claude-sonnet-4", input: 5, output: 7, cost: "0.25"),
        ])
        for chunk in [1, 7, 64, 4096, data.count] {
            let found = entries(data, chunk: chunk)
            #expect(found.map(\.id) == ["a1", "a2"], "chunk \(chunk)")
            #expect(found[0].input == 10_090 && found[0].output == 182 && found[0].cacheRead == 112)
            #expect(found[0].model == "cline-pass/deepseek-v4.1-flash" && found[0].cost == nil)
            #expect(found[0].timestamp == Date(timeIntervalSince1970: 1_791_434_860.233))
            #expect(found[1].cost == 0.25)
        }
    }

    @Test func aMessageWithoutCountsOrAModelIsLeftOut() {
        let noMetrics = """
                {
                  "id": "a3",
                  "role": "assistant",
                  "content": [],
                  "ts": 1791434860233,
                  "modelInfo": {
                    "id": "m"
                  }
                }
            """
        #expect(entries(session([noMetrics, user]), chunk: 50).isEmpty)
    }

    @Test func thePricingNamesTryTheBareIdThenTheVendorsOwn() {
        #expect(
            ClineLogUsageScanner.pricingNames(for: "cline-pass/deepseek-v4.1-flash") == [
                "deepseek-v4.1-flash", "deepseek/deepseek-v4.1-flash",
            ])
        #expect(ClineLogUsageScanner.pricingNames(for: "cline-free/kimi-k3") == ["kimi-k3", "moonshot/kimi-k3"])
        #expect(ClineLogUsageScanner.pricingNames(for: "claude-sonnet-4") == ["claude-sonnet-4"])
    }

    @Test func aFileThatHasNotChangedIsNotReadAgain() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "Cline-\(UUID().uuidString)")
        let folder = root.appending(path: "s1")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = folder.appending(path: "s1.messages.json")
        let now = Date(timeIntervalSince1970: 1_791_440_000)
        try session([assistant(id: "a1", ts: 1_791_434_860_233, input: 1000, output: 500, cost: "0.5")]).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: file.path)
        let scanner = ClineLogUsageScanner(sessionsRoot: { root }, cache: ClineScanCache())
        let scan = try #require(await scanner.scan(now: now, pricing: .empty))
        #expect(scan.series.daily.map(\.totalTokens) == [1500] && scan.series.daily.map(\.costUSD) == [0.5])
        #expect(scanner.hasSessions())
        // Same size and time, other content: the cache answers, so the old numbers stand.
        var other = try Data(contentsOf: file)
        other.replaceSubrange(
            other.range(of: Data("\"inputTokens\": 1000".utf8))!, with: Data("\"inputTokens\": 2000".utf8))
        try other.write(to: file)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: file.path)
        let again = try #require(await scanner.scan(now: now, pricing: .empty))
        #expect(again.series.daily.map(\.totalTokens) == [1500])
        #expect(await ClineLogUsageScanner(sessionsRoot: { root.appending(path: "none") }).scan(pricing: .empty) == nil)
    }

    @Test func tokensOfAModelNobodyPricesCountWithNoCost() {
        let entry = ClineLogUsageScanner.Entry(
            id: "a", timestamp: Date(timeIntervalSince1970: 1_791_434_860), model: "cline-pass/unknown-model",
            input: 100,
            output: 50, cacheRead: 0, cacheWrite: 0, cost: nil)
        let scan = ClineLogUsageScanner.aggregate(entries: [entry], since: .distantPast, pricing: .empty)
        #expect(scan.series.daily.count == 1 && scan.series.daily[0].totalTokens == 150)
        #expect(scan.series.daily[0].costUSD == nil, "no price is not a price of zero")
        #expect(scan.unknownModelsByDay.values.first == ["unknown-model"])
    }

    @Test func theLimitsAreTheCliEndpointsInTheirOrder() throws {
        let body = Data(
            """
            {"success": true, "data": {"limits": [
              {"type": "weekly", "percentUsed": 23, "resetsAt": "2026-11-05T10:00:00.000Z"},
              {"type": "five_hour", "percentUsed": 27.5},
              {"type": "monthly", "percentUsed": 150},
              {"type": "other", "percentUsed": 1}
            ]}}
            """.utf8)
        let limits = try #require(ClineQuotaClient.parse(body))
        #expect(limits.map(\.label) == ["5-hour", "Weekly"], "out of range and unknown ones are left out")
        #expect(limits[0].usedPercent == 27.5 && limits[0].windowMinutes == 300 && limits[0].resetsAt == nil)
        #expect(limits[1].resetsAt != nil)
        #expect(ClineQuotaClient.parse(Data("{\"success\": false}".utf8)) == nil)
        #expect(ClineQuotaClient.parse(Data("nonsense".utf8)) == nil)
    }

    @Test func theTokenIsTheClisOwnAndNotAnExpiredOne() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "ClineHome-\(UUID().uuidString)")
        let settings = home.appending(path: ".cline/data/settings")
        try FileManager.default.createDirectory(at: settings, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let now = Date(timeIntervalSince1970: 1_791_440_000)
        let past = Int((now.timeIntervalSince1970 - 3600) * 1000)
        let future = Int((now.timeIntervalSince1970 + 3600) * 1000)
        let json = """
            {"providers": {
              "cline-pass": {"settings": {"auth": {"accessToken": "expired-one", "expiresAt": \(past)}}},
              "cline": {"settings": {"auth": {"accessToken": "good-one", "expiresAt": \(future)}}}
            }}
            """
        try Data(json.utf8).write(to: settings.appending(path: "providers.json"))
        let client = ClineQuotaClient(home: { home })
        #expect(client.token(now: now) == "good-one")
        #expect(ClineQuotaClient(home: { home.appending(path: "none") }).token(now: now) == nil)
    }
}
