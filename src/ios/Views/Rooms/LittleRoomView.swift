import SwiftUI

/// 小房间主页。先选角色，再进屋。
///
/// 规则（她定的）：角色不定死，可以随时换；房间数据跟角色走
/// （"anniversary|<characterId>" 的四类房）。
///
/// 审美走 friendly-ui：暖白+玫瑰粉+鼠尾草绿，软不塑料。
/// 所有颜色过主题的 AppearanceStudio scope（不写死色值）。
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
