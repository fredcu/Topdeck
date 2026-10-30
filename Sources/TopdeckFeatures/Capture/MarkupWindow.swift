// SPDX-License-Identifier: MIT
import AppKit
import Carbon.HIToolbox
import SwiftUI

/// What the editor hands back.
enum MarkupAction {
    case copy, shelf, pin, copyText
}

/// The capture editor: the capture with a toolbar of marks above it. Copy, Shelf, and Pin take the
/// marked-up capture and close it; Copy Text reads its text and leaves it open.
@MainActor
final class MarkupWindow: NSObject, NSWindowDelegate {
    private let capture: CaptureImage
    private let model = MarkupModel()
    private let window: NSWindow
    private let canvas: MarkupCanvas
    private let onAction: (MarkupAction, CaptureImage) -> Void
    /// Called once the window has closed.
    var onClose: (() -> Void)?

    init(capture: CaptureImage, onAction: @escaping (MarkupAction, CaptureImage) -> Void) {
        self.capture = capture
        self.onAction = onAction
        canvas = MarkupCanvas(capture: capture, model: model)
        let visible = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1280, height: 800)
        let toolbar: CGFloat = 52
        let size = CGSize(
            width: max(560, min(capture.pointSize.width, visible.width * 0.85)),
            height: max(240, min(capture.pointSize.height + toolbar, visible.height * 0.85)))
        window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        super.init()
        window.title = "Screenshot"
        window.isReleasedWhenClosed = false
        window.delegate = self
        let scroll = NSScrollView()
        scroll.documentView = canvas
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.1
        scroll.maxMagnification = 4
        scroll.backgroundColor = .underPageBackgroundColor
        let fit = min(1, (size.width - 20) / capture.pointSize.width)
        scroll.magnification = fit
        canvas.onEscape = { [weak self] in self?.window.close() }
        let root = MarkupView(model: model, scroll: scroll) { [weak self] action in self?.perform(action) }
        window.contentView = NSHostingView(rootView: root)
        model.onChange = { [weak canvas] in canvas?.needsDisplay = true }
    }

    func show() {
        window.center()
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

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("Tool", selection: $model.tool) {
                    ForEach(MarkTool.allCases) { tool in
                        Image(systemName: tool.symbol).help(tool.title).accessibilityLabel(tool.title).tag(tool)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                HStack(spacing: 4) {
                    ForEach(RGB.markColors, id: \.self) { color in swatch(color) }
                }
                Picker("Width", selection: $model.width) {
                    Image(systemName: "line.diagonal").accessibilityLabel("Thin").tag(CGFloat(2))
                    Image(systemName: "line.diagonal").fontWeight(.bold).accessibilityLabel("Medium").tag(CGFloat(4))
                    Image(systemName: "line.diagonal").fontWeight(.black).accessibilityLabel("Thick").tag(CGFloat(8))
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Button("Undo", systemImage: "arrow.uturn.backward", action: model.undo)
                    .labelStyle(.iconOnly)
                    .keyboardShortcut("z")
                    .disabled(!model.canUndo)
                Button("Redo", systemImage: "arrow.uturn.forward", action: model.redo)
                    .labelStyle(.iconOnly)
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!model.canRedo)
                Spacer(minLength: 0)
                Button("Copy Text", systemImage: "text.viewfinder") { perform(.copyText) }
                    .labelStyle(.iconOnly)
                Button("Pin", systemImage: "pin") { perform(.pin) }
                    .labelStyle(.iconOnly)
                Button("Add to Shelf", systemImage: "tray.and.arrow.down") { perform(.shelf) }
                    .labelStyle(.iconOnly)
                Button("Copy") { perform(.copy) }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            Divider()
            ScrollHost(scroll: scroll)
        }
    }

    private func swatch(_ color: RGB) -> some View {
        let chosen = model.color == color
        return Button {
            model.color = color
        } label: {
            Circle()
                .fill(color.color)
                .overlay(Circle().strokeBorder(.primary.opacity(chosen ? 0.9 : 0.25), lineWidth: chosen ? 2 : 1))
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Self.colorNames[RGB.markColors.firstIndex(of: color) ?? 0])
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }

    private static let colorNames = ["Red", "Yellow", "Green", "Blue", "White", "Black"]
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
