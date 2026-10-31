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
  them, and do not open their source files: MacTools at any later revision, AltTab, Ice, boring.notch,
  DockDoor, macshot, InputSourcePro, Cork.
- One exception: MacTools at commit `9197035650b67f1c313960e8b1dded7a710264dd`, the last Apache-2.0
  revision before its GPL move. Plugins in `Plugins/` at that commit may be adapted. Read only that
  commit, never a newer file, and take no fixes from later history. Keep its copyright notice, mark
  the code as changed, and record the commit in `THIRD_PARTY_NOTICES.md`. Do not use the MacTools
  name or branding.
- Topdeck stays MIT.

## Reuse sources

| Branch | Start from |
|---|---|
| `agent-approvals` | Atoll `Features/Agents`, `Features/AgentsUI` (MIT) |
| `window-manager` | Rectangle (MIT), and KeyboardShortcuts (MIT) for the shortcut recorder |
| `clipboard-plus` | Maccy (MIT) for ignore rules and plain paste, on the existing Clipboard feature |
| `capture-tools` | capcap (MIT), then OmniMac `Features/Tools` (MIT) for what it lacks |
| `input-switch` | MacTools `AutoInput` at the Apache-2.0 commit, or TypeSwitch (MIT) |
| `display-controls` | MonitorControl (MIT), MacTools `DisplayBrightness` and `DisplaySleep` at the Apache-2.0 commit |
| `keep-awake-plus` | The existing Keep Awake, then MacTools `KeepAwake` at the Apache-2.0 commit, without closed-lid mode |
| `storage-tools` | MacTools `XcodeClean` at the Apache-2.0 commit; OpenDisk (MIT) as a candidate for the disk browser |
| `system-admin` | MacTools `LaunchControl` and `Homebrew` at the Apache-2.0 commit |
| `r2-upload` | MacTools `CloudflareR2` at the Apache-2.0 commit, or Soto S3 (Apache-2.0) |
| Batch 3 | OmniMac for the window switcher and command bar, Stats (MIT) for performance |

## Scope

Kept from the base: notch surface, no-notch display support, Media, Shelf with AirDrop, Calendar,
Notes, Shortcuts, Timer, Keep Awake, Sound, AI Usage, Agents, volume HUD, Show in Notch.
Network stays for now and gets a keep-or-cut decision later.

Removed: Mirror, Android Quick Share, App Store edition, Sparkle updates, equaliser, app cleaner,
DMG installer, closed-lid keep awake (it needs a passwordless sudoers rule), fan control, charge
limit, hide notch, plugin marketplace, themes, workflow automation.

## Batches

Each line is one branch.

Batch 1 (merged):

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

Batch 2 (merged):

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

Batch 3 (merged): window switcher by windows, performance and battery health, command bar. Menu bar icon
hiding was part of it and was removed in round 3.

## Pinned notes

A note has three states: in the notch (default), pinned to the desktop, always on top.

- Desktop: borderless panel at `kCGDesktopIconWindowLevel + 1`, with
  `[.canJoinAllSpaces, .stationary, .ignoresCycle]`. Above the icons, below normal windows.
- On top: `.floating` level, plus `.fullScreenAuxiliary` so it shows over full-screen apps.
- Switching: from the note's row in the notch and from buttons shown on hover in the window. The
  window has no title bar.
- The window edits the same `NotesFeature` store as the notch. It must become key for typing, and
  Chinese input composition must work; do not intercept Escape during marked text.
- Saved state: `window: desktop|top` and a stable `topdeck-id:` in the note's front matter (plain
  `id:` belongs to other Markdown apps). Today a note
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

All work is local. Each feature gets a branch, implemented by a Sonnet or Haiku subagent in the
feature's folder, touching shared files only to register the feature. Logic goes in AppKit-free,
tested code, and warnings are errors. The primary session builds the branch on Xcode 27.1, reviews it,
waits for CI, and merges it to `main`. Nothing merges to `main` before review. Fred checks behaviour on
the Mac.

## Not yet verified on a Mac

- Agent approvals in the notch.
- R2 uploads against a real bucket.
- DDC on a real monitor.
- Scrolling capture.
- Window switcher.
- Command bar with Chinese input.
- Temperature and disk readings.
- Synced lyrics (`lyrics-lrclib`, LRCLIB) in the Now card with a real player.

The window switcher defaults to Option-Tab because Command-Tab needs an event tap.

## Now space

Now is rebuilt to the NowToday, NowPlaying, NowAlert, NowAdd, NowFree and NowMin boards. The Plan space and
the Reminders feature (Tasks, due alerts, time blocking, the Reminders permission) are removed; the
owner's Apple Reminders data is untouched. Calendar lives in Now, and Weather is new: Core Location
once (reduced accuracy), Apple's geocoder for the place name, and Apple's WeatherKit for the forecast
(no air quality), with coordinates rounded to two decimals. WeatherKit is a restricted entitlement, so
`scripts/sign-weather.sh` embeds a provisioning profile and signs with `App/Topdeck.weather.entitlements`
when one is installed; to get weather in your own build, make a profile with WeatherKit for your own App ID.

## Round 3

New colours (the black deck fades to `#10131B`, each space has an accent), a new app icon, and six spaces:
Now, Shelf and Clipboard in the left wing, Tools, Agents and Mac in the right. Stash is gone. Shelf (large thumbnail tiles and four
drop targets) and Clipboard (filters, search, list and a large preview) follow the `Shelf3` and `Clipboard3`
boards; every screenshot Topdeck takes goes into Clipboard's history. The old Media tab is gone, and with it
the waveform that listened to the system audio: the Sound tab keeps the audio permission for per-app volumes. There is no Notes tab: notes are in
Now (add field with colour and window, a list with a click-to-open window and a context menu), the folder and
sort order are in Settings, and search is in the Command Bar. The menu bar hider is removed along with its
Settings page. Settings gets one page, Shortcuts & Windows, for Windows, Window Switcher, Command Bar and
Input Sources. The bars in the closed notch while music plays move to a made-up pattern and capture no audio.
Wings: Now, Shelf, Clipboard; Tools, Agents, Mac.
