import Combine
import Foundation

/// 小梦主动 · 控制面板快照。
/// 配置即时读写。打分见 ActiveReachScore。不发通知。
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
        dailyCapCount: 0,
        dailyBreakCount: 0,
        countsDate: ""
    )
}

enum ActiveReachBounds {
    static let intervalMinutes = 15...240
    static let dailyCap = 0...20
    static let dailyBreakCap = 0...5
    static let quietTimeoutMinutes = 30...720
    static let dialogActiveHours = 1...168
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

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard, now: Date = Date()) {
        self.defaults = defaults
        var loaded = Self.load(from: defaults)
        ActiveReachLogic.clamp(&loaded)
        ActiveReachLogic.resetCountsIfNeeded(&loaded, now: now)
        snapshot = loaded
        decisions = ActiveReachWake.loadDecisions(from: defaults)
        drafts = ActiveReachScore.loadDrafts(from: defaults)
    }

    var isEnabled: Bool { ActiveReachLogic.isEnabled(snapshot) }
    /// 只看总闸。打分/发送还要过 `ActiveReachWake.canProceedToScore`。
    var shouldAllowWake: Bool { ActiveReachLogic.shouldAllowWake(snapshot) }

    /// 总闸关的瞬间清待发。本刀无队列，空实现占位；后续唤醒/通知必须接到这里。
    func cancelPending() {
        // Knife 1: no pending wake or notification queue yet.
    }

    /// 唤醒门闩。blocked 才落日志；allowed 交给 runReachCycle 写最终决策。
    @discardableResult
    func handleWake(source: String, now: Date = Date(), calendar: Calendar = .current) -> WakeDisposition {
        var snap = snapshot
        var log = decisions
        let disposition = ActiveReachWake.handleWake(
            snapshot: &snap,
            log: &log,
            source: source,
            now: now,
            calendar: calendar
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

    private static func load(from defaults: UserDefaults) -> ActiveReachSnapshot {
        guard let data = defaults.data(forKey: ActiveReachLogic.storageKey),
              let decoded = try? JSONDecoder().decode(ActiveReachSnapshot.self, from: data)
        else {
            return .default
        }
        return decoded
    }
}
