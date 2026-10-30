// SPDX-License-Identifier: MIT
// Adapted from OmniMac's CommandMatcher (MIT), Copyright (c) 2026 Sergi (BySergiMM); see THIRD_PARTY_NOTICES.md.
import Foundation

/// Matches what's typed against the names in the list.
///
/// It isn't a "contains" search: the letters are found in order, even when apart, so "slmi" finds
/// "Silence the microphone". Typing three letters and seeing the one you meant is what makes a command
/// bar feel quick.
///
/// A score rewards, in this order: the typed text appearing as it is, starting there, landing at the
/// start of a word, and letters that run together. Without the first, "mail" found "Make the Mac
/// awake" (m-a-i-l spread across the phrase) before the Mail app.
enum CommandMatcher {
    /// Scores a candidate, or nil when it doesn't match. An empty query matches everything with 0.
    static func score(_ candidate: String, query: String) -> Int? {
        let needle = normalize(query)
        guard !needle.isEmpty else { return 0 }
        let hay = Array(normalize(candidate))
        let pins = Array(needle)

        var total = 0
        var index = 0
        var previousMatch: Int?

        for pin in pins {
            guard let position = (index..<hay.count).first(where: { hay[$0] == pin }) else { return nil }
            if position == 0 {
                total += 12  // starts there
            } else if hay[position - 1] == " " {
                total += 8  // start of a word
            }
            if let previous = previousMatch, position == previous + 1 {
                total += 6  // letters in a row
            }
            // The further away, the worse, but never painfully.
            total -= min(3, position - index)
            previousMatch = position
            index = position + 1
        }

        // The typed text appears whole, with nothing between: what people expect when they type an
        // app's name. It outweighs everything else together, and more so at the start of a word.
        if let start = firstIndex(of: pins, in: hay) {
            total += 25
            if start == 0 || hay[start - 1] == " " { total += 15 }
        }

        // Of two matches, the shorter name wins: "Sound" before "Sound: switch output".
        return total + max(0, 20 - hay.count / 2)
    }

    /// Sorts and trims. Ties go alphabetically, so the list doesn't dance.
    ///
    /// `bonus` gives a candidate extra points, to tilt the balance without splitting the list into
    /// groups. What barely matches stays out even when there's room: showing things that share only
    /// scattered letters after a good match is what made Return run something unrelated.
    static func rank<T>(
        _ items: [T], query: String, limit: Int = 12, bonus: (T) -> Int = { _ in 0 }, name: (T) -> String
    ) -> [T] {
        let scored = items.compactMap { item -> (item: T, score: Int, name: String)? in
            guard let score = score(name(item), query: query) else { return nil }
            return (item, score + bonus(item), name(item))
        }
        let best = scored.map(\.score).max() ?? 0
        let floor = best > 0 ? best * 2 / 5 : Int.min
        return
            scored
            .filter { $0.score >= floor }
            .sorted {
                $0.score == $1.score
                    ? $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending : $0.score > $1.score
            }
            .prefix(limit)
            .map(\.item)
    }

    /// Lowercase, without accents or punctuation: "cafe" finds "Café", and a stray dot ("mic.")
    /// can't empty the list.
    static func normalize(_ text: String) -> String {
        var result = ""
        for character in text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil) {
            let kept: Character = character.isLetter || character.isNumber ? character : " "
            if kept == " " && (result.last == " " || result.isEmpty) { continue }
            result.append(kept)
        }
        return result.last == " " ? String(result.dropLast()) : result
    }

    /// Where `needle` starts inside `hay`, if it's there as it is.
    private static func firstIndex(of needle: [Character], in hay: [Character]) -> Int? {
        guard !needle.isEmpty, hay.count >= needle.count else { return nil }
        return (0...(hay.count - needle.count)).first { Array(hay[$0..<$0 + needle.count]) == needle }
    }
}
