// SPDX-License-Identifier: MIT
// Adapted from OpenDisk's ProtectedPaths (MIT), Copyright (c) 2026 137137137; see THIRD_PARTY_NOTICES.md.
import Darwin
import Foundation

/// Paths Storage never offers to move to the Trash. Only items inside the home folder qualify, and
/// not the home folder's standard folders, Library or the folders directly in it, or the Trash. A
/// symbolic link anywhere from the home folder down, the item included, refuses the item: removing
/// it never acts on what a link points to.
public enum ProtectedPaths {
    public enum Reason: Equatable, Sendable {
        /// Relative, or with a "." or ".." in it.
        case unclearPath
        case diskRoot
        case systemFolder
        case userAccount
        case mountedVolume
        case outsideHome
        case homeFolder
        case containsHomeFolder
        /// Desktop, Documents, Library and the others macOS makes in every home folder.
        case standardFolder
        /// A folder directly in ~/Library, such as Caches or Developer.
        case libraryFolder
        case trash
        case symbolicLink
        case missing
    }

    private static let systemRoots: Set<String> = [
        "/", "/System", "/Library", "/usr", "/bin", "/sbin", "/private", "/etc", "/var", "/tmp", "/cores", "/opt",
        "/dev", "/Network", "/Volumes", "/Applications", "/Users", "/System/Volumes", "/System/Applications",
        "/System/Library",
    ]

    private static let standardFolders: Set<String> = [
        "Applications", "Desktop", "Documents", "Downloads", "Library", "Movies", "Music", "Pictures", "Public",
    ]

    /// Why `path` may not be offered, from its text alone; nil when it may.
    public static func reason(for path: String, home: String) -> Reason? {
        guard let p = normalized(path), let home = normalized(home) else { return .unclearPath }
        if p == "/" { return .diskRoot }
        if p == home { return .homeFolder }
        if home.hasPrefix(p + "/") { return .containsHomeFolder }
        guard p.hasPrefix(home + "/") else {
            if systemRoots.contains(p) { return .systemFolder }
            switch parent(of: p) {
            case "/Users": return .userAccount
            case "/Volumes": return .mountedVolume
            default: return .outsideHome
            }
        }
        let inside = p.dropFirst(home.count + 1).split(separator: "/").map(String.init)
        if inside.count == 1, standardFolders.contains(inside[0]) { return .standardFolder }
        if inside.count == 2, inside[0] == "Library" { return .libraryFolder }
        if inside[0] == ".Trash" { return .trash }
        return nil
    }

    /// `reason(for:home:)`, then what's on disk: the item must exist, and neither it nor any folder
    /// between it and the home folder may be a symbolic link. Reads metadata only.
    public static func check(_ path: String, home: String) -> Reason? {
        if let reason = reason(for: path, home: home) { return reason }
        guard let p = normalized(path), let home = normalized(home) else { return .unclearPath }
        var current = home
        for component in p.dropFirst(home.count + 1).split(separator: "/") {
            current += "/" + component
            var info = stat()
            guard lstat(current, &info) == 0 else { return .missing }
            if info.st_mode & S_IFMT == S_IFLNK { return .symbolicLink }
        }
        return nil
    }

    /// Without a trailing slash or doubled slashes; nil unless absolute and free of "." and "..".
    static func normalized(_ path: String) -> String? {
        guard path.hasPrefix("/") else { return nil }
        let components = path.split(separator: "/")
        guard !components.contains(where: { $0 == "." || $0 == ".." }) else { return nil }
        return "/" + components.joined(separator: "/")
    }

    private static func parent(of path: String) -> String {
        (path as NSString).deletingLastPathComponent
    }
}
