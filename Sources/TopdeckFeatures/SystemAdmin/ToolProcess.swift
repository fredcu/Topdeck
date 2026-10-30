// SPDX-License-Identifier: MIT
import Darwin
import Foundation
import os

/// Runs a command-line tool for System Admin: an argument array, never a shell string; standard input
/// from /dev/null, so a tool that would ask (sudo, say) fails instead of waiting; and its own process
/// group, so cancelling stops the tool and everything it started. Cancel by cancelling the calling
/// task.
public enum ToolProcess {
    public struct Result: Sendable, Equatable {
        public var status: Int32
        /// Standard output, plus standard error when `mergesErrors` is on.
        public var output: String
        public var cancelled: Bool

        public init(status: Int32, output: String, cancelled: Bool = false) {
            self.status = status
            self.output = output
            self.cancelled = cancelled
        }

        public var succeeded: Bool { status == 0 && !cancelled }
    }

    /// How long a cancelled tool gets to stop after SIGTERM before it's killed.
    static let killDelay: DispatchTimeInterval = .seconds(3)

    /// Runs `executable` to completion. `onLine` gets each line of output as it arrives, on a
    /// background queue; a carriage return (a progress bar) ends a line too.
    public static func run(
        _ executable: String, _ arguments: [String], environment: [String: String]? = nil,
        mergesErrors: Bool = false, onLine: (@Sendable (String) -> Void)? = nil
    ) async -> Result {
        let group = ProcessGroup()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let result = runBlocking(
                        executable, arguments, environment: environment ?? ProcessInfo.processInfo.environment,
                        mergesErrors: mergesErrors, group: group, onLine: onLine)
                    continuation.resume(returning: result)
                }
            }
        } onCancel: {
            group.cancel()
        }
    }

    private static func runBlocking(
        _ executable: String, _ arguments: [String], environment: [String: String], mergesErrors: Bool,
        group: ProcessGroup, onLine: (@Sendable (String) -> Void)?
    ) -> Result {
        var pipe: [Int32] = [-1, -1]
        guard Darwin.pipe(&pipe) == 0 else { return Result(status: -1, output: "") }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, pipe[1], STDOUT_FILENO)
        if mergesErrors {
            posix_spawn_file_actions_adddup2(&actions, pipe[1], STDERR_FILENO)
        } else {
            posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)
        }
        posix_spawn_file_actions_addclose(&actions, pipe[0])
        posix_spawn_file_actions_addclose(&actions, pipe[1])
        // Its own process group, led by the tool, so killpg reaches whatever it starts.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)

        var pid: pid_t = 0
        let argv = [executable] + arguments
        let env = environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        let spawned = withCStrings(argv) { argv in
            withCStrings(env) { env in posix_spawn(&pid, executable, &actions, &attributes, argv, env) }
        }
        close(pipe[1])
        guard spawned == 0 else {
            close(pipe[0])
            return Result(status: -1, output: "")
        }
        group.started(pid)

        var output = Data()
        var line = Data()
        let size = 16_384
        var buffer = [UInt8](repeating: 0, count: size)
        while true {
            let count = read(pipe[0], &buffer, size)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            output.append(buffer, count: count)
            guard let onLine else { continue }
            for byte in buffer[..<count] {
                if byte == 0x0A || byte == 0x0D {
                    if !line.isEmpty { onLine(String(decoding: line, as: UTF8.self)) }
                    line.removeAll(keepingCapacity: true)
                } else {
                    line.append(byte)
                }
            }
        }
        if let onLine, !line.isEmpty { onLine(String(decoding: line, as: UTF8.self)) }
        close(pipe[0])

        // Wait for the tool to exit but leave it unreaped while cancel is shut off, then reap it.
        var info = siginfo_t()
        while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) < 0, errno == EINTR {}
        let cancelled = group.finished()
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0, errno == EINTR {}
        return Result(status: exitCode(status), output: String(decoding: output, as: UTF8.self), cancelled: cancelled)
    }

    /// A wait status as a shell reports it: the exit code, or 128 plus the signal that ended it.
    static func exitCode(_ status: Int32) -> Int32 {
        let signal = status & 0x7f
        return signal == 0 ? (status >> 8) & 0xff : 128 + signal
    }

    private static func withCStrings<R>(
        _ strings: [String], _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> R
    ) -> R {
        var pointers = strings.map { strdup($0) } + [nil]
        defer { for pointer in pointers { free(pointer) } }
        return pointers.withUnsafeMutableBufferPointer { body($0.baseAddress!) }
    }
}

/// The running tool's process group, shared between the thread that waits for it and a cancel that
/// can come at any moment: before it starts, while it runs, or after it's gone.
private final class ProcessGroup: Sendable {
    private struct State {
        var pid: pid_t?
        var cancelled = false
        var finished = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    func started(_ pid: pid_t) {
        let cancelled = state.withLock { state in
            state.pid = pid
            return state.cancelled
        }
        if cancelled { cancel() }
    }

    /// Asks the group to stop, then kills what's left. Signals go out under the lock and only while
    /// the tool is unreaped, so its group ID can't have passed to another process yet.
    func cancel() {
        let pid = state.withLock { state -> pid_t? in
            state.cancelled = true
            guard let pid = state.pid, !state.finished else { return nil }
            killpg(pid, SIGTERM)
            return pid
        }
        guard pid != nil else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + ToolProcess.killDelay) { [self] in
            state.withLock { state in
                guard let pid = state.pid, !state.finished else { return }
                killpg(pid, SIGKILL)
            }
        }
    }

    /// Called once the tool has exited, before it's reaped. Returns whether it was cancelled.
    func finished() -> Bool {
        state.withLock { state in
            state.finished = true
            return state.cancelled
        }
    }
}
