import SwiftUI
import PhotosUI

// MARK: - PersonaSettingsView
//
// 编辑一个人设：名字、头像、人设提示词（SOUL.md 正文）、
// skill 开关、MCP 开关。v1 最小可用，界面跟着 App 现有风格走。

struct PersonaSettingsView: View {
    @ObservedObject var store: PersonaStore
    let personaID: String

    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var avatarURI: String? = nil
    @State private var soulBody: String = ""
    @State private var enabledSkillIds: Set<String> = []
    @State private var enabledMcpIds: Set<String> = []
    @State private var loaded = false

    @State private var showPhotoPicker = false
    @State private var photoItem: PhotosPickerItem?
    @State private var iconError: String?

    private var persona: Persona? {
        store.personas.first { $0.id == personaID }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("基本") {
                    HStack {
                        PersonaAvatarView(iconRef: avatarURI, size: 52)
                        Button("换头像") { showPhotoPicker = true }
                            .font(.callout)
                        if avatarURI != nil {
                            Button("去掉") { removeAvatar() }
                                .font(.callout)
                                .foregroundStyle(MinisTheme.secondaryText)
                        }
                    }
                    TextField("名字", text: $name)
                        .onSubmit {
                            // [D7/P1-1] 回车改名也是改名入口：失败要报，不能静默丢掉。
                            guard saveName() else {
                                MinisToast.show(store.registryDegraded
                                    ? AppLocalized("人设数据坏了，改了也存不上，重启再试。")
                                    : AppLocalized("改名没能存下来，请重试。"),
                                    systemImage: "exclamationmark.triangle.fill")
                                return
                            }
                        }
                }

                Section("人设提示词") {
                    Text("这就是 SOUL.md 的正文，决定它说话的性格和身份。")
                        .font(.caption)
                        .foregroundStyle(MinisTheme.secondaryText)
                    TextEditor(text: $soulBody)
                        .frame(minHeight: 220)
                        .font(.body)
                }

                Section("Skill") {
                    Text("关掉的不再进它的 system prompt。注意：这个开关只管「要不要展示」，不是安全隔离——被关掉的仍可能被直接读取或调用。")
                        .font(.caption)
                        .foregroundStyle(MinisTheme.secondaryText)
                    ForEach(SkillStore.shared.skills) { skill in
                        Toggle(skill.name, isOn: Binding(
                            get: { enabledSkillIds.contains(skill.id) },
                            set: { on in
                                if on { enabledSkillIds.insert(skill.id) }
                                else { enabledSkillIds.remove(skill.id) }
                                saveSkillWhitelist()
                            }
                        ))
                    }
                }

                Section("MCP") {
                    Text("关掉的不再进它的 system prompt。注意：这个开关只管「要不要展示」，不是安全隔离——被关掉的仍可能被直接读取或调用。")
                        .font(.caption)
                        .foregroundStyle(MinisTheme.secondaryText)
                    ForEach(MCPStore.shared.servers) { server in
                        Toggle(server.id, isOn: Binding(
                            get: { enabledMcpIds.contains(server.id) },
                            set: { on in
                                if on { enabledMcpIds.insert(server.id) }
                                else { enabledMcpIds.remove(server.id) }
                                saveMcpWhitelist()
                            }
                        ))
                    }
                }

                if persona?.isBuiltIn == true {
                    Section {
                        Text("这是内置人设，删不掉。提示词可以改，但改了之后它的 MCP 管家身份可能会变味。")
                            .font(.caption)
                            .foregroundStyle(MinisTheme.secondaryText)
                    }
                }
            }
            // [问题7b] 她原话：「这个界面与设置页面的UI尺寸距离也不符合，
            // 显得很奇怪」。
            //
            // 根因不是颜色，是外壳：这页原先手写 .scrollContentBackground
            // + .background(MinisTheme.canvas)，只把底色和色值跟上了，
            // 而行背景、tint、壁纸 backdrop、透明导航栏这些设置面共有的
            // 东西一件都没有。设置里每一页走的都是 .settingsPage()
            // （appearancePage(.settings) + SettingsListRowBackground），
            // 两套外壳并排看就是"尺寸距离不符合"。
            //
            // 直接换成同一个外壳，而不是在这里再手抄一遍——手抄就是当初
            // 走偏的原因。
            .settingsPage()
            .navigationTitle("编辑人设")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("保存") {
                        // [D7/P1-1] 改名没存上就不关页面：关了她会以为改上了。
                        guard saveAll() else {
                            MinisToast.show(store.registryDegraded
                                ? AppLocalized("人设数据坏了，改了也存不上，重启再试。")
                                : AppLocalized("改名没能存下来，请重试。"),
                                systemImage: "exclamationmark.triangle.fill")
                            return
                        }
                        dismiss()
                    }
                }
            }
            .onAppear { loadOnce() }
            .photosPicker(isPresented: $showPhotoPicker, selection: $photoItem,
                          matching: .images, photoLibrary: .shared())
            .onChange(of: photoItem) { newItem in
                guard let newItem else { return }
                Task { await applyPickedImage(newItem) }
            }
            .alert("这张图用不了", isPresented: Binding(
                get: { iconError != nil }, set: { if !$0 { iconError = nil } }
            )) {
                Button("好", role: .cancel) { iconError = nil }
            } message: {
                Text(iconError ?? "")
            }
        }
    }

    // MARK: - load / save

    private func loadOnce() {
        guard !loaded, let p = persona else { return }
        loaded = true
        name = p.name
        avatarURI = p.avatar
        if let file = SoulStore.load(for: personaID) {
            soulBody = file.body
        }
        let allSkillIds = Set(SkillStore.shared.skills.map(\.id))
        enabledSkillIds = p.skillIds.map(Set.init) ?? allSkillIds
        let allMcpIds = Set(MCPStore.shared.servers.map(\.id))
        enabledMcpIds = p.mcpServerIds.map(Set.init) ?? allMcpIds
    }

    /// [D7/P1-1] 返回改名到底落盘没有；没改名（名字没变 / 为空）算成功。
    @discardableResult
    private func saveName() -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        return store.renamePersona(personaID, to: trimmed)
    }

    /// [D7] 返回这次头像改动到底落盘没有：false = 只改了内存，重启会丢。
    @discardableResult
    private func saveAvatar() -> Bool {
        guard var p = persona else { return false }
        p.avatar = avatarURI
        return store.updatePersona(p)
    }

    /// 去掉头像：落盘失败就把预览恢复成原来那张，别挂一张"已去掉"的假象。
    private func removeAvatar() {
        let previous = avatarURI
        avatarURI = nil
        guard saveAvatar() else {
            avatarURI = previous
            iconError = store.registryDegraded
                ? AppLocalized("人设数据坏了，改了也存不上，重启再试。")
                : AppLocalized("头像没能去掉，请重试。")
            return
        }
    }

    private func saveSoul() {
        var file = SoulStore.load(for: personaID)
            ?? SoulFile(metadata: .default, body: "")
        file.body = soulBody
        try? SoulStore.save(file, for: personaID)
    }

    private func saveSkillWhitelist() {
        guard var p = persona else { return }
        let all = Set(SkillStore.shared.skills.map(\.id))
        p.skillIds = (enabledSkillIds == all) ? nil : Array(enabledSkillIds)
        store.updatePersona(p)
    }

    private func saveMcpWhitelist() {
        guard var p = persona else { return }
        let all = Set(MCPStore.shared.servers.map(\.id))
        p.mcpServerIds = (enabledMcpIds == all) ? nil : Array(enabledMcpIds)
        store.updatePersona(p)
    }

    /// [D7/P1-1] 返回改名那一步落盘没有；保存按钮靠它决定要不要关页面。
    /// 头像 / 提示词 / 开关那几步各有自己的 inline 报错，不进这个返回值。
    @discardableResult
    private func saveAll() -> Bool {
        let nameOK = saveName()
        saveAvatar()
        saveSoul()
        saveSkillWhitelist()
        saveMcpWhitelist()
        return nameOK
    }

    private func applyPickedImage(_ item: PhotosPickerItem) async {
        defer { photoItem = nil }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = ThumbnailCache.downsampledImage(from: data, maxEdge: 512) else {
            await MainActor.run { iconError = AppLocalized("这张图读不出来，换一张试试。") }
            return
        }
        // [avatar-file] Stored as a file reference, never inline base64.
        let name = SoulIconImage.storedName(prefix: "persona", id: personaID)
        switch SoulIconImage.store(image, named: name) {
        case .success(let path):
            await MainActor.run {
                avatarURI = path
                // [D7] 注册表降级时改动只进内存：别让她以为换上了，
                // 预览也退回原来那张，别挂一张重启就丢的图。
                guard saveAvatar() else {
                    avatarURI = persona?.avatar
                    iconError = store.registryDegraded
                        ? AppLocalized("人设数据坏了，改了也存不上，重启再试。")
                        : AppLocalized("头像没能存下来，请重试。")
                    return
                }
            }
        case .failure(let reason):
            // [D3] 以前不管什么失败都报"图读不出来"：图明明解出来了，
            // 是写盘失败，赖图只会让她拿一张好图反复重试。
            await MainActor.run { iconError = reason.localizedDescription }
        }
    }
}
