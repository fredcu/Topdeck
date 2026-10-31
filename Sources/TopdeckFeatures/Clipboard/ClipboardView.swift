// SPDX-License-Identifier: MIT
import AppKit
import SwiftUI
import TopdeckSurface

/// The clipboard tab: the history on the left, the chosen item on the right. Paste puts it back on the
/// clipboard and pastes it; Plain does the same without formatting; the pin keeps it first. Double-click
/// or Return in the search does what picking does by default. Select mode ticks items to delete
/// together, and Clear deletes all but favorites.
struct ClipboardView: View {
    let clipboard: ClipboardFeature
    /// The item the card shows; the first match until one is clicked.
    @State private var chosen: ClipItem.ID?
    /// Clicking a row ticks it instead of choosing it.
    @State private var selecting = false
    @State private var selected: Set<ClipItem.ID> = []
    /// Clear asks once more, until the pointer leaves it.
    @State private var confirmingClear = false

    var body: some View {
        if !clipboard.isRecording {
            DeckCard {
                VStack(spacing: Deck.Metric.gap) {
                    Text("Keep what you copy").deckText(.item)
                    Button("Turn On", action: clipboard.startRecording).buttonStyle(.deck(.primary))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else if clipboard.access == .asks || clipboard.access == .denied {
            DeckCard {
                VStack(spacing: Deck.Metric.gap) {
                    Text("Allow Topdeck to read what you copy").deckText(.item)
                    Button("Open Privacy Settings") {
                        NSWorkspace.shared.open(.privacySettings("Privacy_Pasteboard"))
                    }
                    .buttonStyle(.deck(.primary))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .onAppear(perform: clipboard.refreshAccess)
        } else {
            history.onAppear(perform: clipboard.refreshAccess)
        }
    }

    private var history: some View {
        let found = clipboard.search(clipboard.query)
        let shown = found.first { $0.id == chosen } ?? found.first
        return Group {
            if found.isEmpty {
                DeckEmptyLine(clipboard.items.isEmpty ? "Nothing copied yet" : "No matches")
            } else {
                DeckWeightedRow([1.1, 1]) {
                    VStack(spacing: 0) {
                        ScrollView {
                            LazyVStack(spacing: 2) {
                                ForEach(found) { row($0, shown: shown, found: found) }
                            }
                        }
                        footer(found)
                    }
                    if let shown { detail(shown) }
                }
            }
        }
        .onChange(of: clipboard.query) { chosen = nil }
    }

    // MARK: Rows

    private func row(_ item: ClipItem, shown: ClipItem?, found: [ClipItem]) -> some View {
        let ticked = selected.contains(item.id)
        return DeckRow(
            selected: selecting ? ticked : item.id == shown?.id,
            action: {
                if selecting {
                    if ticked { selected.remove(item.id) } else { selected.insert(item.id) }
                } else {
                    chosen = item.id
                }
            }
        ) {
            if selecting {
                DeckIconView(ticked ? .check : .app).foregroundStyle(ticked ? Deck.text : Deck.tertiary)
            } else {
                DeckIconView(item.favorite ? .pin : icon(item.kind))
                    .foregroundStyle(item.favorite ? Deck.signal : Deck.tertiary)
            }
            Text(title(item)).deckText(.body).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
            Text(item.favorite ? "Pinned" : Self.age(of: item.copied)).deckText(.caption).lineLimit(1)
        }
        .simultaneousGesture(TapGesture(count: 2).onEnded { if !selecting { pick(item) } })
        .help(selecting ? (ticked ? "Deselect" : "Select") : clipboard.pastesAfterPicking ? "Paste" : "Copy again")
        .contextMenu {
            Button("Copy") { clipboard.pick(item, paste: false) }
            Button("Paste") { clipboard.pick(item, plainText: false, paste: true) }
            if item.rich != nil {
                Button("Paste as Plain Text") { clipboard.pick(item, plainText: true, paste: true) }
            }
            Button(item.favorite ? "Remove from Favorites" : "Add to Favorites") { clipboard.toggleFavorite(item) }
            Divider()
            Button("Delete") { delete(item) }
        }
        .accessibilityAction(named: "Delete") { delete(item) }
    }

    /// How many are ticked or there are, with Select and Clear; while selecting, Select All, Delete and Done.
    private func footer(_ found: [ClipItem]) -> some View {
        let keptByClear = clipboard.items.count { !$0.favorite }
        let allTicked = !found.isEmpty && found.allSatisfy { selected.contains($0.id) }
        return HStack(spacing: 6) {
            Group {
                if selecting {
                    Text("\(selected.count) selected")
                } else {
                    Text("^[\(clipboard.items.count) item](inflect: true)")
                }
            }
            .deckText(.caption)
            .padding(.leading, 10)
            Spacer(minLength: 0)
            if selecting {
                Button(allTicked ? "Select None" : "Select All") { selected = allTicked ? [] : Set(found.map(\.id)) }
                    .buttonStyle(.deck(compact: true))
                Button("Delete") {
                    clipboard.remove(selected)
                    selected = []
                    if clipboard.items.isEmpty { selecting = false }
                }
                .buttonStyle(.deck(compact: true))
                .foregroundStyle(Deck.stop)
                .disabled(selected.isEmpty)
                .help("Delete the selected items, favorites too")
                Button("Done") {
                    selecting = false
                    selected = []
                }
                .buttonStyle(.deck(compact: true))
            } else {
                Button("Select") {
                    confirmingClear = false
                    selecting = true
                }
                .buttonStyle(.deck(compact: true))
                .help("Select items to delete")
                Button(confirmingClear ? "Clear ^[\(keptByClear) item](inflect: true)?" : "Clear") {
                    if confirmingClear {
                        clipboard.clear()
                        confirmingClear = false
                    } else {
                        confirmingClear = true
                    }
                }
                .buttonStyle(.deck(compact: true))
                .foregroundStyle(confirmingClear ? Deck.stop : Deck.text)
                .disabled(keptByClear == 0)
                .onHover { if !$0 { confirmingClear = false } }
                .help(keptByClear == 0 ? "Only favorites are left" : "Delete everything but favorites")
            }
        }
        .frame(height: 28)
        .padding(.trailing, 28)  // clear of the resize grip in the deck's corner
    }

    // MARK: Detail

    private func detail(_ item: ClipItem) -> some View {
        DeckCard {
            VStack(alignment: .leading, spacing: Deck.Metric.gap) {
                VStack(alignment: .leading, spacing: 8) {
                    if let host = Self.host(of: item) { Text(host).deckText(.item).lineLimit(1) }
                    content(item)
                }
                Spacer(minLength: 0)
                if let source = item.source { Text(source).deckText(.caption).lineLimit(1) }
                HStack(spacing: 8) {
                    Button("Paste") { clipboard.pick(item, paste: true) }
                        .buttonStyle(.deck(.primary, fill: true))
                    Button("Plain") { clipboard.pick(item, plainText: true, paste: true) }
                        .buttonStyle(.deck())
                    DeckIconButton(
                        .pin, label: item.favorite ? "Remove from Favorites" : "Add to Favorites", on: item.favorite
                    ) {
                        clipboard.toggleFavorite(item)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder private func content(_ item: ClipItem) -> some View {
        switch item.kind {
        case .image:
            if let image = clipboard.image(for: item) {
                Image(nsImage: image).resizable().scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: Deck.Radius.control, style: .continuous))
                    .frame(maxWidth: .infinity, maxHeight: 120, alignment: .leading)
            }
        case .files:
            Text(item.paths.map { URL(filePath: $0).lastPathComponent }.joined(separator: "\n"))
                .deckText(.body).lineLimit(5).truncationMode(.middle)
        case .link:
            Text(item.text).deckText(.command).lineSpacing(3).lineLimit(5).truncationMode(.middle)
        case .text:
            Text(item.text).deckText(.body).lineSpacing(2).lineLimit(6).truncationMode(.tail)
        }
    }

    // MARK: Helpers

    /// Option leaves the formatting behind, whatever the setting.
    private func pick(_ item: ClipItem) {
        clipboard.pick(item, plainText: NSEvent.modifierFlags.contains(.option) ? true : nil)
    }

    private func delete(_ item: ClipItem) {
        clipboard.remove(item)
        selected.remove(item.id)
    }

    private func icon(_ kind: ClipItem.Kind) -> DeckIcon {
        switch kind {
        case .text: .note
        case .link: .link
        case .image: .image
        case .files: .file
        }
    }

    private func title(_ item: ClipItem) -> String {
        switch item.kind {
        case .files:
            let names = item.paths.map { URL(filePath: $0).lastPathComponent }
            return names.count == 1 ? names[0] : "\(names[0]) and \(names.count - 1) more"
        default:
            return item.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? item.text
        }
    }

    /// The site of a link, without "www.".
    static func host(of item: ClipItem) -> String? {
        guard item.kind == .link, let host = URL(string: item.text.trimmingCharacters(in: .whitespaces))?.host()
        else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// How long ago, in a word or two: "Now", "2m", "3h", "Yesterday", then the date.
    static func age(of date: Date, at now: Date = .now, calendar: Calendar = .current) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "Now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if calendar.isDate(date, inSameDayAs: now) { return "\(Int(seconds / 3600))h" }
        if calendar.isDate(date, inSameDayAs: calendar.date(byAdding: .day, value: -1, to: now) ?? now) {
            return "Yesterday"
        }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}

/// The deck's second-row search field, once the history can be searched.
struct ClipboardSearch: View {
    let clipboard: ClipboardFeature

    var body: some View {
        if clipboard.showsHistory {
            let bindable = Bindable(clipboard)
            DeckSearchField(
                "Search", text: bindable.query, takeFocus: bindable.wantsSearch,
                submit: { if let first = clipboard.search(clipboard.query).first { clipboard.pick(first) } })
        }
    }
}
