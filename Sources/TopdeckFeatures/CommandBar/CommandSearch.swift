// SPDX-License-Identifier: MIT
// Adapted from OmniMac's CommandBarFeature (MIT), Copyright (c) 2026 Sergi (BySergiMM); see THIRD_PARTY_NOTICES.md.
import Foundation

/// One thing the command bar can do. Features hand these in from `AppDelegate`, so the bar knows
/// nothing about them.
public struct CommandAction: Identifiable {
    public let id: String
    public let title: String
    /// Where it comes from, shown beside the title and searched too: "Windows", "Settings".
    public let area: String
    public let symbol: String
    /// More words that find it.
    public let keywords: String
    public let run: @MainActor () -> Void

    public init(
        id: String, title: String, area: String, symbol: String, keywords: String = "",
        run: @escaping @MainActor () -> Void
    ) {
        self.id = id
        self.title = title
        self.area = area
        self.symbol = symbol
        self.keywords = keywords
        self.run = run
    }

    static let appPrefix = "app:"
    var isApp: Bool { id.hasPrefix(Self.appPrefix) }
    var searchable: String { "\(title) \(area) \(keywords)" }
}

/// What the bar shows for what's typed: the ranked list and the highlighted row. No AppKit.
struct CommandSearch {
    /// An action ranks a little above an app with the same match.
    static let actionBonus = 6
    static let limit = 12

    private(set) var items: [CommandAction] = []
    private(set) var query = ""
    private(set) var results: [CommandAction] = []
    private(set) var selection = 0

    mutating func setItems(_ items: [CommandAction]) {
        self.items = items
        refresh()
    }

    /// Apps arrive after the bar opens, since listing the folders takes a while.
    mutating func add(_ more: [CommandAction]) {
        items += more
        refresh(keepingSelection: true)
    }

    mutating func setQuery(_ text: String) {
        guard text != query else { return }
        query = text
        refresh()
    }

    mutating func move(by step: Int) {
        guard !results.isEmpty else { return }
        selection = min(max(selection + step, 0), results.count - 1)
    }

    /// The row Return runs, nil while an input method is composing: Return then confirms the
    /// composition, and nothing may run.
    func actionToRun(hasMarkedText: Bool) -> CommandAction? {
        guard !hasMarkedText, results.indices.contains(selection) else { return nil }
        return results[selection]
    }

    /// The typed text without the part an input method is still composing.
    static func committedText(_ full: String, marked: NSRange) -> String {
        let text = full as NSString
        guard marked.location != NSNotFound, NSMaxRange(marked) <= text.length else { return full }
        return text.replacingCharacters(in: marked, with: "")
    }

    private mutating func refresh(keepingSelection: Bool = false) {
        let typed = query.trimmingCharacters(in: .whitespaces)
        let previous = results.indices.contains(selection) ? results[selection].id : nil
        if typed.isEmpty {
            // Nothing typed: the actions in the order they were registered, not 300 apps.
            results = items.filter { !$0.isApp }
        } else {
            results = CommandMatcher.rank(
                items, query: typed, limit: Self.limit, bonus: { $0.isApp ? 0 : Self.actionBonus }, name: \.searchable)
        }
        selection = keepingSelection ? results.firstIndex { $0.id == previous } ?? 0 : 0
    }
}
