// SPDX-License-Identifier: MIT
// Moving a window with AXEnhancedUserInterface switched off is adapted from Rectangle
// (https://github.com/rxhanson/Rectangle), Copyright (c) 2019-2026 Ryan Hanson, MIT License.
import AppKit
import ApplicationServices

/// Another app's window, read and moved through the Accessibility API. Frames here are in that API's
/// coordinates: the origin at the top left of the primary display, y going down.
@MainActor
struct AccessibilityWindow {
    let element: AXUIElement
    let pid: pid_t

    /// The frontmost app's focused window.
    static func focused() -> AccessibilityWindow? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = app.processIdentifier
        guard let window = element(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute) else { return nil }
        return AccessibilityWindow(element: window, pid: pid)
    }

    /// The window under `point`, in Accessibility coordinates.
    static func window(at point: CGPoint) -> AccessibilityWindow? {
        var hit: AXUIElement?
        let status = AXUIElementCopyElementAtPosition(
            AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit)
        guard status == .success, let hit else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(hit, &pid) == .success, pid != getpid() else { return nil }
        let isWindow = string(hit, kAXRoleAttribute) == kAXWindowRole
        guard let window = isWindow ? hit : element(hit, kAXWindowAttribute) else { return nil }
        return AccessibilityWindow(element: window, pid: pid)
    }

    /// An app's standard windows that aren't minimized, front to back.
    static func windows(of pid: pid_t) -> [AccessibilityWindow] {
        var value: CFTypeRef?
        let app = AXUIElementCreateApplication(pid)
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
            let elements = value as? [AXUIElement]
        else { return [] }
        return elements.map { AccessibilityWindow(element: $0, pid: pid) }
            .filter { $0.isStandard && !$0.isMinimized }
    }

    var title: String { Self.string(element, kAXTitleAttribute) ?? "" }

    var isStandard: Bool { Self.string(element, kAXSubroleAttribute) == kAXStandardWindowSubrole }

    var isMinimized: Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXMinimizedAttribute as CFString, &value) == .success else {
            return false
        }
        return value as? Bool ?? false
    }

    var frame: CGRect? {
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard let position = Self.value(element, kAXPositionAttribute), AXValueGetValue(position, .cgPoint, &origin),
            let extent = Self.value(element, kAXSizeAttribute), AXValueGetValue(extent, .cgSize, &size)
        else { return nil }
        return CGRect(origin: origin, size: size)
    }

    /// Moves and resizes the window. Size goes first and again last, so a window that couldn't grow
    /// where it was gets its full size once it has moved. Apps with AXEnhancedUserInterface on (set
    /// for VoiceOver and some window tools) animate and fight each change, so it's off meanwhile.
    func setFrame(_ frame: CGRect) {
        let app = AXUIElementCreateApplication(pid)
        let enhanced = "AXEnhancedUserInterface" as CFString
        var value: CFTypeRef?
        let wasEnhanced =
            AXUIElementCopyAttributeValue(app, enhanced, &value) == .success && (value as? Bool ?? false)
        if wasEnhanced { AXUIElementSetAttributeValue(app, enhanced, kCFBooleanFalse) }
        set(size: frame.size)
        set(origin: frame.origin)
        set(size: frame.size)
        if wasEnhanced { AXUIElementSetAttributeValue(app, enhanced, kCFBooleanTrue) }
    }

    private func set(origin: CGPoint) {
        var origin = origin
        guard let value = AXValueCreate(.cgPoint, &origin) else { return }
        AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
    }

    private func set(size: CGSize) {
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else { return }
        AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value)
    }

    // MARK: Attributes

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success, let value,
            CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private static func value(_ element: AXUIElement, _ attribute: String) -> AXValue? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success, let value,
            CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        return unsafeDowncast(value, to: AXValue.self)
    }
}

extension NSScreen {
    /// The display's UUID, which, unlike its number, stays the same across reconnects and restarts.
    var windowDisplayUUID: String {
        let number = (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(number)?.takeRetainedValue() else { return "\(number)" }
        return CFUUIDCreateString(nil, uuid) as String
    }
}
