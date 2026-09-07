import SwiftUI

/// 工坊——名册置顶、消息流、派发杆。
///
/// 路径：ContentView 侧边栏的锤子按钮 → sheet。
/// 不要 ViewModel（一层薄壳等于多一道 bug 源）——视图直接读 store。
struct GroupChatView: View {

    @ObservedObject private var store = GroupChatStore.shared

    @State private var draft: String = ""
    @State private var isSending = false
    @State private var showAgentEditor: ChatAgent? = nil
    @State private var showRoster = false

    var body: some View {
        VStack(spacing: 0) {
            // 名册置顶条
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(store.agents) { agent in
                        Button { showAgentEditor = agent } label: {
                            VStack(spacing: 4) {
                                AgentAvatarView(agent: agent, size: 44)
                                Text(agent.name)
                                    .font(.caption2)
                                    .foregroundStyle(ChatColors.secondaryText)
                                    .lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button { showAgentEditor = agent } label: {
                                Label(AppLocalized("Edit"), systemImage: "pencil")
                            }
                            Button(role: .destructive) {
                                store.remove(agent)
                            } label: {
                                Label(AppLocalized("Remove"), systemImage: "trash")
                            }
                        }
                    }
                    Button { showRoster = true } label: {
                        VStack(spacing: 4) {
                            ZStack {
                                Circle()
                                    .strokeBorder(AppearanceStudio.shared.color(.border, scope: .chat), lineWidth: 1)
                                    .background(Circle().fill(AppearanceStudio.shared.color(.surface, scope: .chat).opacity(0.5)))
                                    .frame(width: 44, height: 44)
                                Image(systemName: "plus")
                                    .foregroundStyle(ChatColors.secondaryText)
                            }
                            Text(AppLocalized("Add"))
                                .font(.caption2)
                                .foregroundStyle(ChatColors.secondaryText)
                        }
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            Divider()

            // 消息流
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(store.messages) { msg in
                            GroupBubbleRow(message: msg)
                                .id(msg.id)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .onChange(of: store.messages.count) { _ in
                    if let last = store.messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }

            Divider()

            // 派发杆
            HStack(spacing: 8) {
                TextField(
                    AppLocalized("点 '@名字' 就单派，不点就全员上…"),
                    text: $draft,
                    axis: .vertical
                )
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...3)
                Button {
                    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return }
                    draft = ""
                    isSending = true
                    Task { @MainActor in
                        _ = await GroupChatOrchestrator.shared.dispatch(userText: text)
                        isSending = false
                    }
                } label: {
                    Image(systemName: "paperplane.fill")
                        .foregroundStyle(ChatColors.accent)
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
            }
            .padding(10)
            .background(.bar)
        }
        .navigationTitle(AppLocalized("工坊"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $showAgentEditor) { agent in
            NavigationStack { ChatAgentEditor(agent: agent) }
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showRoster) {
            NavigationStack { GroupRosterView() }
                .presentationDetents([.medium, .large])
        }
    }
}
