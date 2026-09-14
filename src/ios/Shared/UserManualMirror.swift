import Foundation

// MARK: - User-manual mirror for the agent
//
// [T-manual-agent-visibility 09-12] 醒醒 3：「使用手册是给 ai 看的不是给醒醒看的。
// 如果 ai 可以看见那就没问题。」Applying manual renders from Bundle.main — but
// the agent's file tools ONLY see /var/minis/** (the shell rootfs has no view of
// the app bundle), so the in-bundle manual was invisible to the agent.
//
// Fix: mirror the bundled user-manual.md into the SHARED app-group dir at launch
// (host side: MinisAppGroupRoot/shared/user-manual.md ⇔ iSH side:
// /var/minis/shared/user-manual.md). The mirror is refreshed on every launch,
// so a bundle update re-publishes itself; an agent edit to the mirrored file
// survives until the next launch re-syncs (documented in the system prompt
// pointer so the agent knows the bundle copy is authoritative).

enum UserManualMirror {
    private static let fileName = "user-manual.md"
    /// [T-agent-prompt-claude-code 09-14] The detailed agent operating manual
    /// (extracted from the old inlined `baseSystemPrompt` long text). The thin
    /// system prompt points here; the agent file_read's sections on demand —
    /// Claude Code style progressive disclosure. Same mirror mechanism as the
    /// user manual: bundle copy is authoritative, refreshed every launch.
    private static let agentManualFileName = "agent-manual.md"

    /// Host URL the agent sees as /var/minis/shared/user-manual.md.
    static var mirroredURL: URL {
        AIChatViewModel.minisSharedPersistentDir.appendingPathComponent(fileName)
    }

    /// Linux path advertised to the agent.
    static let linuxPath = "/var/minis/shared/user-manual.md"

    /// Linux path of the agent operating manual mirror.
    static let agentManualLinuxPath = "/var/minis/shared/agent-manual.md"

    /// Host URL the agent sees as /var/minis/shared/agent-manual.md.
    static var agentManualMirroredURL: URL {
        AIChatViewModel.minisSharedPersistentDir.appendingPathComponent(agentManualFileName)
    }

    /// Copy the bundled manual over the mirror when their contents differ.
    /// Cheap: both files are tens of KB; compare via data equality, skip the
    /// write when identical (keeps mtime stable so agent caches don't churn).
    static func syncFromBundle() {
        syncOne(resource: "user-manual", dest: mirroredURL)
        syncOne(resource: "agent-manual", dest: agentManualMirroredURL)
    }

    /// [T-manual-mirror-dest-fallback 09-14] Guarantee the agent manual mirror
    /// exists, repairing it on the spot if it does not. The system prompt
    /// advertises `agentManualLinuxPath`, so if the app was updated (or killed
    /// before the launch sync completed) and the mirror is missing, the model
    /// would file_read a 404 with no way to recover. Called from the system
    /// prompt composer: the `fileExists` probe is cheap and the sync only runs
    /// in the missing case, so a normal turn pays nothing.
    static func ensureAgentManualMirror() {
        guard !FileManager.default.fileExists(atPath: agentManualMirroredURL.path) else { return }
        AppLogger(category: "ManualMirror").info("agent manual mirror absent at prompt-build time — re-syncing from bundle")
        syncOne(resource: "agent-manual", dest: agentManualMirroredURL)
    }

    /// Shared body of the bundle→mirror sync for one markdown resource.
    /// [T-manual-mirror-dest-fallback 09-14] The system prompt advertises the
    /// mirror path, so the mirror must exist whenever the bundle copy does:
    /// a bundle-missing case logs a warning, but a MISSING DEST with a present
    /// bundle is always repaired here (that is the only reason the pointer in
    /// the prompt can be trusted), and a dest that is still absent after the
    /// write is logged as an error instead of failing silently.
    private static func syncOne(resource: String, dest: URL) {
        let fm = FileManager.default
        let destExists = fm.fileExists(atPath: dest.path)
        guard let bundleURL = Bundle.main.url(forResource: resource, withExtension: "md"),
              let bundleData = try? Data(contentsOf: bundleURL) else {
            if !destExists {
                AppLogger(category: "ManualMirror").error("manual mirror: bundle \(resource).md missing AND no existing mirror at \(dest.path) — the prompt pointer is dangling until the next launch")
            } else {
                AppLogger(category: "ManualMirror").warning("manual mirror: bundle \(resource).md missing — keeping existing mirror")
            }
            return
        }
        do {
            try? fm.createDirectory(at: dest.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
            // Re-read after the directory step: a first-launch dest is absent
            // here, and that is exactly the case this fallback exists for.
            if let existing = try? Data(contentsOf: dest), existing == bundleData { return }
            try bundleData.write(to: dest, options: .atomic)
            AppLogger(category: "ManualMirror").info("manual mirror synced \(resource) (\(bundleData.count) bytes → \(dest.path))")
        } catch {
            AppLogger(category: "ManualMirror").warning("manual mirror write failed (\(resource)): \(error.localizedDescription)")
        }
        if !fm.fileExists(atPath: dest.path) {
            AppLogger(category: "ManualMirror").error("manual mirror \(resource).md still absent after write attempt: \(dest.path)")
        }
    }
}
