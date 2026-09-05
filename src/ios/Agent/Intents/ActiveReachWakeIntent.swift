import AppIntents
import Foundation

/// 静默唤醒占位。perform 跑 runReachCycle：门闩 + 打分，只入草稿不发通知。
/// 不注册进 MinisShortcutsProvider。
struct ActiveReachWakeIntent: AppIntent {
    static var title: LocalizedStringResource = "小梦主动唤醒"
    static var description = IntentDescription("把唤醒信号交给小梦主动。默认关，空对话框不往下走，不发通知。")
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        if let cycle = await ActiveReachStore.shared.runReachCycle(source: "intent") {
            return .result(value: "\(cycle.disposition):\(cycle.reason ?? "")")
        }
        let last = await MainActor.run { ActiveReachStore.shared.decisions.first }
        if let last {
            return .result(value: "\(last.disposition):\(last.reason ?? "")")
        }
        return .result(value: "blocked")
    }
}
