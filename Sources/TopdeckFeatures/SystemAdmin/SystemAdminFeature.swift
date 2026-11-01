// SPDX-License-Identifier: MIT
import Foundation
import Observation
import SwiftUI
import TopdeckCore

/// Launch agents and Homebrew from the notch. Everything runs as the user: launchctl in the user's own
/// domain and brew as installed, with no helper and no sudo. Agents outside ~/Library/LaunchAgents
/// and system daemons are shown but read-only. Unloading, disabling, removing, and uninstalling wait
/// for a confirmation, and a command's output shows as it runs, with Cancel.
@MainActor
@Observable
public final class SystemAdminFeature: NotchFeature {
    public enum Section: String, CaseIterable, Identifiable, Sendable {
        case services, homebrew

        public var id: Self { self }

        public var title: String {
            switch self {
            case .services: "Services"
            case .homebrew: "Homebrew"
            }
        }
    }

    /// A command started from the tab: its output so far and, once it's done, how it ended.
    public struct Job: Identifiable, Sendable {
        public let id = UUID()
        public let title: String
        public var lines: [String] = []
        public var result: ToolProcess.Result?

        public var isRunning: Bool { result == nil }
    }

    /// An action that waits for the user to confirm it.
    public struct Pending: Identifiable, Sendable {
        public enum Action: Sendable {
            case launch(LaunchAction, LaunchItem)
            case brew(BrewAction)
        }

        public let id = UUID()
        public let action: Action

        public var title: String {
            switch action {
            case .launch(let action, let item): "\(action.title) \(item.label)?"
            case .brew(let action): "\(action.title)?"
            }
        }

        public var message: String {
            switch action {
            case .launch(.remove, _): "It's unloaded and its file goes to the Trash."
            case .launch(.disable, _): "It won't start again, even after a restart, until you enable it."
            case .launch: "It stops and won't start again until it's loaded or you log in again."
            case .brew: "Its files are removed from this Mac."
            }
        }

        public var button: String {
            switch action {
            case .launch(let action, _): action.title
            case .brew: "Uninstall"
            }
        }
    }

    /// Runs a tool. `onLine` is set for a command whose output is shown, which then gets standard
    /// error too; without it, standard error is dropped so JSON stays clean.
    public typealias Runner =
        @Sendable (
            _ executable: String, _ arguments: [String], _ environment: [String: String]?,
            _ onLine: (@Sendable (String) -> Void)?
        ) async -> ToolProcess.Result

    public let id = FeatureID.admin
    public var phase: FeaturePhase = .stopped {
        didSet {
            guard phase != oldValue else { return }
            if phase == .foreground { loadIfNeeded() }
            // Lists and pending questions go; a command the user started keeps running to the end.
            if phase == .stopped {
                loadTask?.cancel()
                loadTask = nil
                services = nil
                packages = nil
                brewError = nil
                pending = nil
                isLoading = false
            }
        }
    }
    public var section = Section.services {
        didSet { if section != oldValue, phase == .foreground { loadIfNeeded() } }
    }
    /// Nil until they're read.
    public private(set) var services: [LaunchItem]?
    public private(set) var packages: [BrewPackage]?
    public private(set) var isLoading = false
    /// Why the Homebrew list couldn't be read.
    public private(set) var brewError: String?
    public private(set) var job: Job?
    public private(set) var pending: Pending?
    /// Raised when a command finishes.
    @ObservationIgnored public var onActivity: ((Activity) -> Void)?

    @ObservationIgnored private let run: Runner
    @ObservationIgnored private let scanner: LaunchScanner
    @ObservationIgnored private let brewPath: () -> String?
    @ObservationIgnored private let trash: @Sendable (URL) throws -> Void
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var jobTask: Task<Void, Never>?
    /// The most output lines a job keeps.
    static let maxLines = 500

    public convenience init() {
        self.init(run: { await ToolProcess.run($0, $1, environment: $2, mergesErrors: $3 != nil, onLine: $3) })
    }

    init(
        run: @escaping Runner, launchFolders: [(url: URL, scope: LaunchItem.Scope)]? = nil, uid: uid_t = getuid(),
        brewPath: @escaping () -> String? = { Brew.locate() },
        trash: @escaping @Sendable (URL) throws -> Void = moveToTrash
    ) {
        self.run = run
        self.scanner = LaunchScanner(
            uid: uid, folders: launchFolders, run: { await run(LaunchScanner.launchctl, $0, nil, nil) })
        self.brewPath = brewPath
        self.trash = trash
    }

    public var view: some View { SystemAdminView(admin: self) }

    nonisolated static func moveToTrash(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    public var outdated: [BrewPackage] { packages?.filter(\.isOutdated) ?? [] }

    /// How many launch services failed, as far as they have been read.
    public var failedCount: Int { services?.filter { $0.state == .failed }.count ?? 0 }

    /// Shows these lists as read, with no reading: for screenshots and tests.
    func preview(services: [LaunchItem]?, packages: [BrewPackage]?) {
        self.services = services
        self.packages = packages
    }

    /// Reads the open section's list again.
    public func refresh() {
        loadTask?.cancel()
        isLoading = true
        switch section {
        case .services:
            loadTask = Task {
                let items = await scanner.scan()
                guard !Task.isCancelled, phase != .stopped else { return }
                services = items
                isLoading = false
            }
        case .homebrew:
            loadTask = Task { await loadPackages() }
        }
    }

    private func loadIfNeeded() {
        switch section {
        case .services where services == nil, .homebrew where packages == nil && brewError == nil: refresh()
        default: break
        }
    }

    private func loadPackages() async {
        guard let brew = brewPath() else {
            brewError = "Homebrew isn't installed"
            packages = nil
            isLoading = false
            return
        }
        let environment = Brew.environment(brew: brew, base: ProcessInfo.processInfo.environment)
        let info = await run(brew, ["info", "--json=v2", "--installed"], environment, nil)
        guard !Task.isCancelled, phase != .stopped else { return }
        guard info.succeeded, var list = try? Brew.parseInstalled(Data(info.output.utf8)) else {
            brewError = "brew info didn't answer"
            isLoading = false
            return
        }
        let outdated = await run(brew, ["outdated", "--json=v2"], environment, nil)
        guard !Task.isCancelled, phase != .stopped else { return }
        // brew outdated exits 1 when something is outdated; the JSON is what counts.
        if let latest = try? Brew.parseOutdated(Data(outdated.output.utf8)) {
            list = Brew.merge(list, outdated: latest)
        }
        packages = list
        brewError = nil
        isLoading = false
    }

    // MARK: Actions

    /// Runs `action` on a launch agent, or asks first when it's destructive. Does nothing for an item
    /// that isn't the user's own.
    public func perform(_ action: LaunchAction, on item: LaunchItem) {
        guard action.arguments(for: item) != nil else { return }
        if action.isDestructive {
            pending = Pending(action: .launch(action, item))
        } else {
            execute(action, on: item)
        }
    }

    /// Runs a Homebrew action, or asks first when it's destructive.
    public func perform(_ action: BrewAction) {
        guard action.arguments != nil else { return }
        if action.isDestructive {
            pending = Pending(action: .brew(action))
        } else {
            execute(action)
        }
    }

    public func confirm() {
        guard let pending else { return }
        self.pending = nil
        switch pending.action {
        case .launch(let action, let item): execute(action, on: item)
        case .brew(let action): execute(action)
        }
    }

    public func dismissPending() { pending = nil }

    /// Stops the running command and whatever it started.
    public func cancelJob() { jobTask?.cancel() }

    /// Closes a finished command's output.
    public func closeJob() {
        guard job?.isRunning == false else { return }
        job = nil
    }

    private func execute(_ action: LaunchAction, on item: LaunchItem) {
        guard let arguments = action.arguments(for: item) else { return }
        let title = "\(action.title) \(item.label)"
        start(title, LaunchScanner.launchctl, arguments, environment: nil) { [weak self] result in
            guard let self else { return }
            if action == .remove, !result.cancelled {
                // Unloading fails for an agent that wasn't loaded; the file goes either way.
                do {
                    try trash(item.plist)
                    append("Moved \(item.plist.lastPathComponent) to the Trash.", to: job?.id)
                } catch {
                    append("Couldn't move it to the Trash: \(error.localizedDescription)", to: job?.id)
                }
            }
            services = nil
            if phase == .foreground, section == .services { refresh() }
        }
    }

    private func execute(_ action: BrewAction) {
        guard let arguments = action.arguments, let brew = brewPath() else { return }
        let environment = Brew.environment(brew: brew, base: ProcessInfo.processInfo.environment)
        start(action.title, brew, arguments, environment: environment) { [weak self] _ in
            guard let self, action != .doctor else { return }
            packages = nil
            if phase == .foreground, section == .homebrew { refresh() }
        }
    }

    /// Runs one command at a time, its output streaming into `job`.
    private func start(
        _ title: String, _ executable: String, _ arguments: [String], environment: [String: String]?,
        then finish: @escaping @MainActor (ToolProcess.Result) -> Void
    ) {
        guard job?.isRunning != true else { return }
        let job = Job(title: title)
        self.job = job
        let (lines, continuation) = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(Self.maxLines))
        let reader = Task { [weak self] in
            for await line in lines { self?.append(line, to: job.id) }
        }
        let run = run
        jobTask = Task { [weak self] in
            let result = await run(executable, arguments, environment) { continuation.yield($0) }
            continuation.finish()
            await reader.value
            guard let self, self.job?.id == job.id else { return }
            self.job?.result = result
            finish(result)
            onActivity?(
                Activity(
                    feature: .admin,
                    symbol: result.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                    title: result.cancelled ? "\(title) cancelled" : result.succeeded ? title : "\(title) failed",
                    duration: .seconds(2)))
        }
    }

    private func append(_ line: String, to id: Job.ID?) {
        guard let id, job?.id == id else { return }
        job?.lines.append(line)
        if let count = job?.lines.count, count > Self.maxLines { job?.lines.removeFirst(count - Self.maxLines) }
    }
}
