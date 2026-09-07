import PhotosUI
import SwiftUI

/// 新建/编辑一个人物卡。
///
/// 模式题来自 kelivo 的 assistant 编辑页 + 醒醒常说的「软件要做，不能像
/// 填表」——这里只保留：名字、头像、喜欢的颜色、人设、记忆入口、模型绑定。
/// 别的不显示，放少宁坏多。
struct CharacterEditorView: View {

    let character: CharacterCard?     // nil = 新建

    @ObservedObject private var store = CharacterStore.shared
    @ObservedObject private var providers = ProviderConfigStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var persona: String
    @State private var hue: Double
    @State private var memory: String
    @State private var modelEntryId: String?
    @State private var pickedPhoto: PhotosPickerItem?
    @State private var avatarImage: UIImage?

    init(character: CharacterCard?) {
        self.character = character
        _name = State(initialValue: character?.name ?? "")
        _persona = State(initialValue: character?.persona ?? "")
        _hue = State(initialValue: character?.hue ?? Double.random(in: 0...1))
        _memory = State(initialValue: character == nil ? "" : CharacterStore.shared.memory(for: character!.id))
        _modelEntryId = State(initialValue: character?.modelEntryId)
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Form {
            Section(AppLocalized("长什么样")) {
                HStack(spacing: 14) {
                    avatarPreview
                        .frame(width: 60, height: 60)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    VStack(alignment: .leading, spacing: 8) {
                        PhotosPicker(selection: $pickedPhoto, matching: .images) {
                            Label(AppLocalized("换头像"), systemImage: "photo")
                        }
                        ColorPicker(AppLocalized("喜欢的颜色"), selection: Binding(
                            get: { Color(hue: hue, saturation: 0.7, brightness: 0.85) },
                            set: { c in
                                var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                                if UIColor(c).getHue(&h, saturation: &s, brightness: &b, alpha: &a) {
                                    hue = Double(h)
                                }
                            }
                        ))
                    }
                }
            }

            Section(AppLocalized("是谁")) {
                TextField(AppLocalized("名字"), text: $name)
                Picker(AppLocalized("默认模型"), selection: $modelEntryId) {
                    Text(AppLocalized("跟着聊天页选的那个走")).tag(String?.none)
                    ForEach(modelChoices, id: \.id) { entry in
                        Text(Self.modelLabel(entry)).tag(String?.some(entry.id))
                    }
                }
            }

            Section(AppLocalized("人设") + " (system prompt)") {
                TextEditor(text: $persona)
                    .frame(minHeight: 140)
                Text(AppLocalized("她在这场聊天里是谁。一两句就够，越具体越像。"))
                    .font(.caption)
                    .foregroundStyle(ChatColors.secondaryText)
            }

            Section(AppLocalized("记忆")) {
                TextEditor(text: $memory)
                    .frame(minHeight: 100)
                Text(AppLocalized("写在这儿的她下回还记得（只有这个角色知道，不进主记忆）。"))
                    .font(.caption)
                    .foregroundStyle(ChatColors.secondaryText)
            }
        }
        .navigationTitle(character == nil ? AppLocalized("新人物") : AppLocalized("编辑人物"))
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
            Image(uiImage: img)
                .resizable()
                .scaledToFill()
        } else if let c = character,
                  let f = c.avatarImageFile,
                  let data = try? Data(contentsOf: FileManager.default
                    .urls(for: .documentDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("characters/avatars", isDirectory: true)
                    .appendingPathComponent(f)),
                  let img = UIImage(data: data) {
            Image(uiImage: img)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                Color(hue: hue, saturation: 0.55, brightness: 0.85)
                Text(name.prefix(1).isEmpty ? "?" : String(name.prefix(1)))
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
            }
        }
    }

    private var modelChoices: [ModelEntry] {
        providers.config.modelEntries.filter { !$0.isHidden }
    }

    private static func modelLabel(_ entry: ModelEntry) -> String {
        let n = entry.model.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? entry.id : n
    }

    private func save() {
        let c = character ?? CharacterCard(name: "")
        var updated = c
        updated.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.persona = persona
        updated.hue = hue
        updated.modelEntryId = modelEntryId
        store.upsert(updated)
        // 记忆单独走文件——implify ugly on display plus detail edit:
        let memURL = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("characters/memory/\(updated.id.uuidString).md")
        try? FileManager.default.createDirectory(
            at: memURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? memory.write(to: memURL, atomically: true, encoding: .utf8)
        if let img = avatarImage, let jpeg = img.jpegData(compressionQuality: 0.85) {
            store.setAvatarJPEG(jpeg, for: updated.id)
        }
        dismiss()
    }
}
