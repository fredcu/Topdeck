// SPDX-License-Identifier: MIT
import AppKit
import Testing
import TopdeckCore

@testable import TopdeckFeatures

/// On a private pasteboard, which macOS always lets an app read, never the user's own clipboard.
@MainActor
struct ClipboardTests {
    private let pasteboard = NSPasteboard(name: .init("TopdeckTests.\(UUID().uuidString)"))
    private let folder = FileManager.default.temporaryDirectory.appending(path: "Clipboard-\(UUID().uuidString)")
    private let defaults = UserDefaults(suiteName: "Clipboard.\(UUID().uuidString)")!

    private func clipboard(
        in app: (id: String?, name: String?) = ("com.apple.TextEdit", "TextEdit"),
        pasteInFront: @escaping @MainActor () -> Void = {}
    ) throws -> ClipboardFeature {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return ClipboardFeature(
            pasteboard: pasteboard, defaults: defaults, storeURL: folder.appending(path: "clipboard.json"),
            imagesURL: folder.appending(path: "Clipboard"), frontmostApp: { app }, pasteInFront: pasteInFront)
    }

    private func copy(_ text: String, marked type: String? = nil, from source: String? = nil, rtf: Data? = nil) {
        var types: [NSPasteboard.PasteboardType] = [.string]
        if let type { types.append(NSPasteboard.PasteboardType(type)) }
        if source != nil { types.append(NSPasteboard.PasteboardType(ClipboardRules.sourceType)) }
        if rtf != nil { types.append(.rtf) }
        pasteboard.clearContents()
        pasteboard.declareTypes(types, owner: nil)
        pasteboard.setString(text, forType: .string)
        if let source { pasteboard.setString(source, forType: NSPasteboard.PasteboardType(ClipboardRules.sourceType)) }
        if let rtf { pasteboard.setData(rtf, forType: .rtf) }
    }

    /// A recording clipboard with its feature running.
    private func recording(in app: (id: String?, name: String?) = ("com.apple.TextEdit", "TextEdit")) throws
        -> ClipboardFeature
    {
        let clipboard = try clipboard(in: app)
        clipboard.phase = .background
        clipboard.startRecording()
        return clipboard
    }

    @Test func nothingIsReadUntilTheUserTurnsItOn() throws {
        let clipboard = try clipboard()
        clipboard.phase = .background
        #expect(!clipboard.isRecording && !clipboard.isPolling, "off by default: no poll at all")
        clipboard.startRecording()
        #expect(clipboard.isRecording && clipboard.isPolling && clipboard.access == .allowed)
        clipboard.stopRecording()
        #expect(!clipboard.isPolling)
    }

    @Test func copiesAreKeptNewestFirstAndACopyAgainMovesToTheTop() throws {
        let clipboard = try clipboard()
        clipboard.phase = .background
        clipboard.startRecording()
        copy("first")
        clipboard.check()
        copy("https://example.com/page")
        clipboard.check()
        copy("first")
        clipboard.check()
        clipboard.check()  // nothing changed since
        #expect(clipboard.items.map(\.text) == ["first", "https://example.com/page"])
        #expect(clipboard.items.map(\.kind) == [.text, .link] && clipboard.items.first?.source == "TextEdit")
    }

    @Test func privateCopiesAndPasswordManagersAreSkipped() throws {
        let clipboard = try clipboard()
        clipboard.phase = .background
        clipboard.startRecording()
        copy("hunter2", marked: "org.nspasteboard.ConcealedType")
        clipboard.check()
        #expect(clipboard.items.isEmpty, "marked secret by the app that copied it")

        let manager = try self.clipboard(in: ("com.1password.1password", "1Password"))
        manager.phase = .background
        manager.startRecording()
        copy("correct horse battery staple")
        manager.check()
        #expect(manager.items.isEmpty, "copied in a password manager")
    }

    @Test(arguments: ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType"])
    func concealedAndTransientCopiesAreNeverKept(type: String) throws {
        let clipboard = try recording()
        copy("one-time code 123456", marked: type)
        clipboard.check()
        copy("kept")
        clipboard.check()
        #expect(clipboard.items.map(\.text) == ["kept"])
        clipboard.phase = .stopped
        let saved = try String(contentsOf: folder.appending(path: "clipboard.json"), encoding: .utf8)
        #expect(!saved.contains("123456"), "not on disk either")
    }

    @Test func aPasswordManagerNamedAsTheSourceIsSkippedWhateverIsInFront() throws {
        let clipboard = try recording(in: ("com.apple.Safari", "Safari"))
        copy("correct horse battery staple", from: "com.bitwarden.desktop")
        clipboard.check()
        #expect(clipboard.items.isEmpty)
    }

    @Test func appsTheUserSkipsAreLeftOutUntilRemoved() throws {
        let terminal = try recording(in: ("com.apple.Terminal", "Terminal"))
        terminal.ignoreApp("com.apple.Terminal")
        terminal.ignoreApp("com.apple.Terminal")
        #expect(terminal.ignoredApps == ["com.apple.Terminal"], "listed once")
        copy("export TOKEN=abc")
        terminal.check()
        #expect(terminal.items.isEmpty)

        let relaunched = try recording(in: ("com.apple.Terminal", "Terminal"))
        #expect(relaunched.ignoredApps == ["com.apple.Terminal"], "kept across launches")
        relaunched.stopIgnoringApp("com.apple.Terminal")
        copy("ls -la")
        relaunched.check()
        #expect(relaunched.items.map(\.text) == ["ls -la"])
    }

    @Test func linksLoseTheirTrackingOnlyWhenTheUserAsks() throws {
        let clipboard = try recording()
        copy("https://example.com/post?id=4&utm_source=newsletter")
        clipboard.check()
        #expect(clipboard.items.first?.text == "https://example.com/post?id=4&utm_source=newsletter", "off by default")

        clipboard.cleansLinks = true
        copy("https://example.com/post?id=5&utm_source=newsletter&fbclid=x")
        clipboard.check()
        copy("https://exa mple.com/?utm_source=x")
        clipboard.check()
        let unparsed = "https://exa mple.com/?utm_source=x"
        #expect(clipboard.items.map(\.text).prefix(2) == [unparsed, "https://example.com/post?id=5"], "unparsed: as is")
        #expect(try self.clipboard().cleansLinks, "kept across launches")
    }

    @Test func theKeystrokeFindsVInTheLayout() {
        #expect(PasteKeystroke.keyCode(for: "v") == 9, "the runner's U.S. layout")
    }

    @Test func formattingStaysUnlessPastedAsPlainText() throws {
        var pasted = 0
        let clipboard = try self.clipboard(pasteInFront: { pasted += 1 })
        clipboard.phase = .background
        clipboard.startRecording()
        let bold = NSAttributedString(string: "bold", attributes: [.font: NSFont.boldSystemFont(ofSize: 12)])
        let rtf = try #require(bold.rtf(from: NSRange(location: 0, length: bold.length), documentAttributes: [:]))
        copy("bold", rtf: rtf)
        clipboard.check()
        let item = try #require(clipboard.items.first)
        #expect(item.rich?[NSPasteboard.PasteboardType.rtf.rawValue] == rtf)

        clipboard.pick(item)
        #expect(pasteboard.data(forType: .rtf) == rtf && pasted == 0, "copied with its formatting, not pasted")

        clipboard.pick(item, plainText: true, paste: true)
        #expect(pasteboard.string(forType: .string) == "bold" && pasteboard.data(forType: .rtf) == nil)
        #expect(pasted == 1)

        clipboard.pastesAsPlainText = true
        clipboard.pastesAfterPicking = true
        clipboard.pick(item)
        #expect(pasteboard.data(forType: .rtf) == nil && pasted == 2, "the settings are the defaults")
        clipboard.check()
        #expect(clipboard.items.count == 1, "its own paste isn't a new copy")
    }

    @Test func filesAndImagesAreKeptAsWhatTheyAre() throws {
        let clipboard = try clipboard()
        clipboard.phase = .background
        clipboard.startRecording()
        pasteboard.clearContents()
        pasteboard.writeObjects([URL(filePath: "/tmp/Invoice.pdf") as NSURL])
        clipboard.check()
        #expect(clipboard.items.first?.kind == .files && clipboard.items.first?.paths == ["/tmp/Invoice.pdf"])

        let image = NSImage(size: CGSize(width: 40, height: 30), flipped: false) { rect in
            NSColor.systemOrange.setFill()
            rect.fill()
            return true
        }
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
        clipboard.check()
        let copied = try #require(clipboard.items.first)
        #expect(copied.kind == .image && clipboard.image(for: copied) != nil && clipboard.thumbnail(for: copied) != nil)
    }

    @Test func pickingPutsAnItemBackWithoutRecordingItTwice() throws {
        let clipboard = try clipboard()
        var picked = false
        clipboard.onPicked = { picked = true }
        clipboard.phase = .background
        clipboard.startRecording()
        for text in ["one", "two"] {
            copy(text)
            clipboard.check()
        }
        let one = try #require(clipboard.items.last)
        clipboard.pick(one)
        clipboard.check()
        #expect(pasteboard.string(forType: .string) == "one" && picked)
        #expect(clipboard.items.map(\.text) == ["one", "two"], "back at the top, and only once")
    }

    @Test func favoritesOutlastTheCapAndClearing() throws {
        let clipboard = try clipboard()
        clipboard.phase = .background
        clipboard.startRecording()
        copy("keep me")
        clipboard.check()
        clipboard.toggleFavorite(try #require(clipboard.items.first))
        for index in 0...ClipboardFeature.capacity {
            copy("copy \(index)")
            clipboard.check()
        }
        #expect(clipboard.items.count == ClipboardFeature.capacity && clipboard.items.contains { $0.text == "keep me" })
        #expect(clipboard.search("").first?.text == "keep me", "favorites come first")
        #expect(clipboard.search("copy 20").map(\.text) == ["copy 200", "copy 20"])
        clipboard.clear()
        #expect(clipboard.items.map(\.text) == ["keep me"])
    }

    @Test func selectedItemsAreDeletedTogetherFavoritesToo() throws {
        let clipboard = try clipboard()
        clipboard.phase = .background
        clipboard.startRecording()
        for text in ["one", "two", "three"] {
            copy(text)
            clipboard.check()
        }
        let two = try #require(clipboard.items.first { $0.text == "two" })
        clipboard.toggleFavorite(two)
        let three = try #require(clipboard.items.first { $0.text == "three" })
        clipboard.remove([two.id, three.id])
        #expect(clipboard.items.map(\.text) == ["one"])
        clipboard.phase = .stopped
        clipboard.phase = .background
        #expect(clipboard.items.map(\.text) == ["one"], "saved that way")
    }

    @Test func theHistoryIsSavedAndLetGoWhenStopped() throws {
        let clipboard = try clipboard()
        clipboard.phase = .background
        clipboard.startRecording()
        copy("saved")
        clipboard.check()
        clipboard.phase = .stopped
        #expect(clipboard.items.isEmpty && !clipboard.isPolling, "stopped: nothing in memory, no poll")
        clipboard.phase = .background
        #expect(clipboard.items.map(\.text) == ["saved"])
        #expect(try self.clipboard().isRecording, "recording stays on across launches")
    }
}
