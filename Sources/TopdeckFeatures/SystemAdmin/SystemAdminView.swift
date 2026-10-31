// SPDX-License-Identifier: MIT
import SwiftUI
import TopdeckSurface

/// The System tab: launch agents or Homebrew packages, a running command's output in place of the
/// list, and a question before anything destructive.
struct SystemAdminView: View {
    @Bindable var admin: SystemAdminFeature

    var body: some View {
        VStack(spacing: Deck.Metric.gap) {
            header
            if let job = admin.job {
                JobOutput(job: job, cancel: admin.cancelJob, close: admin.closeJob)
            } else {
                switch admin.section {
                case .services: services
                case .homebrew: homebrew
                }
            }
            if let pending = admin.pending {
                ConfirmBar(pending: pending, confirm: admin.confirm, dismiss: admin.dismissPending)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            DeckSegmented(SystemAdminFeature.Section.allCases, selection: admin.section, title: \.title) {
                admin.section = $0
            }
            Spacer(minLength: 0)
            let busy = admin.job?.isRunning == true
            if admin.section == .homebrew, admin.packages != nil {
                headerButton("Update", label: "Check for Updates") { admin.perform(.update) }
                    .disabled(busy)
                headerButton("Upgrade All") { admin.perform(.upgradeAll) }
                    .disabled(busy || admin.outdated.isEmpty)
                headerButton("Doctor") { admin.perform(.doctor) }
                    .disabled(busy)
            }
            if admin.isLoading {
                ProgressView().controlSize(.mini).frame(width: 18)
            } else {
                headerButton("Refresh", action: admin.refresh).disabled(admin.job != nil)
            }
        }
    }

    private func headerButton(_ title: String, label: String? = nil, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.deck(compact: true))
            .help(label ?? title)
            .accessibilityLabel(label ?? title)
    }

    @ViewBuilder private var services: some View {
        if let items = admin.services {
            if items.isEmpty {
                DeckEmptyLine("No launch agents")
            } else {
                list(items) { ServiceRow(item: $0, perform: admin.perform(_:on:)) }
            }
        } else {
            loading
        }
    }

    @ViewBuilder private var homebrew: some View {
        if let error = admin.brewError {
            DeckEmptyLine(error)
        } else if let packages = admin.packages {
            if packages.isEmpty {
                DeckEmptyLine("Nothing installed")
            } else {
                list(packages) { PackageRow(package: $0, perform: admin.perform(_:)) }
            }
        } else {
            loading
        }
    }

    private var loading: some View {
        ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func list<Item: Identifiable, Row: View>(_ items: [Item], row: @escaping (Item) -> Row) -> some View {
        DeckCard(padding: 6) {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(items) { row($0) }
                }
            }
            .fadingEdges(length: 6)
        }
    }
}

private struct ServiceRow: View {
    let item: LaunchItem
    let perform: (LaunchAction, LaunchItem) -> Void

    var body: some View {
        DeckRow {
            DeckDot(item.state.tone)
            Text(item.label).deckText(.body).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
            if let pid = item.pid, item.state == .running {
                Text(verbatim: "\(pid)").deckText(.caption)
            }
            if item.isManageable {
                Menu {
                    ForEach(LaunchAction.available(for: item), id: \.self) { action in
                        Button(action.isDestructive ? "\(action.title)\u{2026}" : action.title) {
                            perform(action, item)
                        }
                    }
                } label: {
                    Text(verbatim: "···").deckText(.item, color: Deck.secondary)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Actions for \(item.label)")
            } else {
                DeckIconView(.shield, size: 13)
                    .foregroundStyle(Deck.tertiary)
                    .accessibilityElement()
                    .accessibilityLabel("Read-only")
            }
        }
        .help(([item.state.title] + item.program).joined(separator: "\n"))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(item.label), \(item.state.title)")
    }
}

private struct PackageRow: View {
    let package: BrewPackage
    let perform: (BrewAction) -> Void

    var body: some View {
        DeckRow {
            DeckIconView(package.kind == .cask ? .app : .stack, size: 14)
                .foregroundStyle(Deck.tertiary)
                .accessibilityElement()
                .accessibilityLabel(package.kind == .cask ? "Cask" : "Formula")
            Text(package.name).deckText(.body).lineLimit(1)
            Spacer(minLength: 0)
            if let latest = package.latest {
                Text(verbatim: "\(package.version) → \(latest)").deckText(.detail, color: Deck.signal).lineLimit(1)
            } else {
                Text(verbatim: package.version).deckText(.caption).lineLimit(1)
            }
            if package.isOutdated, !package.isPinned {
                DeckIconButton(.arrowUpRight, label: "Upgrade \(package.name)") { perform(.upgrade(package)) }
            }
            DeckIconButton(.trash, label: "Uninstall \(package.name)") { perform(.uninstall(package)) }
        }
        .help(package.summary)
    }
}

/// A command's output, following the newest line, with Cancel while it runs and Done after.
private struct JobOutput: View {
    let job: SystemAdminFeature.Job
    let cancel: () -> Void
    let close: () -> Void

    var body: some View {
        DeckCard(padding: Deck.Metric.gap) {
            VStack(alignment: .leading, spacing: Deck.Metric.gap) {
                HStack(spacing: 6) {
                    if let result = job.result {
                        DeckDot(result.succeeded ? .go : .stop)
                            .accessibilityHidden(false)
                            .accessibilityLabel(result.cancelled ? "Cancelled" : result.succeeded ? "Done" : "Failed")
                    } else {
                        ProgressView().controlSize(.mini)
                    }
                    Text(job.title).deckText(.item).lineLimit(1)
                    Spacer(minLength: 0)
                    Button(job.isRunning ? "Cancel" : "Done", action: job.isRunning ? cancel : close)
                        .buttonStyle(.deck(compact: true))
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(job.lines.enumerated()), id: \.offset) { index, line in
                                Text(verbatim: line).id(index)
                            }
                        }
                        .deckText(.command)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Deck.Metric.gap)
                    }
                    .background(
                        RoundedRectangle(cornerRadius: Deck.Radius.control, style: .continuous).fill(Deck.cardRaised)
                    )
                    .onChange(of: job.lines.count) { _, count in
                        if count > 0 { proxy.scrollTo(count - 1, anchor: .bottom) }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

/// The question before a destructive action, at the bottom of the tab.
private struct ConfirmBar: View {
    let pending: SystemAdminFeature.Pending
    let confirm: () -> Void
    let dismiss: () -> Void

    var body: some View {
        DeckCard(.signal, padding: Deck.Metric.gap) {
            HStack(spacing: Deck.Metric.gap) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(pending.title).deckText(.item).lineLimit(1).truncationMode(.middle)
                    Text(pending.message).deckText(.detail).lineLimit(2)
                }
                Spacer(minLength: 0)
                Button("Cancel", action: dismiss).buttonStyle(.deck())
                Button(role: .destructive, action: confirm) {
                    Text(pending.button).foregroundStyle(Deck.stop)
                }
                .buttonStyle(.deck(.outline))
            }
        }
    }
}

extension LaunchItem.State {
    fileprivate var title: String {
        switch self {
        case .running: "Running"
        case .loaded: "Loaded"
        case .disabled: "Disabled"
        case .failed: "Failed"
        case .unloaded: "Not loaded"
        case .unknown: "Unknown"
        }
    }

    fileprivate var tone: DeckTone {
        switch self {
        case .running: .go
        case .failed: .stop
        case .loaded, .disabled, .unloaded, .unknown: .quiet
        }
    }
}
