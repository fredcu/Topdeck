// SPDX-License-Identifier: MIT
import Foundation

/// Checks names before they reach launchctl or brew. Both get them as one argument each, never through
/// a shell, so this guards what the tool itself reads: a leading dash would make a name an option, a
/// slash would reach another domain or tap, and anything outside ASCII letters, digits, and a little
/// punctuation has no business in either.
public enum AdminNames {
    /// A launchd label, such as `com.example.agent` or `homebrew.mxcl.postgresql@16`.
    public static func isValidLabel(_ label: String) -> Bool {
        (1...255).contains(label.utf8.count) && isWord(Substring(label), punctuation: "._-@")
    }

    /// A Homebrew formula or cask, such as `wget`, `python@3.13`, `gtk+3`, or a tap's `user/repo/name`.
    public static func isValidPackage(_ name: String) -> Bool {
        let parts = name.split(separator: "/", omittingEmptySubsequences: false)
        guard name.utf8.count <= 200, parts.count == 1 || parts.count == 3 else { return false }
        return parts.allSatisfy { isWord($0, punctuation: "._-@+") }
    }

    /// Starts with a letter or digit, then letters, digits, and `punctuation`. Only ASCII.
    private static func isWord(_ word: Substring, punctuation: String) -> Bool {
        guard let first = word.unicodeScalars.first, isAlphanumeric(first) else { return false }
        return word.unicodeScalars.allSatisfy { isAlphanumeric($0) || punctuation.unicodeScalars.contains($0) }
    }

    private static func isAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar)
    }
}
