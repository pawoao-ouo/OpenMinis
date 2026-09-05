import Foundation
import UIKit

/// 小梦主动 · 在场。前台立刻 true，进后台立刻 false。
/// 不靠 30 分钟时间戳。调试开关默认关：在场仍拦打分。
@MainActor
final class ActiveReachPresence: ObservableObject {
    static let shared = ActiveReachPresence()
    static let debugKey = "activeReach.debugRunWhilePresent"

    @Published private(set) var isPresent: Bool
    @Published private(set) var lastPresentAt: Date?
    @Published private(set) var lastAbsentAt: Date?
    @Published var debugRunWhilePresent: Bool {
        didSet { UserDefaults.standard.set(debugRunWhilePresent, forKey: Self.debugKey) }
    }

    init(defaults: UserDefaults = .standard, now: Date = Date()) {
        debugRunWhilePresent = defaults.bool(forKey: Self.debugKey)
        let state = UIApplication.shared.applicationState
        isPresent = (state == .active)
        if isPresent {
            lastPresentAt = now
        }
    }

    func setPresent(_ present: Bool, now: Date = Date()) {
        if isPresent == present { return }
        isPresent = present
        if present {
            lastPresentAt = now
        } else {
            lastAbsentAt = now
        }
    }

    /// 在场且未开调试 → 打分循环该停。
    var shouldBlockScoring: Bool {
        isPresent && !debugRunWhilePresent
    }
}
