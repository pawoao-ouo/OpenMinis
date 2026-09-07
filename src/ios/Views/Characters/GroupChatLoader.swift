import SwiftUI

/// 群聊主页——承接组里 groupeSession 的入口，UI 直接复用 AIChatView。
///
/// 实现策略（和醒醒说的 @提及对齐）：
///   - 每条用户消息响起一轮。作者在群卡上的"成员"决定参与全量，@name 会
///     裁到那一位。
///   - vm.soulOverlay 里装 "群名册+人设+成员memory" + 一条系统不能失的
///     规则【群体的格定》："每个成员发言前带头色块，格式 `**[名]** …内容…`。
///     这轮点到名谁发言，没有点名就全员轮一次，一次不超过 3 段短。"
///   - 一段 member 段结束自动 appendMemory 到那成员的 memory.md（他专属）。
struct GroupChatLoader: View {

    let sessionId: String
    let group: GroupCard

    @ObservedObject private var charStore = CharacterStore.shared

    private var vm: AIChatViewModel {
        let (vm, _) = ViewModelCache.shared.getOrCreate(for: sessionId)
        return vm
    }

    var body: some View {
        AIChatView(sessionId: sessionId)
            .onAppear { pushOverlay(mentionNames: []) }
            .onChange(of: vm.inputText) { newText in
                // 谁在输入框里被 @ 就在 overlay 里加上"必发言"的旗。
                // 在发消息时（不是打字时）生效——send 读 soulOverlay。
                let mentionNames = extractMentions(from: newText)
                pushOverlay(mentionNames: mentionNames)
            }
            .onChange(of: vm.isProcessing) { processing in
                guard !processing else { return }
                harvestMemories()
            }
    }

    /// 从输入文本抽 @名字。只吃 `@` 紧跟的人名（别让 @ 里面夹一段英文
    /// 都当成人名）。命中成员库才生效。
    private func extractMentions(from text: String) -> [String] {
        let members = charStore.characters.filter { group.memberIds.contains($0.id) }
        var hits: [String] = []
        for m in members where !m.name.isEmpty {
            // 同时允许 "@名" 或 "NAME,"（英文逗号格式）
            if text.contains("@\(m.name)") || text.contains("＠\(m.name)") {
                hits.append(m.name)
            }
        }
        return hits
    }

    /// 决定本轮轮值：
    ///   - 有点名 => 只有 named 这些成员
    ///   - 没点名 => 全部成员都发 （group 不小于 2，总没超）
    private func pushOverlay(mentionNames: [String]) {
        let members = charStore.characters.filter { group.memberIds.contains($0.id) }
        let roster: [CharacterCard]
        if mentionNames.isEmpty {
            roster = members
        } else {
            roster = members.filter { mentionNames.contains($0.name) }
        }
        guard !roster.isEmpty else { vm.soulOverlay = nil; return }

        var s = "【THIS IS A GROUP CHAT】群名「\(group.name)」。\n"
        if !group.brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            s += "群氛围/场景：\(group.brief)\n"
        }
        s += "这轮轮到的发言者：\n"
        for m in roster {
            s += "・「\(m.name)」"
            if !m.persona.isEmpty { s += "——\(m.persona)" }
            let mem = CharacterStore.shared.memory(for: m.id)
            if !mem.isEmpty {
                let clipped = mem.split(separator: "\n").suffix(8).joined(separator: "\n")
                s += "\n    （他的私人记忆，仅他知道）：\n" + clipped
            }
            s += "\n"
        }
        s += """
        【群规矩，别丢】
        1. 每个角色单独一段，以加粗成员名开场：「**\(roster[0].name)** …、**名字** …」。
        2. 成员写回的语气、口径必须各归各——这是在演一出对话，不是一个人喊三遍。
        3. 成员可以互相抬杠、捧场、爆料；但角度不能飘离自己的 persona。
        4. 私人记忆里你是有权看的在场人，别拿来砸场子，别把记忆当事实陈述出去。
        """
        vm.soulOverlay = s
    }

    /// 对话结束后扫一遍最后这条 assistant 回复，把以「**X**」开头的每一段
    /// 塞到那个 X 的 memory.md（角色自己的记忆，群共享视角）。
    private func harvestMemories() {
        guard let last = vm.messages.last(where: { $0.role == .assistant }),
              !last.content.isEmpty
        else { return }
        let stamp = ISO8601DateFormatter().string(from: Date())
        let members = charStore.characters.filter { group.memberIds.contains($0.id) }
        for m in members {
            let head = "**\(m.name)**"
            // 抽出所有以「**name**」开头的段（以换行拆、剥前缀）
            let excerpts = last.content
                .components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.hasPrefix(head) }
                .map { String($0.dropFirst(head.count)).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard !excerpts.isEmpty else { continue }
            let merged = excerpts.joined(separator: " / ")
            CharacterStore.shared.appendMemory(
                "\(stamp) 群「\(group.name)」里我说：\(merged.prefix(200))",
                to: m.id
            )
        }
    }
}
