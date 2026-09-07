import SwiftUI
import PhotosUI

/// 名册：新增 agent、看列表、进编辑器。开 `sheet` 形式。
struct GroupRosterView: View {
    @ObservedObject private var store = GroupChatStore.shared
    @State private var showNewAgent = false

    var body: some View {
        List {
            Section {
                if store.agents.isEmpty {
                    Text(AppLocalized("还没有 agent——点右上角加一个。"))
                        .foregroundStyle(ChatColors.secondaryText)
                } else {
                    ForEach(store.agents) { agent in
                        NavigationLink {
                            ChatAgentEditor(agent: agent)
                        } label: {
                            HStack(spacing: 10) {
                                AgentAvatarView(agent: agent, size: 36)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(agent.name)
                                        .foregroundStyle(ChatColors.primaryText)
                                    if !agent.persona.isEmpty {
                                        Text(agent.persona)
                                            .font(.caption)
                                            .foregroundStyle(ChatColors.secondaryText)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer()
                                if agent.modelEntryId != nil {
                                    Image(systemName: "link.circle")
                                        .foregroundStyle(ChatColors.accent)
                                }
                            }
                        }
                    }
                    .onDelete { offsets in
                        for i in offsets { store.remove(store.agents[i]) }
                    }
                }
            } header: {
                Text(AppLocalized("Members"))
            } footer: {
                Text(AppLocalized("每个 agent 人设+记忆单独存，不共享。"))
            }
        }
        .navigationTitle(AppLocalized("名册"))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showNewAgent = true } label: { Image(systemName: "plus") }
            }
        }
        .sheet(isPresented: $showNewAgent) {
            NavigationStack { ChatAgentEditor(agent: nil) }
        }
    }
}

/// 编辑/新建一个 agent。 `mode` 由我悄悄的推过去：贴图 + 文本。
struct ChatAgentEditor: View {

    let existing: ChatAgent?

    @ObservedObject private var store = GroupChatStore.shared
    @ObservedObject private var providers = ProviderConfigStore.shared

    @State private var name: String
    @State private var persona: String
    @State private var hue: Double
    @State private var memory: String
    @State private var modelEntryId: String?
    @State private var pickedPhoto: PhotosPickerItem? = nil
    @State private var avatarPreview: UIImage? = nil
    @Environment(\.dismiss) private var dismiss

    init(agent: ChatAgent?) {
        self.existing = agent
        _name = State(initialValue: agent?.name ?? "")
        _persona = State(initialValue: agent?.persona ?? "")
        _hue = State(initialValue: agent?.hue ?? Double.random(in: 0...1))
        _memory = State(initialValue: agent?.memory ?? "")
        _modelEntryId = State(initialValue: agent?.modelEntryId)
    }

    var body: some View {
        Form {
            // 头像 + 色相
            Section(AppLocalized("长什么样")) {
                HStack(spacing: 14) {
                    ZStack {
                        if let img = avatarPreview {
                            Image(uiImage: img).resizable().scaledToFill()
                                .clipShape(Circle())
                        } else if let a = existing, let f = a.avatarImageFile {
                            AgentAvatarView(agent: a, size: 60)
                        } else {
                            Circle().fill(Color(hue: hue, saturation: 0.5, brightness: 0.8))
                                .overlay(
                                    Text(name.prefix(1).isEmpty ? "?" : String(name.prefix(1)))
                                        .font(.title2.weight(.bold)).foregroundStyle(.white)
                                )
                        }
                    }
                    .frame(width: 60, height: 60)
                    .clipShape(Circle())

                    VStack(alignment: .leading, spacing: 8) {
                        PhotosPicker(selection: $pickedPhoto, matching: .images) {
                            Label(AppLocalized("挑一张图"), systemImage: "photo")
                        }
                        ColorPicker(AppLocalized("品牌色"), selection: Binding(
                            get: { Color(hue: hue, saturation: 0.7, brightness: 0.85) },
                            set: { c in
                                if let h = UIColor(c).hsbHue { hue = h }
                            }
                        ))
                    }
                }
            }

            Section(AppLocalized("基本")) {
                TextField(AppLocalized("名字"), text: $name)
                Picker(AppLocalized("模型"), selection: $modelEntryId) {
                    Text(AppLocalized("跟随默认")).tag(String?.none)
                    ForEach(modelChoices, id: \.id) { entry in
                        Text(Self.modelLabel(entry)).tag(String?.some(entry.id))
                    }
                }
            }

            Section(AppLocalized("人设") + " (system prompt)") {
                TextEditor(text: $persona)
                    .frame(minHeight: 120)
            }

            Section(AppLocalized("它的记忆")) {
                TextEditor(text: $memory)
                    .frame(minHeight: 100)
                Text(AppLocalized("它每回完话自己记一行。你也可以手改。"))
                    .font(.caption)
                    .foregroundStyle(ChatColors.secondaryText)
            }

            if existing != nil {
                Section {
                    Button(AppLocalized("删除"), role: .destructive) {
                        if let a = existing { store.remove(a) }
                        dismiss()
                    }
                }
            }
        }
        .navigationTitle(existing == nil ? AppLocalized("新 Agent") : AppLocalized("编辑 Agent"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(AppLocalized("取消")) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(AppLocalized("好了")) {
                    save()
                }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .onChange(of: pickedPhoto) { newItem in
            guard let item = newItem else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let img = UIImage(data: data) {
                    await MainActor.run { avatarPreview = img }
                }
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
        var agent = existing ?? ChatAgent(name: "")
        agent.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        agent.persona = persona
        agent.hue = hue
        agent.memory = memory
        agent.modelEntryId = modelEntryId
        store.upsert(agent)
        if let img = avatarPreview,
           let data = img.jpegData(compressionQuality: 0.85) {
            store.setAvatarJPEG(data, for: agent)
        }
        dismiss()
    }
}

private extension UIColor {
    var hsbHue: Double? {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard getHue(&h, saturation: &s, brightness: &b, alpha: &a) else { return nil }
        return Double(h)
    }
}
