import SwiftUI

/// agent 脑袋头像组件：有图贴图，没图文本占位。色彩走 token（这里是
/// agent 自己的品牌色——不属于主题 token 常规槽位，按名册数据来）
struct AgentAvatarView: View {
    let agent: ChatAgent
    var size: CGFloat = 44

    @State private var image: UIImage? = nil

    var body: some View {
        ZStack {
            if let img = image {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .clipShape(Circle())
            } else {
                Circle().fill(agent.displayColor)
                Text(agent.placeholderGlyph)
                    .font(.system(size: size * 0.45, weight: .semibold))
                    .foregroundStyle(Color.white)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(Color.white.opacity(0.25), lineWidth: 1))
        .task(id: agent.avatarImageFile) {
            guard let f = agent.avatarImageFile else { image = nil; return }
            image = await GroupChatStore.AvatarCache.shared.image(for: f)
        }
    }
}

/// 工坊里的一条消息。左 = agent，右 = 醒醒。
struct GroupBubbleRow: View {
    let message: GroupMessage
    @ObservedObject private var store = GroupChatStore.shared

    private var agent: ChatAgent? {
        guard let aid = message.agentId else { return nil }
        return store.agents.first(where: { $0.id == aid })
    }

    var body: some View {
        if let a = agent {
            // agent 消息：头像 + 名字牌 + 气泡
            HStack(alignment: .top, spacing: 8) {
                AgentAvatarView(agent: a, size: 28)
                VStack(alignment: .leading, spacing: 4) {
                    Text(a.name)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(a.displayColor)
                    Text(message.text)
                        .font(.body)
                        .foregroundStyle(ChatColors.primaryText)
                        .textSelection(.enabled)
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(a.displayColor.opacity(0.12))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(a.displayColor.opacity(0.3), lineWidth: 0.5)
                        )
                }
                Spacer(minLength: 40)
            }
        } else {
            // 醒醒的消息：靠右，走全局用户气泡 token
            HStack(alignment: .top) {
                Spacer(minLength: 40)
                Text(message.text)
                    .font(.body)
                    .foregroundStyle(.white)
                    .textSelection(.enabled)
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(AppearanceStudio.shared.color(.userBubble, scope: .chat))
                    )
            }
        }
    }
}
