import SwiftUI

/// 群聊主页——承接组里 groupSession 的入口，UI 复用 AIChatView。
///
/// QQ 式多角色：vm.groupRoster 塞「这一轮谁开口」，send() 里每个成员
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
            .onAppear { applyRoster(from: vm.inputText) }
            .onChange(of: vm.inputText) { newText in
                applyRoster(from: newText)
            }
            .onDisappear {
                vm.groupRoster = nil
                vm.groupHeaderPrompt = nil
            }
    }

    /// @名字 只让那个人说；没 @ 全员轮一圈。
    private func applyRoster(from text: String) {
        let members = charStore.characters.filter { group.memberIds.contains($0.id) }
        guard !members.isEmpty else {
            vm.groupRoster = nil
            vm.groupHeaderPrompt = nil
            return
        }

        var header = "【群聊】群名「\(group.name)」。"
        if !group.brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            header += "\n群氛围：\(group.brief)"
        }
        vm.groupHeaderPrompt = header

        let mentioned = members.filter { m in
            !m.name.isEmpty && (text.contains("@\(m.name)") || text.contains("＠\(m.name)"))
        }
        vm.groupRoster = mentioned.isEmpty ? members : mentioned
    }
}
