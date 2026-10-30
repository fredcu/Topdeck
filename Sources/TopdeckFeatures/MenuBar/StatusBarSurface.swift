// SPDX-License-Identifier: MIT
// Adapted from OmniMac (https://github.com/BySergiMM/OmniMac) at 6a56641: Features/MenuBar/MenuBarFeature.swift.
// Copyright (c) 2026 Sergi (BySergiMM). MIT License; changed for Topdeck: comments translated from Spanish.
// See THIRD_PARTY_NOTICES.md.
import AppKit

/// The hider's two status items. macOS puts each new item left of the last, so the expander ends up left
/// of the arrow, where it has to be to push the others away.
@MainActor
final class StatusBarSurface: MenuBarSurface {
    var onClick: (() -> Void)?
    private var separator: NSStatusItem?
    private var expander: NSStatusItem?
    private var collapsed = false
    private var screensObserver: (any NSObjectProtocol)?

    private static let arrowWidth: CGFloat = 24
    private static let dividerWidth: CGFloat = 10
    private static var isMacOS27: Bool { ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 }

    func install() {
        guard separator == nil else { return }
        let separator = Self.makeItem(named: MenuBarLayout.separatorName, length: Self.arrowWidth)
        separator.button?.target = self
        separator.button?.action = #selector(clicked)
        self.separator = separator

        let expander = Self.makeItem(named: MenuBarLayout.expanderName, length: Self.dividerWidth)
        // A mark, not a button.
        expander.button?.isEnabled = false
        self.expander = expander

        // The width depends on the screens, so it's worked out again when they change.
        screensObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.render(collapsed: self?.collapsed ?? false) }
        }
        render(collapsed: collapsed)
    }

    func remove() {
        if let screensObserver { NotificationCenter.default.removeObserver(screensObserver) }
        screensObserver = nil
        if let separator { NSStatusBar.system.removeStatusItem(separator) }
        if let expander { NSStatusBar.system.removeStatusItem(expander) }
        separator = nil
        expander = nil
    }

    func render(collapsed: Bool) {
        self.collapsed = collapsed
        expander?.length = collapsed ? pushWidth() : Self.dividerWidth
        // On macOS 27 a collapsed expander stays on screen, and its mark would float in the middle of nowhere.
        expander?.button?.image = collapsed && Self.isMacOS27 ? nil : Self.dividerImage()
        let image = NSImage(
            systemSymbolName: collapsed ? "chevron.left" : "chevron.right",
            accessibilityDescription: collapsed ? "Show hidden icons" : "Hide icons")
        image?.isTemplate = true
        separator?.button?.image = image
    }

    @objc private func clicked() { onClick?() }

    /// How far the expander's right edge is from the notch's right edge, and the same for any other
    /// screen with a notch; the smallest wins, so the expander crosses none of them.
    private func pushWidth() -> CGFloat {
        var gaps = NSScreen.screens.compactMap { $0.auxiliaryTopRightArea.map { Double($0.width) } }
        if let window = expander?.button?.window, let screen = window.screen, let right = screen.auxiliaryTopRightArea {
            gaps.append(Double(window.frame.maxX - (screen.frame.maxX - right.width)))
        }
        return CGFloat(
            MenuBarLayout.pushWidth(
                screenWidths: NSScreen.screens.map { Double($0.frame.width) }, macOS27: Self.isMacOS27,
                notchGap: Self.isMacOS27 ? gaps.filter { $0 > 0 }.min() : nil))
    }

    private static func makeItem(named name: String, length: CGFloat) -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: length)
        item.autosaveName = name
        return item
    }

    private static func dividerImage() -> NSImage {
        let image = NSImage(size: CGSize(width: 3, height: 13), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(
                roundedRect: CGRect(x: rect.midX - 0.75, y: 0, width: 1.5, height: rect.height),
                xRadius: 0.75, yRadius: 0.75
            ).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Icons to the left of this are hidden"
        return image
    }
}
