// SPDX-License-Identifier: MIT
import AppKit
import SwiftUI
import TopdeckSurface

/// A note's text in an AppKit text view. The view owns the text while it is edited, so the selection, undo and
/// an input method's marked text are left alone: the text goes out on every change, and comes back in only
/// when it differs and nothing is being composed, as when another app edited the file.
struct NoteTextEditor: NSViewRepresentable {
    @Binding var text: String

    private static let ink = NSColor(Deck.Paper.ink)

    private static let paragraphStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 4.5
        return style
    }()

    private static let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 13), .foregroundColor: ink, .paragraphStyle: paragraphStyle,
    ]

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NoteTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.drawsBackground = false
        textView.insertionPointColor = Self.ink
        textView.defaultParagraphStyle = Self.paragraphStyle
        textView.typingAttributes = Self.attributes
        textView.textContainerInset = NSSize(width: 5, height: 8)
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.setAccessibilityLabel("Note text")
        textView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: Self.attributes))

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.documentView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.text = $text
        guard let textView = scroll.documentView as? NSTextView, textView.string != text,
            !textView.hasMarkedText()
        else {
            return
        }
        let selection = textView.selectedRange()
        let offset = scroll.contentView.bounds.origin
        textView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: Self.attributes))
        // What undo would restore belongs to the text that was just replaced.
        textView.undoManager?.removeAllActions()
        let length = (text as NSString).length
        let start = min(selection.location, length)
        textView.setSelectedRange(NSRange(location: start, length: min(selection.length, length - start)))
        scroll.contentView.scroll(to: offset)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }
    }
}

/// Takes the click that makes its note's window key, so it starts typing at the clicked spot.
private final class NoteTextView: NSTextView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
