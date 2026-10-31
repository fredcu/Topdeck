// SPDX-License-Identifier: MIT
// swift-format-ignore-file

import Foundation

/// Cline: tokens and cost from its own session files, and its plan limits when its CLI is signed in.
/// Without a sign-in there are no limits to show, and none are made up.
@MainActor
final class ClineProvider: ProviderRuntime {
    let provider = Provider(
        id: "cline",
        displayName: "Cline",
        icon: .providerMark("cline"),
        links: [.init(label: "Usage", url: "https://app.cline.bot")]
    )

    let scanner: ClineLogUsageScanner
    let quotaClient: ClineQuotaClient
    let now: @Sendable () -> Date
    let pricing: @Sendable () async -> ModelPricing

    init(
        scanner: ClineLogUsageScanner = ClineLogUsageScanner(),
        quotaClient: ClineQuotaClient = ClineQuotaClient(),
        now: @escaping @Sendable () -> Date = Date.init,
        pricing: @escaping @Sendable () async -> ModelPricing = { await ModelPricingStore.shared.current() }
    ) {
        self.scanner = scanner
        self.quotaClient = quotaClient
        self.now = now
        self.pricing = pricing
    }

    var widgetDescriptors: [WidgetDescriptor] { WidgetDescriptor.spendTiles(provider: provider) }

    func hasLocalCredentials() async -> Bool {
        await loadOffMainActor { [scanner, quotaClient] in scanner.hasSessions() || quotaClient.token() != nil }
    }

    func refresh() async -> ProviderSnapshot {
        let refreshedAt = now()
        var lines: [MetricLine] = []
        var warning: String?
        var signedIn = false
        do {
            for limit in try await quotaClient.limits(now: refreshedAt) {
                signedIn = true
                lines.append(
                    .progress(
                        label: limit.label, used: limit.usedPercent, limit: 100, format: .percent, resetsAt: limit.resetsAt,
                        periodDurationMs: limit.windowMinutes * 60_000))
            }
        } catch ClineQuotaError.notSignedIn {
            // Local usage can still be read.
        } catch {
            warning = error.localizedDescription
        }
        var usageHistory: ProviderUsageHistory?
        if let scan = await scanner.scan(daysBack: UsageHistoryWindow.scanDays, now: refreshedAt, pricing: await pricing()) {
            usageHistory = ProviderUsageHistory(
                series: scan.series, modelUsage: scan.modelUsage, unknownModelsByDay: scan.unknownModelsByDay)
            SpendTileMapper.appendTokenUsage(
                scan.series, to: &lines, now: refreshedAt, unknownModelsByDay: scan.unknownModelsByDay,
                modelUsage: scan.modelUsage, modelSourceNote: "From your Cline sessions (estimated)")
        } else if !signedIn {
            return ProviderSnapshot.error(provider: provider, message: ClineQuotaError.notSignedIn.localizedDescription, category: .notLoggedIn)
        }
        MetricLine.appendNoDataIfNeeded(&lines)
        return ProviderSnapshot.make(
            provider: provider, plan: nil, lines: lines, refreshedAt: refreshedAt, usageHistory: usageHistory,
            warning: warning)
    }
}
