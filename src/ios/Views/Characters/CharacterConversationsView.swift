import SwiftUI

/// 角色的对话清单（"这个人开过的全部会话"）。kelivo 侧边栏的精神：
/// 每个角色一个抽屉，里面是她自己的话题历史，点进去就接着聊。
struct CharacterConversationsView: View {

    let character: CharacterCard

    @ObservedObject private var store = CharacterStore.shared
    @State private var sessions: [ChatSession] = []
    @State private var showEditor = false

    var body: some View {
        List {
            Section {
                Button {
                    startNewConversation()
                } label: {
                    Label(AppLocalized("聊个新的"), systemImage: "square.and.pencil")
                }
            }
            Section(header: Text(AppLocalized("聊过的"))) {
                if sessions.isEmpty {
                    Text(AppLocalized("还没聊过呢，点上面开个头。"))
                        .foregroundStyle(ChatColors.secondaryText)
                } else {
                    ForEach(sessions, id: \.id) { session in
                        NavigationLink(value: session.id) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(session.title?.isEmpty == false
                                     ? session.title!
                                     : AppLocalized("没起名的聊天"))
                                    .foregroundStyle(ChatColors.primaryText)
                                    .lineLimit(1)
                                Text(session.updatedAt, style: .relative)
                                    .font(.caption)
                                    .foregroundStyle(ChatColors.secondaryText)
                            }
                        }
                    }
                    .onDelete { offsets in
                        for i in offsets {
                            let sid = sessions[i].id
                            Task { await ChatStore.shared.deleteSession(sid) }
                        }
                        sessions.remove(atOffsets: offsets)
                    }
                }
            }
        }
        .navigationTitle(character.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showEditor = true } label: {
                    Image(systemName: "pencil")
                }
            }
        }
        .sheet(isPresented: $showEditor) {
            NavigationStack { CharacterEditorView(character: character) }
        }
        .navigationDestination(for: String.self) { sessionId in
            // 角色会话就是正常 AIChatView 承载——工具/skill/记忆全部在该用。
            // 这是不是"工坊"：工坊改成了角色卡，不是独立的一套。
            CharacterChatLoader(sessionId: sessionId, character: character)
        }
        .task(id: character.id) { await reload() }
    }

    private func reload() async {
        sessions = await ChatStore.shared.listSessionsForCharacter(characterId: character.id)
    }

    private func startNewConversation() {
        Task { @MainActor in
            let session = await ChatStore.shared.createSession(
                modelId: character.modelEntryId ?? "default",
                title: character.name,
                source: "character:\(character.id.uuidString)"
            )
            sessions.insert(session, at: 0)
        }
    }
}

/// 真正用来开聊的容器。负责三件事：
///   1. 把 persona + 该角色的 memory 锤进 VM 的 systemPromptOver架构（不重动 ChatStore schema）
///   2. 托管一个 AIChatView(sessionId:)，命为"角色内部聊天页"
///   3. 对话结束后把这条回复写到角色的 memory.md，并更新"最后聊"在 index
///     里（不必改的当天，后续会查这个到角色卡显示活跃度）
struct CharacterChatLoader: View {
    let sessionId: String
    let character: CharacterCard

    private var vm: AIChatViewModel {
        let (vm, _) = ViewModelCache.shared.getOrCreate(for: sessionId)
        return vm
    }

    var body: some View {
        AIChatView(sessionId: sessionId)
            .toolbar {
                // 右上角她给自己干活的入口。单个小屋菜单，
                // 列日记/梦/信三个动作。
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { generateRoom(.diary) } label: {
                            Label(AppLocalized("今天的日记写一页"), systemImage: "book")
                        }
                        Button { generateRoom(.dream) } label: {
                            Label(AppLocalized("记述一个梦"), systemImage: "moon.stars")
                        }
                        Button { generateRoom(.letter) } label: {
                            Label(AppLocalized("写一封信给你"), systemImage: "envelope")
                        }
                    } label: {
                        Image(systemName: "door.left.hand.open")
                            .font(.system(size: 15))
                    }
                    .accessibilityLabel(Text(AppLocalized("小屋")))
                }
            }
            .onAppear {
                // 人设+记忆前缀推进 system 层（裸量缝在 build 里包 UI 层,这层视图
                // 是package 弃用 seal pull）
                vm.soulOverlay = buildOverlay()
                applyParameterDefaults()
            }
            .onChange(of: vm.isProcessing) { isProcessing in
                guard !isProcessing else { return }
                // 滚动条答完——拆成一轮它自己说的话进记忆
                rememberLatest()
            }
            .alert(item: $roomFeedback) { fb in
                Alert(title: Text(fb.title), message: Text(fb.body))
            }
    }

    @State private var roomFeedback: RoomFeedback? = nil

    private struct RoomFeedback: Identifiable {
        let id = UUID()
        let title: String
        let body: String
    }

    /// 让这个角色基于**当前会话**生成房间内容。
    /// 畜点：dialogue 是本页的、patch 用的不是"最近几条"而是这页的完整对话，
    /// 所以人格/记忆/当下感受全在上面,不是放空模型去瞎编。
    private func generateRoom(_ kind: RoomContentGenerator.Kind) {
        let conversation = vm.messages
            .filter { !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { m in
                let who = (m.role == .user ? "我" : "她")
                return "\(who)：\(m.content)"
            }
            .joined(separator: "\n")
        Task { @MainActor in
            let res = await RoomContentGenerator.shared.generate(
                kind: kind,
                character: character,
                conversationOverride: conversation
            )
            if res.succeeded {
                let roomId = RoomStore.roomId(kind: kind.roomKind, characterId: character.id)
                RoomContentGenerator.shared.commit(kind: kind, roomId: roomId, character: character, raw: res.raw)
                let what: String
                switch kind {
                case .dream: what = AppLocalized("梦见你了")
                case .diary: what = AppLocalized("写了一页日记")
                case .letter: what = AppLocalized("写了一封信")
                }
                roomFeedback = RoomFeedback(
                    title: AppLocalized("她") + " \(character.name) \(what)",
                    body: AppLocalized("存在小屋里了。")
                )
            } else {
                roomFeedback = RoomFeedback(
                    title: AppLocalized("写不出来"),
                    body: res.error ?? ""
                )
            }
        }
    }

    private func buildOverlay() -> String {
        var s = "你在这个会话里不是系统默认人设——你是「\(character.name)」。"
        if !character.persona.isEmpty {
            s += "\n人设:\n" + character.persona
            }
        let memory = CharacterStore.shared.memory(for: character.id)
        if !memory.isEmpty {
            s += "\n你的专属记忆（仅你知道、只有你所有）：\n" + memory
        }
        return s
    }

    /// 把角色卡上的思考/温度/Token 默认灌输进这个会话的 inference 配置。
    /// 规则：**会话从未动过推理配置 → 整份默认写进；已动过 → 只补用户没设的 nil 位**。
    /// thinking 那格只要 inferenceConfig 一存在就视为「用户已表态」，不再覆盖。
    private func applyParameterDefaults() {
        let store = ProviderConfigStore.shared
        let existing = store.inferenceConfig(for: sessionId)
        let fresh = (existing == nil)
        var cfg = existing ?? SessionInferenceConfig()
        var changed = false

        if fresh, let tl = character.thinkingLevel {
            cfg.thinkingLevel = ThinkingLevel.decoded(tl)
            changed = true
        }
        if cfg.temperature == nil, let t = character.temperature {
            cfg.temperature = t
            changed = true
        }
        if cfg.maxOutputTokens == nil, let m = character.maxOutputTokens {
            cfg.maxOutputTokens = m
            changed = true
        }
        if changed {
            store.setInferenceConfig(cfg, for: sessionId)
        }
    }

    private func rememberLatest() {
        let assistantMessages = vm.messages.filter { $0.role == .assistant }
        guard let last = assistantMessages.last, !last.content.isEmpty else { return }
        // 一行以时间戳开头，越权 ”得着越 ()
        let stamp = ISO8601DateFormatter().string(from: Date())
        let snippet = String(last.content.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        CharacterStore.shared.appendMemory("[\(stamp)] 回复: \(snippet)", to: character.id)
    }
}
