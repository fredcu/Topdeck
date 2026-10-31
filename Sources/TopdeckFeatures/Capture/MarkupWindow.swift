// SPDX-License-Identifier: MIT
import AppKit
import Carbon.HIToolbox
import SwiftUI
import TopdeckSurface

/// What the editor hands back.
enum MarkupAction {
    case copy, shelf, pin, copyText
}

/// The capture editor: the capture with a toolbar of marks above it. Copy, Shelf, and Pin take the
/// marked-up capture and close it; Copy Text reads its text and leaves it open.
@MainActor
final class MarkupWindow: NSObject, NSWindowDelegate {
    private let capture: CaptureImage
    let model = MarkupModel()
    let window: NSWindow
    private let canvas: MarkupCanvas
    private let onAction: (MarkupAction, CaptureImage) -> Void
    /// Called once the window has closed.
    var onClose: (() -> Void)?

    init(capture: CaptureImage, onAction: @escaping (MarkupAction, CaptureImage) -> Void) {
        self.capture = capture
        self.onAction = onAction
        canvas = MarkupCanvas(capture: capture, model: model)
        let visible = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1280, height: 800)
        let toolbar = Self.toolbarHeight
        let size = CGSize(
            width: max(Self.minimumWidth, min(capture.pointSize.width, visible.width * 0.85)),
            height: max(240, min(capture.pointSize.height + toolbar, visible.height * 0.85)))
        window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        window.title = "Screenshot"
        // The toolbar is the title bar: the traffic lights sit in its left end.
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(Deck.Floating.window)
        window.minSize = CGSize(width: Self.minimumWidth, height: 240)
        window.isReleasedWhenClosed = false
        window.delegate = self
        let scroll = NSScrollView()
        scroll.documentView = canvas
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.1
        scroll.maxMagnification = 4
        scroll.backgroundColor = NSColor(Deck.Floating.window)
        let fit = min(1, (size.width - 20) / capture.pointSize.width)
        scroll.magnification = fit
        canvas.onEscape = { [weak self] in self?.window.close() }
        let root = MarkupView(model: model, scroll: scroll) { [weak self] action in self?.perform(action) }
        window.contentView = NSHostingView(rootView: root)
        model.onChange = { [weak canvas] in canvas?.needsDisplay = true }
    }

    /// The toolbar's height, which is also the title bar's.
    private static let toolbarHeight: CGFloat = 52
    /// Wide enough for every tool and button.
    private static let minimumWidth: CGFloat = 880

    /// Centers the traffic lights in the toolbar by making the title bar as tall as it is.
    private func alignTrafficLights() {
        guard let bar = window.standardWindowButton(.closeButton)?.superview?.superview else { return }
        bar.frame = CGRect(
            x: 0, y: window.frame.height - Self.toolbarHeight, width: window.frame.width, height: Self.toolbarHeight)
    }

    func windowDidResize(_ notification: Notification) { alignTrafficLights() }

    func show() {
        window.center()
        alignTrafficLights()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(canvas)
    }

    func close() { window.close() }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }

    private func perform(_ action: MarkupAction) {
        canvas.endTextEditing()
        let image = MarkRenderer.render(capture.image, marks: model.marks, scale: capture.scale) ?? capture.image
        onAction(action, CaptureImage(image: image, scale: capture.scale))
        if action != .copyText { window.close() }
    }
}

private struct MarkupView: View {
    @Bindable var model: MarkupModel
    let scroll: NSScrollView
    let perform: (MarkupAction) -> Void

    /// The board's order, with the highlighter after the pen.
    private static let tools: [MarkTool] = [
        .select, .arrow, .rectangle, .ellipse, .pen, .highlighter, .text, .pixelate, .counter,
    ]
    private static let widths: [(label: String, value: CGFloat, line: CGFloat)] = [
        ("Thin", 2, 2), ("Medium", 4, 4), ("Thick", 8, 7),
    ]

    var body: some View {
        VStack(spacing: 0) {
            toolbar
                .padding(.leading, 84)
                .padding(.trailing, 12)
                .frame(height: 52)
            DeckSeparator()
            ScrollHost(scroll: scroll)
        }
        .background(Deck.Floating.window)
        .ignoresSafeArea()
    }

    private var toolbar: some View {
        HStack(spacing: 2) {
            ForEach(Self.tools) { tool in
                DeckIconButton(tool.deckIcon, label: tool.title, on: model.tool == tool) { model.tool = tool }
                    .accessibilityAddTraits(model.tool == tool ? .isSelected : [])
            }
            divider
            HStack(spacing: 0) {
                ForEach(RGB.markColors, id: \.self) { color in swatch(color) }
            }
            divider
            ForEach(Self.widths, id: \.value) { width in
                Button {
                    model.width = width.value
                } label: {
                    Capsule().fill(model.width == width.value ? Deck.text : Deck.secondary)
                        .frame(width: 14, height: width.line)
                        .frame(width: Deck.Metric.iconButton, height: Deck.Metric.iconButton)
                }
                .buttonStyle(.deckIcon(on: model.width == width.value))
                .help(width.label)
                .accessibilityLabel(width.label)
                .accessibilityAddTraits(model.width == width.value ? .isSelected : [])
            }
            Spacer(minLength: 8)
            DeckIconButton(.undo, label: "Undo", action: model.undo)
                .keyboardShortcut("z")
                .disabled(!model.canUndo)
            DeckIconButton(.undo, label: "Redo", action: model.redo)
                .scaleEffect(x: -1)
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!model.canRedo)
            DeckIconButton(.recognizeText, label: "Copy Text") { perform(.copyText) }
            DeckIconButton(.pin, label: "Pin") { perform(.pin) }
            DeckIconButton(.share, label: "Add to Shelf") { perform(.shelf) }
            Button("Copy") { perform(.copy) }
                .buttonStyle(.deck(.primary))
                .keyboardShortcut(.defaultAction)
                .padding(.leading, 4)
        }
    }

    private var divider: some View {
        Rectangle().fill(Deck.hairline).frame(width: 1, height: 22).padding(.horizontal, 8).accessibilityHidden(true)
    }

    private func swatch(_ color: RGB) -> some View {
        let chosen = model.color == color
        return Button {
            model.color = color
        } label: {
            Circle()
                .fill(color.color)
                .overlay(Circle().strokeBorder(Deck.hairline, lineWidth: 1))
                .frame(width: 20, height: 20)
                .overlay {
                    if chosen { Circle().strokeBorder(Deck.text, lineWidth: 1.5).frame(width: 26, height: 26) }
                }
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Self.colorNames[RGB.markColors.firstIndex(of: color) ?? 0])
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }

    private static let colorNames = ["Red", "Yellow", "Green", "Blue", "White", "Black"]
}

extension MarkTool {
    var deckIcon: DeckIcon {
        switch self {
        case .select: .cursor
        case .rectangle: .markupRectangle
        case .ellipse: .markupOval
        case .arrow: .markupArrow
        case .pen: .markupPen
        case .highlighter: .markupHighlighter
        case .text: .recognizeText
        case .pixelate: .markupMosaic
        case .counter: .markupNumber
        }
    }
}

private struct ScrollHost: NSViewRepresentable {
    let scroll: NSScrollView

    func makeNSView(context: Context) -> NSScrollView { scroll }

    func updateNSView(_ view: NSScrollView, context: Context) {}
}

/// The capture at its size in points, with its marks; pointer events go to the model.
private final class MarkupCanvas: NSView, NSTextFieldDelegate {
    private let capture: CaptureImage
    private let model: MarkupModel
    private var field: NSTextField?
    var onEscape: (() -> Void)?

    init(capture: CaptureImage, model: MarkupModel) {
        self.capture = capture
        self.model = model
        super.init(frame: CGRect(origin: .zero, size: capture.pointSize))
    }

    required init?(coder: NSCoder) { return nil }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    /// Dragging inside the capture draws; only the toolbar moves the window.
    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: model.tool == .select ? .arrow : model.tool == .text ? .iBeam : .crosshair)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        MarkRenderer.drawUpright(capture.image, in: bounds, context: context)
        for mark in model.marks + [model.draft].compactMap({ $0 }) {
            MarkRenderer.draw(mark, in: context, source: capture.image, scale: capture.scale)
        }
        if let index = model.selection, model.marks.indices.contains(index) {
            let outline = NSBezierPath(rect: model.marks[index].bounds.insetBy(dx: -3, dy: -3))
            outline.setLineDash([4, 3], count: 2, phase: 0)
            NSColor.controlAccentColor.setStroke()
            outline.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        if model.tool == .text {
            beginTextEditing(at: point)
        } else {
            model.press(at: point)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        model.drag(to: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        model.release(at: convert(event.locationInWindow, from: nil))
        window?.invalidateCursorRects(for: self)
    }

    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case kVK_Delete, kVK_ForwardDelete: model.deleteSelection()
        case kVK_Escape: onEscape?()
        default: super.keyDown(with: event)
        }
    }

    private func beginTextEditing(at point: CGPoint) {
        endTextEditing()
        let field = NSTextField(string: "")
        field.font = .systemFont(ofSize: Mark.fontSize(for: model.width), weight: .bold)
        field.textColor = NSColor(cgColor: model.color.cgColor)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = self
        field.placeholderString = "Text"
        field.frame = CGRect(x: point.x, y: point.y, width: max(120, bounds.maxX - point.x), height: 0)
        field.sizeToFit()
        field.frame.size.width = max(120, bounds.maxX - point.x)
        addSubview(field)
        window?.makeFirstResponder(field)
        self.field = field
    }

    /// Turns the text being typed into a mark.
    func endTextEditing() {
        guard let field else { return }
        self.field = nil
        model.addText(field.stringValue, at: field.frame.origin)
        field.removeFromSuperview()
        window?.makeFirstResponder(self)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        endTextEditing()
    }
}
