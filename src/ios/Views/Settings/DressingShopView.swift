import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

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
    //
    // 2026-11-02: the 名片 tab became the colour-variable panel.
    // The business-card page itself was only an honest next-batch
    // panel (no records, no other references); the tab now holds
    // the complete CSS-style global-variable colour settings.
    case other, recommend, outfit, theme, bubble, pendant, font, colorVars
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
        case .colorVars: return AppLocalized("配色变量")
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
    @ObservedObject private var fontSettings = FontSettings.shared
    @ObservedObject private var uploadedFontStore = UploadedFontStore.shared
    @State private var showFontPicker = false
    @State private var fontImportFailed = false
    @State private var fontImportInvalid = false
    @State private var fontImportFailedName = ""
    @State private var fontPendingDelete: UploadedFont?
    /// v2 toast pill: one transient message, auto-dismissed after
    /// 2.2s, shared by the font section (size / family / upload /
    /// delete confirmations). Displayed by the body ZStack, not by
    /// the scrolling font section, so it always sits at the
    /// bottom of the screen like the HTML toast.
    @State private var fontToastMessage: String?
    /// Which variable set the colour panel is editing. Independent
    /// of the mode picker: with "跟随系统" on a light phone she can
    /// still edit (and preview, by flipping the mode) the dark set.
    @State private var editingVariant: AppearanceVariant = .light
    /// The one mode key the whole app already uses (MinisApp root
    /// `.preferredColorScheme` + AppearanceStudio dynamic colours).
    /// The panel reuses it — it must NOT invent a second mode key.
    @AppStorage("appearanceMode") private var appearanceMode = 0
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
    // Theme-set detail (2026-11-02 theme-set batch): the saved
    // record being previewed, its bottom sheet, the save-current
    // name field and its message, the last apply result shown in
    // the detail, and the delete confirmation. The preview colour
    // scheme is theme-preview only: it picks which of the saved
    // pack's two colour maps the preview draws from.
    @State private var detailTheme: AppearanceSavedTheme?
    @State private var themeSheetUp = false
    @State private var themeSaveName = ""
    @State private var themeSaveMessage: String?
    @State private var themeApplyMessage: String?
    @State private var themeConfirmDelete = false
    @State private var themeConfirmApply = false
    @State private var themePendingApplyItem: AppearanceSavedTheme?
    @State private var themePendingApplyWarning: String?
    @State private var wallpaperPickerPresented = false
    @State private var pickedWallpaperItem: PhotosPickerItem?
    @State private var pickedWallpaperIsDark = false
    @State private var wallpaperMessage: String?
    @State private var showSTImporter = false
    @State private var stImportReport: [String]?
    // Shake preview (2026-11-02 shake-preview batch): the rolled palette
    // being previewed, if any. Live colours are never touched while a
    // preview exists — Keep applies it, Discard only drops this state.
    private struct ShakePreviewRoll {
        var light: [AppearanceColorRole: String]
        var dark: [AppearanceColorRole: String]
        var name: String
    }
    @State private var shakePreview: ShakePreviewRoll?
    @Environment(\.colorScheme) private var themePreviewScheme
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
                        case .colorVars: colorVarsView
                        }
                    }
                    .padding(.bottom, 32)
                }
                .scrollIndicators(.hidden)
            }
            .background(studio.color(.canvas))

            // v2 toast pill: black pill, white text, check icon,
            // 10/18 padding, 0 8 24 rgba(0,0,0,0.18) shadow, spring
            // in/out, gone after 2.2s. Sits above the page but
            // below the slide-in detail pages.
            if let toast = fontToastMessage {
                VStack {
                    Spacer(minLength: 0)
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 14, weight: .semibold))
                        Text(toast)
                            .font(ChatFont.font(12, weight: .semibold))
                            .lineLimit(2)
                    }
                    .foregroundStyle(studio.color(.surface))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(studio.color(.primaryText))
                    .clipShape(RoundedRectangle(cornerRadius: 999, style: .continuous))
                    .shadow(color: .black.opacity(0.18), radius: 24, x: 0, y: 8)
                    .padding(.bottom, 24)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if let pack = detailPack {
                bubbleDetailView(pack)
                    .transition(.move(edge: .trailing))
            }
            if let pendant = detailPendant {
                pendantDetailView(pendant)
                    .transition(.move(edge: .trailing))
            }
            if let item = detailTheme {
                themeDetailView(item)
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
        .photosPicker(isPresented: $wallpaperPickerPresented,
                      selection: $pickedWallpaperItem, matching: .images)
        .onChange(of: pickedWallpaperItem) { item in
            guard let item else { return }
            Task { await applyPickedWallpaper(item) }
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
                // Category header keeps its hierarchy above card titles:
                // at the default global size 13 this is exactly 20pt bold
                // (13 * 20 / 13), and it scales with the global size.
                .font(.system(size: globalPointSize * 20 / 13, weight: .bold))
                .foregroundStyle(studio.color(.primaryText))
            Spacer(minLength: 0)
            Button { category = jumpTo } label: {
                Image(systemName: "chevron.right")
                    // At the default global size 13 this is exactly 17pt.
                    .font(.system(size: globalPointSize * 17 / 13))
                    .foregroundStyle(studio.color(.secondaryText))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.top, fontSettings.density(22))
        .padding(.bottom, fontSettings.density(12))
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

    // MARK: - Theme sets (2026-11-02 theme-set batch)
    //
    // A theme set is one library pack plus the per-side bubble
    // and pendant numbers recorded when it was saved
    // (AppearanceSavedTheme). No fake cards: the list only shows
    // records the library actually holds, and an empty library
    // shows only a truthful empty line plus the save-current
    // entry. The old THM-0001..0003 placeholder cards stay
    // deleted — they claimed numbers with no record behind them.
    //
    // Preview and apply are a pair. The preview draws the saved
    // pack's own colours and wallpaper, the recorded bubble
    // packs through the same bubbleShapeView real chat draws,
    // the real avatars with the recorded rings, and an input
    // bar in the pack's style — never a prettier drawing than
    // real chat. Avatar shape IS previewed here: the preview
    // passes the set pack's shape through PersonAvatarView's
    // shapeOverride (an invalid pack value falls back to the
    // live shape, and the shape is also listed in the detail).
    // A side with no recorded bubble draws no bubble
    // in the preview (nothing is guessed for it), and a recorded
    // number that is no longer in the catalogue is named in the
    // detail and reported as failed on apply, never faked.
    //
    // Apply order is fixed: the pack goes through the true
    // replace first, then the recorded per-side numbers. A
    // failed piece keeps the detail open with the failure named;
    // only a clean apply closes it. Save requires a name (an
    // empty name is refused in the UI, never silently relabelled)
    // and at the 40-set limit the UI says "delete one first"
    // and refuses — it never quietly drops an old set. Delete
    // goes through the library's delete-by-id path only.

    private var themeView: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(AppLocalized("主题"), jumpTo: .theme)
            VStack(alignment: .leading, spacing: 8) {
                TextField(AppLocalized("给现在这套起个名"), text: $themeSaveName)
                    .font(.system(size: fsSub))
                    .foregroundStyle(studio.color(.primaryText))
                    .padding(.horizontal, 14)
                    .frame(minHeight: 44)
                    .background(studio.color(.field))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                HStack(spacing: 12) {
                    Button(AppLocalized("把现在这套存下来")) { saveCurrentThemeSet() }
                        .font(.system(size: fsSub, weight: .semibold))
                        .foregroundStyle(studio.color(.surface))
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 44)
                        .background(studio.color(.accent))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .buttonStyle(.plain)
                    Text("\(studio.savedThemes().count) / \(AppearanceSavedTheme.limit)")
                        .font(.system(size: fsCaption, design: .monospaced))
                        .foregroundStyle(studio.color(.secondaryText))
                }
                if let message = themeSaveMessage {
                    Text(message)
                        .font(.system(size: fsCaption))
                        .foregroundStyle(studio.color(.secondaryText))
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
            if studio.savedThemes().isEmpty {
                Text(AppLocalized("还没有存下来的整套。上面起个名，把现在这套存下来，它就会出现在这里。"))
                    .font(.system(size: fsSub))
                    .foregroundStyle(studio.color(.secondaryText))
                    .padding(.horizontal, 16)
            } else {
                ForEach(studio.savedThemes()) { item in themeCard(item) }
            }
            Text(AppLocalized("换主题、重置都不会清掉这里；删只能按套删。"))
                .font(.system(size: fsCaption))
                .foregroundStyle(studio.color(.secondaryText))
                .padding(.horizontal, 16)
                .padding(.top, 10)
            globalWallpaperSection
                .padding(.top, 16)
            stImportSection
                .padding(.top, 16)
        }
    }

    // MARK: - ST theme import (theme category, ST-import batch)
    //
    // The old studio page's ST importer is unreachable (settings open
    // the shop directly), so the import lives here, in the theme
    // category. It reuses the shared copy-mode DocumentCopyPicker
    // (plain tmp file URL, no security-scope dance — .fileImporter
    // silently refuses its grant on resigned builds) and reports
    // inline, like the shop's other messages, so no alert has to be
    // raised while the picker sheet is still on screen.
    private var stImportSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(AppLocalized("导入 ST 主题包"))
                .font(.system(size: fsTitle, weight: .semibold, design: .serif))
                .foregroundStyle(studio.color(.primaryText))
            Text(AppLocalized("选一个 ST 的主题 JSON。颜色、头像形状、消息形态、行高、字距会一起换掉；字号只在包里写了 font_scale 时才按它换算。CSS 里的装饰图接不了。"))
                .font(.system(size: fsSub))
                .foregroundStyle(studio.color(.secondaryText))
            Button(AppLocalized("选一个 ST 主题包")) { showSTImporter = true }
                .font(.system(size: fsSub, weight: .semibold))
                .foregroundStyle(studio.color(.surface))
                .frame(maxWidth: .infinity)
                .frame(minHeight: 44)
                .background(studio.color(.accent))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .buttonStyle(.plain)
            if let report = stImportReport {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(report.indices, id: \.self) { i in
                        Text(report[i])
                            .font(.system(size: fsCaption))
                            .foregroundStyle(studio.color(.secondaryText))
                    }
                }
            }
        }
        .padding(16)
        .background(studio.color(.surface))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(studio.color(.border), lineWidth: 1))
        .padding(.horizontal, 16)
        .sheet(isPresented: $showSTImporter) {
            DocumentCopyPicker(contentTypes: [.json, .plainText, .data, .item],
                               allowsMultipleSelection: false) { urls in
                guard let url = urls.first else { return }
                importSTTheme(url)
            } onDone: {
                showSTImporter = false
            }
        }
    }

    private func importSTTheme(_ url: URL) {
        guard let data = try? Data(contentsOf: url) else {
            stImportReport = [AppLocalized("这个文件读不出来。")]
            return
        }
        do {
            let imported = try SillyTavernTheme.parse(data)
            studio.applySillyTavern(imported)
            var notes: [String] = [String(format: AppLocalized("已应用「%@」。"), imported.name)]
            if imported.fontScale != nil {
                notes.append(AppLocalized("字号已按包里的 font_scale 换算。"))
            }
            notes.append(contentsOf: imported.warnings)
            notes.append(AppLocalized("CSS 里的装饰图、伪元素、按钮换图原生接不了，这些没有导入。"))
            if imported.blurStrength > 0 || imported.shadowWidth > 0 {
                notes.append(AppLocalized("包里的毛玻璃浓度与阴影没有对应的调节项，这次没有导入；颜色、字号和其他项已按包换上。"))
            }
            notes.append(AppLocalized("旧图片和没提到的设置会保留，不会被清掉。"))
            stImportReport = notes
        } catch {
            stImportReport = [error.localizedDescription]
        }
    }

    // MARK: - Global wallpaper (theme category, wallpaper batch)
    //
    // The old studio backdrop page is unreachable (settings open the shop
    // directly), so the global wallpaper control lives here, in the theme
    // category, where the shop merge already maps palette colours +
    // wallpaper + theme library. Global scope ONLY: it reuses the existing
    // setWallpaper / removeWallpaper / wallpaperShade machinery, the
    // existing PhotosPicker flow (downsampled to 2200, dark variant
    // captured at tap, same as the old backdrop page), and the same
    // preview rendering real chat uses (image scaled to fill plus the
    // canvas shade overlay). It does not touch page-scope wallpapers:
    // those are carried by theme packs and theme sets, not controlled
    // here, and the section says so in its own footnote.
    private var globalWallpaperSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(AppLocalized("全局壁纸"))
                .font(.system(size: fsTitle, weight: .semibold, design: .serif))
                .foregroundStyle(studio.color(.primaryText))
            ZStack(alignment: .bottomTrailing) {
                if let image = studio.wallpaper(for: .global) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .clipped()
                    studio.color(.canvas).opacity(studio.wallpaperShade)
                } else {
                    studio.color(.canvas)
                }
                Text(studio.hasOwnWallpaper(.global)
                     ? AppLocalized("壁纸预览") : AppLocalized("没有壁纸，纯色背景"))
                    .font(.system(size: fsCaption, weight: .medium))
                    .foregroundStyle(studio.color(.primaryText))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(studio.color(.raised).opacity(0.85), in: Capsule())
                    .padding(10)
            }
            .id(studio.wallpaperRevision)
            .frame(height: 150)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(studio.color(.border), lineWidth: 1))
            Button(studio.hasOwnWallpaper(.global) ? AppLocalized("换这张") : AppLocalized("选一张")) {
                pickedWallpaperIsDark = studio.activeVariant == .dark
                wallpaperPickerPresented = true
            }
            .font(.system(size: fsSub, weight: .semibold))
            .foregroundStyle(studio.color(.surface))
            .frame(maxWidth: .infinity)
            .frame(minHeight: 44)
            .background(studio.color(.accent))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .buttonStyle(.plain)
            if studio.hasOwnWallpaper(.global) {
                Button(AppLocalized("清除全局壁纸")) {
                    studio.removeWallpaper(.global)
                    wallpaperMessage = AppLocalized("全局壁纸已清除")
                }
                .font(.system(size: fsSub, weight: .semibold))
                .foregroundStyle(studio.color(.destructive))
                .frame(maxWidth: .infinity)
                .frame(minHeight: 44)
                .buttonStyle(.plain)
            }
            HStack(spacing: 12) {
                Text(AppLocalized("壁纸压色"))
                    .font(.system(size: fsSub))
                    .foregroundStyle(studio.color(.primaryText))
                Slider(value: $studio.wallpaperShade, in: 0...0.65)
                    .frame(minHeight: 44)
                    .accessibilityLabel(AppLocalized("壁纸压色"))
                Text(String(format: "%.2f", studio.wallpaperShade))
                    .font(.system(size: fsCaption, design: .monospaced))
                    .foregroundStyle(studio.color(.secondaryText))
            }
            Text(AppLocalized("只管全局壁纸；各页自己的壁纸不在这里改，跟着主题整套和主题包走。"))
                .font(.system(size: fsCaption))
                .foregroundStyle(studio.color(.secondaryText))
            if let message = wallpaperMessage {
                Text(message)
                    .font(.system(size: fsCaption))
                    .foregroundStyle(studio.color(.secondaryText))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(studio.color(.surface))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(studio.color(.border), lineWidth: 1))
        .shadow(color: .black.opacity(0.03), radius: 3, x: 0, y: 1)
        .shadow(color: .black.opacity(0.02), radius: 2, x: 0, y: 1)
        .padding(.horizontal, 16)
    }

    @MainActor
    private func applyPickedWallpaper(_ item: PhotosPickerItem) async {
        defer { pickedWallpaperItem = nil }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = ThumbnailCache.downsampledImage(from: data, maxEdge: 2200) else {
            wallpaperMessage = AppLocalized("选中的图读不出来。")
            return
        }
        if studio.setWallpaper(image, for: .global, dark: pickedWallpaperIsDark) {
            wallpaperMessage = AppLocalized("全局壁纸已换上")
        } else {
            wallpaperMessage = AppLocalized("选中的图读不出来。")
        }
    }

    private func saveCurrentThemeSet() {
        let name = themeSaveName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            themeSaveMessage = AppLocalized("先给这套起个名")
            return
        }
        guard studio.savedThemes().count < AppearanceSavedTheme.limit else {
            themeSaveMessage = AppLocalized("库满了，删一套再存")
            return
        }
        if studio.saveCurrentTheme(name: name) != nil {
            themeSaveName = ""
            themeSaveMessage = AppLocalized("已存下来")
        } else {
            themeSaveMessage = AppLocalized("库满了，删一套再存")
        }
    }

    /// A set counts as in use only when the pack still matches
    /// AND every recorded number is still what that side wears.
    /// A number drifted afterwards (or a pack field changed) drops
    /// the tick honestly instead of claiming the set is on.
    private func themeSetInUse(_ item: AppearanceSavedTheme) -> Bool {
        guard studio.savedThemeMatch(id: item.id) == .inUse else { return false }
        if let number = item.userBubbleNumber,
           bubblePackStore.appliedNumber(for: .user) != number { return false }
        if let number = item.assistantBubbleNumber,
           bubblePackStore.appliedNumber(for: .assistant) != number { return false }
        if let number = item.userPendantNumber,
           pendantStore.appliedNumber(for: .user) != number { return false }
        if let number = item.assistantPendantNumber,
           pendantStore.appliedNumber(for: .assistant) != number { return false }
        return true
    }

    private func themeSetRecordedCount(_ item: AppearanceSavedTheme) -> Int {
        [item.userBubbleNumber, item.assistantBubbleNumber,
         item.userPendantNumber, item.assistantPendantNumber].compactMap { $0 }.count
    }

    private func themeCard(_ item: AppearanceSavedTheme) -> some View {
        let inUse = themeSetInUse(item)
        let recorded = themeSetRecordedCount(item)
        return Button { openThemeDetail(item) } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.name)
                        .font(.system(size: fsTitle, weight: .semibold, design: .serif))
                        .foregroundStyle(studio.color(.primaryText))
                    Spacer(minLength: 0)
                    if inUse {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(studio.color(.accent))
                    }
                }
                Text(item.savedAt.formatted(date: .abbreviated, time: .omitted))
                    .font(.system(size: fsCaption, design: .monospaced))
                    .foregroundStyle(studio.color(.secondaryText))
                Text(recorded > 0
                    ? AppLocalized("已记 \(recorded) 项气泡挂件")
                    : AppLocalized("旧存法，没记气泡挂件"))
                    .font(.system(size: fsCaption))
                    .foregroundStyle(studio.color(.secondaryText))
                if inUse {
                    Text(AppLocalized("正在用这套"))
                        .font(.system(size: fsCaption, weight: .semibold))
                        .foregroundStyle(studio.color(.accent))
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(studio.color(.surface))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(inUse ? studio.color(.accent) : studio.color(.border),
                        lineWidth: inUse ? 1.5 : 1))
            .shadow(color: .black.opacity(inUse ? 0.12 : 0.03),
                    radius: inUse ? 16 : 3, x: 0, y: inUse ? 4 : 1)
            .shadow(color: .black.opacity(inUse ? 0 : 0.02),
                    radius: 2, x: 0, y: 1)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private func openThemeDetail(_ item: AppearanceSavedTheme) {
        themeSheetUp = false
        themeApplyMessage = nil
        detailTheme = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) {
            if detailTheme?.id == item.id { themeSheetUp = true }
        }
    }

    private func closeThemeDetail() {
        themeSheetUp = false
        themeApplyMessage = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            detailTheme = nil
        }
    }

    /// The saved pack's own colour for a role, in the preview's
    /// light/dark map. A missing or malformed pack value falls
    /// back to the live theme colour rather than rendering a
    /// grey that neither the pack nor the live theme carries.
    private func themePreviewColor(_ pack: AppearanceThemePack, _ role: AppearanceColorRole) -> Color {
        let map = themePreviewScheme == .dark ? pack.colorsDark : pack.colorsLight
        if let raw = map[role.rawValue] {
            let cleaned = raw.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            let hexDigits = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
            if (cleaned.count == 6 || cleaned.count == 8)
                && cleaned.unicodeScalars.allSatisfy({ hexDigits.contains($0) }) {
                return Color(hex: raw)
            }
        }
        return studio.color(role)
    }

    private func themePreviewImage(_ base64: String?) -> UIImage? {
        guard let base64, !base64.isEmpty,
              let data = Data(base64Encoded: base64),
              let image = UIImage(data: data) else { return nil }
        return image
    }

    /// One preview row: the recorded bubble pack drawn through
    /// the same bubbleShapeView as real chat, with the saved
    /// pack's colours, and the real avatar wearing the recorded
    /// ring (showPendant off, so the live ring never stacks
    /// under the previewed one). A side with no recorded bubble
    /// draws no bubble at all — nothing is guessed for it; a
    /// recorded bubble that is no longer in the catalogue is
    /// likewise omitted, and the warning below the preview
    /// names it instead of faking it.
    private func themePreviewRow(pack: AppearanceThemePack, item: AppearanceSavedTheme, isUser: Bool) -> some View {
        let number = isUser ? item.userBubbleNumber : item.assistantBubbleNumber
        let rowPack = number.flatMap { bubblePackStore.pack(number: $0) }
        let ringNumber = isUser ? item.userPendantNumber : item.assistantPendantNumber
        let ring = ringNumber.flatMap { n in pendantStore.pendants.first { $0.number == n } }
        return HStack(alignment: .center, spacing: 8) {
            if !isUser {
                themePreviewAvatar(isUser: false, ring: ring, shape: AppearanceAvatarShape(rawValue: pack.avatarShape))
            }
            if isUser { Spacer(minLength: 0) }
            if let rowPack {
                bubbleShapeView(pack: rowPack, isUser: isUser,
                                text: AppLocalized("今天也想你"),
                                fontSize: 16, padding: 14,
                                bubbleColour: themePreviewColor(pack, isUser ? .userBubble : .assistantBubble),
                                textColour: rowPack.style.textColor(isUser: isUser)
                                    ?? themePreviewColor(pack, isUser ? .bubbleText : .assistantBubbleText),
                                borderWidth: isUser ? rowPack.style.userBorderWidth : rowPack.style.assistantBorderWidth)
            }
            if isUser {
                themePreviewAvatar(isUser: true, ring: ring, shape: AppearanceAvatarShape(rawValue: pack.avatarShape))
            }
            if !isUser { Spacer(minLength: 0) }
        }
    }

    /// Theme-set preview avatar. `shape` is the previewed pack's
    /// avatar shape; nil (an invalid pack value) leaves the avatar
    /// on the current-pack shape, exactly as before this fix.
    private func themePreviewAvatar(isUser: Bool, ring: AvatarPendant?, shape: AppearanceAvatarShape?) -> some View {
        ZStack {
            PersonAvatarView(kind: isUser ? .user : .assistant, size: 36, showPendant: false, shapeOverride: shape)
            if let ring {
                AvatarRingView(size: 36, color: ring.color, imageFile: ring.imageFile)
            }
        }
    }

    private func themePreviewHasMissingPiece(_ item: AppearanceSavedTheme) -> Bool {
        for number in [item.userBubbleNumber, item.assistantBubbleNumber] {
            if let number, bubblePackStore.pack(number: number) == nil { return true }
        }
        for number in [item.userPendantNumber, item.assistantPendantNumber] {
            if let number, pendantStore.pendants.first(where: { $0.number == number }) == nil { return true }
        }
        return false
    }

    private func themePreview(pack: AppearanceThemePack, item: AppearanceSavedTheme) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            themePreviewRow(pack: pack, item: item, isUser: false)
            themePreviewRow(pack: pack, item: item, isUser: true)
            HStack(spacing: 6) {
                Image(systemName: "plus")
                    .foregroundStyle(themePreviewColor(pack, .secondaryText))
                Spacer(minLength: 0)
                Image(systemName: "mic")
                    .foregroundStyle(themePreviewColor(pack, .secondaryText))
            }
            .padding(.horizontal, 16)
            .frame(height: 52)
            .background {
                if let image = themePreviewImage(pack.inputBarJPEGBase64) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    themePreviewColor(pack, .field)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: pack.inputBarRadius > 0 ? pack.inputBarRadius : 26,
                                        style: .continuous))
            if themePreviewHasMissingPiece(item) {
                Text(AppLocalized("这套里有记的编号不在店里，预览里没画那一项，换上时也会如实报出来。"))
                    .font(.system(size: fsCaption))
                    .foregroundStyle(themePreviewColor(pack, .secondaryText))
            }
        }
        .padding(16)
        .background {
            if let image = themePreviewImage(pack.wallpaperJPEGBase64) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                themePreviewColor(pack, .canvas)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func themeBubbleLine(_ item: AppearanceSavedTheme, isUser: Bool) -> String {
        let number = isUser ? item.userBubbleNumber : item.assistantBubbleNumber
        guard let number else { return AppLocalized("跟包走") }
        if let pack = bubblePackStore.pack(number: number) { return "\(pack.title) · \(pack.number)" }
        return AppLocalized("不在店里：") + number
    }

    private func themePendantLine(_ item: AppearanceSavedTheme, isUser: Bool) -> String {
        let number = isUser ? item.userPendantNumber : item.assistantPendantNumber
        guard let number else { return AppLocalized("不动") }
        if let pendant = pendantStore.pendants.first(where: { $0.number == number }) {
            return "\(pendant.title) · \(pendant.number)"
        }
        return AppLocalized("不在店里：") + number
    }

    private func themeFailedPieceLine(_ piece: String) -> String {
        switch piece {
        case "userBubble":
            return sidePickerLabel(for: .user) + AppLocalized("的气泡不在店里，跳过了")
        case "assistantBubble":
            return sidePickerLabel(for: .assistant) + AppLocalized("的气泡不在店里，跳过了")
        case "userPendant":
            return sidePickerLabel(for: .user) + AppLocalized("的挂件不在店里，跳过了")
        case "assistantPendant":
            return sidePickerLabel(for: .assistant) + AppLocalized("的挂件不在店里，跳过了")
        default:
            return piece
        }
    }

    /// Pre-apply contrast check for a shop theme set, read-only.
    /// The set's pack colours are the post-apply globals: replace
    /// wipes globals first, then repaints from the pack, so a role
    /// the pack does not carry falls back to the built-in default
    /// (AppearancePaletteBook light/dark), not to the live value.
    /// Only primaryText (4.5) and accent (3.0) against canvas and
    /// surface are checked. Nil = passes, apply directly as before.
    /// A failing pack is NOT refused — the confirm step names what
    /// is unreadable and the user decides.
    private func themeContrastWarning(forSet item: AppearanceSavedTheme) -> String? {
        guard let pack = studio.libraryPack(id: item.id) else { return nil }
        // Built-in fallbacks for roles a pack does not carry, from
        // AppearancePaletteBook (AppearanceStudio.swift): if that
        // palette ever changes, these four pairs must change with it.
        let builtIn: [AppearanceVariant: [AppearanceColorRole: String]] = [
            .light: [.canvas: "F5F5F7", .surface: "FFFFFF",
                     .primaryText: "111113", .accent: "111113"],
            .dark: [.canvas: "000000", .surface: "1C1C1E",
                    .primaryText: "FFFFFF", .accent: "FFFFFF"],
        ]
        var failing: [String] = []
        for variant in [AppearanceVariant.light, .dark] {
            let map = variant == .light ? pack.colorsLight : pack.colorsDark
            func effective(_ role: AppearanceColorRole) -> String {
                map[role.rawValue] ?? builtIn[variant]?[role] ?? "808080"
            }
            let canvas = effective(.canvas), surface = effective(.surface)
            let checks: [(AppearanceColorRole, AppearanceContrast.Level, String)] = [
                (.primaryText, .body, AppLocalized("正文")),
                (.accent, .ui, AppLocalized("重点色")),
            ]
            for (role, level, name) in checks {
                let fg = effective(role)
                for (bgName, bg) in [(AppLocalized("底色"), canvas),
                                     (AppLocalized("卡片底"), surface)] {
                    let r = AppearanceContrast.ratio(fg, on: bg)
                    if r < AppearanceContrast.threshold(level) {
                        failing.append(String(format: AppLocalized("%@%@在%@上约 %.1f（要 %.1f）"),
                                              variant == .light ? AppLocalized("浅色") : AppLocalized("深色"),
                                              name, bgName, r,
                                              AppearanceContrast.threshold(level)))
                    }
                }
            }
        }
        guard !failing.isEmpty else { return nil }
        return AppLocalized("这套有颜色看不清：") + failing.joined(separator: "、")
            + AppLocalized("，个别地方可能看不清。")
    }

    private func applyThemeSet(_ item: AppearanceSavedTheme) {
        if let warning = themeContrastWarning(forSet: item) {
            themePendingApplyItem = item
            themePendingApplyWarning = warning
            themeConfirmApply = true
            return
        }
        applyThemeSetConfirmed(item)
    }

    private func applyThemeSetConfirmed(_ item: AppearanceSavedTheme) {
        guard let result = studio.applySavedThemeSet(id: item.id) else {
            themeApplyMessage = AppLocalized("这套没换上：包文件读不出来。")
            return
        }
        if result.packWarnings.isEmpty && result.failedPieces.isEmpty {
            closeThemeDetail()
        } else {
            var parts: [String] = []
            if !result.packWarnings.isEmpty {
                parts.append(AppLocalized("主题包有几项没落住：") + result.packWarnings.joined(separator: "、"))
            }
            for piece in result.failedPieces {
                parts.append(themeFailedPieceLine(piece))
            }
            themeApplyMessage = AppLocalized("整套没全换上：") + parts.joined(separator: "；")
        }
    }

    private func deleteThemeSet(_ item: AppearanceSavedTheme) {
        if studio.deleteSavedTheme(id: item.id) {
            closeThemeDetail()
        } else {
            themeApplyMessage = AppLocalized("这套没删掉，再试一次。")
        }
    }

    private func themeDetailView(_ item: AppearanceSavedTheme) -> some View {
        VStack(spacing: 0) {
            ZStack {
                Text(AppLocalized("主题"))
                    .font(.system(size: fsTitle, weight: .bold, design: .serif))
                    .foregroundStyle(studio.color(.primaryText))
                HStack {
                    Button { closeThemeDetail() } label: {
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
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(studio.color(.border))
                    .frame(height: 0.5)
            }

            VStack(alignment: .leading, spacing: 14) {
                Text(AppLocalized("正在看：") + item.name)
                    .font(.system(size: fsSub, weight: .semibold))
                    .foregroundStyle(studio.color(.primaryText))
                if let pack = studio.libraryPack(id: item.id) {
                    themePreview(pack: pack, item: item)
                } else {
                    Text(AppLocalized("这套的包文件读不出来，换上会失败，先删掉它再存一套新的。"))
                        .font(.system(size: fsSub))
                        .foregroundStyle(studio.color(.secondaryText))
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .onTapGesture { themeSheetUp.toggle() }

            if themeSheetUp {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        Text(item.name)
                            .font(.system(size: fsTitle, weight: .bold, design: .serif))
                            .foregroundStyle(studio.color(.primaryText))
                        Text("·")
                            .font(.system(size: fsTitle, weight: .bold))
                            .foregroundStyle(studio.color(.secondaryText))
                        Text(item.savedAt.formatted(date: .abbreviated, time: .omitted))
                            .font(.system(size: fsCaption, weight: .semibold, design: .monospaced))
                            .foregroundStyle(studio.color(.secondaryText))
                        Spacer(minLength: 0)
                    }
                    if themeSetInUse(item) {
                        Text(AppLocalized("正在用这套"))
                            .font(.system(size: fsSub, weight: .semibold))
                            .foregroundStyle(studio.color(.accent))
                    } else if studio.savedThemeMatch(id: item.id) == .inUse {
                        Text(AppLocalized("主题包是这套，气泡或挂件后来换过"))
                            .font(.system(size: fsSub))
                            .foregroundStyle(studio.color(.secondaryText))
                    } else if studio.savedThemeMatch(id: item.id) == .modifiedSince {
                        Text(AppLocalized("这套换上过，但之后改过东西"))
                            .font(.system(size: fsSub))
                            .foregroundStyle(studio.color(.secondaryText))
                    }
                    if themeSetRecordedCount(item) == 0 {
                        Text(AppLocalized("旧存法，没记气泡挂件，换上只换主题包"))
                            .font(.system(size: fsSub))
                            .foregroundStyle(studio.color(.secondaryText))
                    }
                    Text(sidePickerLabel(for: .assistant) + AppLocalized("气泡：") + themeBubbleLine(item, isUser: false))
                        .font(.system(size: fsCaption))
                        .foregroundStyle(studio.color(.secondaryText))
                    Text(sidePickerLabel(for: .user) + AppLocalized("气泡：") + themeBubbleLine(item, isUser: true))
                        .font(.system(size: fsCaption))
                        .foregroundStyle(studio.color(.secondaryText))
                    Text(sidePickerLabel(for: .assistant) + AppLocalized("挂件：") + themePendantLine(item, isUser: false))
                        .font(.system(size: fsCaption))
                        .foregroundStyle(studio.color(.secondaryText))
                    Text(sidePickerLabel(for: .user) + AppLocalized("挂件：") + themePendantLine(item, isUser: true))
                        .font(.system(size: fsCaption))
                        .foregroundStyle(studio.color(.secondaryText))
                    if let pack = studio.libraryPack(id: item.id) {
                        Text(AppLocalized("头像形状：") + AppearanceAvatarShape.parse(pack.avatarShape).title
                            + AppLocalized("（随包换上）"))
                            .font(.system(size: fsCaption))
                            .foregroundStyle(studio.color(.secondaryText))
                        Text(AppLocalized("字体：跟主题包走"))
                            .font(.system(size: fsCaption))
                            .foregroundStyle(studio.color(.secondaryText))
                    }
                    if let message = themeApplyMessage {
                        Text(message)
                            .font(.system(size: fsSub))
                            .foregroundStyle(studio.color(.secondaryText))
                    }
                    HStack(spacing: 12) {
                        Button(AppLocalized("删除这套")) {
                            themeConfirmDelete = true
                        }
                        .font(.callout)
                        .foregroundStyle(studio.color(.destructive))
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(studio.color(.destructive), lineWidth: 1)
                        )
                        .buttonStyle(.plain)
                        Button(AppLocalized("换上整套")) {
                            applyThemeSet(item)
                        }
                        .font(.callout)
                        .foregroundStyle(studio.color(.surface))
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(studio.color(.accent))
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
        .animation(.easeOut(duration: 0.3), value: themeSheetUp)
        .alert(AppLocalized("删除这套？"), isPresented: $themeConfirmDelete) {
            Button(AppLocalized("删除"), role: .destructive) {
                deleteThemeSet(item)
            }
            Button(AppLocalized("取消"), role: .cancel) {}
        } message: {
            Text(AppLocalized("删掉后这套就从列表里消失。"))
        }
        .alert(AppLocalized("这套有颜色看不清"), isPresented: $themeConfirmApply) {
            Button(AppLocalized("仍要换上")) {
                if let pending = themePendingApplyItem {
                    applyThemeSetConfirmed(pending)
                }
                themePendingApplyItem = nil
                themePendingApplyWarning = nil
            }
            Button(AppLocalized("不换了"), role: .cancel) {
                themePendingApplyItem = nil
                themePendingApplyWarning = nil
            }
        } message: {
            Text(themePendingApplyWarning ?? "")
        }
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
                    // Bubble batch aesthetic: monochrome + one
                    // accent, hairline border from the theme
                    // token, soft shadows copied from the font
                    // card (same two layers, same values).
                    // No fixed height: the art is exactly as
                    // tall as its two sample rows + padding, so
                    // no empty space is left inside the card.
                    // The sample rows themselves are untouched:
                    // same shape, padding, and text colour as
                    // real chat, so the card never looks better
                    // than the chat it previews.
                    bubbleCardArt(pack)
                        .frame(width: fixedWidth ? 125 : nil)
                        .background(studio.color(.surface))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(applied ? studio.color(.accent) : studio.color(.border),
                                    lineWidth: applied ? 1.5 : 1))
                        .shadow(color: .black.opacity(applied ? 0.12 : 0.03),
                                radius: applied ? 16 : 3, x: 0, y: applied ? 4 : 1)
                        .shadow(color: .black.opacity(applied ? 0 : 0.02),
                                radius: 2, x: 0, y: 1)
                    if applied {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(studio.color(.accent))
                            .background(studio.color(.surface))
                            .clipShape(Circle())
                            .padding(8)
                    }
                }
                Text(pack.title)
                    .font(.system(size: fsTitle, weight: .semibold, design: .serif))
                    .foregroundStyle(studio.color(.primaryText))
                    .padding(.top, 10)
                Text(pack.number)
                    .font(.system(size: fsCaption, weight: .semibold, design: .monospaced))
                    .foregroundStyle(studio.color(.secondaryText))
                    .padding(.top, 3)
                if applied {
                    Text(AppLocalized("正在用"))
                        .font(.system(size: fsCaption, weight: .semibold))
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
                    // Pendant batch aesthetic, copied from the
                    // bubble cards: monochrome + one accent,
                    // hairline border from the theme token, soft
                    // shadows copied from the font card (same
                    // two layers, same values). No fixed height:
                    // the art is exactly as tall as the 72pt
                    // avatar + padding, so no empty space is
                    // left inside the card. The ring itself is
                    // untouched: same AvatarRingView, same
                    // colour and image file as live chat.
                    pendantCardArt(pendant)
                        .frame(width: fixedWidth ? 125 : nil)
                        .background(studio.color(.surface))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(applied ? studio.color(.accent) : studio.color(.border),
                                    lineWidth: applied ? 1.5 : 1))
                        .shadow(color: .black.opacity(applied ? 0.12 : 0.03),
                                radius: applied ? 16 : 3, x: 0, y: applied ? 4 : 1)
                        .shadow(color: .black.opacity(applied ? 0 : 0.02),
                                radius: 2, x: 0, y: 1)
                    if applied {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(studio.color(.accent))
                            .background(studio.color(.surface))
                            .clipShape(Circle())
                            .padding(8)
                    }
                }
                Text(pendant.title)
                    .font(.system(size: fsTitle, weight: .semibold, design: .serif))
                    .foregroundStyle(studio.color(.primaryText))
                    .padding(.top, 10)
                Text(pendant.number)
                    .font(.system(size: fsCaption, weight: .semibold, design: .monospaced))
                    .foregroundStyle(studio.color(.secondaryText))
                    .padding(.top, 3)
                if applied {
                    Text(AppLocalized("正在用"))
                        .font(.system(size: fsCaption, weight: .semibold))
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
                    .font(.system(size: fsTitle, weight: .bold, design: .serif))
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
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(studio.color(.border))
                    .frame(height: 0.5)
            }

            VStack(alignment: .leading, spacing: 14) {
                // Side label, resolved live: this detail edits
                // one side only, and the preview below shows
                // THAT side's avatar — the current persona's
                // avatar for the AI side, the user-profile avatar
                // for the user side — never a generic disc and
                // never the other side's picture.
                Text(AppLocalized("正在改：") + sidePickerLabel(for: detailPendantSide))
                    .font(.system(size: fsSub, weight: .semibold))
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
                    HStack(spacing: 6) {
                        Text(pendant.title)
                            .font(.system(size: fsTitle, weight: .bold, design: .serif))
                            .foregroundStyle(studio.color(.primaryText))
                        Text("·")
                            .font(.system(size: fsTitle, weight: .bold))
                            .foregroundStyle(studio.color(.secondaryText))
                        Text(pendant.number)
                            .font(.system(size: fsCaption, weight: .semibold, design: .monospaced))
                            .foregroundStyle(studio.color(.secondaryText))
                        Spacer(minLength: 0)
                    }
                    Text(AppLocalized("在大头像上看这款圆环，再确认换上；只换这一边的挂件，另一边不动，其他搭配也不动。"))
                        .font(.system(size: fsSub))
                        .foregroundStyle(studio.color(.secondaryText))
                    Text(AppLocalized("组成：") + AppLocalized("圆环"))
                        .font(.system(size: fsCaption))
                        .foregroundStyle(studio.color(.secondaryText))
                    if !pendant.detail.isEmpty {
                        Text(pendant.detail)
                            .font(.system(size: fsCaption))
                            .foregroundStyle(studio.color(.secondaryText))
                    }
                    HStack(spacing: 12) {
                        Button(AppLocalized("保存成搭配")) {
                            outfitStore.save(pendant: pendant)
                            closePendantDetail()
                        }
                        .font(.callout)
                        .foregroundStyle(studio.color(.accent))
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(studio.color(.accent), lineWidth: 1)
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
                        .background(studio.color(.accent))
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
                    .font(.system(size: fsSub))
                    .foregroundStyle(studio.color(.secondaryText))
                    .padding(.horizontal, 16)
            } else {
                ForEach(outfitStore.outfits) { outfit in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(outfit.title)
                                .font(.system(size: fsTitle, weight: .semibold, design: .serif))
                                .foregroundStyle(studio.color(.primaryText))
                            HStack(alignment: .top, spacing: 4) {
                                Text(outfit.number)
                                    .font(.system(size: fsCaption, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(studio.color(.secondaryText))
                                Text("·")
                                    .font(.system(size: fsCaption))
                                    .foregroundStyle(studio.color(.secondaryText))
                                Text(outfit.summary)
                                    .font(.system(size: fsCaption))
                                    .foregroundStyle(studio.color(.secondaryText))
                            }
                        }
                        Spacer(minLength: 0)
                        Button(AppLocalized("按编号删除")) {
                            outfitStore.delete(number: outfit.number)
                        }
                        .font(.system(size: fsCaption))
                        .foregroundStyle(studio.color(.secondaryText))
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                        .buttonStyle(.plain)
                    }
                    .padding(14)
                    .background(studio.color(.surface))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(studio.color(.border), lineWidth: 1))
                    .shadow(color: .black.opacity(0.03), radius: 3, x: 0, y: 1)
                    .shadow(color: .black.opacity(0.02), radius: 2, x: 0, y: 1)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                }
            }
            Text(AppLocalized("换主题、重置都不会清掉这里；只有按编号删，才会删掉那一行。"))
                .font(.system(size: fsCaption))
                .foregroundStyle(studio.color(.secondaryText))
                .padding(.horizontal, 16)
                .padding(.top, 10)
        }
    }

    // MARK: - Font section, Gemini workshop skin (locked layout)

    /// Layout constants for the font section ONLY, in one
    /// place, private to this file — never in the theme pack,
    /// so AI theme tools (colour / wallpaper / font size
    /// only) cannot move them. This is the layout lock her
    /// 2026-11-01 AI-theme ban requires: radii, padding
    /// bases, and gaps are fixed numbers here. Padding and
    /// gap bases still pass through `density()` so a small
    /// global size pulls the section together (the 194 fix);
    /// radii never densify. Colours are all theme globals
    /// (`studio.color`), never literals — the SwiftUI
    /// equivalent of the Gemini file's `:root` variables.
    /// Shadows are the one exception: they are black
    /// translucency, not palette colours, exactly as in the
    /// Gemini file's fixed rgba shadows.
    ///
    /// 2026-11-02 (v2 diff): radii now match v2 exactly —
    /// stage card 24 (v2 radius-lg), font card 16 (v2
    /// radius-md), size card 10 (v2 radius-sm), tag 5. The 195
    /// values (22 / 22 / 16) were v1's, not v2's.
    private enum FontSkin {
        static let radiusStage: CGFloat = 24
        static let radiusMedium: CGFloat = 16
        static let radiusSmall: CGFloat = 10
        static let radiusTag: CGFloat = 5
        static let radiusPill: CGFloat = 999
        static let cardPadding: CGFloat = 16
        static let sectionGap: CGFloat = 28
        static let listGap: CGFloat = 10
        static let gridGap: CGFloat = 8
        static let horizontal: CGFloat = 16
    }

    /// v2's `--fs-*` ladder, derived from the one global base
    /// exactly as the HTML derives every size from
    /// `--font-size-base`: hero 1.32, title 1.15, body 1.0, sub
    /// 0.92, caption 0.82, mini 0.72. Rendered with
    /// `messageFont` (exact size in the global family, uploaded
    /// font included) or system mono for the mono tokens — never
    /// through `ChatFont.font`, which would scale an already
    /// scaled ladder value a second time. At the 13pt default
    /// title is 14.95 (≈ the old 15) and sub 11.96 (≈ 12), so
    /// the ladder changes no default pixel, it just names the
    /// rule the section already followed implicitly.
    private var fsHero: CGFloat { globalPointSize * 1.32 }
    private var fsTitle: CGFloat { globalPointSize * 1.15 }
    private var fsBody: CGFloat { globalPointSize }
    private var fsSub: CGFloat { globalPointSize * 0.92 }
    private var fsCaption: CGFloat { globalPointSize * 0.82 }
    private var fsMini: CGFloat { globalPointSize * 0.72 }

    /// v2's `:active` press: size cards scale 0.96, font cards
    /// 0.985, the 195 `.plain` style gave no feedback at all.
    private struct FontPressStyle: ButtonStyle {
        var scale: CGFloat
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .scaleEffect(configuration.isPressed ? scale : 1)
                .animation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.15), value: configuration.isPressed)
        }
    }

    /// v2's SYNCHRONIZED dot: accent colour, pulsing 2s infinite.
    /// The colour is passed in (the new palette's accent flips
    /// black/white with the mode) rather than a literal.
    private struct SyncDot: View {
        var color: Color
        @State private var pulse = false
        var body: some View {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
                .scaleEffect(pulse ? 1.2 : 0.9)
                .opacity(pulse ? 1 : 0.3)
                .onAppear {
                    withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) {
                        pulse = true
                    }
                }
        }
    }

    /// The one global point size, read once per render:
    /// message, UI, and input all derive from it. Size-card
    /// samples render at exactly their own pt; font-card
    /// specimens and the live preview render at this value.
    private var globalPointSize: CGFloat { fontSettings.messagePointSize }

    /// Current global font, as (number, title), resolved
    /// live: an uploaded font wins by postScript name, else
    /// the built-in family. Never a stored name.
    private var currentFontLabel: (number: String, title: String) {
        if let name = MinisThemeShape.globalCustomFontName,
           let up = uploadedFontStore.fonts.first(where: { $0.postScriptName == name }) {
            return (up.number, up.title)
        }
        let family = MinisThemeShape.globalFontFamily
        let number = UploadedFontStore.builtIns.first(where: { $0.family == family })?.number ?? "FON-0001"
        return (number, family.title)
    }

    /// Section head in the Gemini language: a title at the
    /// `--fs-title` step and a description at `--fs-caption`,
    /// with v2's bilingual suffix (mono, tertiary, wide tracking)
    /// where v2 has one — "TYPE SCALE", "TYPEFACES", and the
    /// preview's "LIVE PREVIEW". The suffix is decoration; the
    /// Chinese title and description carry the meaning.
    private func fontSectionHead(title: String, desc: String, en: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: fontSettings.density(3)) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title)
                    .font(MinisThemeShape.messageFont(size: fsTitle, weight: .bold))
                    .tracking(-0.2)
                    .foregroundStyle(studio.color(.primaryText))
                if let en {
                    Text(en)
                        .font(.system(size: fsCaption, weight: .medium, design: .monospaced))
                        .tracking(1.0)
                        .foregroundStyle(studio.color(.tertiaryText))
                }
            }
            Text(desc)
                .font(MinisThemeShape.messageFont(size: fsCaption))
                .foregroundStyle(studio.color(.secondaryText))
        }
        .padding(.horizontal, FontSkin.horizontal)
    }

    private var fontView: some View {
        VStack(alignment: .leading, spacing: 0) {
            fontLivePreview
                .padding(.top, fontSettings.density(18))
            fontSizeSection
                .padding(.top, fontSettings.density(FontSkin.sectionGap))
            fontListSection
                .padding(.top, fontSettings.density(FontSkin.sectionGap))
        }
        .padding(.bottom, fontSettings.density(44))
        // v2's spring on every size/font change: the whole section
        // (preview, cards, badges) eases 0.22s on the spring curve
        // instead of jumping. Font rendering itself cannot tween
        // glyphs, but layout, badge fades, and card borders do.
        .animation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.22), value: globalPointSize)
        .animation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.22), value: currentFontLabel.number)
        .sheet(isPresented: $showFontPicker) {
            FontFilePicker(
                onPick: { url in
                    showFontPicker = false
                    // v2 upload flow, in order: parsing toast, then
                    // install + auto-apply + success toast. The
                    // picker already filters to fonts, but a picked
                    // file with another extension still gets v2's
                    // "格式不受支持" modal instead of a silent fail.
                    showFontToast(AppLocalized("正在解析字体文件…"))
                    let ext = url.pathExtension.lowercased()
                    guard ext == "ttf" || ext == "otf" else {
                        fontImportFailedName = url.lastPathComponent
                        fontImportInvalid = true
                        return
                    }
                    Task { @MainActor in
                        if let font = uploadedFontStore.importFont(from: url) {
                            applyUploadedFont(font)
                            showFontToast(AppLocalized("字体 \(font.number) 安装成功并已应用"))
                        } else {
                            fontImportFailedName = url.lastPathComponent
                            fontImportFailed = true
                        }
                    }
                },
                onCancel: { showFontPicker = false }
            )
        }
        .alert(AppLocalized("字体注册失败"), isPresented: $fontImportFailed) {
            Button(AppLocalized("知道了"), role: .cancel) { fontImportFailedName = "" }
        } message: {
            // v2's register-failure wording, with the file name:
            // corrupt files are the failure this path can reach,
            // since the picker already filters extensions.
            Text(AppLocalized("无法解析字体文件「\(fontImportFailedName)」。文件可能已损坏，或并非合法的 OpenType / TrueType 轮廓规范。"))
        }
        .alert(AppLocalized("格式不受支持"), isPresented: $fontImportInvalid) {
            Button(AppLocalized("我知道了"), role: .cancel) { fontImportFailedName = "" }
        } message: {
            Text(AppLocalized("所选文件「\(fontImportFailedName)」格式无效。装扮店只支持 .ttf 或 .otf 格式的字体文件。"))
        }
        .alert(AppLocalized("删除自定义字体"), isPresented: Binding(
            get: { fontPendingDelete != nil },
            set: { if !$0 { fontPendingDelete = nil } }
        )) {
            Button(AppLocalized("彻底删除"), role: .destructive) {
                if let font = fontPendingDelete {
                    // In-use font falls back to FON-0001
                    // (system) first, then the file and its
                    // record go, so nothing keeps pointing
                    // at a deleted font. The card itself fades
                    // and shrinks out (v2's 0.2s exit) before
                    // the record is removed.
                    if isUploadedFontApplied(font) { studio.setFontFamily(.system) }
                    withAnimation(.easeOut(duration: 0.2)) {
                        uploadedFontStore.delete(font)
                    }
                    showFontToast(AppLocalized("已移除字体：\(font.title)"))
                }
                fontPendingDelete = nil
            }
            Button(AppLocalized("保留"), role: .cancel) { fontPendingDelete = nil }
        } message: {
            Text(AppLocalized("确认删除字体「\(fontPendingDelete?.title ?? "")」？删除后系统将清理文件引用与内存缓存。"))
        }
    }

    // MARK: Live preview — the proof the global claim is real

    /// Gemini's preview module, our content: two real chat
    /// rows (current persona avatar + user avatar, live
    /// side names, never hardcoded names) and an input-bar
    /// mock, all rendered at the current global size and
    /// family. Tapping a size or family card below redraws
    /// this preview at once, because every text here reads
    /// the same global value live chat reads. The preview
    /// is display-only, not a control: no dead send button.
    ///
    /// 2026-11-02 (v2 diff): stage card 24 / 20x18 with the
    /// two-layer stage shadow, chat box 16x14 with a 0.5
    /// hairline, 30pt avatars, 10pt row gaps, bubbles 10x14
    /// radius 18 tail 4 with v2's shadows, tertiary meta,
    /// a pulsing SYNCHRONIZED badge, a leading pen icon and
    /// a send capsule with its paper-plane icon.
    private var fontLivePreview: some View {
        VStack(alignment: .leading, spacing: 0) {
            fontSectionHead(
                title: AppLocalized("实时联动预览"),
                desc: AppLocalized("改字号或换字体，界面、消息、输入框一起变。"),
                en: "LIVE PREVIEW"
            )
            VStack(alignment: .leading, spacing: fontSettings.density(14)) {
                // v2 stage-top-meta: SYNCHRONIZED badge (pulsing
                // dot + mono caption, badge-bg = iconTile) left,
                // "全域毫秒响应" caption right.
                HStack {
                    HStack(spacing: 6) {
                        SyncDot(color: studio.color(.accent))
                        Text("SYNCHRONIZED")
                            .font(.system(size: fsCaption, weight: .semibold, design: .monospaced))
                            .tracking(0.6)
                    }
                    .foregroundStyle(studio.color(.primaryText))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(studio.color(.iconTile))
                    .clipShape(RoundedRectangle(cornerRadius: FontSkin.radiusPill, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: FontSkin.radiusPill, style: .continuous)
                        .stroke(studio.color(.border), lineWidth: 0.5))
                    Spacer(minLength: 0)
                    Text(AppLocalized("全域毫秒响应"))
                        .font(MinisThemeShape.messageFont(size: fsCaption))
                        .foregroundStyle(studio.color(.tertiaryText))
                }
                // Live specs, like v2's stage-specs: current size
                // and font, live, in mono.
                HStack {
                    Text("\(Int(globalPointSize))pt · \(currentFontLabel.title)")
                        .font(.system(size: fsSub, weight: .semibold, design: .monospaced))
                        .tracking(-0.2)
                        .foregroundStyle(studio.color(.secondaryText))
                    Spacer(minLength: 0)
                    Text(currentFontLabel.number)
                        .font(.system(size: fsSub, weight: .semibold, design: .monospaced))
                        .foregroundStyle(studio.color(.secondaryText))
                }
                // Chat box: muted surface, like Gemini's
                // preview-chat-box.
                VStack(alignment: .leading, spacing: fontSettings.density(14)) {
                    HStack(alignment: .top, spacing: 10) {
                        PersonAvatarView(kind: .assistant, size: 30, showPendant: false)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(AppLocalized("今天也想你"))
                                .font(MinisThemeShape.messageFont(size: globalPointSize))
                                .lineSpacing(globalPointSize * 0.25)
                                .foregroundStyle(studio.color(.primaryText))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .background(studio.color(.surface))
                                .clipShape(UnevenRoundedRectangle(
                                    topLeadingRadius: 4, bottomLeadingRadius: 18,
                                    bottomTrailingRadius: 18, topTrailingRadius: 18))
                                .overlay(UnevenRoundedRectangle(
                                    topLeadingRadius: 4, bottomLeadingRadius: 18,
                                    bottomTrailingRadius: 18, topTrailingRadius: 18)
                                    .stroke(studio.color(.border), lineWidth: 1))
                                .shadow(color: .black.opacity(0.03), radius: 4, x: 0, y: 1)
                            Text(assistantSideName)
                                .font(MinisThemeShape.messageFont(size: fsCaption))
                                .foregroundStyle(studio.color(.tertiaryText))
                                .padding(.horizontal, 4)
                        }
                    }
                    HStack(alignment: .top, spacing: 10) {
                        Spacer(minLength: 0)
                        VStack(alignment: .trailing, spacing: 4) {
                            Text(AppLocalized("我也想你"))
                                .font(MinisThemeShape.messageFont(size: globalPointSize))
                                .lineSpacing(globalPointSize * 0.25)
                                .foregroundStyle(studio.color(.surface))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .background(studio.color(.primaryText))
                                .clipShape(UnevenRoundedRectangle(
                                    topLeadingRadius: 18, bottomLeadingRadius: 18,
                                    bottomTrailingRadius: 18, topTrailingRadius: 4))
                                .shadow(color: .black.opacity(0.12), radius: 10, x: 0, y: 3)
                            Text(userSideName)
                                .font(MinisThemeShape.messageFont(size: fsCaption))
                                .foregroundStyle(studio.color(.tertiaryText))
                                .padding(.horizontal, 4)
                        }
                        PersonAvatarView(kind: .user, size: 30, showPendant: false)
                    }
                }
                .padding(.horizontal, fontSettings.density(14))
                .padding(.vertical, fontSettings.density(16))
                .background(studio.color(.mutedSurface))
                .clipShape(RoundedRectangle(cornerRadius: FontSkin.radiusMedium, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: FontSkin.radiusMedium, style: .continuous)
                    .stroke(studio.color(.border), lineWidth: 0.5))
                // Input-bar mock: pill, pen icon, field text at
                // the global size, send capsule with its icon.
                // Still display-only: an editable field here
                // would be fake chat, and v2's mock send only
                // toasts — it never sends anything either.
                HStack(spacing: 8) {
                    Image(systemName: "pencil.tip")
                        .font(.system(size: 18))
                        .foregroundStyle(studio.color(.tertiaryText))
                    Text(AppLocalized("今天也想你"))
                        .font(MinisThemeShape.messageFont(size: globalPointSize))
                        .lineLimit(1)
                        .foregroundStyle(studio.color(.primaryText))
                    Spacer(minLength: 0)
                    HStack(spacing: 5) {
                        Text(AppLocalized("发送"))
                            .font(MinisThemeShape.messageFont(size: fsSub, weight: .semibold))
                        Image(systemName: "paperplane.fill")
                            .font(.system(size: 12))
                    }
                    .foregroundStyle(studio.color(.surface))
                    .padding(.horizontal, 14)
                    .frame(height: 34)
                    .background(studio.color(.primaryText))
                    .clipShape(RoundedRectangle(cornerRadius: FontSkin.radiusPill, style: .continuous))
                }
                .padding(.leading, 14)
                .padding(.trailing, 6)
                .padding(.vertical, 4)
                .frame(minHeight: 44)
                .background(studio.color(.surface))
                .clipShape(RoundedRectangle(cornerRadius: FontSkin.radiusPill, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: FontSkin.radiusPill, style: .continuous)
                    .stroke(studio.color(.border), lineWidth: 1))
                .shadow(color: .black.opacity(0.03), radius: 4, x: 0, y: 1)
            }
            .padding(.horizontal, fontSettings.density(18))
            .padding(.vertical, fontSettings.density(20))
            .background(studio.color(.surface))
            .clipShape(RoundedRectangle(cornerRadius: FontSkin.radiusStage, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: FontSkin.radiusStage, style: .continuous)
                .stroke(studio.color(.border), lineWidth: 1))
            .shadow(color: .black.opacity(0.08), radius: 40, x: 0, y: 16)
            .shadow(color: .black.opacity(0.02), radius: 10, x: 0, y: 2)
            .padding(.horizontal, FontSkin.horizontal)
            .padding(.top, fontSettings.density(12))
        }
    }

    // MARK: Global size — 3-column grid, honest samples

    private var fontSizeSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            fontSectionHead(
                title: AppLocalized("全局字号"),
                desc: AppLocalized("卡里的字就是它标的那个字号，点一下全 App 一起变。"),
                en: "TYPE SCALE"
            )
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: fontSettings.density(FontSkin.gridGap)), count: 3),
                      spacing: fontSettings.density(FontSkin.gridGap)) {
                ForEach([10, 11, 12, 13, 14, 15], id: \.self) { pt in
                    fontSizeCard(pt: pt)
                }
            }
            .padding(.horizontal, FontSkin.horizontal)
            .padding(.top, fontSettings.density(12))
        }
    }

    /// v2's size tiers, one per step: 13 is the default step,
    /// the rest are named by role. Rendered mono at the
    /// `--fs-mini` step in tertiary, uppercase, wide tracking —
    /// exactly v2's `.size-scale-tag`.
    private func fontSizeTier(pt: Int) -> String {
        switch pt {
        case 10: return "MICRO · 10PX"
        case 11: return "COMPACT · 11PX"
        case 12: return "REGULAR · 12PX"
        case 13: return "DEFAULT · 13PX"
        case 14: return "MEDIUM · 14PX"
        default: return "PROMINENT · 15PX"
        }
    }

    /// Gemini size card, v2 numbers: radius 10, 11x10 padding,
    /// 74pt min height, 8pt grid gap, mono number at `--fs-sub`,
    /// sample at EXACTLY its own pt in the current global family,
    /// semibold + primary when active, secondary otherwise, tier
    /// tag under the sample. The "正在用" badge is always in the
    /// layout and only fades in when active (v2 opacity/translate),
    /// so activating a card never shifts its neighbours. The
    /// border is the subtle border token when inactive and the
    /// 1.5pt accent border when active — not a 40%-opacity
    /// primary stroke. Re-tapping the active card is a no-op
    /// (v2's early return): no haptic, no toast.
    private func fontSizeCard(pt: Int) -> some View {
        let applied = Int(globalPointSize) == pt
        return Button {
            guard !applied else { return }
            fontTapHaptic()
            fontSettings.messagePointSize = CGFloat(pt)
            showFontToast(AppLocalized("全局字号已应用：\(pt)pt"))
        } label: {
            VStack(alignment: .leading, spacing: fontSettings.density(2)) {
                HStack {
                    Text("\(pt) pt")
                        .font(.system(size: fsSub, weight: .bold, design: .monospaced))
                        .tracking(-0.2)
                        .foregroundStyle(studio.color(.primaryText))
                    Spacer(minLength: 0)
                    Text(AppLocalized("正在用"))
                        .font(MinisThemeShape.messageFont(size: fsMini, weight: .semibold))
                        .tracking(0.2)
                        .foregroundStyle(studio.color(.surface))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(studio.color(.primaryText))
                        .clipShape(RoundedRectangle(cornerRadius: FontSkin.radiusPill, style: .continuous))
                        .opacity(applied ? 1 : 0)
                        .offset(y: applied ? 0 : -2)
                }
                Text(AppLocalized("今天也想你"))
                    .font(MinisThemeShape.messageFont(size: CGFloat(pt)))
                    .foregroundStyle(applied ? studio.color(.primaryText) : studio.color(.secondaryText))
                    .fontWeight(applied ? .semibold : .regular)
                    .lineLimit(1)
                Text(fontSizeTier(pt: pt))
                    .font(.system(size: fsMini, design: .monospaced))
                    .tracking(0.4)
                    .foregroundStyle(studio.color(.tertiaryText))
                    .lineLimit(1)
            }
            .padding(.horizontal, fontSettings.density(10))
            .padding(.vertical, fontSettings.density(11))
            .frame(minHeight: 74, alignment: .leading)
            .background(studio.color(.surface))
            .clipShape(RoundedRectangle(cornerRadius: FontSkin.radiusSmall, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: FontSkin.radiusSmall, style: .continuous)
                .stroke(applied ? studio.color(.primaryText) : studio.color(.border), lineWidth: applied ? 1.5 : 1))
            .shadow(color: .black.opacity(applied ? 0.12 : 0.03), radius: applied ? 16 : 3, x: 0, y: applied ? 4 : 1)
            .shadow(color: .black.opacity(applied ? 0 : 0.02), radius: 2, x: 0, y: 1)
        }
        .buttonStyle(FontPressStyle(scale: 0.96))
    }

    // MARK: All fonts — vertical list, specimen at live size

    private var fontListSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .bottom, spacing: 0) {
                fontSectionHead(
                    title: AppLocalized("全部字体"),
                    desc: AppLocalized("样张跟随全局字号缩放渲染 · 点选全域换装"),
                    en: "TYPEFACES"
                )
                Spacer(minLength: 0)
                // v2's upload trigger lives in this head, not in a
                // separate section at the bottom: a solid 1pt
                // border pill (not the 195 dashed pill) with the
                // upload icon, knob shadow, press 0.97.
                Button { showFontPicker = true } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 13, weight: .semibold))
                        Text(AppLocalized("上传字体"))
                            .font(MinisThemeShape.messageFont(size: fsSub, weight: .semibold))
                    }
                    .foregroundStyle(studio.color(.primaryText))
                    .padding(.horizontal, 14)
                    .frame(minHeight: 44)
                    .background(studio.color(.surface))
                    .clipShape(RoundedRectangle(cornerRadius: FontSkin.radiusPill, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: FontSkin.radiusPill, style: .continuous)
                        .stroke(studio.color(.border), lineWidth: 1))
                    .shadow(color: .black.opacity(0.03), radius: 3, x: 0, y: 1)
                    .shadow(color: .black.opacity(0.02), radius: 2, x: 0, y: 1)
                }
                .buttonStyle(FontPressStyle(scale: 0.97))
            }
            .padding(.trailing, FontSkin.horizontal)
            VStack(spacing: fontSettings.density(FontSkin.listGap)) {
                ForEach(UploadedFontStore.builtIns, id: \.number) { item in
                    fontFamilyCard(number: item.number, title: item.family.title,
                                   font: item.family.font(size: globalPointSize))
                }
                ForEach(uploadedFontStore.fonts) { font in
                    uploadedFontCard(font)
                }
            }
            .padding(.horizontal, FontSkin.horizontal)
            .padding(.top, fontSettings.density(12))
        }
    }

    /// v2's specimen second line: the English line under the
    /// Chinese line, in the same card family at `--fs-body`.
    /// The mono card gets v2's code line instead of the pangram.
    private func fontSpecimenEN(number: String) -> String {
        number == "FON-0004"
            ? "function evaluateBeauty() { return true; }"
            : "The quick brown fox jumps over the lazy dog. 0123456789"
    }

    /// v2 font card, exact: radius 16, 14x16 padding, 10pt list
    /// gap, tag mono caption 2x6 radius 5 with a 0.5 hairline
    /// (tag-bg maps to the chip token — v2's ECECEF sits between
    /// chip EBEBEF and iconTile F2F2F5 and has no own slot),
    /// title at `--fs-title`, badge always in layout fading and
    /// scaling in when active (v2 opacity 0 / scale 0.9), and the
    /// specimen as a hairline-separated plain area — NOT the 195
    /// muted rounded box — with a Chinese line and an English
    /// line, both in this card's family at the current global pt.
    /// Border: subtle token inactive, 1.5pt accent active.
    private func fontFamilyCard(number: String, title: String, font: Font) -> some View {
        let applied = isFontApplied(number: number, familyTitle: title)
        return Button {
            guard applyFont(number: number, familyTitle: title) else { return }
            fontTapHaptic()
            showFontToast(AppLocalized("全局字体已换装：\(title)"))
        } label: {
            VStack(alignment: .leading, spacing: fontSettings.density(10)) {
                HStack {
                    Text(number)
                        .font(.system(size: fsCaption, weight: .semibold, design: .monospaced))
                        .foregroundStyle(applied ? studio.color(.surface) : studio.color(.secondaryText))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(applied ? studio.color(.primaryText) : studio.color(.chip))
                        .clipShape(RoundedRectangle(cornerRadius: FontSkin.radiusTag, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: FontSkin.radiusTag, style: .continuous)
                            .stroke(applied ? studio.color(.primaryText) : studio.color(.border), lineWidth: 0.5))
                    Text(title)
                        .font(MinisThemeShape.messageFont(size: fsTitle, weight: .semibold))
                        .tracking(-0.2)
                        .foregroundStyle(studio.color(.primaryText))
                    Spacer(minLength: 0)
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                        Text(AppLocalized("正在用"))
                            .font(MinisThemeShape.messageFont(size: fsCaption, weight: .semibold))
                    }
                    .foregroundStyle(studio.color(.primaryText))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(studio.color(.iconTile))
                    .clipShape(RoundedRectangle(cornerRadius: FontSkin.radiusPill, style: .continuous))
                    .opacity(applied ? 1 : 0)
                    .scaleEffect(applied ? 1 : 0.9)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(AppLocalized("今天也想你"))
                        .font(font)
                        .lineSpacing(fsBody * 0.25)
                        .foregroundStyle(studio.color(.primaryText))
                        .lineLimit(1)
                    Text(fontSpecimenEN(number: number))
                        .font(font)
                        .lineSpacing(fsBody * 0.2)
                        .tracking(-0.2)
                        .foregroundStyle(studio.color(.secondaryText))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 10)
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(studio.color(.border))
                        .frame(height: 0.5)
                }
            }
            .padding(.horizontal, fontSettings.density(16))
            .padding(.vertical, fontSettings.density(14))
            .background(studio.color(.surface))
            .clipShape(RoundedRectangle(cornerRadius: FontSkin.radiusMedium, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: FontSkin.radiusMedium, style: .continuous)
                .stroke(applied ? studio.color(.primaryText) : studio.color(.border), lineWidth: applied ? 1.5 : 1))
            .shadow(color: .black.opacity(applied ? 0.12 : 0.03), radius: applied ? 16 : 3, x: 0, y: applied ? 4 : 1)
            .shadow(color: .black.opacity(applied ? 0 : 0.02), radius: 2, x: 0, y: 1)
        }
        .buttonStyle(FontPressStyle(scale: 0.985))
    }

    /// Uploaded card, same v2 chrome as the built-in card, but
    /// the delete control is v2's: a 44pt circle trash icon in
    /// the top row (tertiary icon, danger on hover in the web
    /// version — taps here open the delete modal), NOT the 195
    /// full-width "删除" text row under the specimen. The delete
    /// button is a sibling of the two apply buttons, never nested
    /// inside one, so tapping it cannot also apply the font —
    /// the web version's `stopPropagation` in native form. The
    /// card carries v2's 0.2s fade-and-shrink exit transition.
    private func uploadedFontCard(_ font: UploadedFont) -> some View {
        let applied = isUploadedFontApplied(font)
        let applyAction = {
            guard applyUploadedFont(font) else { return }
            fontTapHaptic()
            showFontToast(AppLocalized("全局字体已换装：\(font.title)"))
        }
        return VStack(alignment: .leading, spacing: fontSettings.density(10)) {
            HStack(spacing: 4) {
                Button(action: applyAction) {
                    HStack {
                        Text(font.number)
                            .font(.system(size: fsCaption, weight: .semibold, design: .monospaced))
                            .foregroundStyle(applied ? studio.color(.surface) : studio.color(.secondaryText))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(applied ? studio.color(.primaryText) : studio.color(.chip))
                            .clipShape(RoundedRectangle(cornerRadius: FontSkin.radiusTag, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: FontSkin.radiusTag, style: .continuous)
                                .stroke(applied ? studio.color(.primaryText) : studio.color(.border), lineWidth: 0.5))
                        Text(font.title)
                            .font(MinisThemeShape.messageFont(size: fsTitle, weight: .semibold))
                            .tracking(-0.2)
                            .foregroundStyle(studio.color(.primaryText))
                        Spacer(minLength: 0)
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                            Text(AppLocalized("正在用"))
                                .font(MinisThemeShape.messageFont(size: fsCaption, weight: .semibold))
                        }
                        .foregroundStyle(studio.color(.primaryText))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(studio.color(.iconTile))
                        .clipShape(RoundedRectangle(cornerRadius: FontSkin.radiusPill, style: .continuous))
                        .opacity(applied ? 1 : 0)
                        .scaleEffect(applied ? 1 : 0.9)
                    }
                }
                .buttonStyle(FontPressStyle(scale: 0.985))
                Button { fontPendingDelete = font } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 15))
                        .foregroundStyle(studio.color(.tertiaryText))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(FontPressStyle(scale: 0.9))
            }
            Button(action: applyAction) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(AppLocalized("今天也想你"))
                        .font(uploadedFontStore.previewFont(for: font, size: globalPointSize))
                        .lineSpacing(fsBody * 0.25)
                        .foregroundStyle(studio.color(.primaryText))
                        .lineLimit(1)
                    Text("The quick brown fox jumps over the lazy dog. 0123456789")
                        .font(uploadedFontStore.previewFont(for: font, size: globalPointSize))
                        .lineSpacing(fsBody * 0.2)
                        .tracking(-0.2)
                        .foregroundStyle(studio.color(.secondaryText))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 10)
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(studio.color(.border))
                        .frame(height: 0.5)
                }
            }
            .buttonStyle(FontPressStyle(scale: 0.985))
        }
        .padding(.horizontal, fontSettings.density(16))
        .padding(.vertical, fontSettings.density(14))
        .background(studio.color(.surface))
        .clipShape(RoundedRectangle(cornerRadius: FontSkin.radiusMedium, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: FontSkin.radiusMedium, style: .continuous)
            .stroke(applied ? studio.color(.primaryText) : studio.color(.border), lineWidth: applied ? 1.5 : 1))
        .shadow(color: .black.opacity(applied ? 0.12 : 0.03), radius: applied ? 16 : 3, x: 0, y: applied ? 4 : 1)
        .shadow(color: .black.opacity(applied ? 0 : 0.02), radius: 2, x: 0, y: 1)
        .transition(.scale(scale: 0.92).combined(with: .opacity))
    }

    /// Whether a built-in family card is the current global
    /// pick, matched by number (never by title). A card is
    /// not the pick while any uploaded font is the global
    /// choice. Uploaded fonts are checked separately, by
    /// postScript name.
    private func isFontApplied(number: String, familyTitle: String) -> Bool {
        guard let item = UploadedFontStore.builtIns.first(where: { $0.number == number }) else { return false }
        if MinisThemeShape.globalCustomFontName != nil { return false }
        return MinisThemeShape.globalFontFamily == item.family
    }

    private func isUploadedFontApplied(_ font: UploadedFont) -> Bool {
        MinisThemeShape.globalCustomFontName == font.postScriptName
    }

    /// Apply a built-in family. Returns false (and changes
    /// nothing) when the card is already the pick — v2's
    /// early return, so re-taps stay silent.
    private func applyFont(number: String, familyTitle: String) -> Bool {
        guard let item = UploadedFontStore.builtIns.first(where: { $0.number == number }) else { return false }
        guard !isFontApplied(number: number, familyTitle: familyTitle) else { return false }
        studio.setFontFamily(item.family)
        studio.setGlobalCustomFont(nil)
        return true
    }

    /// Apply an uploaded font. Same early-return contract.
    /// The upload-success path also calls this, then shows its
    /// own install toast instead of the换装 toast.
    private func applyUploadedFont(_ font: UploadedFont) -> Bool {
        guard !isUploadedFontApplied(font) else { return false }
        studio.setGlobalCustomFont(font.postScriptName)
        return true
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

    /// Show a v2-style toast for 2.2s, replacing any toast already
    /// up (v2 clears its timer on every new toast, so rapid taps
    /// never stack pills).
    private func showFontToast(_ message: String) {
        withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.28)) {
            fontToastMessage = message
        }
        let shown = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            if fontToastMessage == shown {
                withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.28)) {
                    fontToastMessage = nil
                }
            }
        }
    }

    /// v2 haptic: a light tick on every font/colour tap, the
    /// in-repo equivalent of the HTML `navigator.vibrate(12)`.
    private func fontTapHaptic() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    // MARK: - Colour variables (replaces the 名片 tab)

    /// The complete CSS-style global-variable colour panel.
    /// Every colour slot in the theme system is here, each row
    /// writes the GLOBAL scope (never a page scope), so a change
    /// lands app-wide at once — that is what "global variable"
    /// means in this app. Light and dark are two full variable
    /// sets: the mode picker picks which set is LIVE (following
    /// the system, or forced), the editing picker picks which set
    /// these rows edit, so the dark set can be tuned while the
    /// phone is in light mode and vice versa.
    // MARK: - Shake preview (2026-11-02 shake-preview batch)
    //
    // Rolling shows only a preview and never touches live colours.
    // The main button always rolls: its label is "摇一摇" before the
    // first roll and "再摇一次" once a preview exists. The three
    // buttons under a preview are Keep, Save-as-set, Discard:
    // Keep applies the preview to the global colours and persists
    // it, then closes the preview; Save-as-set keeps first, then
    // jumps to the theme category with a message telling the user
    // to name and save it there — it never silently saves and
    // never invents a name; Discard only drops the preview state.

    private func rollShakePreview() {
        let rolled = AppearanceThemeShuffle.shufflePureRandom()
        shakePreview = ShakePreviewRoll(light: rolled.light, dark: rolled.dark, name: rolled.name)
    }

    private func keepShakePreview() {
        guard let roll = shakePreview else { return }
        studio.applyRolledPalette(light: roll.light, dark: roll.dark)
        shakePreview = nil
        showFontToast(AppLocalized("已留下来"))
    }

    private func saveShakePreviewAsSet() {
        keepShakePreview()
        category = .theme
        themeSaveMessage = AppLocalized("已留下来，上面起个名，把这套存下来")
    }

    private func discardShakePreview() {
        shakePreview = nil
    }

    /// A colour from the shake preview's own light/dark map. A missing
    /// or malformed preview value falls back to the preview's own
    /// primary text for text roles (never to the rolled accent as
    /// body text), and to the live theme colour for everything else —
    /// never to a grey neither the preview nor the live theme carries.
    private func shakePreviewColor(_ role: AppearanceColorRole, variant: AppearanceVariant) -> Color {
        guard let roll = shakePreview else { return studio.color(role) }
        let map = variant == .dark ? roll.dark : roll.light
        if let raw = map[role] {
            let cleaned = raw.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            let hexDigits = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
            if (cleaned.count == 6 || cleaned.count == 8)
                && cleaned.unicodeScalars.allSatisfy({ hexDigits.contains($0) }) {
                return Color(hex: raw)
            }
        }
        if role == .bubbleText || role == .assistantBubbleText {
            return shakePreviewColor(.primaryText, variant: variant)
        }
        return studio.color(role)
    }

    /// One preview sample in one variant: a swatch strip plus two
    /// sample bubbles. The bubble text uses the preview's own
    /// near-neutral text roles — never the rolled accent as body
    /// text — and the rest of the shop page keeps the live theme,
    /// so the preview never dyes the whole page.
    private func shakePreviewSample(variant: AppearanceVariant) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(variant == .dark ? AppLocalized("深色") : AppLocalized("浅色"))
                .font(.system(size: fsCaption, design: .monospaced))
                .foregroundStyle(shakePreviewColor(.secondaryText, variant: variant))
            HStack(spacing: 6) {
                ForEach([AppearanceColorRole.canvas, .surface, .accent, .userBubble, .assistantBubble], id: \.self) { role in
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(shakePreviewColor(role, variant: variant))
                        .frame(height: 24)
                }
            }
            HStack {
                Text(AppLocalized("今天也想你"))
                    .font(.system(size: fsSub))
                    .foregroundStyle(shakePreviewColor(.assistantBubbleText, variant: variant))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(shakePreviewColor(.assistantBubble, variant: variant), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                Spacer(minLength: 0)
            }
            HStack {
                Spacer(minLength: 0)
                Text(AppLocalized("今天也想你"))
                    .font(.system(size: fsSub))
                    .foregroundStyle(shakePreviewColor(.bubbleText, variant: variant))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(shakePreviewColor(.userBubble, variant: variant), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
        .padding(12)
        .background(shakePreviewColor(.canvas, variant: variant))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(shakePreviewColor(.border, variant: variant), lineWidth: 1))
    }

    private var shakeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(AppLocalized("摇一摇"))
                .font(.system(size: fsTitle, weight: .semibold, design: .serif))
                .foregroundStyle(studio.color(.primaryText))
            Text(AppLocalized("摇出一套新配色，先预览再决定；预览时现场配色不动。"))
                .font(.system(size: fsSub))
                .foregroundStyle(studio.color(.secondaryText))
            Button {
                fontTapHaptic()
                rollShakePreview()
            } label: {
                Text(shakePreview == nil ? AppLocalized("摇一摇") : AppLocalized("再摇一次"))
                    .font(.system(size: fsSub, weight: .semibold))
                    .foregroundStyle(studio.color(.surface))
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 44)
                    .background(studio.color(.accent))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            if let roll = shakePreview {
                Text(roll.name)
                    .font(.system(size: fsTitle, weight: .semibold, design: .serif))
                    .foregroundStyle(studio.color(.primaryText))
                shakePreviewSample(variant: .light)
                shakePreviewSample(variant: .dark)
                Button {
                    fontTapHaptic()
                    keepShakePreview()
                } label: {
                    Text(AppLocalized("留下来"))
                        .font(.system(size: fsSub, weight: .semibold))
                        .foregroundStyle(studio.color(.surface))
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 44)
                        .background(studio.color(.accent))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                HStack(spacing: 12) {
                    Button {
                        fontTapHaptic()
                        saveShakePreviewAsSet()
                    } label: {
                        Text(AppLocalized("存一套"))
                            .font(.system(size: fsSub, weight: .semibold))
                            .foregroundStyle(studio.color(.primaryText))
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: 44)
                            .background(studio.color(.surface))
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(studio.color(.border), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    Button {
                        fontTapHaptic()
                        discardShakePreview()
                    } label: {
                        Text(AppLocalized("放弃"))
                            .font(.system(size: fsSub, weight: .semibold))
                            .foregroundStyle(studio.color(.destructive))
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                }
                Text(AppLocalized("预览只画这一小块，店页其他地方仍是现场主题；放弃就什么都不变。"))
                    .font(.system(size: fsCaption))
                    .foregroundStyle(studio.color(.secondaryText))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(studio.color(.surface))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(studio.color(.border), lineWidth: 1))
        .shadow(color: .black.opacity(0.03), radius: 3, x: 0, y: 1)
        .shadow(color: .black.opacity(0.02), radius: 2, x: 0, y: 1)
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    private var colorVarsView: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(AppLocalized("配色变量"))
                    .font(ChatFont.font(15, weight: .bold))
                    .foregroundStyle(studio.color(.primaryText))
                Text(AppLocalized("改一处，全 App 一起变。浅色与深色是两套完整变量，切换模式整套换，不是单色反色。"))
                    .font(ChatFont.font(11))
                    .foregroundStyle(studio.color(.secondaryText))
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)

            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(AppLocalized("白天 / 黑夜"))
                        .font(ChatFont.font(13, weight: .semibold))
                        .foregroundStyle(studio.color(.primaryText))
                    Picker("", selection: $appearanceMode) {
                        Text(AppLocalized("跟随系统")).tag(0)
                        Text(AppLocalized("浅色")).tag(1)
                        Text(AppLocalized("深色")).tag(2)
                    }
                    .pickerStyle(.segmented)
                    Text(AppLocalized("跟随系统就跟着手机走；选浅色或深色就固定那一套。"))
                        .font(ChatFont.font(11))
                        .foregroundStyle(studio.color(.secondaryText))
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(AppLocalized("正在编辑哪一套变量"))
                        .font(ChatFont.font(13, weight: .semibold))
                        .foregroundStyle(studio.color(.primaryText))
                    Picker("", selection: $editingVariant) {
                        Text(AppLocalized("浅色变量")).tag(AppearanceVariant.light)
                        Text(AppLocalized("深色变量")).tag(AppearanceVariant.dark)
                    }
                    .pickerStyle(.segmented)
                    Text(AppLocalized("跟上面那档无关：手机是浅色时也能调深色那套，改完切模式就看见。"))
                        .font(ChatFont.font(11))
                        .foregroundStyle(studio.color(.secondaryText))
                }
            }
            .padding(16)
            .background(studio.color(.surface))
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(studio.color(.border), lineWidth: 1))
            .padding(.horizontal, 16)
            .padding(.top, 12)

            shakeSection

            ForEach(colorVarGroups) { group in
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(group.title)
                            .font(ChatFont.font(15, weight: .bold))
                            .foregroundStyle(studio.color(.primaryText))
                        Text(group.hint)
                            .font(ChatFont.font(11))
                            .foregroundStyle(studio.color(.secondaryText))
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 10)
                    ForEach(Array(group.roles.enumerated()), id: \.element) { index, role in
                        if index > 0 {
                            Rectangle()
                                .fill(studio.color(.border).opacity(0.22))
                                .frame(height: 0.5)
                                .padding(.leading, 16)
                        }
                        colorVarRow(role)
                    }
                }
                .background(studio.color(.surface))
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(studio.color(.border), lineWidth: 1))
                .padding(.horizontal, 16)
                .padding(.top, 24)
            }

            Button {
                fontTapHaptic()
                studio.resetGlobalColors()
                showFontToast(AppLocalized("已恢复默认配色"))
            } label: {
                Text(AppLocalized("恢复默认配色"))
                    .font(ChatFont.font(13, weight: .semibold))
                    .foregroundStyle(studio.color(.primaryText))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(studio.color(.surface))
                    .clipShape(RoundedRectangle(cornerRadius: 999, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 999, style: .continuous)
                        .stroke(studio.color(.border), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.top, 24)
            Text(AppLocalized("只清全局配色，回到内置单色；逐页单独调过的颜色不动。"))
                .font(ChatFont.font(11))
                .foregroundStyle(studio.color(.secondaryText))
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 32)
        }
    }

    /// Panel groups, in the old studio page's grouping order.
    /// The chat group adds the two bubble-text slots the old
    /// page's chat group never listed — without them the panel
    /// would not be the "complete set" it claims to be.
    private struct ColorVarGroup: Identifiable {
        var title: String
        var hint: String
        var roles: [AppearanceColorRole]
        var id: String { title }
    }

    private var colorVarGroups: [ColorVarGroup] {
        [
            ColorVarGroup(title: AppLocalized("文字"), hint: AppLocalized("标题、正文、说明、时间戳——所有字"),
                          roles: [.primaryText, .secondaryText, .tertiaryText]),
            ColorVarGroup(title: AppLocalized("背景与卡片"), hint: AppLocalized("页面底衬、大块卡片、弹窗浮层、次要底块"),
                          roles: [.canvas, .surface, .raised, .mutedSurface]),
            ColorVarGroup(title: AppLocalized("控件"), hint: AppLocalized("图标底、胶囊底、输入框、边线——小零件"),
                          roles: [.iconTile, .chip, .field, .border]),
            ColorVarGroup(title: AppLocalized("强调"), hint: AppLocalized("按钮、开关、选中态"),
                          roles: [.accent]),
            ColorVarGroup(title: AppLocalized("聊天"), hint: AppLocalized("聊天气泡与气泡里的字（未设置时跟主文字走）"),
                          roles: [.userBubble, .assistantBubble, .bubbleText, .assistantBubbleText]),
            ColorVarGroup(title: AppLocalized("状态"), hint: AppLocalized("成功、警告、危险"),
                          roles: [.success, .warning, .destructive]),
        ]
    }

    /// Contrast warning for a colour-panel row, live values only.
    /// Only primaryText (4.5) and accent (3.0) are checked, against
    /// canvas and surface of the variant being edited. Nil when the
    /// value passes, so passing rows show nothing. This never blocks:
    /// the user's own colour choice is respected, it just never lands
    /// silently unreadable.
    private func colorContrastWarning(for role: AppearanceColorRole) -> String? {
        let level: AppearanceContrast.Level
        switch role {
        case .primaryText: level = .body
        case .accent: level = .ui
        default: return nil
        }
        let fg = studio.hex(role, scope: .global, variant: editingVariant)
        var failing: [String] = []
        for (bgName, bgRole) in [(AppLocalized("底色"), AppearanceColorRole.canvas),
                                 (AppLocalized("卡片底"), AppearanceColorRole.surface)] {
            let bg = studio.hex(bgRole, scope: .global, variant: editingVariant)
            let r = AppearanceContrast.ratio(fg, on: bg)
            if r < AppearanceContrast.threshold(level) {
                failing.append(String(format: AppLocalized("%@约 %.1f"), bgName, r))
            }
        }
        guard !failing.isEmpty else { return nil }
        return String(format: AppLocalized("%@对比不够：%@（要 %.1f），个别地方可能看不清"),
                      role.title, failing.joined(separator: "、"),
                      AppearanceContrast.threshold(level))
    }

    /// One variable row: the old studio page's row mode
    /// (ColorPicker + title + hint + #hex + revert-when-overridden),
    /// bound to the GLOBAL scope and the set being edited.
    private func colorVarRow(_ role: AppearanceColorRole) -> some View {
        VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 13) {
            ColorPicker("", selection: studio.colorBinding(role, scope: .global, variant: editingVariant),
                        supportsOpacity: false)
                .labelsHidden()
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(role.title)
                    .font(ChatFont.font(13, weight: .medium))
                    .foregroundStyle(studio.color(.primaryText))
                Text(role.hint)
                    .font(ChatFont.font(10))
                    .foregroundStyle(studio.color(.secondaryText).opacity(0.72))
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            Text("#\(studio.hex(role, scope: .global, variant: editingVariant))")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(studio.color(.secondaryText).opacity(0.55))
            if studio.hasOverride(role, scope: .global, variant: editingVariant) {
                Button {
                    studio.clearOverride(role, scope: .global, variant: editingVariant)
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(studio.color(.secondaryText))
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        if let warning = colorContrastWarning(for: role) {
            Text(warning)
                .font(.system(size: fsSub))
                .foregroundStyle(studio.color(.destructive))
                .padding(.horizontal, 16)
        }
        }
    }

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
                    .font(.system(size: fsTitle, weight: .bold, design: .serif))
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
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(studio.color(.border))
                    .frame(height: 0.5)
            }

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
                    .font(.system(size: fsSub, weight: .semibold))
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
                    HStack(spacing: 6) {
                        Text(pack.title)
                            .font(.system(size: fsTitle, weight: .bold, design: .serif))
                            .foregroundStyle(studio.color(.primaryText))
                        Text("·")
                            .font(.system(size: fsTitle, weight: .bold))
                            .foregroundStyle(studio.color(.secondaryText))
                        Text(pack.number)
                            .font(.system(size: fsCaption, weight: .semibold, design: .monospaced))
                            .foregroundStyle(studio.color(.secondaryText))
                        Spacer(minLength: 0)
                    }
                    Text(AppLocalized("在模拟聊天里看这款的长句和短句，确认后再换上；只换这一边的气泡，另一边不动，其他搭配也不动。"))
                        .font(.system(size: fsSub))
                        .foregroundStyle(studio.color(.secondaryText))
                    Text(AppLocalized("组成：") + pack.composition.joined(separator: " · "))
                        .font(.system(size: fsCaption))
                        .foregroundStyle(studio.color(.secondaryText))
                    HStack(spacing: 12) {
                        Button(AppLocalized("保存成搭配")) {
                            outfitStore.save(bubblePack: pack)
                            closeDetail()
                        }
                        .font(.callout)
                        .foregroundStyle(studio.color(.accent))
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(studio.color(.accent), lineWidth: 1)
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
                        .background(studio.color(.accent))
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
    @ObservedObject private var fontSettings = FontSettings.shared

    @AppStorage("appLanguage") private var appLanguage: String = ""
    @AppStorage("appIconMode") private var appIconMode: Int = 0
    @AppStorage("launchScreen") private var launchScreen: Int = 0
    @AppStorage("returnKeyBehavior") private var returnKeyBehavior: Int = 0
    @AppStorage("chat.autoFocusAfterReply") private var autoFocusAfterReply: Bool = true
    @AppStorage("chat.autoExpandThinking") private var autoExpandThinking: Bool = true
    @AppStorage("keepScreenAwakeDuringTasks") private var keepScreenAwakeDuringTasks: Bool = false
    @State private var iconFailed = false

    // Same fs ladder as the shop's main view (fsTitle / fsBody /
    // fsSub / fsCaption), derived from the one global size, so
    // this section follows the global font size instead of
    // fixed sizes. Weights and roles stay as they were.
    private var fsTitle: CGFloat { fontSettings.globalPointSize * 1.15 }
    private var fsBody: CGFloat { fontSettings.globalPointSize }
    private var fsSub: CGFloat { fontSettings.globalPointSize * 0.92 }
    private var fsCaption: CGFloat { fontSettings.globalPointSize * 0.82 }

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
                                .font(.system(size: fsBody))
                                .foregroundStyle(studio.color(.secondaryText))
                                .frame(width: 26)
                            Text(lang.name)
                                .font(.system(size: fsBody))
                                .foregroundStyle(studio.color(.primaryText))
                            Spacer(minLength: 0)
                            if appLanguage == lang.id {
                                Image(systemName: "checkmark")
                                    .font(.system(size: fsCaption, weight: .semibold))
                                    .foregroundStyle(studio.color(.primaryText))
                            }
                        }
                        .padding(.vertical, fontSettings.density(4))
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
                                        .font(.system(size: fsBody, weight: .medium))
                                        .foregroundStyle(studio.color(.primaryText))
                                    Text(option.subtitle)
                                        .font(.system(size: fsSub))
                                        .foregroundStyle(studio.color(.secondaryText))
                                }
                                Spacer(minLength: 0)
                                if appIconMode == option.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(studio.color(.primaryText))
                                        .font(.system(size: fsBody))
                                }
                            }
                            .padding(.vertical, fontSettings.density(3))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if iconFailed {
                        Text(AppLocalized("换图标失败，请重试。"))
                            .font(.system(size: fsSub))
                            .foregroundStyle(studio.color(.secondaryText))
                            .padding(.top, fontSettings.density(6))
                    }
                } else {
                    Text(AppLocalized("这台设备不支持换图标。"))
                        .font(.system(size: fsBody))
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
                .font(.system(size: fsBody))
                .tint(studio.color(.primaryText))
                Text(AppLocalized("打开 App 时显示什么。「自动」会在上次会话超过 15 分钟时开新会话。"))
                    .font(.system(size: fsSub))
                    .foregroundStyle(studio.color(.secondaryText))
            }

            sectionTitle(AppLocalized("输入"))
            sectionCard {
                Picker(AppLocalized("回车键"), selection: $returnKeyBehavior) {
                    Text(AppLocalized("换行")).tag(0)
                    Text(AppLocalized("发送")).tag(1)
                }
                .pickerStyle(.segmented)
                .font(.system(size: fsBody))
                Text(AppLocalized("回车是换行还是发送。硬件键盘的 Shift+回车 永远是换行。"))
                    .font(.system(size: fsSub))
                    .foregroundStyle(studio.color(.secondaryText))
                Divider().padding(.vertical, fontSettings.density(4))
                Toggle(AppLocalized("回复后自动聚焦"), isOn: $autoFocusAfterReply)
                    .font(.system(size: fsBody))
                    .tint(studio.color(.primaryText))
                Text(AppLocalized("模型回复完自动弹出键盘，方便接着问。不想被键盘打断就关掉。"))
                    .font(.system(size: fsSub))
                    .foregroundStyle(studio.color(.secondaryText))
            }

            sectionTitle(AppLocalized("聊天行为"))
            sectionCard {
                Toggle(AppLocalized("流式展开思考"), isOn: $autoExpandThinking)
                    .font(.system(size: fsBody))
                    .tint(studio.color(.primaryText))
                Text(AppLocalized("开着时，模型推理中的思考块自动展开，完成后收起。关掉就保持折叠，点一下才看。"))
                    .font(.system(size: fsSub))
                    .foregroundStyle(studio.color(.secondaryText))
                Divider().padding(.vertical, fontSettings.density(4))
                Toggle(AppLocalized("自动分组"), isOn: autoGroupingBinding)
                    .font(.system(size: fsBody))
                    .tint(studio.color(.primaryText))
                Text(AppLocalized("首次生成会话标题时，顺便归进匹配的分组。每个会话只做一次，只用你已经建好的分组。"))
                    .font(.system(size: fsSub))
                    .foregroundStyle(studio.color(.secondaryText))
                Divider().padding(.vertical, fontSettings.density(4))
                Toggle(AppLocalized("任务时屏幕常亮"), isOn: $keepScreenAwakeDuringTasks)
                    .font(.system(size: fsBody))
                    .tint(studio.color(.primaryText))
                Text(AppLocalized("有会话在跑任务时不熄屏。会更费电。"))
                    .font(.system(size: fsSub))
                    .foregroundStyle(studio.color(.secondaryText))
            }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: fsTitle, weight: .bold))
            .foregroundStyle(studio.color(.primaryText))
            .padding(.horizontal, 16)
            .padding(.top, fontSettings.density(22))
            .padding(.bottom, fontSettings.density(12))
    }

    private func sectionCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: fontSettings.density(12)) {
            content()
        }
        .padding(fontSettings.density(16))
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
