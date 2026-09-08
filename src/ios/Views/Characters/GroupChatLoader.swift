import SwiftUI

/// 群聊主页——承接组里 groupSession 的入口，UI 复用 AIChatView。
///
/// QQ 式多角色：vm.groupMembers 塞群成员全集；send() 里按 @过滤后每个成员
/// 自己跑一整轮模型——自己的人设、自己的记忆、自己的模型、自己的气泡
/// （speakerId 落到 messages 表）。记忆收割在 vm 轮值循环里做：谁说完
/// 当场把那段话进谁的 memory.md，跨重启不重复收。
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
            .onAppear { configure() }
            // 名册不在打字时重算——send() 里会按「发送那一秒的文本」
            // 重新抽 @，群成员全集（groupMembers）进场就常驻。
            .onDisappear {
                vm.groupMembers = []
                                vm.groupHeaderPrompt = nil
            }
    }

    private func configure() {
        let members = charStore.characters.filter { group.memberIds.contains($0.id) }
        guard !members.isEmpty else {
            vm.groupMembers = []
                        vm.groupHeaderPrompt = nil
            return
        }

        var header = "【群聊】群名「\(group.name)」。"
        if !group.brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            header += "\n群氛围：\(group.brief)"
        }
        vm.groupHeaderPrompt = header
        vm.groupMembers = members
    }
}
