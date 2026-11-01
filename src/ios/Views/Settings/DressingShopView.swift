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
// Scope of this batch: the bubble path, end to end, plus the
// avatar-pendant path (four pale glowing rings, same
// card / detail / apply / save pattern as bubbles). Theme cards
// are visual placeholders for the theme batch (plain, not buttons,
// labelled as coming later — never a dead button), and the font /
// name-card tabs are honest "next batch" panels, not fake cards.
// Nothing here invents theme, font, or name-card records that
// the later batches have not defined yet.
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
    // `other` sits before 推荐 by user order: it is the home for
    // the non-dressing controls (language, app icon, launch,
    // input, chat behaviour) that the appearance merge stranded.
    // It is deliberately NOT a dressing category — it holds no
    // theme/bubble/pendant/font/name-card records — it is just
    // the reachable entry those controls were promised.
    case other, recommend, outfit, theme, bubble, pendant, font, namecard
    var id: String { rawValue }
    var title: String {
        switch self {
        case .other: return AppLocalized("其他设置")
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
    /// kept pack is reachable via a rail tag: 柔和 shows
    /// BUB-0001/0003, 简约 shows BUB-0006, 全部 shows all three
    /// kept packs. 清新 / 淡雅 are kept from the draft's shared
    /// rail (they match theme records there, not bubble packs)
    /// and are not invented per-batch taxonomy.
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
    @ObservedObject private var pendantStore = AvatarPendantStore.shared
    @ObservedObject private var outfitStore = DressingOutfitStore.shared

    @State private var category: DressingCategory = .recommend
    @State private var tag: DressingTag = .all
    @State private var detailPack: BubbleStylePack?
    @State private var detailPendant: AvatarPendant?
    @State private var sheetUp = false
    @State private var pendantSheetUp = false

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
                        case .other: OtherSettingsContentView()
                        case .recommend: recommendView
                        case .outfit: outfitView
                        case .theme: themeView
                        case .bubble: bubbleView
                        case .pendant: pendantView
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
            if let pendant = detailPendant {
                pendantDetailView(pendant)
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

    // Classification fix: the shared rail's 清新 / 淡雅 tags match
    // theme / pendant records in the draft, not bubble packs, so
    // on the bubble category they filtered to an empty grid with
    // no empty state. The bubble rail only offers 全部 plus the
    // tags at least one bubble pack actually carries (简约 / 柔和),
    // in the shared rail's order — a tag that shows nothing is
    // never offered. Other categories get their own rails when
    // their records exist; they do not borrow the bubble rail.
    private var bubbleTagRail: some View {
        let offered = DressingTag.allCases.filter { item in
            item.packTag == nil || bubblePackStore.packs.contains { $0.tag == item.packTag }
        }
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(offered) { item in
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

    // Recommend is a curated VIEW, not a category: it shows the
    // same bubble records the 聊天气泡 category owns, through the
    // same cards and the same detail sheet — one record, one apply
    // path, never a second copy of an item.
    private var recommendView: some View {
        VStack(alignment: .leading, spacing: 0) {
            nowWearingStrip
            bubbleTagRail
            sectionHeader(AppLocalized("聊天气泡"), jumpTo: .bubble)
            cardRow {
                ForEach(visiblePacks) { pack in bubbleCard(pack) }
            }
            sectionHeader(AppLocalized("头像挂件"), jumpTo: .pendant)
            cardRow {
                ForEach(pendantStore.pendants) { pendant in pendantCard(pendant) }
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

    // MARK: - Theme (next batch, honest panel, no fake cards)
    //
    // The old THM-0001..0003 placeholder cards are deleted: they
    // claimed numbers with no record behind them, which is exactly
    // the fake-card classification fault. Until the theme batch
    // defines real theme-set records, this category is an honest
    // next-batch panel like pendant / font / name card — not a
    // card, not a text row.
    //
    // Required connection for the theme batch, recorded here so
    // it cannot be reduced later: a theme set is NOT just bubbles.
    // A full-set preview must show wallpaper + bubbles + avatar +
    // input bar + pendant together, and applying a set must swap
    // all of those pieces together — never two bubble samples.
    // A theme set will reference a bubble by number and apply it
    // through BubbleStylePackStore.apply, alongside the set's
    // wallpaper, pendant, font, and input-bar pieces, each from
    // its own record. The bubble record owns no wallpaper,
    // pendant, or avatar field, so the set can compose them.
    // Retired appearance rows map here: palette colours, wallpaper
    // (backdrop), and the theme library (save / import / export).

    private var themeView: some View {
        nextBatchPanel(AppLocalized("主题"))
    }

    // MARK: - Bubble views

    private var bubbleView: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(AppLocalized("聊天气泡"), jumpTo: .bubble)
            cardRow {
                ForEach(visiblePacks) { pack in bubbleCard(pack) }
            }
            bubbleTagRail
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
        // Pack text colour wins when the pack carries one (a future
        // image-background pack's text must stay readable on its own
        // background); otherwise the theme's bubble text slot, as
        // before. Live chat resolves the same way (ChatColors), so
        // sample and live can never disagree on text colour.
        let textColour = style.textColor(isUser: isUser)
            ?? studio.color(isUser ? .bubbleText : .assistantBubbleText)
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
        // The one shared surface: solid colour, image background,
        // pattern, and decorations all come from this same record
        // here, in the detail preview (which calls this view), and
        // in live chat (which reads the same fields from the theme
        // pack apply() wrote). No surface draws a second version.
        return AnyView(Text(text)
            .font(.system(size: fontSize))
            .foregroundStyle(textColour)
            .padding(.horizontal, padding).padding(.vertical, 8)
            .background(BubblePackSurfaceBackground(
                shape: shape, colour: bubbleColour,
                imageFile: style.backgroundImageFile,
                pattern: style.pattern, patternOpacity: style.patternOpacity,
                textColour: textColour))
            .clipShape(shape)
            .modifier(BubbleBorderChrome(shape: shape, width: borderWidth))
            .overlay(BubblePackDecorationsView(decorations: style.decorations)))
    }

    // MARK: - Pendant views (enclosing rings, same pattern as bubbles)

    private var pendantView: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(AppLocalized("头像挂件"), jumpTo: .pendant)
            cardRow {
                ForEach(pendantStore.pendants) { pendant in pendantCard(pendant) }
            }
            sectionHeader(AppLocalized("全部挂件"), jumpTo: .pendant)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3),
                      spacing: 12) {
                ForEach(pendantStore.pendants) { pendant in pendantCard(pendant, fixedWidth: false) }
            }
            .padding(.horizontal, 16)
        }
    }

    private func pendantCard(_ pendant: AvatarPendant, fixedWidth: Bool = true) -> some View {
        let applied = pendantStore.appliedNumber == pendant.number
        return Button { openPendantDetail(pendant) } label: {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .topTrailing) {
                    pendantCardArt(pendant)
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
                Text(pendant.title)
                    .font(.system(size: 16))
                    .foregroundStyle(studio.color(.primaryText))
                    .padding(.top, 10)
                Text(pendant.number)
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

    /// One card's art: a large avatar with this pendant's ring
    /// on it — the same shared ring view live chat draws, so
    /// the card can never promise a different ring.
    private func pendantCardArt(_ pendant: AvatarPendant) -> some View {
        ZStack {
            avatarDisc(size: 72)
                .overlay(AvatarRingView(size: 72, color: pendant.color, imageFile: pendant.imageFile))
        }
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    private func openPendantDetail(_ pendant: AvatarPendant) {
        pendantSheetUp = false
        detailPendant = pendant
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) {
            if detailPendant?.number == pendant.number { pendantSheetUp = true }
        }
    }

    private func closePendantDetail() {
        pendantSheetUp = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            detailPendant = nil
        }
    }

    private func pendantDetailView(_ pendant: AvatarPendant) -> some View {
        VStack(spacing: 0) {
            ZStack {
                Text(AppLocalized("头像挂件"))
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(studio.color(.primaryText))
                HStack {
                    Button { closePendantDetail() } label: {
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

            VStack(alignment: .leading, spacing: 14) {
                // Large-avatar preview: the ring on a big
                // avatar, exactly as live chat draws it, plus one
                // sample chat row wearing the same ring.
                ZStack {
                    avatarDisc(size: 120)
                        .overlay(AvatarRingView(size: 120, color: pendant.color, imageFile: pendant.imageFile))
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 12)
                .padding(.bottom, 12)
                HStack(alignment: .center, spacing: 8) {
                    avatarDisc(size: 36)
                        .overlay(AvatarRingView(size: 36, color: pendant.color, imageFile: pendant.imageFile))
                    Text(AppLocalized("今天也想你"))
                        .font(.system(size: 16))
                        .foregroundStyle(studio.color(.assistantBubbleText))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(studio.color(.assistantBubble))
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    Spacer(minLength: 0)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .onTapGesture { pendantSheetUp.toggle() }

            if pendantSheetUp {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("\(pendant.title) · \(pendant.number)")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(studio.color(.primaryText))
                        Spacer(minLength: 0)
                    }
                    Text(AppLocalized("在大头像上看这款圆环，再确认换上；只换挂件，不动其他搭配。"))
                        .font(.system(size: 15))
                        .foregroundStyle(studio.color(.secondaryText))
                    Text(AppLocalized("组成：") + AppLocalized("圆环"))
                        .font(.system(size: 14))
                        .foregroundStyle(studio.color(.secondaryText))
                    HStack(spacing: 12) {
                        Button(AppLocalized("保存成搭配")) {
                            outfitStore.save(pendant: pendant)
                            closePendantDetail()
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
                            pendantStore.apply(pendant)
                            closePendantDetail()
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
        .animation(.easeOut(duration: 0.3), value: pendantSheetUp)
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
                            textColour: pack.style.textColor(isUser: isUser)
                                ?? studio.color(isUser ? .bubbleText : .assistantBubbleText),
                            borderWidth: isUser ? pack.style.userBorderWidth : pack.style.assistantBorderWidth)
            if isUser { avatarDisc(size: 36) }
            if !isUser { Spacer(minLength: 0) }
        }
    }
}

// MARK: - 其他设置（装扮店第一个入口，推荐前面）
//
// Home for exactly the eight non-dressing controls the appearance
// merge stranded: language, app icon, launch screen, return key,
// auto-focus after reply, expand thinking while streaming,
// auto-grouping, keep screen awake. Nothing else lives here: no
// font sizes (they belong to 字体), no light/dark mode, no row
// background, no bubble/theme controls — those already have
// their own shop homes or batches, and duplicating them here
// would recreate the duplicate-page fault this merge removed.
//
// Style and language are the shop's own, not the old studio
// page's: porcelain surface cards on the canvas background,
// 20pt bold section titles, secondary-text explanations, and
// Chinese labels throughout — the old studio labels mixed in
// other-language wording, and that mix is not carried over.
// Language names themselves stay as names.
// All bindings read and write the same UserDefaults keys the
// old studio page used, so switching here and switching there
// (where it is still reachable) can never disagree.

private struct OtherSettingsContentView: View {
    @ObservedObject private var studio = AppearanceStudio.shared

    @AppStorage("appLanguage") private var appLanguage: String = ""
    @AppStorage("appIconMode") private var appIconMode: Int = 0
    @AppStorage("launchScreen") private var launchScreen: Int = 0
    @AppStorage("returnKeyBehavior") private var returnKeyBehavior: Int = 0
    @AppStorage("chat.autoFocusAfterReply") private var autoFocusAfterReply: Bool = true
    @AppStorage("chat.autoExpandThinking") private var autoExpandThinking: Bool = true
    @AppStorage("keepScreenAwakeDuringTasks") private var keepScreenAwakeDuringTasks: Bool = false
    @State private var iconFailed = false

    private var autoGroupingBinding: Binding<Bool> {
        Binding(
            get: { UserDefaults.standard.bool(forKey: "autoGroupingEnabled") },
            set: { UserDefaults.standard.set($0, forKey: "autoGroupingEnabled") }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle(AppLocalized("语言"))
            sectionCard {
                ForEach(shopLanguages) { lang in
                    Button {
                        // Same reopen dance as the old studio page:
                        // the root view rebuilds on language change,
                        // so the pending reopen flag brings the user
                        // back to the appearance entry (now the shop).
                        UserDefaults.standard.set("appearance", forKey: "pendingSettingsReopen")
                        ViewModelCache.shared.suspendAllForTreeRemount()
                        appLanguage = lang.id
                        Bundle.setLanguage(lang.id.isEmpty ? nil : lang.id)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "globe")
                                .font(.system(size: 14))
                                .foregroundStyle(studio.color(.secondaryText))
                                .frame(width: 26)
                            Text(lang.name)
                                .font(.system(size: 15))
                                .foregroundStyle(studio.color(.primaryText))
                            Spacer(minLength: 0)
                            if appLanguage == lang.id {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(studio.color(.primaryText))
                            }
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            sectionTitle(AppLocalized("App 图标"))
            sectionCard {
                if UIApplication.shared.supportsAlternateIcons {
                    ForEach(shopIconOptions) { option in
                        Button {
                            guard appIconMode != option.id else { return }
                            let previous = appIconMode
                            appIconMode = option.id
                            iconFailed = false
                            UIApplication.shared.setAlternateIconName(option.iconName) { error in
                                DispatchQueue.main.async {
                                    guard error != nil else { return }
                                    // Same revert-on-failure rule as the
                                    // old studio page: a refused icon
                                    // must not stay ticked.
                                    appIconMode = previous
                                    iconFailed = true
                                }
                            }
                        } label: {
                            HStack(spacing: 14) {
                                if let img = UIImage(named: option.imageName) {
                                    Image(uiImage: img)
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                        .frame(width: 52, height: 52)
                                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.title)
                                        .font(.system(size: 15, weight: .medium))
                                        .foregroundStyle(studio.color(.primaryText))
                                    Text(option.subtitle)
                                        .font(.system(size: 13))
                                        .foregroundStyle(studio.color(.secondaryText))
                                }
                                Spacer(minLength: 0)
                                if appIconMode == option.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(studio.color(.primaryText))
                                        .font(.system(size: 16))
                                }
                            }
                            .padding(.vertical, 3)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if iconFailed {
                        Text(AppLocalized("换图标失败，请重试。"))
                            .font(.system(size: 13))
                            .foregroundStyle(studio.color(.secondaryText))
                            .padding(.top, 6)
                    }
                } else {
                    Text(AppLocalized("这台设备不支持换图标。"))
                        .font(.system(size: 15))
                        .foregroundStyle(studio.color(.secondaryText))
                }
            }

            sectionTitle(AppLocalized("启动时显示"))
            sectionCard {
                Picker("", selection: $launchScreen) {
                    Text(AppLocalized("自动")).tag(0)
                    Text(AppLocalized("上次会话")).tag(1)
                    Text(AppLocalized("新会话")).tag(2)
                    Text(AppLocalized("首页")).tag(3)
                }
                .pickerStyle(.menu)
                .tint(studio.color(.primaryText))
                Text(AppLocalized("打开 App 时显示什么。「自动」会在上次会话超过 15 分钟时开新会话。"))
                    .font(.system(size: 13))
                    .foregroundStyle(studio.color(.secondaryText))
            }

            sectionTitle(AppLocalized("输入"))
            sectionCard {
                Picker(AppLocalized("回车键"), selection: $returnKeyBehavior) {
                    Text(AppLocalized("换行")).tag(0)
                    Text(AppLocalized("发送")).tag(1)
                }
                .pickerStyle(.segmented)
                Text(AppLocalized("回车是换行还是发送。硬件键盘的 Shift+回车 永远是换行。"))
                    .font(.system(size: 13))
                    .foregroundStyle(studio.color(.secondaryText))
                Divider().padding(.vertical, 4)
                Toggle(AppLocalized("回复后自动聚焦"), isOn: $autoFocusAfterReply)
                    .tint(studio.color(.primaryText))
                Text(AppLocalized("模型回复完自动弹出键盘，方便接着问。不想被键盘打断就关掉。"))
                    .font(.system(size: 13))
                    .foregroundStyle(studio.color(.secondaryText))
            }

            sectionTitle(AppLocalized("聊天行为"))
            sectionCard {
                Toggle(AppLocalized("流式展开思考"), isOn: $autoExpandThinking)
                    .tint(studio.color(.primaryText))
                Text(AppLocalized("开着时，模型推理中的思考块自动展开，完成后收起。关掉就保持折叠，点一下才看。"))
                    .font(.system(size: 13))
                    .foregroundStyle(studio.color(.secondaryText))
                Divider().padding(.vertical, 4)
                Toggle(AppLocalized("自动分组"), isOn: autoGroupingBinding)
                    .tint(studio.color(.primaryText))
                Text(AppLocalized("首次生成会话标题时，顺便归进匹配的分组。每个会话只做一次，只用你已经建好的分组。"))
                    .font(.system(size: 13))
                    .foregroundStyle(studio.color(.secondaryText))
                Divider().padding(.vertical, 4)
                Toggle(AppLocalized("任务时屏幕常亮"), isOn: $keepScreenAwakeDuringTasks)
                    .tint(studio.color(.primaryText))
                Text(AppLocalized("有会话在跑任务时不熄屏。会更费电。"))
                    .font(.system(size: 13))
                    .foregroundStyle(studio.color(.secondaryText))
            }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 20, weight: .bold))
            .foregroundStyle(studio.color(.primaryText))
            .padding(.horizontal, 16)
            .padding(.top, 22)
            .padding(.bottom, 12)
    }

    private func sectionCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            content()
        }
        .padding(16)
        .background(studio.color(.surface))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 16)
    }
}

private struct ShopLanguageOption: Identifiable {
    let id: String
    let name: String
}

private let shopLanguages: [ShopLanguageOption] = [
    ShopLanguageOption(id: "", name: "跟随系统"),
    ShopLanguageOption(id: "en", name: "English"),
    ShopLanguageOption(id: "zh-Hans", name: "简体中文"),
    ShopLanguageOption(id: "zh-Hant", name: "繁體中文"),
    ShopLanguageOption(id: "ja", name: "日本語"),
    ShopLanguageOption(id: "ko", name: "한국어"),
    ShopLanguageOption(id: "es", name: "Español"),
    ShopLanguageOption(id: "fr", name: "Français"),
    ShopLanguageOption(id: "de", name: "Deutsch"),
    ShopLanguageOption(id: "ru", name: "Русский"),
]

private struct ShopIconOption: Identifiable {
    let id: Int
    let title: String
    let subtitle: String
    let iconName: String?
    let imageName: String
}

private let shopIconOptions: [ShopIconOption] = [
    ShopIconOption(id: 0, title: "饼干小熊", subtitle: "跟随系统",
                   iconName: nil, imageName: "AlternateIcons/AppIcon-Primary"),
    ShopIconOption(id: 1, title: "小蓝莓", subtitle: "蓝色头巾，眨眨眼",
                   iconName: "AppIcon-Light", imageName: "AlternateIcons/AppIcon-Light"),
    ShopIconOption(id: 2, title: "鱼鱼小猫", subtitle: "叼着粉色小鱼",
                   iconName: "AppIcon-Dark", imageName: "AlternateIcons/AppIcon-Dark"),
    ShopIconOption(id: 3, title: "小包子", subtitle: "红蝴蝶结，热乎乎",
                   iconName: "AppIcon-LegacyLight", imageName: "AlternateIcons/AppIcon-LegacyLight"),
    ShopIconOption(id: 4, title: "小懒猫", subtitle: "躺着，挂着小铃铛",
                   iconName: "AppIcon-LegacyDark", imageName: "AlternateIcons/AppIcon-LegacyDark"),
]
