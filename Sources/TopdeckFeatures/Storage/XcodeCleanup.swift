// SPDX-License-Identifier: MIT
// Adapted from MacTools' XcodeClean plugin (Apache-2.0) at commit 9197035650b67f1c313960e8b1dded7a710264dd,
// Copyright the MacTools authors: its categories, folders, and the rule that only items inside them are
// offered. Changed for Topdeck: four categories, no glob, links and protected paths refused, items sized
// by DiskUsage, and removal to the Trash only. See THIRD_PARTY_NOTICES.md.
import Darwin
import Foundation

/// What Xcode leaves behind, by kind. Each category is a set of folders whose items Xcode makes
/// again when it needs them, apart from Archives.
public enum XcodeCategory: String, CaseIterable, Identifiable, Sendable {
    case derivedData, deviceSupport, archives, caches

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .derivedData: "DerivedData"
        case .deviceSupport: "Device Support"
        case .archives: "Archives"
        case .caches: "Caches"
        }
    }

    /// The folders whose items belong to the category, from the home folder.
    var folders: [String] {
        switch self {
        case .derivedData: ["Library/Developer/Xcode/DerivedData"]
        case .deviceSupport:
            ["iOS", "tvOS", "watchOS", "visionOS", "macOS"].map { "Library/Developer/Xcode/\($0) DeviceSupport" }
        case .archives: ["Library/Developer/Xcode/Archives"]
        case .caches:
            [
                "Library/Developer/CoreSimulator/Caches", "Library/Developer/Xcode/UserData/Previews",
                "Library/Caches/com.apple.dt.Xcode",
            ]
        }
    }

    /// Ticked after a scan. Archives hold the builds you shipped and their debug symbols, so
    /// they're never ticked for you.
    public var selectedByDefault: Bool { self != .archives }

    /// The category of an item directly in one of its folders; nil for anything else, the folders
    /// themselves included.
    public static func category(of path: String, home: String) -> XcodeCategory? {
        guard let path = ProtectedPaths.normalized(path), let home = ProtectedPaths.normalized(home) else { return nil }
        let parent = (path as NSString).deletingLastPathComponent
        return allCases.first { category in category.folders.contains { home + "/" + $0 == parent } }
    }

    /// Whether removing `path` could pull files from under a running Xcode or `xcodebuild`: it is
    /// in, or holds, ~/Library/Developer or Xcode's caches.
    public static func belongsToXcode(_ path: String, home: String) -> Bool {
        guard let path = ProtectedPaths.normalized(path), let home = ProtectedPaths.normalized(home) else {
            return true
        }
        return ["Library/Developer", "Library/Caches/com.apple.dt.Xcode"].contains { folder in
            let root = home + "/" + folder
            return path == root || path.hasPrefix(root + "/") || root.hasPrefix(path + "/")
        }
    }
}

/// An item Xcode cleanup offers: something directly in one of a category's folders.
public struct XcodeItem: Identifiable, Hashable, Sendable {
    public let category: XcodeCategory
    public let item: DiskItem

    public var id: String { item.path }
}

public enum XcodeCleanup {
    /// The items in `categories`' folders, each measured, largest first within its category. Items
    /// whose names start with a dot (.DS_Store) are left alone, and so is anything
    /// `ProtectedPaths.check` refuses, symbolic links among them. Reads metadata only.
    public static func scan(
        home: String, categories: Set<XcodeCategory> = Set(XcodeCategory.allCases)
    ) async -> [XcodeItem] {
        var found: [XcodeItem] = []
        for category in XcodeCategory.allCases where categories.contains(category) {
            var items: [XcodeItem] = []
            for relative in category.folders {
                if Task.isCancelled { return found }
                let folder = home + "/" + relative
                guard ProtectedPaths.check(folder, home: home) == nil else { continue }
                let paths = await entries(in: folder)
                for path in paths where ProtectedPaths.check(path, home: home) == nil {
                    if Task.isCancelled { return found }
                    items.append(XcodeItem(category: category, item: await measure(path)))
                }
            }
            found += items.sorted { $0.item.bytes > $1.item.bytes }
        }
        return found
    }

    /// The paths directly in `folder`, but not those starting with a dot.
    private static func entries(in folder: String) async -> [String] {
        await DiskUsage.offline {
            var paths: [String] = []
            DiskUsage.forEachEntry(in: folder) { name, _ in
                if !name.hasPrefix(".") { paths.append(folder + "/" + name) }
            }
            return paths.sorted()
        }
    }

    private static func measure(_ path: String) async -> DiskItem {
        var info = stat()
        guard lstat(path, &info) == 0 else { return DiskItem(path: path, kind: .other, bytes: 0) }
        switch info.st_mode & S_IFMT {
        case S_IFDIR: return DiskItem(path: path, kind: .folder, bytes: await DiskUsage.measure(path).bytes)
        case S_IFREG: return DiskItem(path: path, kind: .file, bytes: DiskUsage.allocated(info))
        default: return DiskItem(path: path, kind: .other, bytes: DiskUsage.allocated(info))
        }
    }
}
