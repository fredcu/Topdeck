// SPDX-License-Identifier: MIT
import Foundation
import Testing

@testable import TopdeckFeatures

private let abc = InputSource(id: "com.apple.keylayout.ABC", name: "ABC", languages: ["en"])
private let pinyin = InputSource(
    id: "com.apple.inputmethod.SCIM.ITABC", name: "Pinyin - Simplified", languages: ["zh-Hans"])
private let kana = InputSource(
    id: "com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese", name: "Hiragana", languages: ["ja"])

private let xcode = InputSwitchApp(bundleID: "com.apple.dt.Xcode", name: "Xcode")
private let wechat = InputSwitchApp(bundleID: "com.tencent.xinWeChat", name: "WeChat")
private let safari = InputSwitchApp(bundleID: "com.apple.Safari", name: "Safari")
private let topdeck = InputSwitchApp(bundleID: "net.icuai.topdeck", name: "Topdeck")

private func makeDefaults() throws -> UserDefaults {
    try #require(UserDefaults(suiteName: "InputSwitchTests.\(UUID().uuidString)"))
}

struct InputSwitchRulesTests {
    private let available: Set = [abc.id, pinyin.id]

    private func fixed(_ source: InputSource) -> InputSwitchRules.Choice {
        InputSwitchRules.Choice(sourceID: source.id, reason: .fixed)
    }

    private func remembered(_ source: InputSource) -> InputSwitchRules.Choice {
        InputSwitchRules.Choice(sourceID: source.id, reason: .remembered)
    }

    @Test func aFixedSourceBeatsTheRememberedOne() {
        var rules = InputSwitchRules()
        rules.remember(abc.id, for: wechat)
        #expect(rules.choice(for: wechat.bundleID, available: available, remembers: true) == remembered(abc))
        rules.fix(pinyin.id, for: wechat)
        #expect(rules.choice(for: wechat.bundleID, available: available, remembers: true) == fixed(pinyin))
        #expect(rules.choice(for: wechat.bundleID, available: available, remembers: false)?.sourceID == pinyin.id)
    }

    @Test func eachAppGetsItsOwnSource() {
        var rules = InputSwitchRules()
        rules.remember(abc.id, for: xcode)
        rules.remember(pinyin.id, for: wechat)
        #expect(rules.choice(for: xcode.bundleID, available: available, remembers: true)?.sourceID == abc.id)
        #expect(rules.choice(for: wechat.bundleID, available: available, remembers: true)?.sourceID == pinyin.id)
        #expect(rules.choice(for: safari.bundleID, available: available, remembers: true) == nil, "never seen")
    }

    @Test func rememberedSourcesWaitWhileRememberingIsOff() {
        var rules = InputSwitchRules()
        rules.remember(pinyin.id, for: wechat)
        #expect(rules.choice(for: wechat.bundleID, available: available, remembers: false) == nil)
        #expect(rules.choice(for: wechat.bundleID, available: available, remembers: true) != nil)
    }

    @Test func aSourceTurnedOffIsSkipped() {
        var rules = InputSwitchRules()
        rules.fix(kana.id, for: xcode)
        #expect(rules.choice(for: xcode.bundleID, available: available, remembers: true) == nil)
        rules.remember(abc.id, for: xcode)
        let choice = rules.choice(for: xcode.bundleID, available: available, remembers: true)
        #expect(choice == remembered(abc), "falls back to the remembered one")
        let back = available.union([kana.id])
        #expect(rules.choice(for: xcode.bundleID, available: back, remembers: true) == fixed(kana))
    }

    @Test func removingAFixedSourceGoesBackToRemembering() {
        var rules = InputSwitchRules()
        rules.fix(pinyin.id, for: wechat)
        rules.fix(nil, for: wechat)
        #expect(rules.entries.isEmpty, "nothing left to keep")
        rules.remember(abc.id, for: wechat)
        rules.fix(pinyin.id, for: wechat)
        rules.fix(nil, for: wechat)
        #expect(rules.entries[wechat.bundleID]?.remembered == abc.id)
        #expect(rules.fixedApps.isEmpty)
    }

    @Test func forgettingKeepsTheFixedSources() {
        var rules = InputSwitchRules()
        rules.remember(abc.id, for: xcode)
        rules.remember(abc.id, for: wechat)
        rules.fix(pinyin.id, for: wechat)
        #expect(rules.hasRemembered)
        rules.forgetRemembered()
        #expect(!rules.hasRemembered)
        #expect(rules.entries[xcode.bundleID] == nil)
        #expect(rules.entries[wechat.bundleID]?.fixed == pinyin.id)
    }

    @Test func fixedAppsAreListedByName() {
        var rules = InputSwitchRules()
        rules.fix(abc.id, for: xcode)
        rules.fix(pinyin.id, for: wechat)
        rules.fix(abc.id, for: safari)
        rules.remember(abc.id, for: topdeck)
        #expect(rules.fixedApps.map(\.name) == ["Safari", "WeChat", "Xcode"])
    }

    @Test func emptyIDsAreIgnored() {
        var rules = InputSwitchRules()
        rules.remember("", for: xcode)
        rules.fix(abc.id, for: InputSwitchApp(bundleID: "", name: "Nameless"))
        rules.fix("", for: wechat)
        #expect(rules.entries.isEmpty)
    }

    @Test func chineseJapaneseKoreanAndVietnameseNeedTheFocusNudge() {
        #expect(pinyin.isCJKV)
        #expect(kana.isCJKV)
        #expect(InputSource(id: "2SetKorean", name: "2-Set", languages: ["ko"]).isCJKV)
        #expect(InputSource(id: "VietnameseTelex", name: "Telex", languages: ["vi", "en"]).isCJKV)
        #expect(InputSource(id: "Zhuyin", name: "Zhuyin", languages: ["zh-Hant"]).isCJKV)
        #expect(InputSource(id: "Cantonese", name: "Cantonese", languages: ["ZH-HK"]).isCJKV)
        #expect(!abc.isCJKV)
        #expect(!InputSource(id: "French", name: "French", languages: ["fr"]).isCJKV)
        #expect(!InputSource(id: "Unknown", name: "Unknown").isCJKV, "no language")
    }
}

@MainActor
struct InputSwitchStoreTests {
    @Test func startsOffAndRemembering() throws {
        let store = InputSwitchStore(defaults: try makeDefaults())
        #expect(!store.isEnabled)
        #expect(store.remembers)
        #expect(store.rules.entries.isEmpty)
    }

    @Test func rulesSurviveARelaunch() throws {
        let defaults = try makeDefaults()
        var rules = InputSwitchRules()
        rules.fix(pinyin.id, for: wechat)
        rules.remember(abc.id, for: xcode)
        let store = InputSwitchStore(defaults: defaults)
        store.rules = rules
        store.isEnabled = true
        store.remembers = false

        let relaunched = InputSwitchStore(defaults: defaults)
        #expect(relaunched.rules == rules)
        #expect(relaunched.rules.entries[wechat.bundleID]?.name == "WeChat")
        #expect(relaunched.isEnabled)
        #expect(!relaunched.remembers)
    }

    @Test func damagedRulesReadAsNone() throws {
        let defaults = try makeDefaults()
        defaults.set(Data("not json".utf8), forKey: "inputSwitch.rules")
        #expect(InputSwitchStore(defaults: defaults).rules.entries.isEmpty)
    }

    @Test func emptyStoredEntriesAreDropped() throws {
        let defaults = try makeDefaults()
        let json = """
            {"entries": {
                "com.apple.Safari": {"name": "Safari"},
                "com.apple.dt.Xcode": {"name": "Xcode", "fixed": "", "remembered": "com.apple.keylayout.ABC"},
                "": {"name": "Nameless", "fixed": "com.apple.keylayout.ABC"}
            }}
            """
        defaults.set(Data(json.utf8), forKey: "inputSwitch.rules")
        let rules = InputSwitchStore(defaults: defaults).rules
        #expect(Array(rules.entries.keys) == [xcode.bundleID])
        #expect(rules.entries[xcode.bundleID]?.fixed == nil)
        #expect(rules.entries[xcode.bundleID]?.remembered == abc.id)
    }
}

@MainActor
private final class FakeSources: InputSourceControlling {
    var onChange: (() -> Void)?
    var sources: [InputSource] = [abc, pinyin, kana]
    var currentID: String? = abc.id
    var selected: [String] = []
    var running = false
    /// Like the system: selecting posts a change notification.
    var notifies = true

    func start() { running = true }
    func stop() { running = false }
    func refresh() {}

    func select(_ id: String) throws {
        guard sources.contains(where: { $0.id == id }) else { throw InputSourceError.unavailable }
        selected.append(id)
        currentID = id
        if notifies { onChange?() }
    }

    /// The user picks a source from the menu bar or with the keyboard.
    func userSelects(_ id: String) {
        currentID = id
        onChange?()
    }
}

@MainActor
private final class FakeApps: FrontmostAppMonitoring {
    var onActivate: ((InputSwitchApp) -> Void)?
    var frontmost: InputSwitchApp?
    var running = false
    /// Holds the switcher, as the app delegate does: it only holds its monitors' callbacks weakly.
    var switcher: InputSwitcher?

    init(frontmost: InputSwitchApp?) { self.frontmost = frontmost }

    func start() { running = true }
    func stop() { running = false }

    func activate(_ app: InputSwitchApp) {
        frontmost = app
        onActivate?(app)
    }
}

@MainActor
struct InputSwitcherTests {
    private let sources = FakeSources()
    private let apps = FakeApps(frontmost: xcode)
    private let defaults: UserDefaults

    init() throws {
        defaults = try makeDefaults()
    }

    @discardableResult
    private func switcher(enabled: Bool = true) -> InputSwitcher {
        let store = InputSwitchStore(defaults: defaults)
        store.isEnabled = enabled
        let switcher = InputSwitcher(store: store, inputSources: sources, apps: apps, ownBundleID: topdeck.bundleID)
        switcher.resume()
        apps.switcher = switcher
        return switcher
    }

    @Test func eachAppGetsBackTheSourceItWasLeftWith() {
        let switcher = switcher()
        sources.userSelects(abc.id)  // in Xcode
        apps.activate(wechat)
        #expect(sources.selected.isEmpty, "WeChat has no source yet, so it keeps ABC")
        sources.userSelects(pinyin.id)
        apps.activate(xcode)
        #expect(sources.currentID == abc.id)
        apps.activate(wechat)
        #expect(sources.currentID == pinyin.id)
        #expect(sources.selected == [abc.id, pinyin.id])
        #expect(switcher.rules.entries[wechat.bundleID]?.remembered == pinyin.id)
        #expect(switcher.rules.entries[xcode.bundleID]?.remembered == abc.id)
    }

    @Test func rememberingWorksWhenTheSystemIsLateToNotify() {
        sources.notifies = false
        switcher()
        apps.activate(wechat)
        sources.currentID = pinyin.id  // changed, but the notification hasn't come yet
        apps.activate(xcode)
        apps.activate(wechat)
        #expect(sources.currentID == pinyin.id, "WeChat was remembered on the way out")
    }

    @Test func aFixedSourceAppliesEveryTime() {
        let switcher = switcher()
        switcher.fix(pinyin.id, for: wechat)
        apps.activate(wechat)
        #expect(sources.currentID == pinyin.id)
        sources.userSelects(abc.id)
        apps.activate(xcode)
        apps.activate(wechat)
        #expect(sources.currentID == pinyin.id, "the fixed source wins over the one it was left with")
    }

    @Test func fixingTheAppInFrontSwitchesAtOnce() {
        let switcher = switcher()
        switcher.fix(pinyin.id, for: xcode)
        #expect(sources.currentID == pinyin.id)
        switcher.fix(abc.id, for: safari)
        #expect(sources.currentID == pinyin.id, "Safari isn't in front")
    }

    @Test func topdecksOwnWindowsKeepTheCurrentSource() {
        let switcher = switcher()
        sources.userSelects(pinyin.id)  // in Xcode
        apps.activate(topdeck)
        #expect(sources.selected.isEmpty)
        sources.userSelects(abc.id)  // typing in Settings
        #expect(switcher.rules.entries[topdeck.bundleID] == nil)
        #expect(switcher.rules.entries[xcode.bundleID]?.remembered == pinyin.id)
        apps.activate(xcode)
        #expect(sources.currentID == pinyin.id, "back to what Xcode had")
    }

    @Test func turnedOffItLeavesSourcesAlone() {
        let switcher = switcher(enabled: false)
        #expect(!apps.running && !sources.running)
        switcher.fix(pinyin.id, for: wechat)
        apps.activate(wechat)
        #expect(sources.selected.isEmpty)

        switcher.isEnabled = true
        #expect(apps.running && sources.running)
        apps.activate(wechat)
        #expect(sources.currentID == pinyin.id)

        switcher.isEnabled = false
        #expect(!apps.running && !sources.running)
        #expect(!InputSwitchStore(defaults: defaults).isEnabled)
        apps.activate(xcode)
        sources.userSelects(kana.id)
        #expect(switcher.rules.entries[xcode.bundleID] == nil, "nothing is remembered while off")
    }

    @Test func withRememberingOffOnlyFixedSourcesApply() {
        let switcher = switcher()
        sources.userSelects(pinyin.id)
        apps.activate(safari)
        sources.userSelects(abc.id)
        switcher.remembers = false
        apps.activate(xcode)
        #expect(sources.currentID == abc.id)
        #expect(sources.selected.isEmpty)
    }

    @Test func aSourceTurnedOffIsNotSelected() {
        let switcher = switcher()
        switcher.fix(kana.id, for: wechat)
        sources.sources = [abc, pinyin]
        sources.onChange?()
        apps.activate(wechat)
        #expect(sources.selected.isEmpty)
        #expect(switcher.sources.map(\.id) == [abc.id, pinyin.id])
    }

    @Test func rulesAreSavedAsTheyChange() {
        let switcher = switcher()
        switcher.fix(pinyin.id, for: wechat)
        sources.userSelects(kana.id)
        #expect(InputSwitchStore(defaults: defaults).rules == switcher.rules)
        #expect(InputSwitchStore(defaults: defaults).rules.entries[xcode.bundleID]?.remembered == kana.id)
        switcher.forgetRemembered()
        #expect(InputSwitchStore(defaults: defaults).rules.entries[xcode.bundleID] == nil)
    }
}
