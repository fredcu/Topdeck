// SPDX-License-Identifier: MIT
import Foundation
import Testing

@testable import TopdeckFeatures

@MainActor
private func action(_ title: String, area: String = "Notch", keywords: String = "", app: Bool = false) -> CommandAction
{
    CommandAction(
        id: (app ? CommandAction.appPrefix : "") + title, title: title, area: area, symbol: "app", keywords: keywords,
        run: {})
}

@MainActor
private func search(_ items: [CommandAction], _ query: String = "") -> CommandSearch {
    var search = CommandSearch()
    search.setItems(items)
    search.setQuery(query)
    return search
}

@MainActor
@Suite struct CommandBarTests {
    @Test func lettersMatchInOrderAndIgnoreAccentsAndCase() {
        #expect(CommandMatcher.score("Café Maker", query: "cafe") != nil)
        #expect(CommandMatcher.score("Mute the Microphone", query: "mtmi") != nil)
        #expect(CommandMatcher.score("Mute the Microphone", query: "mic.") != nil)
        #expect(CommandMatcher.score("Mail", query: "lm") == nil)
        #expect(CommandMatcher.score("Mail", query: "") == 0)
    }

    @Test func wholeTextBeatsScatteredLetters() {
        let items = [action("Keep the Mac Awake", area: "Timer"), action("Mail", app: true)]
        #expect(search(items, "mail").results.first?.title == "Mail")
    }

    @Test func prefixAndShorterNamesRankFirst() {
        let items = [action("Open Sound Settings"), action("Sound"), action("Surround")]
        #expect(search(items, "sound").results.map(\.title).first == "Sound")
    }

    @Test func anActionOutranksAnAppWithTheSameMatch() {
        let items = [action("Safari", app: true), action("Safari", area: "Notch")]
        #expect(search(items, "safari").results.first?.isApp == false)
    }

    @Test func weakMatchesAreLeftOut() {
        let items = [action("Safari", app: true), action("Skip a Few Frames in Output", area: "Media")]
        #expect(search(items, "safari").results.map(\.title) == ["Safari"])
    }

    @Test func emptyQueryListsActionsInOrderWithoutApps() {
        let items = [action("Zebra"), action("Mail", app: true), action("Alpha")]
        #expect(search(items).results.map(\.title) == ["Zebra", "Alpha"])
    }

    @Test func appsArrivingLaterJoinTheSearchAndKeepTheSelection() {
        var search = search([action("Alpha"), action("Alpine")], "al")
        search.move(by: 1)
        let selected = search.results[search.selection].id
        search.add([action("Almanac", app: true)])
        #expect(search.results.count == 3)
        #expect(search.results[search.selection].id == selected)
    }

    @Test func selectionStaysInsideTheList() {
        var search = search([action("Alpha"), action("Alpine")], "al")
        search.move(by: -1)
        #expect(search.selection == 0)
        search.move(by: 5)
        #expect(search.selection == 1)
        search.setQuery("alpi")
        #expect(search.selection == 0)
    }

    @Test func returnRunsTheSelectedRow() {
        var search = search([action("Alpha"), action("Alpine")], "al")
        search.move(by: 1)
        #expect(search.actionToRun(hasMarkedText: false)?.id == search.results[1].id)
    }

    @Test func markedTextBlocksARun() {
        #expect(search([action("Alpha")], "al").actionToRun(hasMarkedText: true) == nil)
    }

    @Test func nothingMatchingRunsNothing() {
        #expect(search([action("Alpha")], "zzz").actionToRun(hasMarkedText: false) == nil)
    }

    @Test func composedTextIsLeftOutOfTheQuery() {
        // "打开 ni" with "ni" still being composed.
        let text = "打开ni"
        #expect(CommandSearch.committedText(text, marked: NSRange(location: 2, length: 2)) == "打开")
        #expect(CommandSearch.committedText(text, marked: NSRange(location: NSNotFound, length: 0)) == text)
        #expect(CommandSearch.committedText(text, marked: NSRange(location: 4, length: 9)) == text)
    }

    @Test func chineseTitlesMatch() {
        #expect(search([action("微信", app: true), action("Mail", app: true)], "微信").results.map(\.title) == ["微信"])
    }
}
