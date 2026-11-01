// SPDX-License-Identifier: MIT
import AppKit
import SwiftUI
import Testing
import TopdeckCore

@testable import TopdeckSurface

/// A color's sRGB components as 0...255 integers, plus alpha.
private func rgba(_ color: Color) -> [Int] {
    let converted = NSColor(color).usingColorSpace(.sRGB)!
    return [converted.redComponent, converted.greenComponent, converted.blueComponent, converted.alphaComponent]
        .map { Int(($0 * 255).rounded()) }
}

@MainActor
struct DeckTokenTests {
    /// docs/design-spec.md's table, value for value.
    @Test func theColorsAreTheSpecs() {
        #expect(rgba(Deck.deck) == [0x00, 0x00, 0x00, 255])
        #expect(rgba(Deck.body) == [0x10, 0x13, 0x1B, 255])
        #expect(rgba(Deck.card) == [0x1A, 0x1F, 0x2B, 255])
        #expect(rgba(Deck.cardRaised) == [0x23, 0x29, 0x36, 255])
        #expect(rgba(Deck.control) == [0x2E, 0x35, 0x45, 255])
        #expect(rgba(Deck.hairline) == [190, 205, 235, 28], "rgba(190, 205, 235, .11)")
        #expect(rgba(Deck.text) == [0xF3, 0xF5, 0xFA, 255])
        #expect(rgba(Deck.secondary) == [0xB7, 0xBF, 0xD0, 255])
        #expect(rgba(Deck.tertiary) == [0x87, 0x91, 0xA6, 255])
        #expect(rgba(Deck.navInactive) == [0xA4, 0xAE, 0xC2, 255])
        #expect(rgba(Deck.signal) == [0xFF, 0xB3, 0x40, 255])
        #expect(rgba(Deck.go) == [0x32, 0xD7, 0x4B, 255])
        #expect(rgba(Deck.stop) == [0xFF, 0x69, 0x61, 255])
    }

    @Test func eachSpaceHasItsAccent() {
        let accents: [(SpaceID, [Int])] = [
            (.now, [0x6C, 0xB2, 0xFF]), (.shelf, [0x3F, 0xD6, 0xC5]), (.clipboard, [0xB4, 0x9C, 0xFF]),
            (.tools, [0xFF, 0x9F, 0x5A]), (.agents, [0xFF, 0xB3, 0x40]), (.mac, [0x5E, 0xDB, 0x8A]),
        ]
        #expect(accents.map(\.0) == SpaceID.allCases)
        for (space, rgb) in accents { #expect(Array(rgba(space.accent).prefix(3)) == rgb, "\(space)") }
    }

    @Test func theProviderAndTintColoursAreTheBoards() {
        #expect(Array(rgba(Deck.Provider.claude).prefix(3)) == [0xF2, 0xA7, 0x73])
        #expect(Array(rgba(Deck.Provider.codex).prefix(3)) == [0x8F, 0xD6, 0xA4])
        #expect(Array(rgba(Deck.Provider.antigravity).prefix(3)) == [0x8F, 0xB8, 0xFF])
        #expect(Array(rgba(Deck.Provider.cline).prefix(3)) == [0xE7, 0xA6, 0xF0])
        #expect(Array(rgba(Deck.Provider.grok).prefix(3)) == [0xC9, 0xD0, 0xDE])
        #expect(rgba(Deck.Provider.color("somethingelse")) == rgba(Deck.Provider.neutral), "others are neutral")
        #expect(Array(rgba(Deck.Tint.magenta).prefix(3)) == [0xF0, 0x7B, 0xD0])
        #expect(Array(rgba(Deck.Tint.yellow).prefix(3)) == [0xFF, 0xD1, 0x66])
    }

    @Test func theShapeAndSpacingAreTheSpecs() {
        #expect(Deck.Radius.deck == 30 && Deck.Radius.card == 16 && Deck.Radius.control == 9)
        #expect(Deck.Metric.cardPadding == 14 && Deck.Metric.gap == 10 && Deck.Metric.side == 14)
        #expect(Deck.Metric.subRow == 42)
    }

    @Test func theTypeScaleIsTheSpecs() {
        #expect(DeckTextStyle.allCases.map(\.size) == [44, 28, 20, 15, 13, 12, 12, 12, 34, 32, 26, 20, 12, 15, 13])
    }

    /// Text must meet 4.5:1 on the surface it sits on. Black on signal is a badge; the rest is on a card.
    @Test func textMeetsContrastOnItsBackground() {
        func luminance(_ color: Color) -> Double {
            let parts = rgba(color).prefix(3).map { Double($0) / 255 }.map {
                $0 <= 0.03928 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * parts[0] + 0.7152 * parts[1] + 0.0722 * parts[2]
        }
        func ratio(_ foreground: Color, on background: Color) -> Double {
            let (a, b) = (luminance(foreground), luminance(background))
            return (max(a, b) + 0.05) / (min(a, b) + 0.05)
        }
        for text in [
            Deck.text, Deck.secondary, Deck.tertiary, Deck.signal, Deck.go, Deck.stop, Deck.Provider.claude,
            Deck.Provider.codex, Deck.Provider.antigravity, Deck.Provider.cline, Deck.Provider.grok,
            Deck.Provider.neutral,
        ] {
            for surface in [Deck.deck, Deck.body, Deck.card, Deck.cardRaised] {
                #expect(ratio(text, on: surface) >= 4.5, "\(rgba(text)) on \(rgba(surface))")
            }
        }
        #expect(ratio(Deck.text, on: Deck.control) >= 4.5 && ratio(Deck.secondary, on: Deck.control) >= 4.5)
        #expect(ratio(Deck.onFill, on: Deck.signal) >= 4.5 && ratio(Deck.onFill, on: Deck.text) >= 4.5)
        #expect(ratio(Deck.onFill, on: Deck.go) >= 4.5)
    }
}

@MainActor
struct DeckIconTests {
    @Test(arguments: DeckIcon.allCases)
    func everyIconDraws(icon: DeckIcon) throws {
        let image = try #require(icon.image, "\(icon) has an SVG macOS can draw")
        #expect(image.isTemplate && image.size.width > 0)
    }

    @Test func iconsForActivitiesAreTheDecksWhereItHasThem() {
        #expect(DeckIcon.matching(symbol: "hand.raised.fill") == .hand)
        #expect(DeckIcon.matching(symbol: "speaker.wave.3.fill") == .volume)
        #expect(DeckIcon.matching(symbol: "music.note") == nil)
    }
}

struct ClosedContentTests {
    private func content(
        _ feature: FeatureID?, _ symbol: String, _ title: String, level: Double? = nil, countdown: Date? = nil,
        artwork: Data? = nil
    ) -> ClosedContent {
        ClosedContent(
            Activity(
                feature: feature, symbol: symbol, title: title, level: level, duration: .zero, countdown: countdown,
                artwork: artwork))
    }

    @Test func aLevelIsAnIconAndAMeter() {
        let volume = content(nil, "speaker.wave.2.fill", "64%", level: 0.64)
        #expect(volume.leading == .icon(.volume) && volume.label == nil && volume.trailing == .meter(0.64))
        #expect(volume.spoken == "64%", "VoiceOver still reads the value")
    }

    @Test func aMeetingCountsDownInSignal() {
        let end = Date.now + 240
        let meeting = content(.calendar, "video.fill", "Standup starts in", countdown: end)
        #expect(meeting.leading == .icon(.calendar) && meeting.trailing == .countdown(end))
        #expect(meeting.trailingTone == .signal)
        let focus = content(.timer, "cup.and.saucer.fill", "Awake", countdown: end)
        #expect(focus.trailingTone == .normal, "only a meeting needs you")
    }

    @Test func whatIsPlayingIsItsCoverAndFourBars() {
        let cover = Data([1])
        #expect(
            content(.media, "music.note", "Song", artwork: cover).trailing == .equalizer(playing: true, accent: nil))
        #expect(
            content(.media, "pause.fill", "Song", artwork: cover).trailing == .equalizer(playing: false, accent: nil),
            "paused, the bars stay, low and still")
        let tint = ActivityTint(red: 0.9, green: 0.4, blue: 0.2)
        let tinted = ClosedContent(
            Activity(
                feature: .media, symbol: "music.note", title: "Song", duration: .zero, artwork: cover, accent: tint))
        #expect(tinted.trailing == .equalizer(playing: true, accent: tint), "the track's colour reaches the bars")
        #expect(tinted.trailingWidth == CGFloat(MusicBars.width))
        #expect(content(.media, "music.note", "Song", artwork: cover).label == nil, "the cover says what it is")
    }

    @Test func waitingAgentsAreSignalWithACountWhenThereAreSeveral() {
        let one = content(.agents, "hand.raised.fill", "Topdeck")
        #expect(one.tone == .signal && one.label == "Topdeck" && one.trailing == nil)
        let several = content(.agents, "hand.raised.fill", "3 waiting")
        #expect(several.label == "Agents" && several.trailing == .badge(3) && several.tone == .signal)
    }

    @Test func aFinishedAgentIsGoWithDoneOnTheRight() {
        let done = content(.agents, "checkmark.circle.fill", "Build")
        #expect(done.leading == .icon(.check) && done.tone == .go && done.label == "Build")
        #expect(done.trailing == .text("Done"))
        let other = content(.network, "checkmark.circle.fill", "Downloaded 1 GB")
        #expect(other.tone == .go && other.trailing == nil, "only an agent says Done")
    }

    @Test func anythingElseIsItsIconAndTitle() {
        let copied = content(.clipboard, "doc.on.clipboard.fill", "Copied")
        #expect(
            copied.leading == .symbol("doc.on.clipboard.fill") && copied.label == "Copied" && copied.trailing == nil)
    }

    @Test func aRecordingIsARedDotAndItsCountOrClock() {
        func recording(_ phase: RecordingPhase) -> ClosedContent {
            ClosedContent(
                Activity(
                    feature: .capture, symbol: "record.circle", title: "Recording", duration: .zero, recording: phase))
        }
        let since = Date.now - 42
        let running = recording(.running(since: since))
        #expect(
            running.leading == .recordDot && running.label == nil
                && running.trailing == .recording(.running(since: since)))
        #expect(running.spoken == "Recording")
        #expect(recording(.countdown(3)).trailing == .recording(.countdown(3)))
        #expect(recording(.paused(elapsed: 61)).trailing == .recording(.paused(elapsed: 61)))
        // The clock and the buttons that replace it under the pointer share one width, so the notch holds still.
        for phase in [RecordingPhase.countdown(1), .running(since: since), .paused(elapsed: 5)] {
            #expect(recording(phase).trailingWidth == ClosedContent.recordingWidth)
        }
        #expect(ClosedContent.recordingWidth >= 2 * ClosedContent.recordingButton + 6)
    }

    @Test func aHeldRecordingsLengthReadsLikeAClock() {
        #expect(ClosedContent.clockText(0) == "0:00" && ClosedContent.clockText(61) == "1:01")
        #expect(ClosedContent.clockText(3725) == "1:02:05" && ClosedContent.clockText(-4) == "0:00")
    }

    @Test func widthsAreMeasuredFromWhatIsDrawn() {
        let short = content(.clipboard, "doc.on.clipboard.fill", "Copied")
        let long = content(.clipboard, "doc.on.clipboard.fill", "Copied a longer thing")
        #expect(short.leadingWidth > 16 && short.leadingWidth < long.leadingWidth)
        #expect(content(nil, "speaker.wave.2.fill", "5%", level: 0.05).trailingWidth == ClosedContent.meterWidth)
        #expect(content(.clipboard, "doc.on.clipboard.fill", "Copied").trailingWidth == 0)
    }
}

/// The shared components on the deck's black, as the Design language board lays them out. With
/// SNAPSHOT_DIR set, the picture is written there to compare with the board.
@MainActor
struct DeckComponentSnapshotTests {
    @Test func theComponentsDraw() throws {
        let view = VStack(alignment: .leading, spacing: Deck.Metric.gap) {
            HStack {
                DeckNavItem("Now", accent: SpaceID.now.accent, selected: true) {}
                DeckNavItem("Shelf", accent: SpaceID.shelf.accent, selected: false) {}
                DeckNavItem("Agents", accent: SpaceID.agents.accent, selected: false, badge: 2) {}
            }
            HStack {
                Button("Allow") {}.buttonStyle(.deck(.primary))
                Button("Deny") {}.buttonStyle(.deck())
                Button("Join") {}.buttonStyle(.deck(.accent))
                Button("Terminal") {}.buttonStyle(.deck(.outline))
                Button("Join") {}.buttonStyle(.deck(.accent, compact: true))
                DeckIconButton(.pin, label: "Keep open", on: true) {}
                DeckIconButton(.gear, label: "Settings") {}
            }
            HStack {
                DeckKeyCap("⌥")
                DeckKeyCap("Space")
                DeckBadge(2)
                DeckDot(.go)
                DeckDot(.signal)
                DeckSegmented(["Notch", "Desktop", "On Top"], selection: "On Top", title: { $0 }, select: { _ in })
            }
            VStack(spacing: Deck.Metric.gap) {
                DeckWeightedRow([1.25, 1]) {
                    DeckCard {
                        VStack(alignment: .leading) {
                            Text("Midnight City").deckText(.item)
                            Text("M83").deckText(.detail)
                            DeckBar(0.38)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                    DeckCard(.signal) {
                        VStack(alignment: .leading) {
                            Text("git push origin main").deckText(.command)
                            Text("24:58").deckText(.metric)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                }
                DeckWeightedRow([1]) {
                    DeckCard(.raised) {
                        VStack(spacing: 0) {
                            DeckRow(selected: true) {
                                DeckDot()
                                Text("Topdeck launch").deckText(.body)
                                Spacer()
                            }
                            DeckSeparator()
                            DeckRow {
                                Text("Groceries").deckText(.body)
                                Spacer()
                            }
                        }
                    }
                }
            }
            .frame(width: 560, height: 220)
        }
        .padding(20)
        .background(Deck.deck)
        .environment(\.colorScheme, .dark)
        let size = CGSize(width: 620, height: 420)
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height, alignment: .topLeading))
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        if let directory = ProcessInfo.processInfo.environment["SNAPSHOT_DIR"] {
            try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try? bitmap.representation(using: .png, properties: [:])?.write(
                to: URL(filePath: directory).appending(path: "components.png"))
        }
        #expect(bitmap.pixelsWide > 0)
    }
}

/// The colours on the deck's surfaces: the contrast text needs, and the gradient from the notch.
struct DeckColorTests {
    /// Relative luminance of an sRGB colour, as WCAG defines it.
    private static func luminance(_ color: Color) -> Double {
        let rgb = NSColor(color).usingColorSpace(.sRGB)!
        func linear(_ value: CGFloat) -> Double {
            let v = Double(value)
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent) + 0.0722
            * linear(rgb.blueComponent)
    }

    private static func contrast(_ a: Color, _ b: Color) -> Double {
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    /// `color` at `opacity` over `base`.
    private static func over(_ color: Color, _ opacity: Double, _ base: Color) -> Color {
        let c = NSColor(color).usingColorSpace(.sRGB)!
        let b = NSColor(base).usingColorSpace(.sRGB)!
        func mix(_ x: CGFloat, _ y: CGFloat) -> Double { Double(x) * opacity + Double(y) * (1 - opacity) }
        return Color(
            .sRGB, red: mix(c.redComponent, b.redComponent), green: mix(c.greenComponent, b.greenComponent),
            blue: mix(c.blueComponent, b.blueComponent))
    }

    @Test func textReadsAtFourPointFiveOnEverySurfaceItSitsOn() {
        for surface in [Deck.deck, Deck.body, Deck.card, Deck.cardRaised] {
            for text in [Deck.text, Deck.secondary, Deck.tertiary, Deck.navInactive] {
                #expect(Self.contrast(text, surface) >= 4.5, "\(text) on \(surface)")
            }
        }
        for text in [Deck.text, Deck.secondary] {
            #expect(Self.contrast(text, Deck.control) >= 4.5, "controls hold text and secondary only")
        }
    }

    @Test func eachAccentReadsOnItsTintedPillAndOnTheBody() {
        for space in SpaceID.allCases {
            let pill = Self.over(space.accent, 0.18, Deck.body)
            #expect(Self.contrast(space.accent, pill) >= 4.5, "\(space) on its nav pill")
            #expect(Self.contrast(space.accent, Deck.body) >= 4.5, "\(space) on the body")
            let tint = Self.over(space.accent, 0.22, Deck.card)
            #expect(Self.contrast(space.accent, tint) >= 4.5, "\(space) on a primary button")
        }
        #expect(Self.contrast(Deck.onAccent, Deck.Accent.now) >= 4.5, "today's number")
        #expect(Self.contrast(Deck.onFill, Deck.signal) >= 4.5)
    }

    @Test func everySpaceHasItsOwnAccent() {
        #expect(Set(SpaceID.allCases.map { "\($0.accent)" }).count == SpaceID.allCases.count)
    }

    @Test func theDeckIsBlackAtTheNotchAndFadesToTheBodyFiftyFivePointsLower() throws {
        let stops = Deck.panelStops(height: 430, notch: 37)
        #expect(stops.count == 4)
        #expect(stops[0].location == 0 && stops[1].location == 37.0 / 430, "black down to the notch")
        #expect(abs(stops[2].location - 92.0 / 430) < 1e-9, "55 points to the body colour")
        #expect(stops[3].location == 1)
        #expect(Self.luminance(stops[1].color) == 0 && Self.contrast(stops[3].color, Deck.body) == 1)
    }

    @Test func aDeckShorterThanTheGradientStillEndsInTheBody() {
        let stops = Deck.panelStops(height: 60, notch: 37)
        #expect(stops.map { $0.location } == stops.map { $0.location }.sorted() && stops[2].location == 1)
    }
}
