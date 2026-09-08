import SwiftUI

/// 梦境房。剪影抄小手机的 dream.js：
/// 每间房每天最多一个梦，白天点开就能看到这角色夜里做了什么。
///
/// 现在这版只摆结构：房间已就位，生成按钮等你来点。
/// 自动生成的逻辑下一步接到聊天循环里——现在先让你看看她梦里的样子。
struct DreamRoomView: View {

    let roomId: String
    let character: CharacterCard

    @ObservedObject private var store = RoomStore.shared
    @State private var showGenerateSheet = false

    private var entries: [RoomEntry] {
        store.entries(in: roomId).sorted { $0.createdAt > $1.createdAt }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                // 今晚生成开关 (占位) —— 真正的自动生成走后续补丁
                Button {
                    showGenerateSheet = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "moon.stars.fill")
                            .foregroundStyle(ChatColors.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(AppLocalized("她今晚梦见了什么"))
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(ChatColors.primaryText)
                            Text(AppLocalized("戳一下生成（接聊天上下文，手动按钮版）"))
                                .font(.caption)
                                .foregroundStyle(ChatColors.secondaryText)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(ChatColors.secondaryText)
                    }
                    .padding(16)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(ChatColors.secondaryBg)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(ChatColors.inputIconBorder.opacity(0.5), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)

                if entries.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "moon.zzz")
                            .font(.system(size: 32))
                            .foregroundStyle(ChatColors.secondaryText)
                        Text(AppLocalized("还没有梦。生成一个，她就把梦里看到的放到这里。"))
                            .font(.footnote)
                            .foregroundStyle(ChatColors.secondaryText)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                    }
                    .padding(.vertical, 30)
                }

                ForEach(entries) { entry in
                    DreamCard(entry: entry)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
        .background(ChatColors.background.ignoresSafeArea())
        .navigationTitle(AppLocalized("梦境"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showGenerateSheet) {
            NavigationStack {
                DreamGenerateView(roomId: roomId, character: character)
            }
        }
        .onAppear { store.loadIfNeeded(roomId: roomId) }
    }
}

private struct DreamCard: View {
    let entry: RoomEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "moon")
                    .foregroundStyle(ChatColors.accent)
                Text(entry.createdAt, style: .date)
                    .font(.footnote)
                    .foregroundStyle(ChatColors.secondaryText)
                Spacer()
            }
            Text(entry.text)
                .font(.system(size: 14.5, design: .serif))
                .foregroundStyle(ChatColors.primaryText)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(ChatColors.secondaryBg)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(ChatColors.inputIconBorder.opacity(0.4), lineWidth: 1)
        )
    }
}

/// 生成梦境的小面板。下一步接聊天上下文，现在先手动写个框进去。
private struct DreamGenerateView: View {
    let roomId: String
    let character: CharacterCard
    @Environment(\.dismiss) private var dismiss
    @State private var text: String = ""

    var body: some View {
        Form {
            Section {
                TextEditor(text: $text)
                    .frame(minHeight: 140)
                Text(AppLocalized("或者让事情自然发生——等接入对话生成器，她会自己写梦进来。"))
                    .font(.caption)
                    .foregroundStyle(ChatColors.secondaryText)
            } header: {
                Text(AppLocalized("坦白今天梦的"))
            }
        }
        .navigationTitle(AppLocalized("新的梦"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button(AppLocalized("取消")) { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(AppLocalized("记下这个梦")) {
                    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !t.isEmpty else { return }
                    RoomStore.shared.append(owner: .assistant, text: t, in: roomId)
                    dismiss()
                }
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}
