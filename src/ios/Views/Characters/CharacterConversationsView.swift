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
            .onAppear {
                // 人设+记忆前缀推进 system 层（裸量缝在 build 里包 UI 层,这层视图
                // 是package 弃用 seal pull）
                vm.soulOverlay = buildOverlay()
            }
            .onChange(of: vm.isProcessing) { isProcessing in
                guard !isProcessing else { return }
                // 滚动条答完——拆成一轮它自己说的话进记忆
                rememberLatest()
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

    private func rememberLatest() {
        let assistantMessages = vm.messages.filter { $0.role == .assistant }
        guard let last = assistantMessages.last, !last.content.isEmpty else { return }
        // 一行以时间戳开头，越权 ”得着越 ()
        let stamp = ISO8601DateFormatter().string(from: Date())
        let snippet = String(last.content.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        CharacterStore.shared.appendMemory("[\(stamp)] 回复: \(snippet)", to: character.id)
    }
}
