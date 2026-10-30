// SPDX-License-Identifier: MIT
import Foundation

/// The items picked for the Trash, every one shown with its size before anything moves.
public struct TrashReview: Equatable, Sendable {
    public let items: [DiskItem]

    public init(_ items: [DiskItem]) {
        var seen: Set<String> = []
        // An item inside another picked one goes with it, and would count twice.
        let paths = Set(items.map(\.path))
        self.items = items.filter { item in
            seen.insert(item.path).inserted
                && !paths.contains { item.path.hasPrefix($0 + "/") }
        }
    }

    public var totalBytes: Int64 { items.reduce(0) { $0 + max(0, $1.bytes) } }
}

/// What happened to each reviewed item.
public enum TrashOutcome: Equatable, Sendable {
    case trashed
    case refused(ProtectedPaths.Reason)
    /// Xcode or a build was running, and the item is Xcode's.
    case xcodeBusy
    case failed(String)
}

public struct TrashReport: Equatable, Sendable {
    public let outcomes: [String: TrashOutcome]
    public let trashedBytes: Int64

    public var trashed: Int { outcomes.values.count { $0 == .trashed } }
    public var kept: Int { outcomes.count - trashed }
}

/// Moves reviewed items to the Trash, never deleting anything. Each item is checked again first:
/// it must still pass `ProtectedPaths.check`, so no protected path and nothing reached through a
/// symbolic link, and an item of Xcode's waits while Xcode or `xcodebuild` runs.
public struct StorageTrash: Sendable {
    let home: String
    let moveToTrash: @Sendable (URL) throws -> Void
    let xcodeBusy: @Sendable () -> Bool

    public init(
        home: String = NSHomeDirectory(),
        moveToTrash: @escaping @Sendable (URL) throws -> Void = {
            try FileManager.default.trashItem(at: $0, resultingItemURL: nil)
        },
        xcodeBusy: @escaping @Sendable () -> Bool = { XcodeActivity.isBusy() }
    ) {
        self.home = home
        self.moveToTrash = moveToTrash
        self.xcodeBusy = xcodeBusy
    }

    public func perform(_ review: TrashReview) -> TrashReport {
        var outcomes: [String: TrashOutcome] = [:]
        var trashedBytes: Int64 = 0
        for item in review.items {
            let outcome = trash(item)
            outcomes[item.path] = outcome
            if outcome == .trashed { trashedBytes += max(0, item.bytes) }
        }
        return TrashReport(outcomes: outcomes, trashedBytes: trashedBytes)
    }

    private func trash(_ item: DiskItem) -> TrashOutcome {
        if let reason = ProtectedPaths.check(item.path, home: home) { return .refused(reason) }
        // Asked per item, so a build started midway stops the rest.
        if XcodeCategory.belongsToXcode(item.path, home: home), xcodeBusy() { return .xcodeBusy }
        do {
            let hint: URL.DirectoryHint = item.kind == .folder ? .isDirectory : .notDirectory
            try moveToTrash(URL(filePath: item.path, directoryHint: hint))
            return .trashed
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
