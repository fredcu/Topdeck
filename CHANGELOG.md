# Changelog

## [0.1.0]

- Recording stops only once on repeated clicks. Cancelling an export and retrying keeps the new task's state; exports use separate temporary files and replace an existing output without deleting it first.
- Topdeck starts from ILoveNotch 1.4.0, without Mirror, Android sharing, the App Store edition or Sparkle.
- A new deck: black at the notch, fading to a deep blue-grey, 700 by 430 to begin with, and a colour for each space. Six spaces sit in two wings beside the camera: Now, Shelf and Clipboard on the left, Tools, Agents and Mac on the right, with sub-tabs for Agents and Mac. Settings reorders and hides them. Now shows what's playing, the agent waiting, the day's events and notes, a month, the weather, the timer and Keep Awake. The Glass theme, the tab row and the app drawer are gone.
- Notes live in Now: the add field takes a colour and a window, a click opens a note in a floating window, and a right-click colours, pins, shares, reveals or deletes it. Search is in the Command Bar.
- Settings has one page, Shortcuts & Windows, for Windows, Window Switcher, Command Bar and Input Sources.
- While music plays, four thin bars in the cover's colour move beside the camera.
- The closed notch shows what an activity is to the left of the camera and its state to the right, and a file dragged near becomes a drop target for the shelf.
- A new app icon and menu bar glyph.
- Windows: shortcuts for halves, thirds, quarters, almost maximize and the next display, drag to snap, and saved
  layouts.
- Clipboard pastes into the app in front, as plain text if you like, removes tracking from links, and skips apps you list.
- Agents: answer Claude Code and Codex permission requests and Claude's questions from the notch.
- Agents has three columns like Now: sessions (or the period's total, share and last 30 days) on the left, and a table with each tool's spend beside its quota on the right.
- Keep Awake: keep the screen on or let it sleep, and stay awake until a chosen time.
- Input Sources: each app gets its own keyboard input source when you switch to it, Chinese ones included.
- Storage: clean Xcode's DerivedData, device support, archives, and caches, and see what fills the home folder. Items go to the Trash after a review.
- Shelf: upload a file to your Cloudflare R2 bucket from its menu and copy its link. Keys stay in the keychain.
- Monitors: set external monitors' brightness and volume over DDC, and put every display to sleep.
- System Admin: start, stop, load, disable, and remove your launch agents, and upgrade, uninstall, and check Homebrew packages, from the notch. Off by default.
- Window Switcher: Option-Tab (or your own shortcut) shows every window with a thumbnail; type to filter, let go to pick. Off by default.
- Record Window and Record Screen: a three-second countdown in the closed notch, then a red dot and the clock with Pause and Stop; system audio and the microphone are switches in a popover and off to begin with. A recording is an MP4 in the Captures folder and opens in a video editor (trim, zoom that follows the cursor, crop, speed, background, audio; MP4 and GIF export) whose edits are kept beside the video.
