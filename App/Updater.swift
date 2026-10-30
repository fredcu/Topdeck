// SPDX-License-Identifier: MIT
import AppKit
import Observation

/// Keeps Topdeck current. A build made from a local checkout (`make run` or `make install`)
/// updates by rebuilding that checkout: `scripts/update.sh` fast-forwards main when that's safe,
/// builds, reinstalls into /Applications, and relaunches. Other builds open the releases page.
@MainActor
@Observable
final class Updater {
    enum State: Equatable {
        case idle
        case updating
        case failed
    }

    private(set) var state = State.idle

    /// The checkout this build came from, when it's still on this Mac.
    let sourceDirectory: URL?

    init() {
        let path = Bundle.main.object(forInfoDictionaryKey: "TopdeckSourceDirectory") as? String ?? ""
        let checkout = !path.isEmpty && FileManager.default.fileExists(atPath: path + "/scripts/update.sh")
        sourceDirectory = checkout ? URL(filePath: path, directoryHint: .isDirectory) : nil
    }

    /// "0.2.0", as releases are named.
    static var shortVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    /// "0.2.0 (c94187a)": the version and, for local builds, the commit it was built from ("+" when
    /// the checkout had uncommitted changes).
    static var version: String {
        guard let commit = Bundle.main.object(forInfoDictionaryKey: "TopdeckCommit") as? String, !commit.isEmpty
        else { return shortVersion }
        return "\(shortVersion) (\(commit))"
    }

    static let log = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appending(path: "Logs/Topdeck/update.log")

    /// Rebuilds from the local checkout. On success the new build quits this one and takes its place.
    func updateFromSource() {
        guard state != .updating, let sourceDirectory else { return }
        state = .updating
        try? FileManager.default.createDirectory(
            at: Self.log.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: Self.log.path, contents: nil)
        let process = Process()
        process.executableURL = URL(filePath: "/bin/bash")
        process.arguments = [sourceDirectory.appending(path: "scripts/update.sh").path]
        process.currentDirectoryURL = sourceDirectory
        // A file, not a pipe: the script outlives this app when the update succeeds.
        if let log = try? FileHandle(forWritingTo: Self.log) {
            process.standardOutput = log
            process.standardError = log
        }
        // A successful update quits this app before the script ends. If the script ends first, a
        // non-zero status means the pull or the build failed; the log says why.
        process.terminationHandler = { [weak self] ended in
            let succeeded = ended.terminationStatus == 0
            Task { @MainActor in self?.state = succeeded ? .idle : .failed }
        }
        do {
            try process.run()
        } catch {
            state = .failed
        }
    }

    func checkForUpdates() {
        openReleases()
    }

    func showLog() { NSWorkspace.shared.open(Self.log) }

    func openReleases() { NSWorkspace.shared.open(Links.releases) }
}
