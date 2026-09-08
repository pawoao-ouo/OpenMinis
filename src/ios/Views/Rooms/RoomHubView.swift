import SwiftUI

/// 一个角色的小房间主页：挂她的名字，里面二开门四类房。
/// 这里就是"房间与角色联动"的总括——选好的角色不用换，所有房数据都往她名下灌。
struct RoomHubView: View {

    let character: CharacterCard

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    avatarCircle
                    VStack(alignment: .leading, spacing: 3) {
                        Text(character.name)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(ChatColors.primaryText)
                        Text(AppLocalized("和她有关的都在这间屋子里"))
                            .font(.footnote)
                            .foregroundStyle(ChatColors.secondaryText)
                    }
                }
                .padding(.vertical, 6)
            }

            Section {
                ForEach(RoomKind.allCases) { kind in
                    NavigationLink {
                        roomDestination(kind)
                    } label: {
                        HStack {
                            Image(systemName: kind.iconName)
                                .foregroundStyle(ChatColors.accent)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(kind.displayName)
                                    .foregroundStyle(ChatColors.primaryText)
                                Text(kind.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(ChatColors.secondaryText)
                            }
                        }
                    }
                }
            } header: {
                Text(AppLocalized("这间屋子有什么"))
            }
        }
        .background(ChatColors.background.ignoresSafeArea())
        .navigationTitle(character.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func roomDestination(_ kind: RoomKind) -> some View {
        let roomId = RoomStore.roomId(kind: kind, characterId: character.id)
        switch kind {
        case .anniversary:
            AnniversaryRoomView(roomId: roomId, character: character)
        case .diary:
            DiaryRoomView(roomId: roomId, character: character)
        case .dream:
            DreamRoomView(roomId: roomId, character: character)
        case .letter:
            LetterRoomView(roomId: roomId, character: character)
        }
    }

    private var avatarCircle: some View {
        Group {
            if let f = character.avatarImageFile,
               let data = try? Data(contentsOf: FileManager.default
                .urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("characters/avatars", isDirectory: true)
                .appendingPathComponent(f)),
               let img = UIImage(data: data) {
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
        .frame(width: 48, height: 48)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

extension RoomKind {
    var iconName: String {
        switch self {
        case .anniversary: return "calendar"
        case .diary:       return "book"
        case .dream:       return "moon.stars"
        case .letter:      return "envelope"
        }
    }

    var subtitle: String {
        switch self {
        case .anniversary: return AppLocalized("挂牌日、日历标记、跟这间屋主人哪天的数数")
        case .diary:       return AppLocalized("小卡片、可折、按日期查")
        case .dream:       return AppLocalized("梦里看到的，醒来后还热乎的")
        case .letter:      return AppLocalized("想写就写，不选中发")
        }
    }
}
