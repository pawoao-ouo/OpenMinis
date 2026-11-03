//
//  ThemeBridgeCall.swift
//  MinisApp
//
//  [H-02 / H-06] One wait-or-cancel contract for the `minis-theme` CLI
//  bridge.
//
//  Every theme command used to open-code the same pattern: spawn a
//  MainActor Task, then block the calling thread on a 5s semaphore. When
//  the semaphore timed out the CLI reported failure — but the Task was
//  still queued, so it could run afterwards and write the very change
//  the CLI had just reported as failed. "Reported failure, actually
//  changed" is worse than a slow command: the AI retries, and the retry
//  lands on top of whatever the user did in between.
//
//  This helper keeps the shape (the native offload handler is a
//  synchronous C function, so the caller must block) but adds a token:
//  on timeout the token is cancelled, and every mutation checks
//  `beginWrite()` right before touching storage. A late Task therefore
//  does nothing instead of writing.
//

import Foundation

/// Cooperative cancellation for one CLI call.
///
/// The timeout fires on the blocked caller thread while the work runs on
/// the main actor, so the flag is lock-protected rather than an isolated
/// var.
final class ThemeBridgeCallToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    /// Checked immediately before a storage mutation.
    ///
    /// Returns false once the caller has timed out. This closes the
    /// "timeout then late write" window down to the microseconds between
    /// this check and the first write; it cannot undo a write that had
    /// already started, which is why the check sits at the top of each
    /// mutating block rather than around the whole body.
    func beginWrite() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !cancelled
    }
}

enum ThemeBridgeCall {

    /// Runs `work` on the main actor and blocks until it finishes or
    /// `timeout` elapses.
    ///
    /// - Parameter timeout: 5s for reads and instantaneous writes; a
    ///   destructive command that waits for a confirmation sheet passes a
    ///   window wider than the confirmation gate's own timeout.
    static func run(timeout: TimeInterval = 5,
                    _ work: @escaping @MainActor (ThemeBridgeCallToken) async -> [String: Any]) -> NSDictionary {
        let sem = DispatchSemaphore(value: 0)
        let token = ThemeBridgeCallToken()
        var result: [String: Any] = [:]
        Task { @MainActor in
            // Already timed out before this Task got a turn: do nothing at
            // all. No signal() either — the waiter is long gone and
            // bumping an abandoned semaphore would only leak a count.
            guard !token.isCancelled else { return }
            result = await work(token)
            sem.signal()
        }
        if sem.wait(timeout: .now() + timeout) == .timedOut {
            token.cancel()
            NSLog("[CLIBridge] theme call timed out after \(Int(timeout))s - cancelled, no write will follow")
            return [
                "ok": false,
                "error": "timeout",
                "message": "The appearance system did not answer within \(Int(timeout))s. This call was cancelled; it will not write anything later.",
            ] as NSDictionary
        }
        return result as NSDictionary
    }

    /// The standard answer when a confirmation did not come back approved.
    /// Returned as data (not thrown) so the ObjC layer reports it through
    /// the same envelope as every other failure.
    static func declined(_ reason: String, action: String) -> [String: Any] {
        switch reason {
        case "rejected":
            return [
                "ok": false,
                "error": "rejected",
                "message": "The user declined this theme change (\(action)); nothing was changed.",
            ]
        default:
            return [
                "ok": false,
                "error": "confirmation_timeout",
                "message": "No confirmation for \(action) within the wait window; nothing was changed.",
            ]
        }
    }
}