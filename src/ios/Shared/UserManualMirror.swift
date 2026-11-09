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

    /// Host URL the agent sees as /var/minis/shared/user-manual.md.
    static var mirroredURL: URL {
        AIChatViewModel.minisSharedPersistentDir.appendingPathComponent(fileName)
    }

    /// Linux path advertised to the agent.
    static let linuxPath = "/var/minis/shared/user-manual.md"

    // [T-manual-index] 手册索引进上下文。
    //
    // 病根（审计 P0-4）：手册 350 行只打包进 bundle、镜像到 shared，提示词
    // 从头到尾**没有一处提到这个路径**——"read it before answering" 那句在
    // 402 里已经不存在了。等于路标立在仓库里没挂到路上，AI 永远不知道有手册。
    //
    // 全文 350 行约 4300 token，每轮常驻太贵；索引 15 行约 400 token，常驻得起。
    // 索引和全文是**同一份文件的同一个块**（MANUAL-INDEX-BEGIN/END 之间），
    // 不是两处各写一遍——改手册时改一处，不会两边说法打架。
    private static let indexBeginMarker = "<!-- MANUAL-INDEX-BEGIN"
    private static let indexEndMarker = "MANUAL-INDEX-END -->"

    /// 手册索引块，连同"全文在哪、什么时候读"的一句指路。读不到返回 nil。
    ///
    /// 从 bundle 读而不是从 mirroredURL 读：镜像文件是给 shell 侧用的，
    /// 它可能被上一次运行的旧版本覆盖、也可能被 agent 改过；bundle 里的
    /// 才是这次构建的真相。
    nonisolated static func indexFragment() -> String? {
        guard let url = Bundle.main.url(forResource: "user-manual", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8),
              let begin = text.range(of: indexBeginMarker),
              let end = text.range(of: indexEndMarker, range: begin.upperBound..<text.endIndex)
        else { return nil }
        // 起止标记之间才是索引；标记本身连同它上面的说明注释一起丢掉。
        var body = String(text[begin.upperBound..<end.lowerBound])
        // 去掉标记行剩下的 "-->".
        if let arrow = body.range(of: "-->") {
            body = String(body[arrow.upperBound...])
        }
        body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        return """
        User manual (this app's own features — read a section with file_read before answering questions about what the app can do; do not guess):
        \(body)
        Full manual: \(linuxPath)
        """
    }

    /// Copy the bundled manual over the mirror when their contents differ.
    /// Cheap: both files are tens of KB; compare via data equality, skip the
    /// write when identical (keeps mtime stable so agent caches don't churn).
    static func syncFromBundle() {
        guard let bundleURL = Bundle.main.url(forResource: "user-manual", withExtension: "md"),
              let bundleData = try? Data(contentsOf: bundleURL) else {
            AppLogger(category: "ManualMirror").warning("manual mirror: bundle manual missing")
            return
        }
        let fm = FileManager.default
        let dest = mirroredURL
        do {
            try? fm.createDirectory(at: dest.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
            if let existing = try? Data(contentsOf: dest), existing == bundleData { return }
            try bundleData.write(to: dest, options: .atomic)
            AppLogger(category: "ManualMirror").info("manual mirror synced (\(bundleData.count) bytes → \(dest.path))")
        } catch {
            AppLogger(category: "ManualMirror").warning("manual mirror write failed: \(error.localizedDescription)")
        }
    }
}
