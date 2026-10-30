// SPDX-License-Identifier: MIT

/// A card on Now.
public enum NowCard: CaseIterable, Hashable, Sendable {
    /// What's playing.
    case media
    /// The oldest agent waiting for an answer.
    case agent
    /// The next calendar event and the first task.
    case event
    /// The timer and Keep Awake, side by side.
    case timers
}

/// Which cards Now shows and how they're arranged. A card appears only when it has something, and an
/// empty slot closes up, so with nothing to show Now is only the date and clock. Pure, so it's
/// tested without any UI.
public struct NowLayout: Equatable, Sendable {
    /// Rows of one or two cards, in order. A row of one card fills the width.
    public let rows: [[NowCard]]

    /// What each slot has.
    public init(media: Bool, agent: Bool, event: Bool, task: Bool, timer: Bool, awake: Bool) {
        let present: [NowCard] = [
            media ? .media : nil, agent ? .agent : nil, event || task ? .event : nil, timer || awake ? .timers : nil,
        ].compactMap { $0 }
        rows = stride(from: 0, to: present.count, by: 2).map { Array(present[$0..<min($0 + 2, present.count)]) }
    }

    /// Nothing to show: Now draws the date and clock.
    public var isEmpty: Bool { rows.isEmpty }
}
