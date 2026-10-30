// SPDX-License-Identifier: MIT

/// Waits until `condition` holds, checking every 20 ms, for at most `timeout`. Timing tests use it
/// instead of fixed sleeps, which flake on busy CI runners where tests share the main actor.
@MainActor
func eventually(within timeout: Duration = .seconds(30), _ condition: () -> Bool) async -> Bool {
    // Counts polls, not wall time: when another test holds the main actor past the deadline, a clock
    // would fail this at once, before the awaited main-actor work has had its turn.
    let polls = Int(timeout / .milliseconds(20))
    for _ in 0..<polls {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}
