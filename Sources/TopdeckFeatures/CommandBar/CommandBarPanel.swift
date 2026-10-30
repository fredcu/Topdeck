// SPDX-License-Identifier: MIT
// Adapted from OmniMac's CommandBarPanel (MIT), Copyright (c) 2026 Sergi (BySergiMM); see THIRD_PARTY_NOTICES.md.
import AppKit
import Observation
import SwiftUI
import TopdeckSurface

/// The bar's state, shared by its window and its view.
@MainActor
@Observable
final class CommandBarModel {
    var search = CommandSearch() {
        didSet { if search.results.count != oldValue.results.count { onResize?(search.results.count) } }
    }
    /// Raised with the number of rows, so the window can grow and shrink.
    @ObservationIgnored var onResize: ((Int) -> Void)?
    @ObservationIgnored var onRun: ((CommandAction) -> Void)?
    @ObservationIgnored var onClose: (() -> Void)?
}

/// A panel with no title bar that takes the keyboard without activating Topdeck, as pinned notes
/// do, so the app that was in front stays in front and keeps its window.
final class CommandBarWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isFloatingPanel = true
        animationBehavior = .utilityWindow
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        level = .popUpMenu  // after isFloatingPanel, which resets it
    }
}

/// The search field. It's a real text field, so the system's input methods compose in it:
/// Chinese, Japanese, dead keys. Keys the list needs are caught in `doCommandBy`.
private struct SearchField: NSViewRepresentable {
    let model: CommandBarModel

    func makeNSView(context: Context) -> FocusingTextField {
        let field = FocusingTextField()
        field.delegate = context.coordinator
        field.stringValue = model.search.query
        field.placeholderAttributedString = NSAttributedString(
            string: "Search apps and actions",
            attributes: [.foregroundColor: NSColor(Deck.tertiary), .font: NSFont.systemFont(ofSize: 20)])
        field.textColor = NSColor(Deck.text)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 20)
        field.cell?.usesSingleLineMode = true
        return field
    }

    func updateNSView(_ field: FocusingTextField, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        let model: CommandBarModel

        init(model: CommandBarModel) { self.model = model }

        func controlTextDidChange(_ notification: Notification) {
            guard let editor = (notification.object as? NSTextField)?.currentEditor() as? NSTextView else { return }
            // Pinyin still being composed is not a search yet.
            MainActor.assumeIsolated {
                model.search.setQuery(CommandSearch.committedText(editor.string, marked: editor.markedRange()))
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            // While an input method composes, Return and Escape belong to it.
            if textView.hasMarkedText() { return false }
            return MainActor.assumeIsolated {
                switch selector {
                case #selector(NSResponder.insertNewline(_:)),
                    #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                    if let action = model.search.actionToRun(hasMarkedText: textView.hasMarkedText()) {
                        model.onRun?(action)
                    }
                case #selector(NSResponder.cancelOperation(_:)): model.onClose?()
                case #selector(NSResponder.moveDown(_:)): model.search.move(by: 1)
                case #selector(NSResponder.moveUp(_:)): model.search.move(by: -1)
                default: return false
                }
                return true
            }
        }
    }
}

/// Takes the keyboard as soon as it is on screen.
private final class FocusingTextField: NSTextField {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            window.makeFirstResponder(self)
            (currentEditor() as? NSTextView)?.insertionPointColor = NSColor(Deck.signal)
        }
    }
}

struct CommandBarView: View {
    static let width: CGFloat = 640
    static let fieldHeight: CGFloat = 60
    static let rowHeight: CGFloat = 46
    static let listPadding: CGFloat = 6
    static let footerHeight: CGFloat = 38
    static let maxRows = 8

    let model: CommandBarModel

    var body: some View {
        let search = model.search
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                DeckIconView(.search, size: 20).foregroundStyle(Deck.tertiary)
                SearchField(model: model)
            }
            .padding(.horizontal, 20)
            .frame(height: Self.fieldHeight)
            if !search.results.isEmpty {
                DeckSeparator()
                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: false) {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(search.results.enumerated()), id: \.element.id) { index, action in
                                CommandRow(action: action, selected: index == search.selection)
                                    .id(index)
                                    .contentShape(Rectangle())
                                    .onTapGesture { model.onRun?(action) }
                            }
                        }
                        .padding(Self.listPadding)
                    }
                    .onChange(of: search.selection) { _, row in proxy.scrollTo(row) }
                }
                footer(count: search.results.count)
            } else if !search.query.isEmpty {
                DeckSeparator()
                Text("Nothing matches")
                    .deckText(.body, color: Deck.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
        }
        .frame(width: Self.width)
        .background(Deck.Floating.panel)
        .clipShape(RoundedRectangle(cornerRadius: Deck.Floating.barRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Deck.Floating.barRadius, style: .continuous)
                .strokeBorder(Deck.hairline, lineWidth: 1)
        )
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func footer(count: Int) -> some View {
        HStack {
            Text(count == 1 ? "1 result" : "\(count) results").deckText(.caption)
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                Text("Run").deckText(.detail)
                DeckKeyCap("\u{21A9}")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: Self.footerHeight)
        .background(Deck.Floating.panelFooter)
        .accessibilityElement(children: .combine)
    }

    /// The window's height for `rows` results.
    static func height(rows: Int, hasQuery: Bool) -> CGFloat {
        guard rows > 0 else { return fieldHeight + (hasQuery ? 45 : 0) }
        return fieldHeight + 1 + CGFloat(min(maxRows, rows)) * rowHeight + listPadding * 2 + footerHeight
    }
}

private struct CommandRow: View {
    let action: CommandAction
    let selected: Bool

    var body: some View {
        HStack(spacing: 12) {
            CommandIcon(action: action)
            Text(action.title)
                .deckText(selected ? .item : .body)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(action.area).deckText(.caption).lineLimit(1)
            if selected, let shortcut = action.shortcut { DeckKeyCap(shortcut) }
        }
        .padding(.horizontal, 12)
        .frame(height: CommandBarView.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: Deck.Radius.control, style: .continuous)
                .fill(selected ? Deck.control : .clear)
        )
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// An action's icon: an app's own icon, or the deck's icon for it on a tile.
private struct CommandIcon: View {
    let action: CommandAction

    var body: some View {
        if action.isApp {
            Image(nsImage: NSWorkspace.shared.icon(forFile: String(action.id.dropFirst(CommandAction.appPrefix.count))))
                .resizable()
                .interpolation(.high)
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
        } else {
            Group {
                if let icon = DeckIcon.matching(commandSymbol: action.symbol) {
                    DeckIconView(icon)
                } else {
                    Image(systemName: action.symbol).font(.system(size: 13)).accessibilityHidden(true)
                }
            }
            .foregroundStyle(Deck.text)
            .frame(width: 28, height: 28)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Deck.control))
        }
    }
}

extension DeckIcon {
    /// The deck's icon for the SF Symbol a command names, where it has one.
    static func matching(commandSymbol symbol: String) -> DeckIcon? {
        if symbol.hasSuffix(".calendar") { return .calendar }
        switch symbol {
        case "play.circle": return .play
        case "speaker.wave.2": return .volume
        case "tray.full", "square.2.layers.3d": return .stack
        case "list.clipboard": return .copy
        case "camera.viewfinder": return .capture
        case "calendar": return .calendar
        case "checklist": return .check
        case "note.text": return .note
        case "timer": return .clock
        case "internaldrive": return .disk
        case "arrow.up.arrow.down.circle": return .network
        case "gauge.with.needle", "cpu": return .cpu
        case "apple.terminal": return .terminal
        case "gearshape", "gearshape.2": return .gear
        case "display", "display.2": return .display
        case "scroll": return .scrollingCapture
        case "text.viewfinder": return .recognizeText
        case "qrcode.viewfinder": return .qrCode
        case "eyedropper": return .colorPicker
        case "pin": return .pin
        case "rectangle.split.2x1": return .markupRectangle
        case "rectangle.3.group", "rectangle.topthird.inset.filled": return .grid
        case "cup.and.saucer": return .bolt
        default: return nil
        }
    }
}
