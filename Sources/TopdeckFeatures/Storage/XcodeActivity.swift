// SPDX-License-Identifier: MIT
import Darwin

/// Whether Xcode or a command-line build is running, from the names of this Mac's processes. While
/// one is, Storage moves nothing of Xcode's to the Trash.
public enum XcodeActivity {
    /// Xcode itself, `xcodebuild`, and the build service either one starts.
    static let processNames: Set<String> = ["Xcode", "xcodebuild", "XCBBuildService"]

    public static func isBusy(running names: some Sequence<String>) -> Bool {
        names.contains { processNames.contains($0) }
    }

    /// True when a process list can't be read, too: not knowing counts as busy.
    public static func isBusy() -> Bool {
        guard let names = runningProcessNames() else { return true }
        return isBusy(running: names)
    }

    /// Every process's short name, as `ps -c` shows it; nil when the list can't be read.
    static func runningProcessNames() -> [String]? {
        let expected = proc_listallpids(nil, 0)
        guard expected > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(expected) + 64)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard count > 0 else { return nil }
        return pids.prefix(Int(count)).compactMap { pid in
            var name = [CChar](repeating: 0, count: 64)
            guard proc_name(pid, &name, UInt32(name.count)) > 0 else { return nil }
            return String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
    }
}
