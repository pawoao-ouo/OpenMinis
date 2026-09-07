import SwiftUI

/// 群聊的对话清单。和角色那版对称——一个群一个抽屉。
struct GroupConversationsView: View {
    let group: GroupCard

    @State private var sessions: [ChatSession] = []
    @State private var showEditor = false

    var body: some View {
        List {
            Section {
                Button { startNewConversation() } label: {
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
                                     ? session.title! : AppLocalized("没起名的聊天"))
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
        .navigationTitle(group.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showEditor = true } label: {
                    Image(systemName: "pencil")
                }
            }
        }
        .sheet(isPresented: $showEditor) {
            NavigationStack { GroupEditorView(group: group) }
        }
        .navigationDestination(for: String.self) { sessionId in
            GroupChatLoader(sessionId: sessionId, group: group)
        }
        .task(id: group.id) {
            sessions = await ChatStore.shared.listSessionsForGroup(groupId: group.id)
        }
    }

    private func startNewConversation() {
        Task { @MainActor in
            let session = await ChatStore.shared.createSession(
                modelId: "default",
                title: group.name,
                source: "group:\(group.id.uuidString)"
            )
            sessions.insert(session, at: 0)
        }
    }
}
