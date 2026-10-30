// SPDX-License-Identifier: MIT
import Foundation
import Testing
import os

@testable import TopdeckFeatures

struct AdminNamesTests {
    @Test(arguments: [
        "com.example.agent", "homebrew.mxcl.postgresql@16", "local.backup", "org.nix-community.daemon", "a",
        "com.Example_App.Helper2",
    ])
    func labelsLaunchdUsesPass(label: String) {
        #expect(AdminNames.isValidLabel(label))
    }

    @Test(arguments: [
        "", "-k", "--help", ".hidden", "gui/501/com.example", "com.example agent", "com.example;rm", "com.example\n",
        "com.ëxample", "com.example$(id)", String(repeating: "a", count: 256),
    ])
    func labelsThatCouldMisleadLaunchctlFail(label: String) {
        #expect(!AdminNames.isValidLabel(label))
    }

    @Test(arguments: [
        "wget", "python@3.13", "gtk+3", "node_exporter", "visual-studio-code", "user/tap/formula", "1password",
    ])
    func packageNamesBrewUsesPass(name: String) {
        #expect(AdminNames.isValidPackage(name))
    }

    @Test(arguments: [
        "", "-f", "--force", "wget --force", "../wget", "user/formula", "user//formula", "a/b/c/d", "wget;ls",
        "wget`id`", "wget\t", "ffmpég",
    ])
    func packageNamesThatCouldMisleadBrewFail(name: String) {
        #expect(!AdminNames.isValidPackage(name))
    }
}

struct LaunchctlParsingTests {
    @Test func listGivesEachJobsPIDAndLastExitStatus() {
        let output =
            "PID\tStatus\tLabel\n-\t0\tcom.example.idle\n4242\t0\tcom.example.running\n"
            + "-\t78\tcom.example.crashed\n-\t-9\tcom.example.killed\nnot a row\n"
        let jobs = LaunchScanner.parseList(output)
        #expect(jobs.count == 4)
        #expect(jobs["com.example.idle"] == .init(pid: nil, lastExitStatus: 0))
        #expect(jobs["com.example.running"] == .init(pid: 4242, lastExitStatus: 0))
        #expect(jobs["com.example.crashed"] == .init(pid: nil, lastExitStatus: 78))
        #expect(jobs["com.example.killed"]?.lastExitStatus == -9)
        #expect(jobs["Label"] == nil)
    }

    @Test func printReadsOnlyTheJobsOwnLines() {
        let output = """
            system/com.example.daemon = {
            \tactive count = 1
            \tpath = /Library/LaunchDaemons/com.example.daemon.plist
            \tstate = running

            \tprogram = /usr/local/bin/daemon
            \targuments = {
            \t\t/usr/local/bin/daemon
            \t\tpid = 99
            \t}

            \truns = 3
            \tpid = 4242
            \tlast exit code = 1
            }
            """
        #expect(LaunchScanner.parsePrint(output) == .init(pid: 4242, lastExitStatus: 1))
        let neverRan = "system/com.example.idle = {\n\tstate = not running\n\tlast exit code = (never exited)\n}\n"
        #expect(LaunchScanner.parsePrint(neverRan) == .init(pid: nil, lastExitStatus: nil))
    }

    @Test func printDisabledReadsOnlyTheDisabledServices() {
        let modern = """
            disabled services = {
            \t"com.apple.ScriptMenuApp" => disabled
            \t"com.example.off" => disabled
            \t"com.example.on" => enabled
            }

            login item associations = {
            \t"com.example.helper" => disabled
            }
            """
        #expect(LaunchScanner.parseDisabled(modern) == ["com.apple.ScriptMenuApp", "com.example.off"])
        let beforeSonoma = "disabled services = {\n\t\"com.example.old\" => true\n\t\"com.example.new\" => false\n}\n"
        #expect(LaunchScanner.parseDisabled(beforeSonoma) == ["com.example.old"])
        #expect(LaunchScanner.parseDisabled("").isEmpty)
    }

    @Test func plistsGiveTheirLabelAndCommand() throws {
        let xml = try PropertyListSerialization.data(
            fromPropertyList: ["Label": "com.example.agent", "ProgramArguments": ["/usr/bin/true", "--flag"]],
            format: .xml, options: 0)
        let job = LaunchScanner.Job(label: "com.example.agent", program: ["/usr/bin/true", "--flag"])
        #expect(LaunchScanner.parsePlist(xml) == job)
        let binary = try PropertyListSerialization.data(
            fromPropertyList: ["Program": "/usr/bin/true"], format: .binary, options: 0)
        #expect(LaunchScanner.parsePlist(binary) == .init(label: nil, program: ["/usr/bin/true"]))
        #expect(LaunchScanner.parsePlist(Data("not a plist".utf8)) == nil)
    }

    @Test func stateComesFromDisabledThenPIDThenExitStatus() {
        #expect(LaunchScanner.state(.init(pid: 12, lastExitStatus: 0), disabled: true) == .disabled)
        #expect(LaunchScanner.state(.init(pid: 12, lastExitStatus: 1), disabled: false) == .running)
        #expect(LaunchScanner.state(.init(pid: nil, lastExitStatus: 1), disabled: false) == .failed)
        #expect(LaunchScanner.state(.init(pid: nil, lastExitStatus: 0), disabled: false) == .loaded)
        #expect(LaunchScanner.state(.init(loaded: false), disabled: false) == .unloaded)
    }
}

struct LaunchScannerTests {
    private let root = FileManager.default.temporaryDirectory.appending(path: "LaunchScanner-\(UUID().uuidString)")

    private func write(_ plist: [String: Any], to folder: String, as name: String) throws {
        let url = root.appending(path: folder)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: url.appending(path: name))
    }

    @Test func scanningCombinesTheFoldersWithWhatLaunchctlSays() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try write(["Label": "com.example.running", "Program": "/usr/bin/true"], to: "user", as: "a.plist")
        try write(["Label": "com.example.off"], to: "user", as: "b.plist")
        try write(["ProgramArguments": ["/usr/bin/true"]], to: "user", as: "local.unnamed.plist")
        try write(["Label": "com.vendor.updater"], to: "global", as: "c.plist")
        try write(["Label": "com.vendor.daemon"], to: "daemons", as: "d.plist")
        try Data("ignored".utf8).write(to: root.appending(path: "user/notes.txt"))
        let asked = OSAllocatedUnfairLock(initialState: [[String]]())
        let scanner = LaunchScanner(
            uid: 501,
            folders: [
                (root.appending(path: "user"), .user), (root.appending(path: "global"), .global),
                (root.appending(path: "daemons"), .daemon),
            ]
        ) { arguments in
            asked.withLock { $0.append(arguments) }
            switch arguments {
            case ["list"]: return .init(status: 0, output: "PID\tStatus\tLabel\n77\t0\tcom.example.running\n")
            case ["print-disabled", "gui/501"]:
                return .init(status: 0, output: "disabled services = {\n\t\"com.example.off\" => disabled\n}\n")
            case ["print", "system/com.vendor.daemon"]:
                return .init(status: 0, output: "system/com.vendor.daemon = {\n\tpid = 9\n}\n")
            default: return .init(status: 0, output: "")
            }
        }
        let items = await scanner.scan()
        let user = ["com.example.off", "com.example.running", "local.unnamed"]
        #expect(items.map(\.label) == user + ["com.vendor.updater", "com.vendor.daemon"])
        let byLabel = Dictionary(uniqueKeysWithValues: items.map { ($0.label, $0) })
        #expect(byLabel["com.example.running"]?.state == .running && byLabel["com.example.running"]?.pid == 77)
        #expect(byLabel["com.example.off"]?.state == .disabled)
        #expect(byLabel["local.unnamed"]?.state == .unloaded, "named after its file, and not in the list")
        #expect(byLabel["com.vendor.updater"]?.domain == "gui/501")
        #expect(byLabel["com.vendor.daemon"]?.domain == "system" && byLabel["com.vendor.daemon"]?.state == .running)
        #expect(items.filter(\.isManageable).map(\.label) == user)
        #expect(asked.withLock { $0 }.allSatisfy { ["list", "print-disabled", "print"].contains($0[0]) }, "reads only")
    }
}

struct LaunchActionTests {
    private let agent = LaunchItem(
        label: "com.example.agent", plist: URL(filePath: "/Users/me/Library/LaunchAgents/com.example.agent.plist"),
        scope: .user, domain: "gui/501", state: .running)

    @Test func actionsBecomeLaunchctlArgumentsForTheUsersDomain() {
        #expect(LaunchAction.start.arguments(for: agent) == ["kickstart", "gui/501/com.example.agent"])
        #expect(LaunchAction.restart.arguments(for: agent) == ["kickstart", "-k", "gui/501/com.example.agent"])
        #expect(LaunchAction.stop.arguments(for: agent) == ["kill", "TERM", "gui/501/com.example.agent"])
        #expect(
            LaunchAction.load.arguments(for: agent)
                == ["bootstrap", "gui/501", "/Users/me/Library/LaunchAgents/com.example.agent.plist"])
        #expect(LaunchAction.unload.arguments(for: agent) == ["bootout", "gui/501/com.example.agent"])
        #expect(LaunchAction.disable.arguments(for: agent) == ["disable", "gui/501/com.example.agent"])
        #expect(LaunchAction.enable.arguments(for: agent) == ["enable", "gui/501/com.example.agent"])
    }

    @Test func otherScopesAndOddLabelsAreReadOnly() {
        for scope in [LaunchItem.Scope.global, .daemon] {
            let item = LaunchItem(
                label: "com.vendor.daemon", plist: URL(filePath: "/Library/LaunchDaemons/com.vendor.daemon.plist"),
                scope: scope, domain: "system", state: .running)
            #expect(LaunchAction.allCases.allSatisfy { $0.arguments(for: item) == nil })
            #expect(LaunchAction.available(for: item).isEmpty)
        }
        let odd = LaunchItem(
            label: "-k", plist: URL(filePath: "/Users/me/Library/LaunchAgents/x.plist"), scope: .user,
            domain: "gui/501", state: .loaded)
        #expect(LaunchAction.allCases.allSatisfy { $0.arguments(for: odd) == nil })
    }

    @Test func onlyUnloadDisableAndRemoveAreDestructive() {
        #expect(LaunchAction.allCases.filter(\.isDestructive) == [.unload, .disable, .remove])
        #expect(LaunchAction.available(for: agent).contains(.stop))
    }
}

struct BrewParsingTests {
    private let info = Data(
        """
        {
          "formulae": [
            {
              "name": "wget", "full_name": "wget", "desc": "Internet file retriever",
              "versions": {"stable": "1.25.0", "head": "HEAD", "bottle": true},
              "installed": [{"version": "1.24.5", "installed_on_request": true}],
              "pinned": false, "outdated": true
            },
            {
              "name": "python@3.13", "full_name": "python@3.13", "desc": "Interpreted language",
              "versions": {"stable": "3.13.1"}, "installed": [{"version": "3.13.1"}],
              "pinned": true, "outdated": false
            },
            {
              "name": "tool", "full_name": "someone/tap/tool", "desc": null,
              "versions": {"stable": "2.0"}, "installed": [{"version": "1.0"}, {"version": "2.0"}],
              "pinned": false, "outdated": false
            },
            {"name": "not-installed", "full_name": "not-installed", "installed": []}
          ],
          "casks": [
            {
              "token": "firefox", "full_token": "firefox", "name": ["Mozilla Firefox"], "desc": "Web browser",
              "version": "133.0", "installed": "132.0", "outdated": true
            },
            {
              "token": "iterm2", "full_token": "iterm2", "name": ["iTerm2"], "desc": null,
              "version": "3.5.10", "installed": "3.5.10", "outdated": false
            }
          ]
        }
        """.utf8)

    @Test func infoListsEveryInstalledFormulaAndCask() throws {
        let packages = try Brew.parseInstalled(info)
        #expect(packages.map(\.name) == ["firefox", "iterm2", "python@3.13", "tool", "wget"])
        let wget = try #require(packages.first { $0.name == "wget" })
        #expect(wget.kind == .formula && wget.version == "1.24.5" && wget.latest == "1.25.0")
        #expect(wget.summary == "Internet file retriever" && wget.id == "formula:wget")
        let python = try #require(packages.first { $0.name == "python@3.13" })
        #expect(python.isPinned && !python.isOutdated)
        let tool = try #require(packages.first { $0.name == "tool" })
        #expect(tool.fullName == "someone/tap/tool" && tool.version == "2.0", "the newest installed version")
        let firefox = try #require(packages.first { $0.name == "firefox" })
        #expect(firefox.kind == .cask && firefox.version == "132.0" && firefox.latest == "133.0")
        let iterm = try #require(packages.first { $0.name == "iterm2" })
        #expect(iterm.summary == "iTerm2" && !iterm.isOutdated, "a cask without a description shows its name")
    }

    @Test func outdatedGivesTheNewestVersions() throws {
        let output = Data(
            """
            {
              "formulae": [
                {"name": "wget", "installed_versions": ["1.24.5"], "current_version": "1.25.0",
                 "pinned": false, "pinned_version": null}
              ],
              "casks": [
                {"name": "iterm2", "installed_versions": ["3.5.10"], "current_version": "3.5.11"}
              ]
            }
            """.utf8)
        let latest = try Brew.parseOutdated(output)
        #expect(latest == ["formula:wget": "1.25.0", "cask:iterm2": "3.5.11"])
        let merged = Brew.merge(try Brew.parseInstalled(info), outdated: latest)
        #expect(merged.filter(\.isOutdated).map(\.name) == ["iterm2", "wget"], "outdated wins over info")
    }

    @Test func somethingThatIsntJSONThrows() {
        #expect(throws: Brew.ParseError.self) { try Brew.parseInstalled(Data("Error: no such command".utf8)) }
        #expect(throws: Brew.ParseError.self) { try Brew.parseOutdated(Data()) }
        #expect(try Brew.parseInstalled(Data("{}".utf8)).isEmpty)
    }

    @Test func actionsBecomeBrewArgumentsAndBadNamesNone() {
        let wget = BrewPackage(name: "wget", kind: .formula, version: "1")
        let firefox = BrewPackage(name: "firefox", kind: .cask, version: "1")
        let tapped = BrewPackage(name: "tool", fullName: "someone/tap/tool", kind: .formula, version: "1")
        #expect(BrewAction.upgrade(wget).arguments == ["upgrade", "--formula", "wget"])
        #expect(BrewAction.uninstall(firefox).arguments == ["uninstall", "--cask", "firefox"])
        #expect(BrewAction.upgrade(tapped).arguments == ["upgrade", "--formula", "someone/tap/tool"])
        #expect(BrewAction.upgradeAll.arguments == ["upgrade"])
        #expect(BrewAction.doctor.arguments == ["doctor"])
        #expect(BrewAction.update.arguments == ["update"])
        let bad = BrewPackage(name: "--force", kind: .formula, version: "1")
        #expect(BrewAction.uninstall(bad).arguments == nil && BrewAction.upgrade(bad).arguments == nil)
        #expect(BrewAction.uninstall(wget).isDestructive && !BrewAction.upgradeAll.isDestructive)
    }

    @Test func brewRunsWithItsFolderFirstAndNothingInteractive() {
        let environment = Brew.environment(
            brew: "/opt/homebrew/bin/brew", base: ["PATH": "/usr/bin:/opt/homebrew/bin:/bin", "HOME": "/Users/me"])
        #expect(environment["PATH"] == "/opt/homebrew/bin:/usr/bin:/bin")
        #expect(environment["HOME"] == "/Users/me")
        #expect(environment["HOMEBREW_NO_AUTO_UPDATE"] == "1" && environment["NONINTERACTIVE"] == "1")
    }

    @Test func brewIsFoundOnlyWhereItIsAnExecutableFile() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "Brew-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let directory = folder.appending(path: "dir/brew")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let plain = folder.appending(path: "plain")
        try Data().write(to: plain)
        let executable = folder.appending(path: "brew")
        try Data("#!/bin/sh\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let paths = [folder.appending(path: "missing").path, folder.appending(path: "dir/brew").path, plain.path]
        #expect(Brew.locate(paths: paths) == nil)
        #expect(Brew.locate(paths: paths + [executable.path]) == executable.path)
    }
}

/// Records what the feature runs, and answers each with success.
private final class Recorder: Sendable {
    let calls = OSAllocatedUnfairLock(initialState: [[String]]())

    var all: [[String]] { calls.withLock { $0 } }

    var runner: SystemAdminFeature.Runner {
        { [calls] executable, arguments, _, onLine in
            calls.withLock { $0.append([executable] + arguments) }
            onLine?("ran \(arguments.first ?? "")")
            return .init(status: 0, output: "")
        }
    }
}

@MainActor
struct SystemAdminFeatureTests {
    private let recorder = Recorder()
    private let trashed = OSAllocatedUnfairLock(initialState: [URL]())
    private let agent = LaunchItem(
        label: "com.example.agent", plist: URL(filePath: "/Users/me/Library/LaunchAgents/com.example.agent.plist"),
        scope: .user, domain: "gui/501", state: .running)

    private func feature() -> SystemAdminFeature {
        SystemAdminFeature(
            run: recorder.runner, launchFolders: [], uid: 501, brewPath: { "/opt/homebrew/bin/brew" },
            trash: { [trashed] url in trashed.withLock { $0.append(url) } })
    }

    @Test func disablingAsksFirstAndRunsOnlyOnceConfirmed() async {
        let admin = feature()
        admin.perform(.disable, on: agent)
        #expect(admin.pending != nil && admin.job == nil)
        #expect(recorder.all.isEmpty)
        admin.confirm()
        #expect(await eventually { admin.job?.result != nil })
        #expect(recorder.all == [["/bin/launchctl", "disable", "gui/501/com.example.agent"]])
        #expect(admin.job?.lines == ["ran disable"])
    }

    @Test func dismissingTheQuestionRunsNothing() async throws {
        let admin = feature()
        for action in [LaunchAction.unload, .disable, .remove] {
            admin.perform(action, on: agent)
            admin.dismissPending()
        }
        admin.perform(.uninstall(BrewPackage(name: "wget", kind: .formula, version: "1")))
        #expect(admin.pending != nil)
        admin.dismissPending()
        try await Task.sleep(for: .milliseconds(100))
        #expect(recorder.all.isEmpty && admin.job == nil)
    }

    @Test func removingUnloadsThenMovesThePlistToTheTrash() async {
        let admin = feature()
        admin.perform(.remove, on: agent)
        admin.confirm()
        #expect(await eventually { admin.job?.result != nil })
        #expect(recorder.all == [["/bin/launchctl", "bootout", "gui/501/com.example.agent"]])
        #expect(trashed.withLock { $0 } == [agent.plist])
    }

    @Test func startingRunsAtOnce() async {
        let admin = feature()
        admin.perform(.start, on: agent)
        #expect(admin.pending == nil)
        #expect(await eventually { admin.job?.result != nil })
        #expect(recorder.all == [["/bin/launchctl", "kickstart", "gui/501/com.example.agent"]])
        admin.closeJob()
        #expect(admin.job == nil)
    }

    @Test func readOnlyItemsAndBadNamesAreIgnored() async throws {
        let admin = feature()
        let daemon = LaunchItem(
            label: "com.vendor.daemon", plist: URL(filePath: "/Library/LaunchDaemons/com.vendor.daemon.plist"),
            scope: .daemon, domain: "system", state: .running)
        for action in LaunchAction.allCases { admin.perform(action, on: daemon) }
        admin.perform(.uninstall(BrewPackage(name: "-rf", kind: .formula, version: "1")))
        admin.perform(.upgrade(BrewPackage(name: "a b", kind: .cask, version: "1")))
        try await Task.sleep(for: .milliseconds(100))
        #expect(admin.pending == nil && admin.job == nil && recorder.all.isEmpty)
    }

    @Test func uninstallingAsksFirstThenRunsBrew() async {
        let admin = feature()
        admin.perform(.uninstall(BrewPackage(name: "firefox", kind: .cask, version: "1")))
        #expect(recorder.all.isEmpty)
        admin.confirm()
        #expect(await eventually { admin.job?.result != nil })
        #expect(recorder.all == [["/opt/homebrew/bin/brew", "uninstall", "--cask", "firefox"]])
    }

    @Test func doctorRunsAtOnceAndListsDropWhenStopped() async {
        let admin = feature()
        admin.perform(.doctor)
        #expect(await eventually { admin.job?.result != nil })
        #expect(recorder.all == [["/opt/homebrew/bin/brew", "doctor"]])
        admin.phase = .foreground  // reads the (empty) launch folders
        #expect(await eventually { admin.services != nil })
        admin.phase = .stopped
        #expect(admin.services == nil && admin.packages == nil)
        #expect(admin.job != nil, "a command's output stays until it's closed")
    }
}

struct ToolProcessTests {
    @Test func outputArrivesLineByLineAndInFull() async {
        let lines = OSAllocatedUnfairLock(initialState: [String]())
        let result = await ToolProcess.run("/bin/echo", ["one two"], mergesErrors: true) { line in
            lines.withLock { $0.append(line) }
        }
        #expect(result == .init(status: 0, output: "one two\n"))
        #expect(lines.withLock { $0 } == ["one two"])
    }

    @Test func standardErrorIsDroppedUnlessMerged() async {
        let quiet = await ToolProcess.run("/bin/ls", ["/no/such/path"])
        #expect(quiet.status != 0 && quiet.output.isEmpty)
        let merged = await ToolProcess.run("/bin/ls", ["/no/such/path"], mergesErrors: true)
        #expect(merged.output.contains("/no/such/path"))
    }

    @Test func argumentsAreNeverReadByAShell() async {
        let result = await ToolProcess.run("/bin/echo", ["$(id)", "; ls", "`id`"])
        #expect(result.output == "$(id) ; ls `id`\n")
    }

    @Test func aMissingToolFails() async {
        #expect(await ToolProcess.run("/no/such/tool", []).status == -1)
    }

    @Test func cancellingStopsTheToolAndWhatItStarted() async throws {
        let started = OSAllocatedUnfairLock(initialState: false)
        let clock = ContinuousClock()
        let start = clock.now
        // A child that would outlive its parent: only killing the process group ends it early.
        let task = Task {
            await ToolProcess.run("/bin/sh", ["-c", "sleep 60 & echo started; wait"], mergesErrors: true) { _ in
                started.withLock { $0 = true }
            }
        }
        while !started.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(20)) }
        task.cancel()
        let result = await task.value
        #expect(result.cancelled && !result.succeeded)
        #expect(clock.now - start < .seconds(20))
    }
}
