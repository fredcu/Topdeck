// SPDX-License-Identifier: MIT
import AppKit
import KeyboardShortcuts
import Observation
import SwiftUI
import TopdeckCore

/// Screen capture tools: an area screenshot to mark up, a scrolling capture, text and QR codes read
/// from an area, a colour picker, and images pinned on screen. Captures stay on this Mac: they go to
/// the clipboard, or to the Shelf from a file in Topdeck's own folder. Screen Recording is asked for
/// the first time a tool needs it, not before.
@MainActor
@Observable
public final class CaptureFeature: NotchFeature {
    public enum Tool: String, CaseIterable, Identifiable, Sendable {
        case screenshot, scrolling, text, qrCode, color, pin

        public var id: Self { self }

        public var title: String {
            switch self {
            case .screenshot: "Screenshot"
            case .scrolling: "Scrolling"
            case .text: "Text"
            case .qrCode: "QR Code"
            case .color: "Color"
            case .pin: "Pin"
            }
        }

        public var symbol: String {
            switch self {
            case .screenshot: "camera.viewfinder"
            case .scrolling: "scroll"
            case .text: "text.viewfinder"
            case .qrCode: "qrcode.viewfinder"
            case .color: "eyedropper"
            case .pin: "pin"
            }
        }
    }

    public let id = FeatureID.capture
    /// Nothing runs in the background: every tool starts from a click.
    public var phase: FeaturePhase = .stopped
    /// Colours picked, as hex codes, newest first.
    public private(set) var colors: [String] {
        didSet { defaults.set(colors, forKey: Self.colorsKey) }
    }
    /// Raised when something is copied, or a tool can't run.
    @ObservationIgnored public var onActivity: ((Activity) -> Void)?
    /// Puts files on the Shelf; false when the Shelf is off.
    @ObservationIgnored public var addToShelf: (([URL]) -> Bool)?
    /// Called as a tool starts, so the notch gets out of the way.
    @ObservationIgnored public var onBegin: (() -> Void)?
    /// Whether the tab is on; the shortcuts do nothing while it's off.
    @ObservationIgnored public var isEnabled: () -> Bool = { true }

    static let colorsKey = "capture.colors"
    static let askedKey = "capture.askedForScreenRecording"
    static let keptColors = 6
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let overlay = SelectionOverlay()
    @ObservationIgnored private var session: ScrollingSession?
    @ObservationIgnored private var sampler: NSColorSampler?
    @ObservationIgnored private var editors: [ObjectIdentifier: MarkupWindow] = [:]
    @ObservationIgnored private var pins: [ObjectIdentifier: PinnedImage] = [:]

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        colors = defaults.stringArray(forKey: Self.colorsKey) ?? []
        // Each tool's shortcut works from any app, with the notch closed.
        for tool in Tool.allCases {
            KeyboardShortcuts.onKeyDown(for: .capture(tool)) { [weak self] in
                guard let self, isEnabled() else { return }
                run(tool)
            }
        }
    }

    public var view: some View { CaptureView(capture: self) }

    public func run(_ tool: Tool) {
        guard !overlay.isActive, session == nil, sampler == nil else { return }
        onBegin?()
        if tool == .color {
            pickColor()
            return
        }
        guard ScreenGrab.hasAccess() else {
            askForAccess()
            return
        }
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
                if let image { self?.edit(image) }
            }
            self.session = session
            session.start()
            return
        }
        Task {
            do {
                let image = try await ScreenGrab.image(of: area, excluding: [overlayWindow])
                switch tool {
                case .pin: pin(image)
                case .text: readText(in: image)
                case .qrCode: readCodes(in: image)
                default: edit(image)
                }
            } catch {
                Log.features.error("Capture failed: \(error.localizedDescription, privacy: .public)")
                report("Couldn't capture the screen", symbol: "exclamationmark.triangle.fill")
            }
        }
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
            guard let png = CaptureFiles.png(capture.image) else { throw CocoaError(.fileWriteUnknown) }
            let url = try CaptureFiles.save(png, named: CaptureFiles.name(at: .now), in: CaptureFiles.folder)
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
