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

    @Test func theTabShowsTheProviderPickedInTheSecondRow() async throws {
        let usage = try usage(with: [
            Self.sample("claude", "Claude", session: 62, weekly: 38),
            Self.sample("codex", "Codex", session: 86, weekly: 40),
            Self.sample("copilot", "Copilot", session: 15, weekly: 5),
        ])
        #expect(usage.currentProvider?.id == "claude", "the first one until another is picked")
        try render(usage, name: "usage")
        usage.selectedProvider = "codex"
        #expect(usage.currentProvider?.id == "codex")
        try render(usage, name: "usage-codex")
        usage.setEnabled("codex", false)
        #expect(usage.currentProvider?.id == "claude", "a provider that is turned off is no longer shown")
    }

    @Test func aProviderWithMoreLimitsThanFitScrollsThem() async throws {
        var snapshot = Self.sample("claude", "Claude", session: 97, weekly: 88)
        snapshot.lines.insert(
            contentsOf: (1...3).map { .progress(label: "Model \($0)", used: 20, limit: 100, format: .percent) }, at: 2)
        snapshot.lines.append(.text(label: "Organization", value: "Forge"))
        snapshot.warning = "Sign in again for live usage"
        try render(try usage(with: [snapshot]), name: "usage-many")
    }

    @Test func moreChipsThanFitScrollSideways() async throws {
        let ids = [
            ("claude", "Claude"), ("codex", "Codex"), ("cursor", "Cursor"), ("copilot", "Copilot"), ("grok", "Grok"),
        ]
        let usage = try usage(with: ids.map { Self.sample($0.0, $0.1, session: 42, weekly: 20) })
        try render(usage, name: "usage-five")
    }

    @Test func aProviderCanBeAddedFromTheMenuAndTurnedOffFromItsChip() async throws {
        let usage = try usage(
            with: [Self.sample("claude", "Claude", session: 42, weekly: 71)], offered: [("codex", "Codex")])
        usage.add("codex")
        #expect(usage.isEnabled("codex") && usage.currentProvider?.id == "codex", "added and shown")
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
        let tabs = ["Sessions", "Usage"]
        try DeckScreen.render(
            UsageView(usage: usage), name: name, tabs: tabs, selected: "Usage", actions: usage.actions)
        try DeckScreen.render(
            UsageView(usage: usage), name: name + "-smallest", size: DeckScreen.smallest, tabs: tabs,
            selected: "Usage", actions: usage.actions)
    }
}
