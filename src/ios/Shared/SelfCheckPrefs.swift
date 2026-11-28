import Foundation

/// [batch5-selfcheck 11-27 醒醒] 「让ai先想一下」开关的持久化。
/// [batch9 11-28 醒醒] 改成纯全局：原来按会话存，用户在一个会话里打开，
/// 换个会话又关着，以为没生效。现在一个 key 管全部会话。
/// 默认关：不打开就完全不出现在提示词里。
/// sessionId 参数保留是为了不动调用方。
enum SelfCheckPrefs {
    private static let globalKey = "ai.selfCheck.enabled"

    static func isEnabled(sessionId: String) -> Bool {
        _ = sessionId
        return UserDefaults.standard.bool(forKey: globalKey)
    }

    static func set(_ enabled: Bool, sessionId: String) {
        _ = sessionId
        UserDefaults.standard.set(enabled, forKey: globalKey)
    }
}
