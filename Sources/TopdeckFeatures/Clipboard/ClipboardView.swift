// SPDX-License-Identifier: MIT
import AppKit
import SwiftUI
import TopdeckSurface

/// The clipboard space: search and the history on the left, the chosen item large on the right. Paste
/// puts it back on the clipboard and pastes it. Up and Down move through the list, Return pastes, and
/// typing goes to the search. Select mode ticks items to delete together, and Clear deletes all but
/// favorites; both, and the settings that have no place on the board, are in the second row's menu.
struct ClipboardView: View {
    let clipboard: ClipboardFeature
    @FocusState private var focused: Bool

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
        let found = clipboard.search(clipboard.query, filter: clipboard.filter)
        let shown = found.first { $0.id == clipboard.chosen } ?? found.first
        return Group {
            if clipboard.items.isEmpty {
                DeckEmptyLine("Nothing copied yet")
            } else {
                HStack(alignment: .top, spacing: Deck.Metric.gap) {
                    VStack(spacing: 6) {
                        search(found, shown)
                        if found.isEmpty {
                            Spacer(minLength: 0)
                        } else {
                            ScrollViewReader { proxy in
                                ScrollView {
                                    LazyVStack(spacing: 0) {
                                        ForEach(found) { ClipboardRow(clipboard: clipboard, item: $0, shown: shown) }
                                    }
                                }
                                .onChange(of: shown?.id) { _, id in if let id { proxy.scrollTo(id) } }
                            }
                            footer(found)
                        }
                    }
                    .frame(width: 296)
                    Rectangle().fill(Deck.hairline).frame(width: 1)
                    if let shown {
                        ClipboardPreview(clipboard: clipboard, item: shown)
                    } else {
                        DeckEmptyLine(emptyLine)
                    }
                }
            }
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear { if !clipboard.wantsSearch { focused = true } }
        .onKeyPress(.upArrow) { move(-1, in: found, from: shown) }
        .onKeyPress(.downArrow) { move(1, in: found, from: shown) }
        .onKeyPress(.return) {
            guard let shown else { return .ignored }
            clipboard.pick(shown, paste: true)
            return .handled
        }
        .onKeyPress(phases: .down) { press in type(press) }
        .onChange(of: clipboard.query) { clipboard.chosen = nil }
        .onChange(of: clipboard.filter) { clipboard.chosen = nil }
    }

    private var emptyLine: String {
        clipboard.query.isEmpty ? "No \(clipboard.filter.title.lowercased())" : "No matches"
    }

    private func search(_ found: [ClipItem], _ shown: ClipItem?) -> some View {
        let bindable = Bindable(clipboard)
        return DeckSearchField(
            "Search", text: bindable.query, width: 296, takeFocus: bindable.wantsSearch,
            submit: { if let shown { clipboard.pick(shown) } })
    }

    /// Up or Down: the next item in the list, stopping at its ends.
    private func move(_ step: Int, in found: [ClipItem], from shown: ClipItem?) -> KeyPress.Result {
        guard let shown, let index = found.firstIndex(where: { $0.id == shown.id }) else { return .ignored }
        clipboard.chosen = found[min(max(index + step, 0), found.count - 1)].id
        return .handled
    }

    /// A key that types a character, pressed with the list in front: it goes to the search.
    private func type(_ press: KeyPress) -> KeyPress.Result {
        let characters = press.characters
        guard focused, press.modifiers.isDisjoint(with: [.command, .control, .option]), !characters.isEmpty,
            characters.unicodeScalars.allSatisfy({
                !CharacterSet.controlCharacters.contains($0) && $0.properties.generalCategory != .privateUse
            })
        else { return .ignored }
        clipboard.query += characters
        clipboard.wantsSearch = true
        return .handled
    }

    /// Under the list, only while it is needed: what is ticked and what to do with it, or Clear's go-ahead.
    @ViewBuilder private func footer(_ found: [ClipItem]) -> some View {
        let keptByClear = clipboard.items.count { !$0.favorite }
        let allTicked = !found.isEmpty && found.allSatisfy { clipboard.ticked.contains($0.id) }
        if clipboard.isSelecting {
            HStack(spacing: 6) {
                Text("\(clipboard.ticked.count) selected").deckText(.caption).padding(.leading, 10)
                Spacer(minLength: 0)
                Button(allTicked ? "Select None" : "Select All") {
                    clipboard.ticked = allTicked ? [] : Set(found.map(\.id))
                }
                .buttonStyle(.deck(compact: true))
                Button("Delete") { clipboard.removeTicked() }
                    .buttonStyle(.deck(compact: true))
                    .foregroundStyle(Deck.stop)
                    .disabled(clipboard.ticked.isEmpty)
                    .help("Delete the selected items, favorites too")
                Button("Done") { clipboard.finishSelecting() }
                    .buttonStyle(.deck(compact: true))
            }
            .frame(height: 28)
        } else if clipboard.isConfirmingClear {
            HStack(spacing: 6) {
                Text("Clear ^[\(keptByClear) item](inflect: true)?").deckText(.caption).padding(.leading, 10)
                Spacer(minLength: 0)
                Button("Clear") {
                    clipboard.clear()
                    clipboard.isConfirmingClear = false
                }
                .buttonStyle(.deck(compact: true))
                .foregroundStyle(Deck.stop)
                Button("Cancel") { clipboard.isConfirmingClear = false }
                    .buttonStyle(.deck(compact: true))
            }
            .frame(height: 28)
        }
    }
}

// MARK: Rows

private struct ClipboardRow: View {
    let clipboard: ClipboardFeature
    let item: ClipItem
    let shown: ClipItem?
    @Environment(\.deckAccent) private var accent

    var body: some View {
        let ticked = clipboard.ticked.contains(item.id)
        let selected = clipboard.isSelecting ? ticked : item.id == shown?.id
        Button {
            if clipboard.isSelecting {
                if ticked { clipboard.ticked.remove(item.id) } else { clipboard.ticked.insert(item.id) }
            } else {
                clipboard.chosen = item.id
            }
        } label: {
            HStack(spacing: 9) {
                leading(ticked: ticked)
                VStack(alignment: .leading, spacing: 0) {
                    Text(ClipboardView.title(of: item)).deckText(.body).lineLimit(1).truncationMode(.middle)
                    Text(ClipboardView.subtitle(of: item)).deckText(.caption).lineLimit(1)
                }
                Spacer(minLength: 0)
                if item.favorite { DeckIconView(.star, size: 12).foregroundStyle(accent) }
            }
            .padding(.horizontal, 8)
            .frame(height: 44)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(selected ? accent.tint(0.16) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .simultaneousGesture(TapGesture(count: 2).onEnded { if !clipboard.isSelecting { pick() } })
        .help(clipboard.pastesAfterPicking ? "Paste" : "Copy again")
        .id(item.id)
        .contextMenu {
            Button("Copy") { clipboard.pick(item, paste: false) }
            Button("Paste") { clipboard.pick(item, plainText: false, paste: true) }
            if item.rich != nil {
                Button("Paste as Plain Text") { clipboard.pick(item, plainText: true, paste: true) }
            }
            Button(item.favorite ? "Remove from Favorites" : "Add to Favorites") { clipboard.toggleFavorite(item) }
            Divider()
            Button("Delete") { clipboard.remove(item) }
        }
        .accessibilityAction(named: "Delete") { clipboard.remove(item) }
    }

    /// A picture shows itself; the rest show their kind.
    @ViewBuilder private func leading(ticked: Bool) -> some View {
        if clipboard.isSelecting {
            DeckIconView(ticked ? .check : .app).foregroundStyle(ticked ? Deck.text : Deck.tertiary)
                .frame(width: 26, height: 26)
        } else if item.kind == .image, let thumbnail = clipboard.thumbnail(for: item, side: 104) {
            Image(nsImage: thumbnail).resizable().scaledToFill()
                .frame(width: 26, height: 26)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            let tint = tint(of: item.kind)
            DeckIconView(icon(item.kind), size: 15).foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint.tint(0.2)))
        }
    }

    /// Default-picks the item, as double-click does. Option leaves the formatting behind.
    private func pick() {
        clipboard.pick(item, plainText: NSEvent.modifierFlags.contains(.option) ? true : nil)
    }

    private func icon(_ kind: ClipItem.Kind) -> DeckIcon {
        switch kind {
        case .text: .note
        case .link: .link
        case .image: .image
        case .files: .file
        }
    }

    private func tint(of kind: ClipItem.Kind) -> Color {
        switch kind {
        case .text: Deck.secondary
        case .link: Deck.Accent.now
        case .image: accent
        case .files: Deck.Accent.tools
        }
    }
}

// MARK: Preview

/// The chosen item large, with what it is, where it came from, a favorite button and Paste.
private struct ClipboardPreview: View {
    let clipboard: ClipboardFeature
    let item: ClipItem

    var body: some View {
        VStack(spacing: 8) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: Deck.Radius.tile, style: .continuous).fill(Deck.cardRaised))
                .clipShape(RoundedRectangle(cornerRadius: Deck.Radius.tile, style: .continuous))
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(ClipboardView.facts(of: item)).deckText(.figure).lineLimit(1)
                    Text(ClipboardView.origin(of: item)).deckText(.caption).lineLimit(1)
                }
                Spacer(minLength: 0)
                DeckIconButton(
                    .star, label: item.favorite ? "Remove from Favorites" : "Add to Favorites", on: item.favorite
                ) {
                    clipboard.toggleFavorite(item)
                }
                Button("Paste") { clipboard.pick(item, paste: true) }.buttonStyle(.deck(.primary))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var content: some View {
        switch item.kind {
        case .image:
            if let image = clipboard.thumbnail(for: item, side: 1200) {
                Image(nsImage: image).resizable().scaledToFit().padding(8)
            }
        case .files:
            files
        case .link:
            VStack(alignment: .leading, spacing: 6) {
                if let host = ClipboardView.host(of: item) { Text(host).deckText(.item).lineLimit(1) }
                ScrollView {
                    Text(item.text).deckText(.command).lineSpacing(3).textSelection(.enabled).frame(
                        maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(12)
            .frame(maxHeight: .infinity, alignment: .top)
        case .text:
            ScrollView {
                Text(item.text).deckText(.body).lineSpacing(2).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
        }
    }

    private var files: some View {
        let paths = item.paths
        return VStack(spacing: 8) {
            if let first = paths.first {
                Image(nsImage: NSWorkspace.shared.icon(forFile: first)).resizable().frame(width: 56, height: 56)
            }
            Text(paths.map { URL(filePath: $0).lastPathComponent }.joined(separator: "\n"))
                .deckText(.body).multilineTextAlignment(.center).lineLimit(4).truncationMode(.middle)
        }
        .padding(12)
    }
}

// MARK: Second row

/// The second row's filters at its left.
struct ClipboardFilters: View {
    let clipboard: ClipboardFeature

    var body: some View {
        HStack(spacing: 5) {
            ForEach(ClipFilter.allCases, id: \.self) { filter in
                Button(filter.title) { clipboard.filter = filter }
                    .buttonStyle(.deckPill(on: clipboard.filter == filter))
                    .accessibilityAddTraits(clipboard.filter == filter ? .isSelected : [])
            }
        }
    }
}

/// The second row's menu: what the board has no place for.
struct ClipboardMenu: View {
    let clipboard: ClipboardFeature

    var body: some View {
        if clipboard.showsHistory {
            let bindable = Bindable(clipboard)
            Menu {
                Button(clipboard.isSelecting ? "Done Selecting" : "Select Items") {
                    clipboard.isConfirmingClear = false
                    if clipboard.isSelecting { clipboard.finishSelecting() } else { clipboard.isSelecting = true }
                }
                Button("Clear History\u{2026}") {
                    clipboard.finishSelecting()
                    clipboard.isConfirmingClear = true
                }
                .disabled(clipboard.items.allSatisfy(\.favorite))
                Divider()
                Toggle("Paste as Plain Text", isOn: bindable.pastesAsPlainText)
                Toggle("Remove Link Tracking", isOn: bindable.cleansLinks)
                Divider()
                Button("Stop Keeping History", action: clipboard.stopRecording)
            } label: {
                DeckIconView(.more)
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.deckIcon())
            .fixedSize()
            .help("More")
            .accessibilityLabel("More")
        }
    }
}

// MARK: Helpers

extension ClipboardView {
    static func title(of item: ClipItem) -> String {
        switch item.kind {
        case .files:
            let names = item.paths.map { URL(filePath: $0).lastPathComponent }
            return names.count == 1 ? names[0] : "\(names[0]) and \(names.count - 1) more"
        default:
            return item.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? item.text
        }
    }

    /// "Safari, 8m": where it was copied and how long ago.
    static func subtitle(of item: ClipItem, at now: Date = .now) -> String {
        [item.source, age(of: item.copied, at: now)].compactMap { $0 }.joined(separator: ", ")
    }

    /// "Safari, 8m ago" under the preview.
    static func origin(of item: ClipItem, at now: Date = .now) -> String {
        let when = age(of: item.copied, at: now)
        let recent = when.hasSuffix("m") || when.hasSuffix("h")
        let ago = when == "Now" ? "just now" : recent ? "\(when) ago" : when.lowercased()
        return [item.source, ago].compactMap { $0 }.joined(separator: ", ")
    }

    /// What the preview says it is: a picture's size, a file's size, a text's length.
    static func facts(of item: ClipItem) -> String {
        switch item.kind {
        case .image: return "\(item.text.replacingOccurrences(of: "Image ", with: "")), PNG"
        case .files:
            let paths = item.paths
            let bytes = paths.reduce(0) { total, path in
                let size = try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int
                return total + (size ?? 0)
            }
            let size = bytes.formatted(.byteCount(style: .file))
            return paths.count == 1 ? size : "\(paths.count) files, \(size)"
        case .link: return host(of: item) ?? "Link"
        case .text: return item.text.count == 1 ? "1 character" : "\(item.text.count.formatted()) characters"
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
