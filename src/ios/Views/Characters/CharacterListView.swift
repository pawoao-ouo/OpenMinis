import SwiftUI

/// 角色宫格页（ST 小酒馆形）。
///
/// 一行 2-3 个卡，头像大图、名字、记忆行数、人设一句话摘要、
/// 长按可删/改名。头顶摆「新建」走sheet，左上角可以括回房间。
/// 点进任意角色 → 该角色的会话抽屉页（CharacterConversationsView）。
struct CharacterListView: View {

    @ObservedObject private var store = CharacterStore.shared
    @ObservedObject private var groups = GroupStore.shared
    @State private var showNewCharacter = false
    @State private var showNewGroup = false
    // kelivo 的 Assistants/Topics 两 tab 的翻版——人物 或 群聊
    @State private var showsGroups = false

    private let columns = [
        GridItem(.adaptive(minimum: 140), spacing: 12)
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                Picker("", selection: $showsGroups) {
                    Text(AppLocalized("人物")).tag(false)
                    Text(AppLocalized("群聊")).tag(true)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 12)

                LazyVGrid(columns: columns, spacing: 12) {
                    if !showsGroups {
                        ForEach(store.characters) { character in
                            NavigationLink(value: NavTarget.character(character.id)) {
                                CharacterCardView(character: character)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button(AppLocalized("删角色"), role: .destructive) {
                                    store.remove(id: character.id)
                                }
                            }
                        }
                    } else {
                        ForEach(groups.groups) { group in
                            NavigationLink(value: NavTarget.group(group.id)) {
                                GroupCardView(group: group)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button(AppLocalized("删群"), role: .destructive) {
                                    groups.remove(id: group.id)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
            }
            .padding(.vertical, 12)
        }
        .background(AppearanceStudio.shared.color(.canvas, scope: .chat))
        .navigationTitle(AppLocalized("人物卡"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    if showsGroups { showNewGroup = true } else { showNewCharacter = true }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showNewCharacter) {
            NavigationStack { CharacterEditorView(character: nil) }
                .presentationDetents([.large])
        }
        .sheet(isPresented: $showNewGroup) {
            NavigationStack { GroupEditorView(group: nil) }
        }
        .navigationDestination(for: NavTarget.self) { target in
            switch target {
            case .character(let id):
                if let c = store.characters.first(where: { $0.id == id }) {
                    CharacterConversationsView(character: c)
                }
            case .group(let id):
                if let g = groups.groups.first(where: { $0.id == id }) {
                    GroupConversationsView(group: g)
                }
            }
        }
    }

    private enum NavTarget: Hashable {
        case character(UUID)
        case group(UUID)
    }
}

///网格里的角色卡。解法色块：上中下——头像、名字、人设首句/记忆行数
private struct CharacterCardView: View {
    let character: CharacterCard

    @State private var avatarImage: UIImage? = nil

    private var memoryExcerpt: String {
        let memory = character.memory.trimmingCharacters(in: .whitespacesAndNewlines)
        if memory.isEmpty { return AppLocalized("还没记忆") }
        let firstLine = memory.split(separator: "\n").first.map(String.init) ?? memory
        return String(firstLine.prefix(20))
    }

    var body: some View {
        VStack(spacing: 8) {
            AvatarSquareView(image: avatarImage, name: character.name, hue: character.hue, size: 80)
                .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
            Text(character.name)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(ChatColors.primaryText)
                .lineLimit(1)
            Text(memoryExcerpt)
                .font(.caption2)
                .foregroundStyle(ChatColors.secondaryText)
                .lineLimit(1)
        }
        .timerFramePadding()
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(AppearanceStudio.shared.color(.surface, scope: .chat))
        )
        .task {
            avatarImage = await CharacterStore.AvatarCache.shared.image(for: character.avatarImageFile)
        }
        .id(character.avatarImageFile ?? "no-img")
    }
}

/// 纸片化头像：有图贴图，没图用色块+首字
private struct AvatarSquareView: View {
    let image: UIImage?
    let name: String
    let hue: Double
    let size: CGFloat

    var body: some View {
        Group {
            if let img = image {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Color(hue: hue, saturation: 0.55, brightness: 0.85)
                    Text(String(name.prefix(1)))
                        .font(.system(size: size * 0.45, weight: .semibold))
                        .foregroundStyle(Color.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
    }
}

/// 群卡（列表里的长样）：叠 2 个成员脸 + 群名 + 成员数
private struct GroupCardView: View {
    let group: GroupCard
    @ObservedObject private var chars = CharacterStore.shared

    var body: some View {
        VStack(spacing: 8) {
            avatars
                .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
            Text(group.name)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(ChatColors.primaryText)
                .lineLimit(1)
            Text("\(group.memberIds.count) 人")
                .font(.caption2)
                .foregroundStyle(ChatColors.secondaryText)
        }
        .timerFramePadding()
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(AppearanceStudio.shared.color(.surface, scope: .chat))
        )
    }

    @ViewBuilder private var avatars: some View {
        let members = chars.characters.filter { group.memberIds.contains($0.id) }
        HStack(spacing: -10) {
            ForEach(members.prefix(3)) { c in
                ZStack {
                    Circle().fill(Color(hue: c.hue, saturation: 0.55, brightness: 0.85))
                    Text(String(c.name.prefix(1)))
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.white)
                }
                .frame(width: 48, height: 48)
                .overlay(Circle().stroke(Color(uiColor: .systemBackground), lineWidth: 2))
            }
            if members.count > 3 {
                Text("+\(members.count - 3)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color.gray))
            }
        }
        .frame(height: 52)
    }
}

private extension View {
    /// 统一卡片内垫（不出奇防震但要风格一致）
    func timerFramePadding() -> some View {
        self.padding(.vertical, 12).frame(maxWidth: .infinity)
    }
}
