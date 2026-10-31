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
        #expect(rgba(Deck.card) == [0x15, 0x15, 0x17, 255])
        #expect(rgba(Deck.cardRaised) == [0x1F, 0x1F, 0x22, 255])
        #expect(rgba(Deck.control) == [0x2A, 0x2A, 0x2E, 255])
        #expect(rgba(Deck.hairline) == [255, 255, 255, 23], "white at 9%")
        #expect(rgba(Deck.text) == [0xF5, 0xF5, 0xF7, 255])
        #expect(rgba(Deck.secondary) == [0xBD, 0xBD, 0xC4, 255])
        #expect(rgba(Deck.tertiary) == [0x8E, 0x8E, 0x95, 255])
        #expect(rgba(Deck.signal) == [0xFF, 0xB3, 0x40, 255])
        #expect(rgba(Deck.go) == [0x32, 0xD7, 0x4B, 255])
        #expect(rgba(Deck.stop) == [0xFF, 0x69, 0x61, 255])
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
        for text in [Deck.text, Deck.secondary, Deck.tertiary, Deck.signal, Deck.go, Deck.stop] {
            for surface in [Deck.deck, Deck.card, Deck.cardRaised] {
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
        #expect(content(.media, "music.note", "Song", artwork: cover).trailing == .equalizer)
        #expect(content(.media, "pause.fill", "Song", artwork: cover).trailing == .icon(.pause))
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

    @Test func widthsAreMeasuredFromWhatIsDrawn() {
        let short = content(.clipboard, "doc.on.clipboard.fill", "Copied")
        let long = content(.clipboard, "doc.on.clipboard.fill", "Copied a longer thing")
        #expect(short.leadingWidth > 16 && short.leadingWidth < long.leadingWidth)
        #expect(content(nil, "speaker.wave.2.fill", "5%", level: 0.05).trailingWidth == ClosedContent.meterWidth)
        #expect(content(.clipboard, "doc.on.clipboard.fill", "Copied").trailingWidth == 0)
    }
}

struct SpaceHeadlineTests {
    @Test func aSpaceWithoutSubTabsIsTitledByName() {
        #expect(SpaceID.tools.headline() == "Tools")
    }
}

/// The shared components on the deck's black, as the Design language board lays them out. With
/// SNAPSHOT_DIR set, the picture is written there to compare with the board.
@MainActor
struct DeckComponentSnapshotTests {
    @Test func theComponentsDraw() throws {
        let view = VStack(alignment: .leading, spacing: Deck.Metric.gap) {
            HStack {
                DeckNavItem("Now", selected: true) {}
                DeckNavItem("Stash", selected: false) {}
                DeckNavItem("Agents", selected: false, badge: 2) {}
            }
            DeckSubTabs(["Shelf", "Clipboard", "Notes"], selection: "Clipboard", title: { $0 }, select: { _ in })
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
