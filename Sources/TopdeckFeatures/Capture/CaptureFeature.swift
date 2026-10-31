// SPDX-License-Identifier: MIT
import AppKit
import KeyboardShortcuts
import Observation
import SwiftUI
import TopdeckCore
import UniformTypeIdentifiers

/// Screen capture tools: an area screenshot to mark up, a scrolling capture, text and QR codes read
/// from an area, a colour picker, and images pinned on screen. Captures stay on this Mac: they go to
/// the clipboard, or to the Shelf from a file in Topdeck's own folder. Screen Recording is asked for
/// the first time a tool needs it, not before. Window and screen recordings are the same tools with a
/// countdown and a clock (`RecordingController`), and they open the video editor when they are stopped.
@MainActor
@Observable
public final class CaptureFeature: NotchFeature {
    public enum Tool: String, CaseIterable, Identifiable, Sendable {
        case screenshot, window, screen, scrolling, text, qrCode, color, pin, recordWindow, recordScreen

        public var id: Self { self }

        public var title: String {
            switch self {
            case .screenshot: "Screenshot"
            case .window: "Window"
            case .screen: "Screen"
            case .scrolling: "Scrolling"
            case .text: "Text"
            case .qrCode: "QR Code"
            case .color: "Color"
            case .pin: "Pin"
            case .recordWindow: "Record Window"
            case .recordScreen: "Record Screen"
            }
        }

        public var symbol: String {
            switch self {
            case .screenshot: "camera.viewfinder"
            case .window: "macwindow"
            case .screen: "display"
            case .scrolling: "scroll"
            case .text: "text.viewfinder"
            case .qrCode: "qrcode.viewfinder"
            case .color: "eyedropper"
            case .pin: "pin"
            case .recordWindow, .recordScreen: "record.circle"
            }
        }

        var isRecording: Bool { self == .recordWindow || self == .recordScreen }
    }

    public let id = FeatureID.capture
    /// Nothing runs in the background: every tool starts from a click.
    public var phase: FeaturePhase = .stopped {
        didSet { if phase == .foreground, oldValue != .foreground { reloadRecents() } }
    }
    /// The newest captures kept in the Captures folder, newest first.
    public private(set) var recents: [RecentCapture] = []
    /// Colours picked, as hex codes, newest first.
    public private(set) var colors: [String] {
        didSet { defaults.set(colors, forKey: Self.colorsKey) }
    }
    /// Raised when something is copied, or a tool can't run.
    @ObservationIgnored public var onActivity: ((Activity) -> Void)?
    /// Puts files on the Shelf; false when the Shelf is off.
    @ObservationIgnored public var addToShelf: (([URL]) -> Bool)?
    /// Raised with the PNG of every screenshot taken, for the Clipboard's history. Not for recordings.
    @ObservationIgnored public var onScreenshot: ((Data) -> Void)?
    /// Called as a tool starts, so the notch gets out of the way.
    @ObservationIgnored public var onBegin: (() -> Void)?
    /// Whether the tab is on; the shortcuts do nothing while it's off.
    @ObservationIgnored public var isEnabled: () -> Bool = { true }
    /// Opens a video in the editor. Without one, a video opens in its own app.
    @ObservationIgnored public var openEditor: ((URL) -> Void)?
    /// Window and screen recording.
    public let recorder: RecordingController

    static let colorsKey = "capture.colors"
    static let askedKey = "capture.askedForScreenRecording"
    static let keptColors = 6
    /// How many recent captures are listed; the folder keeps them all.
    nonisolated static let listedRecents = 8
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let folder: URL?
    @ObservationIgnored let thumbnails = CaptureThumbnails()
    @ObservationIgnored private let overlay = SelectionOverlay()
    @ObservationIgnored private let windowPicker = WindowPicker()
    @ObservationIgnored private var session: ScrollingSession?
    @ObservationIgnored private var sampler: NSColorSampler?
    @ObservationIgnored private var editors: [ObjectIdentifier: MarkupWindow] = [:]
    @ObservationIgnored private var pins: [ObjectIdentifier: PinnedImage] = [:]

    /// `folder` is where captures are kept: Topdeck's Captures folder unless a test gives its own.
    public convenience init(defaults: UserDefaults = .standard, folder: URL? = nil) {
        self.init(
            defaults: defaults, folder: folder,
            recorder: RecordingController(defaults: defaults, folder: { folder ?? CaptureFiles.folder }))
    }

    init(defaults: UserDefaults, folder: URL?, recorder: RecordingController) {
        self.defaults = defaults
        self.folder = folder
        self.recorder = recorder
        colors = defaults.stringArray(forKey: Self.colorsKey) ?? []
        // Each tool's shortcut works from any app, with the notch closed.
        for tool in Tool.allCases {
            KeyboardShortcuts.onKeyDown(for: .capture(tool)) { [weak self] in
                guard let self, isEnabled() else { return }
                run(tool)
            }
        }
        recorder.onSaved = { [weak self] url, open in self?.recordingSaved(url, opening: open) }
    }

    public var view: some View { CaptureView(capture: self) }

    private var capturesFolder: URL { folder ?? CaptureFiles.folder }

    public func run(_ tool: Tool) {
        // A second press of a Record tile ends the recording, or cancels its countdown.
        if tool.isRecording, recorder.isActive {
            recorder.stop()
            return
        }
        guard !overlay.isActive, !windowPicker.isActive, session == nil, sampler == nil else { return }
        onBegin?()
        if tool == .color {
            pickColor()
            return
        }
        guard ScreenGrab.hasAccess() else {
            askForAccess()
            return
        }
        switch tool {
        case .window: pickWindow()
        case .screen: captureScreen()
        case .recordWindow: pickWindowToRecord()
        case .recordScreen: recordScreen()
        default: pickArea(for: tool)
        }
    }

    // MARK: Recording

    /// The window highlight and pick overlay, then the countdown.
    private func pickWindowToRecord() {
        windowPicker.begin { [weak self] picked, _, _ in self?.recorder.begin(.window(picked.id)) }
    }

    /// The only display, or the one the user picks from a menu when there are several (the one under the
    /// pointer, where the deck is, first).
    private func recordScreen() {
        let pointer = NSEvent.mouseLocation
        let screens = NSScreen.screens.sorted { a, _ in a.frame.contains(pointer) }
        let displays = screens.compactMap { screen in screen.displayID.map { (screen.localizedName, $0) } }
        guard displays.count > 1 else {
            if let only = displays.first { recorder.begin(.screen(only.1)) }
            return
        }
        let chooser = DisplayMenu { [weak self] id in self?.recorder.begin(.screen(id)) }
        chooser.show(displays)
    }

    /// Escape during the countdown. False when there is none.
    @discardableResult
    public func cancelRecordingCountdown() -> Bool { recorder.cancelCountdown() }

    /// A recording was saved: it joins the recent captures, and the editor opens on it unless it ended in a failure.
    private func recordingSaved(_ url: URL, opening: Bool) {
        reloadRecents()
        if opening { openVideo(url) }
    }

    // MARK: Video

    /// Opens a video in the editor, or in its own app when there is none.
    public func openVideo(_ url: URL) {
        if let openEditor { openEditor(url) } else { NSWorkspace.shared.open(url) }
    }

    /// Asks for a video, starting in the Captures folder, and opens it in the editor.
    public func editVideo() {
        onBegin?()
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie, .movie]
        panel.allowsMultipleSelection = false
        panel.directoryURL = capturesFolder
        NSApp.activate()
        if panel.runModal() == .OK, let url = panel.url { openVideo(url) }
    }

    private func pickWindow() {
        windowPicker.begin { [weak self] picked, _, _ in
            self?.finish { try await ScreenGrab.image(ofWindow: picked.id) }
        }
    }

    /// The whole display under the pointer, once the notch has gone.
    private func captureScreen() {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main,
            let area = CaptureArea(screen.frame, on: screen)
        else { return }
        finish {
            try await Task.sleep(for: .milliseconds(350))
            return try await ScreenGrab.image(of: area, excluding: [])
        }
    }

    /// Takes the picture `grab` makes, keeps it and opens it in the editor.
    private func finish(_ grab: @escaping @MainActor () async throws -> CaptureImage) {
        Task {
            do {
                let image = try await grab()
                keep(image)
                edit(image)
            } catch {
                Log.features.error("Capture failed: \(error.localizedDescription, privacy: .public)")
                report("Couldn't capture the screen", symbol: "exclamationmark.triangle.fill")
            }
        }
    }

    private func pickArea(for tool: Tool) {
        overlay.begin { [weak self] rect, screen, window in
            self?.selected(rect, on: screen, overlayWindow: window, for: tool)
        }
    }

    /// Forgets the colours picked so far.
    public func clearColors() { colors = [] }

    /// Copies a colour picked earlier again.
    public func copyColor(_ code: String) {
        copy(code)
        report("Copied \(code)", symbol: "eyedropper")
    }

    /// macOS asks once, the first time. After that, only System Settings can allow it.
    private func askForAccess() {
        if defaults.bool(forKey: Self.askedKey) {
            NSWorkspace.shared.open(.privacySettings("Privacy_ScreenCapture"))
        }
        defaults.set(true, forKey: Self.askedKey)
        report("Allow Screen Recording", symbol: "rectangle.dashed.badge.record")
    }

    private func selected(_ rect: CGRect, on screen: NSScreen, overlayWindow: Int, for tool: Tool) {
        guard let area = CaptureArea(rect, on: screen) else { return }
        if tool == .scrolling {
            let session = ScrollingSession(area: area, rect: rect, screen: screen) { [weak self] image in
                self?.session = nil
                if let image {
                    self?.keep(image)
                    self?.edit(image)
                }
            }
            self.session = session
            session.start()
            return
        }
        Task {
            do {
                let image = try await ScreenGrab.image(of: area, excluding: [overlayWindow])
                switch tool {
                case .pin:
                    keep(image)
                    pin(image)
                case .text: readText(in: image)
                case .qrCode: readCodes(in: image)
                default:
                    keep(image)
                    edit(image)
                }
            } catch {
                Log.features.error("Capture failed: \(error.localizedDescription, privacy: .public)")
                report("Couldn't capture the screen", symbol: "exclamationmark.triangle.fill")
            }
        }
    }

    /// Hands a screenshot on, as a PNG, to whoever keeps them, and keeps it in the Captures folder, where
    /// the Tools screen lists it.
    private func keep(_ capture: CaptureImage) {
        guard let png = CaptureFiles.png(capture.image, scale: capture.scale) else { return }
        onScreenshot?(png)
        let folder = capturesFolder
        let name = CaptureFiles.name(at: .now)
        Task.detached(priority: .utility) { [weak self] in
            _ = try? CaptureFiles.save(png, named: name, in: folder)
            await self?.reloadRecents()
        }
    }

    /// Looks at the Captures folder again, off the main thread.
    public func reloadRecents() {
        let folder = capturesFolder
        Task.detached(priority: .utility) { [weak self] in
            let found = CaptureLibrary.recent(in: folder, limit: Self.listedRecents)
            await MainActor.run { if self?.recents != found { self?.recents = found } }
        }
    }

    /// Opens a recent capture: a picture in the editor, a recording or GIF in its own app.
    public func open(_ capture: RecentCapture) {
        if capture.kind == .mp4 { return openVideo(capture.url) }
        guard capture.kind == .png, let image = CaptureLibrary.image(at: capture.url) else {
            NSWorkspace.shared.open(capture.url)
            return
        }
        onBegin?()
        edit(image)
    }

    /// Puts a recent capture on the pasteboard: a picture as a picture, anything else as the file.
    public func copy(_ capture: RecentCapture) {
        if capture.kind == .png, let image = CaptureLibrary.image(at: capture.url) {
            copy(image)
        } else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([capture.url as NSURL])
            report("Copied", symbol: "doc.on.clipboard.fill")
        }
    }

    public func reveal(_ capture: RecentCapture) {
        NSWorkspace.shared.activateFileViewerSelecting([capture.url])
    }

    /// Moves a capture to the Trash, where it can be put back.
    public func delete(_ capture: RecentCapture) {
        try? FileManager.default.trashItem(at: capture.url, resultingItemURL: nil)
        // A recording's cursor track and edits go with it.
        for sidecar in [CursorTrack.url(for: capture.url)]
        where FileManager.default.fileExists(atPath: sidecar.path) {
            try? FileManager.default.trashItem(at: sidecar, resultingItemURL: nil)
        }
        thumbnails.forget(capture)
        recents.removeAll { $0.id == capture.id }
        reloadRecents()
    }

    private func edit(_ capture: CaptureImage) {
        let editor = MarkupWindow(capture: capture) { [weak self] action, image in self?.perform(action, with: image) }
        let key = ObjectIdentifier(editor)
        editor.onClose = { [weak self] in
            Task { @MainActor in self?.editors[key] = nil }
        }
        editors[key] = editor
        editor.show()
    }

    private func perform(_ action: MarkupAction, with capture: CaptureImage) {
        switch action {
        case .copy: copy(capture)
        case .shelf: shelve(capture)
        case .pin: pin(capture)
        case .copyText: readText(in: capture)
        }
    }

    private func pin(_ capture: CaptureImage) {
        let pinned = PinnedImage(
            capture: capture, copy: { [weak self] in self?.copy($0) }, shelve: { [weak self] in self?.shelve($0) })
        let key = ObjectIdentifier(pinned)
        pinned.onClose = { [weak self] in
            Task { @MainActor in self?.pins[key] = nil }
        }
        pins[key] = pinned
        pinned.show()
    }

    private func copy(_ capture: CaptureImage) {
        guard let png = CaptureFiles.png(capture.image) else {
            report("Couldn't copy the screenshot", symbol: "exclamationmark.triangle.fill")
            return
        }
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        if let tiff = NSBitmapImageRep(cgImage: capture.image).tiffRepresentation {
            item.setData(tiff, forType: .tiff)
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([item])
        report("Copied", symbol: "doc.on.clipboard.fill")
    }

    /// Saves the capture in Topdeck's Captures folder and puts the file on the Shelf. With the Shelf
    /// off, it's copied instead.
    private func shelve(_ capture: CaptureImage) {
        do {
            guard let png = CaptureFiles.png(capture.image, scale: capture.scale) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let url = try CaptureFiles.save(png, named: CaptureFiles.name(at: .now), in: capturesFolder)
            if addToShelf?([url]) != true { copy(capture) }
        } catch {
            Log.features.error("Couldn't save a capture: \(error.localizedDescription, privacy: .public)")
            copy(capture)
        }
    }

    private func readText(in capture: CaptureImage) {
        Task {
            let text = await Task.detached(priority: .userInitiated) { TextRecognition.text(in: capture.image) }.value
            guard !text.isEmpty else {
                report("No text found", symbol: "text.viewfinder")
                return
            }
            copy(text)
            report("Copied text", symbol: "text.viewfinder")
        }
    }

    private func readCodes(in capture: CaptureImage) {
        Task {
            let codes = await Task.detached(priority: .userInitiated) { TextRecognition.codes(in: capture.image) }.value
            guard !codes.isEmpty else {
                report("No QR code found", symbol: "qrcode.viewfinder")
                return
            }
            copy(codes.joined(separator: "\n"))
            let link = codes.count == 1 && URL(string: codes[0])?.scheme?.hasPrefix("http") == true
            report(link ? "Copied link" : "Copied QR code", symbol: "qrcode.viewfinder")
        }
    }

    private func pickColor() {
        let sampler = NSColorSampler()
        self.sampler = sampler
        sampler.show { [weak self] color in
            let code = color.flatMap(Self.code)
            Task { @MainActor in self?.picked(code) }
        }
    }

    private func picked(_ code: String?) {
        sampler = nil
        guard let code else { return }
        colors = Array(([code] + colors.filter { $0 != code }).prefix(Self.keptColors))
        copyColor(code)
    }

    private nonisolated static func code(_ color: NSColor) -> String? {
        guard let sRGB = color.usingColorSpace(.sRGB) else { return nil }
        let red = Double(sRGB.redComponent)
        return ColorCode.hex(red: red, green: Double(sRGB.greenComponent), blue: Double(sRGB.blueComponent))
    }

    private func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    private func report(_ title: String, symbol: String) {
        onActivity?(Activity(feature: .capture, symbol: symbol, title: title, duration: .seconds(2)))
    }
}

extension KeyboardShortcuts.Name {
    /// Each tool's shortcut. Screenshot starts as Control-Option-S; the others start without one.
    static func capture(_ tool: CaptureFeature.Tool) -> Self {
        let name = "capture" + tool.rawValue.prefix(1).uppercased() + tool.rawValue.dropFirst()
        return Self(name, initial: tool == .screenshot ? .init(.s, modifiers: [.control, .option]) : nil)
    }
}

/// A menu of displays, shown at the pointer: Record Screen with several to choose from.
@MainActor
private final class DisplayMenu: NSObject {
    private let chosen: (CGDirectDisplayID) -> Void

    init(chosen: @escaping (CGDirectDisplayID) -> Void) { self.chosen = chosen }

    func show(_ displays: [(String, CGDirectDisplayID)]) {
        let menu = NSMenu()
        for (name, id) in displays {
            let item = NSMenuItem(title: name, action: #selector(pick(_:)), keyEquivalent: "")
            item.target = self
            item.tag = Int(id)
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    @objc private func pick(_ item: NSMenuItem) { chosen(CGDirectDisplayID(item.tag)) }
}
