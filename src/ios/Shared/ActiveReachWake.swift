import Foundation

/// 唤醒信号进来之后、调模型之前的门闩。
/// 本刀不打分、不发通知、不读会话原文。
enum WakeBlockReason: String, Equatable, Codable {
    /// 总闸关。优先级最高。
    case masterOff
    /// 她在前台。不调模型、不入草稿。手动发通知不走这条。
    case sheIsHere
    /// 未指定对话框。发送门；空列表不准进入打分/发送。
    case noDialogs
}

struct WakeContext: Equatable {
    var snapshot: ActiveReachSnapshot
    var source: String
    var now: Date
}

enum WakeDisposition: Equatable {
    case blocked(reason: WakeBlockReason)
    case allowed(context: WakeContext)
}

struct ActiveReachDecision: Equatable, Codable, Identifiable {
    var id: String
    var time: TimeInterval
    var source: String
    /// `"blocked"` / `"allowed"` / `"drafted"` / `"skipped"`
    var disposition: String
    var reason: String?
    var enabled: Bool
    var dialogCount: Int
    var capCount: Int
    var breakCount: Int
    var dialogId: String?
    var emotionScore: Int?
    var timeScore: Int?
    var totalScore: Int?
    var wouldBreak: Bool?
    var wouldConsumeCap: Bool?
    var pickNote: String?

    enum CodingKeys: String, CodingKey {
        case id, time, source, disposition, reason, enabled
        case dialogCount, capCount, breakCount
        case dialogId, emotionScore, timeScore, totalScore
        case wouldBreak, wouldConsumeCap, pickNote
    }
}

enum ActiveReachWake {
    static let decisionLogKey = "activeReach.decisions.v1"
    static let decisionLogLimit = 50

    /// 只看总闸。完整链路还要过 `canProceedToScore` / `canSend`。
    static func shouldAllowWake(_ snapshot: ActiveReachSnapshot) -> Bool {
        ActiveReachLogic.shouldAllowWake(snapshot)
    }

    /// 可否进入下一刀的打分。本刀：总闸开且对话框非空。
    static func canProceedToScore(_ snapshot: ActiveReachSnapshot) -> Bool {
        canSend(snapshot)
    }

    /// 发送门：总闸开，且指定对话框非空（空=不发，规格强制）。
    static func canSend(_ snapshot: ActiveReachSnapshot) -> Bool {
        snapshot.enabled && !snapshot.dialogIds.isEmpty
    }

    /// 假定计数已按 `now` 清过。不打分、不发。
    static func evaluate(
        snapshot: ActiveReachSnapshot,
        source: String,
        now: Date,
        sheIsHere: Bool = false
    ) -> WakeDisposition {
        if !shouldAllowWake(snapshot) {
            return .blocked(reason: .masterOff)
        }
        if sheIsHere {
            return .blocked(reason: .sheIsHere)
        }
        if snapshot.dialogIds.isEmpty {
            return .blocked(reason: .noDialogs)
        }
        return .allowed(context: WakeContext(snapshot: snapshot, source: source, now: now))
    }

    static func handleWake(
        snapshot: inout ActiveReachSnapshot,
        log: inout [ActiveReachDecision],
        source: String,
        now: Date,
        calendar: Calendar = .current,
        sheIsHere: Bool = false
    ) -> WakeDisposition {
        ActiveReachLogic.resetCountsIfNeeded(&snapshot, now: now, calendar: calendar)
        let disposition = evaluate(
            snapshot: snapshot, source: source, now: now, sheIsHere: sheIsHere)
        if case .blocked = disposition {
            let entry = ActiveReachDecision.make(
                disposition: disposition,
                snapshot: snapshot,
                source: source,
                now: now
            )
            log = prepend(entry, onto: log)
        }
        return disposition
    }

    static func prepend(
        _ entry: ActiveReachDecision,
        onto log: [ActiveReachDecision],
        limit: Int = decisionLogLimit
    ) -> [ActiveReachDecision] {
        Array(([entry] + log).prefix(limit))
    }

    static func loadDecisions(from defaults: UserDefaults) -> [ActiveReachDecision] {
        guard let data = defaults.data(forKey: decisionLogKey),
              let decoded = try? JSONDecoder().decode([ActiveReachDecision].self, from: data)
        else {
            return []
        }
        return decoded
    }

    static func encodeDecisions(_ items: [ActiveReachDecision]) -> Data? {
        try? JSONEncoder().encode(items)
    }
}

extension ActiveReachDecision {
    static func make(
        disposition: WakeDisposition,
        snapshot: ActiveReachSnapshot,
        source: String,
        now: Date
    ) -> ActiveReachDecision {
        let kind: String
        let reason: String?
        switch disposition {
        case .blocked(let block):
            kind = "blocked"
            reason = block.rawValue
        case .allowed:
            kind = "allowed"
            reason = nil
        }
        return ActiveReachDecision(
            id: UUID().uuidString,
            time: now.timeIntervalSince1970,
            source: source,
            disposition: kind,
            reason: reason,
            enabled: snapshot.enabled,
            dialogCount: snapshot.dialogIds.count,
            capCount: snapshot.dailyCapCount,
            breakCount: snapshot.dailyBreakCount,
            dialogId: nil,
            emotionScore: nil,
            timeScore: nil,
            totalScore: nil,
            wouldBreak: nil,
            wouldConsumeCap: nil,
            pickNote: nil
        )
    }

    static func fromCycle(
        _ cycle: ReachCycleResult,
        snapshot: ActiveReachSnapshot,
        source: String,
        now: Date
    ) -> ActiveReachDecision {
        ActiveReachDecision(
            id: UUID().uuidString,
            time: now.timeIntervalSince1970,
            source: source,
            disposition: cycle.disposition,
            reason: cycle.reason,
            enabled: snapshot.enabled,
            dialogCount: snapshot.dialogIds.count,
            capCount: snapshot.dailyCapCount,
            breakCount: snapshot.dailyBreakCount,
            dialogId: cycle.dialogId,
            emotionScore: cycle.emotionScore,
            timeScore: cycle.timeScore,
            totalScore: cycle.totalScore,
            wouldBreak: cycle.wouldBreak,
            wouldConsumeCap: cycle.wouldConsumeCap,
            pickNote: cycle.pickNote
        )
    }
}
