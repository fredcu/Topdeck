# Topdeck design spec

Approved design: 18 artboards in `docs/design/`, one `.dc.html` file each, styled by
`docs/design/deck.css`. They are the source of truth for layout, sizes, colours and copy; open them
in a browser if it helps. This file states what the boards can't. App icon: option A on the `Icon`
board.

## Tokens

Put these in one Swift file in `TopdeckSurface`, public, used by every view. No literal colours,
radii or font sizes in feature views.

| Token | Value |
|---|---|
| deck | `#000000` |
| card | `#151517` |
| card raised | `#1F1F22` |
| control | `#2A2A2E` |
| hairline | white 9% |
| text | `#F5F5F7` |
| secondary | `#BDBDC4` |
| tertiary | `#8E8E95` |
| signal | `#FFB340` |
| go | `#32D74B` |
| stop | `#FF6961` |

Radii: deck 30, card 16, control 9, pill full. Card padding 14, gap 10, deck side padding 14.
Type: Rounded 44 and 28 for timers and metrics, Rounded 34 for Now's clock, Rounded 32/26/20 for the weather's temperature, Bold 15/13 for the lyric line, Semibold 12 for figures, Bold 20 titles, Semibold 15 items, Regular 13 body,
Regular 12 detail, Mono 12 commands. Use system fonts and tabular digits.

Signal means "needs you": waiting agents, a meeting about to start, the active warning. Nothing
decorative uses it. Go and stop are for state, not decoration.

## The deck

- Default open size 700×430. Keep drag-to-resize, with a minimum of 620×340.
- The whole panel is pure black, flush with the hardware notch, with concave top shoulders and
  bottom radius 30. There is no separate grey body, border or glass theme. Remove the Glass theme.
- Top row, height equal to the notch: navigation in two wings beside the camera.
- Second row, 42 high: sub-tabs or a title on the left, the space's actions on the right.
- Body below. Sub-pages fade; the deck never changes size when switching spaces.
- On displays without a notch, use the same layout with the same gap between wings.

## Spaces

`Now`, `Stash`, `Tools` in the left wing; `Agents`, `Mac` in the right. They replace the
tab row, the app drawer and the tab editor. Users can reorder and hide spaces in Settings. Labels are
text, with no icon. Agents shows a signal badge with the waiting count.

| Space | Sub-tabs | Features |
|---|---|---|
| Now | none | Calendar, Notes, Weather, Media, Agents waiting, Timer, Keep Awake |
| Stash | Shelf, Clipboard, Notes | shelf, clipboard, notes |
| Agents | Sessions, Usage | agents, usage |
| Mac | Performance, Sound, Displays, Network, Storage, System | performance, sound, monitors, network, storage, admin |
| Tools | none | capture, timer, keep awake, shortcuts |

A sub-tab for a feature that is off is hidden, and a space with nothing on is hidden. Now is the
default. Each space remembers its last sub-tab. Keep `FeatureID` and `FeatureHost`: a space asks for
the phase of each feature it shows, so every feature on screen is `.foreground`, including all the
ones Now shows.

### Now

Boards: `NowToday`, `NowPlaying`, `NowAlert`, `NowAdd`, `NowFree`, `NowMin`. Three columns on the black deck,
no cards, split by hairlines: left 176, middle 214, right the rest at 700 wide; 150 and 192 at 620. Column gap
14, side padding 18. The second row is 46 high: the clock (Rounded 34) at the left, the running timer and Keep
Awake as chips, then add, pin and settings. Between them one slot, in priority order: an agent request
(same answer rules as Agents), a meeting about to start (30 minutes), the add field. Rows below never move.

- Left: Today (next event not yet ended, with Join; the rest of today), then Notes, most recent first, a pin
  mark for notes on the desktop. With nothing left today, Notes moves up; with nothing at all, "Nothing today".
- Middle: month grid (six weeks, system first weekday, dots, today filled white), then the events from
  tomorrow for a week; a picked day is ringed and lists that day.
- Right: weather (place, condition, temperature, six figures, five hours, five days); while something plays,
  the place and figures, then the player with a thin scrubber and the lyric lines. Open-Meteo is linked beside
  its data, as its licence requires.
- At 620×340: no month title, two event rows, hours but no days, one lyric block, artwork 36.

Add field: Return saves; an Event/Note control chooses itself from the text (a date or time is an Event) until
picked; Tab switches; ⌘Return pins a note to the desktop; Esc closes only the field.

## Closed notch

Follow the `Closed` board. Left of the camera: what it is. Right: its state. Width grows only as far
as needed. Keep existing activity priorities.

## Copy

English only. Empty states are one short line or nothing, never instructions. Follow the global rule
against secondary labels; the boards show the intended amount of text.

## Accessibility

Keep every accessibility label. Respect Reduce Motion. Text meets 4.5:1 on its background.

## Icon

Rebuild `App/Assets.xcassets/AppIcon.appiconset` from option A at every size. Use the 16 pt variant
without the back card, as the board shows. The menu bar item uses the template glyph.

## Out of scope

No new features. Do not change feature behaviour, storage formats or preferences keys beyond
what this spec needs. Old stored tab order and drawer settings may be ignored.
