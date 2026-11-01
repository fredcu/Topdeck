# Changelog

## [0.1.0]

- The notch opens on Now every time, rather than on the space used last or the one an ongoing activity belongs to.
- Floating notes edit like a normal text editor: the text no longer jumps when the pointer enters, a save is not read back into the editor, and a note takes the keyboard only when you click into it or open it, not when the deck or the Command Bar closes.
- A space's name is no longer repeated under the navigation: pages with nothing of their own for the second row (an empty Shelf, Clipboard turned off, Tools, Mac) lose it, and pin and Settings move to the body's top right.
- Mac has a thermal strip with the system's state and the CPU, GPU, SSD and battery temperatures, six plainer tiles (with the battery's time left), the volume and brightness in one card, and a list of Sound, Displays, Network, Storage and System that shows where each stands. The busiest-processes table is gone from the page.
- Mac shows the GPU's temperature (from the SMC, read-only), leaves out a temperature the Mac does not give, and its System row shows what failed, what has updates or the busiest process instead of the macOS version. The System screen opens on the process table (sortable, with app icons and a CPU bar), then Services and Homebrew; it is there whenever Performance or System Admin is on.
- Tools is tidier: the capture tools are two toolbars, the recording options are three small toggles at the end of the second, recent captures are a grid without kind badges, and Timer, Keep Awake, Sleep Screen, Pick Colour and Shortcuts are one list with a pill on each row.
- An empty Shelf is a drop zone with an illustration and a Choose Files… button; with files, Add Files… is an icon in the second row, and dragging files over the tiles shows how many will be added.
- Recording stops only once on repeated clicks. Cancelling an export and retrying keeps the new task's state; exports use separate temporary files and replace an existing output without deleting it first.
- Topdeck starts from ILoveNotch 1.4.0, without Mirror, Android sharing, the App Store edition or Sparkle.
- A new deck: black at the notch, fading to a deep blue-grey, 700 by 430 to begin with, and a colour for each space. Six spaces sit in two wings beside the camera: Now, Shelf and Clipboard on the left, Tools, Agents and Mac on the right, with sub-tabs for Agents and Mac. Settings reorders and hides them. Now shows what's playing, the agent waiting, the day's events and notes, a month, the weather, the timer and Keep Awake. The Glass theme, the tab row and the app drawer are gone.
- Now's add field is an icon, the text and one style button: the icon shows whether the entry is an event or a note and switches it, and a note's colour and window are set in a small panel under the button.
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
- Monitors: set external monitors' brightness and volume over DDC, dim the picture of one that doesn't answer, and put every display to sleep.
- System Admin: start, stop, load, disable, and remove your launch agents, and upgrade, uninstall, and check Homebrew packages, from the notch. Off by default.
- Window Switcher: Option-Tab (or your own shortcut) shows every window with a thumbnail; type to filter, let go to pick. Off by default.
- Record Window and Record Screen: a three-second countdown in the closed notch, then a red dot and the clock with Pause and Stop; system audio and the microphone are switches in a popover and off to begin with. A recording is an MP4 in the Captures folder and opens in a video editor (trim, zoom that follows the cursor, crop, speed, background, audio; MP4 and GIF export) whose edits are kept beside the video.
