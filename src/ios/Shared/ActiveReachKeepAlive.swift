import Foundation

/// 小梦主动 · 保活兜底（第五刀）。
/// 主触发仍是 Shortcuts 定时。这里只在保活心跳里补漏。
/// 阈值：`max(intervalMinutes, 120)`。同一小时 keepalive 最多一次。总闸关不跑。
enum ActiveReachKeepAlive {
    static let floorMinutes = 120
    static let lastAttemptAtKey = "activeReach.lastWakeAttemptAt"
    static let lastSourceKey = "activeReach.lastWakeSource"
    static let lastKeepAliveAtKey = "activeReach.lastKeepAliveAt"

    static func thresholdMinutes(intervalMinutes: Int) -> Int {
        max(intervalMinutes, floorMinutes)
    }

    /// keepalive 是否该补一轮。不改状态。
    static func shouldKeepAlive(
        enabled: Bool,
        intervalMinutes: Int,
        lastAttemptAt: Date?,
        lastKeepAliveAt: Date?,
        now: Date
    ) -> Bool {
        guard enabled else { return false }
        let gap = TimeInterval(thresholdMinutes(intervalMinutes: intervalMinutes) * 60)
        if let last = lastAttemptAt, now.timeIntervalSince(last) < gap {
            return false
        }
        if let ka = lastKeepAliveAt, now.timeIntervalSince(ka) < 3600 {
            return false
        }
        return true
    }
}
