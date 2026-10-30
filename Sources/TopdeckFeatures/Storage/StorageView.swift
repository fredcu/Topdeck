// SPDX-License-Identifier: MIT
import SwiftUI

/// The Storage tab: Xcode's leftovers by category, or the home folder by size. Either list ticks
/// items for the Trash, and Review lists every one with its size before anything moves.
struct StorageView: View {
    let storage: StorageFeature

    var body: some View {
        if let review = storage.review {
            ReviewList(storage: storage, review: review)
        } else {
            VStack(spacing: 6) {
                Group {
                    switch storage.mode {
                    case .xcode: XcodeList(storage: storage)
                    case .disk: DiskBrowser(storage: storage)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                footer
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            HStack(spacing: 0) {
                modeButton("Xcode", .xcode)
                modeButton("Home", .disk)
            }
            .background(GlassPlatter(shape: Capsule()))
            Spacer(minLength: 0)
            if let report = storage.report {
                ReportLine(report: report, dismiss: storage.dismissReport)
            } else {
                selectionSummary
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 8)  // clear of the resize grip in the notch's corner
    }

    @ViewBuilder private var selectionSummary: some View {
        switch storage.mode {
        case .xcode:
            if storage.xcode.value?.isEmpty == false {
                if storage.xcodeBusy {
                    Text("Quit Xcode to clean")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                } else {
                    let bytes = storage.xcodeBytes(selectedOnly: true)
                    StorageButton(title: "Review \(StorageFormat.bytes(bytes))", tint: .white) {
                        storage.reviewXcode()
                    }
                    .disabled(storage.xcodeSelection.isEmpty)
                    .opacity(storage.xcodeSelection.isEmpty ? 0.4 : 1)
                }
            }
        case .disk:
            if !storage.diskSelection.isEmpty {
                let bytes = storage.diskSelectedBytes
                StorageButton(title: "Review \(StorageFormat.bytes(bytes))", tint: .white) { storage.reviewDisk() }
            }
        }
    }

    private func modeButton(_ title: String, _ mode: StorageFeature.Mode) -> some View {
        let selected = storage.mode == mode
        return Button {
            storage.mode = mode
        } label: {
            Text(title)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.white.opacity(selected ? 0.18 : 0), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(selected ? 1 : 0.6))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

enum StorageFormat {
    static func bytes(_ bytes: Int64) -> String { max(0, bytes).formatted(.byteCount(style: .file)) }

    /// The path from the home folder, as "~/…".
    static func path(_ path: String, home: String) -> String {
        path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}

/// A capsule button like the Clipboard tab's footer buttons.
private struct StorageButton: View {
    let title: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(tint)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(.white.opacity(0.12), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// A start button in the middle of an empty tab.
private struct ScanPrompt: View {
    let symbol: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.callout.weight(.semibold))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.white.opacity(0.14), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A tick box for a row.
private struct Tick: View {
    let ticked: Bool
    let label: String
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            Image(systemName: ticked ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(ticked ? 0.95 : 0.4))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(ticked ? "Selected" : "Not selected")
    }
}

private struct SizeText: View {
    let bytes: Int64

    var body: some View {
        Text(StorageFormat.bytes(bytes))
            .font(.caption.weight(.medium))
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.7))
            .fixedSize()
    }
}

private func symbol(for kind: DiskItem.Kind) -> String {
    switch kind {
    case .folder: "folder.fill"
    case .file: "doc.fill"
    case .symbolicLink: "arrowshape.turn.up.right.fill"
    case .other: "questionmark.square.dashed"
    }
}

/// Xcode's items by category, each category with its total and a tick for all of it.
private struct XcodeList: View {
    let storage: StorageFeature

    var body: some View {
        switch storage.xcode {
        case .idle:
            ScanPrompt(symbol: "hammer", title: "Scan Xcode") { _ = storage.scanXcode() }
        case .scanning:
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        case .done(let items) where items.isEmpty:
            FeatureUnavailableView(
                symbol: "checkmark.circle", title: "Nothing to clean", message: "Xcode's folders are empty.",
                action: (label: "Scan Again", perform: { _ = storage.scanXcode() }))
        case .done(let items):
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(XcodeCategory.allCases) { category in
                        let inCategory = items.filter { $0.category == category }
                        if !inCategory.isEmpty {
                            header(category, items: inCategory)
                            ForEach(inCategory) { row($0) }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .fadingEdges()
            .onAppear(perform: storage.refreshXcodeBusy)
        }
    }

    private func header(_ category: XcodeCategory, items: [XcodeItem]) -> some View {
        let ids = Set(items.map(\.id))
        let all = ids.isSubset(of: storage.xcodeSelection)
        return HStack(spacing: 6) {
            Tick(ticked: all, label: "All of \(category.title)") {
                if all { storage.xcodeSelection.subtract(ids) } else { storage.xcodeSelection.formUnion(ids) }
            }
            Text(category.title).font(.caption.weight(.bold))
            Spacer(minLength: 6)
            SizeText(bytes: storage.xcodeBytes(category))
        }
        .padding(.horizontal, 6)
        .padding(.top, 6)
    }

    private func row(_ item: XcodeItem) -> some View {
        let ticked = storage.xcodeSelection.contains(item.id)
        return HStack(spacing: 6) {
            Tick(ticked: ticked, label: item.item.name) {
                if ticked { storage.xcodeSelection.remove(item.id) } else { storage.xcodeSelection.insert(item.id) }
            }
            Text(item.item.name).font(.caption).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 6)
            SizeText(bytes: item.item.bytes)
        }
        .padding(.leading, 18)
        .padding(.trailing, 6)
        .padding(.vertical, 2)
    }
}

/// The home folder by size: a folder at a time, largest first, each folder opening to its own.
private struct DiskBrowser: View {
    let storage: StorageFeature

    var body: some View {
        switch storage.disk {
        case .idle:
            ScanPrompt(symbol: "internaldrive", title: "Scan Home Folder") { _ = storage.scanDisk() }
        case .scanning:
            VStack(spacing: 8) {
                ProgressView().controlSize(.small)
                SizeText(bytes: storage.diskCounted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Scanning, \(StorageFormat.bytes(storage.diskCounted)) so far")
        case .done:
            VStack(spacing: 4) {
                header
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(storage.diskItems) { row($0) }
                    }
                    .padding(.vertical, 4)
                }
                .fadingEdges()
            }
        }
    }

    private var header: some View {
        let atHome = storage.diskPath.count <= 1
        return HStack(spacing: 6) {
            Button {
                Task { await storage.goUp() }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(atHome)
            .opacity(atHome ? 0.3 : 1)
            .accessibilityLabel("Back")
            Text(storage.diskPath.last.map { StorageFormat.path($0, home: storage.home) } ?? "~")
                .font(.caption.weight(.bold))
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 6)
            SizeText(bytes: storage.currentFolder?.bytes ?? 0)
            Button {
                _ = storage.scanDisk()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Scan Again")
        }
        .padding(.horizontal, 6)
    }

    private func row(_ item: DiskItem) -> some View {
        let ticked = storage.diskSelection.contains(item.id)
        let largest = max(storage.diskItems.first?.bytes ?? 1, 1)
        return HStack(spacing: 6) {
            if storage.canRemove(item) {
                Tick(ticked: ticked, label: item.name) {
                    if ticked { storage.diskSelection.remove(item.id) } else { storage.diskSelection.insert(item.id) }
                }
            } else {
                Image(systemName: "lock.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.3))
                    .frame(width: 18, height: 18)
                    .accessibilityLabel("Protected")
            }
            Button {
                if item.kind == .folder { Task { await storage.open(item.path) } }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: symbol(for: item.kind))
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(width: 14)
                    Text(item.name).font(.caption).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 6)
                    Capsule()
                        .fill(.white.opacity(0.35))
                        .frame(width: 40 * CGFloat(Double(max(item.bytes, 0)) / Double(largest)), height: 3)
                        .frame(width: 40, alignment: .leading)
                        .accessibilityHidden(true)
                    SizeText(bytes: item.bytes)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .opacity(item.kind == .folder ? 0.5 : 0)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(item.kind != .folder)
            .accessibilityLabel("\(item.name), \(StorageFormat.bytes(item.bytes))")
            .accessibilityHint(item.kind == .folder ? Text("Opens the folder") : Text(""))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
    }
}

/// Every item about to go to the Trash, with its size and the total, and Move to Trash.
private struct ReviewList: View {
    let storage: StorageFeature
    let review: TrashReview

    var body: some View {
        VStack(spacing: 6) {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(review.items) { item in
                        HStack(spacing: 6) {
                            Image(systemName: symbol(for: item.kind))
                                .font(.system(size: 10))
                                .foregroundStyle(.white.opacity(0.6))
                                .frame(width: 14)
                            Text(StorageFormat.path(item.path, home: storage.home))
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.head)
                            Spacer(minLength: 6)
                            SizeText(bytes: item.bytes)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(.vertical, 4)
            }
            .fadingEdges()
            HStack(spacing: 8) {
                Text("^[\(review.items.count) item](inflect: true), \(StorageFormat.bytes(review.totalBytes))")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                Spacer(minLength: 0)
                if storage.trashing {
                    ProgressView().controlSize(.small)
                } else {
                    StorageButton(title: "Cancel", tint: .white, action: storage.cancelReview)
                    StorageButton(title: "Move to Trash", tint: .red) { Task { await storage.confirmTrash() } }
                }
            }
            .padding(.leading, 6)
            .padding(.trailing, 8)
        }
    }
}

/// What the last Move to Trash did.
private struct ReportLine: View {
    let report: TrashReport
    let dismiss: () -> Void

    var body: some View {
        Button(action: dismiss) {
            HStack(spacing: 4) {
                if report.kept > 0 {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("^[\(report.kept) item](inflect: true) kept")
                } else {
                    Image(systemName: "trash")
                    Text("\(StorageFormat.bytes(report.trashedBytes)) in the Trash")
                }
            }
            .font(.caption2.weight(.medium))
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.75))
        }
        .buttonStyle(.plain)
        .help(report.kept > 0 ? keptReasons : "")
        .accessibilityHint("Dismisses")
    }

    private var keptReasons: String {
        let reasons = report.outcomes.values.compactMap { outcome -> String? in
            switch outcome {
            case .trashed: nil
            case .xcodeBusy: "Xcode or a build was running"
            case .refused: "Protected or a link"
            case .failed(let message): message
            }
        }
        return Array(Set(reasons)).sorted().joined(separator: "\n")
    }
}
