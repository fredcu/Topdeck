// SPDX-License-Identifier: MIT
import SwiftUI

/// The System Admin tab: launch agents or Homebrew packages, a running command's output in place of
/// the list, and a question before anything destructive.
struct SystemAdminView: View {
    @Bindable var admin: SystemAdminFeature

    var body: some View {
        VStack(spacing: 6) {
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
        .padding(.trailing, 8)  // clear of the resize grip in the notch's corner
    }

    private var header: some View {
        HStack(spacing: 8) {
            Picker("Section", selection: $admin.section) {
                ForEach(SystemAdminFeature.Section.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer(minLength: 0)
            let busy = admin.job?.isRunning == true
            if admin.section == .homebrew, admin.packages != nil {
                IconButton(symbol: "arrow.down.circle", label: "Check for Updates") { admin.perform(.update) }
                    .disabled(busy)
                IconButton(symbol: "arrow.up.circle", label: "Upgrade All") { admin.perform(.upgradeAll) }
                    .disabled(busy || admin.outdated.isEmpty)
                IconButton(symbol: "stethoscope", label: "Doctor") { admin.perform(.doctor) }
                    .disabled(busy)
            }
            if admin.isLoading {
                ProgressView().controlSize(.mini).frame(width: 18)
            } else {
                IconButton(symbol: "arrow.clockwise", label: "Refresh", action: admin.refresh)
                    .disabled(admin.job != nil)
            }
        }
    }

    @ViewBuilder private var services: some View {
        if let items = admin.services {
            if items.isEmpty {
                FeatureUnavailableView(
                    symbol: "gearshape.2", title: "No launch agents",
                    message: "Nothing in ~/Library/LaunchAgents, /Library/LaunchAgents, or /Library/LaunchDaemons.")
            } else {
                list(items) { ServiceRow(item: $0, perform: admin.perform(_:on:)) }
            }
        } else {
            loading
        }
    }

    @ViewBuilder private var homebrew: some View {
        if let error = admin.brewError {
            FeatureUnavailableView(symbol: "shippingbox", title: error, message: "Homebrew is at brew.sh.")
        } else if let packages = admin.packages {
            if packages.isEmpty {
                FeatureUnavailableView(
                    symbol: "shippingbox", title: "Nothing installed",
                    message: "Formulae and casks you install with brew show up here.")
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
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(items) { row($0) }
            }
            .padding(.vertical, 4)
        }
        .fadingEdges()
    }
}

private struct ServiceRow: View {
    let item: LaunchItem
    let perform: (LaunchAction, LaunchItem) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(item.state.color).frame(width: 6, height: 6)
            Text(item.label).font(.caption).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
            if let pid = item.pid, item.state == .running {
                Text(verbatim: "\(pid)").font(.caption2).monospacedDigit().foregroundStyle(.white.opacity(0.5))
            }
            if item.isManageable {
                Menu {
                    ForEach(LaunchAction.available(for: item), id: \.self) { action in
                        Button(action.isDestructive ? "\(action.title)\u{2026}" : action.title) {
                            perform(action, item)
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Actions for \(item.label)")
            } else {
                Image(systemName: "lock").font(.caption2).opacity(0.4).accessibilityLabel("Read-only")
            }
        }
        .padding(.horizontal, 8)
        .frame(minHeight: 24)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
        .help(([item.state.title] + item.program).joined(separator: "\n"))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(item.label), \(item.state.title)")
    }
}

private struct PackageRow: View {
    let package: BrewPackage
    let perform: (BrewAction) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: package.kind == .cask ? "macwindow" : "shippingbox")
                .font(.caption2)
                .opacity(0.5)
                .accessibilityLabel(package.kind == .cask ? "Cask" : "Formula")
            Text(package.name).font(.caption).lineLimit(1)
            Spacer(minLength: 0)
            Group {
                if let latest = package.latest {
                    Text(verbatim: "\(package.version) → \(latest)").foregroundStyle(.orange)
                } else {
                    Text(verbatim: package.version).foregroundStyle(.white.opacity(0.5))
                }
            }
            .font(.caption2)
            .lineLimit(1)
            if package.isOutdated, !package.isPinned {
                IconButton(symbol: "arrow.up.circle", label: "Upgrade \(package.name)") { perform(.upgrade(package)) }
            }
            IconButton(symbol: "trash", label: "Uninstall \(package.name)") { perform(.uninstall(package)) }
        }
        .padding(.horizontal, 8)
        .frame(minHeight: 24)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
        .help(package.summary)
    }
}

/// A command's output, following the newest line, with Cancel while it runs and Done after.
private struct JobOutput: View {
    let job: SystemAdminFeature.Job
    let cancel: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if let result = job.result {
                    Image(systemName: result.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(result.succeeded ? .green : .red)
                        .accessibilityLabel(result.cancelled ? "Cancelled" : result.succeeded ? "Done" : "Failed")
                } else {
                    ProgressView().controlSize(.mini)
                }
                Text(job.title).font(.caption.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 0)
                Button(job.isRunning ? "Cancel" : "Done", action: job.isRunning ? cancel : close)
                    .buttonStyle(.plain)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(.white.opacity(0.15), in: Capsule())
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(job.lines.enumerated()), id: \.offset) { index, line in
                            Text(verbatim: line).id(index)
                        }
                    }
                    .font(.system(size: 10, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }
                .background(.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 7))
                .onChange(of: job.lines.count) { _, count in
                    if count > 0 { proxy.scrollTo(count - 1, anchor: .bottom) }
                }
            }
        }
    }
}

/// The question before a destructive action, at the bottom of the tab.
private struct ConfirmBar: View {
    let pending: SystemAdminFeature.Pending
    let confirm: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(pending.title).font(.caption.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                Text(pending.message).font(.caption2).foregroundStyle(.white.opacity(0.6)).lineLimit(2)
            }
            Spacer(minLength: 0)
            Button("Cancel", action: dismiss)
            Button(pending.button, role: .destructive, action: confirm)
                .foregroundStyle(.red)
        }
        .buttonStyle(.plain)
        .font(.caption.weight(.semibold))
        .padding(8)
        .background(GlassPlatter(shape: RoundedRectangle(cornerRadius: 9)))
    }
}

private struct IconButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium)).frame(width: 18, height: 18)
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
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

    fileprivate var color: Color {
        switch self {
        case .running: .green
        case .loaded: .blue
        case .disabled: .orange
        case .failed: .red
        case .unloaded, .unknown: .gray
        }
    }
}
