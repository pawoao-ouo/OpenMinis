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
    @State private var editingEntry: RoomEntry? = nil

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
                            Text(AppLocalized("召唤一次就行——她会如实把梦里看什么放进去"))
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
                        .roomEntryContextMenu(roomId: roomId, entry: entry) { editing in
                            editingEntry = editing
                        }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
        .background(ChatColors.background.ignoresSafeArea())
        .navigationTitle(AppLocalized("梦境"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editingEntry) { entry in
            NavigationStack { RoomEntryEditorView(roomId: roomId, entry: entry) }
        }
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

/// 生成梦境的 sheet——真调模型，进度条转完就入库。
/// 失败不高度，但把错误摆出来让你知道他为什么没梦到。
private struct DreamGenerateView: View {
    let roomId: String
    let character: CharacterCard

    @Environment(\.dismiss) private var dismiss
    @State private var isGenerating = true
    @State private var errorText: String? = nil

    var body: some View {
        VStack(spacing: 20) {
            if isGenerating {
                Spacer()
                ProgressView()
                    .scaleEffect(1.2)
                Text(AppLocalized("做梦呢，别吵"))
                    .font(.footnote)
                    .foregroundStyle(ChatColors.secondaryText)
                Spacer()
            } else {
                Spacer()
                Image(systemName: "moon.stars.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(ChatColors.accent)
                Text(AppLocalized("她梦见了什么！房卡上已记下"))
                    .font(.headline)
                    .foregroundStyle(ChatColors.primaryText)
                Button(AppLocalized("好")) { dismiss() }
                    .buttonStyle(.borderedProminent)
                Spacer()
            }
            if let err = errorText {
                Text(err)
                    .font(.footnote)
                    .foregroundStyle(ChatColors.secondaryText)
                    .padding(.horizontal, 30)
            }
        }
        .navigationTitle(AppLocalized("新的梦"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let res = await RoomContentGenerator.shared.generate(kind: .dream, character: character)
            if res.succeeded {
                RoomContentGenerator.shared.commit(kind: .dream, roomId: roomId, character: character, raw: res.raw)
                isGenerating = false
            } else {
                errorText = res.error ?? "模型今天不想生成"
                isGenerating = false
            }
        }
    }
}
