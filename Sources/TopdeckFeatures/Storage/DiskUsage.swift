// SPDX-License-Identifier: MIT
import Darwin
import Foundation
import os

/// A file or folder as Storage shows it, with what it takes on disk.
public struct DiskItem: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable { case folder, file, symbolicLink, other }

    public let path: String
    public let kind: Kind
    public let bytes: Int64

    public init(path: String, kind: Kind, bytes: Int64) {
        self.path = path
        self.kind = kind
        self.bytes = bytes
    }

    public var id: String { path }
    public var name: String { (path as NSString).lastPathComponent }
}

/// A folder's size and its subfolders', largest first, from one walk.
public struct FolderUsage: Equatable, Sendable {
    public let path: String
    /// Everything inside, at any depth.
    public var bytes: Int64
    public var subfolders: [FolderUsage]
    /// Folders inside it, at any depth, that weren't measured: unreadable, on another volume, or
    /// in iCloud and not downloaded.
    public var unmeasured: Int

    public init(path: String, bytes: Int64, subfolders: [FolderUsage] = [], unmeasured: Int = 0) {
        self.path = path
        self.bytes = bytes
        self.subfolders = subfolders
        self.unmeasured = unmeasured
    }

    /// The folder at `path`, this one or one inside it.
    public func folder(at path: String) -> FolderUsage? {
        if path == self.path { return self }
        guard path.hasPrefix(self.path + "/") else { return nil }
        for subfolder in subfolders {
            if let found = subfolder.folder(at: path) { return found }
        }
        return nil
    }

    /// Takes away an item that's gone: its bytes from every folder that held it, and the folder
    /// itself when it was one. Nothing changes when the item isn't inside this folder.
    public mutating func remove(_ item: DiskItem) {
        guard item.path.hasPrefix(path + "/") else { return }
        bytes = max(0, bytes - item.bytes)
        if let index = subfolders.firstIndex(where: { $0.path == item.path }) {
            unmeasured -= subfolders[index].unmeasured
            subfolders.remove(at: index)
            return
        }
        guard let index = subfolders.firstIndex(where: { item.path.hasPrefix($0.path + "/") }) else { return }
        let before = subfolders[index].unmeasured
        subfolders[index].remove(item)
        unmeasured += subfolders[index].unmeasured - before
        subfolders.sort { $0.bytes > $1.bytes }
    }
}

/// Measures folders from file metadata alone. Each folder is opened without following a link and
/// each entry read with `fstatat(AT_SYMLINK_NOFOLLOW)`: no file's contents are read, no symbolic
/// link is followed, no other volume is entered, and a file with several hard links counts once.
/// Sizes are the blocks allocated, what removing the item would free. The work runs on a thread of
/// its own that never downloads iCloud files, so scanning sends nothing over the network.
public enum DiskUsage {
    /// The size of the folder at `path` and of every folder in it. `progress` hears the bytes
    /// counted so far, now and then.
    public static func measure(
        _ path: String, progress: @escaping @Sendable (Int64) -> Void = { _ in }
    ) async -> FolderUsage {
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        return await withTaskCancellationHandler {
            await offline {
                var walker = Walker(cancelled: { cancelled.withLock { $0 } }, progress: progress)
                return walker.measure(path)
            }
        } onCancel: {
            cancelled.withLock { $0 = true }
        }
    }

    /// What's directly in the folder at `path`, largest first. Folders take their size from
    /// `usage`, the folder's measurement; files and links from their own metadata.
    public static func items(in usage: FolderUsage) async -> [DiskItem] {
        await offline {
            var items: [DiskItem] = []
            _ = forEachEntry(in: usage.path) { name, info in
                let path = usage.path + "/" + name
                switch info.st_mode & S_IFMT {
                case S_IFDIR:
                    let bytes = usage.subfolders.first { $0.path == path }?.bytes ?? 0
                    items.append(DiskItem(path: path, kind: .folder, bytes: bytes))
                case S_IFREG: items.append(DiskItem(path: path, kind: .file, bytes: allocated(info)))
                case S_IFLNK: items.append(DiskItem(path: path, kind: .symbolicLink, bytes: allocated(info)))
                default: items.append(DiskItem(path: path, kind: .other, bytes: allocated(info)))
                }
            }
            return items.sorted { ($0.bytes, $1.name) > ($1.bytes, $0.name) }
        }
    }

    /// Runs `work` on a thread of its own that never materializes a dataless file: one in iCloud
    /// Drive or another file provider whose contents aren't on this Mac. Reading such a folder fails
    /// there instead of downloading it.
    static func offline<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            let thread = Thread {
                _ = setiopolicy_np(
                    IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
                continuation.resume(returning: work())
            }
            thread.qualityOfService = .utility
            thread.start()
        }
    }

    static func allocated(_ info: stat) -> Int64 { Int64(info.st_blocks) * 512 }

    /// Calls `body` with each entry's name and metadata, links not followed. False when the folder
    /// can't be opened: unreadable, gone, or a symbolic link.
    @discardableResult
    static func forEachEntry(in path: String, _ body: (String, stat) -> Void) -> Bool {
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        guard let directory = fdopendir(descriptor) else {
            close(descriptor)
            return false
        }
        defer { closedir(directory) }
        while let entry = readdir(directory) {
            let length = Int(entry.pointee.d_namlen)
            let name = withUnsafeBytes(of: entry.pointee.d_name) { String(decoding: $0.prefix(length), as: UTF8.self) }
            if name == "." || name == ".." { continue }
            var info = stat()
            guard fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            body(name, info)
        }
        return true
    }

    /// One walk's state: the volume it stays on, and the multiply linked files it has counted.
    struct Walker {
        struct FileKey: Hashable {
            let device: dev_t
            let inode: ino_t
        }

        /// SF_DATALESS in sys/stat.h: a file or folder whose contents are in the cloud.
        private static let dataless: UInt32 = 0x4000_0000

        let cancelled: () -> Bool
        let progress: (Int64) -> Void
        private var device: dev_t?
        private var counted: Set<FileKey> = []
        private var total: Int64 = 0
        private var entries = 0

        init(cancelled: @escaping () -> Bool, progress: @escaping (Int64) -> Void) {
            self.cancelled = cancelled
            self.progress = progress
        }

        mutating func measure(_ path: String) -> FolderUsage {
            var info = stat()
            guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
                return FolderUsage(path: path, bytes: 0, unmeasured: 1)
            }
            device = info.st_dev
            let usage = walk(path)
            progress(total)
            return usage
        }

        private mutating func walk(_ path: String) -> FolderUsage {
            var usage = FolderUsage(path: path, bytes: 0)
            var folders: [String] = []
            let opened = DiskUsage.forEachEntry(in: path) { name, info in
                if info.st_mode & S_IFMT == S_IFDIR {
                    if info.st_dev == device, info.st_flags & Self.dataless == 0 {
                        folders.append(name)
                    } else {
                        usage.subfolders.append(FolderUsage(path: path + "/" + name, bytes: 0, unmeasured: 1))
                        usage.unmeasured += 1
                    }
                    return
                }
                if info.st_nlink > 1, !counted.insert(FileKey(device: info.st_dev, inode: info.st_ino)).inserted {
                    return
                }
                usage.bytes += DiskUsage.allocated(info)
            }
            guard opened, !cancelled() else {
                usage.unmeasured += 1
                return usage
            }
            total += usage.bytes
            entries += 1
            if entries % 500 == 0 { progress(total) }
            for name in folders {
                if cancelled() { break }
                let folder = walk(path + "/" + name)
                usage.bytes += folder.bytes
                usage.unmeasured += folder.unmeasured
                usage.subfolders.append(folder)
            }
            usage.subfolders.sort { $0.bytes > $1.bytes }
            return usage
        }
    }
}
