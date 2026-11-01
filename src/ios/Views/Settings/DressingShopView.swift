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
// BubbleStylePackStore.apply(_:for:), which writes that side's
// structural record (including that side's pack shape) to the
// live theme pack, so real chat bubbles change — not just the
// samples — for that side only. The in-use mark, the
// now-wearing strip, and the detail sheet all read the same
// per-side store, keyed by the side the picker selects.
// Saving as an outfit goes through
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

/// Which part a font card applies to. Fonts are per part,
/// not one global pick: the message part (chat message body)
/// and the UI part (everything that reads the global family)
/// can wear different families or uploaded fonts, and changing
/// one part never moves the other.
private enum DressingFontPart: String, CaseIterable, Identifiable {
    case message, ui
    var id: String { rawValue }
    var title: String {
        switch self {
        case .message: return AppLocalized("消息")
        case .ui: return AppLocalized("界面")
        }
    }
}

struct DressingShopView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var studio = AppearanceStudio.shared
    @ObservedObject private var bubblePackStore = BubbleStylePackStore.shared
    @ObservedObject private var pendantStore = AvatarPendantStore.shared
    @ObservedObject private var outfitStore = DressingOutfitStore.shared
    @ObservedObject private var fontSettings = FontSettings.shared
    @ObservedObject private var uploadedFontStore = UploadedFontStore.shared
    @State private var fontPart: DressingFontPart = .message
    @State private var showFontPicker = false
    @State private var fontImportFailed = false
    // Observed so a persona switch (or a user-profile rename via
    // the studio's published display name) redraws every side
    // label in this shop at once — side names are never stored.
    @ObservedObject private var personaStore = PersonaStore.shared

    @State private var category: DressingCategory = .recommend
    @State private var tag: DressingTag = .all
    // Which side the shop is currently editing. One shared
    // selection for the whole shop: picking a card or opening a
    // detail always edits this side, and only this side. The
    // detail captures it on open, so switching the picker while
    // a detail is open cannot retarget that detail mid-apply.
    @State private var editingSide: DressingSide = .assistant
    @State private var detailPack: BubbleStylePack?
    @State private var detailPackSide: DressingSide = .assistant
    @State private var detailPendant: AvatarPendant?
    @State private var detailPendantSide: DressingSide = .assistant
    @State private var sheetUp = false
    @State private var pendantSheetUp = false
    // Bumped on SOUL.md / persona-change notifications so a
    // same-persona rename (which neither PersonaStore nor the
    // studio publishes) still refreshes side labels. Read by
    // sidePicker; the value itself is never shown.
    @State private var sideLabelTick = 0

    private var visiblePacks: [BubbleStylePack] {
        guard let wanted = tag.packTag else { return bubblePackStore.packs }
        return bubblePackStore.packs.filter { $0.tag == wanted }
    }

    private func appliedPack(for side: DressingSide) -> BubbleStylePack? {
        bubblePackStore.appliedPack(for: side)
    }

    /// Side names, resolved live (see DressingSide): the AI
    /// side follows the current persona, the user side follows
    /// the current user profile. If both resolve to the same
    /// string, the picker disambiguates with a generic role word
    /// — never with a hardcoded person's name.
    private var assistantSideName: String { DressingSide.assistant.displayName }
    private var userSideName: String { DressingSide.user.displayName }

    private func sidePickerLabel(for side: DressingSide) -> String {
        let name = side.displayName
        guard assistantSideName == userSideName else { return name }
        return side.isUser ? "\(name) · \(AppLocalized("用户"))" : "\(name) · AI"
    }

    /// The pack a card / detail row draws for one side: the
    /// previewed pack for the side being edited, the side's own
    /// applied pack for the other side (or the previewed pack
    /// when that side has never picked one, so the row is never
    /// empty). A card therefore never claims that applying a
    /// pack to one side changes the other side's row.
    private func rowPack(_ preview: BubbleStylePack, isUser: Bool) -> BubbleStylePack {
        let rowSide: DressingSide = isUser ? .user : .assistant
        if rowSide == editingSide { return preview }
        return appliedPack(for: rowSide) ?? preview
    }

    // MARK: - Side picker (per-side editing)

    /// One picker for the whole shop: bubbles and pendants are
    /// both edited per side, and the picker always shows which
    /// side the next tap will change. Labels are the sides'
    /// live names (current persona / current user profile),
    /// never stored names. Reading sideLabelTick here is what
    /// makes a SOUL.md rename refresh this picker.
    private var sidePicker: some View {
        // Read both refresh sources here so this picker
        // re-resolves its (dynamic) side names on a persona
        // switch (published currentPersonaID) and on a
        // same-persona SOUL.md rename (sideLabelTick bump).
        let _ = sideLabelTick
        let _ = personaStore.currentPersonaID
        return VStack(alignment: .leading, spacing: 8) {
            Text(AppLocalized("改哪一边"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(studio.color(.primaryText))
            Picker("", selection: $editingSide) {
                Text(sidePickerLabel(for: .assistant)).tag(DressingSide.assistant)
                Text(sidePickerLabel(for: .user)).tag(DressingSide.user)
            }
            .pickerStyle(.segmented)
            Text(AppLocalized("先选一边，再点卡片换上；改一边不会动另一边。"))
                .font(.footnote)
                .foregroundStyle(studio.color(.secondaryText))
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
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
                        case .font: fontView
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
        // Same-persona rename arrives via SOUL.md, not via a
        // published store value: bump the side-label tick so the
        // picker and strip re-resolve their (dynamic) names.
        .onReceive(NotificationCenter.default.publisher(for: .soulMdChanged)) { _ in
            sideLabelTick += 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .personaDidChange)) { _ in
            sideLabelTick += 1
        }
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
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
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
            sidePicker
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
        VStack(alignment: .leading, spacing: 6) {
            Text(AppLocalized("现在穿着"))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(studio.color(.primaryText))
            ForEach(DressingSide.allCases, id: \.self) { side in
                HStack(spacing: 10) {
                    Text(sidePickerLabel(for: side))
                        .font(.system(size: 14))
                        .foregroundStyle(studio.color(.primaryText))
                    if let pack = appliedPack(for: side) {
                        Text("\(pack.title) · \(pack.number)")
                            .font(.system(size: 14))
                            .foregroundStyle(studio.color(.secondaryText))
                    } else {
                        Text(AppLocalized("还没选款式"))
                            .font(.system(size: 14))
                            .foregroundStyle(studio.color(.secondaryText))
                    }
                    if let pendant = pendantStore.applied(for: side) {
                        Text("\(pendant.title) · \(pendant.number)")
                            .font(.system(size: 14))
                            .foregroundStyle(studio.color(.secondaryText))
                    }
                    Spacer(minLength: 0)
                }
            }
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
            sidePicker
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
        // "In use" is per editing side: a pack worn only by the
        // other side does not get a tick while this side is
        // being edited, or the shop would claim a tap changed
        // nothing / changed everything.
        let applied = bubblePackStore.appliedNumber(for: editingSide) == pack.number
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
                    .font(.callout)
                    .foregroundStyle(studio.color(.primaryText))
                    .padding(.top, 10)
                Text(pack.number)
                    .font(.footnote)
                    .foregroundStyle(studio.color(.secondaryText))
                    .padding(.top, 3)
                if applied {
                    Text(AppLocalized("正在用"))
                        .font(.footnote.weight(.semibold))
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
            // The editing side's row previews this pack; the
            // other side's row shows what that side actually
            // wears (see rowPack), so the card never promises
            // that one tap changes both sides.
            bubbleSampleRow(pack: rowPack(pack, isUser: false), isUser: false)
            bubbleSampleRow(pack: rowPack(pack, isUser: true), isUser: true)
        }
        .padding(10)
    }

    // Shop samples use the REAL avatar for that side — the
    // current persona's avatar for the AI side, the user-profile
    // avatar for the user side — never a grey placeholder disc.
    // A placeholder person icon made the cards look like an
    // unfinished shell and hid whether the ring/bubble really
    // fits the avatar. PersonAvatarView resolves the image
    // dynamically, so a persona or profile change follows here
    // too; its own applied ring is shown, exactly as live chat.
    private func sampleAvatar(isUser: Bool, size: CGFloat) -> some View {
        PersonAvatarView(kind: isUser ? .user : .assistant, size: size)
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
            if !isUser { sampleAvatar(isUser: false, size: 28) }
            if isUser { Spacer(minLength: 0) }
            bubbleShapeView(pack: pack, isUser: isUser,
                            text: AppLocalized("今天也想你"),
                            fontSize: 12, padding: 8,
                            bubbleColour: bubbleColour, textColour: textColour,
                            borderWidth: borderWidth)
            if isUser { sampleAvatar(isUser: true, size: 28) }
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
            sidePicker
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
        // Per editing side, same rule as bubble cards.
        let applied = pendantStore.appliedNumber(for: editingSide) == pendant.number
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
                    .font(.callout)
                    .foregroundStyle(studio.color(.primaryText))
                    .padding(.top, 10)
                Text(pendant.number)
                    .font(.footnote)
                    .foregroundStyle(studio.color(.secondaryText))
                    .padding(.top, 3)
                if applied {
                    Text(AppLocalized("正在用"))
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(studio.color(.primaryText))
                        .padding(.top, 3)
                }
            }
            .frame(width: fixedWidth ? 125 : nil, alignment: .leading)
        }
        .buttonStyle(.plain)
    }

    /// One card's art: the edited side's REAL avatar with this
    /// pendant's ring on it — the same shared ring view live
    /// chat draws, so the card can never promise a different
    /// ring. showPendant is off so the side's currently applied
    /// ring does not stack under the previewed ring.
    private func pendantCardArt(_ pendant: AvatarPendant) -> some View {
        ZStack {
            PersonAvatarView(kind: editingSide.isUser ? .user : .assistant,
                             size: 72, showPendant: false)
                .overlay(AvatarRingView(size: 72, color: pendant.color, imageFile: pendant.imageFile))
        }
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    private func openPendantDetail(_ pendant: AvatarPendant) {
        pendantSheetUp = false
        // Capture the side being edited: the detail applies to
        // this side even if the picker moves underneath it.
        detailPendantSide = editingSide
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
                    .font(.title3.weight(.bold))
                    .foregroundStyle(studio.color(.primaryText))
                HStack {
                    Button { closePendantDetail() } label: {
                        Image(systemName: "chevron.left")
                            .font(.headline)
                            .foregroundStyle(studio.color(.primaryText))
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
            }
            .frame(height: 52)
            .background(studio.color(.surface))

            VStack(alignment: .leading, spacing: 14) {
                // Side label, resolved live: this detail edits
                // one side only, and the preview below shows
                // THAT side's avatar — the current persona's
                // avatar for the AI side, the user-profile avatar
                // for the user side — never a generic disc and
                // never the other side's picture.
                Text(AppLocalized("正在改：") + sidePickerLabel(for: detailPendantSide))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(studio.color(.primaryText))
                // Large-avatar preview: the previewed ring on
                // this side's big avatar, plus one sample chat
                // row wearing the same ring. showPendant is off
                // so the side's currently applied ring does not
                // stack under the previewed ring.
                ZStack {
                    PersonAvatarView(kind: detailPendantSide.isUser ? .user : .assistant,
                                     size: 120, showPendant: false)
                        .overlay(AvatarRingView(size: 120, color: pendant.color, imageFile: pendant.imageFile))
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 12)
                .padding(.bottom, 12)
                HStack(alignment: .center, spacing: 8) {
                    PersonAvatarView(kind: detailPendantSide.isUser ? .user : .assistant,
                                     size: 36, showPendant: false)
                        .overlay(AvatarRingView(size: 36, color: pendant.color, imageFile: pendant.imageFile))
                    Text(AppLocalized("今天也想你"))
                        .font(.callout)
                        .foregroundStyle(studio.color(detailPendantSide.isUser ? .bubbleText : .assistantBubbleText))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(studio.color(detailPendantSide.isUser ? .userBubble : .assistantBubble))
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
                    Text(AppLocalized("在大头像上看这款圆环，再确认换上；只换这一边的挂件，另一边不动，其他搭配也不动。"))
                        .font(.subheadline)
                        .foregroundStyle(studio.color(.secondaryText))
                    Text(AppLocalized("组成：") + AppLocalized("圆环"))
                        .font(.system(size: 14))
                        .foregroundStyle(studio.color(.secondaryText))
                    if !pendant.detail.isEmpty {
                        Text(pendant.detail)
                            .font(.system(size: 14))
                            .foregroundStyle(studio.color(.secondaryText))
                    }
                    HStack(spacing: 12) {
                        Button(AppLocalized("保存成搭配")) {
                            outfitStore.save(pendant: pendant)
                            closePendantDetail()
                        }
                        .font(.callout)
                        .foregroundStyle(studio.color(.primaryText))
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(studio.color(.primaryText), lineWidth: 1.5)
                        )
                        .buttonStyle(.plain)
                        Button(AppLocalized("换上这款")) {
                            pendantStore.apply(pendant, for: detailPendantSide)
                            closePendantDetail()
                        }
                        .font(.callout)
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
                    .font(.subheadline)
                    .foregroundStyle(studio.color(.secondaryText))
                    .padding(.horizontal, 16)
            } else {
                ForEach(outfitStore.outfits) { outfit in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(outfit.title)
                                .font(.callout)
                                .foregroundStyle(studio.color(.primaryText))
                            Text("\(outfit.number) · \(outfit.summary)")
                                .font(.footnote)
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
                .font(.footnote)
                .foregroundStyle(studio.color(.secondaryText))
                .padding(.horizontal, 16)
                .padding(.top, 10)
        }
    }

    // MARK: - Fonts (cards with previews, per part, 10-15pt)

    /// Font section: family cards with live previews, per part
    /// (message / UI), plus size controls. Message size is the
    /// user's 10-15pt range (default 13pt, never 17pt): the six
    /// preview cards ARE the control — tap a card to set that
    /// size, and the card's sample text renders at exactly that
    /// size, so the card never promises a size live chat does
    /// not use. Input and UI sizes keep their stepped axes.
    /// Uploaded fonts are preview cards too, rendered in the
    /// uploaded file's own font, never as a bare file name.
    private var fontView: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(AppLocalized("字体"), jumpTo: .font)
            // Part picker, same pattern as the side picker:
            // pick a part first, then a card applies to it only.
            VStack(alignment: .leading, spacing: 8) {
                Text(AppLocalized("改哪一部分"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(studio.color(.primaryText))
                Picker("", selection: $fontPart) {
                    ForEach(DressingFontPart.allCases) { part in
                        Text(part.title).tag(part)
                    }
                }
                .pickerStyle(.segmented)
                Text(AppLocalized("先选一部分，再点卡片换上；改一部分不会动另一部分。"))
                    .font(.footnote)
                    .foregroundStyle(studio.color(.secondaryText))
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)

            // Message size cards: 10-15pt, one card per size.
            Text(AppLocalized("消息字号"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(studio.color(.primaryText))
                .padding(.horizontal, 16)
                .padding(.top, 22)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3),
                      spacing: 12) {
                ForEach([10, 11, 12, 13, 14, 15], id: \.self) { pt in
                    fontSizeCard(pt: pt)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            // Per-part stepped sizes for input and UI.
            VStack(alignment: .leading, spacing: 12) {
                fontScaleRow(label: AppLocalized("输入字号"),
                             level: $fontSettings.chatInputScale)
                fontScaleRow(label: AppLocalized("界面字号"),
                             level: $fontSettings.appBaseScale)
            }
            .padding(.horizontal, 16)
            .padding(.top, 22)

            // Family cards: built-ins first, then uploads.
            sectionHeader(AppLocalized("全部字体"), jumpTo: .font)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3),
                      spacing: 12) {
                ForEach(UploadedFontStore.builtIns, id: \.number) { item in
                    fontFamilyCard(number: item.number, title: item.family.title,
                                   font: item.family.font(size: 20))
                }
                ForEach(uploadedFontStore.fonts) { font in
                    uploadedFontCard(font)
                }
            }
            .padding(.horizontal, 16)

            // Upload: a real picker for .ttf/.otf files. A file
            // that cannot be registered adds no card (see
            // UploadedFontStore.importFont), and a failed import
            // shows a plain message instead of a phantom card.
            Button { showFontPicker = true } label: {
                Text(AppLocalized("上传字体文件"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(studio.color(.primaryText))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(studio.color(.surface))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.top, 22)
            Text(AppLocalized("支持 .ttf / .otf 文件；上传的字体会变成一张预览卡，点卡片换上。"))
                .font(.footnote)
                .foregroundStyle(studio.color(.secondaryText))
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 32)
        }
        .sheet(isPresented: $showFontPicker) {
            FontFilePicker(
                onPick: { url in
                    showFontPicker = false
                    if uploadedFontStore.importFont(from: url) == nil {
                        fontImportFailed = true
                    }
                },
                onCancel: { showFontPicker = false }
            )
        }
        .alert(AppLocalized("这个字体文件用不了"), isPresented: $fontImportFailed) {
            Button(AppLocalized("知道了"), role: .cancel) {}
        } message: {
            Text(AppLocalized("文件没有加进来，可能是格式不对或字体损坏。"))
        }
    }

    private func fontSizeCard(pt: Int) -> some View {
        let applied = Int(fontSettings.messagePointSize) == pt
        return Button { fontSettings.messagePointSize = CGFloat(pt) } label: {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    Text(AppLocalized("今天也想你"))
                        .font(MinisThemeShape.messageFont(size: CGFloat(pt)))
                        .foregroundStyle(studio.color(.primaryText))
                        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
                        .padding(10)
                        .background(studio.color(.surface))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    if applied {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(studio.color(.primaryText))
                            .background(studio.color(.surface))
                            .clipShape(Circle())
                            .padding(8)
                    }
                }
                Text("\(pt)pt")
                    .font(.callout)
                    .foregroundStyle(studio.color(.primaryText))
                if applied {
                    Text(AppLocalized("正在用"))
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(studio.color(.primaryText))
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func fontScaleRow(label: String, level: Binding<FontScaleLevel>) -> some View {
        let cases = FontScaleLevel.allCases
        let index = cases.firstIndex(of: level.wrappedValue) ?? cases.firstIndex(of: .default) ?? 0
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(studio.color(.primaryText))
                Spacer(minLength: 0)
                Text(level.wrappedValue.label)
                    .font(.footnote)
                    .foregroundStyle(studio.color(.secondaryText))
            }
            HStack(spacing: 12) {
                Button {
                    if index > 0 { level.wrappedValue = cases[index - 1] }
                } label: {
                    Text("A")
                        .font(.footnote)
                        .foregroundStyle(studio.color(.secondaryText))
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Slider(value: Binding(
                    get: { Double(index) },
                    set: { newValue in
                        let idx = min(cases.count - 1, max(0, Int(newValue.rounded())))
                        level.wrappedValue = cases[idx]
                    }
                ), in: 0...Double(cases.count - 1), step: 1)
                Button {
                    if index < cases.count - 1 { level.wrappedValue = cases[index + 1] }
                } label: {
                    Text("A")
                        .font(.title3)
                        .foregroundStyle(studio.color(.secondaryText))
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func fontFamilyCard(number: String, title: String, font: Font) -> some View {
        let applied = isFontApplied(number: number, familyTitle: title)
        return Button { applyFont(number: number, familyTitle: title) } label: {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    Text(AppLocalized("今天也想你"))
                        .font(font)
                        .foregroundStyle(studio.color(.primaryText))
                        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
                        .padding(10)
                        .background(studio.color(.surface))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    if applied {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(studio.color(.primaryText))
                            .background(studio.color(.surface))
                            .clipShape(Circle())
                            .padding(8)
                    }
                }
                Text(title)
                    .font(.callout)
                    .foregroundStyle(studio.color(.primaryText))
                Text(number)
                    .font(.footnote)
                    .foregroundStyle(studio.color(.secondaryText))
                if applied {
                    Text(AppLocalized("正在用"))
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(studio.color(.primaryText))
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func uploadedFontCard(_ font: UploadedFont) -> some View {
        let applied = isUploadedFontApplied(font)
        return VStack(alignment: .leading, spacing: 6) {
            Button { applyUploadedFont(font) } label: {
                VStack(alignment: .leading, spacing: 6) {
                    ZStack(alignment: .topTrailing) {
                        Text(AppLocalized("今天也想你"))
                            .font(uploadedFontStore.previewFont(for: font, size: 20))
                            .foregroundStyle(studio.color(.primaryText))
                            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
                            .padding(10)
                            .background(studio.color(.surface))
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        if applied {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.title3)
                                .foregroundStyle(studio.color(.primaryText))
                                .background(studio.color(.surface))
                                .clipShape(Circle())
                                .padding(8)
                        }
                    }
                    Text(font.title)
                        .font(.callout)
                        .foregroundStyle(studio.color(.primaryText))
                    Text(font.number)
                        .font(.footnote)
                        .foregroundStyle(studio.color(.secondaryText))
                    if applied {
                        Text(AppLocalized("正在用"))
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(studio.color(.primaryText))
                    }
                }
            }
            .buttonStyle(.plain)
            Button { uploadedFontStore.delete(font) } label: {
                Text(AppLocalized("删除"))
                    .font(.footnote)
                    .foregroundStyle(studio.color(.destructive))
                    .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
        }
    }

    /// Whether a built-in family card is the current pick for
    /// the part being edited, matched by number (never by
    /// title). Uploaded fonts are checked separately, by
    /// postScript name.
    private func isFontApplied(number: String, familyTitle: String) -> Bool {
        guard let item = UploadedFontStore.builtIns.first(where: { $0.number == number }) else { return false }
        let pack = studio.currentThemePack()
        if fontPart == .message {
            if pack.messageCustomFont != nil { return false }
            let current = pack.messageFontFamily.isEmpty
                ? AppearanceFontFamily.parse(pack.fontFamily)
                : AppearanceFontFamily.parse(pack.messageFontFamily)
            return current == item.family
        }
        if pack.uiCustomFont != nil { return false }
        return AppearanceFontFamily.parse(pack.fontFamily) == item.family
    }

    private func isUploadedFontApplied(_ font: UploadedFont) -> Bool {
        let pack = studio.currentThemePack()
        if fontPart == .message { return pack.messageCustomFont == font.postScriptName }
        return pack.uiCustomFont == font.postScriptName
    }

    private func applyFont(number: String, familyTitle: String) {
        guard let item = UploadedFontStore.builtIns.first(where: { $0.number == number }) else { return }
        if fontPart == .message {
            studio.setMessageFontFamily(item.family)
            studio.setMessageCustomFont(nil)
        } else {
            studio.setFontFamily(item.family)
            studio.setUICustomFont(nil)
        }
    }

    private func applyUploadedFont(_ font: UploadedFont) {
        if fontPart == .message {
            studio.setMessageCustomFont(font.postScriptName)
        } else {
            studio.setUICustomFont(font.postScriptName)
        }
    }

    // MARK: - Next-batch panels (honest placeholders, no fake cards)

    private func nextBatchPanel(_ title: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.title3.weight(.bold))
                .foregroundStyle(studio.color(.primaryText))
            Text(AppLocalized("下一批做：详情预览、换上、保存成搭配，都会按气泡这批同一套路接上。"))
                .font(.subheadline)
                .foregroundStyle(studio.color(.secondaryText))
        }
        .padding(16)
    }

    // MARK: - Detail preview (slide-in page + bottom sheet)

    private func openDetail(_ pack: BubbleStylePack) {
        sheetUp = false
        // Capture the side being edited, same rule as pendants.
        detailPackSide = editingSide
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
                    .font(.title3.weight(.bold))
                    .foregroundStyle(studio.color(.primaryText))
                HStack {
                    Button { closeDetail() } label: {
                        Image(systemName: "chevron.left")
                            .font(.headline)
                            .foregroundStyle(studio.color(.primaryText))
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
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
            // Per-side preview: only the side being edited shows
            // this pack; the other side's row shows what that side
            // actually wears (detailRowPack), and each row's avatar
            // is that side's live avatar (current persona for the
            // AI side, user profile for the user side), wearing
            // that side's applied pendant.
            VStack(alignment: .leading, spacing: 14) {
                Text(AppLocalized("正在改：") + sidePickerLabel(for: detailPackSide))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(studio.color(.primaryText))
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
                    Text(AppLocalized("在模拟聊天里看这款的长句和短句，确认后再换上；只换这一边的气泡，另一边不动，其他搭配也不动。"))
                        .font(.subheadline)
                        .foregroundStyle(studio.color(.secondaryText))
                    Text(AppLocalized("组成：") + pack.composition.joined(separator: " · "))
                        .font(.system(size: 14))
                        .foregroundStyle(studio.color(.secondaryText))
                    HStack(spacing: 12) {
                        Button(AppLocalized("保存成搭配")) {
                            outfitStore.save(bubblePack: pack)
                            closeDetail()
                        }
                        .font(.callout)
                        .foregroundStyle(studio.color(.primaryText))
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(studio.color(.primaryText), lineWidth: 1.5)
                        )
                        .buttonStyle(.plain)
                        Button(AppLocalized("换上这款")) {
                            bubblePackStore.apply(pack, for: detailPackSide)
                            closeDetail()
                        }
                        .font(.callout)
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

    /// Detail row pack: the previewed pack for the side being
    /// edited, the other side's own applied pack otherwise (or
    /// the previewed pack when that side has never picked one).
    private func detailRowPack(_ preview: BubbleStylePack, isUser: Bool) -> BubbleStylePack {
        let rowSide: DressingSide = isUser ? .user : .assistant
        if rowSide == detailPackSide { return preview }
        return appliedPack(for: rowSide) ?? preview
    }

    private func detailMessage(pack: BubbleStylePack, isUser: Bool, text: String) -> some View {
        let rowPack = detailRowPack(pack, isUser: isUser)
        return HStack(alignment: .center, spacing: 8) {
            if !isUser {
                PersonAvatarView(kind: .assistant, size: 36)
            }
            if isUser { Spacer(minLength: 0) }
            bubbleShapeView(pack: rowPack, isUser: isUser, text: text,
                            fontSize: 16, padding: 14,
                            bubbleColour: studio.color(isUser ? .userBubble : .assistantBubble),
                            textColour: rowPack.style.textColor(isUser: isUser)
                                ?? studio.color(isUser ? .bubbleText : .assistantBubbleText),
                            borderWidth: isUser ? rowPack.style.userBorderWidth : rowPack.style.assistantBorderWidth)
            if isUser {
                PersonAvatarView(kind: .user, size: 36)
            }
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
