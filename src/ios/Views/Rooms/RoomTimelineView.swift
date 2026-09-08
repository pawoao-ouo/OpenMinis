import SwiftUI

/// 小房间的时间轴视图——把这间屋的四类事件全按期数竖着排下来：
/// 挂牌纪念日 → 日记卡 → 梦境卡 → 信 → 任何房里写的备忘
///
/// 不是独立一页（从那扇门开就是 RoomHub），它是 Hub 默认 Tab 与"四类" Tab 的并列项。
/// 拉进去有 Top →Hero"`挂牌日 - 在一起 X 天`，然后按时间倒序滚所有的
/// 条目，每条都标识出类型（梦/日记/信/备忘）+ 一条柔边的卡片表示。
struct RoomTimelineView: View {

    let character: CharacterCard

    /// 一横条时间轴上的事件。kind/title/date/contentPreview 冷面停另陶，比再调 roomStore 取到的纯稳。
    struct Item: Identifiable {
        let id: UUID
        let kind: RoomKind
        let date: Date
        /// 只有一条短内容预览——进房回首的那张就弹实内容
        let preview: String
        let owner: RoomOwner
    }

    @ObservedObject private var rooms = RoomStore.shared
    @ObservedObject private var chars = CharacterStore.shared
    @ObservedObject private var studio = AppearanceStudio.shared

    /// 攒这角色四屋面的事件。每次渲染算一次——量不大（一房几人，总量一般一两百条），
    /// SwiftUI 每次进这种收集是能做的——就够小房间规模
    private var timeline: [Item] {
        var items: [Item] = []
        for kind in RoomKind.allCases {
            let roomId = RoomStore.roomId(kind: kind, characterId: character.id)
            for e in rooms.entries(in: roomId) {
                items.append(Item(
                    id: e.id,
                    kind: kind,
                    date: e.createdAt,
                    preview: e.text,
                    owner: e.owner
                ))
            }
        }
        return items.sorted { $0.date > $1.date }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                heroCard

                if timeline.isEmpty {
                    emptyState
                }

                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(timeline) { item in
                        TimelineRow(item: item, character: character)
                    }
                }
            }
            .padding(.vertical, 16)
            .padding(.horizontal, 20)
        }
        .background(ChatColors.background.ignoresSafeArea())
        .navigationTitle(AppLocalized("时间轴"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            for kind in RoomKind.allCases {
                rooms.loadIfNeeded(roomId: RoomStore.roomId(kind: kind, characterId: character.id))
            }
        }
    }

    private var heroCard: some View {
        let roomId = RoomStore.roomId(kind: .anniversary, characterId: character.id)
        let date = rooms.landmarkDate(in: roomId)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                avatarImage
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text(character.name)
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .foregroundStyle(ChatColors.primaryText)
                    Text(AppLocalized("在这间屋里"))
                        .font(.footnote)
                        .foregroundStyle(ChatColors.secondaryText)
                }
                Spacer()
            }
            if let d = date {
                Text(daysLine(for: d))
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(ChatColors.accent)
                    .padding(.top, 4)
            } else {
                Text(AppLocalized("挂牌日还没挂上。棚一下纪念。"))
                    .font(.footnote)
                    .foregroundStyle(ChatColors.secondaryText)
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(ChatColors.secondaryBg)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(ChatColors.inputIconBorder.opacity(0.5), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.04), radius: 5, x: 0, y: 2)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 32))
                .foregroundStyle(ChatColors.secondaryText)
            Text(AppLocalized("还没有记录。四间房里写点东西，都会列上来。"))
                .font(.footnote)
                .foregroundStyle(ChatColors.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var avatarImage: some View {
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
        .frame(width: 52, height: 52)
    }

    private func daysLine(for date: Date) -> String {
        let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: date), to: Date()).day ?? 0
        if days == 0 { return AppLocalized("就是今天") }
        if days > 0 { return AppLocalized("在一起 \(days) 天") }
        return AppLocalized("还有 \(-days) 天")
    }
}

private struct TimelineRow: View {
    let item: RoomTimelineView.ItemReady
    let character: CharacterCard

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // 左边根据 kind 上个亮点颜色
            Circle()
                .fill(color(for: item.kind))
                .frame(width: 10, height: 10)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(item.kind.displayName)
                        .font(.caption)
                        .foregroundStyle(ChatColors.accent)
                    Text(item.date, style: .date)
                        .font(.caption2)
                        .foregroundStyle(ChatColors.secondaryText)
                    Spacer()
                    Text(item.date, style: .time)
                        .font(.caption2)
                        .foregroundStyle(ChatColors.tertiaryText)
                }
                Text(item.preview)
                    .font(.subheadline)
                    .foregroundStyle(ChatColors.primaryText)
                    .lineLimit(3)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(ChatColors.secondaryBg)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(ChatColors.inputIconBorder.opacity(0.4), lineWidth: 1)
            )
        }
    }

    private func color(for kind: RoomKind) -> Color {
        switch kind {
        case .anniversary: return ChatColors.accent
        case .diary:       return ChatColors.accent.opacity(0.6)
        case .dream:       return ChatColors.accent.opacity(0.45)
        case .letter:      return ChatColors.accent.opacity(0.3)
        }
    }
}

/// 给内部 Item 一个对外能引用的别名，时间点 icon 神器
extension RoomTimelineView {
    typealias ItemReady = Item
}
