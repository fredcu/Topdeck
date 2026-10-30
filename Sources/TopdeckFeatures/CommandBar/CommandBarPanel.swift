// SPDX-License-Identifier: MIT
// Adapted from OmniMac's CommandBarPanel (MIT), Copyright (c) 2026 Sergi (BySergiMM); see THIRD_PARTY_NOTICES.md.
import AppKit
import Observation
import SwiftUI

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
        field.placeholderString = "Search apps and actions"
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 19)
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
        DispatchQueue.main.async { window.makeFirstResponder(self) }
    }
}

struct CommandBarView: View {
    static let width: CGFloat = 560
    static let fieldHeight: CGFloat = 60
    static let rowHeight: CGFloat = 46
    static let maxRows = 8

    let model: CommandBarModel

    var body: some View {
        let search = model.search
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                SearchField(model: model)
            }
            .padding(.horizontal, 18)
            .frame(height: Self.fieldHeight)
            if !search.results.isEmpty {
                Divider()
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
                        .padding(.vertical, 4)
                    }
                    .onChange(of: search.selection) { _, row in proxy.scrollTo(row) }
                }
            } else if !search.query.isEmpty {
                Divider()
                Text("Nothing matches")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
        }
        .frame(width: Self.width)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.12)))
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// The window's height for `rows` results.
    static func height(rows: Int, hasQuery: Bool) -> CGFloat {
        let list = rows > 0 ? CGFloat(min(maxRows, rows)) * rowHeight + 8 : (hasQuery ? 44 : 0)
        return fieldHeight + list + (list > 0 ? 1 : 0)
    }
}

private struct CommandRow: View {
    let action: CommandAction
    let selected: Bool

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: action.symbol)
                .font(.system(size: 14))
                .frame(width: 22)
                .foregroundStyle(selected ? Color.white : Color.secondary)
                .accessibilityHidden(true)
            Text(action.title)
                .lineLimit(1)
                .foregroundStyle(selected ? Color.white : Color.primary)
            Spacer(minLength: 8)
            Text(action.area)
                .font(.caption)
                .lineLimit(1)
                .foregroundStyle(selected ? Color.white.opacity(0.75) : Color.secondary)
        }
        .padding(.horizontal, 14)
        .frame(height: CommandBarView.rowHeight)
        .background(selected ? Color.accentColor : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, 6)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
