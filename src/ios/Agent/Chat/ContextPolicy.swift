import Foundation

/// Determines offload / compact / exhausted thresholds based on model context window size.
///
/// Tiers:
/// - **< 32K**: No auto-offload, no auto-compact. Prompt "start new / clear" when full.
/// - **32K–64K**: Auto-offload when remaining ≤ 10K. No auto-compact (user can manually).
///   Prompt "start new / clear" when exhausted.
/// - **64K–128K**: Auto-offload when remaining ≤ 20K. Auto-compact when remaining ≤ 10K.
/// - **≥ 128K**: Auto-offload when remaining ≤ 40K. Auto-compact when remaining ≤ 20K.
struct ContextPolicy {
    /// Tokens used must exceed this to trigger auto-offload. 0 = offload disabled.
    let offloadThreshold: Int
    /// Target token count after offloading. 0 = offload everything eligible.
    let offloadTarget: Int
    /// Tokens used must exceed this to trigger auto-compact. 0 = auto-compact disabled.
    let compactThreshold: Int
    /// When true, reaching the limit shows "start new session / clear" instead of compact.
    let exhaustedOnly: Bool
    /// Whether user-initiated manual compact is allowed.
    let manualCompactAllowed: Bool

    /// [T-user-cap] 用户给分组设的上下文上限，和模型原生窗口是两回事。
    ///
    /// 阈值那套固定减法（10K/20K/40K）和"64K 以下不自动压缩"是为**小模型**
    /// 设计的——它真没钱跑一次压缩调用，也塞不下摘要加热身轮。但用户把 1M
    /// 的模型手动限制到 32K 时，这些理由一条都不成立：模型有的是地方跑压缩，
    /// "我要这组不超过 32K"本身就是**要求压缩**，不是不要压缩的理由。
    ///
    /// 所以用户设的上限走百分比：70% offload、85% compact、压完回到 55%。
    /// 百分比（而不是固定减法）在 32K…1M 整条滑杆上都合理——32K 减 20K 会
    /// 掉到地板以下，1M 减 20K 等于没减。
    init(contextWindow: Int, isUserCap: Bool = false) {
        if isUserCap {
            offloadThreshold = Int(Double(contextWindow) * 0.70)
            offloadTarget = Int(Double(contextWindow) * 0.55)
            compactThreshold = Int(Double(contextWindow) * 0.85)
            exhaustedOnly = false
            manualCompactAllowed = true
            return
        }
        if contextWindow < 32_000 {
            // < 32K: no offload, no compact
            offloadThreshold = 0
            offloadTarget = 0
            compactThreshold = 0
            exhaustedOnly = true
            manualCompactAllowed = false
        } else if contextWindow < 64_000 {
            // 32K–64K: offload when remaining ≤ 10K, no auto-compact
            offloadThreshold = contextWindow - 10_000
            offloadTarget = contextWindow - 15_000
            compactThreshold = 0
            exhaustedOnly = true
            manualCompactAllowed = true
        } else if contextWindow < 128_000 {
            // 64K–128K: offload when remaining ≤ 20K, compact when remaining ≤ 10K
            offloadThreshold = contextWindow - 20_000
            offloadTarget = contextWindow - 30_000
            compactThreshold = contextWindow - 10_000
            exhaustedOnly = false
            manualCompactAllowed = true
        } else {
            // ≥ 128K: offload when remaining ≤ 40K, compact when remaining ≤ 20K
            offloadThreshold = contextWindow - 40_000
            offloadTarget = contextWindow - 60_000
            compactThreshold = contextWindow - 20_000
            exhaustedOnly = false
            manualCompactAllowed = true
        }
    }

    // MARK: - Pre-send Check

    /// Pre-send context check result.
    enum CheckResult {
        /// Context is fine, proceed normally.
        case ok
        /// Context is near capacity — auto-compact before sending.
        case needsCompact
        /// Context is exhausted — prompt user to start new session or clear chat.
        case exhausted
    }

    /// Evaluate current token usage against policy thresholds.
    func check(estimatedTokens: Int, contextWindow: Int) -> CheckResult {
        // Check compact threshold first (only for tiers that support auto-compact)
        if compactThreshold > 0, estimatedTokens >= compactThreshold {
            return .needsCompact
        }

        // For tiers where auto-compact is disabled, check if context is exhausted
        if exhaustedOnly {
            let exhaustedThreshold = offloadThreshold > 0
                ? offloadThreshold
                : Int(Double(contextWindow) * 0.90)
            if estimatedTokens >= exhaustedThreshold {
                return .exhausted
            }
        }

        return .ok
    }

    /// Whether auto-offload should trigger at the given token count.
    func shouldOffload(estimatedTokens: Int) -> Bool {
        offloadThreshold > 0 && estimatedTokens >= offloadThreshold
    }

}
