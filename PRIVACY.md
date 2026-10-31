# Privacy

Topdeck is local-first.

- No accounts, analytics, telemetry, or device fingerprinting.
- The network is used only for the AI Usage providers you turn on, for
  uploads to your own Cloudflare R2 bucket (both below), for Weather (below),
  for Synced lyrics when you turn it on, and when you run a Homebrew action in
  System Admin. With no provider on, no upload started, Weather off, Synced
  lyrics off, and no Homebrew action run, none of them touches the network.
- Weather (Settings › Now) is on by default and uses Apple's WeatherKit. While
  Now is open it asks macOS for your approximate location, once each time it
  refreshes, and sends it, rounded to two decimals (about a kilometre), to
  Apple, not to a third party. Apple's geocoder resolves your location to a
  place name. The last result is kept in
  `~/Library/Caches/Topdeck`. Turning Weather off stops all of it; denying
  Location Services shows "Weather unavailable" and sends nothing.
- Synced lyrics (Settings › Now) is off until you turn it on. Then, while the
  notch shows what's playing, the title, artist, and length of the
  track go to lrclib.net, a free third-party service, to find its lyrics, and
  nothing else is sent. Found lyrics are cached on this Mac in
  `~/Library/Caches/net.icuai.topdeck/lyrics`, so a track is asked for once;
  turn the setting off and nothing is sent or read from that folder. When a
  track isn't found under its name, its title and artist also go to Apple's
  public iTunes Search API (itunes.apple.com) to find its name in another
  language.
- Everything Topdeck creates (settings, notes, shelf items) stays on your Mac,
  unless you choose a notes folder that syncs, such as one in iCloud Drive.
- System permissions (Calendar, Location, Camera, and so on) are requested only
  when you enable the feature that needs them. Denying one disables only that
  feature.
- Replacing the macOS volume display is off until you turn it on. It asks for
  Accessibility access to catch the volume keys; Topdeck takes only the three
  volume keys and passes every other event through untouched.
- The Network tab sends nothing. It reads how many bytes your Mac's network
  interfaces have moved, never what the bytes were, where they went, or which
  app moved them, and keeps the totals by the hour in
  `~/Library/Application Support/Topdeck/network.sqlite` on this Mac only.
  The first time it runs, it reads NetSpeed's history from
  `~/Library/Application Support/NetSpeed` if it's there. **Clear History** in
  Settings › Network deletes it, and turning the tab off stops counting.
- The Storage tab (off until you turn it on) scans only when you ask, and then
  reads file and folder metadata (names, sizes, kinds), never contents. It
  doesn't follow symbolic links, enter other volumes, or download iCloud files,
  and sends nothing. Items you pick go to the Trash after you review the list;
  nothing is deleted outright.
- The Monitors tab talks to the monitors attached to your Mac over DDC, the
  control channel in the display cable, to read and set their brightness and
  volume. It sends nothing over the network.
- The System Admin tab (off until you turn it on) reads and manages your launch
  agents on this Mac with `launchctl`, and sends nothing. Its Homebrew actions
  run `brew`, which contacts Homebrew's servers only when you run an action,
  such as an upgrade.
- Messages sent with the Show in Notch action or an `topdeck://` link are
  only displayed: they're never stored, and nothing in them is opened.
- Clipboard history is off until you turn it on in the Clipboard tab. Then it
  keeps what you copy (text, links, images, and file locations) in
  `~/Library/Application Support/Topdeck` on this Mac only, up to 200 items
  plus your favorites. It skips anything the copying app marks secret or
  temporary, anything copied in a password manager, and copies from apps you
  list in Settings › Clipboard. **Clear History**
  removes everything but favorites, and turning it off stops reading the
  clipboard.
- Capture tools (screenshots, scrolling captures, text, QR codes, pinned images)
  need Screen Recording permission, which macOS asks for the first time you use
  one. Captures are read on this Mac, text and QR codes with Apple's Vision
  framework, and stay on it: they go to the clipboard or onto the screen. Only
  **Add to Shelf** writes a file, in
  `~/Library/Application Support/Topdeck/Captures`.
- The bars beside the camera while music plays move to a made-up pattern, not
  to the sound, and listen to nothing. Only the Media view's waveform listens
  to your Mac's audio output (macOS asks for "system audio recording"
  permission the first time), only while that view is open and something
  plays; it turns the sound into loudness per frequency band as it plays, and
  never records, stores, or sends audio. Turn it off in Settings › Now.
- Shuffle, repeat, Music's up next and lyrics, Spotify's recently played, and,
  in the App Store edition, all of Media's controls talk to Music or Spotify
  through their own AppleScript, on this Mac. macOS asks first (Privacy &
  Security › Automation), the first time you press one of those buttons, and
  Topdeck only ever talks to the app that's playing. Spotify's recently
  played list is kept in memory and gone when Topdeck quits.
- An app you turn down in the Sound tab (GitHub build) plays through
  Topdeck at its new volume while it plays, on the same permission; one you
  mute is silenced at its source. Its sound goes straight back out to your
  speakers or headphones and is never recorded, stored, or sent. Apps you leave
  at 100% aren't touched. **Reset All** in Settings › Sound hands
  every app back its own volume. Switching devices and setting the output's or
  microphone's volume there hear nothing at all.

## AI Usage

The AI Usage tab shows how much of your AI coding plans you've used. Its
providers come from [OpenUsage](https://github.com/robinebers/openusage). Every
provider is off until you turn it on, and nothing reaches the network before
that.

To find which tools are signed in on this Mac, when you open the tab or its
settings, and to read a provider's sign-in when it refreshes, Topdeck:

- Reads the sign-in each tool keeps on this Mac: its files (like
  `~/.codex/auth.json` or Cursor's settings database) and its keychain items,
  through `/usr/bin/security`. The sign-ins stay in memory. macOS may ask you
  to allow a keychain read.
- May run your login shell once (`$SHELL -ilc env`) to see settings and API
  keys you export there, such as `CLAUDE_CONFIG_DIR` or `OPENROUTER_API_KEY`.
  Only non-secret settings (config folders, sign-in endpoints) are remembered.
- Keeps an API key you paste in **Settings › AI Usage** (for OpenRouter or
  Z.ai) in your login keychain, as "Topdeck AI Usage", never in a file.
  **Remove** there deletes it.

For each provider you turn on, Topdeck:

- Sends your sign-in only to that provider's own service, to ask for your
  usage. Antigravity is asked through its language server on this Mac, found
  with `ps` and `lsof`.
- When a sign-in has expired, renews it with that provider and saves the new
  token back where its tool keeps it, the same way the tool would. For
  Antigravity, it asks you to open Antigravity instead.
- Reads the tool's local session logs (Claude Code, Codex, and others) to
  estimate what you've spent. Prices come from public price lists: LiteLLM
  (raw.githubusercontent.com), models.dev, and OpenUsage's price supplement
  (robinebers.github.io). Topdeck downloads them about once an hour while a
  provider refreshes. These requests carry nothing about you or your usage.

Refreshes happen when you open the tab, every five minutes while it stays open,
and in the background only if you choose an interval in Settings (off by
default). Results are cached in `~/Library/Application Support/Topdeck/` so
the tab paints at once. Turning a provider off deletes its cached results. The
Mac App Store edition doesn't include the AI Usage tab.

## Agent status

Agent status is off until you connect a tool in the Agents tab or in
**Settings › Agents**. Connecting adds hooks to that tool's own
settings file (`~/.claude/settings.json` for Claude Code, `~/.codex/hooks.json`
for Codex) and first keeps a copy of the file as it was in
`~/Library/Application Support/Topdeck/Backups`. The hooks run a small script,
`~/Library/Application Support/Topdeck/topdeck-agent-hook`, which writes one
file per session into `~/Library/Application Support/Topdeck/Agents`: the
session's state, its project folder, the app it runs in, its process ID, and
the tool's own words for what it's waiting for. Your prompts, code, and tool
output are never written, and nothing leaves your Mac. When a tool asks for
permission, the request, including the tool's input such as a command or file
contents, goes to Topdeck over a local socket, stays in memory only while the
request waits, and never leaves your Mac. Disconnecting removes the
hooks, and with no tool connected, the script and the session files too.

## Sharing with Android

Sharing with Android phones (Quick Share, in the shelf) uses your local network
only: phone and Mac talk directly over your Wi-Fi, never through the internet
or a server, and every connection is end-to-end encrypted.

- **Visible only when you choose.** Receiving is off until you turn it on: for
  10 minutes from the shelf, while the notch is open, or always. While it's on,
  your Mac announces itself to devices on the same network with the name you
  set in **Settings › Shelf** (your Mac's name unless you change it)
  and a random ID that changes each launch. Asleep or locked, it announces
  nothing.
- **Nothing without your consent.** A phone that connects shows its name, what
  it's sending, and a code matching its own, and nothing is saved until you
  accept. Files go to the folder you choose (Downloads unless you change it),
  marked as downloaded, as AirDrop marks files, so macOS checks any app or
  script among them before it runs. Text and links go to the clipboard; a link
  opens only when you click **Open**.
- **Looking for phones only while you send.** The send window looks for phones
  nearby while it's open and stops when it closes. Its QR code holds a key made
  for that window alone.

Topdeck keeps nothing about the phones it meets. macOS asks once for Local
Network access; turning it off in **System Settings › Privacy & Security ›
Local Network** turns this feature off and nothing else.

## Uploading to R2

Files in the shelf go to your own Cloudflare R2 bucket only when you choose
**Upload to R2** on a file. The upload goes over HTTPS to your account's R2
address and nowhere else, and never replaces a file already in the bucket unless
you choose **Replace in R2**. Your R2 keys stay in the keychain and aren't
written to files, settings, or logs. The bucket's address (account ID, bucket
name, folder, public URL) is kept in Topdeck's settings.

A change that weakens any of these points must say so in its pull request and
update this file.
