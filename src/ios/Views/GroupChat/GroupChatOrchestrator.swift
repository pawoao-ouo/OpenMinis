import Foundation
import SwiftUI

/// 工坊编排器 v2 ——「戴面具干活」。
///
/// 第一版（已作废）给每个 agent 起一次独立的 LLMProvider.sendMessage。
/// 那条路绕开了 Minis 的工具和 agent loop，做出来的是个会说话的摆设。
///
/// 第二版：每个工坊 agent = 一个**隐藏的真会话**。会话仍走主聊天的
/// AIChatViewModel（工具、thinking、错误处理全部复用），但 agent 的
/// 人格信息通过 session 的 SOUL 覆盖藏到初始化里——这是符合设计的缝
/// （不是硬切）。
///
/// dispatch() 触发时：
/// 1. 带 @名字 → 点将，没点名 → 全员
/// 2. 每个 agent：取/建它的隐藏会话；把 persona 写到 ChatStore 的
///    session 元数据（人少时同步进 messages 表前缀）
/// 3. 等 agent loop 站完，把它的 final message 和 memory 行写回工坊 store
@MainActor
final class GroupChatOrchestrator {

    static let shared = GroupChatOrchestrator()

    private let store: GroupChatStore

    init(store: GroupChatStore = .shared) {
        self.store = store
    }

    /// 每 agent 的会话 id 映射。mem-level 缓存，重启时从 ChatStore 重建
    /// 会话的 `category` 里编号着工坊 agent id。
    private var sessionIdByAgentId: [UUID: String] = [:]

    /// 工坊前缀，便于隐藏与认领。原本 `groupchat` 但这里碰 T-x 类改多个
    /// 地方的意思大于名字——`workshop` 更清楚
    static let workshopCategory = "workshop"

    /// 并发上限：沿用 llmHub 的 4——再多 iOS 端负担不起
    private let maxConcurrent = 4

    /// 派发器：点将或全员，等人人发完话，把文本爬回工坊消息流。
    @discardableResult
    func dispatch(userText: String) async -> String? {
        let trimmed = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        guard !store.agents.isEmpty else {
            return AppLocalized("名册还是空的——先去右上角加一个 persona。")
        }

        // 先落醒醒的消息（带 @ 解析）。谁叫劲谁。
        let targets = mentioned(in: trimmed, agents: store.agents)
        store.append(GroupMessage(agentId: nil, text: trimmed, mentionedAgentIds: targets.isEmpty ? nil : targets.map(\.id)))

        let answering = targets.isEmpty ? store.agents : targets
        let batch = Array(answering.prefix(maxConcurrent))

        await withTaskGroup(of: Void.self) { tg in
            for agent in batch {
                tg.addTask { [weak self] in
                    await self?.run(agent: agent, userText: trimmed)
                }
            }
        }

        return nil
    }

    /// 单个 agent 的一轮：取或建隐藏会话，设 thing 人设，发送并等回，记忆
    private func run(agent: ChatAgent, userText: String) async {
        let sessionId = await resolveSession(for: agent)
        guard let sessionId else {
            await MainActor.run {
                store.append(GroupMessage(agentId: agent.id, text: AppLocalized("[\(agent.name)] 开不出会话。"), isError: true))
            }
            return
        }

        // 拿到该会话的 VM（来自全部聊天列表，是公有 brain）。新 VM 起来没
        // 装消息就要先 call loadSession——否则发送时装的是空 context。
        let (vm, isNew) = ViewModelCache.shared.getOrCreate(for: sessionId)
        if isNew { await vm.loadSession() }

        let wrapped = wrapUserText(agent: agent, userText: userText)

        await MainActor.run {
            vm.inputText = wrapped
            vm.send()
        }

        // 等回话到位。send 是异步的，先等它真正开跑（isProcessing -> true），
        // 再等它落地（-> false），双阶段轮询避免错过短回答。
        var sawRunning = false
        for _ in 0..<500 {
            try? await Task.sleep(nanoseconds: 300_000_000)
            let running = vm.isProcessing
            if running { sawRunning = true }
            if sawRunning && !running { break }
        }

        // 把末段 assistant 文本拼回来；钉到 agent 的 memory 里
        let reply = await MainActor.run { vm.messages.last(where: { $0.role == .assistant })?.content ?? "" }
        let clean = reply.trimmingCharacters(in: .whitespacesAndNewlines)

        await MainActor.run {
            if clean.isEmpty {
                store.append(GroupMessage(agentId: agent.id, text: AppLocalized("[\(agent.name)] 没回应——model silent or error"), isError: true))
            } else {
                store.append(GroupMessage(agentId: agent.id, text: clean))
                // 以时间戳追加进它的记忆
                let stamp = ISO8601DateFormatter().string(from: Date())
                store.appendMemory("[\(stamp)] 工坊卧谈会「\(userText.prefix(40))」→ \(clean)", to: agent.id)
            }
        }
    }

    /// 找 agent 的隐藏会话：没有就建。source="workshop" 用来从侧边栏
    /// 藏起来（见 ContentView 的过滤补丁），title 人可读。
    private func resolveSession(for agent: ChatAgent) async -> String? {
        if let id = sessionIdByAgentId[agent.id] { return id }
        let session = ChatStore.shared.createSession(
            modelId: agent.modelEntryId ?? "default",
            title: "工坊 · \(agent.name)",
            source: "workshop"
        )
        sessionIdByAgentId[agent.id] = session.id
        return session.id
    }

    /// 把醒醒的话伪装成它的当事人自述，让 agent 自己对芯片说。这个是最小不害
    /// 别的 func 的缝
    private func wrapUserText(agent: ChatAgent, userText: String) -> String {
        var s = ""
        if !agent.persona.isEmpty {
            s += "【工坊直前：你是 \(agent.name)。人设：" + agent.persona + "】"
        } else {
            s += "【工坊直前：你是 \(agent.name)。干醒醒派给你的事。】"
        }
        if !agent.memory.isEmpty {
            s += "\n【你的记忆（私有）：\n" + agent.memory + "\n】"
        }
        s += "\n\n" + userText
        return s
    }

    /// @点名。完整名字精确包含（不 substring），避免名字相近时误伤。
    private func mentioned(in text: String, agents: [ChatAgent]) -> [ChatAgent] {
        let lower = text.lowercased()
        return agents.filter { agent in
            let needle = "@" + agent.name.lowercased()
            return lower.contains(needle)
        }
    }
}
