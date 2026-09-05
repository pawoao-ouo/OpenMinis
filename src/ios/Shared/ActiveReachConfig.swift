import Combine
import Foundation

/// 小梦主动 · 控制面板快照。
/// 配置即时读写。打分见 ActiveReachScore。发送见 ActiveReachSend。
///
/// 总闸语义：`enabled == false` 时，未来任何唤醒与待发都必须停。
/// 自然日以设备本地日历 0 点为界；跨日由 `ActiveReachLogic.resetCountsIfNeeded` 清零计数。
struct ActiveReachSnapshot: Equatable, Codable {
    var enabled: Bool
    var intervalMinutes: Int
    var dailyCap: Int
    var dailyBreakCap: Int
    /// 模型 entry id 或显示名。空=未配。本刀不调 API、不写死模型。
    var modelId: String
    /// 指定会话 ID。空=不发（规格强制）。
    var dialogIds: [String]
    var quietTimeoutMinutes: Int
    var dialogActiveHours: Int
    /// 想你的门槛。总分（情绪+时间）低于此不入草稿。旧存档缺字段当 60。
    var scoreThreshold: Int
    /// 当日已发条数（cap 内）。本刀只存。
    var dailyCapCount: Int
    /// 当日已破例条数。本刀只存。
    var dailyBreakCount: Int
    /// `yyyy-MM-dd`，本地自然日。空表示尚未记过。
    var countsDate: String

    static let `default` = ActiveReachSnapshot(
        enabled: false,
        intervalMinutes: 60,
        dailyCap: 3,
        dailyBreakCap: 1,
        modelId: "",
        dialogIds: [],
        quietTimeoutMinutes: 120,
        dialogActiveHours: 24,
        scoreThreshold: 60,
        dailyCapCount: 0,
        dailyBreakCount: 0,
        countsDate: ""
    )

    enum CodingKeys: String, CodingKey {
        case enabled, intervalMinutes, dailyCap, dailyBreakCap, modelId, dialogIds
        case quietTimeoutMinutes, dialogActiveHours, scoreThreshold
        case dailyCapCount, dailyBreakCount, countsDate
    }

    init(
        enabled: Bool,
        intervalMinutes: Int,
        dailyCap: Int,
        dailyBreakCap: Int,
        modelId: String,
        dialogIds: [String],
        quietTimeoutMinutes: Int,
        dialogActiveHours: Int,
        scoreThreshold: Int = 60,
        dailyCapCount: Int,
        dailyBreakCount: Int,
        countsDate: String
    ) {
        self.enabled = enabled
        self.intervalMinutes = intervalMinutes
        self.dailyCap = dailyCap
        self.dailyBreakCap = dailyBreakCap
        self.modelId = modelId
        self.dialogIds = dialogIds
        self.quietTimeoutMinutes = quietTimeoutMinutes
        self.dialogActiveHours = dialogActiveHours
        self.scoreThreshold = scoreThreshold
        self.dailyCapCount = dailyCapCount
        self.dailyBreakCount = dailyBreakCount
        self.countsDate = countsDate
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        intervalMinutes = try c.decode(Int.self, forKey: .intervalMinutes)
        dailyCap = try c.decode(Int.self, forKey: .dailyCap)
        dailyBreakCap = try c.decode(Int.self, forKey: .dailyBreakCap)
        modelId = try c.decode(String.self, forKey: .modelId)
        dialogIds = try c.decode([String].self, forKey: .dialogIds)
        quietTimeoutMinutes = try c.decode(Int.self, forKey: .quietTimeoutMinutes)
        dialogActiveHours = try c.decode(Int.self, forKey: .dialogActiveHours)
        scoreThreshold = try c.decodeIfPresent(Int.self, forKey: .scoreThreshold) ?? 60
        dailyCapCount = try c.decode(Int.self, forKey: .dailyCapCount)
        dailyBreakCount = try c.decode(Int.self, forKey: .dailyBreakCount)
        countsDate = try c.decode(String.self, forKey: .countsDate)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(intervalMinutes, forKey: .intervalMinutes)
        try c.encode(dailyCap, forKey: .dailyCap)
        try c.encode(dailyBreakCap, forKey: .dailyBreakCap)
        try c.encode(modelId, forKey: .modelId)
        try c.encode(dialogIds, forKey: .dialogIds)
        try c.encode(quietTimeoutMinutes, forKey: .quietTimeoutMinutes)
        try c.encode(dialogActiveHours, forKey: .dialogActiveHours)
        try c.encode(scoreThreshold, forKey: .scoreThreshold)
        try c.encode(dailyCapCount, forKey: .dailyCapCount)
        try c.encode(dailyBreakCount, forKey: .dailyBreakCount)
        try c.encode(countsDate, forKey: .countsDate)
    }
}

enum ActiveReachBounds {
    static let intervalMinutes = 15...240
    static let dailyCap = 0...20
    static let dailyBreakCap = 0...5
    static let quietTimeoutMinutes = 30...720
    static let dialogActiveHours = 1...168
    static let scoreThreshold = 20...200
}

enum ActiveReachLogic {
    static let storageKey = "activeReach.config.v1"

    static func dayStamp(now: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: now)
        let year = parts.year ?? 0
        let month = parts.month ?? 0
        let day = parts.day ?? 0
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    /// 跨本地自然日则清零 cap / 破例计数。同一天原样返回。
    static func resetCountsIfNeeded(
        _ snapshot: inout ActiveReachSnapshot,
        now: Date,
        calendar: Calendar = .current
    ) {
        let today = dayStamp(now: now, calendar: calendar)
        if snapshot.countsDate != today {
            snapshot.dailyCapCount = 0
            snapshot.dailyBreakCount = 0
            snapshot.countsDate = today
        }
    }

    static func clamp(_ snapshot: inout ActiveReachSnapshot) {
        snapshot.intervalMinutes = clampInt(
            snapshot.intervalMinutes, to: ActiveReachBounds.intervalMinutes)
        snapshot.dailyCap = clampInt(snapshot.dailyCap, to: ActiveReachBounds.dailyCap)
        snapshot.dailyBreakCap = clampInt(
            snapshot.dailyBreakCap, to: ActiveReachBounds.dailyBreakCap)
        snapshot.quietTimeoutMinutes = clampInt(
            snapshot.quietTimeoutMinutes, to: ActiveReachBounds.quietTimeoutMinutes)
        snapshot.dialogActiveHours = clampInt(
            snapshot.dialogActiveHours, to: ActiveReachBounds.dialogActiveHours)
        snapshot.scoreThreshold = clampInt(
            snapshot.scoreThreshold, to: ActiveReachBounds.scoreThreshold)
        snapshot.dailyCapCount = max(0, snapshot.dailyCapCount)
        snapshot.dailyBreakCount = max(0, snapshot.dailyBreakCount)
        snapshot.modelId = snapshot.modelId.trimmingCharacters(in: .whitespacesAndNewlines)
        snapshot.dialogIds = sanitizeDialogIds(snapshot.dialogIds)
    }

    static func sanitizeDialogIds(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in ids {
            let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, !seen.contains(id) else { continue }
            seen.insert(id)
            result.append(id)
        }
        return result
    }

    static func isEnabled(_ snapshot: ActiveReachSnapshot) -> Bool {
        snapshot.enabled
    }

    /// 只看总闸。完整链路必须再过 `ActiveReachWake.canProceedToScore` / `canSend`
    ///（指定对话框非空等）。关 → 任何唤醒与待发都停。
    static func shouldAllowWake(_ snapshot: ActiveReachSnapshot) -> Bool {
        snapshot.enabled
    }

    private static func clampInt(_ value: Int, to range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

/// 进程内即时读的配置门面。改完立刻写入 UserDefaults。
@MainActor
final class ActiveReachStore: ObservableObject {
    static let shared = ActiveReachStore()

    @Published private(set) var snapshot: ActiveReachSnapshot
    @Published private(set) var decisions: [ActiveReachDecision]
    @Published private(set) var drafts: [ActiveReachDraft]
    @Published private(set) var sent: [ActiveReachDraft]
    @Published var lastSendError: String?
    @Published private(set) var lastWakeAttemptAt: Date?
    @Published private(set) var lastWakeSource: String
    @Published private(set) var lastKeepAliveAt: Date?

    private let defaults: UserDefaults
    private var keepAliveTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard, now: Date = Date()) {
        self.defaults = defaults
        var loaded = Self.load(from: defaults)
        ActiveReachLogic.clamp(&loaded)
        ActiveReachLogic.resetCountsIfNeeded(&loaded, now: now)
        snapshot = loaded
        decisions = ActiveReachWake.loadDecisions(from: defaults)
        drafts = ActiveReachScore.loadDrafts(from: defaults)
        sent = ActiveReachSend.loadSent(from: defaults)
        let attempt = defaults.double(forKey: ActiveReachKeepAlive.lastAttemptAtKey)
        lastWakeAttemptAt = attempt > 0 ? Date(timeIntervalSince1970: attempt) : nil
        lastWakeSource = defaults.string(forKey: ActiveReachKeepAlive.lastSourceKey) ?? ""
        let ka = defaults.double(forKey: ActiveReachKeepAlive.lastKeepAliveAtKey)
        lastKeepAliveAt = ka > 0 ? Date(timeIntervalSince1970: ka) : nil
    }

    var isEnabled: Bool { ActiveReachLogic.isEnabled(snapshot) }
    /// 只看总闸。打分/发送还要过 `ActiveReachWake.canProceedToScore`。
    var shouldAllowWake: Bool { ActiveReachLogic.shouldAllowWake(snapshot) }

    /// 总闸关：取消本功能已排/已送达通知，并清草稿。
    func cancelPending() {
        ActiveReachSend.cancelOurs()
        discardAllDrafts()
    }

    /// 唤醒门闩。blocked 才落日志；allowed 交给 runReachCycle 写最终决策。
    @discardableResult
    func handleWake(source: String, now: Date = Date(), calendar: Calendar = .current) -> WakeDisposition {
        noteWakeAttempt(source: source, now: now)
        var snap = snapshot
        var log = decisions
        let disposition = ActiveReachWake.handleWake(
            snapshot: &snap,
            log: &log,
            source: source,
            now: now,
            calendar: calendar,
            sheIsHere: ActiveReachPresence.shared.shouldBlockScoring
        )
        snapshot = snap
        decisions = log
        persist()
        persistDecisions()
        return disposition
    }

    /// 门闩 + 打分。不发通知。草稿入队，cap 不预占。
    @discardableResult
    func runReachCycle(
        source: String,
        now: Date = Date(),
        calendar: Calendar = .current,
        sessions: ActiveReachSessionReading = ChatStoreReachReading(),
        model: ActiveReachModelCalling = ModelUseReachCaller(),
        memorySnippet: String? = nil
    ) async -> ReachCycleResult? {
        let wake = handleWake(source: source, now: now, calendar: calendar)
        guard case .allowed = wake else { return nil }
        let memory = memorySnippet ?? ActiveReachMemorySnippet.load(now: now)
        let cycle = await ActiveReachScore.run(
            snapshot: snapshot,
            source: source,
            now: now,
            memorySnippet: memory,
            sessions: sessions,
            model: model
        )
        let entry = ActiveReachDecision.fromCycle(
            cycle, snapshot: snapshot, source: source, now: now)
        decisions = ActiveReachWake.prepend(entry, onto: decisions)
        if let draft = cycle.draft {
            drafts = ActiveReachScore.prependDraft(draft, onto: drafts)
        }
        persistDecisions()
        persistDrafts()
        return cycle
    }

    func discardAllDrafts() {
        drafts = []
        persistDrafts()
    }

    /// 设置页点测。只打分入草稿，不发通知。
    func runNow() async {
        _ = await runReachCycle(source: "manual")
    }

    /// 保活心跳调用。总闸关 / 未到点 / 一小时内已补过 → 不跑。
    func considerKeepAlive(now: Date = Date()) {
        guard ActiveReachKeepAlive.shouldKeepAlive(
            enabled: snapshot.enabled,
            intervalMinutes: snapshot.intervalMinutes,
            lastAttemptAt: lastWakeAttemptAt,
            lastKeepAliveAt: lastKeepAliveAt,
            now: now,
            isPresent: ActiveReachPresence.shared.shouldBlockScoring
        ) else { return }
        lastKeepAliveAt = now
        defaults.set(now.timeIntervalSince1970, forKey: ActiveReachKeepAlive.lastKeepAliveAtKey)
        guard keepAliveTask == nil else { return }
        keepAliveTask = Task { [weak self] in
            _ = await self?.runReachCycle(source: "keepalive", now: now)
            await MainActor.run { self?.keepAliveTask = nil }
        }
    }

    private func noteWakeAttempt(source: String, now: Date) {
        lastWakeAttemptAt = now
        lastWakeSource = source
        defaults.set(now.timeIntervalSince1970, forKey: ActiveReachKeepAlive.lastAttemptAtKey)
        defaults.set(source, forKey: ActiveReachKeepAlive.lastSourceKey)
    }

    @discardableResult
    func sendDraft(
        id: String,
        now: Date = Date(),
        calendar: Calendar = .current,
        scheduler: ((ActiveReachDraft) async -> Result<String, ActiveReachSendError>)? = nil
    ) async -> Result<SendReceipt, ActiveReachSendError> {
        lastSendError = nil
        guard let draft = drafts.first(where: { $0.id == id }) else {
            lastSendError = ActiveReachSendError.missingDraft.rawValue
            return .failure(.missingDraft)
        }
        var snap = snapshot
        let prepared = ActiveReachSend.prepareSend(
            draft: draft, snapshot: &snap, now: now, calendar: calendar)
        snapshot = snap
        persist()
        switch prepared {
        case .failure(let err):
            lastSendError = err.rawValue
            logSend(disposition: "blocked", reason: err.rawValue, draft: draft, now: now)
            return .failure(err)
        case .success(let usedBreak):
            let schedule = scheduler ?? ActiveReachSend.schedule
            let scheduled = await schedule(draft)
            switch scheduled {
            case .failure(let err):
                lastSendError = err.rawValue
                logSend(disposition: "blocked", reason: err.rawValue, draft: draft, now: now)
                return .failure(err)
            case .success(let nid):
                ActiveReachSend.applyCount(usedBreak: usedBreak, snapshot: &snap)
                snapshot = snap
                drafts.removeAll { $0.id == id }
                sent = ActiveReachSend.prependSent(draft, onto: sent)
                persist()
                persistDrafts()
                persistSent()
                // 第一原则：通知里的话必须落进对话，点开才能认领「我说的」。
                await ActiveReachSend.persistAssistantBubble(
                    sessionId: draft.dialogId, text: draft.text)
                logSend(
                    disposition: "sent",
                    reason: usedBreak ? "break" : "cap",
                    draft: draft,
                    now: now
                )
                return .success(SendReceipt(
                    notificationId: nid,
                    dialogId: draft.dialogId,
                    usedBreak: usedBreak,
                    openFallback: false
                ))
            }
        }
    }

    @discardableResult
    func sendAllPending(
        limit: Int = 20,
        now: Date = Date(),
        calendar: Calendar = .current
    ) async -> [Result<SendReceipt, ActiveReachSendError>] {
        let ids = Array(drafts.prefix(limit).map(\.id))
        var results: [Result<SendReceipt, ActiveReachSendError>] = []
        for id in ids {
            results.append(await sendDraft(id: id, now: now, calendar: calendar))
        }
        return results
    }

    private func logSend(
        disposition: String,
        reason: String?,
        draft: ActiveReachDraft,
        now: Date
    ) {
        let entry = ActiveReachDecision(
            id: UUID().uuidString,
            time: now.timeIntervalSince1970,
            source: draft.source,
            disposition: disposition,
            reason: reason,
            enabled: snapshot.enabled,
            dialogCount: snapshot.dialogIds.count,
            capCount: snapshot.dailyCapCount,
            breakCount: snapshot.dailyBreakCount,
            dialogId: draft.dialogId,
            emotionScore: draft.emotion,
            timeScore: draft.timeScore,
            totalScore: draft.total,
            wouldBreak: draft.wouldBreak,
            wouldConsumeCap: !draft.wouldBreak,
            pickNote: nil
        )
        decisions = ActiveReachWake.prepend(entry, onto: decisions)
        persistDecisions()
    }

    func setEnabled(_ value: Bool) {
        mutate { snap in
            snap.enabled = value
            if !value {
                // 紧急停止：破例计数清零。cap 计数仍按自然日走。
                snap.dailyBreakCount = 0
            }
        }
        if !value {
            cancelPending()
            // 关闸世界安静：待发草稿也清，避免重开后手滑发出旧句。
            discardAllDrafts()
        }
    }

    func setIntervalMinutes(_ value: Int) {
        mutate { $0.intervalMinutes = value }
    }

    func setDailyCap(_ value: Int) {
        mutate { $0.dailyCap = value }
    }

    func setDailyBreakCap(_ value: Int) {
        mutate { $0.dailyBreakCap = value }
    }

    func setModelId(_ value: String) {
        mutate { $0.modelId = value }
    }

    func setQuietTimeoutMinutes(_ value: Int) {
        mutate { $0.quietTimeoutMinutes = value }
    }

    func setDialogActiveHours(_ value: Int) {
        mutate { $0.dialogActiveHours = value }
    }

    func setScoreThreshold(_ value: Int) {
        mutate { $0.scoreThreshold = value }
    }

    func setDialogSelected(_ id: String, selected: Bool) {
        mutate { snap in
            if selected {
                if !snap.dialogIds.contains(id) { snap.dialogIds.append(id) }
            } else {
                snap.dialogIds.removeAll { $0 == id }
            }
        }
    }

    func addDialogId(_ raw: String) {
        mutate { snap in
            snap.dialogIds.append(raw)
        }
    }

    func removeDialogId(_ id: String) {
        mutate { snap in
            snap.dialogIds.removeAll { $0 == id }
        }
    }

    func resetCountsIfNeeded(now: Date = Date()) {
        mutate { snap in
            ActiveReachLogic.resetCountsIfNeeded(&snap, now: now)
        }
    }

    private func mutate(_ body: (inout ActiveReachSnapshot) -> Void) {
        var next = snapshot
        body(&next)
        ActiveReachLogic.clamp(&next)
        snapshot = next
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: ActiveReachLogic.storageKey)
        }
    }

    private func persistDecisions() {
        if let data = ActiveReachWake.encodeDecisions(decisions) {
            defaults.set(data, forKey: ActiveReachWake.decisionLogKey)
        }
    }

    private func persistDrafts() {
        if let data = ActiveReachScore.encodeDrafts(drafts) {
            defaults.set(data, forKey: ActiveReachScore.draftKey)
        }
    }

    private func persistSent() {
        if let data = ActiveReachSend.encodeSent(sent) {
            defaults.set(data, forKey: ActiveReachSend.sentKey)
        }
    }

    private static func load(from defaults: UserDefaults) -> ActiveReachSnapshot {
        guard let data = defaults.data(forKey: ActiveReachLogic.storageKey),
              let decoded = try? JSONDecoder().decode(ActiveReachSnapshot.self, from: data)
        else {
            return .default
        }
        return decoded
    }
}
