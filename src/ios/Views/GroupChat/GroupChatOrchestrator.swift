import Foundation

/// 群聊编排器：缝合 llmHub 的 GroupChatOrchestrator。
///
/// 区别在两点：
/// - 上游是 OpenClaw 长驻 sidecar，我们是本机请求——所以不流式，一次
///   request 拿全（LLMProvider.sendMessage 是这个形状）
/// - 并发上限 4 跟他们一致，但"该叫谁起"从消息里解析 @名字 来选，
///   没人点将 = 全名册
///
/// 每个 agent 起独立 Task（actors/isolation 已就位，不共享状态），
/// 完成一律回 MainActor 落 store——UI 不会被 off-main 改。
@MainActor
final class GroupChatOrchestrator {

    static let shared = GroupChatOrchestrator()

    /// 最多同时答的 agent 数。llmHub 也是 4，沿用他们的实验值。
    private let maxConcurrent = 4

    /// 民政局：把 user 消息派给该答的人家。
    ///
    /// `text` 里 @名字（前缀匹配，大小写不敏感）命中的先答；一个都没
    /// 命中 = 全体起立。
    ///
    /// 返回没人可派的错误提示文本（nil = 已成功发出任务）。
    @discardableResult
    func dispatch(userText: String, in store: GroupChatStore) async -> String? {
        let trimmed = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let all = store.agents
        guard !all.isEmpty else {
            return AppLocalized("No agents yet — add one with the roster button up top.")
        }

        // 先落醒醒的消息，再决定谁回
        let mentioned = mentionedAgents(in: trimmed, agents: all)
        store.append(GroupMessage(agentId: nil, text: trimmed, mentionedAgentIds: mentioned.map(\.id)))

        let candidates = mentioned.isEmpty ? all : mentioned
        let batch = Array(candidates.prefix(maxConcurrent))

        // 并发开工。完一个 waypoints 进一条。
        await withTaskGroup(of: Void.self) { tg in
            for agent in batch {
                tg.addTask { [weak self] in
                    await self?.run(agent: agent, userText: trimmed, store: store)
                }
            }
        }

        return nil
    }

    private func run(agent: ChatAgent, userText: String, store: GroupChatStore) async {
        let request = buildRequest(agent: agent, userText: userText, store: store)

        let maybeEntry = resolveEntry(agent: agent)
        guard let entry = maybeEntry else {
            let text = AppLocalized("[\(agent.name)] No model bound. Edit it in the agent editor.")
            await MainActor.run {
                store.append(GroupMessage(agentId: agent.id, text: text, isError: true))
            }
            return
        }

        do {
            let provider = try await AIChatViewModel.makeLLMProvider(for: entry)
            let resp = try await provider.sendMessage(
                messages: request.messages,
                systemPrompt: request.systemPrompt,
                maxTokens: 2000,
                temperature: nil
            )
            let plain = resp.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let shown = plain.isEmpty ? AppLocalized("…") : plain
            await MainActor.run {
                store.append(GroupMessage(agentId: agent.id, text: shown))
                // 学到的写进 agent 的 memory —— 是它自己的，别的人碰不着
                store.appendMemory(AppLocalized("在工坊里回过：") + shown, to: agent.id)
            }
        } catch {
            await MainActor.run {
                store.append(GroupMessage(
                    agentId: agent.id,
                    text: AppLocalized("[\(agent.name)] request failed: \(error.localizedDescription)"),
                    isError: true
                ))
            }
        }
    }

    /// 解析 @点将。前缀匹配（"@工" 能点 "干活的"），大小写不敏感。
    /// 多个 @分隔 "@" 或空白起锚，其余字符向来名字。
    private func mentionedAgents(in text: String, agents: [ChatAgent]) -> [ChatAgent] {
        let matches = agents.filter { agent in
            let needle = "@\(agent.name.lowercased())"
            return text.lowercased().contains(needle)
        }
        return matches
    }

    /// 每个 agent 的上下文结构（iClaw 式人设+记忆隔离）：
    /// - system = 人设 + memory + 名册提示（知道自己不是一个人在工坊）
    /// - user = 最近的群聊历史（它可以看到别的 agent 说过什么——不然不叫群聊）
    private func buildRequest(agent: ChatAgent, userText: String, store: GroupChatStore) -> (systemPrompt: String, messages: [LLMMessage]) {
        var sys = agent.persona.trimmingCharacters(in: .whitespacesAndNewlines)
        if !agent.memory.isEmpty {
            sys += "\n\n[你的记忆]\n" + agent.memory.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let names = store.agents.filter { $0.id != agent.id }.map(\.name).joined(separator: ", ")
        if !names.isEmpty {
            sys += "\n\n[其他在场伙伴：\(names)。你是 '\(agent.name)']。"
        }

        //脸皮：群聊上下文截尾，太长往两边砍
        let tail = store.messages.suffix(28)
        var messages: [LLMMessage] = []
        for m in tail {
            if let aid = m.agentId, let a = store.agents.first(where: { $0.id == aid }) {
                messages.append(LLMMessage(role: .assistant, content: "\(a.name)：\(m.text)"))
            } else if m.agentId == nil {
                messages.append(LLMMessage(role: .user, content: m.text))
            }
        }
        // 保证最末一条是用户的最新发言（@点到的 agent）
        let lastUserText = userText
        if messages.last?.content != lastUserText {
            messages.append(LLMMessage(role: .user, content: lastUserText))
        }

        return (sys, messages)
    }

    /// 解析 agent 的模型入口：优先人马自己的，缺省抓一个当前开着的
    ///（actions 放工坊这类小脚diary——不过会话 binding 不拉进来，避免串台）。
    private func resolveEntry(agent: ChatAgent) -> ModelEntry? {
        if let id = agent.modelEntryId,
           let entry = ProviderConfigStore.shared.entry(for: id) {
            return entry
        }
        // 缺省 = 第一个可调用的模型入口（不看会话 binding）
        return ProviderConfigStore.shared.config.modelEntries.first(where: { !$0.isHidden })
            ?? ProviderConfigStore.shared.config.modelEntries.first
    }
}
