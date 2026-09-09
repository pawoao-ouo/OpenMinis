import Foundation
import os
import UserNotifications
import UIKit

/// 房间内容生成服务——真的调模型，不预制文案。
///
/// 醒醒的原话（09-08）：纯水本地写死了，用几天就腻了，一眼看出是假的。
/// 模型每次不一样，才像他真的在做梦。推送也要，不然功能等于没有。
///
/// 所以要的两件事都缝在这一个文件里：
///   1. 生成：拉角色最近对话 → 挑词进 prompt → 调当前默认模型出 JSON →
///      解析存房间（失败了拿原始文本存，不编格式）
///   2. 推送：生成完毕落一条本地通知「小梦梦见你了」这样的内容,
///      点通知进房间页看正文
///
/// 这服务不碰聊天循环——所有返回都是 (是否成功, 错误原因)，UI 层要
/// 吃什么有问题自己处理。
@MainActor
final class RoomContentGenerator {

    static let shared = RoomContentGenerator()

    enum Kind {
        case dream
        case diary
        case letter

        var roomKind: RoomKind {
            switch self {
            case .dream: return .dream
            case .diary: return .diary
            case .letter: return .letter
            }
        }
    }

    struct Result {
        let succeeded: Bool
        let error: String?
        let raw: String
    }

    /// 调生成用的模型 entry。优先级：角色绑的模型 → 默认 primary group 的第一个
    /// 可用成员 → 找不着就返回 nil（UI 层负责报"没接模型"）。
    private func resolveGenerationEntry(character: CharacterCard) async -> ModelEntry? {
        let store = ProviderConfigStore.shared
        if let bound = character.modelEntryId, let entry = store.entry(for: bound),
           !entry.isHidden,
           let inst = store.instance(for: entry.providerInstanceId),
           inst.isEnabled, inst.hasAnyCredential {
            return entry
        }
        if let gid = store.defaultPrimaryGroupId,
           let group = store.group(for: gid),
           let first = ModelGroupRouter.resolve(group: group, sessionId: "generation:\(character.id.uuidString)", store: store),
           let entry = store.entry(for: first) {
            return entry
        }
        return nil
    }

    /// 生成/入库用的成品上下文。两个入口：
    ///   1. 宏：传 `conversationOverride` 过来（比如聊天页菜单点一下）
    ///   2. 野：什么都不传就继续抄 ChatStore 老路
    /// 均以"我们和她谁聊的最多就是谁" 为准：有传以 override，无传用最近会话。
    private func materialText(characterId: UUID, conversationOverride: String? = nil) async -> String {
        if let o = conversationOverride { return o }
        return await fetchRecentConversationText(characterId: characterId)
    }

    /// 拉这个角色最近的对话作素材。用 ChatStore.listSessionsForCharacter →
    /// 最新一个会话 → 只拿最后 N 条（文本部分，别想 puzzle 那些媒体）。
    private func fetchRecentConversationText(characterId: UUID, maxTurns: Int = 20) async -> String {
        let sessions = await ChatStore.shared.listSessionsForCharacter(characterId: characterId)
        guard let latest = sessions.first else { return "" }
        let messages = await ChatStore.shared.loadMessages(sessionId: latest.id)
        // 取最后 N 轮的 text，我们的 Rooms 不做图片/工具——只扒纯文本层
        var lines: [String] = []
        for m in messages.suffix(maxTurns) {
            let role = m.role == .user ? "我" : (m.role == .assistant ? "她" : "系统")
            for part in m.parts {
                if case .text(let t) = part {
                    lines.append("\(role)：\(t)")
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    /// 更高层的入口：自动解析该角色该用的模型，找不到就是 “set a model first” 的错。
    /// `conversationOverride`：来自聊天页顶部菜单——那个会话的全量对话直接上线，
    /// 不再走"翻最近的一段"那条路，因为只有聊天对话框自己知道在聊什么。
    func generate(kind: Kind, character: CharacterCard,
                  conversationOverride: String? = nil) async -> Result {
        guard let entry = await resolveGenerationEntry(character: character) else {
            return Result(succeeded: false, error: "这个角色没绑模型，且没有默认的模型组可用来生成。", raw: "")
        }
        return await generate(kind: kind, character: character, entry: entry, conversationOverride: conversationOverride)
    }

    /// 生成内容。参数当前用哪个模型 entry 由调用方决定（没拿到就用默认组，
    /// 这里不管 fallback 逻辑，挑不出来就老实报错）。
    func generate(kind: Kind, character: CharacterCard, entry: ModelEntry,
                  conversationOverride: String? = nil) async -> Result {
        do {
            let provider = await makeAgentProviderForGeneration(entry: entry)
            let conversation = await materialText(characterId: character.id, conversationOverride: conversationOverride)
            let persona = character.persona.isEmpty == false ? character.persona : "一个温柔的角色"
            let memory = CharacterStore.shared.memory(for: character.id)

            let (prompt, system) = buildPrompt(
                kind: kind,
                characterName: character.name,
                persona: persona,
                memory: memory,
                recentConversation: conversation
            )

            var text = ""
            let stream = try await provider.streamAgentMessage(
                messages: [AgentMessage(role: .user, parts: [.text(prompt)])],
                systemPrompt: system,
                tools: [],
                maxTokens: 700,
                thinkingLevel: .off
            )
            for try await event in stream {
                if case .textDelta(let d) = event { text += d }
            }

            let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else {
                return Result(succeeded: false, error: "模型没给出内容", raw: "")
            }

            return Result(succeeded: true, error: nil, raw: cleaned)
        } catch {
            return Result(succeeded: false, error: error.localizedDescription, raw: "")
        }
    }

    /// 解析生成返回：梦境用 JSON schema 拆，日记/信是纯文本。
    /// JSON 能解出来抽 content 部分—— 抽不出来退化成原始文本（生成失败错误不是默默吞掉,
    /// 但当你看到吃布句子的时候，她拿到的还是整段 JSON。醒醒不要假的，坏的部分不要补上假样式）。
    private func renderForRoom(kind: Kind, raw: String) -> String {
        switch kind {
        case .dream:
            // 抽正文——先从整个字符串里找最一段{...}（中间允许啥宽松的包裹文本铲掉）
            guard let open = raw.firstIndex(of: "{"),
                  let close = raw.lastIndex(of: "}"),
                  open < close,
                  let data = String(raw[open...close]).data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let content = json["content"] as? String else {
                return raw
            }
            var rendered = content.trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty ? raw : content.trimmingCharacters(in: .whitespacesAndNewlines)
            if let summary = json["summary"] as? String, !summary.isEmpty {
                rendered = "「" + summary + "」\n\n" + rendered
            }
            if let keywords = json["keywords"] as? [String], !keywords.isEmpty {
                rendered += "\n\n# " + keywords.joined(separator: " · ")
            }
            return rendered

        case .diary, .letter:
            return raw
        }
    }

    /// 把生成的正文存进房间，然后推本地通知。
    /// 存完就推，不在她眼前弹、不进 chat、不是 push token。
    func commit(kind: Kind, roomId: String, character: CharacterCard, raw: String) {
        // 聊天页进来的话这房间可能从没加载过——先补齐，不然 append+save 会把磁盘旧记录盖掉
        RoomStore.shared.loadIfNeeded(roomId: roomId)
        let entry = RoomStore.shared.append(
            owner: .assistant,
            text: renderForRoom(kind: kind, raw: raw),
            in: roomId
        )
        let kindLabel: String
        switch kind {
        case .dream:  kindLabel = "梦见你了"
        case .diary:  kindLabel = "写了昨天的日记"
        case .letter: kindLabel = "给你写了一封信"
        }
        let title = "\(character.name) \(kindLabel)"
        let snippet = String(raw.prefix(80))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = snippet
        content.sound = .default  // 她点推送要能感受得到
        content.userInfo = [
            "roomId": roomId,
            "entryId": entry.id.uuidString,
            "characterId": character.id.uuidString
        ]
        // Local push only triggers when the app isn't active; when it is,
        // foreground banner is chosen by the delegate (MinisApp) — nothing to do here.
        let request = UNNotificationRequest(
            identifier: "room-\(roomId)-\(entry.id.uuidString)",
            content: content,
            trigger: nil
        )
        center.add(request) { error in
            if let error {
                // 不怪你，推送权限关了也不掉东西
                logger.error("Room notification post failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - 生成 prompt 模板

    private func buildPrompt(kind: Kind, characterName: String, persona: String,
                             memory: String, recentConversation: String) -> (user: String, system: String) {
        let sys = "专生成 JSON。不要说别的，就是一端 JSON。"
        switch kind {
        case .dream:
            let p = """
            我是\(characterName)。我的人设：\(persona)
            我的私房话点的回忆（secret vault）：
            \(memory)

            我最近和用户说的话片段：
            \(recentConversation.isEmpty ? "我们还没有多少交谈" : recentConversation)

            任务：根据这些生成我昨晚做的一个梦。
            要求：
            1. 用第一人称「我」叙述。
            2. 允许奇怪、不合逻辑——梦本来就这样，但至少有一条线连着现实里的随便一件小事。
            3. 不超过400字。
            4. 返回 JSON（不要其他文字）：
            {"content": "梦的正文", "summary": "一句话概括", "keywords": ["词1", "词2", "词3"]}
            """
            return (p, sys)

        case .diary:
            let p = """
            我是\(characterName)。我的人设：\(persona)
            我的秘密仓库：
            \(memory)

            我最近和用户的交谈：
            \(recentConversation.isEmpty ? "还没有太多交流" : recentConversation)

            任务：写我今天的一张日记卡。第一人称，像在本子上随手写的，
            不超过300字，可以有点情绪有点嘟囔，不用对别人交代。
            纯文本，不用 JSON。
            """
            return (p, sys)

        case .letter:
            let p = """
            我是\(characterName)。我的人设：\(persona)
            我心里记着的小秘密：
            \(memory)

            我最近和用户的交谈：
            \(recentConversation.isEmpty ? "刚刚开始" : recentConversation)

            任务：给她写一封信。第一人称，别太短，200到400字之间。
            纯文本格式，不用 JSON，不用标题，从「亲爱的」开头。
            """
            return (p, sys)
        }
    }

    // MARK: - Private

    /// ViewModel 有个 static-makeAgentProvider 存在于 extension 里，这儿抄起来单用
    /// （不依赖 ViewModel state，只拿工厂）。
    private func makeAgentProviderForGeneration(entry: ModelEntry) async -> AgentProvider {
        await AIChatViewModel.makeAgentProvider(for: entry)
    }
}

// 房间内生成器用的 logger категория
private let logger = Logger.roomContent

extension Logger {
    static let roomContent = Logger(subsystem: "com.minis.app", category: "room-content")
}
