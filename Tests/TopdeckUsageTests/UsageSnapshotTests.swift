// SPDX-License-Identifier: MIT
import AppKit
import SwiftUI
import Testing
import TopdeckSurface

@testable import TopdeckUsage

/// Renders the Usage tab with sample data inside a notch-sized black panel. Always checks that it
/// draws; with SNAPSHOT_DIR set, also writes PNGs there for eyeballing.
@MainActor
struct UsageSnapshotTests {
    private let defaults = UserDefaults(suiteName: "UsageSnapshots.\(UUID().uuidString)")!
    private let cache = FileManager.default.temporaryDirectory.appending(path: "usage-snap-\(UUID().uuidString).json")

    private static let now = Date()

    /// A provider with every kind of line: limits at a given level, spend, a trend, and a note.
    private static func sample(_ id: String, _ name: String, session: Double, weekly: Double) -> ProviderSnapshot {
        let trend = (0..<14).map { day in
            MetricChartPoint(value: Double((day * 37) % 11 + 2) * 1_000_000, label: "Sep \(10 + day)", valueLabel: nil)
        }
        return ProviderSnapshot(
            providerID: id, displayName: name, plan: id == "claude" ? "Max" : "Pro",
            lines: [
                .progress(
                    label: "Session", used: session, limit: 100, format: .percent,
                    resetsAt: now.addingTimeInterval(2 * 3600 + 780), periodDurationMs: 5 * 3_600_000),
                .progress(
                    label: "Weekly", used: weekly, limit: 100, format: .percent,
                    resetsAt: now.addingTimeInterval(3 * 86_400), periodDurationMs: 7 * 86_400_000),
                .progress(label: "Extra Usage", used: 12.5, limit: 100, format: .dollars),
                .values(
                    label: "Today",
                    values: [
                        MetricValue(number: 3.12, kind: .dollars),
                        MetricValue(number: 1_200_000, kind: .count, label: "tokens"),
                    ]),
                .values(label: "Yesterday", values: [MetricValue(number: 8.4, kind: .dollars)]),
                .values(label: "Last 30 Days", values: [MetricValue(number: 58.2, kind: .dollars)]),
                .chart(label: "Usage Trend", points: trend),
            ],
            refreshedAt: now.addingTimeInterval(-120))
    }

    /// A feature with these providers on, and `offered` ones off, in the tray.
    private func usage(with snapshots: [ProviderSnapshot], offered: [(String, String)] = []) throws -> UsageFeature {
        let cached = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.providerID, $0) })
        try JSONEncoder().encode(cached).write(to: cache)
        defaults.set(snapshots.map(\.providerID), forKey: "usage.enabledProviders")
        let runtimes = (snapshots.map { ($0.providerID, $0.displayName) } + offered).map {
            FakeRuntime(id: $0.0, name: $0.1, used: 0)
        }
        return UsageFeature(defaults: defaults, cacheURL: cache, runtimes: { runtimes })
    }

    @Test func theColumnShowsTheToolsThatAreOnAndTheirQuotas() async throws {
        let usage = try AgentsSample.usage(AgentsSample.board(now: Self.now), defaults: defaults, cache: cache)
        #expect(usage.enabledProviders.map(\.id) == ["claude", "antigravity", "codex", "cline", "grok"])
        #expect(
            usage.toolUsage(now: Self.now).map(\.id) == ["claude", "codex", "antigravity", "cline"], "Grok has no spend"
        )
        #expect(usage.quotaBlocks(now: Self.now).count == 5)
        try render(usage, name: "R3c-Agents-usage")
    }

    @Test func aProviderCanBeAddedFromTheMenu() async throws {
        let usage = try usage(
            with: [Self.sample("claude", "Claude", session: 42, weekly: 71)], offered: [("codex", "Codex")])
        usage.add("codex")
        #expect(usage.isEnabled("codex") && usage.enabledProviders.map(\.id) == ["claude", "codex"])
    }

    @Test func beforeAnyProviderIsOnItOffersEveryOneSignedInFirst() async throws {
        let names = [
            "claude": "Claude", "codex": "Codex", "cursor": "Cursor", "antigravity": "Antigravity",
            "copilot": "Copilot", "devin": "Devin", "grok": "Grok", "ollama": "Ollama", "opencode": "OpenCode",
            "openrouter": "OpenRouter", "zai": "Z.ai",
        ]
        let runtimes = names.keys.sorted().map { id in
            let runtime = FakeRuntime(id: id, name: names[id] ?? id, used: 0)
            runtime.signedIn = ["claude", "codex", "copilot"].contains(id)
            return runtime
        }
        let usage = UsageFeature(defaults: defaults, cacheURL: cache, runtimes: { runtimes })
        await usage.detect()
        try render(usage, name: "usage-onboarding")
        #expect(usage.detected == ["claude", "codex", "copilot"])
    }

    /// The tab as the deck shows it, at the default size and the smallest; with SNAPSHOT_DIR set, also PNGs.
    private func render(_ usage: UsageFeature, name: String) throws {
        let title = AnyView(AgentsTitle(agents: nil))
        try DeckScreen.render(
            AgentsScreen(agents: nil, usage: usage), name: name, leading: title, actions: usage.actions)
        try DeckScreen.render(
            AgentsScreen(agents: nil, usage: usage), name: name + "-620x340", size: DeckScreen.smallest, leading: title,
            actions: usage.actions)
    }
}
