import SwiftUI

/// 从主侧栏导航来的 scoped 会话在这里过分拨——根据 target 选 loader。
/// 宁可 import 少一点：character/group loader 本地有，这个只做 switch。
struct ScopedChatDestination: View {
    let sessionId: String
    let target: SidebarAssistantScope

    @ObservedObject private var characters = CharacterStore.shared
    @ObservedObject private var groups = GroupStore.shared

    var body: some View {
        switch target {
        case .main:
            // 不该出现——scopedTarget() 已过滤。安全兜底到普通聊天页。
            AIChatView(sessionId: sessionId)
        case .character(let id):
            if let c = characters.characters.first(where: { $0.id == id }) {
                CharacterChatLoader(sessionId: sessionId, character: c)
            } else {
                AIChatView(sessionId: sessionId)
            }
        case .group(let id):
            if let g = groups.groups.first(where: { $0.id == id }) {
                GroupChatLoader(sessionId: sessionId, group: g)
            } else {
                AIChatView(sessionId: sessionId)
            }
        }
    }
}

/// kelivo 抽屉的「助手 × 话题」两级里，"助手"这一级在 OpenMinis 的缝法：
///
///   - 侧栏顶部钉一颗「当前助手」贴片，点开选人 sheet；
///   - 选中谁，下面的会话列表就只剩谁的（ContentView 用 sessionSourcePrefix
///     把列表换成 listSessionsForCharacter / listSessionsForGroup）；
///   - 新对话开在选中的人名下（FAB 在 scoped 模式下直接建带 source 的会话）。
///
/// 选择持久化在 UserDefaults("sidebar.scope")，格式：
/// "main" / "character:<uuid>" / "group:<uuid>"。
enum SidebarAssistantScope: Equatable {
    case main
    case character(UUID)
    case group(UUID)

    var rawValue: String {
        switch self {
        case .main: return "main"
        case .character(let id): return "character:\(id.uuidString)"
        case .group(let id): return "group:\(id.uuidString)"
        }
    }

    init(rawValue: String) {
        if rawValue.hasPrefix("character:"),
           let id = UUID(uuidString: String(rawValue.dropFirst("character:".count))) {
            self = .character(id)
        } else if rawValue.hasPrefix("group:"),
                  let id = UUID(uuidString: String(rawValue.dropFirst("group:".count))) {
            self = .group(id)
        } else {
            self = .main
        }
    }
}

/// 侧栏顶部那枚「当前助手」贴片。kelivo 里它固定在抽屉顶部带下箭头——
/// 我们也固定（用 safeAreaInset 挂在会话列表上方），点开出选人 sheet。
struct AssistantScopeTile: View {
    @Binding var scope: SidebarAssistantScope
    let soulName: String
    let onManage: () -> Void

    @ObservedObject private var characters = CharacterStore.shared
    @ObservedObject private var groups = GroupStore.shared
    @State private var showPicker = false

    var body: some View {
        Button { showPicker = true } label: {
            HStack(spacing: 10) {
                currentAvatar
                    .frame(width: 32, height: 32)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                Text(currentName)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(ChatColors.primaryText)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(AppearanceStudio.shared.color(.surface, scope: .chat))
            )
            .padding(.horizontal, 12)
            .padding(.top, 6)
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showPicker) {
            AssistantPickerSheet(scope: $scope, soulName: soulName, onManage: onManage)
                .presentationDetents([.medium, .large])
        }
    }

    private var currentName: String {
        switch scope {
        case .main:
            return soulName.isEmpty ? "Minis" : soulName
        case .character(let id):
            return characters.characters.first(where: { $0.id == id })?.name
                ?? soulName
        case .group(let id):
            return groups.groups.first(where: { $0.id == id })?.name
                ?? AppLocalized("群聊")
        }
    }

    @ViewBuilder private var currentAvatar: some View {
        switch scope {
        case .main:
            ZStack {
                Color.accentColor
                Text(String((soulName.isEmpty ? "M" : soulName).prefix(1)))
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
            }
        case .character(let id):
            if let c = characters.characters.first(where: { $0.id == id }) {
                ScopeAvatar(name: c.name, hue: c.hue, avatarFile: c.avatarImageFile, isGroup: false)
            } else {
                fallbackAvatar(name: soulName)
            }
        case .group(let id):
            if let g = groups.groups.first(where: { $0.id == id }) {
                ScopeAvatar(name: g.name, hue: g.hue, avatarFile: g.avatarImageFile, isGroup: true)
            } else {
                fallbackAvatar(name: soulName)
            }
        }
    }

    private func fallbackAvatar(name: String) -> some View {
        ZStack {
            Color.accentColor
            Text(String((name.isEmpty ? "M" : name).prefix(1)))
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
        }
    }
}

/// 头像：有图贴图（异步从缓存拿），没图色块+首字。群聊复用同款。
private struct ScopeAvatar: View {
    let name: String
    let hue: Double
    let avatarFile: String?
    let isGroup: Bool

    @State private var image: UIImage? = nil

    var body: some View {
        Group {
            if let img = image {
                Image(uiImage: img).resizable().scaledToFill()
            } else {
                ZStack {
                    Color(hue: hue, saturation: 0.55, brightness: 0.85)
                    Text(String(name.prefix(1)))
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                }
            }
        }
        .task {
            guard !isGroup else {
                // 群头像存在 Documents/groups/avatars/ 下，跟角色的目录不同。
                if let f = avatarFile,
                   let data = try? Data(contentsOf: FileManager.default
                    .urls(for: .documentDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("groups/avatars", isDirectory: true)
                    .appendingPathComponent(f)),
                   let img = UIImage(data: data) {
                    image = img
                }
                return
            }
            image = await CharacterStore.AvatarCache.shared.image(for: avatarFile)
        }
        .id(avatarFile ?? "none")
    }
}

/// 选人 sheet：默认（主 AI）在上，人物和群各自成组。点谁谁上场。
private struct AssistantPickerSheet: View {
    @Binding var scope: SidebarAssistantScope
    let soulName: String
    let onManage: () -> Void

    @ObservedObject private var characters = CharacterStore.shared
    @ObservedObject private var groups = GroupStore.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    pickRow(title: soulName.isEmpty ? "Minis" : soulName,
                            isSelected: scope == .main,
                            tint: Color.accentColor) {
                        scope = .main
                    }
                }
                if !characters.characters.isEmpty {
                    Section(AppLocalized("人物")) {
                        ForEach(characters.characters) { c in
                            pickRow(title: c.name,
                                    isSelected: scope == .character(c.id),
                                    tint: Color(hue: c.hue, saturation: 0.55, brightness: 0.85)) {
                                scope = .character(c.id)
                            }
                        }
                    }
                }
                if !groups.groups.isEmpty {
                    Section(AppLocalized("群聊")) {
                        ForEach(groups.groups) { g in
                            pickRow(title: g.name,
                                    isSelected: scope == .group(g.id),
                                    tint: Color(hue: g.hue, saturation: 0.55, brightness: 0.85),
                                    systemIcon: "person.2.fill") {
                                scope = .group(g.id)
                            }
                        }
                    }
                }
            }
            .navigationTitle(AppLocalized("和谁聊"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(AppLocalized("管理人物")) {
                        dismiss()
                        onManage()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(AppLocalized("取消")) { dismiss() }
                }
            }
        }
    }

    private func pickRow(title: String, isSelected: Bool, tint: Color,
                         systemIcon: String? = nil, action: @escaping () -> Void) -> some View {
        Button {
            action()
            dismiss()
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(tint)
                    if let icon = systemIcon {
                        Image(systemName: icon)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                    } else {
                        Text(String(title.prefix(1)))
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 30, height: 30)
                Text(title)
                    .foregroundStyle(ChatColors.primaryText)
                    .lineLimit(1)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
        .buttonStyle(.plain)
    }
}
