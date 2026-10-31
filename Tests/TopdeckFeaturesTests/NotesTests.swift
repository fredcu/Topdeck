// SPDX-License-Identifier: MIT
import Foundation
import Testing

@testable import TopdeckFeatures

@MainActor
struct NotesFeatureTests {
    private let folder = FileManager.default.temporaryDirectory.appending(path: "NotesTests-\(UUID().uuidString)")

    private func files() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    @Test func notesAreSavedAsFilesNamedByTitleAndSurviveARelaunch() {
        let notes = NotesFeature(directory: folder)
        notes.phase = .foreground
        let id = notes.add()
        notes.update(id, text: "Groceries\n- milk")
        notes.phase = .background  // leaving the tab writes pending edits
        #expect(files() == ["Groceries.md"])

        let relaunched = NotesFeature(directory: folder)
        relaunched.phase = .foreground
        #expect(relaunched.notes.map(\.text) == ["Groceries\n- milk"])
        #expect(relaunched.notes.first?.title == "Groceries")
    }

    @Test func typingSavesAfterAShortPause() async throws {
        let notes = NotesFeature(directory: folder)
        notes.phase = .foreground
        notes.update(notes.add(), text: "draft")
        #expect(files().isEmpty, "not on every keystroke")
        #expect(await eventually { files().count == 1 })
    }

    @Test func emptyNotesAreNeverKept() {
        let notes = NotesFeature(directory: folder)
        notes.phase = .foreground
        let id = notes.add()
        notes.update(id, text: "temporary")
        notes.phase = .background
        notes.phase = .foreground
        notes.update(id, text: "   \n")
        notes.phase = .background
        #expect(files().isEmpty)
    }

    @Test func deletingANoteRemovesItsFile() {
        let notes = NotesFeature(directory: folder)
        notes.phase = .foreground
        let first = notes.add()
        notes.update(first, text: "one")
        let second = notes.add()
        notes.update(second, text: "two")
        notes.phase = .background
        notes.delete(second)
        #expect(files() == ["one.md"])
        #expect(notes.notes.map(\.id) == [first])
    }

    @Test func stoppingWritesEverythingAndReleasesMemory() {
        let notes = NotesFeature(directory: folder)
        notes.phase = .foreground
        notes.update(notes.add(), text: "keep me")
        notes.phase = .stopped
        #expect(notes.notes.isEmpty)
        #expect(files().count == 1)
    }

    @Test func titlesComeFromTheFirstNonEmptyLine() {
        #expect(Note(id: UUID(), text: "\n  \n  Plan  \nmore", modified: .now).title == "Plan")
        #expect(Note(id: UUID(), text: "## Trip", modified: .now).title == "Trip")
        #expect(Note(id: UUID(), text: "", modified: .now).title == "New Note")
    }

    @Test func renamingTheFirstLineRenamesTheFile() {
        let notes = NotesFeature(directory: folder)
        notes.phase = .foreground
        let id = notes.add()
        notes.update(id, text: "Draft")
        notes.flush()
        notes.update(id, text: "Final: plan\nbody")
        notes.flush()
        #expect(files() == ["Final- plan.md"], "a colon isn't allowed in a file name")
    }

    @Test func aFileTheUserNamedKeepsItsNameThroughEdits() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, text) in [
            ("Meeting 2026-09-01.md", "# Standup\n- notes"), ("Vault note.md", "---\ntags:\n  - work\n---\nBody"),
            ("Groceries 2.md", "Groceries\n- milk"),
        ] {
            try text.write(to: folder.appending(path: name), atomically: true, encoding: .utf8)
        }
        let notes = NotesFeature(directory: folder)
        notes.phase = .foreground
        for note in notes.notes {
            let edited = note.text.replacingOccurrences(of: "Standup", with: "Retro")
            notes.update(note.id, text: edited.replacingOccurrences(of: "Groceries", with: "Shopping") + "\nmore")
        }
        notes.phase = .background
        #expect(files() == ["Meeting 2026-09-01.md", "Shopping.md", "Vault note.md"], "only Topdeck's names follow")
    }

    @Test func notesWithTheSameTitleGetTheirOwnFiles() {
        let notes = NotesFeature(directory: folder)
        notes.phase = .foreground
        notes.update(notes.add(), text: "Todo")
        notes.update(notes.add(), text: "Todo")
        notes.flush()
        #expect(files() == ["Todo 2.md", "Todo.md"])
    }

    @Test func filesFromBeforeTitleNamesStillLoad() throws {
        let id = UUID()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "Old note".write(to: folder.appending(path: "\(id.uuidString).md"), atomically: true, encoding: .utf8)
        let notes = NotesFeature(directory: folder)
        notes.phase = .foreground
        #expect(notes.notes.map(\.id) == [id])
        notes.update(id, text: "Old note, edited")
        notes.flush()
        #expect(files() == ["Old note, edited.md"])
    }

    @Test func colorAndPinAreKeptInFrontMatter() throws {
        let notes = NotesFeature(directory: folder)
        notes.phase = .foreground
        let id = notes.add()
        notes.update(id, text: "Ideas")
        notes.setColor(id, .mint)
        notes.togglePin(id)
        notes.flush()
        let contents = try String(contentsOf: folder.appending(path: "Ideas.md"), encoding: .utf8)
        #expect(contents == "---\ncolor: mint\npinned: true\n---\nIdeas")

        let relaunched = NotesFeature(directory: folder)
        relaunched.phase = .foreground
        let note = try #require(relaunched.notes.first)
        #expect(note.text == "Ideas" && note.color == .mint && note.isPinned)
    }

    @Test func frontMatterFromOtherAppsIsKeptAndRulesAreNotFrontMatter() {
        let note = Note(
            id: UUID(), fileName: "a.md", contents: "---\ntags: work\ncolor: blue\n---\nBody", modified: .now,
            created: nil)
        #expect(note.text == "Body" && note.color == .blue)
        #expect(note.fileContents == "---\ncolor: blue\ntags: work\n---\nBody")
        let rule = Note(id: UUID(), fileName: "b.md", contents: "---\nJust text\n---\n", modified: .now, created: nil)
        #expect(rule.text == "---\nJust text\n---\n" && rule.color == nil)
    }

    @Test func keptFirstNotesComeFirstThenTheChosenOrder() throws {
        let now = Date.now
        let defaults = try #require(UserDefaults(suiteName: "NotesTests.\(UUID().uuidString)"))
        let notes = NotesFeature(directory: folder, defaults: defaults)
        notes.show(notes: [
            Note(id: UUID(), text: "Newest", modified: now),
            Note(id: UUID(), text: "Pinned and old", modified: now - 3600, isPinned: true),
            Note(id: UUID(), text: "Middle\nmilk", modified: now - 60),
        ])
        #expect(notes.visibleNotes.map(\.title) == ["Pinned and old", "Newest", "Middle"])
        notes.sort = .title
        #expect(notes.visibleNotes.map(\.title) == ["Pinned and old", "Middle", "Newest"])
    }

    @Test func theCommandBarFindsNotesWithoutTheNotchAndOpensThemInAWindow() throws {
        let defaults = try #require(UserDefaults(suiteName: "NotesTests.\(UUID().uuidString)"))
        let writer = NotesFeature(directory: folder, defaults: defaults)
        writer.phase = .foreground
        writer.update(writer.add(), text: "Gift ideas\nfor the *garden*")
        writer.update(writer.add(), text: "Trip packing list")
        writer.phase = .stopped
        let notes = NotesFeature(directory: folder, defaults: defaults)
        #expect(notes.notes.isEmpty, "nothing loaded, as when Now is away")
        let index = notes.searchIndex()
        #expect(index.map(\.title).sorted() == ["Gift ideas", "Trip packing list"])
        let gift = try #require(index.first { $0.title == "Gift ideas" })
        #expect(gift.excerpt == "Gift ideas for the *garden*", "one line of the text, searchable")
        let id = try #require(notes.hold(fileName: gift.fileName))
        #expect(notes.notes.map(\.id) == [id], "held in memory for its window, and only it")
        notes.phase = .stopped
        #expect(notes.notes.map(\.id) == [id], "stopping Notes keeps a note that is open")
        notes.held = []
        notes.phase = .background
        notes.phase = .stopped
        #expect(notes.notes.isEmpty)
        #expect(notes.hold(fileName: "missing.md") == nil)
    }

    @Test func choosingAFolderMovesTheNotesThere() throws {
        let defaults = try #require(UserDefaults(suiteName: "NotesTests.\(UUID().uuidString)"))
        let notes = NotesFeature(directory: folder, defaults: defaults)
        notes.phase = .foreground
        notes.update(notes.add(), text: "Moving day")
        notes.flush()
        let chosen = FileManager.default.temporaryDirectory.appending(path: "NotesFolder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)
        notes.chooseFolder(chosen)
        #expect(notes.usesCustomFolder)
        #expect(files().isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: chosen.path) == ["Moving day.md"])
        #expect(notes.notes.map(\.title) == ["Moving day"])
    }

    @Test func windowAndIDRoundTripThroughFrontMatter() {
        let id = UUID()
        let contents = "---\ncolor: blue\nwindow: top\ntopdeck-id: \(id.uuidString)\ntags: work\n---\nBody"
        let note = Note(id: UUID(), fileName: "a.md", contents: contents, modified: .now, created: nil)
        #expect(note.id == id && note.window == .top && note.color == .blue && note.text == "Body")
        #expect(note.fileContents == contents)

        let foreign = Note(
            id: UUID(), fileName: "b.md", contents: "---\nid: 20260901-standup\nwindow: sideways\n---\nBody",
            modified: .now, created: nil)
        #expect(foreign.window == nil, "an unknown window stays among the other fields")
        #expect(foreign.fileContents == "---\nid: 20260901-standup\nwindow: sideways\n---\nBody")
    }

    @Test func aNoteKeepsItsIDOnceItHasHadAWindow() throws {
        let notes = NotesFeature(directory: folder)
        notes.phase = .foreground
        let id = notes.add()
        notes.update(id, text: "Sticky")
        notes.setWindow(id, .desktop)
        notes.flush()
        let contents = try String(contentsOf: folder.appending(path: "Sticky.md"), encoding: .utf8)
        #expect(contents == "---\nwindow: desktop\ntopdeck-id: \(id.uuidString)\n---\nSticky")

        notes.setWindow(id, nil)
        notes.update(id, text: "Sticky, renamed")
        notes.flush()
        let relaunched = NotesFeature(directory: folder)
        relaunched.phase = .foreground
        let note = try #require(relaunched.notes.first)
        #expect(note.id == id && note.window == nil, "the id outlives the window and the rename")
    }

    @Test func aCopiedFileGetsAnIDOfItsOwn() throws {
        let id = UUID()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let contents = "---\nwindow: top\ntopdeck-id: \(id.uuidString)\n---\nTwin"
        try contents.write(to: folder.appending(path: "Twin.md"), atomically: true, encoding: .utf8)
        try contents.write(to: folder.appending(path: "Twin copy.md"), atomically: true, encoding: .utf8)
        let notes = NotesFeature(directory: folder)
        notes.phase = .foreground
        #expect(Set(notes.notes.map(\.id)).count == 2)
        #expect(notes.notes.contains { $0.id == id })
        notes.flush()

        let relaunched = NotesFeature(directory: folder)
        relaunched.phase = .foreground
        #expect(Set(relaunched.notes.map(\.id)) == Set(notes.notes.map(\.id)), "the new id was written")
    }

    @Test func windowedNotesLoadAtLaunchAndKeepSavingWhileStopped() throws {
        let notes = NotesFeature(directory: folder)
        notes.phase = .foreground
        let pinned = notes.add()
        notes.update(pinned, text: "On the desktop")
        notes.setWindow(pinned, .desktop)
        notes.update(notes.add(), text: "In the notch")
        notes.phase = .stopped
        #expect(notes.notes.map(\.id) == [pinned], "only the windowed note stays in memory")

        let relaunched = NotesFeature(directory: folder)
        relaunched.loadWindowed()
        #expect(relaunched.phase == .stopped)
        #expect(relaunched.windowed.map(\.id) == [pinned])
        #expect(relaunched.notes.count == 1)
        relaunched.update(pinned, text: "On the desktop, edited")
        relaunched.flush()
        let contents = try String(contentsOf: folder.appending(path: "On the desktop, edited.md"), encoding: .utf8)
        #expect(contents.hasSuffix("On the desktop, edited"))

        relaunched.phase = .foreground
        #expect(relaunched.notes.count == 2)
        #expect(relaunched.notes.contains { $0.id == pinned && $0.window == .desktop })
    }

    @Test func anotherAppsIDStaysBesideOurs() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "Standup.md")
        try "---\nid: 20260901-standup\n---\nStandup".write(to: file, atomically: true, encoding: .utf8)
        let notes = NotesFeature(directory: folder)
        notes.phase = .foreground
        let id = try #require(notes.notes.first?.id)
        notes.setWindow(id, .top)
        notes.flush()
        let contents = try String(contentsOf: file, encoding: .utf8)
        #expect(contents == "---\nwindow: top\ntopdeck-id: \(id.uuidString)\nid: 20260901-standup\n---\nStandup")
    }

    @Test func aWindowedNoteEmptiedOutStaysInItsWindow() throws {
        let notes = NotesFeature(directory: folder)
        notes.phase = .foreground
        let id = notes.add()
        notes.update(id, text: "Sticky")
        notes.setWindow(id, .desktop)
        notes.flush()
        notes.update(id, text: "")
        notes.flush()

        let relaunched = NotesFeature(directory: folder)
        relaunched.loadWindowed()
        #expect(relaunched.windowed.map(\.id) == [id])

        relaunched.setWindow(id, nil)
        relaunched.flush()
        #expect(files().isEmpty, "back in the notch, an empty note isn't kept")
    }

    @Test func aChangeOnDiskReachesAWindowButNotOverUnsavedEdits() throws {
        let notes = NotesFeature(directory: folder)
        notes.phase = .foreground
        let id = notes.add()
        notes.update(id, text: "From here")
        notes.setWindow(id, .top)
        notes.flush()
        notes.phase = .stopped
        let file = folder.appending(path: "From here.md")
        let header = "---\nwindow: top\ntopdeck-id: \(id.uuidString)\n---\n"

        try (header + "From iCloud").write(to: file, atomically: true, encoding: .utf8)
        notes.loadWindowed()
        #expect(notes.windowed.first?.text == "From iCloud")

        notes.update(id, text: "Still typing")
        try (header + "From iCloud again").write(to: file, atomically: true, encoding: .utf8)
        notes.loadWindowed()
        #expect(notes.windowed.first?.text == "Still typing")
    }

    @Test func deletingAWindowedNoteTellsItsWindow() {
        let notes = NotesFeature(directory: folder)
        notes.phase = .foreground
        let id = notes.add()
        notes.update(id, text: "Gone")
        notes.setWindow(id, .top)
        var deleted: [Note.ID] = []
        notes.onDelete = { deleted.append($0) }
        notes.delete(id)
        #expect(deleted == [id])
        #expect(notes.windowed.isEmpty)
    }
}
