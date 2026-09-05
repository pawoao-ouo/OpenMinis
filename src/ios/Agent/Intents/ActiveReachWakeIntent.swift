import AppIntents
import Foundation

/// 静默唤醒。Shortcuts 定时主触发；perform 只跑打分入草稿，不发通知。
struct ActiveReachWakeIntent: AppIntent {
    static var title: LocalizedStringResource = "小梦主动唤醒"
    static var description = IntentDescription("叫醒小梦去想要不要找你。只打分、只入草稿，不发通知。")
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        if let cycle = await ActiveReachStore.shared.runReachCycle(source: "shortcuts") {
            return .result(value: "\(cycle.disposition):\(cycle.reason ?? "")")
        }
        let last = await MainActor.run { ActiveReachStore.shared.decisions.first }
        if let last {
            return .result(value: "\(last.disposition):\(last.reason ?? "")")
        }
        return .result(value: "blocked")
    }
}
