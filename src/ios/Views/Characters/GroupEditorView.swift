import PhotosUI
import SwiftUI

/// 建群。点进这页的两种入口：新建（member 空）或编辑已有群。
///
/// 像 QQ 一样：多选人物（checkbox），起个名，完了点保存。列表用完即弃，
/// 没去动 ChatStore——真正新建第一条会话发生在用户第一次发消息那一刻。
struct GroupEditorView: View {

    let group: GroupCard?   // nil = 新建

    @ObservedObject private var charStore = CharacterStore.shared
    @ObservedObject private var groupStore = GroupStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var brief: String
    @State private var pickedMemberIDs: Set<UUID>
    @State private var pickedPhoto: PhotosPickerItem?
    @State private var avatarImage: UIImage?

    init(group: GroupCard?) {
        self.group = group
        _name = State(initialValue: group?.name ?? "")
        _brief = State(initialValue: group?.brief ?? "")
        _pickedMemberIDs = State(initialValue: Set(group?.memberIds ?? []))
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && pickedMemberIDs.count >= 2
    }

    var body: some View {
        Form {
            Section(AppLocalized("群名片")) {
                HStack(spacing: 14) {
                    avatarPreview
                        .frame(width: 60, height: 60)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    VStack(alignment: .leading, spacing: 8) {
                        PhotosPicker(selection: $pickedPhoto, matching: .images) {
                            Label(AppLocalized("换头像"), systemImage: "photo")
                        }
                        Text("\(pickedMemberIDs.count) \(AppLocalized("个成员"))")
                            .font(.caption)
                            .foregroundStyle(ChatColors.secondaryText)
                    }
                }
                TextField(AppLocalized("群名字"), text: $name)
            }

            Section(AppLocalized("叫上谁（至少两个）")) {
                if charStore.characters.isEmpty {
                    Text(AppLocalized("还没有人呢，先去捏一个。"))
                        .foregroundStyle(ChatColors.secondaryText)
                } else {
                    ForEach(charStore.characters) { c in
                        Toggle(isOn: Binding(
                            get: { pickedMemberIDs.contains(c.id) },
                            set: { on in
                                if on { pickedMemberIDs.insert(c.id) } else { pickedMemberIDs.remove(c.id) }
                            }
                        )) {
                            HStack(spacing: 10) {
                                MemberDot(character: c)
                                Text(c.name)
                            }
                        }
                    }
                }
            }

            Section(AppLocalized("这个群的氛围")) {
                TextEditor(text: $brief)
                    .frame(minHeight: 100)
                Text(AppLocalized("写给这群人的氛围。比如：今晚在露营，大家说话都懒洋洋的。"))
                    .font(.caption)
                    .foregroundStyle(ChatColors.secondaryText)
            }
        }
        .navigationTitle(group == nil ? AppLocalized("新群聊") : AppLocalized("编辑群聊"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(AppLocalized("取消")) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(AppLocalized("完成")) { save() }
                    .disabled(!canSave)
            }
        }
        .onChange(of: pickedPhoto) { newItem in
            guard let item = newItem else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let img = UIImage(data: data) {
                    await MainActor.run { avatarImage = img }
                }
            }
        }
    }

    @ViewBuilder private var avatarPreview: some View {
        if let img = avatarImage {
            Image(uiImage: img).resizable().scaledToFill()
        } else if let g = group,
                  let f = g.avatarImageFile,
                  let data = try? Data(contentsOf: FileManager.default
                    .urls(for: .documentDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("groups/avatars", isDirectory: true)
                    .appendingPathComponent(f)),
                  let img = UIImage(data: data) {
            Image(uiImage: img).resizable().scaledToFill()
        } else {
            ZStack {
                Color(hue: group?.hue ?? 0.6, saturation: 0.55, brightness: 0.85)
                Image(systemName: "person.2.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
            }
        }
    }

    private func save() {
        var g = group ?? GroupCard(name: "")
        g.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        g.brief = brief
        g.memberIds = charStore.characters
            .filter { pickedMemberIDs.contains($0.id) }
            .map(\.id)
        groupStore.upsert(g)
        if let img = avatarImage, let jpeg = img.jpegData(compressionQuality: 0.85) {
            groupStore.setAvatarJPEG(jpeg, for: g.id)
        }
        dismiss()
    }
}

/// 成员圆点（色+首字），用来做组的视觉定调
private struct MemberDot: View {
    let character: CharacterCard
    var body: some View {
        ZStack {
            Circle().fill(Color(hue: character.hue, saturation: 0.55, brightness: 0.85))
            Text(String(character.name.prefix(1)))
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
        }
        .frame(width: 24, height: 24)
    }
}
