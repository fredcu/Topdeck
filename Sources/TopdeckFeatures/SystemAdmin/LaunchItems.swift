// SPDX-License-Identifier: MIT AND Apache-2.0
// Adapted from MacTools (https://github.com/mactools-app/MacTools) at 9197035, Plugins/LaunchControl:
// LaunchControlScanner.swift, LaunchControlModels.swift, and LaunchControlController.swift.
// Copyright the MacTools authors. Apache License 2.0; see THIRD_PARTY_NOTICES.md.
// Changed for Topdeck: renamed; async scanning through ToolProcess; labels validated before they reach
// launchctl; only agents in the user's own LaunchAgents folder can be managed; Apple's own items in
// /System are left out; no favorites, notes, or origin guessing; a line-based print-disabled parser
// that reads only the disabled services block.
import Foundation

/// A launchd job found as a plist in one of the LaunchAgents or LaunchDaemons folders.
public struct LaunchItem: Identifiable, Hashable, Sendable {
    /// Where its plist lives, which decides who may change it.
    public enum Scope: String, Sendable {
        /// ~/Library/LaunchAgents: the user's own, so Topdeck can manage it.
        case user
        /// /Library/LaunchAgents: every user's, installed by an app. Read-only.
        case global
        /// /Library/LaunchDaemons: system daemons, run as root. Read-only.
        case daemon
    }

    public enum State: String, Sendable {
        case running, loaded, disabled, failed, unloaded, unknown
    }

    public var id: String { plist.path }
    public let label: String
    public let plist: URL
    public let scope: Scope
    /// launchctl's domain for it: `gui/<uid>` or `system`.
    public let domain: String
    public var state: State
    public var pid: Int?
    public var lastExitStatus: Int?
    /// The command it runs.
    public let program: [String]

    public init(
        label: String, plist: URL, scope: Scope, domain: String, state: State, pid: Int? = nil,
        lastExitStatus: Int? = nil, program: [String] = []
    ) {
        self.label = label
        self.plist = plist
        self.scope = scope
        self.domain = domain
        self.state = state
        self.pid = pid
        self.lastExitStatus = lastExitStatus
        self.program = program
    }

    /// Only the user's own agents, and only with a label launchctl can be given safely.
    public var isManageable: Bool { scope == .user && AdminNames.isValidLabel(label) }

    /// `gui/<uid>/<label>`: what launchctl calls a service target.
    public var target: String { "\(domain)/\(label)" }
}

/// Something to do to a launch agent.
public enum LaunchAction: String, CaseIterable, Sendable {
    case start, stop, restart, load, unload, enable, disable, remove

    public var title: String {
        switch self {
        case .start: "Start"
        case .stop: "Stop"
        case .restart: "Restart"
        case .load: "Load"
        case .unload: "Unload"
        case .enable: "Enable"
        case .disable: "Disable"
        case .remove: "Remove"
        }
    }

    /// Asks first: what turns an agent off for good, or deletes it.
    public var isDestructive: Bool { self == .unload || self == .disable || self == .remove }

    /// launchctl's arguments, or nil when the item can't be managed. Remove unloads; the feature then
    /// moves the plist to the Trash.
    public func arguments(for item: LaunchItem) -> [String]? {
        guard item.isManageable else { return nil }
        switch self {
        case .start: return ["kickstart", item.target]
        case .stop: return ["kill", "TERM", item.target]
        case .restart: return ["kickstart", "-k", item.target]
        case .load: return ["bootstrap", item.domain, item.plist.path]
        case .unload, .remove: return ["bootout", item.target]
        case .enable: return ["enable", item.target]
        case .disable: return ["disable", item.target]
        }
    }

    /// The actions that make sense for an item in its current state.
    public static func available(for item: LaunchItem) -> [LaunchAction] {
        guard item.isManageable else { return [] }
        switch item.state {
        case .running: return [.restart, .stop, .unload, .disable, .remove]
        case .loaded, .failed, .unknown: return [.start, .unload, .disable, .remove]
        case .unloaded: return [.load, .disable, .remove]
        case .disabled: return [.enable, .remove]
        }
    }
}

/// Reads the launch folders and asks launchctl how each job is doing.
public struct LaunchScanner: Sendable {
    public typealias Launchctl = @Sendable ([String]) async -> ToolProcess.Result

    public static let launchctl = "/bin/launchctl"

    let home: URL
    let uid: uid_t
    let run: Launchctl
    /// The folders to read, in order, with their scope. Tests point these at a temporary folder.
    let folders: [(url: URL, scope: LaunchItem.Scope)]

    public init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser, uid: uid_t = getuid(),
        folders: [(url: URL, scope: LaunchItem.Scope)]? = nil,
        run: @escaping Launchctl = { await ToolProcess.run(LaunchScanner.launchctl, $0) }
    ) {
        self.home = home
        self.uid = uid
        self.run = run
        self.folders =
            folders ?? [
                (home.appending(path: "Library/LaunchAgents", directoryHint: .isDirectory), .user),
                (URL(filePath: "/Library/LaunchAgents", directoryHint: .isDirectory), .global),
                (URL(filePath: "/Library/LaunchDaemons", directoryHint: .isDirectory), .daemon),
            ]
    }

    public var userDomain: String { "gui/\(uid)" }

    public func scan() async -> [LaunchItem] {
        // One `list` covers the user's whole domain; daemons each need a `print`.
        let listed = Self.parseList(await run(["list"]).output)
        let disabledInUser = Self.parseDisabled(await run(["print-disabled", userDomain]).output)
        var disabledInSystem: Set<String>?
        var items: [LaunchItem] = []
        for folder in folders {
            guard
                let files = try? FileManager.default.contentsOfDirectory(
                    at: folder.url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            else { continue }
            for file in files where file.pathExtension == "plist" {
                guard let data = try? Data(contentsOf: file), let job = Self.parsePlist(data) else { continue }
                let label = job.label ?? file.deletingPathExtension().lastPathComponent
                let domain = folder.scope == .daemon ? "system" : userDomain
                var status: Status
                let disabled: Bool
                if folder.scope == .daemon {
                    if disabledInSystem == nil {
                        disabledInSystem = Self.parseDisabled(await run(["print-disabled", "system"]).output)
                    }
                    disabled = disabledInSystem?.contains(label) ?? false
                    status = Status(loaded: false)
                    if AdminNames.isValidLabel(label) {
                        let printed = await run(["print", "system/\(label)"])
                        status = printed.status == 0 ? Self.parsePrint(printed.output) : Status(loaded: false)
                    }
                } else {
                    disabled = disabledInUser.contains(label)
                    status = listed[label] ?? Status(loaded: false)
                }
                items.append(
                    LaunchItem(
                        label: label, plist: file, scope: folder.scope, domain: domain,
                        state: Self.state(status, disabled: disabled), pid: status.pid,
                        lastExitStatus: status.lastExitStatus, program: job.program))
            }
        }
        return items.sorted {
            $0.scope.order != $1.scope.order
                ? $0.scope.order < $1.scope.order
                : $0.label.localizedStandardCompare($1.label) == .orderedAscending
        }
    }

    /// What launchctl knows about a loaded job.
    struct Status: Equatable {
        var loaded = true
        var pid: Int?
        var lastExitStatus: Int?
    }

    static func state(_ status: Status, disabled: Bool) -> LaunchItem.State {
        if disabled { return .disabled }
        if let pid = status.pid, pid > 0 { return .running }
        if let exit = status.lastExitStatus, exit != 0 { return .failed }
        return status.loaded ? .loaded : .unloaded
    }

    /// `launchctl list`: a header, then `PID<tab>Status<tab>Label` per job, `-` for no PID.
    static func parseList(_ output: String) -> [String: Status] {
        var jobs: [String: Status] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let columns = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard columns.count == 3 else { continue }
            let label = columns[2].trimmingCharacters(in: .whitespaces)
            guard !label.isEmpty, label != "Label" else { continue }
            jobs[label] = Status(
                pid: Int(columns[0].trimmingCharacters(in: .whitespaces)),
                lastExitStatus: Int(columns[1].trimmingCharacters(in: .whitespaces)))
        }
        return jobs
    }

    /// `launchctl print <domain>/<label>`: the job's own `pid = ` and `last exit code = ` lines, before
    /// any nested block (a nested block can describe other processes).
    static func parsePrint(_ output: String) -> Status {
        var status = Status()
        var depth = 0
        for line in output.split(whereSeparator: \.isNewline) {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.hasSuffix("{") { depth += 1 }
            if text == "}" { depth -= 1 }
            guard depth == 1 else { continue }
            if let value = value(of: "pid", in: text) {
                status.pid = Int(value)
            } else if let value = value(of: "last exit code", in: text) ?? value(of: "last exit status", in: text) {
                status.lastExitStatus = Int(value)
            }
        }
        return status
    }

    private static func value(of key: String, in line: String) -> String? {
        guard line.hasPrefix(key + " = ") else { return nil }
        return String(line.dropFirst(key.count + 3)).trimmingCharacters(in: .whitespaces)
    }

    /// `launchctl print-disabled <domain>`: the labels set to `disabled` (or `true`, before macOS 14) in
    /// its `disabled services` block. Other blocks, such as login item associations, are skipped.
    static func parseDisabled(_ output: String) -> Set<String> {
        var labels: Set<String> = []
        var inServices = false
        for line in output.split(whereSeparator: \.isNewline) {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.hasSuffix("= {") {
                inServices = text.hasPrefix("disabled services")
                continue
            }
            if text == "}" {
                inServices = false
                continue
            }
            guard inServices, text.hasPrefix("\""), let close = text.dropFirst().firstIndex(of: "\"") else { continue }
            let label = String(text[text.index(after: text.startIndex)..<close])
            let value = text[text.index(after: close)...].trimmingCharacters(in: .whitespaces)
            if value == "=> disabled" || value == "=> true" { labels.insert(label) }
        }
        return labels
    }

    struct Job: Equatable {
        var label: String?
        var program: [String]
    }

    /// A launchd plist, XML or binary: its label and the command it runs.
    static func parsePlist(_ data: Data) -> Job? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        let label = (plist["Label"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let program = plist["ProgramArguments"] as? [String] ?? (plist["Program"] as? String).map { [$0] } ?? []
        return Job(label: label, program: program)
    }
}

extension LaunchItem.Scope {
    fileprivate var order: Int {
        switch self {
        case .user: 0
        case .global: 1
        case .daemon: 2
        }
    }
}
