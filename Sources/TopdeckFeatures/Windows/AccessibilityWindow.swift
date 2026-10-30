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

    /// How long one call may wait on an app. A hung app would otherwise block the main actor for the
    /// system default of six seconds.
    private static let timeout: Float = 0.25

    private static func bounded(_ element: AXUIElement) -> AXUIElement {
        AXUIElementSetMessagingTimeout(element, timeout)
        return element
    }

    /// The frontmost app's focused window.
    static func focused() -> AccessibilityWindow? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = app.processIdentifier
        guard let window = element(bounded(AXUIElementCreateApplication(pid)), kAXFocusedWindowAttribute) else {
            return nil
        }
        return AccessibilityWindow(element: bounded(window), pid: pid)
    }

    /// The window under `point`, in Accessibility coordinates.
    static func window(at point: CGPoint) -> AccessibilityWindow? {
        var hit: AXUIElement?
        let status = AXUIElementCopyElementAtPosition(
            bounded(AXUIElementCreateSystemWide()), Float(point.x), Float(point.y), &hit)
        guard status == .success, let hit = hit.map(bounded) else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(hit, &pid) == .success, pid != getpid() else { return nil }
        let isWindow = string(hit, kAXRoleAttribute) == kAXWindowRole
        guard let window = isWindow ? hit : element(hit, kAXWindowAttribute) else { return nil }
        return AccessibilityWindow(element: bounded(window), pid: pid)
    }

    /// An app's standard windows, front to back; minimized ones only when asked for.
    static func windows(of pid: pid_t, includingMinimized: Bool = false) -> [AccessibilityWindow] {
        var value: CFTypeRef?
        let app = bounded(AXUIElementCreateApplication(pid))
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
            let elements = value as? [AXUIElement]
        else { return [] }
        return elements.map { AccessibilityWindow(element: bounded($0), pid: pid) }
            .filter { $0.isStandard && (includingMinimized || !$0.isMinimized) }
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
        let app = Self.bounded(AXUIElementCreateApplication(pid))
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

    /// Brings the window to the front, restoring it if it's minimized, and its app with it.
    func raise() {
        AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(
            Self.bounded(AXUIElementCreateApplication(pid)), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
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
