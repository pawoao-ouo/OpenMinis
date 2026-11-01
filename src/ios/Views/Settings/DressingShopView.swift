import SwiftUI

// MARK: - 装扮店（dressing shop, bubble batch)
//
// Layout replicated from the dressing-page draft, not reinterpreted:
// sticky 52pt top bar (back, centred title, search/profile icons),
// 44pt scrollable category tab rail with a centred 26x3pt underline
// on the active tab, an in-flow scrollable tag rail, vertically
// stacked sections (header + chevron jumping to the category view),
// horizontally scrolling card rows where the next card peeks at
// the right edge, tall theme cards (125x182) and square bubble
// cards (125x122), a 3-column grid on the bubble category page,
// and a detail page that slides in from the right with a bottom
// sheet sliding up 260ms later. The shop stays mounted under the
// detail overlay, so back restores the same tab and scroll position
// — the scroll state is never torn down, it is simply covered.
//
// Colours come only from the theme variables (AppearanceStudio
// roles); this view hard-codes no hex, no palette of its own.
// No emoji, no prices, no SVIP, no gift, no QQ artwork or names.
//
// Scope of this batch: the bubble path, end to end. Theme cards
// are visual placeholders for the theme batch (plain, not buttons,
// labelled as coming later — never a dead button), and the pendant /
// font / name-card tabs are honest "next batch" panels, not fake
// cards. Nothing here invents theme, pendant, font, or name-card
// records that the later batches have not defined yet.
//
// Connections (no gaps): applying a pack goes through
// BubbleStylePackStore.apply, which writes the full structural
// record (including the pack shape) to the live theme pack, so
// real chat bubbles change — not just the samples. The in-use
// mark, the now-wearing strip, and the detail sheet all read the
// same store. Saving as an outfit goes through
// DressingOutfitStore, whose rows survive theme change and reset
// and can only be removed by deleting by number.

private enum DressingCategory: String, CaseIterable, Identifiable {
    case recommend, outfit, theme, bubble, pendant, font, namecard
    var id: String { rawValue }
    var title: String {
        switch self {
        case .recommend: return AppLocalized("推荐")
        case .outfit: return AppLocalized("搭配灵感")
        case .theme: return AppLocalized("主题")
        case .bubble: return AppLocalized("聊天气泡")
        case .pendant: return AppLocalized("头像挂件")
        case .font: return AppLocalized("字体")
        case .namecard: return AppLocalized("名片")
        }
    }
}

private enum DressingTag: String, CaseIterable, Identifiable {
    case all, simple, soft, fresh, refined
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return AppLocalized("全部")
        case .simple: return AppLocalized("简约")
        case .soft: return AppLocalized("柔和")
        case .fresh: return AppLocalized("清新")
        case .refined: return AppLocalized("淡雅")
        }
    }
    /// The pack tag value this rail tag matches. Nil = no filtering.
    /// Bubble packs use the draft's tags (柔和 / 简约), so every
    /// pack is reachable via a rail tag: 柔和 shows BUB-0001..0004,
    /// 简约 shows BUB-0005..0006, 全部 shows all six. 清新 / 淡雅
    /// are kept from the draft's shared rail (they match theme /
    /// pendant records there, not bubble packs in this batch) and
    /// are not invented per-batch taxonomy.
    var packTag: String? {
        switch self {
        case .all: return nil
        case .simple: return "简约"
        case .soft: return "柔和"
        case .fresh: return "清新"
        case .refined: return "淡雅"
        }
    }
}

struct DressingShopView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var studio = AppearanceStudio.shared
    @ObservedObject private var bubblePackStore = BubbleStylePackStore.shared
    @ObservedObject private var outfitStore = DressingOutfitStore.shared

    @State private var category: DressingCategory = .recommend
    @State private var tag: DressingTag = .all
    @State private var detailPack: BubbleStylePack?
    @State private var sheetUp = false

    private var visiblePacks: [BubbleStylePack] {
        guard let wanted = tag.packTag else { return bubblePackStore.packs }
        return bubblePackStore.packs.filter { $0.tag == wanted }
    }

    private var appliedPack: BubbleStylePack? {
        guard let number = bubblePackStore.appliedNumber else { return nil }
        return bubblePackStore.pack(number: number)
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                topBar
                tabRail
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        switch category {
                        case .recommend: recommendView
                        case .outfit: outfitView
                        case .theme: themeView
                        case .bubble: bubbleView
                        case .pendant: nextBatchPanel(AppLocalized("头像挂件"))
                        case .font: nextBatchPanel(AppLocalized("字体"))
                        case .namecard: nextBatchPanel(AppLocalized("名片"))
                        }
                    }
                    .padding(.bottom, 32)
                }
                .scrollIndicators(.hidden)
            }
            .background(studio.color(.canvas))

            if let pack = detailPack {
                bubbleDetailView(pack)
                    .transition(.move(edge: .trailing))
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .animation(.easeOut(duration: 0.32), value: detailPack != nil)
    }

    // MARK: - Top bar (52pt, draft measurement)

    private var topBar: some View {
        ZStack {
            Text(AppLocalized("装扮"))
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(studio.color(.primaryText))
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(studio.color(.primaryText))
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
                // Header icons are display-only in this batch:
                // the draft's search/profile glyphs, not buttons,
                // so there is no dead control pretending to search.
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 17))
                    .foregroundStyle(studio.color(.primaryText))
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 17))
                    .foregroundStyle(studio.color(.primaryText))
            }
            .padding(.horizontal, 16)
        }
        .frame(height: 52)
        .background(studio.color(.surface))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(studio.color(.border).opacity(0.4))
                .frame(height: 0.5)
        }
    }

    // MARK: - Category tab rail (44pt, underline active)

    private var tabRail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 26) {
                ForEach(DressingCategory.allCases) { item in
                    Button { category = item } label: {
                        VStack(spacing: 2) {
                            Text(item.title)
                                .font(.system(size: 17,
                                              weight: category == item ? .bold : .regular))
                                .foregroundStyle(category == item
                                    ? studio.color(.primaryText)
                                    : studio.color(.secondaryText))
                            Rectangle()
                                .fill(studio.color(.primaryText))
                                .frame(width: 26, height: 3)
                                .cornerRadius(1.5)
                                .opacity(category == item ? 1 : 0)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
        .frame(height: 44)
        .background(studio.color(.surface))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(studio.color(.border).opacity(0.4))
                .frame(height: 0.5)
        }
    }

    // MARK: - Tag rail (in-flow, 36pt pills)

    private var tagRail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(DressingTag.allCases) { item in
                    Button { tag = item } label: {
                        Text(item.title)
                            .font(.system(size: 15))
                            .foregroundStyle(tag == item
                                ? studio.color(.surface)
                                : studio.color(.secondaryText))
                            .padding(.horizontal, 16)
                            .frame(height: 36)
                            .background(tag == item
                                ? studio.color(.primaryText)
                                : studio.color(.mutedSurface))
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 18)
    }

    // MARK: - Sections and rows

    private func sectionHeader(_ title: String, jumpTo: DressingCategory) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(studio.color(.primaryText))
            Spacer(minLength: 0)
            Button { category = jumpTo } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 17))
                    .foregroundStyle(studio.color(.secondaryText))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.top, 22)
        .padding(.bottom, 12)
    }

    private func cardRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                content()
            }
            .padding(.horizontal, 16)
        }
    }

    // MARK: - Recommend

    private var recommendView: some View {
        VStack(alignment: .leading, spacing: 0) {
            nowWearingStrip
            sectionHeader(AppLocalized("主题"), jumpTo: .theme)
            cardRow {
                ForEach(themePlaceholders) { theme in themePlaceholderCard(theme) }
            }
            tagRail
            sectionHeader(AppLocalized("聊天气泡"), jumpTo: .bubble)
            cardRow {
                ForEach(visiblePacks) { pack in bubbleCard(pack) }
            }
            Text(AppLocalized("点卡片进入详情预览，确认后再换上；标签条按心情筛选当前页的卡片。"))
                .font(.system(size: 13))
                .foregroundStyle(studio.color(.secondaryText))
                .padding(.horizontal, 16)
                .padding(.top, 10)
        }
    }

    private var nowWearingStrip: some View {
        HStack(spacing: 10) {
            Text(AppLocalized("现在穿着"))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(studio.color(.primaryText))
            if let pack = appliedPack {
                Text("\(pack.title) · \(pack.number)")
                    .font(.system(size: 14))
                    .foregroundStyle(studio.color(.secondaryText))
            } else {
                Text(AppLocalized("还没选款式，点一款先看看"))
                    .font(.system(size: 14))
                    .foregroundStyle(studio.color(.secondaryText))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // MARK: - Theme placeholders (next batch, not buttons)
    //
    // Required connection for the theme batch, recorded here so
    // it cannot be reduced later: a theme set is NOT just bubbles.
    // A full-set preview must show wallpaper + bubbles + avatar +
    // input bar + pendant together, and applying a set must swap
    // all of those pieces together — never two bubble samples.
    // This batch's bubble record does not block that wiring: a
    // theme set will reference a bubble by number and apply it
    // through BubbleStylePackStore.apply, alongside the set's
    // wallpaper, pendant, font, and input-bar pieces, each from
    // its own record. The bubble record owns no wallpaper,
    // pendant, or avatar field, so the set can compose them.

    private struct ThemePlaceholder: Identifiable {
        var id: String { number }
        let number: String
        let title: String
    }

    private var themePlaceholders: [ThemePlaceholder] {
        [
            ThemePlaceholder(number: "THM-0001", title: "瓷白晨光"),
            ThemePlaceholder(number: "THM-0002", title: "圆点纸纹"),
            ThemePlaceholder(number: "THM-0003", title: "横线信纸"),
        ]
    }

    private func themePlaceholderCard(_ theme: ThemePlaceholder) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text(AppLocalized("今天也想你"))
                    .font(.system(size: 11))
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .background(studio.color(.surface))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                HStack {
                    Spacer(minLength: 0)
                    Text(AppLocalized("今天也想你"))
                        .font(.system(size: 11))
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .background(studio.color(.userBubble))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                Spacer(minLength: 0)
                Capsule()
                    .fill(studio.color(.mutedSurface))
                    .frame(height: 18)
            }
            .padding(10)
            .frame(width: 125, height: 182)
            .background(studio.color(.surface))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            Text(theme.title)
                .font(.system(size: 16))
                .foregroundStyle(studio.color(.primaryText))
                .padding(.top, 10)
            Text(theme.number)
                .font(.system(size: 13))
                .foregroundStyle(studio.color(.secondaryText))
                .padding(.top, 3)
            Text(AppLocalized("稍后推出"))
                .font(.system(size: 13))
                .foregroundStyle(studio.color(.secondaryText))
                .padding(.top, 3)
        }
        .frame(width: 125)
    }

    private var themeView: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(AppLocalized("主题"), jumpTo: .theme)
            cardRow {
                ForEach(themePlaceholders) { theme in themePlaceholderCard(theme) }
            }
        }
    }

    // MARK: - Bubble views

    private var bubbleView: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(AppLocalized("聊天气泡"), jumpTo: .bubble)
            cardRow {
                ForEach(visiblePacks) { pack in bubbleCard(pack) }
            }
            tagRail
            sectionHeader(AppLocalized("全部气泡"), jumpTo: .bubble)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3),
                      spacing: 12) {
                ForEach(visiblePacks) { pack in bubbleCard(pack, fixedWidth: false) }
            }
            .padding(.horizontal, 16)
        }
    }

    private func bubbleCard(_ pack: BubbleStylePack, fixedWidth: Bool = true) -> some View {
        let applied = bubblePackStore.appliedNumber == pack.number
        return Button { openDetail(pack) } label: {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .topTrailing) {
                    bubbleCardArt(pack)
                        .frame(height: 122)
                        .frame(width: fixedWidth ? 125 : nil)
                        .background(studio.color(.surface))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    if applied {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(studio.color(.primaryText))
                            .background(studio.color(.surface))
                            .clipShape(Circle())
                            .padding(8)
                    }
                }
                Text(pack.title)
                    .font(.system(size: 16))
                    .foregroundStyle(studio.color(.primaryText))
                    .padding(.top, 10)
                Text(pack.number)
                    .font(.system(size: 13))
                    .foregroundStyle(studio.color(.secondaryText))
                    .padding(.top, 3)
                if applied {
                    Text(AppLocalized("正在用"))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(studio.color(.primaryText))
                        .padding(.top, 3)
                }
            }
            .frame(width: fixedWidth ? 125 : nil, alignment: .leading)
        }
        .buttonStyle(.plain)
    }

    /// One card's art: the same avatar disc and the same sample
    /// text on every card, changing only the pack — so cards are
    /// compared on the pack, never on copy or avatar.
    private func bubbleCardArt(_ pack: BubbleStylePack) -> some View {
        VStack(spacing: 8) {
            bubbleSampleRow(pack: pack, isUser: false)
            bubbleSampleRow(pack: pack, isUser: true)
        }
        .padding(10)
    }

    private func avatarDisc(size: CGFloat) -> some View {
        Circle()
            .fill(studio.color(.accent).opacity(0.2))
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.45))
                    .foregroundStyle(studio.color(.secondaryText))
            )
    }

    private func bubbleSampleRow(pack: BubbleStylePack, isUser: Bool) -> some View {
        let style = pack.style
        let bubbleColour = studio.color(isUser ? .userBubble : .assistantBubble)
        let textColour = studio.color(isUser ? .bubbleText : .assistantBubbleText)
        let borderWidth = isUser ? style.userBorderWidth : style.assistantBorderWidth
        return HStack(alignment: .center, spacing: 6) {
            if !isUser { avatarDisc(size: 28) }
            if isUser { Spacer(minLength: 0) }
            bubbleShapeView(pack: pack, isUser: isUser,
                            text: AppLocalized("今天也想你"),
                            fontSize: 12, padding: 8,
                            bubbleColour: bubbleColour, textColour: textColour,
                            borderWidth: borderWidth)
            if isUser { avatarDisc(size: 28) }
            if !isUser { Spacer(minLength: 0) }
        }
    }

    /// One bubble drawn with the pack's own outline and chrome, so
    /// shop, detail, and live chat all draw the same shape. The
    /// stitch pack is the dashed border in all three places — the
    /// draft shows it as a dashed border only, with no ribbon tab
    /// — so no sample promises anything live chat does not draw.
    private func bubbleShapeView(pack: BubbleStylePack, isUser: Bool, text: String,
                                 fontSize: CGFloat, padding: CGFloat,
                                 bubbleColour: Color, textColour: Color,
                                 borderWidth: CGFloat) -> some View {
        let style = pack.style
        let radius = CGFloat(isUser ? style.userRadius : style.assistantRadius)
        let shape = MinisBubbleShape(style: style.liveStyle(), radius: radius,
                                     tailOnTrailing: isUser, packKind: style.packShape)
        return AnyView(Text(text)
            .font(.system(size: fontSize))
            .foregroundStyle(textColour)
            .padding(.horizontal, padding).padding(.vertical, 8)
            .background(bubbleColour)
            .clipShape(shape)
            .modifier(BubbleBorderChrome(shape: shape, width: borderWidth)))
    }

    // MARK: - Outfit view

    private var outfitView: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(AppLocalized("我的搭配"), jumpTo: .outfit)
            if outfitStore.outfits.isEmpty {
                Text(AppLocalized("还没有保存的搭配。在气泡详情里点“保存成搭配”，就会出现在这里。"))
                    .font(.system(size: 15))
                    .foregroundStyle(studio.color(.secondaryText))
                    .padding(.horizontal, 16)
            } else {
                ForEach(outfitStore.outfits) { outfit in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(outfit.title)
                                .font(.system(size: 16))
                                .foregroundStyle(studio.color(.primaryText))
                            Text("\(outfit.number) · \(outfit.summary)")
                                .font(.system(size: 13))
                                .foregroundStyle(studio.color(.secondaryText))
                        }
                        Spacer(minLength: 0)
                        Button(AppLocalized("按编号删除")) {
                            outfitStore.delete(number: outfit.number)
                        }
                        .font(.system(size: 14))
                        .foregroundStyle(studio.color(.secondaryText))
                        .buttonStyle(.plain)
                    }
                    .padding(14)
                    .background(studio.color(.surface))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                }
            }
            Text(AppLocalized("换主题、重置都不会清掉这里；只有按编号删，才会删掉那一行。"))
                .font(.system(size: 13))
                .foregroundStyle(studio.color(.secondaryText))
                .padding(.horizontal, 16)
                .padding(.top, 10)
        }
    }

    // MARK: - Next-batch panels (honest placeholders, no fake cards)

    private func nextBatchPanel(_ title: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(studio.color(.primaryText))
            Text(AppLocalized("下一批做：详情预览、换上、保存成搭配，都会按气泡这批同一套路接上。"))
                .font(.system(size: 15))
                .foregroundStyle(studio.color(.secondaryText))
        }
        .padding(16)
    }

    // MARK: - Detail preview (slide-in page + bottom sheet)

    private func openDetail(_ pack: BubbleStylePack) {
        sheetUp = false
        detailPack = pack
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) {
            if detailPack?.number == pack.number { sheetUp = true }
        }
    }

    private func closeDetail() {
        sheetUp = false
        // Sheet slide-down is 0.3s; removing the page sooner
        // would cut the sheet off mid-animation.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            detailPack = nil
        }
    }

    private func bubbleDetailView(_ pack: BubbleStylePack) -> some View {
        VStack(spacing: 0) {
            ZStack {
                Text(AppLocalized("聊天气泡"))
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(studio.color(.primaryText))
                HStack {
                    Button { closeDetail() } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(studio.color(.primaryText))
                    }
                    .buttonStyle(.plain)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
            }
            .frame(height: 52)
            .background(studio.color(.surface))

            // Preview area: tapping it toggles the sheet, exactly
            // as the draft does. The sheet itself is outside this
            // gesture, so its buttons never toggle it by accident.
            VStack(alignment: .leading, spacing: 14) {
                detailMessage(pack: pack, isUser: false,
                              text: AppLocalized("今天也想你。早上出门的时候还在想，晚上回来第一句还是想跟你说这个。"))
                detailMessage(pack: pack, isUser: true,
                              text: AppLocalized("今天也想你。这句短的、长的、放在不同气泡里，看着都不一样，你挑一个最顺眼的。"))
                detailMessage(pack: pack, isUser: false,
                              text: AppLocalized("好，那就这款。"))
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                        .foregroundStyle(studio.color(.secondaryText))
                    Spacer(minLength: 0)
                    Image(systemName: "mic")
                        .foregroundStyle(studio.color(.secondaryText))
                }
                .padding(.horizontal, 16)
                .frame(height: 52)
                .background(studio.color(.field))
                .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            }
            .padding(16)
            .onTapGesture { sheetUp.toggle() }

            if sheetUp {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("\(pack.title) · \(pack.number)")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(studio.color(.primaryText))
                        Spacer(minLength: 0)
                    }
                    Text(AppLocalized("在模拟聊天里看这款的长句和短句，确认后再换上；只换气泡，不动其他搭配。"))
                        .font(.system(size: 15))
                        .foregroundStyle(studio.color(.secondaryText))
                    Text(AppLocalized("组成：") + pack.composition.joined(separator: " · "))
                        .font(.system(size: 14))
                        .foregroundStyle(studio.color(.secondaryText))
                    HStack(spacing: 12) {
                        Button(AppLocalized("保存成搭配")) {
                            outfitStore.save(bubblePack: pack)
                            closeDetail()
                        }
                        .font(.system(size: 16))
                        .foregroundStyle(studio.color(.primaryText))
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(studio.color(.primaryText), lineWidth: 1.5)
                        )
                        .buttonStyle(.plain)
                        Button(AppLocalized("换上这款")) {
                            bubblePackStore.apply(pack)
                            closeDetail()
                        }
                        .font(.system(size: 16))
                        .foregroundStyle(studio.color(.surface))
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(studio.color(.primaryText))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .buttonStyle(.plain)
                    }
                    .padding(.top, 6)
                }
                .padding(20)
                .background(
                    studio.color(.surface),
                    in: UnevenRoundedRectangle(
                        cornerRadii: RectangleCornerRadii(
                            topLeading: 22, bottomLeading: 0,
                            bottomTrailing: 0, topTrailing: 22))
                )
                .transition(.move(edge: .bottom))
            }
        }
        .background(studio.color(.canvas))
        .animation(.easeOut(duration: 0.3), value: sheetUp)
    }

    private func detailMessage(pack: BubbleStylePack, isUser: Bool, text: String) -> some View {
        HStack(alignment: .center, spacing: 8) {
            if !isUser { avatarDisc(size: 36) }
            if isUser { Spacer(minLength: 0) }
            bubbleShapeView(pack: pack, isUser: isUser, text: text,
                            fontSize: 16, padding: 14,
                            bubbleColour: studio.color(isUser ? .userBubble : .assistantBubble),
                            textColour: studio.color(isUser ? .bubbleText : .assistantBubbleText),
                            borderWidth: isUser ? pack.style.userBorderWidth : pack.style.assistantBorderWidth)
            if isUser { avatarDisc(size: 36) }
            if !isUser { Spacer(minLength: 0) }
        }
    }
}
