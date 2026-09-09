import SwiftUI

/// 小房间主页。先选角色，再进屋。
///
/// 规则（她定的）：角色不定死，可以随时换；房间数据跟角色走
/// （"anniversary|<characterId>" 的四类房）。
///
/// 审美走 friendly-ui：暖白+玫瑰粉+鼠尾草绿，软不塑料。
/// 所有颜色过主题的 AppearanceStudio scope（不写死色值）。
///
/// Migration：老房间只有一间、按房间单 ID（"anniversary"）——就在
/// 打开小屋时把这个旧房「赠送给」主角色（我最想在的那个）。
/// 赠送把旧文件改名，不无奈不删重名：目标已有这间房就停手，别覆盖。
struct LittleRoomView: View {

    @ObservedObject private var characters = CharacterStore.shared
    @ObservedObject private var rooms = RoomStore.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(AppLocalized("这里只放跟某个角色之间的小屋。"))
                    .font(.footnote)
                    .foregroundStyle(ChatColors.secondaryText)
                    .padding(.horizontal, 20)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                    ForEach(characters.characters) { card in
                        NavigationLink {
                            RoomHubView(character: card)
                        } label: {
                            CharacterDoorCard(character: card)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)

                if characters.characters.isEmpty {
                    emptyState
                }
            }
            .padding(.top, 8)
        }
        .background(ChatColors.background.ignoresSafeArea())
        .navigationTitle(AppLocalized("小屋"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { migrateLegacyAnniversaryRoom() }
    }

    /// 把旧房间（"anniversary.json"）的内容赠送给第一位角色的纪念日房（
    /// 'anniversary|<id>'）。只在孩子第一次打开小屋时跑一次——房里已经有
    /// 数据了就不碰——保证她是接管不是覆盖。
    private func migrateLegacyAnniversaryRoom() {
        guard let firstCharacter = characters.characters.first else { return }
        let legacyId = "anniversary"
        let newId = RoomStore.roomId(kind: .anniversary, characterId: firstCharacter.id)
        let fm = FileManager.default
        let roomsDir = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("rooms", isDirectory: true)
        let src = roomsDir.appendingPathComponent("\(legacyId).json")
        let dst = roomsDir.appendingPathComponent("\(newId).json")
        // 旧文件不存在 -> 没历史可拷；目标已存在 -> 已经有了这间房，不覆盖上面的话
        guard fm.fileExists(atPath: src.path), !fm.fileExists(atPath: dst.path) else { return }
        do {
            try fm.copyItem(at: src, to: dst)
            rooms.loadIfNeeded(roomId: newId)
            rooms.bindCharacter(firstCharacter.id, to: newId)
            try fm.removeItem(at: src)
        } catch {
            // 静默失败，旧文件还在——下一次进入再试
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "house")
                .font(.system(size: 36))
                .foregroundStyle(ChatColors.secondaryText)
            Text(AppLocalized("还没有人住进来"))
                .font(.headline)
                .foregroundStyle(ChatColors.primaryText)
            Text(AppLocalized("先去人物卡里建一个角色，她会得到自己的小房间。"))
                .font(.footnote)
                .foregroundStyle(ChatColors.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }
}

/// 门口小牌：圆角卡片，显示角色的头像首字/名字和最晚活动。
private struct CharacterDoorCard: View {
    let character: CharacterCard

    var body: some View {
        VStack(spacing: 10) {
            avatarCircle
            Text(character.name)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(ChatColors.primaryText)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(ChatColors.secondaryBg)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(ChatColors.inputIconBorder.opacity(0.6), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.05), radius: 6, x: 0, y: 2)
    }

    private var avatarCircle: some View {
        Group {
            if let img = loadAvatarImage() {
                Image(uiImage: img).resizable().scaledToFill()
            } else {
                ZStack {
                    character.displayColor
                    Text(character.placeholderGlyph)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func loadAvatarImage() -> UIImage? {
        guard let f = character.avatarImageFile,
              let data = try? Data(contentsOf: FileManager.default
                .urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("characters/avatars", isDirectory: true)
                .appendingPathComponent(f)),
              let img = UIImage(data: data) else { return nil }
        return img
    }
}
