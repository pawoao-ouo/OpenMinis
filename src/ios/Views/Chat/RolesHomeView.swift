import SwiftUI
import PhotosUI

// MARK: - Roles (Address Book) [T-roles-09-15]
//
// 角色列表 + 详情 + 创建/编辑. 列表逻辑对齐 QQ 通讯录:
//   点角色 → 进角色详情页（查看信息 + 编辑 + 删除，全在明面，不用长按）
// 规则（醒醒拍板）：
//   • 列表分组折叠，未分组的进「未分组」
//   • 点人 → 详情页（不是直接进对话框）
//   • 创建/编辑三样：名字 + 头像 + 提示词
//   • 头像只支持上传图片（无 emoji），不限制大小
//   • 删角色 = 连会话带记忆全清（deleteAssistant 已级联）
//   • 空模板，用户自定义
// 颜色全走 MinisThemeList / AppearanceStudio token，零硬编码色。

// MARK: - 列表页（通讯录）

struct RolesHomeView: View {
    @StateObject private var store = RoleStore()
    @State private var creating = false
    @State private var detailRoleId: String?
    @State private var expandedGroups: Set<String> = ["ungrouped"]

    /// Drives the detail-page push. iOS 16 has no `navigationDestination(item:)`.
    private var detailBinding: Binding<Bool> {
        Binding(
            get: { detailRoleId != nil },
            set: { on, _ in if !on { detailRoleId = nil } }
        )
    }

    private var grouped: [(key: String, title: String, roles: [Assistant])] {
        var byGroup: [String: [Assistant]] = [:]
        for role in store.assistants {
            byGroup[role.groupId ?? "ungrouped", default: []].append(role)
        }
        var out: [(key: String, title: String, roles: [Assistant])] = []
        for group in store.groups {
            if let roles = byGroup[group.id], !roles.isEmpty {
                out.append((group.id, group.name, roles))
            }
        }
        if let ungrouped = byGroup["ungrouped"], !ungrouped.isEmpty {
            out.append(("ungrouped", AppLocalized("Ungrouped"), ungrouped))
        }
        return out
    }

    var body: some View {
        List {
            if !expandedGroups.isEmpty {
                ForEach(grouped, id: \.key) { section in
                    Section {
                        // 折叠组里显示角色，否则只显示一行"N 人"占位
                        if expandedGroups.contains(section.key) {
                            ForEach(section.roles.sorted { $0.sortIndex < $1.sortIndex }) { role in
                                Button {
                                    detailRoleId = role.id
                                } label: {
                                    roleRow(role)
                                }
                                .buttonStyle(.plain)
                                .listRowBackground(MinisThemeList.rowFill)
                            }
                        } else {
                            Text("\(section.roles.count) \(section.roles.count == 1 ? AppLocalized("person") : AppLocalized("persons"))")
                                .font(.footnote)
                                .foregroundStyle(MinisThemeList.subtitle)
                                .listRowBackground(MinisThemeList.rowFill)
                        }                    } header: {
                        HStack(spacing: 6) {
                            Button {
                                if expandedGroups.contains(section.key) {
                                    expandedGroups.remove(section.key)
                                } else {
                                    expandedGroups.insert(section.key)
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: expandedGroups.contains(section.key) ? "chevron.down" : "chevron.right")
                                        .font(.system(size: 10, weight: .semibold))
                                    Text(section.title)
                                        .font(.headline)
                                    Spacer()
                                }
                                .foregroundStyle(MinisThemeList.title)
                            }
                        }
                    }
                }
            } else {
                Text(AppLocalized("No roles yet"))
                    .font(.footnote)
                    .foregroundStyle(MinisThemeList.subtitle)
                    .listRowBackground(MinisThemeList.rowFill)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .navigationTitle(AppLocalized("Roles"))
        // [T-roles-09-15] iOS 16: `navigationDestination(item:)` needs 17+,
        // so drive the detail page off an isPresented binding instead.
        .navigationDestination(isPresented: detailBinding) {
            if let roleId = detailRoleId,
               let role = store.assistants.first(where: { $0.id == roleId }) {
                RoleDetailView(role: role, store: store)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    creating = true
                } label: {
                    Image(systemName: "plus")
                }
                .tint(MinisThemeList.accent)
            }
        }
        .sheet(isPresented: $creating) {
            RoleEditorView(store: store)
        }
        .task { await store.load() }
        .refreshable { await store.load() }
    }

    private func roleRow(_ role: Assistant) -> some View {
        HStack(spacing: 12) {
            RoleAvatar(role: role, size: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(role.name.isEmpty ? AppLocalized("Untitled") : role.name)
                    .font(.body.weight(.medium))
                    .foregroundStyle(MinisThemeList.title)
                let n = store.sessionCount[role.id] ?? 0
                Text(n == 0 ? AppLocalized("No chats yet") : "\(n)")
                    .font(.footnote)
                    .foregroundStyle(MinisThemeList.subtitle)
            }
            Spacer()
            Image(systemName: "chevron.forward")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(MinisThemeList.meta)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - 角色详情页（QQ 通讯录式：信息 + 明面操作）

struct RoleDetailView: View {
    let role: Assistant
    @ObservedObject var store: RoleStore
    @Environment(\.dismiss) private var dismiss

    @State private var showEdit = false
    @State private var showDeleteConfirm = false
    @State private var showChats = false
    @State private var liveRole: Assistant = .init(name: "", avatarPath: nil, systemPrompt: "")
    /// [T-roles-chat-09-16] New chat created from the 发消息 button — bound to
    /// this role via createSession(assistantId:). Drives the push into AIChatView.
    @State private var startChatId: String? = nil

    var body: some View {
        List {
            Section {
                HStack(spacing: 16) {
                    RoleAvatar(role: liveRole, size: 64)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(liveRole.name.isEmpty ? AppLocalized("Untitled") : liveRole.name)
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(MinisThemeList.title)
                        let n = store.sessionCount[liveRole.id] ?? 0
                        Text(n == 0 ? AppLocalized("No chats yet") : "\(n)")
                            .font(.footnote)
                            .foregroundStyle(MinisThemeList.subtitle)
                    }
                }
                .padding(.vertical, 4)
            }
            .listRowBackground(MinisThemeList.rowFill)

            if !liveRole.systemPrompt.isEmpty {
                Section(AppLocalized("Prompt")) {
                    Text(liveRole.systemPrompt)
                        .font(.system(size: 13))
                        .foregroundStyle(MinisThemeList.title)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .listRowBackground(MinisThemeList.rowFill)
                }
            }

            Section {
                // [T-roles-chat-09-16] 发消息 — the primary action a QQ-style
                // contact card is missing here. Creates a new session bound to
                // this role and pushes into AIChatView. (Eager create: the app's
                // main New Chat uses a transient draft, but the role flow
                // intentionally creates the session so it lands in this role's
                // chat list immediately. An empty session left by backing out
                // is deletable now that deleteAssistant is fixed.)
                Button {
                    Task {
                        let s = await ChatStore.shared.createSession(modelId: "", assistantId: role.id)
                        startChatId = s.id
                    }
                } label: {
                    Label(AppLocalized("Start Chat"), systemImage: "bubble.left.fill")
                        .foregroundStyle(MinisThemeList.accent)
                }
                NavigationLink {
                    RoleSessionsView(role: role)
                } label: {
                    Label(AppLocalized("Chats"), systemImage: "bubble.left.and.bubble.right")
                        .foregroundStyle(MinisThemeList.title)
                }
                Button {
                    showEdit = true
                } label: {
                    Label(AppLocalized("Edit"), systemImage: "pencil")
                        .foregroundStyle(MinisThemeList.title)
                }
            }
            .listRowBackground(MinisThemeList.rowFill)

            Section {
                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Label(AppLocalized("Delete Role"), systemImage: "trash")
                        .foregroundStyle(MinisThemeList.accent)
                }
                .listRowBackground(MinisThemeList.rowFill)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .navigationTitle(role.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            liveRole = role
        }
        .onReceive(NotificationCenter.default.publisher(for: .assistantDidChange)) { _ in
            // Edit sheet saved → refresh the live copy so the detail header
            // (name/avatar/prompt) shows the change immediately (闭环).
            Task {
                await store.load()
                liveRole = store.assistants.first(where: { $0.id == role.id }) ?? liveRole
            }
        }
        .sheet(isPresented: $showEdit) {
            RoleEditorView(store: store, existing: liveRole)
        }
        .confirmationDialog(AppLocalized("Delete Role"), isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button(AppLocalized("Delete All"), role: .destructive) {
                Task {
                    await store.delete(liveRole)
                    dismiss()
                }
            }
            Button(AppLocalized("Cancel"), role: .cancel) {}
        } message: {
            Text(AppLocalized("This deletes the role, all its chats, and its memory. Cannot be undone."))
        }
        .navigationDestination(isPresented: Binding(
            get: { startChatId != nil },
            set: { if !$0 { startChatId = nil } }
        )) {
            if let id = startChatId {
                AIChatView(sessionId: id)
            }
        }
    }
}

// MARK: - 角色对话框列表

struct RoleSessionsView: View {
    let role: Assistant
    @State private var sessions: [ChatSession] = []
    /// [T-roles-chat-09-16] New chat started from the + toolbar button —
    /// bound to this role.
    @State private var startChatId: String? = nil

    var body: some View {
        List {
            if sessions.isEmpty {
                if #available(iOS 17, *) {
                    ContentUnavailableView(AppLocalized("No chats yet"), systemImage: "bubble.left.and.bubble.right")
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "bubble.left.and.bubble.right")
                            .font(.system(size: 36))
                            .foregroundStyle(MinisThemeList.subtitle)
                        Text(AppLocalized("No chats yet"))
                            .font(.subheadline)
                            .foregroundStyle(MinisThemeList.subtitle)
                    }
                    .frame(maxWidth: .infinity, minHeight: 180)
                }
            } else {
                ForEach(sessions) { session in
                    NavigationLink {
                        AIChatView(sessionId: session.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.title ?? AppLocalized("Untitled"))
                                .font(.body)
                                .foregroundStyle(MinisThemeList.title)
                                .lineLimit(1)
                            Text(session.updatedAt, format: .relative(presentation: .named))
                                .font(.caption)
                                .foregroundStyle(MinisThemeList.subtitle)
                        }
                    }
                    .listRowBackground(MinisThemeList.rowFill)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .navigationTitle(role.name)
        .navigationBarTitleDisplayMode(.inline)
        // [T-roles-chat-09-16] + starts a new chat bound to this role
        // (covers both the empty state and the populated list).
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task {
                        let s = await ChatStore.shared.createSession(modelId: "", assistantId: role.id)
                        // Refresh so the new chat lands in this list immediately.
                        sessions = await ChatStore.shared.sessions(forAssistant: role.id)
                        startChatId = s.id
                    }
                } label: {
                    Image(systemName: "square.and.pencil")
                        .foregroundStyle(MinisThemeList.accent)
                }
                .accessibilityLabel(AppLocalized("Start Chat"))
            }
        }
        .navigationDestination(isPresented: Binding(
            get: { startChatId != nil },
            set: { if !$0 { startChatId = nil } }
        )) {
            if let id = startChatId {
                AIChatView(sessionId: id)
            }
        }
        .task {
            sessions = await ChatStore.shared.sessions(forAssistant: role.id)
        }
    }
}

// MARK: - 创建 / 编辑（三样：名字 + 头像 + 提示词）

struct RoleEditorView: View {
    @ObservedObject var store: RoleStore
    var existing: Assistant?
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var prompt = ""
    @State private var avatarImage: UIImage?
    @State private var avatarChanged = false
    @State private var pickerItem: PhotosPickerItem?
    @State private var saving = false
    @State private var saveError: String? = nil
    @State private var showPhotoPicker = false

    private var isEditing: Bool { existing != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        Button {
                            showPhotoPicker = true
                        } label: {
                            avatarPreview
                        }
                        .buttonStyle(.plain)
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                    Text(AppLocalized("Tap avatar to choose a photo"))
                        .font(.caption)
                        .foregroundStyle(MinisThemeList.subtitle)
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                    if let saveError {
                        Text(saveError)
                            .font(.caption)
                            .foregroundStyle(MinisThemeList.accent)
                            .frame(maxWidth: .infinity)
                            .listRowBackground(Color.clear)
                    }
                }
                Section(AppLocalized("Name")) {
                    TextField(AppLocalized("Role name"), text: $name)
                        .font(.body)
                }
                Section(AppLocalized("Prompt")) {
                    TextEditor(text: $prompt)
                        .frame(minHeight: 140)
                        .font(.system(size: 14))
                }
            }
            .navigationTitle(isEditing ? AppLocalized("Edit Role") : AppLocalized("New Role"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(AppLocalized("Cancel")) { dismiss() }
                        .tint(MinisThemeList.accent)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(AppLocalized("Save")) { save() }
                        .font(.body.weight(.semibold))
                        .disabled(saving || name.trimmingCharacters(in: .whitespaces).isEmpty)
                        .tint(MinisThemeList.accent)
                }
            }
        }
        .onAppear(perform: seed)
        .photosPicker(isPresented: $showPhotoPicker, selection: $pickerItem, matching: .images)
        .onChange(of: pickerItem) { item in
            loadPicker(item)
        }
    }

    @ViewBuilder
    private var avatarPreview: some View {
        Group {
            if let img = avatarImage {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
            } else if let role = existing, let p = role.avatarPath, !p.isEmpty {
                RoleAvatar(path: p, size: 88)
            } else {
                Image(systemName: "person.crop.circle.badge.plus")
                    .font(.system(size: 44))
                    .foregroundStyle(MinisThemeList.accent)
                    .frame(width: 88, height: 88)
            }
        }
        .frame(width: 88, height: 88)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(MinisThemeList.accent.opacity(0.4), lineWidth: 1)
        )
    }

    private func seed() {
        guard let r = existing else { return }
        name = r.name
        prompt = r.systemPrompt
    }

    private func save() {
        saving = true
        Task {
            var avatarPath: String?
            if avatarChanged {
                // 原图存文件，不压缩、不限大小（醒醒 09-15）。
                if let img = avatarImage, let data = img.pngData() {
                    let file = "\(UUID().uuidString).png"
                    do {
                        // [T-avatar-09-16] Ensure the dir exists (MinisApp also
                        // creates it at launch; belt for installs where the
                        // group was wiped mid-life). Without this the write
                        // throws on a fresh install and was silently swallowed.
                        try FileManager.default.createDirectory(
                            at: RoleStore.avatarsDir,
                            withIntermediateDirectories: true)
                        try data.write(to: RoleStore.avatarsDir.appendingPathComponent(file))
                        avatarPath = file
                        saveError = nil
                    } catch {
                        // Don't swallow: a real product tells the user the
                        // photo didn't save and lets them retry.
                        saveError = AppLocalized("Couldn't save the photo. Try again.")
                        saving = false
                        return
                    }
                }
            } else {
                avatarPath = existing?.avatarPath // unchanged
            }
            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if let r = existing {
                await store.update(r, name: trimmedName, avatarPath: avatarPath, prompt: prompt)
            } else {
                await store.create(name: trimmedName, avatarPath: avatarPath, prompt: prompt)
            }
            saving = false
            dismiss()
        }
    }

    private func loadPicker(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task {
            if let data = try? await item.loadTransferable(type: Data.self),
               let img = UIImage(data: data) {
                avatarImage = img
                avatarChanged = true
            }
        }
    }
}
