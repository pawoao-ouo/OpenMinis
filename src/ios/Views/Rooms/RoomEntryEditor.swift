import SwiftUI

/// 编辑一条房间记录的通用面板。
/// 用途：房间里不管是纪念日便签、日记、梦还是信，长按那条都能"点进去改"，保存直接覆盖原文。
///
/// 挂到 pbxproj：放在 Views/Rooms/ 里。进来了哪里点进去看都有，
/// 别再给四个房间各写一遍这个表单。
struct RoomEntryEditorView: View {

    let roomId: String
    let entry: RoomEntry

    @Environment(\.dismiss) private var dismiss
    @State private var text: String

    init(roomId: String, entry: RoomEntry) {
        self.roomId = roomId
        self.entry = entry
        _text = State(initialValue: entry.text)
    }

    var body: some View {
        Form {
            Section {
                TextEditor(text: $text)
                    .frame(minHeight: 160)
            } header: {
                Text(AppLocalized("改一改"))
            } footer: {
                Text(AppLocalized("保存后会直接覆盖这条，不改成新条目。"))
                    .font(.caption)
                    .foregroundStyle(ChatColors.secondaryText)
            }
        }
        .navigationTitle(AppLocalized("编辑这条"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(AppLocalized("取消")) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(AppLocalized("保存")) {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    RoomStore.shared.update(id: entry.id, text: trimmed, in: roomId)
                    dismiss()
                }
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}

extension View {
    /// 长按一下，弹出快捷菜单：编辑（第一个）、删除（第二个）。
    /// 各房间卡片通用——一圈调用一圈完成。
    @ViewBuilder
    func roomEntryContextMenu(
        roomId: String,
        entry: RoomEntry,
        edit: @escaping (RoomEntry) -> Void,
        deleteLabel: String.LocalizationValue = "删除",
        editLabel: String.LocalizationValue = "编辑"
    ) -> some View {
        self.contextMenu {
            Button {
                edit(entry)
            } label: {
                Label(AppLocalized(editLabel), systemImage: "pencil")
            }
            Button(role: .destructive) {
                RoomStore.shared.delete(id: entry.id, in: roomId)
            } label: {
                Label(AppLocalized(deleteLabel), systemImage: "trash")
            }
        }
    }
}
