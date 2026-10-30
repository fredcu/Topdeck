// SPDX-License-Identifier: MIT
import Darwin
import Foundation
import Testing

@testable import TopdeckFeatures

/// A scratch home folder per test, with Xcode's folders and files of known sizes.
private struct ScratchHome {
    let path: String

    init() throws {
        path = FileManager.default.temporaryDirectory.appending(path: "StorageTests-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    /// Writes `bytes` bytes at `relative`, making the folders on the way.
    @discardableResult
    func file(_ relative: String, bytes: Int = 10_000) throws -> String {
        let target = path + "/" + relative
        try FileManager.default.createDirectory(
            atPath: (target as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: bytes).write(to: URL(filePath: target))
        return target
    }

    @discardableResult
    func folder(_ relative: String) throws -> String {
        let target = path + "/" + relative
        try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: true)
        return target
    }

    @discardableResult
    func link(_ relative: String, to destination: String) throws -> String {
        let target = path + "/" + relative
        try FileManager.default.createDirectory(
            atPath: (target as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: target, withDestinationPath: destination)
        return target
    }
}

/// What a path takes on disk, by lstat, the way DiskUsage counts it.
private func allocated(_ path: String) -> Int64 {
    var info = stat()
    #expect(lstat(path, &info) == 0, "\(path) exists")
    return Int64(info.st_blocks) * 512
}

private let derivedData = "Library/Developer/Xcode/DerivedData"

struct ProtectedPathsTests {
    let home = "/Users/someone"

    @Test(arguments: [
        ("/", ProtectedPaths.Reason.diskRoot),
        ("/System", .systemFolder),
        ("/Library", .systemFolder),
        ("/Applications", .systemFolder),
        ("/System/Library/CoreServices", .outsideHome),
        ("/usr/bin/swift", .outsideHome),
        ("/Users", .containsHomeFolder),
        ("/Users/other", .userAccount),
        ("/Volumes/Backup", .mountedVolume),
        ("/Users/someone", .homeFolder),
        ("/Users/someone/", .homeFolder),
        ("/Users/someone/Desktop", .standardFolder),
        ("/Users/someone/Documents", .standardFolder),
        ("/Users/someone/Library", .standardFolder),
        ("/Users/someone/Library/Caches", .libraryFolder),
        ("/Users/someone/Library/Developer", .libraryFolder),
        ("/Users/someone/.Trash", .trash),
        ("/Users/someone/.Trash/old.zip", .trash),
        ("/Users/someone/Library/Keychains", .credentials),
        ("/Users/someone/Library/Keychains/login.keychain-db", .credentials),
        ("/Users/someone/Library/Keychains/ABC/keychain-2.db", .credentials),
        ("/Users/someone/library/keychains/login.keychain-db", .credentials),
        ("/Users/someone/.ssh", .credentials),
        ("/Users/someone/.ssh/id_ed25519", .credentials),
        ("/Users/someone/.gnupg", .credentials),
        ("/Users/someone/.gnupg/private-keys-v1.d/key.key", .credentials),
        ("Users/someone/Projects", .unclearPath),
        ("/Users/someone/Projects/../Library", .unclearPath),
        ("/Users/someone/./Library", .unclearPath),
    ])
    func systemAndStandardPathsAreNeverOffered(path: String, reason: ProtectedPaths.Reason) {
        #expect(ProtectedPaths.reason(for: path, home: home) == reason)
    }

    @Test(arguments: [
        "/Users/someone/Projects/app/build",
        "/Users/someone/Desktop/Screenshot.png",
        "/Users/someone/Library/Caches/com.example.app",
        "/Users/someone/Library/Caches/com.example.app/data.db",
        "/Users/someone/Projects/.ssh-notes",
        "/Users/someone/Projects/app/.ssh/config",
        "/Users/someone/Library/Developer/Xcode/DerivedData/App-abc",
        "/Users/someone//Movies/clip.mov/",
    ])
    func itemsInTheHomeFolderMayBe(path: String) {
        #expect(ProtectedPaths.reason(for: path, home: home) == nil)
    }

    @Test func aLinkAnywhereOnTheWayIsRefused() throws {
        let scratch = try ScratchHome()
        let outside = try ScratchHome()
        try outside.file("data/big.bin")
        let linkedFolder = try scratch.link("Projects/linked", to: outside.path + "/data")
        let linkedFile = try scratch.link("Projects/big.bin", to: outside.path + "/data/big.bin")
        let real = try scratch.file("Projects/real.bin")

        #expect(ProtectedPaths.check(linkedFolder, home: scratch.path) == .symbolicLink)
        #expect(ProtectedPaths.check(linkedFolder + "/big.bin", home: scratch.path) == .symbolicLink)
        #expect(ProtectedPaths.check(linkedFile, home: scratch.path) == .symbolicLink)
        #expect(ProtectedPaths.check(real, home: scratch.path) == nil)
        #expect(ProtectedPaths.check(scratch.path + "/Projects/gone.bin", home: scratch.path) == .missing)
        #expect(ProtectedPaths.check(scratch.path + "/Desktop", home: scratch.path) == .standardFolder)
    }
}

struct XcodeCleanupTests {
    let home = "/Users/someone"

    @Test(arguments: [
        ("Library/Developer/Xcode/DerivedData/App-abcdef", XcodeCategory?.some(.derivedData)),
        ("Library/Developer/Xcode/iOS DeviceSupport/18.0 (22A3354)", .deviceSupport),
        ("Library/Developer/Xcode/watchOS DeviceSupport/11.0", .deviceSupport),
        ("Library/Developer/Xcode/Archives/2026-10-01", .archives),
        ("Library/Developer/CoreSimulator/Caches/dyld", .caches),
        ("Library/Developer/Xcode/UserData/Previews/Simulator Devices", .caches),
        ("Library/Caches/com.apple.dt.Xcode/Cache.db", .caches),
        ("Library/Developer/Xcode/DerivedData", nil),
        ("Library/Developer/Xcode/DerivedData/App-abcdef/Build", nil),
        ("Library/Developer/Xcode/UserData/CodeSnippets/a.codesnippet", nil),
        ("Projects/DerivedData/App", nil),
    ])
    func itemsAreSortedIntoCategories(relative: String, category: XcodeCategory?) {
        #expect(XcodeCategory.category(of: home + "/" + relative, home: home) == category)
    }

    @Test func xcodesFoldersBelongToXcode() {
        #expect(XcodeCategory.belongsToXcode(home + "/Library/Developer/Xcode/DerivedData/App", home: home))
        #expect(XcodeCategory.belongsToXcode(home + "/Library/Developer", home: home))
        #expect(XcodeCategory.belongsToXcode(home + "/Library/Caches/com.apple.dt.Xcode", home: home))
        #expect(!XcodeCategory.belongsToXcode(home + "/Library/Caches/com.example.app", home: home))
        #expect(!XcodeCategory.belongsToXcode(home + "/Projects/App/build", home: home))
    }

    @Test func aScanFindsEachCategorysItemsAndSizesThem() async throws {
        let scratch = try ScratchHome()
        let app = try scratch.file(derivedData + "/App-abc/Build/Products/App.o", bytes: 40_000)
        try scratch.file(derivedData + "/Other-def/info.plist", bytes: 2_000)
        try scratch.file(derivedData + "/.DS_Store")
        try scratch.file("Library/Developer/Xcode/iOS DeviceSupport/18.0/Symbols/dyld")
        try scratch.file("Library/Developer/Xcode/Archives/2026-10-01/App.xcarchive/Info.plist")
        try scratch.file("Library/Developer/CoreSimulator/Caches/dyld/cache")
        try scratch.file("Library/Caches/com.apple.dt.Xcode/Cache.db")

        let items = await XcodeCleanup.scan(home: scratch.path)
        let names = Dictionary(grouping: items, by: \.category).mapValues { $0.map(\.item.name) }
        #expect(names[.derivedData] == ["App-abc", "Other-def"], "largest first, no dot files")
        #expect(names[.deviceSupport] == ["18.0"])
        #expect(names[.archives] == ["2026-10-01"])
        #expect(names[.caches]?.sorted() == ["Cache.db", "dyld"])
        let built = try #require(items.first { $0.item.name == "App-abc" })
        #expect(built.item.kind == .folder)
        #expect(built.item.bytes == allocated(app))

        let archives = await XcodeCleanup.scan(home: scratch.path, categories: [.archives])
        #expect(archives.map(\.category) == [.archives])
    }

    @Test func aScanSkipsLinksAndLinkedFolders() async throws {
        let scratch = try ScratchHome()
        let outside = try ScratchHome()
        try outside.file("Projects/huge.bin", bytes: 100_000)
        try scratch.file(derivedData + "/App-abc/a.o")
        try scratch.link(derivedData + "/Linked", to: outside.path + "/Projects")
        try scratch.link("Library/Developer/Xcode/Archives", to: outside.path + "/Projects")

        let items = await XcodeCleanup.scan(home: scratch.path)
        #expect(items.map(\.item.name) == ["App-abc"])
        #expect(FileManager.default.fileExists(atPath: outside.path + "/Projects/huge.bin"))
    }
}

struct DiskUsageTests {
    @Test func totalsCountEachFileOnceAndFollowNoLinks() async throws {
        let scratch = try ScratchHome()
        let outside = try ScratchHome()
        try outside.file("huge.bin", bytes: 200_000)
        let a = try scratch.file("a.bin", bytes: 5_000)
        let b = try scratch.file("sub/b.bin", bytes: 30_000)
        try scratch.folder("sub2")
        try FileManager.default.linkItem(atPath: b, toPath: scratch.path + "/sub2/b-again.bin")
        let link = try scratch.link("outside", to: outside.path)
        try scratch.folder("empty")

        let usage = await DiskUsage.measure(scratch.path)
        #expect(allocated(b) > 0)
        #expect(usage.bytes == allocated(a) + allocated(b) + allocated(link))
        let sub = try #require(usage.folder(at: scratch.path + "/sub"))
        let sub2 = try #require(usage.folder(at: scratch.path + "/sub2"))
        #expect(sub.bytes + sub2.bytes == allocated(b), "the hard link counts once")
        #expect(usage.subfolders.map(\.bytes) == usage.subfolders.map(\.bytes).sorted(by: >))
        #expect(usage.unmeasured == 0)

        let items = await DiskUsage.items(in: usage)
        #expect(items.map(\.bytes) == items.map(\.bytes).sorted(by: >))
        #expect(items.first { $0.name == "outside" }?.kind == .symbolicLink)
        #expect(items.first { $0.name == "a.bin" } == DiskItem(path: a, kind: .file, bytes: allocated(a)))
        #expect(items.first { $0.name == "empty" } == DiskItem(path: scratch.path + "/empty", kind: .folder, bytes: 0))
    }

    @Test func aLinkIsNotMeasuredAsAFolder() async throws {
        let scratch = try ScratchHome()
        try scratch.file("data/x.bin")
        let link = try scratch.link("link", to: scratch.path + "/data")
        let usage = await DiskUsage.measure(link)
        #expect(usage.bytes == 0)
        #expect(usage.unmeasured == 1)
    }

    @Test func removingAnItemTakesItsBytesFromEveryFolderAbove() {
        let leaf = FolderUsage(path: "/h/a/b", bytes: 40)
        let a = FolderUsage(path: "/h/a", bytes: 70, subfolders: [leaf])
        var root = FolderUsage(path: "/h", bytes: 100, subfolders: [a, FolderUsage(path: "/h/c", bytes: 20)])
        root.remove(DiskItem(path: "/h/a/b/file", kind: .file, bytes: 15))
        #expect(root.bytes == 85)
        #expect(root.folder(at: "/h/a/b")?.bytes == 25)
        root.remove(DiskItem(path: "/h/a", kind: .folder, bytes: 55))
        #expect(root.bytes == 30)
        #expect(root.subfolders.map(\.path) == ["/h/c"])
        root.remove(DiskItem(path: "/elsewhere/x", kind: .file, bytes: 5))
        #expect(root.bytes == 30)
    }
}

struct StorageTrashTests {
    @Test func aReviewTotalsItsItemsAndDropsOnesInsideOthers() {
        let review = TrashReview([
            DiskItem(path: "/h/a", kind: .folder, bytes: 10),
            DiskItem(path: "/h/a/b", kind: .file, bytes: 5),
            DiskItem(path: "/h/c", kind: .file, bytes: 7),
            DiskItem(path: "/h/c", kind: .file, bytes: 7),
        ])
        #expect(review.items.map(\.path) == ["/h/a", "/h/c"])
        #expect(review.totalBytes == 17)
    }

    /// Moves to a folder of the test's, standing in for the Trash.
    static func trash(into folder: String) -> @Sendable (URL) throws -> Void {
        { url in try FileManager.default.moveItem(atPath: url.path, toPath: folder + "/" + url.lastPathComponent) }
    }

    @Test func everyItemIsCheckedAgainBeforeItMoves() throws {
        let scratch = try ScratchHome()
        let bin = try ScratchHome()
        let outside = try ScratchHome()
        try outside.file("keep.bin")
        let plain = try scratch.file("Projects/old.zip", bytes: 20_000)
        let link = try scratch.link("Projects/shortcut", to: outside.path + "/keep.bin")
        let desktop = try scratch.folder("Desktop")
        let built = try scratch.file(derivedData + "/App-abc/a.o")
        let items = [
            DiskItem(path: plain, kind: .file, bytes: 20_480),
            DiskItem(path: link, kind: .file, bytes: 0),
            DiskItem(path: desktop, kind: .folder, bytes: 0),
            DiskItem(path: (built as NSString).deletingLastPathComponent, kind: .folder, bytes: 12_288),
            DiskItem(path: scratch.path + "/Projects/gone", kind: .file, bytes: 1),
            DiskItem(path: outside.path + "/keep.bin", kind: .file, bytes: 1),
        ]
        let trash = StorageTrash(home: scratch.path, moveToTrash: Self.trash(into: bin.path), xcodeBusy: { true })

        let report = trash.perform(TrashReview(items))
        #expect(report.outcomes[plain] == .trashed)
        #expect(report.outcomes[link] == .refused(.symbolicLink))
        #expect(report.outcomes[desktop] == .refused(.standardFolder))
        #expect(report.outcomes[items[3].path] == .xcodeBusy)
        #expect(report.outcomes[items[4].path] == .refused(.missing))
        #expect(report.outcomes[items[5].path] == .refused(.outsideHome))
        #expect(report.trashed == 1)
        #expect(report.kept == 5)
        #expect(report.trashedBytes == 20_480)
        #expect(FileManager.default.fileExists(atPath: bin.path + "/old.zip"))
        #expect(FileManager.default.fileExists(atPath: built))
        #expect(FileManager.default.fileExists(atPath: outside.path + "/keep.bin"))
    }

    @Test func xcodesItemsMoveOnceXcodeIsClosed() throws {
        let scratch = try ScratchHome()
        let bin = try ScratchHome()
        let built = (try scratch.file(derivedData + "/App-abc/a.o") as NSString).deletingLastPathComponent
        let trash = StorageTrash(home: scratch.path, moveToTrash: Self.trash(into: bin.path), xcodeBusy: { false })
        let report = trash.perform(TrashReview([DiskItem(path: built, kind: .folder, bytes: 1)]))
        #expect(report.outcomes[built] == .trashed)
        #expect(!FileManager.default.fileExists(atPath: built))
    }

    @Test func xcodeAndBuildsAreSeen() throws {
        #expect(XcodeActivity.isBusy(running: ["launchd", "Xcode"]))
        #expect(XcodeActivity.isBusy(running: ["Finder", "xcodebuild"]))
        #expect(!XcodeActivity.isBusy(running: ["Finder", "XcodeCleaner", "xcodes"]))
        let names = try #require(XcodeActivity.runningProcessNames())
        #expect(!names.isEmpty)
    }
}

@MainActor
struct StorageFeatureTests {
    @Test func xcodeCleanupReviewsTicksAndMovesThemToTheTrash() async throws {
        let scratch = try ScratchHome()
        let bin = try ScratchHome()
        let built = try scratch.file(derivedData + "/App-abc/a.o")
        let archive = try scratch.file("Library/Developer/Xcode/Archives/2026-10-01/App.xcarchive/Info.plist")
        let moveToTrash = StorageTrashTests.trash(into: bin.path)
        let trash = StorageTrash(home: scratch.path, moveToTrash: moveToTrash, xcodeBusy: { false })
        let storage = StorageFeature(home: scratch.path, trash: trash, xcodeBusy: { false })

        #expect(storage.xcode.value == nil, "nothing is scanned until asked")
        await storage.scanXcode().value
        let items = try #require(storage.xcode.value)
        #expect(items.count == 2)
        #expect(storage.xcodeSelection == [scratch.path + "/" + derivedData + "/App-abc"], "archives aren't ticked")
        #expect(storage.xcodeBytes() == allocated(built) + allocated(archive))

        storage.reviewXcode()
        let review = try #require(storage.review)
        #expect(review.items.map(\.name) == ["App-abc"])
        await storage.confirmTrash()
        #expect(storage.review == nil)
        #expect(storage.report?.trashed == 1)
        #expect(!FileManager.default.fileExists(atPath: built))
        #expect(FileManager.default.fileExists(atPath: archive))
        #expect(storage.xcode.value?.map(\.category) == [.archives])
    }

    @Test func nothingOfXcodesMovesWhileItRuns() async throws {
        let scratch = try ScratchHome()
        let built = try scratch.file(derivedData + "/App-abc/a.o")
        let storage = StorageFeature(
            home: scratch.path, trash: StorageTrash(home: scratch.path, moveToTrash: { _ in }, xcodeBusy: { true }),
            xcodeBusy: { true })
        await storage.scanXcode().value
        #expect(storage.xcodeBusy)
        storage.reviewXcode()
        await storage.confirmTrash()
        #expect(storage.report?.outcomes.values.first == .xcodeBusy)
        #expect(FileManager.default.fileExists(atPath: built))
    }

    @Test func theHomeFolderOpensFolderByFolder() async throws {
        let scratch = try ScratchHome()
        let big = try scratch.file("Projects/app/big.bin", bytes: 50_000)
        try scratch.file("notes.txt", bytes: 1_000)
        try scratch.folder("Library/Caches")
        let storage = StorageFeature(home: scratch.path, xcodeBusy: { false })

        await storage.scanDisk().value
        #expect(storage.diskPath == [scratch.path])
        #expect(storage.diskItems.first?.name == "Projects")
        let library = try #require(storage.diskItems.first { $0.name == "Library" })
        #expect(!storage.canRemove(library))
        #expect(storage.canRemove(storage.diskItems[0]))

        await storage.open(scratch.path + "/Projects/app")
        #expect(storage.diskPath == [scratch.path, scratch.path + "/Projects", scratch.path + "/Projects/app"])
        #expect(storage.diskItems.map(\.path) == [big])
        #expect(storage.currentFolder?.bytes == allocated(big))
        await storage.goUp()
        #expect(storage.diskPath.last == scratch.path + "/Projects")
    }
}
