import AppIntents
import Foundation

/// 静默唤醒占位。perform 只过门闩、写决策日志，不打分、不发通知。
/// 不注册进 MinisShortcutsProvider，避免变成现成 Shortcuts 图。
struct ActiveReachWakeIntent: AppIntent {
    static var title: LocalizedStringResource = "小梦主动唤醒"
    static var description = IntentDescription("把唤醒信号交给小梦主动门闩。默认关，空对话框不往下走。")
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let disposition = await MainActor.run {
            ActiveReachStore.shared.handleWake(source: "intent")
        }
        switch disposition {
        case .blocked(let reason):
            return .result(value: "blocked:\(reason.rawValue)")
        case .allowed:
            return .result(value: "allowed")
        }
    }
}
