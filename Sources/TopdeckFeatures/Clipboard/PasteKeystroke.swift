// SPDX-License-Identifier: MIT
// Adapted from Maccy's Clipboard.paste() (https://github.com/p0deje/Maccy), Copyright (c) 2025 Alex Rodionov, MIT,
// which is based on Clipy's PasteService (MIT).
import ApplicationServices
import Carbon.HIToolbox

/// Pastes into the app in front by pressing ⌘V for the user. Posting key events needs Accessibility
/// access; without it macOS drops them, so callers check `VolumeKeyTap.isTrusted` first.
@MainActor
enum PasteKeystroke {
    /// Presses ⌘V once the notch has closed and the app the user copies into has the keyboard again.
    static func paste() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            post()
        }
    }

    private static func post() {
        let source = CGEventSource(stateID: .combinedSessionState)
        // The user's own keys stay out of the shortcut while it's pressed.
        source?.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents], state: .eventSuppressionStateSuppressionInterval)
        // 0x08 marks the left ⌘ key as the one held, which some apps check (Flycut pull request 18).
        let flags = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x08)
        let key = keyCode(for: "v")
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)
            event?.flags = flags
            event?.post(tap: .cgSessionEventTap)
        }
    }

    /// The key that types `character` with ⌘ held in the current keyboard layout, so ⌘V lands on
    /// Dvorak or AZERTY too, and on layouts that switch to QWERTY while ⌘ is down. Falls back to
    /// QWERTY's V.
    static func keyCode(for character: Character) -> CGKeyCode {
        let fallback = CGKeyCode(kVK_ANSI_V)
        // kTISPropertyUnicodeKeyLayoutData's value; the global itself isn't concurrency-safe in Swift 6.
        guard let input = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
            let property = TISGetInputSourceProperty(input, "TISPropertyUnicodeKeyLayoutData" as CFString),
            let target = character.utf16.first, character.utf16.count == 1
        else { return fallback }
        let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return fallback }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        let command = UInt32((cmdKey >> 8) & 0xFF)
        for code in CGKeyCode(0)..<128 {
            var deadKeys: UInt32 = 0
            var length = 0
            var typed = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(
                layout, code, UInt16(kUCKeyActionDisplay), command, UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeys, 4, &length, &typed)
            if status == OSStatus(noErr), length == 1, typed[0] == target { return code }
        }
        return fallback
    }
}
