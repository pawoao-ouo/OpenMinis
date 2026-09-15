import SwiftUI
import UIKit

// MARK: - RoleStore (observable wrapper around ChatStore assistant CRUD)

@MainActor
final class RoleStore: ObservableObject {
    @Published var assistants: [Assistant] = []
    @Published var groups: [AssistantGroup] = []
    @Published var sessionCount: [String: Int] = [:]

    private let store = ChatStore.shared

    /// Physical home for avatar files: <appGroup>/avatars/. Same dir as
    /// AIChatViewModel.minisAvatarsDir — kept here as the single reference
    /// so the role UI and the identity layer cannot diverge.
    static var avatarsDir: URL {
        AIChatViewModel.minisAvatarsDir
    }

    /// Delete an avatar file by its DB-stored name (relative to avatarsDir).
    /// No-op for nil / empty / legacy "emoji:…" paths — those never had a file.
    static func removeAvatarFile(_ name: String?) {
        guard let name, !name.isEmpty, !name.hasPrefix("emoji:") else { return }
        let url = avatarsDir.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
    }

    func load() async {
        let list = await store.listAssistants()
        let grp = await store.listAssistantGroups()
        assistants = list
        groups = grp
        var counts: [String: Int] = [:]
        for r in list {
            counts[r.id] = await store.sessionCount(forAssistant: r.id)
        }
        sessionCount = counts
    }

    func create(name: String, avatarPath: String?, prompt: String, groupId: String? = nil) async {
        await store.createAssistant(name: name, avatarPath: avatarPath, systemPrompt: prompt, groupId: groupId)
        await refreshSystemAndList()
    }

    func update(_ role: Assistant, name: String, avatarPath: String?, prompt: String, groupId: String? = nil) async {
        let oldAvatar = role.avatarPath
        await store.updateAssistant(role.id, name: name, avatarPath: avatarPath, systemPrompt: prompt, groupId: groupId)
        // [T-avatar-09-16] Photo changed → delete the OLD file so it can't leak.
        // save() already wrote the new file before this call. Helper is a
        // no-op for nil / unchanged / legacy-emoji paths.
        if oldAvatar != avatarPath {
            Self.removeAvatarFile(oldAvatar)
        }
        await refreshSystemAndList()
    }

    func delete(_ role: Assistant) async {
        await store.deleteAssistant(role.id)
        await refreshSystemAndList()
    }

    /// [T-roles-09-15 闭环] Every persona write must re-populate
    /// SoulStore.cachedAssistants so `identitySection` (the system prompt)
    /// picks up the new identity, and post the change notification UI
    /// observes. Then refresh our own list/counters.
    private func refreshSystemAndList() async {
        await SoulStore.refreshAssistantCache()
        await load()
    }
}

// MARK: - RoleAvatar (image-only; 醒醒 no emoji avatars)

struct RoleAvatar: View {
    let role: Assistant?
    var path: String?
    var size: CGFloat = 38
    @State private var image: UIImage?

    init(role: Assistant, size: CGFloat = 38) {
        self.role = role
        self.path = role.avatarPath
        self.size = size
    }

    init(path: String?, size: CGFloat = 38) {
        self.role = nil
        self.path = path
        self.size = size
    }

    var body: some View {
        Group {
            if let img = image {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: size * 0.42, weight: .medium))
                    .foregroundStyle(MinisThemeList.accent)
            }
        }
        .frame(width: size, height: size)
        .background(MinisThemeList.rowFill, in: RoundedRectangle(cornerRadius: size * 0.25, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: size * 0.25, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
                .stroke(MinisThemeList.accent.opacity(0.25), lineWidth: 0.7)
        )
        .task { await load() }
    }

    private func load() async {
        let p = path ?? role?.avatarPath
        guard let p, !p.isEmpty else { return }
        let url = RoleStore.avatarsDir.appendingPathComponent(p)
        // [T-avatar-09-16] Render a downsampled thumbnail, not the full-size
        // original — list rows would otherwise hold multi-megapixel UIImages
        // (醒醒: storage stays uncompressed; only display is scaled). Reuse
        // the shared ThumbnailCache (ImageIO downsample + NSCache + memory
        // pressure eviction). Crisp at size × screen scale.
        let scale = UIScreen.main.scale
        if let img = await ThumbnailCache.shared.thumbnail(for: url.path, maxSize: size * scale) {
            image = img
        }
    }
}
