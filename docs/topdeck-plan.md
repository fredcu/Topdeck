# Topdeck plan

Topdeck is Fred's macOS notch and utility app. The base is ILoveNotch (MIT). Features come from
OmniMac (MIT), Atoll (MIT) and MacTools (GPL-3.0-only).

## Source rules

- Reuse first. Before writing a feature, check the source listed for it, then GitHub for something
  better. Only write what no suitable project covers.
- Allowed licences: MIT, BSD, Apache-2.0, ISC, zlib. Read the licence file, not GitHub's label.
- Adapted code keeps its copyright notice, and the source goes in `THIRD_PARTY_NOTICES.md`.
- All names in the project use Topdeck: modules, types that carry a project name, bundle IDs, URL
  schemes, log subsystems, data folders, keychain labels. Rename adapted code on the way in. The only
  place an upstream name may appear is its credit and copyright notice.
- GPL and non-free projects are behaviour references only. Never copy, translate or closely paraphrase
  them, and do not open their source files: MacTools, AltTab, Ice, boring.notch, DockDoor, macshot,
  InputSourcePro, Cork.
- Topdeck stays MIT.

## Reuse sources

| Branch | Start from |
|---|---|
| `agent-approvals` | Atoll `Features/Agents`, `Features/AgentsUI` (MIT) |
| `window-manager` | Rectangle (MIT), and KeyboardShortcuts (MIT) for the shortcut recorder |
| `clipboard-plus` | Maccy (MIT) for ignore rules and plain paste, on the existing Clipboard feature |
| `capture-tools` | capcap (MIT), then OmniMac `Features/Tools` (MIT) for what it lacks |
| `input-switch` | TypeSwitch (MIT) |
| `display-controls` | MonitorControl (MIT) |
| `keep-awake-plus` | The existing Keep Awake, then OmniMac `Features/KeepAwake` (MIT) without closed-lid mode |
| `storage-tools` | OpenDisk (MIT) as a candidate; evaluate before adopting |
| `system-admin` | No reusable project. Thin wrappers over `brew` JSON output and `launchctl` |
| `r2-upload` | Soto S3 (Apache-2.0) against the R2 endpoint |
| Batch 3 | OmniMac for the window switcher and command bar, Stats (MIT) for performance, hidden (MIT) for the menu bar |

## Scope

Kept from the base: notch surface, no-notch display support, Media, Shelf with AirDrop, Calendar,
Tasks, Notes, Shortcuts, Timer, Keep Awake, Sound, AI Usage, Agents, volume HUD, Show in Notch.
Network stays for now and gets a keep-or-cut decision later.

Removed: Mirror, Android Quick Share, App Store edition, Sparkle updates, equaliser, app cleaner,
DMG installer, closed-lid keep awake (it needs a passwordless sudoers rule), fan control, charge
limit, hide notch, plugin marketplace, themes, workflow automation.

## Batches

Each line is one branch and one cloud session.

Batch 1:

1. `sticky-notes`: pinned notes, design below.
2. `agent-approvals`: answer Claude Code and Codex permission requests and `AskUserQuestion` prompts
   from the notch. Adapt Atoll's blocking hook. Put the socket in the user's Application Support
   folder with `0600` set before listening, not in `/tmp`. If Topdeck is not running or does not
   answer, the agent's normal prompt must take over. Never approve by default.
3. `window-manager`: halves, thirds, quarters, almost-maximize, next display, drag-to-snap, saved
   layouts.
4. `clipboard-plus`: paste as plain text, strip link tracking parameters, app ignore list. Extend
   the existing Clipboard feature. Password manager content is never recorded.
5. `capture-tools`: area screenshot with annotation, pin an image on screen, OCR, QR recognition,
   colour picker, scrolling capture.

Batch 2:

6. `input-switch`: remember and switch the input source per app.
7. `display-controls`: per-display brightness and volume for external monitors over DDC, plus an
   action that sleeps all displays at once. Unsupported monitors show as unavailable.
8. `keep-awake-plus`: extend the existing Keep Awake with a keep-screen-on choice and timed or
   until-a-time sessions. No closed-lid mode.
9. `storage-tools`: Xcode clean by category (DerivedData, device support, archives, caches) and a
   disk usage browser. Scanning reads metadata only. Deletion goes to the Trash after a review list,
   and never follows symlinks.
10. `system-admin`: view and manage launchctl items in the user's domain, and a Homebrew package
    list with upgrade, uninstall and doctor. No privileged helper. Destructive actions confirm first.
11. `r2-upload`: upload files from the Shelf to Cloudflare R2. Keys live in the Keychain through the
    existing `APIKeyVault` and are never logged.

Batch 3: window switcher by windows, performance and battery health, menu bar icon hiding, command
bar.

## Pinned notes

A note has three states: in the notch (default), pinned to the desktop, always on top.

- Desktop: borderless panel at `kCGDesktopIconWindowLevel + 1`, with
  `[.canJoinAllSpaces, .stationary, .ignoresCycle]`. Above the icons, below normal windows.
- On top: `.floating` level, plus `.fullScreenAuxiliary` so it shows over full-screen apps.
- Switching: from the note's row in the notch and from buttons shown on hover in the window. The
  window has no title bar.
- The window edits the same `NotesFeature` store as the notch. It must become key for typing, and
  Chinese input composition must work; do not intercept Escape during marked text.
- Saved state: `window: desktop|top` and a stable `id:` in the note's front matter. Today a note
  named after its title gets a new ID on every launch, so window state cannot key on it.
- Frames: UserDefaults, keyed by note ID and display, so dragging does not rewrite the file.
- Unplugged display: move the window onto a visible screen and keep the saved frame for its return.
- Lifecycle: `FeatureHost` stops features while the notch is hidden or suspended. Pinned windows must
  keep loading and saving in that phase.
- Deleting a note closes its window. Restart restores all pinned windows.

Logic goes in testable code with no AppKit: front matter parsing, the frame store, screen placement.

Needs a real Mac: both levels with Spaces, full-screen apps, Stage Manager, Show Desktop, Chinese
input, and unplugging the external display.

## How work flows

Cloud sessions are Ubuntu x86_64 with no AppKit, SwiftUI or Xcode, so they cannot compile the app.
Each pushes a branch; CI on GitHub's macOS runners compiles and tests it. The session reads the
result, fixes failures, and stops when CI is green. Fred's primary session then fetches the branch,
builds it on Xcode 27.1, reviews it and merges it to `main`. Fred checks behaviour on the Mac.
