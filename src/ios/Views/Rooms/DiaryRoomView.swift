import SwiftUI

/// 日记房。仅角色能写（这是她的私本，能帮但不能代笔）。
/// 卡片式列表——每张是可折叠的小纸片，点开看写的那天忘了什么。
struct DiaryRoomView: View {

    let roomId: String
    let character: CharacterCard

    @ObservedObject private var store = RoomStore.shared
    @State private var expandedIds: Set<UUID> = []
    @State private var draftText: String = ""
    @State private var showEditor = false

    private var entries: [RoomEntry] {
        store.entries(in: roomId).sorted { $0.createdAt > $1.createdAt }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                if entries.isEmpty {
                    Text(AppLocalized("这本还没有写下第一页。\n跟她说「记今天的日记」就行。"))
                        .font(.footnote)
                        .foregroundStyle(ChatColors.secondaryText)
                        .multilineTextAlignment(.center)
                        .padding(.vertical, 40)
                }
                ForEach(entries) { entry in
                    DiaryCard(
                        entry: entry,
                        expanded: expandedIds.contains(entry.id),
                        onToggle: {
                            if expandedIds.contains(entry.id) { expandedIds.remove(entry.id) }
                            else { expandedIds.insert(entry.id) }
                        }
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
        .background(ChatColors.background.ignoresSafeArea())
        .navigationTitle(AppLocalized("日记"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showEditor = true } label: { Image(systemName: "pencil") }
            }
        }
        .sheet(isPresented: $showEditor) {
            NavigationStack {
                DiaryEditorView(roomId: roomId, owner: .user)
            }
        }
        .onAppear { store.loadIfNeeded(roomId: roomId) }
    }
}

private struct DiaryCard: View {
    let entry: RoomEntry
    let expanded: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(entry.createdAt, style: .date)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(ChatColors.secondaryText)
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundStyle(ChatColors.secondaryText)
                }
                Text(entry.text)
                    .font(.system(size: 14))
                    .foregroundStyle(ChatColors.primaryText)
                    .lineLimit(expanded ? nil : 3)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(ChatColors.secondaryBg)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(ChatColors.inputIconBorder.opacity(0.5), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

/// 写新一页。房间主人自动是 user（只有你能写）。
private struct DiaryEditorView: View {
    let roomId: String
    let owner: RoomOwner
    @Environment(\.dismiss) private var dismiss
    @State private var text: String = ""

    var body: some View {
        Form {
            Section(AppLocalized("今天想记下来什么")) {
                TextEditor(text: $text)
                    .frame(minHeight: 180)
            }
        }
        .navigationTitle(AppLocalized("写一页"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button(AppLocalized("取消")) { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(AppLocalized("完成")) {
                    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !t.isEmpty else { return }
                    RoomStore.shared.append(owner: owner, text: t, in: roomId)
                    dismiss()
                }.disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}
