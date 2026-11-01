# Topdeck design spec

Approved design: the artboards in `docs/design/`, one `.dc.html` file each, styled by
`docs/design/deck.css`. They are the source of truth for layout, sizes, colours and copy; open them
in a browser if it helps. This file states what the boards can't. Round 3 (`NowColor3`, `NowPlay3`,
`NoteAdd3`) sets the colours and Now; `Shelf3` and `Clipboard3` set those two spaces; `Agents3`, `Tools3` and
`Mac3` set those three; `Editor3` sets the video editor. Where an older board disagrees with a
round 3 one, round 3 wins. App icon: `docs/design/icon-paper.svg`.

## Tokens

Put these in one Swift file in `TopdeckSurface`, public, used by every view. No literal colours,
radii or font sizes in feature views.

| Token | Value |
|---|---|
| deck (top, at the notch) | `#000000` |
| body (from 55 points below the notch) | `#10131B` |
| card | `#1A1F2B` |
| card raised | `#232936` |
| control | `#2E3545` |
| hairline | `rgba(190, 205, 235, .11)` |
| text | `#F3F5FA` |
| secondary | `#B7BFD0` |
| tertiary | `#8791A6` |
| inactive navigation | `#A4AEC2` |
| signal | `#FFB340` |
| go | `#32D74B` |
| stop | `#FF6961` |

Each space has an accent: Now `#6CB2FF`, Shelf `#3FD6C5`, Clipboard `#B49CFF`, Tools `#FF9F5A`, Agents
`#FFB340`, Mac `#5EDB8A`. The deck passes the open space's accent down through the environment
(`deckAccent`), and components take it from there: the active navigation pill (accent at 18%, accent
text), chips and pills when picked, primary buttons (accent at 22%, accent text), selected rows, bars,
sliders, ticks and the scrubber's played part. Signal stays for "needs you" and is never used as an accent
by a component. Text meets 4.5:1 on every surface it sits on; a test checks it.

Radii: deck 30, card 16, control 9, pill full. Card padding 14, gap 10, deck side padding 14.
Type: Rounded 44 and 28 for timers and metrics, Rounded 34 for Now's clock, Rounded 32/26/20 for the weather's temperature, Bold 15/13 for the lyric line, Semibold 12 for figures, Bold 20 titles, Semibold 15 items, Regular 13 body,
Regular 12 detail, Mono 12 commands. Use system fonts and tabular digits.

Signal means "needs you": waiting agents, a meeting about to start, the active warning. Nothing
decorative uses it. Go and stop are for state, not decoration.

## The deck

- Default open size 700×430. Keep drag-to-resize, with a minimum of 620×340.
- Opening the closed notch (hover, click, the shortcut) always shows Now, not the space used last, and not the
  space of an ongoing activity such as Keep Awake. A live activity hovered or clicked as it appears opens its own
  feature's space (Now for a system one); files dragged near open the Shelf. With Now hidden, the first space.
- The panel is pure black at the top, flush with the hardware notch, with concave top shoulders and
  bottom radius 30. Below the notch it fades over 55 points to the body colour, which holds to the
  bottom. There is no border or glass theme. Remove the Glass theme.
- Top row, height equal to the notch: navigation in two wings beside the camera.
- Second row, 42 high: the page's own content on the left, its actions on the right, then pin and Settings.
  The top navigation already names the space, so the row never repeats it, and it only holds content that
  belongs to the page. A page with nothing for it has no row: the body moves up, to 10 under the navigation,
  and pin and Settings stand at its top right instead, above the page's right-hand column, which leaves
  `deckCornerInset` (30) free at its top. Which pages: Now always has one; the Shelf when it holds files; the
  Clipboard while it shows its history; Agents while usage is on (its left side is empty until an agent waits,
  then "N waiting" and the total); Tools and Mac never. A screen that slides over a space's body (Mac's) brings
  the row back, with a back button before its name. The row appears and goes without animation.
- Body below. The deck never changes size when switching spaces.
- On displays without a notch, use the same layout with the same gap between wings.

## Spaces

`Now`, `Shelf`, `Clipboard` in the left wing; `Tools`, `Agents`, `Mac` in the right. They replace the
tab row, the app drawer and the tab editor. Users can reorder and hide spaces in Settings. Labels are
text, with no icon. Agents shows a signal badge with the waiting count. An older stored order or
hidden list that names Stash becomes Shelf and Clipboard in its place.

| Space | Page | Features |
|---|---|---|
| Now | three columns | Calendar, Notes, Weather, Media, Agents waiting, Timer, Keep Awake |
| Shelf | tiles and targets | shelf |
| Clipboard | list and preview | clipboard |
| Agents | sessions and usage | agents, usage |
| Mac | cards; Sound, Displays, Network, Storage and System (processes, services, Homebrew) slide over it | performance, sound, monitors, network, storage, admin |
| Tools | tiles, recent captures and tools | capture, timer, keep awake, shortcuts |

There are no sub-tabs. A space with nothing on is hidden, and Now is the default. Keep `FeatureID` and
`FeatureHost`: a space asks for the phase of each feature it shows, so every feature on screen is
`.foreground`, including all the ones Now shows. Mac runs Performance and Displays (for its brightness
slider) on its page, and the feature of a screen that is over it as well, so the page's history carries on;
the screen goes when the space does, or the notch closes.

### Now

Boards: `NowColor3`, `NowPlay3`, `NoteAdd3` (colour, player, note add), then `NowToday`, `NowPlaying`,
`NowAlert`, `NowAdd`, `NowFree`, `NowMin` for the states. Three columns on the black deck,
no cards, split by hairlines: left 176, middle 214, right the rest at 700 wide; 150 and 192 at 620. Column gap
14, side padding 18. The second row is 46 high: the clock (Rounded 34) at the left, the running timer and Keep
Awake as chips, then add, pin and settings. Between them one slot, in priority order: an agent request
(same answer rules as Agents), a meeting about to start (30 minutes), the add field. Rows below never move.

- Left: Today (next event not yet ended, with Join; the rest of today), then Notes, in the order Settings
  sets (most recently edited first to begin with), each with a small square in the note's colour and a pin
  mark for notes in a window. With nothing left today, Notes moves up; with nothing at all, "Nothing today".
- Middle: month grid (six weeks, system first weekday, dots in the accent, today filled in the accent with
  dark text), then the events from tomorrow for a week; a picked day is ringed and lists that day.
- Right: weather from Apple's WeatherKit. Top block: the place on a line of its own, the whole column wide
  (truncated only if it still does not fit, the full name on hover); under it the icon and temperature at the
  left, and at the right the condition over today's low and high ("↓9° ↑19°"); a hairline, and one row of four
  figures (feels like, humidity, rain chance, UV) spread edge to edge; then the next five hours and, with
  nothing playing, as many of the next five days as fit in the height left (at least two, else none). The icons are in
  colour (SF Symbols' multicolor, fill variant) and each day's range bar runs from blue through yellow to
  orange. The clock is in the accent and so is the scrubber's played part. A player with no artwork shows
  `music.note` on a control tile. While something
  plays, the same top block with a smaller temperature, then the player with a thin scrubber and the lyric
  lines. Apple's mark, linking to its legal page, closes the column in both states as a small, faint footnote at
  the bottom right, as WeatherKit requires.
  No air quality.
- At 620×340: no month title, two event rows, the hours and, with nothing playing, the two days that fit, one lyric block of two lines, artwork 36.

Add field: an icon, the text, and at the right either the parsed date and time (an Event) or one style button
(a Note). The icon is a note or a calendar and says what Return will save; a date or time makes it an Event
until picked, and a click on the icon (or Tab) switches it, when both are possible. Return saves; Esc closes the
style panel first, then the field. The style button is a 30 square holding the note's colour as a 16 swatch
(hollow for none), with a small badge for the Desktop or On Top window; it opens a panel under it (also ⌘.)
with none and five colours (yellow, orange, green, blue, purple; ⌘0 to ⌘5) and a None, Desktop, On Top
control. Colour and window are off to begin with. The panel is drawn in the deck, not a popover, and choosing
keeps the field editing.

Notes in the left column: a click opens the note in a floating window, the window a pinned note has, to read
and edit; closing the window keeps the note, and a note that is already in a window is brought forward.
A note window is a plain AppKit text editor (undo, find, copy and paste, input methods) whose text never moves when
the bar shows on hover. It takes the keyboard only when clicked or opened on purpose, never when the deck or the
Command Bar closes; Topdeck's own saves are not read back into the editor, only another app's changes are.
Right-click: each colour, Pin to Desktop, Keep on Top, Unpin, Keep First in List, Share, Reveal in Finder,
Delete (after a confirmation). There is no Notes tab. The folder and the sort order are in Settings, search
is in the Command Bar (Notes appear there by title and the start of their text), and the new-note shortcut
opens the notch on Now with the add field set to Note.

### Shelf

Board `Shelf3`. Second row, only while there are files: the item count (Bold 20) and the total size at the
left; Add Files…, Select and Clear at the right. An empty shelf has no row, and the targets start under pin
and Settings. Add Files… is the empty-state illustration's small version (`ShelfTrayArt`, 18 in a 26
button, in its own colours, lit with `Deck.control` on hover); it opens the file panel, in Downloads or where
the last pick was, for files and folders. Body: a grid of three large tiles (the board's 102 high at 700 wide,
the same ratio at 620), each a real Quick Look thumbnail, or the file's kind colour (`Deck.Kind`, defined once)
with its extension, then the name and "KIND, size". Four targets stand to the right, 172 wide: AirDrop, Upload to R2, Add to Note, Open
With. Upload to R2 is dimmed until R2 is set up.

Click ticks a tile (Command-click, or Select mode, ticks several), double-click opens it, Space opens Quick
Look, and a tile drags out as a file. A target acts on the ticked tiles, or on all when none is ticked; tiles
or files dropped on it are acted on instead. Add to Note starts a note with a text file's content or else the
file's path; Open With pops up the apps that can open the file. Items dropped together are not grouped: the
model keeps no groups. Thumbnails are made off the main thread and kept in memory. An empty shelf is a dashed
drop zone where the tiles go, with the targets beside it as always: the illustration (three kind-coloured
cards in an open tray, 132 by 96), "Drop files here" (Semibold 15), one tertiary line, "Keep files at hand
while you switch apps. Drag them onto the notch from anywhere.", and an outline button, Choose Files…. The
smallest deck has no room for the line. Over the zone the border and a faint fill take the accent, the cards
sink into the tray and the title reads "Let go to keep them here". With files, dragging over the tiles outlines
the area in the accent and floats "Add N files" low in it; the tiles' own drop takes the files, not the notch's.
A target is not clicked while the shelf is empty, but files dropped on it are still acted on.

### Clipboard

Board `Clipboard3`. Second row, while the history shows: the filters All, Text, Images, Links, Files at the left;
a menu, Keep open and Settings at the right. Turned off, or waiting for access, there is no row and the card
starts under pin and Settings. The menu holds what the board has no place for: Select Items, Clear History, paste as
plain text, link cleaning, and turning the history off. Ignored apps stay in Settings. Left column, 296 wide:
the search field and the list, each row 44 high with a kind icon (a real thumbnail for an image), the title and
"source, age". Right column: the chosen item large (an image scaled to fit, text and links scrollable, a file
with its icon and name), what it is ("1440 × 900, PNG") and where it came from, a favourite star and Paste.

Up and Down move the choice, Return pastes it, and typing goes to the search. A filter with nothing in it is
"No images" and so on; a search with nothing is "No matches".

Every screenshot Topdeck takes is kept in the history as an image from "Topdeck", without touching the system
pasteboard, within the same size limit and capacity, and only while the history is on. A screenshot that is
also copied stays one item (the pictures are matched by a fingerprint of their PNG). Recordings do not go in.

### Tools

Board `Tools3`, with the owner's changes, tidied. No second row: pin and Settings stand above the right list.
Body, left: two toolbars, each one card cut into equal cells
by hairlines (64 high, 56 at the smallest size): a 19pt line icon over a Semibold 12 name, no icon chips,
the icons in the Tools accent. Bar one: Area, Window, Screen, Scrolling, Text. Bar two: Record Window, Record
Screen, Edit Video and a narrow last cell with the recording options (see Recording); the two Record cells
draw their icon in the text colour with a small red dot at its top-right (there is no Record Area). Under
them the recent captures as a grid of 16:10 thumbnails with a hairline, four columns (three at the smallest
size) and as many rows as fit, each with its time; a recording or GIF has a dark pill at the bottom-left with
a play glyph and its length (or "GIF"), a picture has no badge. Click opens a picture in the editor,
drag takes the file out, right-click offers Copy, Reveal and Delete (to the Trash). Every screenshot,
including a scrolling or pinned one, is kept as a PNG in the Captures folder, which the list reads; the
thumbnail model also takes recordings. Right, 192 wide (176 at the smallest size): one card of Timer, Keep
Awake, Sleep Screen, Pick Colour and Shortcuts, the rows sharing its height, split by hairlines. A row is an
18pt line icon, the name and a capsule at its end: the timer's time left in the accent while it runs
("Start" when idle), Keep Awake's time left in the accent ("Off" when off), "Now", a swatch of the last
colour picked (the key before any), the count. Timer, Keep Awake, Pick Colour and Shortcuts open their
controls in a popover, Sleep Screen acts at once; the recent colours live in Pick Colour's. QR Code and Pin
stay on their shortcuts and in the Command Bar.

#### Recording

Record Window picks a window with the Window tool's highlight and pick overlay; Record Screen records the
only display, or asks which from a menu at the pointer when there are several. The last cell of the
second toolbar holds three small icon toggles, remembered: System audio and Microphone (both off to begin
with) and Show clicks (on; its tooltip says screen recordings only). While a recording is on, the toggles are
fixed and the two Record cells read Stop (in the stop colour) and a press ends it, or cancels its countdown.
Both are also commands (Record Window, Record Screen) with shortcuts in
Settings › Capture, like the other tools.

Three seconds count down in the closed notch, a red dot to the left of the camera and the number to the right;
Esc cancels it (a global Escape is held for the three seconds only). Then the dot and the clock: Topdeck's own
windows stay out of the picture, apart from the ring that marks a click, which is drawn in the Tools accent
(a window recording marks no clicks: a window's picture has nowhere to put them). With the pointer on the closed notch the clock is
replaced by Pause and Stop, and hovering does not open the deck (a click does, on Tools); paused, the dot is a ring and
the clock holds. It is an ordinary ongoing activity of the Capture feature and sits above music (and the
network's speed) like any newer one. Stop saves `Screen Recording <date> at <time>.mp4` (or `Window Recording …`) in
Captures, lists it with its MP4 badge and a thumbnail, and opens the editor. A recording that ends by itself (the
permission revoked, the disk nearly full or full, the window closed, a display unplugged) is closed, kept, and
announced once in the notch; the editor stays shut. The display is kept awake with its own power assertion,
released when the recording ends.

### Mac

Board `Mac3`, revised (the mockup `mac2`). No second row: pin and Settings stand above the right column.
Left, a thermal strip (a card, radius 14, 52 high) over six tiles in three columns by two rows, the rows
weighted 1.45 to 1 (charts above, bars below). The strip: "Thermal" (Semibold 12) over the system's state
(Bold 13: Normal in go, Fair in secondary, Throttling, for serious and critical, in signal), a hairline, then
CPU, GPU, SSD and Battery, each its name (11.5 tertiary), its degrees (Rounded 15 semibold) and a 4 point
gauge filled to the reading over 110° in the colour of its heat: blue under 70, yellow to 84, orange to 94,
stop from 95; from 85 the degrees take the colour too. Under CPU, "peak N°" (the hottest die), except at 620×340. A
reading the Mac does not give is left out, with no "–" (the GPU's comes from the SMC, so most Macs show all four); a Mac
with no sensors shows the state alone.
A tile: its name (Semibold 12 secondary) and a detail at the right (12 tertiary), the value (Rounded 26
semibold, its unit 14), a chart or a bar and one caption (11.5 tertiary), no icon chips. CPU: cores, the
last minute, Load. GPU: the chip, the last minute, "Idle" when it is. Wi-Fi or Ethernet: the last minute,
"↓ x  ↑ y". Memory: its size, a bar in app, wired and compressed, "N GB used". Storage: its size, free space,
a bar of what is used, read and write speed. Battery: Health, the charge, a bar, the time left ("3:42 left"),
or the time to full, or the state. A Mac without a battery shows its uptime in the last tile. At 620×340 the
captions and the battery's detail are left out (they stay in the tooltip and for VoiceOver). Right, 192
wide (176 at the smallest size): one card of the output volume (a click on its icon mutes) and the brightness
of the external monitors that answer over DDC, or that are dimmed in software when they don't (hidden when none
is; the built-in display needs a private API the plan does not name), 40 high each with the percent at the right; then one list of Sound, Displays, Network,
Storage and System, sharing the height, each with where it stands (the output device, the display count, the
connection, "Clean up", and for System a summary: "N failed" in stop when launch services failed, else "N updates" in the
accent when Homebrew packages have updates, else the busiest process as "Xcode  48%" in tertiary, empty when none is
known; only what the features already hold, so nothing is started for the row) and a chevron. A row slides that tab's existing screen over the
whole body, with the second row back, as "‹ Sound", and everything those screens did stays there. System is there when
Performance or System Admin is on. The history is
a ring buffer of a minute kept in memory while the page is on screen.

#### Displays screen

A card for each external monitor: its name, then a Brightness row and, where the monitor has speakers, a Volume row
(`DeckLevelRow`), both over DDC. A monitor that doesn't answer DDC (a dock's hub may not pass it on) is dimmed in
software instead: its card has the Brightness row alone, with the tooltip "Dims the picture; the monitor's own
brightness stays the same." and no visible helper text. The picture is dimmed by scaling the display's gamma table
(public Core Graphics calls) from the curve it had, so a calibration is kept. The level runs from 100%, the original
curve exactly, down to 15%, so the screen can't go black. The level is kept per monitor (vendor, product, serial) and
applied again at launch, after the displays change and after wake; every curve is put back on quit, and macOS puts
the ColorSync curve back on the next display change if Topdeck crashes. If DDC starts answering (a direct cable), DDC
wins and the curve goes back to 100%. A monitor with neither shows "Unavailable" and no controls. The Mac page's
brightness slider drives whichever applies.

#### System screen

A segmented Processes / Services / Homebrew at the top left, Processes first and selected on opening. Processes is one card
filling the screen (radius 14): a 30 high header of Process, CPU and Memory (11 Semibold tertiary; click to sort, the
sorted one in the text colour with a ↓), then 30 high rows with a hairline between, as many as fit: the app's icon (18,
a plain glyph for a process with none), the name (13), the CPU (12.5 secondary, right-aligned, 64 wide) over a faint bar
of its share in the accent, and the memory (80 wide). Services and Homebrew are the System Admin lists as before, with
Refresh and the Homebrew buttons at the right of the same row. Without System Admin (it starts off) the screen is the
table alone and has no segmented control; without Performance it is Services and Homebrew as before.

### Agents

Board `Agents3`, laid out in three columns like Now: side padding 18, a 14 gap, hairlines between, no cards but
the request's. Below 660 wide the left column is 150 and the middle 192, else 176 and 214; the right takes the
rest. Second row: the waiting count at the left ("1 waiting"), nothing when none waits, and the period's total
beside it (`$4,178.24  17.5B`, the tokens dropping out first when the row is short);
Today, 7 Days, 30 Days and All at the right (the choice is kept), then Refresh, an add-a-provider menu, pin and
Settings.

Left, with a request or a session: the requests waiting for an answer first (same answers, safety and Always Allow
as before, the command in a dark block), then sessions waiting on their terminal, then sessions at
work, each under a hairline: the tool's colour, the project, how long since it last moved (`now`, `2m`, `1h`,
`3d`), and under it what it is doing, or "Waiting for you" in the signal colour; a click goes to its terminal. A
finished or quiet session is not listed. With none, the left column is the period at a glance: the total in whole
dollars with its tokens (the tokens alone when nothing is priced), a bar of each tool's share, the last 30 days'
cost as bars with today in the accent (whatever the period), and Today against Per day, the period's total
over its days (for All, from the first day with usage).

Middle and right are one table, a row for each tool, level across both and split by hairlines: the tools with
usage by cost, then the ones that have only a quota. A row is as tall as its quota needs (9 + 17 for each line,
two at least). Middle: the tool's colour, name and cost (`$241.60`), and under them its tokens (`850k`, `18.2M`,
`1.2B`, `T`). Right: a row each for 5h, W and M: a bar in the tool's colour for what is left with a tick where even
use would have it by now, the percent left (in the stop colour at 0), and the time to the reset. A tool that cannot
be read shows "Checking…", "Sign in" or "Unavailable" in its place, with the reason in its tooltip, never zeros. More
rows than fit scroll as one. With usage off the sessions take the full width. Tool colours are tokens: Claude
`#F2A773`, Codex `#8FD6A4`, Antigravity `#8FB8FF`, Cline `#E7A6F0`, Grok `#C9D0DE`, any other neutral.

## Video editor

Board `Editor3`. A normal window (960×506 to begin with, 820×480 at the least, resizable) in the deck's dark colours
(`body` behind, `card` for the picture's box, `control` for the pills), opened by Edit Video (a file picker that starts in
Captures), by a click on a recording in Tools, and by Stop. One window per video; a video already open comes forward.
Selection is the Tools accent, not the board's purple: pills, the selected segment, the slider fill, the crop frame.
The trim frame and its handles are `Tint.yellow`, as on the board.

- Title bar, 48 high: the file's name at the left (after the traffic lights), then the GIF and MP4 pills and Export.
  Export opens a popover with the size (Original, 1080p, 720p, 480p) and quality (High, Medium, Low) chips, Save As… and
  Export. Export writes `<name> edited.mp4` (or `.gif`, then ` 2`, ` 3`…) next to the source, never over it; Save As… starts
  in that folder. A banner over the picture's top shows the progress with Cancel, then the file's name with Reveal.
  A GIF starts at 720p and is never larger than that unless a bigger size is picked; MP4 starts at the source's size.
- Picture, left: the edit drawn by the same renderer the export uses (crop, zoom, rounded corners, background), fitted in
  a `card` box; click or Space plays and pauses, and playback stops at the trim's end and runs a speed segment at its
  rate. With the Crop tool out it shows the whole picture with the crop rectangle on it to drag by its corners and body.
- Settings, right, 204 wide: Zoom then Background, as on the board, then Crop, Speed and Audio (Audio only when the file
  has sound); the tool that is out comes to the top with its name in the accent, so nothing scrolls to find it.
  Zoom: add at the playhead (+), delete, Scale (1× to 4×), Follow cursor (only when the recording kept the pointer),
  otherwise a small picture to click or drag the target on. Background: no background, the board's three gradients and
  one solid, Padding and Corners (in units of a 1000-wide frame, so the preview and the export agree at any size; they
  are dimmed with no background). Crop: 16:9, 4:3, 1:1, 9:16, and reset. Speed: add at the playhead, delete,
  0.25× to 8× chips. Audio: each track by name (System audio, Microphone), its level and a mute button.
- Timeline: the tool pills and the position ("0:42 / 1:36") above a 50 high strip of 16 frames; the part the trim leaves
  out is dimmed, the kept part outlined with a handle at each end (at least half a second between them), the playhead a
  2 point line, dragged or clicked on the strip. Under it the zoom row (12 high), and a speed row once there is a speed
  segment or the Speed tool is out. A segment is a block to click, drag, or stretch at its ends; it stops at its
  neighbours and the trim, and none overlap.
- Space plays and pauses, Delete removes the picked segment, Command-Z and Shift-Command-Z undo and redo (a drag or a
  slider is one step), the arrows step a frame (a second with Shift).
- Non-destructive: the edit is `<name>.topdeck-edit.json` beside the video, written a moment after each change and when
  the window closes or Topdeck quits, and removed when there is nothing in it. It is ignored when the video's length no
  longer matches. The recorded pointer is `<name>.topdeck-cursor.json`, which also names the audio tracks.

## Closed notch states for recording

Counting down: `●  |  3`. Recording: `●  |  1:42`, and with the pointer on it `●  |  ⏸ ⏹` in the same width, so
the notch holds still. Paused: a ring in place of the dot, the clock held. Reduce Motion: nothing here moves.

## Settings

Pages: General, Notch, one page for each space, Shortcuts & Windows, About. Shortcuts & Windows holds
Windows, Window Switcher, Command Bar and Input Sources, each starting with its switch and the way to start
it (key caps, or a phrase such as "Drag a window to a screen edge"), since none of them can be seen otherwise.

## Closed notch

Follow the `Closed` board. Left of the camera: what it is. Right: its state. Width grows only as far
as needed. Keep existing activity priorities.

While music plays the state is four thin rounded bars, 3 wide with 2 between, up to 14 tall, in the track's
accent colour (the Now accent without one). They move to a made-up pattern, each bar's height the sum of two
sines of different speeds (`MusicBars`), not the audio, and nothing is captured. They redraw about 20 times
a second only while the music plays, the notch is on screen and Reduce Motion is off; paused they stand low
and still, and with Reduce Motion on they stand still in the middle. A still bar set has no timeline.

## Copy

English only. Empty states are one short line or nothing, never instructions. Follow the global rule
against secondary labels; the boards show the intended amount of text.

## Accessibility

Keep every accessibility label. Respect Reduce Motion. Text meets 4.5:1 on its background.

## Icon

`docs/design/icon-paper.svg`: a cream plate, the notch in ink above two lines and an orange dot.
`scripts/render-icon.swift` rebuilds `App/Assets.xcassets/AppIcon.appiconset` from it at every size and the
menu bar's template glyph, which has the same notch and lines. The 16 pt variant leaves out the second line
and the dot, which turn to mud there.

## Out of scope

No new features. Do not change feature behaviour, storage formats or preferences keys beyond
what this spec needs. Old stored tab order and drawer settings may be ignored.
