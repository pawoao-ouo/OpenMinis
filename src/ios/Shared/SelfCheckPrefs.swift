import Foundation

/// [batch5-selfcheck 11-27 醒醒] 「让ai先想一下」开关的持久化。
/// 按会话存 UserDefaults，照 AIVoiceMessageComposer.voiceReplies 的先例。
/// 默认关：不打开就完全不出现在提示词里。
enum SelfCheckPrefs {
    private static func key(_ sid: String) -> String { "ai.selfCheck.\(sid)" }

    static func isEnabled(sessionId: String) -> Bool {
        UserDefaults.standard.bool(forKey: key(sessionId))
    }

    static func set(_ enabled: Bool, sessionId: String) {
        UserDefaults.standard.set(enabled, forKey: key(sessionId))
    }
}
