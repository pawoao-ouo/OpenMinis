import Foundation
import SwiftUI

private let logger = AppLogger(category: "GroupChat")

/// 群聊工坊的 agent 模型。
///
/// 缝合自 llmHub(筛选-infektyd/llmHub) 的 AgentIdentity + iClaw 的
/// 人设/记忆分离思路：每个 agent 有名字、自定义头像（可选）、
/// 确定性品牌色、人设提示词、绑定的模型入口，和一份只属于自己的
/// 记忆。
///
/// 醒醒明说不用 emoji 当头像，所以这里不再存 emoji 字段：
///   - 有 `avatarImageFile` → 从 Documents/groupchat/avatars/ 读
///   - 没有 → 退化成"品牌色圆 + 名字首字"的文本 placeholder
///
/// 记忆隔离（@iClaw SOUL.md/MEMORY.md per agent）：每个 agent 的
/// memory 只被它自己的对话读取，不共享。
struct ChatAgent: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    /// 头像图文件名（位于 Documents/groupchat/avatars/）；nil 时 UI
    /// 退化成文本占位头像
    var avatarImageFile: String?
    /// 存 hue (0...1)，UI 侧转 Color，不持久化 SwiftUI 类型
    var hue: Double
    /// 人设（system prompt 注入到最前）
    var persona: String
    /// 绑定的模型入口 id（ModelEntry.id），nil = 用当前会话默认模型
    var modelEntryId: String?
    /// 该 agent 的独立记忆原文
    var memory: String

    var displayColor: Color {
        Color(hue: hue, saturation: 0.5, brightness: 0.8)
    }

    /// 文本占位头像用的首字。没有图片时的兜底。
    var placeholderGlyph: String {
        String(name.prefix(1))
    }

    init(
        id: UUID = UUID(),
        name: String,
        avatarImageFile: String? = nil,
        hue: Double? = nil,
        persona: String = "",
        modelEntryId: String? = nil,
        memory: String = ""
    ) {
        self.id = id
        self.name = name
        self.avatarImageFile = avatarImageFile
        // 没给 hue 就用 id 哈希出一个——同一个 agent 永远同一个色
        self.hue = hue ?? Double(abs(id.uuidString.hashValue) % 360) / 360.0
        self.persona = persona
        self.modelEntryId = modelEntryId
        self.memory = memory
    }
}

/// 群聊工坊的 Agent 名册与群消息持久化。
///
/// 全部落 Documents/groupchat/：
///   agents.json    —— 名册
///   messages.json  —— 工坊对话（一条 message 要么 user 要么某个 agent）
@MainActor
final class GroupChatStore: ObservableObject {

    static let shared = GroupChatStore()

    @Published private(set) var agents: [ChatAgent] = []
    @Published private(set) var messages: [GroupMessage] = []

    private let fm = FileManager.default
    private var dir: URL {
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("groupchat", isDirectory: true)
    }

    private init() {
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        loadAll()
        if agents.isEmpty { seedDefaultCrew() }
    }

    // MARK: - Agents

    func upsert(_ agent: ChatAgent) {
        if let idx = agents.firstIndex(where: { $0.id == agent.id }) {
            agents[idx] = agent
        } else {
            agents.append(agent)
        }
        saveAgents()
    }

    func remove(_ agent: ChatAgent) {
        let old = agents.first(where: { $0.id == agent.id })
        agents.removeAll { $0.id == agent.id }
        if let file = old?.avatarImageFile {
            try? fm.removeItem(at: avatarsDir.appendingPathComponent(file))
        }
        saveAgents()
    }

    /// 换个头像：存到 avatars/ 下，按 agent id 命名（一 agent 一头像，
    /// 新图覆盖旧图）
    func setAvatarJPEG(_ data: Data, for agent: ChatAgent) {
        try? fm.createDirectory(at: avatarsDir, withIntermediateDirectories: true)
        let fname = "\(agent.id.uuidString).jpg"
        let url = avatarsDir.appendingPathComponent(fname)
        do {
            try data.write(to: url, options: .atomic)
            var updated = agent
            updated.avatarImageFile = fname
            upsert(updated)
        } catch {
            logger.error("[GroupChat] avatar write failed: \(error.localizedDescription)")
        }
    }

    actor AvatarCache {
        static let shared = AvatarCache()
        private var cache: [String: UIImage] = [:]
        // 不查 @MainActor 的 store——本地自己拼路径，actor 侧保持独立
        private var avatarsDir: URL {
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("groupchat/avatars", isDirectory: true)
        }
        func image(for file: String) async -> UIImage? {
            if let hit = cache[file] { return hit }
            let url = avatarsDir.appendingPathComponent(file)
            guard let data = try? Data(contentsOf: url),
                  let img = UIImage(data: data) else { return nil }
            cache[file] = img
            return img
        }
        func invalidate(_ file: String) { cache[file] = nil }
    }

    var avatarsDir: URL {
        dir.appendingPathComponent("avatars", isDirectory: true)
    }

    // MARK: - Messages

    func append(_ msg: GroupMessage) {
        messages.append(msg)
        saveMessages()
    }

    func appendMemory(_ note: String, to agentId: UUID) {
        guard let idx = agents.firstIndex(where: { $0.id == agentId }) else { return }
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let stamp = ISO8601DateFormatter().string(from: Date())
        agents[idx].memory += "\n- [\(stamp)] \(trimmed)"
        saveAgents()
    }

    // MARK: - Persistence

    private var agentsURL: URL { dir.appendingPathComponent("agents.json") }
    private var messagesURL: URL { dir.appendingPathComponent("messages.json") }

    private func loadAll() {
        if let d = try? Data(contentsOf: agentsURL),
           let a = try? JSONDecoder().decode([ChatAgent].self, from: d) {
            agents = a
        }
        if let d = try? Data(contentsOf: messagesURL),
           let m = try? JSONDecoder().decode([GroupMessage].self, from: d) {
            messages = m
        }
    }

    private func saveAgents() {
        if let d = try? JSONEncoder.gp.encode(agents) {
            try? d.write(to: agentsURL, options: .atomic)
        }
    }

    private func saveMessages() {
        if let d = try? JSONEncoder.gp.encode(messages) {
            try? d.write(to: messagesURL, options: .atomic)
        }
    }

    /// 默认班底：图用文本占位，让醒醒来贴图。不预置 emoji。
    private func seedDefaultCrew() {
        let seeds: [(String, Double, String)] = [
            ("干活的", 0.35, "你是干活的agent，活干得漂亮，缺陷主动认。"),
            ("收集的", 0.58, "你是收集资料的agent，找资料带出处。"),
            ("验收的", 0.13, "你是验收的agent，挑刺看到位，别放水。"),
        ]
        for (name, hue, persona) in seeds {
            agents.append(ChatAgent(name: name, hue: hue, persona: persona))
        }
        saveAgents()
    }
}

// MARK: - Message

struct GroupMessage: Identifiable, Codable, Equatable {
    var id: UUID
    /// nil = 醒醒发的；有值 = 哪个 agent 回的
    var agentId: UUID?
    var text: String
    var createdAt: Date
    /// 发送时点了哪些人（nil = 全员）
    var mentionedAgentIds: [UUID]?
    /// 错误态：某 agent 挂了把错误本身落进来
    var isError: Bool

    init(id: UUID = UUID(), agentId: UUID? = nil, text: String, createdAt: Date = Date(), mentionedAgentIds: [UUID]? = nil, isError: Bool = false) {
        self.id = id
        self.agentId = agentId
        self.text = text
        self.createdAt = createdAt
        self.mentionedAgentIds = mentionedAgentIds
        self.isError = isError
    }
}

private extension JSONEncoder {
    static var gp: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
}
