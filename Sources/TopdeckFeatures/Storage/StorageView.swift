// SPDX-License-Identifier: MIT
import SwiftUI
import TopdeckSurface

/// The Storage tab: Xcode's leftovers by category, or the home folder by size. Either list ticks
/// items for the Trash, and Review lists every one with its size before anything moves.
struct StorageView: View {
    let storage: StorageFeature

    var body: some View {
        if let review = storage.review {
            ReviewList(storage: storage, review: review)
        } else {
            VStack(spacing: Deck.Metric.gap) {
                header
                DeckCard(padding: 6) {
                    Group {
                        switch storage.mode {
                        case .xcode: XcodeList(storage: storage)
                        case .disk: DiskBrowser(storage: storage)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    /// The Xcode and Home switch, and on the right what's next: the last Trash report, Review, or why
    /// there's no Review.
    private var header: some View {
        HStack(spacing: Deck.Metric.gap) {
            DeckSegmented([StorageFeature.Mode.xcode, .disk], selection: storage.mode, title: Self.title) {
                storage.mode = $0
            }
            Spacer(minLength: 0)
            if let report = storage.report {
                ReportLine(report: report, dismiss: storage.dismissReport)
            } else {
                selectionSummary
            }
        }
    }

    private static func title(_ mode: StorageFeature.Mode) -> String { mode == .xcode ? "Xcode" : "Home" }

    @ViewBuilder private var selectionSummary: some View {
        switch storage.mode {
        case .xcode:
            if storage.xcode.value?.isEmpty == false {
                if storage.xcodeBusy {
                    Text("Quit Xcode to clean").deckText(.detail, color: Deck.signal)
                } else {
                    let bytes = storage.xcodeBytes(selectedOnly: true)
                    Button("Review \(StorageFormat.bytes(bytes))") { storage.reviewXcode() }
                        .buttonStyle(.deck(.primary))
                        .disabled(storage.xcodeSelection.isEmpty)
                }
            }
        case .disk:
            if !storage.diskSelection.isEmpty {
                Button("Review \(StorageFormat.bytes(storage.diskSelectedBytes))") { storage.reviewDisk() }
                    .buttonStyle(.deck(.primary))
            }
        }
    }
}

enum StorageFormat {
    static func bytes(_ bytes: Int64) -> String { max(0, bytes).formatted(.byteCount(style: .file)) }

    /// The path from the home folder, as "~/…".
    static func path(_ path: String, home: String) -> String {
        path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}

/// A start button in the middle of an empty tab.
private struct ScanPrompt: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .buttonStyle(.deck())
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SizeText: View {
    let bytes: Int64

    var body: some View {
        Text(StorageFormat.bytes(bytes)).deckText(.detail).lineLimit(1).fixedSize()
    }
}

/// Xcode's items by category, each category with its total and a tick for all of it.
private struct XcodeList: View {
    let storage: StorageFeature

    var body: some View {
        switch storage.xcode {
        case .idle:
            ScanPrompt(title: "Scan Xcode") { _ = storage.scanXcode() }
        case .scanning:
            ProgressView().controlSize(.small)
        case .done(let items) where items.isEmpty:
            VStack(spacing: Deck.Metric.gap) {
                DeckEmptyLine("Nothing to clean")
                Button("Scan Again") { _ = storage.scanXcode() }.buttonStyle(.deck(.outline))
            }
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
            }
            .fadingEdges(length: 6)
            .onAppear(perform: storage.refreshXcodeBusy)
        }
    }

    private func header(_ category: XcodeCategory, items: [XcodeItem]) -> some View {
        let ids = Set(items.map(\.id))
        let all = ids.isSubset(of: storage.xcodeSelection)
        return DeckRow {
            DeckCheckbox(ticked: all, label: "All of \(category.title)") {
                if all { storage.xcodeSelection.subtract(ids) } else { storage.xcodeSelection.formUnion(ids) }
            }
            Text(category.title).deckText(.item).lineLimit(1)
            Spacer(minLength: 6)
            SizeText(bytes: storage.xcodeBytes(category))
        }
    }

    private func row(_ item: XcodeItem) -> some View {
        let ticked = storage.xcodeSelection.contains(item.id)
        return DeckRow {
            DeckCheckbox(ticked: ticked, label: item.item.name) {
                if ticked { storage.xcodeSelection.remove(item.id) } else { storage.xcodeSelection.insert(item.id) }
            }
            Text(item.item.name).deckText(.body).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 6)
            SizeText(bytes: item.item.bytes)
        }
        .padding(.leading, 20)
    }
}

/// The home folder by size: a folder at a time, largest first, each folder opening to its own.
private struct DiskBrowser: View {
    let storage: StorageFeature

    var body: some View {
        switch storage.disk {
        case .idle:
            ScanPrompt(title: "Scan Home Folder") { _ = storage.scanDisk() }
        case .scanning:
            VStack(spacing: Deck.Metric.gap) {
                ProgressView().controlSize(.small)
                SizeText(bytes: storage.diskCounted)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Scanning, \(StorageFormat.bytes(storage.diskCounted)) so far")
        case .done:
            VStack(spacing: 2) {
                header
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(storage.diskItems) { row($0) }
                    }
                }
                .fadingEdges(length: 6)
            }
        }
    }

    private var header: some View {
        let atHome = storage.diskPath.count <= 1
        return HStack(spacing: 6) {
            Button {
                Task { await storage.goUp() }
            } label: {
                DeckIconView(.chevronRight).rotationEffect(.degrees(180))
            }
            .buttonStyle(.deckIcon())
            .disabled(atHome)
            .accessibilityLabel("Back")
            Text(storage.diskPath.last.map { StorageFormat.path($0, home: storage.home) } ?? "~")
                .deckText(.item)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 6)
            SizeText(bytes: storage.currentFolder?.bytes ?? 0)
            Button("Scan Again") { _ = storage.scanDisk() }.buttonStyle(.deck(.outline, compact: true))
        }
        .padding(.horizontal, 4)
    }

    private func row(_ item: DiskItem) -> some View {
        let ticked = storage.diskSelection.contains(item.id)
        let largest = max(storage.diskItems.first?.bytes ?? 1, 1)
        return DeckRow {
            if storage.canRemove(item) {
                DeckCheckbox(ticked: ticked, label: item.name) {
                    if ticked { storage.diskSelection.remove(item.id) } else { storage.diskSelection.insert(item.id) }
                }
            } else {
                DeckIconView(.shield, size: 13)
                    .foregroundStyle(Deck.tertiary)
                    .frame(width: 24, height: 24)
                    .accessibilityElement()
                    .accessibilityLabel("Protected")
            }
            Button {
                if item.kind == .folder { Task { await storage.open(item.path) } }
            } label: {
                HStack(spacing: Deck.Metric.gap) {
                    Text(item.name).deckText(.body).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 6)
                    DeckBar(Double(max(item.bytes, 0)) / Double(largest))
                        .frame(width: 48)
                        .accessibilityHidden(true)
                    SizeText(bytes: item.bytes)
                    DeckIconView(.chevronRight, size: 13)
                        .foregroundStyle(Deck.tertiary)
                        .opacity(item.kind == .folder ? 1 : 0)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(item.name), \(StorageFormat.bytes(item.bytes))")
            .accessibilityHint(item.kind == .folder ? Text("Opens the folder") : Text(""))
        }
    }
}

/// Every item about to go to the Trash, with its size and the total, and Move to Trash.
private struct ReviewList: View {
    let storage: StorageFeature
    let review: TrashReview

    var body: some View {
        VStack(spacing: Deck.Metric.gap) {
            DeckCard(padding: 6) {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(review.items) { item in
                            DeckRow {
                                Text(StorageFormat.path(item.path, home: storage.home))
                                    .deckText(.body)
                                    .lineLimit(1)
                                    .truncationMode(.head)
                                Spacer(minLength: 6)
                                SizeText(bytes: item.bytes)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
                .fadingEdges(length: 6)
            }
            HStack(spacing: Deck.Metric.gap) {
                Text("^[\(review.items.count) item](inflect: true), \(StorageFormat.bytes(review.totalBytes))")
                    .deckText(.item)
                Spacer(minLength: 0)
                if storage.trashing {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Cancel", action: storage.cancelReview).buttonStyle(.deck())
                    Button {
                        Task { await storage.confirmTrash() }
                    } label: {
                        Text("Move to Trash").foregroundStyle(Deck.stop)
                    }
                    .buttonStyle(.deck(.outline))
                }
            }
        }
    }
}

/// What the last Move to Trash did.
private struct ReportLine: View {
    let report: TrashReport
    let dismiss: () -> Void

    var body: some View {
        Button(action: dismiss) {
            HStack(spacing: 6) {
                if report.kept > 0 {
                    DeckDot(.signal)
                    Text("^[\(report.kept) item](inflect: true) kept").deckText(.detail, color: Deck.signal)
                } else {
                    DeckIconView(.trash, size: 13)
                    Text("\(StorageFormat.bytes(report.trashedBytes)) in the Trash").deckText(.detail)
                }
            }
            .foregroundStyle(Deck.secondary)
            .frame(minHeight: Deck.Metric.buttonHeight)
            .contentShape(Rectangle())
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
