import SwiftUI

/// 日记房。仅角色能写（这是她的私本，能帮但不能代笔）。
/// 卡片式列表——每张是可折叠的小纸片，点开看写的那天忘了什么。
struct DiaryRoomView: View {

    let roomId: String
    let character: CharacterCard

    @ObservedObject private var store = RoomStore.shared
    @State private var expandedIds: Set<UUID> = []
    @State private var showEditor = false
    @State private var showGenerate = false
    @State private var editingEntry: RoomEntry? = nil

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
                        fromName: entry.owner == .assistant ? character.name : AppLocalized("我"),
                        expanded: expandedIds.contains(entry.id),
                        onToggle: {
                            if expandedIds.contains(entry.id) { expandedIds.remove(entry.id) }
                            else { expandedIds.insert(entry.id) }
                        }
                    )
                    .roomEntryContextMenu(roomId: roomId, entry: entry) { editing in
                        editingEntry = editing
                    }
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
                Menu {
                    Button {
                        showEditor = true
                    } label: {
                        Label(AppLocalized("我自己写一页"), systemImage: "pencil")
                    }
                    Button {
                        showGenerate = true
                    } label: {
                        Label(AppLocalized("让她去写"), systemImage: "pencil.and.scribble")
                    }
                } label: {
                    Image(systemName: "square.and.pencil")
                }
            }
        }
        .sheet(isPresented: $showEditor) {
            NavigationStack {
                DiaryEditorView(roomId: roomId, owner: .user)
            }
        }
        .sheet(item: $editingEntry) { entry in
            NavigationStack { RoomEntryEditorView(roomId: roomId, entry: entry) }
        }
        .sheet(isPresented: $showGenerate) {
            NavigationStack {
                DiaryGenerateView(roomId: roomId, character: character)
            }
        }
        .onAppear { store.loadIfNeeded(roomId: roomId) }
    }
}

private struct DiaryCard: View {
    let entry: RoomEntry
    let fromName: String
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

/// 让角色去写一篇日记。她（角色）来写，你只负责按一天几次召唤。
private struct DiaryGenerateView: View {
    let roomId: String
    let character: CharacterCard

    @Environment(\.dismiss) private var dismiss
    @State private var isGenerating = true
    @State private var errorText: String? = nil

    var body: some View {
        VStack(spacing: 20) {
            if isGenerating {
                Spacer()
                ProgressView().scaleEffect(1.2)
                Text(AppLocalized("日记写着呢"))
                    .font(.footnote)
                    .foregroundStyle(ChatColors.secondaryText)
                Spacer()
            } else if let err = errorText {
                Spacer()
                Image(systemName: "exclamationmark.bubble")
                    .font(.system(size: 36))
                    .foregroundStyle(ChatColors.secondaryText)
                Text(err)
                    .font(.footnote)
                    .foregroundStyle(ChatColors.secondaryText)
                    .padding(.horizontal, 30)
                Button(AppLocalized("好")) { dismiss() }
                    .buttonStyle(.bordered)
                Spacer()
            } else {
                Spacer()
                Image(systemName: "book.closed.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(ChatColors.accent)
                Text(AppLocalized("写完了，去翻翻看"))
                    .font(.headline)
                    .foregroundStyle(ChatColors.primaryText)
                Button(AppLocalized("好")) { dismiss() }
                    .buttonStyle(.borderedProminent)
                Spacer()
            }
        }
        .navigationTitle(AppLocalized("她在写"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let res = await RoomContentGenerator.shared.generate(kind: .diary, character: character)
            if res.succeeded {
                RoomContentGenerator.shared.commit(kind: .diary, roomId: roomId, character: character, raw: res.raw)
                isGenerating = false
            } else {
                errorText = res.error ?? AppLocalized("写不出来")
                isGenerating = false
            }
        }
    }
}
