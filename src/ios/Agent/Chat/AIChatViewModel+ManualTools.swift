import Foundation

private let manualToolsLogger = AppLogger(category: "ManualTools")

// MARK: - [T-manual-phase2-5a/6a] 手册第二阶段新增的三个小工具
//
// 这三个上游都没有，是照 ai-manual-phase2-brief.md 第 5、6 节新写的：
//
// - `set_env_var`：把用户在对话里给的密钥存进 Keychain。不走 `minis-config`
//   ——`EnvVarsCollection.add()` 是故意抛 permissionDenied 的（值只走 Keychain
//   和用户界面）。工具返回、日志、记忆里都不许出现值。
// - `switch_persona`：换全局当前人设。只换"新对话的默认身份"，当前这轮对话
//   的人设在建会话时就定死了，这里不改也不该假装改了。
// - `set_tts_default_group`：换默认 TTS 分组。单次换声音走 send_voice 的
//   voice/group 参数，和这个工具不是一件事。
//
// 三个都不带界面，颜色/字号/布局的全局变量约束在这里没有落点。

extension AIChatViewModel {

    // MARK: - set_env_var

    /// 存一个环境变量。值只在内存里过一遍，返回文本里只有 key 和长度级别的
    /// 描述，绝不回显值本身。
    func executeSetEnvVar(args: [String: Any]) -> (output: String, success: Bool) {
        let rawKey = (args["key"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let rawValue = args["value"] as? String ?? ""
        let note = (args["note"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !rawKey.isEmpty else {
            return ("Error: Missing required 'key' parameter.", false)
        }
        let key = rawKey.uppercased()
        guard EnvVarStore.isValidKey(key) else {
            return ("Error: '\(rawKey)' is not a valid variable name. Letters, digits and underscore only, must start with a letter.", false)
        }
        guard !rawValue.isEmpty else {
            // 没给值就绝不自己编一个，把深链给她自己填。
            let link = "[Set \(key)](minis-clone://settings/environments?create_key=\(key)&create_value=&create_note=)"
            return ("Error: no value given. The user has to tell you the value in chat, or fill it in themselves: \(link)", false)
        }
        // 重复 key 时 add() 只打一条 warning 就返回，静默失败最难查——先自己查一遍。
        if EnvVarStore.shared.entries.contains(where: { $0.key == key }) {
            return ("Error: '\(key)' already exists. Ask the user whether to replace it — deleting first needs their confirmation, because the old value cannot be recovered from here.", false)
        }

        EnvVarStore.shared.add(key: key, value: rawValue, note: note)
        // add() 失败时也不抛错，只能回读确认。
        guard EnvVarStore.shared.entries.contains(where: { $0.key == key }) else {
            return ("Error: storing '\(key)' failed (Keychain write refused). Tell the user plainly; do not retry with the value pasted into a command.", false)
        }
        manualToolsLogger.info("[set_env_var] stored \(key) (value not logged)")
        return ("Stored \(key) in the Keychain. The value is not echoed back and never appears in logs or files. Use it as $\(key) inside shell commands.", true)
    }

    // MARK: - switch_persona

    /// 换全局当前人设。找不到或重名时返回列表让模型再问，不瞎切。
    func executeSwitchPersona(args: [String: Any]) -> (output: String, success: Bool) {
        let wanted = (args["persona"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else {
            return ("Error: Missing required 'persona' parameter.", false)
        }

        let store = PersonaStore.shared
        // 「我自己」是用户档案，不是可以切过去的人设。
        let candidates = store.personas.filter { !$0.isUserProfile }
        guard !candidates.isEmpty else {
            return ("Error: no personas are configured on this device.", false)
        }

        let matches = candidates.filter {
            $0.name.caseInsensitiveCompare(wanted) == .orderedSame || $0.id == wanted
        }
        let list = candidates.map { "- \($0.name) (\($0.id))" }.joined(separator: "\n")

        guard matches.count == 1, let target = matches.first else {
            let why = matches.isEmpty ? "no persona named '\(wanted)'" : "'\(wanted)' matches more than one persona"
            return ("Error: \(why). Available personas:\n\(list)\nAsk the user which one; do not pick for them.", false)
        }

        let previous = store.currentPersonaID
        store.currentPersonaID = target.id

        // 当前这轮对话的人设是建会话时定死的，这里明确说出来，别让模型
        // 以为它把眼下的对话也换了。
        var out = "Switched the app's current persona to \(target.name) (\(target.id)). "
        if let sessionPersona = sessionPersonaId, sessionPersona != target.id {
            let currentName = candidates.first(where: { $0.id == sessionPersona })?.name ?? sessionPersona
            out += "This conversation keeps its own persona (\(currentName)) — new conversations will use \(target.name)."
        } else {
            out += "New conversations will use this persona."
        }
        manualToolsLogger.info("[switch_persona] \(previous.prefix(8)) → \(target.id.prefix(8))")
        return (out, true)
    }

    // MARK: - set_tts_default_group

    /// 换默认 TTS 分组。找不到或重名时返回分组列表。
    func executeSetTTSDefaultGroup(args: [String: Any]) -> (output: String, success: Bool) {
        let wanted = (args["group"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else {
            return ("Error: Missing required 'group' parameter.", false)
        }

        let store = TTSGroupStore.shared
        let groups = store.groups
        guard !groups.isEmpty else {
            return ("Error: no TTS groups are configured. Tell the user to set one up in Settings → Voice Services.", false)
        }

        let matches = groups.filter {
            $0.name.caseInsensitiveCompare(wanted) == .orderedSame || $0.id == wanted
        }
        let list = groups.map { "- \($0.name) (\($0.memberServiceIds.count) 个服务)" }.joined(separator: "\n")

        guard matches.count == 1, let target = matches.first else {
            let why = matches.isEmpty ? "no TTS group named '\(wanted)'" : "'\(wanted)' matches more than one group"
            return ("Error: \(why). Configured groups:\n\(list)\nAsk the user which one; do not pick for them.", false)
        }
        guard !target.memberServiceIds.isEmpty else {
            return ("Error: the group '\(target.name)' has no services in it, so it cannot produce any voice. Tell the user to add a service to it first.", false)
        }

        let previous = store.defaultGroupId
        store.setDefaultGroupId(target.id)
        guard store.defaultGroupId == target.id else {
            return ("Error: setting the default TTS group failed. Tell the user plainly.", false)
        }
        manualToolsLogger.info("[set_tts_default_group] \(previous?.prefix(8) ?? "nil") → \(target.id.prefix(8))")
        return ("Default TTS group is now \(target.name) (\(target.memberServiceIds.count) services). This applies to send_voice calls that do not pass voice=/group=; the current message's voice does not change.", true)
    }
}
