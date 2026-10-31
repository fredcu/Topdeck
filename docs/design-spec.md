# Topdeck design spec

Approved design: the artboards in `docs/design/`, one `.dc.html` file each, styled by
`docs/design/deck.css`. They are the source of truth for layout, sizes, colours and copy; open them
in a browser if it helps. This file states what the boards can't. Round 3 (`NowColor3`, `NowPlay3`,
`NoteAdd3`) sets the colours and Now; `Shelf3` and `Clipboard3` set those two spaces; `Agents3`, `Tools3`,
`Mac3` and `Editor3` show where the others go and are built in later batches. Where an older board disagrees with a
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
- The panel is pure black at the top, flush with the hardware notch, with concave top shoulders and
  bottom radius 30. Below the notch it fades over 55 points to the body colour, which holds to the
  bottom. There is no border or glass theme. Remove the Glass theme.
- Top row, height equal to the notch: navigation in two wings beside the camera.
- Second row, 42 high: sub-tabs or a title on the left, the space's actions on the right.
- Body below. Sub-pages fade; the deck never changes size when switching spaces.
- On displays without a notch, use the same layout with the same gap between wings.

## Spaces

`Now`, `Shelf`, `Clipboard` in the left wing; `Tools`, `Agents`, `Mac` in the right. They replace the
tab row, the app drawer and the tab editor. Users can reorder and hide spaces in Settings. Labels are
text, with no icon. Agents shows a signal badge with the waiting count. An older stored order or
hidden list that names Stash becomes Shelf and Clipboard in its place.

| Space | Sub-tabs | Features |
|---|---|---|
| Now | none | Calendar, Notes, Weather, Media, Agents waiting, Timer, Keep Awake |
| Shelf | none | shelf |
| Clipboard | none | clipboard |
| Agents | Sessions, Usage | agents, usage |
| Mac | Performance, Sound, Displays, Network, Storage, System | performance, sound, monitors, network, storage, admin |
| Tools | none | capture, timer, keep awake, shortcuts |

A sub-tab for a feature that is off is hidden, and a space with nothing on is hidden. Now is the
default. Each space remembers its last sub-tab. Keep `FeatureID` and `FeatureHost`: a space asks for
the phase of each feature it shows, so every feature on screen is `.foreground`, including all the
ones Now shows.

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
- Right: weather from Apple's WeatherKit. Top block: the place with the icon and temperature, then the
  condition with today's low and high ("↓9° ↑19°"), a hairline, and one row of four figures (feels like,
  humidity, rain chance, UV) spread edge to edge; then the next five hours and five days. The icons are in
  colour (SF Symbols' multicolor, fill variant) and each day's range bar runs from blue through yellow to
  orange. The clock is in the accent and so is the scrubber's played part. A player with no artwork shows
  `music.note` on a control tile. While something
  plays, the same top block with a smaller temperature, then the player with a thin scrubber and the lyric
  lines. Apple's mark, linking to its legal page, closes the column in both states, as WeatherKit requires.
  No air quality.
- At 620×340: no month title, two event rows, hours but no days, one lyric block of two lines, artwork 36.

Add field: Return saves; an Event/Note control chooses itself from the text (a date or time is an Event) until
picked; Tab switches; Esc closes only the field. With Note chosen the field also shows five colour dots
(yellow, orange, green, blue, purple) and two toggles, Desktop and On Top, which exclude each other. All
are off to begin with, and Return saves the note with that colour and window.

Notes in the left column: a click opens the note in a floating window, the window a pinned note has, to read
and edit; closing the window keeps the note, and a note that is already in a window is brought forward.
Right-click: each colour, Pin to Desktop, Keep on Top, Unpin, Keep First in List, Share, Reveal in Finder,
Delete (after a confirmation). There is no Notes tab. The folder and the sort order are in Settings, search
is in the Command Bar (Notes appear there by title and the start of their text), and the new-note shortcut
opens the notch on Now with the add field set to Note.

### Shelf

Board `Shelf3`. Second row: the item count (Bold 20) and the total size at the left; Select and Clear at the
right. Body: a grid of three large tiles (the board's 102 high at 700 wide, the same ratio at 620), each a
real Quick Look thumbnail, or the file's kind colour (`Deck.Kind`, defined once) with its extension, then the
name and "KIND, size". Four targets stand to the right, 172 wide: AirDrop, Upload to R2, Add to Note, Open
With. Upload to R2 is dimmed until R2 is set up.

Click ticks a tile (Command-click, or Select mode, ticks several), double-click opens it, Space opens Quick
Look, and a tile drags out as a file. A target acts on the ticked tiles, or on all when none is ticked; tiles
or files dropped on it are acted on instead. Add to Note starts a note with a text file's content or else the
file's path; Open With pops up the apps that can open the file. Items dropped together are not grouped: the
model keeps no groups. Thumbnails are made off the main thread and kept in memory. An empty shelf is one line,
"Drop files here", and the drop highlight.

### Clipboard

Board `Clipboard3`. Second row: the filters All, Text, Images, Links, Files at the left; a menu, Keep open and
Settings at the right. The menu holds what the board has no place for: Select Items, Clear History, paste as
plain text, link cleaning, and turning the history off. Ignored apps stay in Settings. Left column, 296 wide:
the search field and the list, each row 44 high with a kind icon (a real thumbnail for an image), the title and
"source, age". Right column: the chosen item large (an image scaled to fit, text and links scrollable, a file
with its icon and name), what it is ("1440 × 900, PNG") and where it came from, a favourite star and Paste.

Up and Down move the choice, Return pastes it, and typing goes to the search. A filter with nothing in it is
"No images" and so on; a search with nothing is "No matches".

Every screenshot Topdeck takes is kept in the history as an image from "Topdeck", without touching the system
pasteboard, within the same size limit and capacity, and only while the history is on. A screenshot that is
also copied stays one item (the pictures are matched by a fingerprint of their PNG). Recordings do not go in.

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
