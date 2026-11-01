// SPDX-License-Identifier: MIT
import Foundation
import Observation
import SwiftUI
import TopdeckCore

/// How the notes list is ordered. Pinned notes always come first.
public enum NoteSort: String, CaseIterable, Identifiable, Sendable {
    case modified
    case created
    case title

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .modified: "Last Edited"
        case .created: "Date Created"
        case .title: "Title"
        }
    }
}

/// Quick notes kept as Markdown files, one per note, named after their first line. They live in
/// Application Support unless the user picks a folder, such as one in iCloud Drive, so they reach
/// the iPhone's Files app or a Markdown app there. They load when Now comes on screen, save half
/// a second after typing stops, are written out whenever Now goes away, and leave memory when
/// the feature stops, except notes with a window of their own, or open in one: those load at launch
/// and keep saving while the notch is away. Empty notes are never saved.
@MainActor
@Observable
public final class NotesFeature: NotchFeature {
    public let id = FeatureID.notes
    public var phase: FeaturePhase = .stopped {
        didSet {
            guard phase != oldValue else { return }
            if phase == .foreground {
                load()
            } else {
                flush()
            }
            if phase == .stopped { keepOnlyWindowed() }
        }
    }
    public private(set) var notes: [Note] = []
    public var sort: NoteSort {
        didSet { defaults.set(sort.rawValue, forKey: Self.sortKey) }
    }
    /// Per-feature setting: Control-Option-N opens a new note from anywhere.
    public var quickNoteShortcut: Bool {
        didSet { defaults.set(quickNoteShortcut, forKey: Self.shortcutKey) }
    }
    /// Where the notes are stored.
    public private(set) var directory: URL
    /// Whether `directory` is a folder the user chose rather than the app's own.
    public private(set) var usesCustomFolder: Bool
    /// A short confirmation or problem. Clears itself.
    public private(set) var notice: String?
    /// Called with a note's id once it has gone to the Trash.
    @ObservationIgnored public var onDelete: ((Note.ID) -> Void)?
    /// Notes open in a window without having one of their own, which stay in memory while they are open.
    @ObservationIgnored public var held: Set<Note.ID> = []

    private static let sortKey = "notes.sort"
    private static let shortcutKey = "notes.quickNoteShortcut"
    private static let folderKey = "notes.folderBookmark"
    @ObservationIgnored private let defaultDirectory: URL
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var unsaved: Set<Note.ID> = []
    @ObservationIgnored private var pendingSave: Task<Void, Never>?
    /// The modification date of each Markdown file as Topdeck last read or wrote it, to tell its own saves from
    /// another app's changes.
    @ObservationIgnored private var knownDates: [String: Date] = [:]
    @ObservationIgnored private var clearNotice: Task<Void, Never>?
    /// The chosen folder while its security scope is open, in a sandboxed build.
    @ObservationIgnored private var folderAccess: URL?

    /// `directory` replaces both the default folder and any folder the user chose, for tests.
    public init(directory: URL? = nil, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaultDirectory = directory ?? AppSupport.file("Notes")
        sort = defaults.string(forKey: Self.sortKey).flatMap(NoteSort.init(rawValue:)) ?? .modified
        quickNoteShortcut = defaults.object(forKey: Self.shortcutKey) as? Bool ?? true
        let chosen = directory == nil ? defaults.data(forKey: Self.folderKey).flatMap(Self.resolve) : nil
        self.directory = chosen ?? defaultDirectory
        usesCustomFolder = chosen != nil
        if let chosen, ShelfFeature.sandboxed, chosen.startAccessingSecurityScopedResource() { folderAccess = chosen }
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    /// The notes shown in windows of their own.
    public var windowed: [Note] { notes.filter { $0.window != nil } }

    /// Every note, the most recently edited first: what Now lists.
    public var recent: [Note] { notes.sorted { $0.modified > $1.modified } }

    /// The notes Now lists: kept-first notes at the top, then in the order chosen in Settings.
    public var visibleNotes: [Note] {
        let order = self.sort
        return notes.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
            switch order {
            case .modified: return lhs.modified > rhs.modified
            case .created: return lhs.created > rhs.created
            case .title: return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
        }
    }

    @discardableResult
    public func add(_ text: String = "") -> Note.ID {
        let note = Note(id: UUID(), text: text, modified: .now)
        notes.insert(note, at: 0)
        if !text.isEmpty {
            unsaved.insert(note.id)
            scheduleSave()
        }
        return note.id
    }

    public func update(_ id: Note.ID, text: String) {
        guard let index = notes.firstIndex(where: { $0.id == id }), notes[index].text != text else { return }
        notes[index].text = text
        notes[index].modified = .now
        unsaved.insert(id)
        scheduleSave()
    }

    public func setColor(_ id: Note.ID, _ color: NoteColor?) {
        change(id) { $0.color = color }
    }

    public func togglePin(_ id: Note.ID) {
        change(id) { $0.isPinned.toggle() }
    }

    /// Shows a note in a window on the desktop or on top, or, with nil, only in the notch again. From
    /// its first window on, the note keeps its id in its file, since the window's place is stored by it.
    public func setWindow(_ id: Note.ID, _ window: NoteWindow?) {
        change(id) { note in
            note.window = window
            if window != nil { note.storesID = true }
        }
    }

    /// Reads the folder for the notes that have windows, at launch and when the folder changes, even
    /// while the notch has never shown Notes.
    public func loadWindowed() {
        load()
        if phase == .stopped { keepOnlyWindowed() }
    }

    public func delete(_ id: Note.ID) {
        guard let note = notes.first(where: { $0.id == id }) else { return }
        notes.removeAll { $0.id == id }
        unsaved.remove(id)
        if let name = note.fileName {
            // To the Trash, not gone for good: a note is often the only copy of something.
            let url = directory.appending(path: name)
            if (try? FileManager.default.trashItem(at: url, resultingItemURL: nil)) == nil {
                try? FileManager.default.removeItem(at: url)
            }
            knownDates[name] = nil
        }
        held.remove(id)
        onDelete?(id)
    }

    /// The note's file, written out first, for dragging it out of the notch.
    public func fileURL(for id: Note.ID) -> URL? {
        flush()
        return notes.first { $0.id == id }?.fileName.map { directory.appending(path: $0) }
    }

    /// Stores notes in `folder` from now on. Notes in the app's own folder move there; a folder
    /// chosen earlier keeps its files.
    public func chooseFolder(_ folder: URL) {
        flush()
        guard folder.standardizedFileURL != directory.standardizedFileURL else { return }
        let options: URL.BookmarkCreationOptions = ShelfFeature.sandboxed ? .withSecurityScope : []
        guard let bookmark = try? folder.bookmarkData(options: options) else {
            show(notice: "Couldn't use that folder")
            return
        }
        if !usesCustomFolder { moveNotes(from: directory, to: folder) }
        defaults.set(bookmark, forKey: Self.folderKey)
        switchFolder(to: folder, custom: true)
    }

    /// Goes back to the app's own folder. Notes in the chosen folder stay there.
    public func useDefaultFolder() {
        flush()
        defaults.removeObject(forKey: Self.folderKey)
        switchFolder(to: defaultDirectory, custom: false)
    }

    /// Whether the folder's Markdown files differ from what Topdeck last read or wrote, which is so only
    /// when another app (or iCloud) changed them.
    public func folderChanged() -> Bool {
        modificationDates() != knownDates
    }

    func load() {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .creationDateKey]
        let listing = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        // Ids stay the same across reloads so open windows keep their notes. Files from before notes were
        // named by title are named by their id.
        let known = Dictionary(
            notes.compactMap { note in note.fileName.map { ($0, note.id) } }, uniquingKeysWith: { first, _ in first })
        var dates: [String: Date] = [:]
        var stored = (listing ?? []).filter { $0.pathExtension.lowercased() == "md" }.compactMap { url -> Note? in
            let values = try? url.resourceValues(forKeys: Set(keys))
            let name = url.lastPathComponent
            dates[name] = values?.contentModificationDate ?? .distantPast
            guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            let id = known[name] ?? UUID(uuidString: url.deletingPathExtension().lastPathComponent) ?? UUID()
            return Note(
                id: id, fileName: name, contents: contents, modified: values?.contentModificationDate ?? .distantPast,
                created: values?.creationDate)
        }
        // A copy of a file, say from Finder, has its original's id: it gets its own, written to it.
        // The older file keeps the id, so its window stays its own.
        stored.sort { ($0.created, $0.fileName ?? "") < ($1.created, $1.fileName ?? "") }
        var seen: Set<Note.ID> = []
        for index in stored.indices where !seen.insert(stored[index].id).inserted {
            stored[index].id = UUID()
            unsaved.insert(stored[index].id)
            scheduleSave()
        }
        knownDates = dates
        // A note whose file says what it already does stays as it is, so a window's editor isn't handed a new
        // value (and loses its selection and composition) for a save of its own.
        let current = Dictionary(notes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for index in stored.indices {
            guard var old = current[stored[index].id] else { continue }
            old.modified = stored[index].modified
            old.created = stored[index].created
            if old == stored[index] { stored[index] = current[old.id] ?? stored[index] }
        }
        // Edits not yet on disk win over what's stored.
        let pending = notes.filter { unsaved.contains($0.id) }
        let pendingIDs = Set(pending.map(\.id))
        let pendingFiles = Set(pending.compactMap(\.fileName))
        let merged =
            pending + stored.filter { !pendingIDs.contains($0.id) && !pendingFiles.contains($0.fileName ?? "") }
        // The order the notes are held in doesn't matter, so the same notes are not assigned again.
        if merged.count != notes.count || !merged.allSatisfy(notes.contains) { notes = merged }
    }

    /// Writes every unsaved note now, renaming a file Topdeck named when its title changed; a note
    /// emptied out is deleted rather than kept blank, unless it has a window to come back to.
    func flush() {
        pendingSave?.cancel()
        let manager = FileManager.default
        for id in unsaved {
            guard let index = notes.firstIndex(where: { $0.id == id }) else { continue }
            let note = notes[index]
            if note.isEmpty, note.window == nil {
                if let name = note.fileName {
                    try? manager.removeItem(at: directory.appending(path: name))
                    knownDates[name] = nil
                }
                notes[index].fileName = nil
                continue
            }
            // A file the user named, in a folder they picked, keeps its name: another app, such as a
            // Markdown editor, may link to it by that name.
            var name =
                note.followsTitle
                ? freeName(for: note.title, in: directory, keeping: note.fileName)
                : note.fileName ?? freeName(for: note.title, in: directory)
            if let old = note.fileName, old != name {
                do {
                    try manager.moveItem(at: directory.appending(path: old), to: directory.appending(path: name))
                    knownDates[old] = nil
                } catch {
                    name = old  // keep the old name rather than leave a second copy behind
                }
            }
            let url = directory.appending(path: name)
            do {
                try note.fileContents.write(to: url, atomically: true, encoding: .utf8)
                // An atomic write replaces the file, so the creation date is put back.
                try? manager.setAttributes([.creationDate: note.created], ofItemAtPath: url.path)
                notes[index].fileName = name
                knownDates[name] =
                    (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate
            } catch {
                Log.features.error("Couldn't save a note: \(error.localizedDescription, privacy: .public)")
            }
        }
        unsaved = []
    }

    private func modificationDates() -> [String: Date] {
        let listing = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])
        return (listing ?? []).filter { $0.pathExtension.lowercased() == "md" }.reduce(into: [:]) { dates, url in
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            dates[url.lastPathComponent] = values?.contentModificationDate ?? .distantPast
        }
    }

    /// Lets go of every note but those with windows or open in one, and edits not yet written.
    private func keepOnlyWindowed() {
        notes = notes.filter { $0.window != nil || held.contains($0.id) || unsaved.contains($0.id) }
    }

    /// Shows the given notes as they'd load from disk. For tests and snapshots only.
    func show(notes: [Note]) {
        self.notes = notes
    }

    /// Reads the folder and keeps the note in the file named `fileName` in memory, for the Command Bar to
    /// open in a window without the notch. Returns its id, or nil when there is no such file.
    public func hold(fileName: String) -> Note.ID? {
        load()
        guard let id = notes.first(where: { $0.fileName == fileName })?.id else {
            if phase == .stopped { keepOnlyWindowed() }
            return nil
        }
        held.insert(id)
        if phase == .stopped { keepOnlyWindowed() }
        return id
    }

    /// Every note in the folder as the Command Bar searches them: the file's name, the title, and the
    /// start of the text. Read from disk, so notes are found while Now is away; edits not yet saved are
    /// written first.
    public func searchIndex() -> [NoteSearchEntry] {
        flush()
        let listing =
            (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return listing.filter { $0.pathExtension.lowercased() == "md" }.compactMap { url in
            guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            let note = Note(id: UUID(), text: Note.splitFrontMatter(contents).body, modified: .now)
            return NoteSearchEntry(
                fileName: url.lastPathComponent, title: note.title, excerpt: String(note.text.prefix(240)))
        }
    }

    private func change(_ id: Note.ID, _ apply: (inout Note) -> Void) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        apply(&notes[index])
        unsaved.insert(id)
        scheduleSave()
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            self?.flush()
        }
    }

    private func show(notice text: String) {
        notice = text
        clearNotice?.cancel()
        clearNotice = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            self?.notice = nil
        }
    }

    /// "Groceries.md", or "Groceries 2.md" when another file has that name. The note's own file,
    /// `current`, doesn't count, even if only its capitalization differs.
    private func freeName(for title: String, in folder: URL, keeping current: String? = nil) -> String {
        let base = Note.fileBase(for: title)
        var candidate = "\(base).md"
        var number = 2
        while candidate.lowercased() != current?.lowercased(),
            FileManager.default.fileExists(atPath: folder.appending(path: candidate).path)
        {
            candidate = "\(base) \(number).md"
            number += 1
        }
        return candidate
    }

    private func moveNotes(from source: URL, to folder: URL) {
        let manager = FileManager.default
        try? manager.createDirectory(at: folder, withIntermediateDirectories: true)
        let files = (try? manager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension.lowercased() == "md" {
            let contents = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            let (_, body) = Note.splitFrontMatter(contents)
            let title = Note(id: UUID(), text: body, modified: .now).title
            let target = folder.appending(path: freeName(for: title, in: folder))
            do {
                try manager.moveItem(at: file, to: target)
            } catch {
                Log.features.error("Couldn't move a note: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func switchFolder(to folder: URL, custom: Bool) {
        folderAccess?.stopAccessingSecurityScopedResource()
        folderAccess = nil
        if custom, ShelfFeature.sandboxed, folder.startAccessingSecurityScopedResource() { folderAccess = folder }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        directory = folder
        usesCustomFolder = custom
        notes = []
        unsaved = []
        held = []
        loadWindowed()
    }

    /// The folder a bookmark points to. A stale bookmark still resolves; it's renewed next time the
    /// folder is chosen.
    private static func resolve(_ bookmark: Data) -> URL? {
        var stale = false
        let options: URL.BookmarkResolutionOptions = ShelfFeature.sandboxed ? .withSecurityScope : []
        return try? URL(resolvingBookmarkData: bookmark, options: options, bookmarkDataIsStale: &stale)
    }
}

/// A note as the Command Bar finds it.
public struct NoteSearchEntry: Equatable, Sendable {
    public let fileName: String
    public let title: String
    /// The start of the text, flattened to one line.
    public let excerpt: String

    public init(fileName: String, title: String, excerpt: String) {
        self.fileName = fileName
        self.title = title
        self.excerpt = excerpt.split(whereSeparator: \.isNewline).joined(separator: " ")
    }
}
