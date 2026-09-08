import SwiftUI

/// 小房间·第一间：纪念日。
///
/// 不碰主界面骨架，从侧边栏底部的小门进来。
/// 内容：挂牌日（可加可改）、房里的便签（按 owner 区分谁贴的）。
/// 主题全体走现有 AppearanceStudio/ChatColors token，不写死颜色。
struct AnniversaryRoomView: View {

    let roomId: String
    let character: CharacterCard

    @ObservedObject private var store = RoomStore.shared
    @State private var draftText: String = ""
    @State private var draftOwner: RoomOwner = .user
    @State private var editingDate: Date = Date()
    @State private var hasDate: Bool = false

    private var entries: [RoomEntry] {
        store.entries(in: roomId)
    }

    var body: some View {
        List {
            // 挂牌日
            Section {
                HStack {
                    Text(AppLocalized("Landmark day"))
                        .foregroundStyle(ChatColors.primaryText)
                    Spacer()
                    if hasDate {
                        DatePicker("", selection: $editingDate, displayedComponents: .date)
                            .labelsHidden()
                            .onChange(of: editingDate) { newValue in
                                store.setLandmarkDate(newValue, in: roomId)
                            }
                    } else {
                        Button(AppLocalized("Set")) {
                            hasDate = true
                            store.setLandmarkDate(editingDate, in: roomId)
                        }
                    }
                }
                if hasDate, let date = store.landmarkDate(in: roomId) {
                    Text(daysLine(for: date))
                        .font(.footnote)
                        .foregroundStyle(ChatColors.secondaryText)
                }
            }

            // 便签列表
            Section(header: Text(AppLocalized("Notes"))) {
                if entries.isEmpty {
                    Text(AppLocalized("Nothing yet. Leave the first one."))
                        .foregroundStyle(ChatColors.secondaryText)
                } else {
                    ForEach(entries) { entry in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(entry.owner.displayName)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(entry.owner == .assistant
                                        ? ChatColors.accent
                                        : ChatColors.secondaryText)
                                Spacer()
                                Text(entry.createdAt, style: .date)
                                    .font(.caption2)
                                    .foregroundStyle(ChatColors.secondaryText)
                            }
                            Text(entry.text)
                                .foregroundStyle(ChatColors.primaryText)
                        }
                        .padding(.vertical, 2)
                    }
                    .onDelete { offsets in
                        for idx in offsets {
                            let entry = entries[idx]
                            store.delete(id: entry.id, in: roomId)
                        }
                    }
                }
            }

            // 写一张新的
            Section(header: Text(AppLocalized("Leave a note"))) {
                Picker(AppLocalized("As"), selection: $draftOwner) {
                    ForEach(RoomOwner.allCases) { owner in
                        Text(owner.displayName).tag(owner)
                    }
                }
                .pickerStyle(.segmented)
                TextField(AppLocalized("Write something…"), text: $draftText, axis: .vertical)
                    .lineLimit(1...4)
                Button(AppLocalized("Pin it")) {
                    let text = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return }
                    store.append(owner: draftOwner, text: text, in: roomId)
                    draftText = ""
                }
                .disabled(draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .navigationTitle(character.name)
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(.background)
        .onAppear {
            if let d = store.landmarkDate(in: roomId) {
                editingDate = d
                hasDate = true
            }
        }
    }

    private func daysLine(for date: Date) -> String {
        let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: date), to: Calendar.current.startOfDay(for: Date())).day ?? 0
        if days == 0 { return AppLocalized("That's today.") }
        if days > 0 { return AppLocalized("\(days) days since.") }
        return AppLocalized("\(-days) days to go.")
    }
}
