// SPDX-License-Identifier: MIT
import Foundation
import Observation
import SwiftUI
import TopdeckCore

/// Storage: Xcode cleanup by category, and what takes the space in the home folder. Nothing is
/// scanned until asked, scanning reads file metadata only, and removing moves items to the Trash
/// after a review of every item and its size.
@MainActor
@Observable
public final class StorageFeature: NotchFeature {
    public enum Mode: Sendable { case xcode, disk }

    /// A scan's progress: not asked for yet, under way, or done.
    public enum Scan<Value: Sendable>: Sendable {
        case idle
        case scanning
        case done(Value)

        public var value: Value? {
            if case .done(let value) = self { return value }
            return nil
        }
    }

    public let id = FeatureID.storage
    public var phase: FeaturePhase = .stopped {
        didSet { if phase == .stopped { cancelScans() } }
    }
    public var mode = Mode.xcode
    public private(set) var xcode: Scan<[XcodeItem]> = .idle
    /// Ticked Xcode items, by path.
    public var xcodeSelection: Set<String> = []
    /// Whether Xcode or a build is running, as of the last look.
    public private(set) var xcodeBusy = false

    public private(set) var disk: Scan<FolderUsage> = .idle
    /// Bytes counted so far while the home folder is scanned.
    public private(set) var diskCounted: Int64 = 0
    /// The folder on screen, and the ones above it back to the home folder.
    public private(set) var diskPath: [String] = []
    /// What's in the folder on screen.
    public private(set) var diskItems: [DiskItem] = []
    /// Ticked items in the folder on screen, by path.
    public var diskSelection: Set<String> = []

    /// Waiting for Move to Trash or Cancel.
    public private(set) var review: TrashReview?
    public private(set) var report: TrashReport?
    public private(set) var trashing = false

    public let home: String
    @ObservationIgnored private let trash: StorageTrash
    @ObservationIgnored private let checkXcode: @Sendable () -> Bool
    @ObservationIgnored private var xcodeTask: Task<Void, Never>?
    @ObservationIgnored private var diskTask: Task<Void, Never>?

    public init(
        home: String = NSHomeDirectory(), trash: StorageTrash? = nil,
        xcodeBusy: @escaping @Sendable () -> Bool = { XcodeActivity.isBusy() }
    ) {
        self.home = home
        self.trash = trash ?? StorageTrash(home: home, xcodeBusy: xcodeBusy)
        checkXcode = xcodeBusy
    }

    public var view: some View { StorageView(storage: self) }

    // MARK: Xcode

    /// Scans Xcode's folders, replacing the last scan.
    @discardableResult
    public func scanXcode() -> Task<Void, Never> {
        xcodeTask?.cancel()
        refreshXcodeBusy()
        report = nil
        xcode = .scanning
        let task = Task { [weak self, home] in
            let items = await XcodeCleanup.scan(home: home)
            guard !Task.isCancelled, let self else { return }
            xcode = .done(items)
            xcodeSelection = Set(items.filter(\.category.selectedByDefault).map(\.id))
        }
        xcodeTask = task
        return task
    }

    public func refreshXcodeBusy() {
        xcodeBusy = checkXcode()
    }

    /// The ticked items of `category`, or with nil, of every category.
    public func xcodeBytes(_ category: XcodeCategory? = nil, selectedOnly: Bool = false) -> Int64 {
        (xcode.value ?? [])
            .filter { category == nil || $0.category == category }
            .filter { !selectedOnly || xcodeSelection.contains($0.id) }
            .reduce(0) { $0 + $1.item.bytes }
    }

    public func reviewXcode() {
        let items = (xcode.value ?? []).filter { xcodeSelection.contains($0.id) }.map(\.item)
        guard !items.isEmpty else { return }
        review = TrashReview(items)
    }

    // MARK: Disk

    /// Measures the home folder, replacing the last scan, and shows it.
    @discardableResult
    public func scanDisk() -> Task<Void, Never> {
        diskTask?.cancel()
        report = nil
        disk = .scanning
        diskCounted = 0
        diskPath = []
        diskItems = []
        // Holds the feature only while the scan runs.
        let counted: @Sendable (Int64) -> Void = { bytes in
            Task { @MainActor in
                if case .scanning = self.disk { self.diskCounted = bytes }
            }
        }
        let task = Task { [weak self, home] in
            let usage = await DiskUsage.measure(home, progress: counted)
            guard !Task.isCancelled, let self else { return }
            disk = .done(usage)
            await open(usage.path)
        }
        diskTask = task
        return task
    }

    /// Shows the folder at `path`, inside the scanned home folder.
    public func open(_ path: String) async {
        guard let root = disk.value, let folder = root.folder(at: path) else { return }
        let items = await DiskUsage.items(in: folder)
        var trail: [String] = []
        var current = folder.path
        while current.hasPrefix(root.path) {
            trail.insert(current, at: 0)
            if current == root.path { break }
            current = (current as NSString).deletingLastPathComponent
        }
        diskSelection = []
        diskPath = trail
        diskItems = items
    }

    public func goUp() async {
        guard diskPath.count > 1 else { return }
        await open(diskPath[diskPath.count - 2])
    }

    /// The folder on screen, as measured.
    public var currentFolder: FolderUsage? {
        diskPath.last.flatMap { disk.value?.folder(at: $0) }
    }

    /// Whether an item may be ticked: not protected, and not a symbolic link.
    public func canRemove(_ item: DiskItem) -> Bool {
        item.kind != .symbolicLink && ProtectedPaths.reason(for: item.path, home: home) == nil
    }

    public var diskSelectedBytes: Int64 {
        diskItems.filter { diskSelection.contains($0.id) }.reduce(0) { $0 + $1.bytes }
    }

    public func reviewDisk() {
        let items = diskItems.filter { diskSelection.contains($0.id) && canRemove($0) }
        guard !items.isEmpty else { return }
        review = TrashReview(items)
    }

    // MARK: Trash

    public func cancelReview() { review = nil }

    /// Moves the reviewed items to the Trash, then takes what went out of the scans.
    public func confirmTrash() async {
        guard let review, !trashing else { return }
        trashing = true
        let trash = trash
        let report = await Task.detached { trash.perform(review) }.value
        trashing = false
        self.review = nil
        self.report = report
        refreshXcodeBusy()
        let gone = review.items.filter { report.outcomes[$0.path] == .trashed }
        if case .done(let items) = xcode {
            let paths = Set(gone.map(\.path))
            xcode = .done(items.filter { !paths.contains($0.id) })
            xcodeSelection.subtract(paths)
        }
        if case .done(var usage) = disk {
            for item in gone { usage.remove(item) }
            disk = .done(usage)
            if let folder = diskPath.last { await open(usage.folder(at: folder) == nil ? usage.path : folder) }
        }
    }

    public func dismissReport() { report = nil }

    private func cancelScans() {
        xcodeTask?.cancel()
        diskTask?.cancel()
        if case .scanning = xcode { xcode = .idle }
        if case .scanning = disk { disk = .idle }
    }
}
