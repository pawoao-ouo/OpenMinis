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
    /// [T-67] 店里这几处动画一直不看系统开关。开启“减少动态效果”后,
    /// 呼吸点、字号变化的回弹、详情浮层的进出都还照动。
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
    /// Whether the current toast is a warning (missing pieces on
    /// outfit apply): warning toasts show a warning icon instead
    /// of the success checkmark. Set by showFontToast(_:warning:).
    @State private var fontToastIsWarning = false
    /// [T-49] 刚删掉的那套,给店里一个撤销位。
    @State private var lastDeletedTheme: AppearanceSavedTheme?
    /// Which variable set the colour panel is editing. Independent
    /// of the mode picker: with "跟随系统" on a light phone she can
    /// still edit (and preview, by flipping the mode) the dark set.
    @State private var editingVariant: AppearanceVariant = .light
    /// The one mode key the whole app already uses (MinisApp root
    /// `.preferredColorScheme` + AppearanceStudio dynamic colours).
    /// The panel reuses it — it must NOT invent a second mode key.
    @AppStorage(AppearanceMode.defaultsKey) private var appearanceMode = 0
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
    @State private var themeRenameItem: AppearanceSavedTheme?
    @State private var themeRenameName = ""
    @State private var themeConfirmApply = false
    /// Close tokens: a pending delayed nil is valid only for the
    /// close that scheduled it. Opening a new detail bumps the
    /// token, so a stale close can never nil a just-opened page
    /// (the close-then-reopen race in the theme-place research).
    @State private var themeCloseToken = 0
    @State private var bubbleCloseToken = 0
    @State private var pendantCloseToken = 0
    /// Which theme-sheet row is expanded for inspection, if any.
    @State private var themeInspectedRow: String?
    @State private var themePendingApplyItem: AppearanceSavedTheme?
    @State private var themePendingApplyWarning: String?
    @State private var wallpaperPickerPresented = false
    @State private var pickedWallpaperItem: PhotosPickerItem?
    @State private var pickedWallpaperIsDark = false
    @State private var wallpaperMessage: String?
    /// [分页壁纸] 拾图这次要贴到哪一页。只放内存里：点"选一张"时设，
    /// 落地后在 applyPickedWallpaper 的 defer 里回到 .global；全局
    /// 那组按钮自己也先设 .global 再打开拾图，免得上一次的页还留着。
    @State private var pickedWallpaperScope: AppearanceScope = .global
    @State private var pageWallpaperMessage: String?
    /// [T-39] 从死页搬来的两组贴图各自要贴到哪。
    @State private var pickedDecalTarget: DecalTarget?
    @State private var decalMessage: String?

    private enum DecalTarget {
        case inputBar, thinkingCard, category(String)
        /// [T-39] 死页删掉之后这几样在界面上就没有入口了，必须补回来：
        /// 她的头像、AI 的头像、立绘、设置里的行图标。留着不动等于借删代码删功能。
        case userAvatar, assistantAvatar, characterArt, icon(String)
    }
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
    /// Shake roll mode: nil = the 11 curated sets (shufflePureRandom),
    /// a Mood = a random Morandi roll inside that mood's parameter
    /// range (shuffle(seed:mood:)). Never persisted — the roll button
    /// reads it, nothing else does.
    @State private var shakeMood: AppearanceThemeShuffle.Mood?
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

    /// AI side name, same source as the dead page
    /// (`AppearanceStudioView.aiName`): the persona name from
    /// `SoulStore.cachedMetadata`, falling back to "AI" when no
    /// name is set — never the shop's `sidePickerLabel` fallback.
    @MainActor private var aiName: String {
        let n = SoulStore.cachedMetadata.name
        return n.isEmpty ? "AI" : n
    }

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
                .font(.system(size: globalPointSize * 15 / 13, weight: .semibold))
                .foregroundStyle(studio.color(.primaryText))
            Picker("", selection: $editingSide) {
                Text(sidePickerLabel(for: .assistant)).tag(DressingSide.assistant)
                Text(sidePickerLabel(for: .user)).tag(DressingSide.user)
            }
            .pickerStyle(.segmented)
            Text(AppLocalized("先选一边，再点卡片换上；改一边不会动另一边。"))
                .font(.system(size: globalPointSize))
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
            .background(AppearanceBackdrop(scope: .global))

            // v2 toast pill: black pill, white text, check icon
            // (warning icon when fontToastIsWarning), 10/18 padding,
            // 0 8 24 rgba(0,0,0,0.18) shadow, spring in/out, gone
            // after 2.2s. Sits above the page but below the slide-in
            // detail pages.
            if let toast = fontToastMessage {
                VStack {
                    Spacer(minLength: 0)
                    HStack(spacing: 6) {
                        Image(systemName: fontToastIsWarning ? "exclamationmark.triangle.fill" : "checkmark")
                            .font(.system(size: 14, weight: .semibold))
                        Text(toast)
                            .font(ChatFont.font(12, weight: .semibold))
                            .lineLimit(2)
                        // [T-49] 删套之后这里多一个「撤销」，不用再跑别处。
                        if lastDeletedTheme != nil {
                            Button(AppLocalized("撤销")) { undoDeleteTheme() }
                                .font(ChatFont.font(12, weight: .bold))
                                .foregroundStyle(FontSettings.contrastForeground(on: studio.hex(.primaryText, variant: studio.activeVariant)))
                                .padding(.leading, 6)
                                .buttonStyle(PressableStyle(scale: 0.94))
                        }
                    }
                    // [六定-6] 提示条填主文字，字跟着反色。
                    .foregroundStyle(FontSettings.contrastForeground(on: studio.hex(.primaryText, variant: studio.activeVariant)))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(studio.color(.primaryText))
                    .clipShape(RoundedRectangle(cornerRadius: 999, style: .continuous))
                    .shadow(color: .black.opacity(0.18), radius: 24, x: 0, y: 8)
                    .padding(.bottom, 24)
                    // [T-63] 这条黑底小条是全店唯一的确认途径 —— 换套、删字体、
                    // 摇一摇、恢复默认，做完都只靠它。VoiceOver 以前完全听不到
                    // (它 2.2 秒后自己消失，读屏还在念上一句)。现在整条作为一个
                    // 无障碍元素，并由 showFontToast 主动发一条 announcement。
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(toast)
                    .accessibilityAddTraits(.isStaticText)
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
        .animation(reduceMotion ? nil : .easeOut(duration: 0.32), value: detailPack != nil)
        // Detail overlays animate out instead of vanishing: the
        // parent used to watch only detailPack, so a theme or
        // pendant close jumped after its sheet delay.
        .animation(reduceMotion ? nil : .easeOut(duration: 0.32), value: detailTheme != nil)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.32), value: detailPendant != nil)
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
            // [T-39] 同一个拾图入口，按"这次想贴哪"分流：原来这类活只有
            // 死页能干，现在这一页也干得了。
            if let target = pickedDecalTarget {
                Task { await applyPickedDecal(item, target: target) }
            } else {
                Task { await applyPickedWallpaper(item) }
            }
        }
    }

    // MARK: - Top bar (52pt, draft measurement)

    private var topBar: some View {
        ZStack {
            Text(AppLocalized("装扮"))
                .font(.system(size: globalPointSize * 20 / 13, weight: .bold))
                .foregroundStyle(studio.color(.primaryText))
            HStack(spacing: 0) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(studio.color(.primaryText))
                        .padding(.leading, 16)
                        .frame(minWidth: 60, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(FontPressStyle(scale: 0.92))
                Spacer(minLength: 0)
            }
            .padding(.trailing, 16)
        }
        .frame(height: 52)
        .background(studio.color(.surface))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(studio.color(.border).opacity(0.4))
                .frame(height: 0.5)
        }
    }

    // MARK: - Category tab rail (capsule pills, 44pt)

    private var tabRail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(DressingCategory.allCases) { item in
                    Button { category = item } label: {
                        Text(item.title)
                            .font(ChatFont.font(17, weight: category == item ? .bold : .regular))
                            .foregroundStyle(category == item
                                ? FontSettings.contrastForeground(on: studio.hex(.primaryText, variant: studio.activeVariant))
                                : studio.color(.secondaryText))
                            .padding(.horizontal, 16)
                            // [T-38] 44pt 最小触达:胶囊再小也该点得中。
                            .frame(minHeight: FontSettings.minHitTarget)
                            .background(category == item
                                ? studio.color(.primaryText)
                                : studio.color(.mutedSurface))
                            .clipShape(Capsule())
                            .overlay(Capsule()
                                .stroke(category == item
                                    ? Color.clear
                                    : studio.color(.border), lineWidth: 1))
                    }
                    .buttonStyle(FontPressStyle(scale: 0.98))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
        .background(studio.color(.surface))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(studio.color(.border).opacity(0.4))
                .frame(height: 0.5)
        }
    }

    // MARK: - Tag rail (in-flow, 44pt pills)

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
                            .font(ChatFont.font(15))
                            .foregroundStyle(tag == item
                                ? FontSettings.contrastForeground(on: studio.hex(.primaryText, variant: studio.activeVariant))
                                : studio.color(.secondaryText))
                            .padding(.horizontal, 16)
                            .frame(minHeight: FontSettings.minHitTarget)
                            .background(tag == item
                                ? studio.color(.primaryText)
                                : studio.color(.mutedSurface))
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(FontPressStyle(scale: 0.98))
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
                // [T-62] 有壁纸时这块大标题直接压在照片上，中间只隔一层 8%
                // 的底色 —— 换一张深色或杂乱的照片，标题就糊进去了。
                // 这里给它垫一块不透明的底：只在有壁纸时才出现，用负 padding
                // 把底色向外撑一圈，**不占布局**（标题位置、行高、间距都不变），
                // 所以没有壁纸的页面看起来和以前一模一样。
                .background {
                    if studio.hasWallpaper(.global) {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(studio.color(.canvas))
                            .padding(.horizontal, -6)
                            .padding(.vertical, -2)
                    }
                }
            Spacer(minLength: 0)
            Button { category = jumpTo } label: {
                Image(systemName: "chevron.right")
                    // At the default global size 13 this is exactly 17pt.
                    .font(.system(size: globalPointSize * 17 / 13))
                    .foregroundStyle(studio.color(.secondaryText))
                    .contentShape(Rectangle())
                    // 44pt hit area without growing the row: the clear
                    // overlay extends the tappable region into the
                    // row's existing padding instead of adding height.
                    // Device check still owed: confirm a tap 15pt
                    // above/below the glyph actually jumps.
                    .overlay {
                        Color.clear
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel(title)
            }
            .buttonStyle(FontPressStyle(scale: 0.92))
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
                .font(.system(size: globalPointSize * 13 / 13))
                .foregroundStyle(studio.color(.secondaryText))
                .padding(.horizontal, 16)
                .padding(.top, 10)
        }
    }

    private var nowWearingStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(AppLocalized("现在穿着"))
                .font(.system(size: globalPointSize * 15 / 13, weight: .semibold))
                .foregroundStyle(studio.color(.primaryText))
            ForEach(DressingSide.allCases, id: \.self) { side in
                HStack(spacing: 10) {
                    Text(sidePickerLabel(for: side))
                        .font(.system(size: globalPointSize * 14 / 13))
                        .foregroundStyle(studio.color(.primaryText))
                    if let pack = appliedPack(for: side) {
                        Text("\(pack.title) · \(pack.number)")
                            .font(.system(size: globalPointSize * 14 / 13))
                            .foregroundStyle(studio.color(.secondaryText))
                    } else {
                        Text(AppLocalized("还没选款式"))
                            .font(.system(size: globalPointSize * 14 / 13))
                            .foregroundStyle(studio.color(.secondaryText))
                    }
                    if let pendant = pendantStore.applied(for: side) {
                        Text("\(pendant.title) · \(pendant.number)")
                            .font(.system(size: globalPointSize * 14 / 13))
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
                        .clipShape(Capsule())
                        .buttonStyle(FontPressStyle(scale: 0.97))
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
            presetSection
                .padding(.top, 12)
            Button(AppLocalized("清理无主主题包")) { cleanupOrphanedThemePacks() }
                .font(.system(size: fsSub, weight: .semibold))
                .foregroundStyle(studio.color(.secondaryText))
                .frame(maxWidth: .infinity)
                .frame(minHeight: 44)
                .background(studio.color(.mutedSurface), in: Capsule())
                .buttonStyle(FontPressStyle(scale: 0.97))
                .padding(.horizontal, 16)
                .padding(.top, 8)
            globalWallpaperSection
                .padding(.top, 16)
            pageWallpaperSection
                .padding(.top, 16)
            stImportSection
                .padding(.top, 16)
        }
    }

    // MARK: - Built-in presets (theme category)
    //
    // The three built-in presets live in the backend
    // (AppearancePreset) with full light/dark palettes, but the
    // shop had no entry for them. The row below is the entry:
    // one card per preset, swatches from the preset's own light
    // palette, tap applies it through studio.applyPreset(_:).
    // applyPreset clears the global overrides first and then
    // writes the preset colours, so switching presets never
    // mixes two palettes. Swatches are 16pt (themeCardStrip
    // uses 20pt on a full-width card; four 20pt swatches do
    // not fit a third-width card).
    private var presetSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(AppLocalized("预设"))
                .font(.system(size: fsTitle, weight: .semibold, design: .serif))
                .foregroundStyle(studio.color(.primaryText))
            HStack(spacing: 12) {
                ForEach(AppearancePreset.allCases) { preset in
                    Button {
                        studio.applyPreset(preset)
                        showFontToast(String(format: AppLocalized("已换上「%@」"), preset.title))
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(preset.title)
                                .font(.system(size: fsSub, weight: .semibold))
                                .foregroundStyle(studio.color(.primaryText))
                            HStack(spacing: 4) {
                                ForEach([AppearanceColorRole.canvas, .accent, .userBubble, .assistantBubble], id: \.self) { role in
                                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                                        .fill(Color(hex: preset.colors.light[role] ?? "FFFFFF"))
                                        .frame(width: 16, height: 16)
                                        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                                            .stroke(studio.color(.border).opacity(0.5), lineWidth: 0.5))
                                }
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(studio.color(.surface))
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(studio.color(.border), lineWidth: 1))
                    }
                    .buttonStyle(FontPressStyle(scale: 0.98))
                }
            }
        }
        .padding(.horizontal, 16)
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
                .clipShape(Capsule())
                .buttonStyle(FontPressStyle(scale: 0.97))
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
    // canvas shade overlay). Global wallpaper only: page-scope
    // wallpapers are controlled by pageWallpaperSection just below
    // (chat + home); theme packs and theme sets still carry them.
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
                // 拾图的目标页：全局这组永远写 .global。只设状态不改行为，
                // 免得上一回分页那边的页还留着、全局这张贴错地方。
                pickedWallpaperScope = .global
                pickedWallpaperIsDark = studio.activeVariant == .dark
                wallpaperPickerPresented = true
            }
            .font(.system(size: fsSub, weight: .semibold))
            .foregroundStyle(studio.color(.surface))
            .frame(maxWidth: .infinity)
            .frame(minHeight: 44)
            .background(studio.color(.accent))
            .clipShape(Capsule())
            .buttonStyle(FontPressStyle(scale: 0.97))
            if studio.hasOwnWallpaper(.global) {
                Button(AppLocalized("清除全局壁纸")) {
                    studio.removeWallpaper(.global)
                    wallpaperMessage = AppLocalized("全局壁纸已清除")
                }
                .font(.system(size: fsSub, weight: .semibold))
                .foregroundStyle(studio.color(.destructive))
                .frame(maxWidth: .infinity)
                .frame(minHeight: 44)
                .overlay(Capsule()
                    .stroke(studio.color(.destructive), lineWidth: 1))
                .buttonStyle(FontPressStyle(scale: 0.97))
            }
            HStack(spacing: 12) {
                Text(AppLocalized("壁纸压色"))
                    .font(.system(size: fsSub))
                    .foregroundStyle(studio.color(.primaryText))
                Slider(value: $studio.wallpaperShade, in: 0...0.65)
                    .frame(minHeight: 44)
                    .accessibilityLabel(AppLocalized("壁纸压色"))
                // [T-68] 以前直接吐 "0.42" —— 一个没人知道含义的小数。
                // 换成浅/中/深，并在下面补一句它到底干什么。
                Text(wallpaperShadeLabel)
                    .font(.system(size: fsCaption, weight: .medium))
                    .foregroundStyle(studio.color(.secondaryText))
                    .frame(minWidth: 28, alignment: .trailing)
            }
            // [T-46] 卡片透明度（surfaceOpacity）一直没有活界面的入口——
            // 唯一那根滑杆在 `AppearanceStudioView` 里，而那个页面根本没有
            // 入口，点不到。于是这个值只会在"恢复默认"时被静默重置成 0.88，
            // 她却没有任何地方能看见、能改。现在接到这一页，壁纸压色旁边。
            HStack(spacing: 12) {
                Text(AppLocalized("卡片透明度"))
                    .font(.system(size: fsSub))
                    .foregroundStyle(studio.color(.primaryText))
                Slider(value: $studio.surfaceOpacity, in: 0.35...1)
                    .frame(minHeight: 44)
                    .accessibilityLabel(AppLocalized("卡片透明度"))
                Text(cardOpacityLabel)
                    .font(.system(size: fsCaption, weight: .medium))
                    .foregroundStyle(studio.color(.secondaryText))
                    .frame(minWidth: 34, alignment: .trailing)
            }
            Text(AppLocalized("卡片、输入栏、胶囊的底有多实。调低能透出壁纸；1 是完全不透明。"))
                .font(.system(size: fsCaption))
                .foregroundStyle(studio.color(.secondaryText))
            // [T-39] 这三组控件原来只活在 `AppearanceStudioView` 里，而那个
            // 页面没有任何入口。删页之前先把它们搬到这一页，否则就是借着
            // "清理死代码"把功能删掉——输入栏贴图、思考卡贴图、分类图，
            // 底层接口一直都在，只是没人点得到。
            deadPageImageSection
            // [T-46] 这三根旋钮以前没有任何复位入口，只能靠"恢复默认配色"
            // 顺手抹掉（而且不说）。现在给一个明说的按钮。
            Button(AppLocalized("透明度和压色回到默认")) {
                studio.resetOpacityDials()
                wallpaperMessage = AppLocalized("透明度与压色已回到默认。")
            }
            .font(.system(size: fsCaption, weight: .semibold))
            .foregroundStyle(studio.color(.secondaryText))
            .frame(maxWidth: .infinity, minHeight: 44)
            .overlay(Capsule().stroke(studio.color(.border), lineWidth: 1))
            .buttonStyle(FontPressStyle(scale: 0.97))
            // [T-68] 压色是干什么的，得有一句话。以前只有一根滑杆和一个数字。
            Text(AppLocalized("把壁纸压暗，字更清楚。"))
                .font(.system(size: fsCaption))
                .foregroundStyle(studio.color(.secondaryText))
            Text(AppLocalized("只管全局壁纸；聊天、首页各页的壁纸在下面的「分页壁纸」里改。"))
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

    // MARK: - Page wallpapers (theme category, page-wallpaper batch)
    //
    // Global wallpaper lives in globalWallpaperSection above. Page
    // scopes already exist in the backend (AppearanceScope.chat/.home,
    // studio.wallpaper / setWallpaper / removeWallpaper /
    // hasOwnWallpaper), but the shop had no control for them. This
    // section is the entry, chat + home only. Each row previews that
    // page's OWN image: wallpaper(for:) would fall back to the global
    // image, so the preview is only shown when hasOwnWallpaper is
    // true — otherwise the row says the page follows the global
    // image. Picking reuses the existing PhotosPicker flow: the row
    // sets pickedWallpaperScope before presenting, and
    // applyPickedWallpaper writes to that scope; dark-variant capture
    // and downsampling are unchanged. Clearing deletes the page's own
    // files, so the page falls back to the global image again
    // (removeWallpaper also clears the page's cleared-fallback flag).
    // Page-scope colours are a separate item and are not touched here.
    private var pageWallpaperSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(AppLocalized("分页壁纸"))
                .font(.system(size: fsTitle, weight: .semibold, design: .serif))
                .foregroundStyle(studio.color(.primaryText))
            Text(AppLocalized("聊天和首页可以单独挂一张图；没挂就跟着全局壁纸走。"))
                .font(.system(size: fsCaption))
                .foregroundStyle(studio.color(.secondaryText))
            ForEach([AppearanceScope.chat, .home], id: \.self) { scope in
                pageWallpaperRow(scope)
            }
            if let message = pageWallpaperMessage {
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

    /// Caption for the page-wallpaper preview. Keyed on hasOwnWallpaper,
    /// not on the image load: a page that owns a wallpaper whose file
    /// cannot be read says so, instead of claiming a preview or
    /// claiming it follows the global image.
    private func pageWallpaperCaption(_ scope: AppearanceScope) -> String {
        if !studio.hasOwnWallpaper(scope) {
            return AppLocalized("没有自己的壁纸，跟着全局走")
        }
        return studio.wallpaper(for: scope) == nil
            ? AppLocalized("壁纸读不出来")
            : AppLocalized("壁纸预览")
    }

    private func pageWallpaperRow(_ scope: AppearanceScope) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Text(scope.title)
                    .font(.system(size: fsSub, weight: .semibold))
                    .foregroundStyle(studio.color(.primaryText))
                Spacer(minLength: 0)
                if studio.hasOwnWallpaper(scope) {
                    Button(AppLocalized("清除")) {
                        studio.removeWallpaper(scope)
                        pageWallpaperMessage = String(format: AppLocalized("%@壁纸已清除，跟着全局走"), scope.title)
                    }
                    .font(.system(size: fsCaption, weight: .semibold))
                    .foregroundStyle(studio.color(.destructive))
                    .frame(minHeight: 44)
                }
            }
            ZStack(alignment: .bottomTrailing) {
                if studio.hasOwnWallpaper(scope), let image = studio.wallpaper(for: scope) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .clipped()
                    studio.color(.canvas).opacity(studio.wallpaperShade)
                } else {
                    studio.color(.canvas)
                }
                Text(pageWallpaperCaption(scope))
                    .font(.system(size: fsCaption, weight: .medium))
                    .foregroundStyle(studio.color(.primaryText))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(studio.color(.raised).opacity(0.85), in: Capsule())
                    .padding(10)
            }
            .id(studio.wallpaperRevision)
            .frame(height: 96)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(studio.color(.border), lineWidth: 1))
            Button(studio.hasOwnWallpaper(scope) ? AppLocalized("换这张") : AppLocalized("选一张")) {
                pickedWallpaperScope = scope
                pickedWallpaperIsDark = studio.activeVariant == .dark
                wallpaperPickerPresented = true
            }
            .font(.system(size: fsSub, weight: .semibold))
            .foregroundStyle(studio.color(.surface))
            .frame(maxWidth: .infinity)
            .frame(minHeight: 44)
            .background(studio.color(.accent))
            .clipShape(Capsule())
            .buttonStyle(FontPressStyle(scale: 0.97))
        }
    }

    /// [T-39] 贴图落地。和壁纸走同一个解码上限，但落点不同：
    /// 输入栏、思考卡各自一套 setter + 浓度。
    @MainActor
    private func applyPickedDecal(_ item: PhotosPickerItem, target: DecalTarget) async {
        defer { pickedWallpaperItem = nil; pickedDecalTarget = nil }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = ThumbnailCache.downsampledImage(from: data, maxEdge: WallpaperPipeline.maxEdge) else {
            decalMessage = AppLocalized("选中的图读不出来。")
            return
        }
        switch target {
        case .inputBar:
            decalMessage = studio.setInputBarImage(image)
                ? AppLocalized("输入栏贴图已换上。")
                : AppLocalized("选中的图读不出来。")
        case .thinkingCard:
            decalMessage = studio.setThinkingCardImage(image)
                ? AppLocalized("思考卡贴图已换上。")
                : AppLocalized("选中的图读不出来。")
        case .category(let key):
            decalMessage = studio.setCategoryImage(image, for: key)
                ? AppLocalized("分类图已换上。")
                : AppLocalized("选中的图读不出来。")
        case .userAvatar:
            studio.setUserAvatar(image)
            decalMessage = AppLocalized("我的头像已换上。")
        case .assistantAvatar:
            do {
                try studio.setAssistantAvatar(image)
                decalMessage = AppLocalized("AI 头像已换上。")
            } catch {
                decalMessage = AppLocalized("选中的图读不出来。")
            }
        case .characterArt:
            studio.setCharacterArtImage(image)
            decalMessage = AppLocalized("立绘已换上。")
        case .icon(let slot):
            decalMessage = studio.setIcon(image, for: slot)
                ? AppLocalized("这个图标已换上。")
                : AppLocalized("选中的图读不出来。")
        }
    }

    /// [分页壁纸] 拾图落地。写到 pickedWallpaperScope 那一页，不再写死
    /// .global：全局按钮点进来时它是 .global，分页行点进来时是 .chat /
    /// .home。深浅档（pickedWallpaperIsDark 在点按钮时按当前档位记下）
    /// 和 2200 下采样都和原来一样。落地后目标页回到 .global。
    private func applyPickedWallpaper(_ item: PhotosPickerItem) async {
        defer { pickedWallpaperItem = nil; pickedDecalTarget = nil; pickedWallpaperScope = .global }
        let scope = pickedWallpaperScope
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = ThumbnailCache.downsampledImage(from: data, maxEdge: WallpaperPipeline.maxEdge) else {
            if scope == .global {
                wallpaperMessage = AppLocalized("选中的图读不出来。")
            } else {
                pageWallpaperMessage = AppLocalized("选中的图读不出来。")
            }
            return
        }
        if studio.setWallpaper(image, for: scope, dark: pickedWallpaperIsDark) {
            if scope == .global {
                wallpaperMessage = AppLocalized("全局壁纸已换上")
            } else {
                pageWallpaperMessage = String(format: AppLocalized("%@壁纸已换上"), scope.title)
            }
        } else {
            if scope == .global {
                wallpaperMessage = AppLocalized("选中的图读不出来。")
            } else {
                pageWallpaperMessage = AppLocalized("选中的图读不出来。")
            }
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
        // [T-48] 重名以前一声不响就存进去,列表里两套一模一样,分不清哪套是
        // 哪套。现在存之前点出来,但不拦着 —— 名字是她的,她说重就重。
        if let clash = studio.savedThemes().first(where: {
            $0.name.compare(name, options: .caseInsensitive) == .orderedSame
        }) {
            themeSaveMessage = String(format: AppLocalized("已经有一套叫「%@」，再存一套同名的会分不清（%@）。"), clash.name, clash.savedAt.formatted(date: .abbreviated, time: .shortened))
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
                if let pack = studio.libraryPack(id: item.id) {
                    themeCardStrip(pack: pack)
                }
                if inUse {
                    Text(AppLocalized("正在用这套"))
                        .font(.system(size: fsCaption, weight: .semibold))
                        .foregroundStyle(studio.color(.surface))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(studio.color(.accent), in: Capsule())
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(studio.color(.surface))
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(inUse ? studio.color(.accent) : studio.color(.border),
                        lineWidth: inUse ? 1.5 : 1))
            .shadow(color: .black.opacity(inUse ? 0.12 : 0.03),
                    radius: inUse ? 16 : 3, x: 0, y: inUse ? 4 : 1)
            .shadow(color: .black.opacity(inUse ? 0 : 0.02),
                    radius: 2, x: 0, y: 1)
        }
        .buttonStyle(FontPressStyle(scale: 0.98))
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    /// Theme-card colour strip + wallpaper thumbnail (Minis card
    /// standard: a set is recognisable by its colours, not its name
    /// alone). Colours come from the pack's own maps in the live
    /// scheme, with the same fallback the detail preview uses; a
    /// pack with no wallpaper simply shows no thumbnail.
    private func themeCardStrip(pack: AppearanceThemePack) -> some View {
        HStack(spacing: 6) {
            HStack(spacing: 4) {
                ForEach([AppearanceColorRole.canvas, .surface, .accent, .userBubble, .assistantBubble], id: \.self) { role in
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(themePreviewColor(pack, role))
                        .frame(width: 20, height: 20)
                        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .stroke(studio.color(.border).opacity(0.5), lineWidth: 0.5))
                }
            }
            Spacer(minLength: 0)
            if let image = themePreviewImage(pack.wallpaperJPEGBase64) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 44, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(studio.color(.border).opacity(0.5), lineWidth: 0.5))
            }
        }
        .padding(.top, 6)
    }

    private func openThemeDetail(_ item: AppearanceSavedTheme) {
        themeCloseToken += 1
        themeSheetUp = false
        themeApplyMessage = nil
        themeInspectedRow = nil
        detailTheme = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) {
            if detailTheme?.id == item.id { themeSheetUp = true }
        }
    }

    private func closeThemeDetail() {
        themeSheetUp = false
        themeApplyMessage = nil
        themeCloseToken += 1
        let token = themeCloseToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if token == themeCloseToken { detailTheme = nil }
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
            VStack(alignment: .leading, spacing: 6) {
                Text(AppLocalized("这套的颜色"))
                    .font(.system(size: fsCaption, weight: .semibold))
                    .foregroundStyle(themePreviewColor(pack, .secondaryText))
                HStack(spacing: 6) {
                    ForEach([AppearanceColorRole.canvas, .surface, .raised, .accent, .userBubble, .assistantBubble, .primaryText], id: \.self) { role in
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(themePreviewColor(pack, role))
                            .frame(width: 28, height: 28)
                            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(themePreviewColor(pack, .border).opacity(0.5), lineWidth: 0.5))
                    }
                    Spacer(minLength: 0)
                }
            }
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
            showFontToast(AppLocalized("已换上这套"))
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
            // [T-49] 删完只有一条一闪而过的提示条,撤销 API 却只死在旧页里。
            // 现在删掉的那套先留一份,店里直接给"撤销"。
            lastDeletedTheme = item
            showFontToast(String(format: AppLocalized("已删除「%@」，可撤销"), item.name))
            closeThemeDetail()
        } else {
            themeApplyMessage = AppLocalized("这套没删掉，再试一次。")
        }
    }

    /// Rename the open saved theme. An empty name keeps the old name
    /// and leaves the dialog open so the user can retry in place.
    private func confirmRenameTheme() {
        guard let item = themeRenameItem else { return }
        let name = themeRenameName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            showFontToast(AppLocalized("名字不能为空，没改名"))
            return
        }
        themeRenameItem = nil
        if studio.renameSavedTheme(id: item.id, name: name) {
            // Refresh the open detail sheet's copy so its title shows the new name.
            if let renamed = studio.savedThemes().first(where: { $0.id == item.id }) {
                detailTheme = renamed
            }
            showFontToast(String(format: AppLocalized("已改名「%@」"), name))
        } else {
            themeApplyMessage = AppLocalized("改名没成功，再试一次。")
        }
    }

    /// Remove library pack files with no list entry. They can never be
    /// opened, applied or deleted from the UI, so deleting them loses
    /// nothing the user could touch.
    private func cleanupOrphanedThemePacks() {
        let removed = studio.removeOrphanedLibraryPacks()
        if removed > 0 {
            showFontToast(String(format: AppLocalized("清理了 %d 个无主主题包"), removed))
        } else {
            showFontToast(AppLocalized("没有无主主题包"))
        }
    }

    /// [T-49] 撤销上一次删除。失败如实说,不假装成功。
    private func undoDeleteTheme() {
        guard let item = lastDeletedTheme else { return }
        if studio.restoreSavedTheme(item) {
            lastDeletedTheme = nil
            showFontToast(String(format: AppLocalized("已恢复「%@」"), item.name))
        } else {
            showFontToast(AppLocalized("没恢复成功，可能已经超过回收期限"))
        }
    }

    private func themeDetailView(_ item: AppearanceSavedTheme) -> some View {
        VStack(spacing: 0) {
            ZStack {
                Text(AppLocalized("主题"))
                    .font(.system(size: fsTitle, weight: .bold, design: .serif))
                    .foregroundStyle(studio.color(.primaryText))
                HStack(spacing: 0) {
                    Button { closeThemeDetail() } label: {
                        Image(systemName: "chevron.left")
                            .font(.headline)
                            .foregroundStyle(studio.color(.primaryText))
                            .padding(.leading, 16)
                            .frame(minWidth: 60, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(FontPressStyle(scale: 0.92))
                    Spacer(minLength: 0)
                }
                .padding(.trailing, 16)
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
                if !themeSheetUp {
                    Button {
                        themeSheetUp = true
                    } label: {
                        HStack(spacing: 6) {
                            Text(AppLocalized("查看这套详情"))
                                .font(.system(size: fsSub, weight: .semibold))
                            Image(systemName: "chevron.up")
                                .font(.system(size: fsCaption, weight: .semibold))
                        }
                        .foregroundStyle(studio.color(.secondaryText))
                        .padding(.horizontal, 14)
                        .frame(minHeight: 44)
                        .background(studio.color(.mutedSurface), in: Capsule())
                    }
                    .buttonStyle(FontPressStyle(scale: 0.97))
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .padding(16)

            if themeSheetUp {
                VStack(alignment: .leading, spacing: 10) {
                    ZStack {
                        Capsule()
                            .fill(studio.color(.secondaryText).opacity(0.35))
                            .frame(width: 36, height: 5)
                        HStack {
                            Spacer(minLength: 0)
                            Button {
                                themeSheetUp = false
                            } label: {
                                HStack(spacing: 4) {
                                    Text(AppLocalized("收起"))
                                        .font(.system(size: fsSub, weight: .semibold))
                                    Image(systemName: "chevron.down")
                                        .font(.system(size: fsCaption, weight: .semibold))
                                }
                                .foregroundStyle(studio.color(.secondaryText))
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(FontPressStyle(scale: 0.92))
                        }
                    }
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
                    themeSheetDivider()
                    themeSheetInspectRow(icon: "bubble.left",
                                         title: sidePickerLabel(for: .assistant) + AppLocalized("气泡"),
                                         value: themeBubbleLine(item, isUser: false),
                                         key: "assistantBubble") {
                        if let pack = studio.libraryPack(id: item.id) {
                            themePreviewRow(pack: pack, item: item, isUser: false)
                        }
                    }
                    themeSheetDivider()
                    themeSheetInspectRow(icon: "bubble.left",
                                         title: sidePickerLabel(for: .user) + AppLocalized("气泡"),
                                         value: themeBubbleLine(item, isUser: true),
                                         key: "userBubble") {
                        if let pack = studio.libraryPack(id: item.id) {
                            themePreviewRow(pack: pack, item: item, isUser: true)
                        }
                    }
                    themeSheetDivider()
                    themeSheetInspectRow(icon: "circle.dashed",
                                         title: sidePickerLabel(for: .assistant) + AppLocalized("挂件"),
                                         value: themePendantLine(item, isUser: false),
                                         key: "assistantPendant") {
                        if let number = item.assistantPendantNumber,
                           let ring = pendantStore.pendants.first(where: { $0.number == number }) {
                            HStack(spacing: 8) {
                                themePreviewAvatar(isUser: false, ring: ring, shape: nil)
                                Text(ring.title)
                                    .font(.system(size: fsSub))
                                    .foregroundStyle(studio.color(.primaryText))
                                Spacer(minLength: 0)
                            }
                        } else {
                            Text(AppLocalized("没有记挂件，换上时不动"))
                                .font(.system(size: fsSub))
                                .foregroundStyle(studio.color(.secondaryText))
                        }
                    }
                    themeSheetDivider()
                    themeSheetInspectRow(icon: "circle.dashed",
                                         title: sidePickerLabel(for: .user) + AppLocalized("挂件"),
                                         value: themePendantLine(item, isUser: true),
                                         key: "userPendant") {
                        if let number = item.userPendantNumber,
                           let ring = pendantStore.pendants.first(where: { $0.number == number }) {
                            HStack(spacing: 8) {
                                themePreviewAvatar(isUser: true, ring: ring, shape: nil)
                                Text(ring.title)
                                    .font(.system(size: fsSub))
                                    .foregroundStyle(studio.color(.primaryText))
                                Spacer(minLength: 0)
                            }
                        } else {
                            Text(AppLocalized("没有记挂件，换上时不动"))
                                .font(.system(size: fsSub))
                                .foregroundStyle(studio.color(.secondaryText))
                        }
                    }
                    if let pack = studio.libraryPack(id: item.id) {
                        themeSheetDivider()
                        themeSheetInfoRow(icon: "person.crop.circle",
                                          title: AppLocalized("头像形状"),
                                          value: AppearanceAvatarShape.parse(pack.avatarShape).title
                                            + AppLocalized("（随包换上）"))
                        themeSheetDivider()
                        themeSheetInfoRow(icon: "character",
                                          title: AppLocalized("字体"),
                                          value: AppLocalized("跟主题包走"))
                    }
                    if let message = themeApplyMessage {
                        Text(message)
                            .font(.system(size: fsSub))
                            .foregroundStyle(studio.color(.secondaryText))
                    }
                    HStack(spacing: 12) {
                        Button(AppLocalized("改名")) {
                            themeRenameItem = item
                            themeRenameName = item.name
                        }
                        .font(.system(size: globalPointSize * 16 / 13))
                        .foregroundStyle(studio.color(.primaryText))
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .overlay(
                            Capsule()
                                .stroke(studio.color(.primaryText), lineWidth: 1)
                        )
                        .buttonStyle(FontPressStyle(scale: 0.97))
                        Button(AppLocalized("删除这套")) {
                            themeConfirmDelete = true
                        }
                        .font(.system(size: globalPointSize * 16 / 13))
                        .foregroundStyle(studio.color(.destructive))
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .overlay(
                            Capsule()
                                .stroke(studio.color(.destructive), lineWidth: 1)
                        )
                        .buttonStyle(FontPressStyle(scale: 0.97))
                        Button(AppLocalized("换上整套")) {
                            applyThemeSet(item)
                        }
                        .font(.system(size: globalPointSize * 16 / 13))
                        .foregroundStyle(studio.color(.surface))
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(studio.color(.accent))
                        .clipShape(Capsule())
                        .buttonStyle(FontPressStyle(scale: 0.97))
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
        .background(AppearanceBackdrop(scope: .global))
        .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: themeSheetUp)
        .alert(AppLocalized("删除这套？"), isPresented: $themeConfirmDelete) {
            Button(AppLocalized("删除"), role: .destructive) {
                deleteThemeSet(item)
            }
            Button(AppLocalized("取消"), role: .cancel) {}
        } message: {
            Text(AppLocalized("删掉后这套就从列表里消失。"))
        }
        .alert(AppLocalized("给这套改个名"), isPresented: Binding(
            get: { themeRenameItem != nil },
            set: { if !$0 { themeRenameItem = nil } }
        )) {
            TextField(AppLocalized("新名字"), text: $themeRenameName)
            Button(AppLocalized("取消"), role: .cancel) {}
            Button(AppLocalized("保存")) {
                confirmRenameTheme()
            }
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

    /// Theme-sheet divider: one hairline between inspect rows.
    private func themeSheetDivider() -> some View {
        Rectangle()
            .fill(studio.color(.border).opacity(0.35))
            .frame(height: 0.5)
    }

    /// One theme-sheet inspect row: icon + title + value, tappable.
    /// Tapping expands the real thing inline (the recorded bubble
    /// drawn through the same preview row as above, or the recorded
    /// ring on its avatar) instead of leaving the row as dead text.
    private func themeSheetInspectRow<Expanded: View>(icon: String, title: String, value: String, key: String,
                                                     @ViewBuilder expanded: () -> Expanded) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                themeInspectedRow = (themeInspectedRow == key) ? nil : key
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .font(.system(size: fsCaption))
                        .foregroundStyle(studio.color(.secondaryText))
                        .frame(width: 20)
                    Text(title)
                        .font(.system(size: fsCaption, weight: .medium))
                        .foregroundStyle(studio.color(.primaryText))
                    Spacer(minLength: 0)
                    Text(value)
                        .font(.system(size: fsCaption))
                        .foregroundStyle(studio.color(.secondaryText))
                        .lineLimit(1)
                    Image(systemName: themeInspectedRow == key ? "chevron.up" : "chevron.down")
                        .font(.system(size: fsCaption, weight: .semibold))
                        .foregroundStyle(studio.color(.secondaryText))
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(FontPressStyle(scale: 0.98))
            if themeInspectedRow == key {
                expanded()
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    /// One theme-sheet info row: same icon + divider language as the
    /// inspect rows, but not tappable — the value is a pack fact
    /// (avatar shape, font rule), not an object to inspect.
    private func themeSheetInfoRow(icon: String, title: String, value: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: fsCaption))
                .foregroundStyle(studio.color(.secondaryText))
                .frame(width: 20)
            Text(title)
                .font(.system(size: fsCaption, weight: .medium))
                .foregroundStyle(studio.color(.primaryText))
            Spacer(minLength: 0)
            Text(value)
                .font(.system(size: fsCaption))
                .foregroundStyle(studio.color(.secondaryText))
                .lineLimit(1)
        }
        .frame(minHeight: 44)
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
            bubbleStyleCard
            novelModeCard
        }
    }

    // MARK: - 气泡样式卡（从死页搬过来）

    /// Bindings copied verbatim from `AppearanceStudioView`'s
    /// bubbles page: same getters, same studio setters, so these
    /// controls write the same live state the dead page's did.
    private var userStyleBinding: Binding<AppearanceBubbleStyle> {
        Binding(get: { studio.currentThemePack().userStyle },
                set: { studio.setBubbleStyle($0, user: true) })
    }
    private var assistantStyleBinding: Binding<AppearanceBubbleStyle> {
        Binding(get: { studio.currentThemePack().assistantStyle },
                set: { studio.setBubbleStyle($0, user: false) })
    }
    private var inputBarStyleBinding: Binding<AppearanceBubbleStyle> {
        Binding(get: { AppearanceBubbleStyle.parse(studio.currentThemePack().inputBarStyle) },
                set: { studio.setInputBarStyle($0) })
    }
    private var listIconShapeBinding: Binding<AppearanceListIconShape> {
        Binding(get: { AppearanceListIconShape.parse(studio.currentThemePack().listIconShape) },
                set: { studio.setListIconShape($0) })
    }
    private var inputBarRadiusBinding: Binding<Double> {
        Binding(get: { studio.currentThemePack().inputBarRadius },
                set: { studio.setInputBarRadius($0) })
    }
    private var avatarShapeBinding: Binding<AppearanceAvatarShape> {
        Binding(get: { AppearanceAvatarShape.parse(studio.currentThemePack().avatarShape) },
                set: { studio.setAvatarShape($0) })
    }
    private var chatDisplayBinding: Binding<AppearanceChatDisplay> {
        Binding(get: { AppearanceChatDisplay.parse(studio.currentThemePack().chatDisplay) },
                set: { studio.setChatDisplay($0) })
    }
    private var lineHeightBinding: Binding<Double> {
        Binding(get: { studio.currentThemePack().lineHeight },
                set: { studio.setLineHeight($0) })
    }
    private var letterSpacingBinding: Binding<Double> {
        Binding(get: { studio.currentThemePack().letterSpacing },
                set: { studio.setLetterSpacing($0) })
    }

    /// Slider row in the shop's wallpaper-section style: label,
    /// slider, plain value on the right.
    private func styleSliderRow(_ title: String, value: Binding<Double>,
                                range: ClosedRange<Double>, display: String) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: fsSub))
                .foregroundStyle(studio.color(.primaryText))
            Slider(value: value, in: range)
                .frame(minHeight: 44)
                .accessibilityLabel(title)
            Text(display)
                .font(.system(size: fsCaption, weight: .medium))
                .foregroundStyle(studio.color(.secondaryText))
                .frame(minWidth: 34, alignment: .trailing)
        }
    }

    /// [T-46 续] 死页 `AppearanceStudioView` 的气泡页里才有的
    /// 控件，搬到店里气泡页：透明度、分边气泡形状、输入栏形状 /
    /// 圆角、列表图标、头像形状、消息形态、行高、字距。绑定和
    /// 范围与死页一字不差，写同一份 live 状态。气泡颜色不在
    /// 这里，颜色变量页已经有了；正文字体在字体页；代码块折叠
    /// 这次没搬。视觉小说模式在下面单独一张卡。
    private var bubbleStyleCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(AppLocalized("气泡样式"), jumpTo: .bubble)
            VStack(alignment: .leading, spacing: 12) {
                Text(AppLocalized("形状"))
                    .font(.system(size: fsSub, weight: .semibold))
                    .foregroundStyle(studio.color(.primaryText))
                styleSliderRow(AppLocalized("气泡透明度"), value: $studio.bubbleOpacity, range: 0.15...1,
                               display: "\(Int(studio.bubbleOpacity * 100))%")
                Picker(AppLocalized("我的气泡"), selection: userStyleBinding) {
                    ForEach(AppearanceBubbleStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                .tint(studio.color(.accent))
                .font(.system(size: fsSub))
                Picker(String(format: AppLocalized("%@气泡"), aiName), selection: assistantStyleBinding) {
                    ForEach(AppearanceBubbleStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                .tint(studio.color(.accent))
                .font(.system(size: fsSub))
                Picker(AppLocalized("输入栏形状"), selection: inputBarStyleBinding) {
                    ForEach(AppearanceBubbleStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                .tint(studio.color(.accent))
                .font(.system(size: fsSub))
                Picker(AppLocalized("列表图标"), selection: listIconShapeBinding) {
                    ForEach(AppearanceListIconShape.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                .tint(studio.color(.accent))
                .font(.system(size: fsSub))
                styleSliderRow(AppLocalized("输入栏圆角"), value: inputBarRadiusBinding, range: 4...32,
                               display: "\(Int(inputBarRadiusBinding.wrappedValue))")
                Picker(AppLocalized("头像形状"), selection: avatarShapeBinding) {
                    ForEach(AppearanceAvatarShape.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                .tint(studio.color(.accent))
                .font(.system(size: fsSub))
                Text(AppLocalized("头像形状同时作用于聊天、列表和通讯录。"))
                    .font(.system(size: fsCaption))
                    .foregroundStyle(studio.color(.secondaryText))
                Divider().padding(.vertical, fontSettings.density(4))
                Text(AppLocalized("消息形态"))
                    .font(.system(size: fsSub, weight: .semibold))
                    .foregroundStyle(studio.color(.primaryText))
                Picker("", selection: chatDisplayBinding) {
                    ForEach(AppearanceChatDisplay.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel(AppLocalized("消息形态"))
                Text(chatDisplayBinding.wrappedValue.hint)
                    .font(.system(size: fsCaption))
                    .lineSpacing(1.5)
                    .foregroundStyle(studio.color(.secondaryText))
                styleSliderRow(AppLocalized("行高"), value: lineHeightBinding, range: 0.9...2.2,
                               display: String(format: "%.1fx", lineHeightBinding.wrappedValue))
                styleSliderRow(AppLocalized("字距"), value: letterSpacingBinding, range: -1...3,
                               display: "\(Int(letterSpacingBinding.wrappedValue)) pt")
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
    }

    // MARK: - 视觉小说卡（从死页搬过来）

    /// Binding copied verbatim from `AppearanceStudioView`'s
    /// novelModeCard: same getter, same studio setter, so this
    /// control writes the same live state the dead page's did.
    private var novelModeBinding: Binding<AppearanceNovelMode> {
        Binding(get: { AppearanceNovelMode.parse(studio.currentThemePack().novelMode) },
                set: { studio.setNovelMode($0) })
    }

    /// [10-19 醒醒] 视觉小说模式卡，从死页 `AppearanceStudioView`
    /// 的气泡页搬过来，放在气泡样式卡下面。立绘是照 ST 的
    /// `waifuMode` 做的：全屏角色图 + 聊天窗压底部。对话框是
    /// Galgame 那种：底部半透明框，一次一句，点一下往下推。
    /// 选立绘走店里已有的贴图 PhotosPicker（`pickedDecalTarget`
    /// = .characterArt），不另起一套。
    private var novelModeCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(AppLocalized("视觉小说"), jumpTo: .bubble)
            VStack(alignment: .leading, spacing: 12) {
                Picker("", selection: novelModeBinding) {
                    ForEach(AppearanceNovelMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel(AppLocalized("视觉小说"))
                Text(AppearanceNovelMode.parse(studio.currentThemePack().novelMode).hint)
                    .font(.system(size: fsCaption))
                    .lineSpacing(1.5)
                    .foregroundStyle(studio.color(.secondaryText))
                // 只有立绘和对话框模式才用得上角色图
                if novelModeBinding.wrappedValue != .off {
                    Divider().padding(.vertical, fontSettings.density(4))
                    HStack(spacing: 12) {
                        if let img = studio.characterArtImage() {
                            Image(uiImage: img)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 52, height: 72)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        } else {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(studio.color(.mutedSurface))
                                .frame(width: 52, height: 72)
                                .overlay {
                                    Image(systemName: "person.crop.rectangle")
                                        .font(.system(size: 20))
                                        .foregroundStyle(studio.color(.secondaryText).opacity(0.6))
                                }
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(AppLocalized("人设立绘"))
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(studio.color(.primaryText))
                            Text(AppLocalized("竖图最好，底部对齐铺满。不传就用头像放大。"))
                                .font(.system(size: fsCaption))
                                .foregroundStyle(studio.color(.secondaryText))
                        }
                        Spacer()
                        Button {
                            pickedDecalTarget = .characterArt
                            wallpaperPickerPresented = true
                        } label: {
                            Text(studio.hasCharacterArt ? AppLocalized("Change") : AppLocalized("Select"))
                                .font(.system(size: 13, weight: .medium))
                        }
                        .buttonStyle(.borderless)
                    }
                    if studio.hasCharacterArt {
                        Button(role: .destructive) {
                            studio.removeCharacterArt()
                        } label: {
                            Text(AppLocalized("移除立绘"))
                                .font(.system(size: 12))
                        }
                        .buttonStyle(.borderless)
                    }
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
        .buttonStyle(FontPressStyle(scale: 0.98))
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
        .buttonStyle(FontPressStyle(scale: 0.98))
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
        pendantCloseToken += 1
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
        pendantCloseToken += 1
        let token = pendantCloseToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if token == pendantCloseToken { detailPendant = nil }
        }
    }

    private func pendantDetailView(_ pendant: AvatarPendant) -> some View {
        VStack(spacing: 0) {
            ZStack {
                Text(AppLocalized("头像挂件"))
                    .font(.system(size: fsTitle, weight: .bold, design: .serif))
                    .foregroundStyle(studio.color(.primaryText))
                HStack(spacing: 0) {
                    Button { closePendantDetail() } label: {
                        Image(systemName: "chevron.left")
                            .font(.headline)
                            .foregroundStyle(studio.color(.primaryText))
                            .padding(.leading, 16)
                            .frame(minWidth: 60, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(FontPressStyle(scale: 0.92))
                    Spacer(minLength: 0)
                }
                .padding(.trailing, 16)
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
                            outfitStore.save(pendant: pendant, side: detailPendantSide)
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
                        .buttonStyle(FontPressStyle(scale: 0.97))
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
                        .buttonStyle(FontPressStyle(scale: 0.97))
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
        .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: pendantSheetUp)
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
                        Button(AppLocalized("换上")) {
                            let outcome = outfitStore.apply(outfit)
                            if !outcome.missing.isEmpty {
                                showFontToast(outfitMissingMessage(outcome.missing), warning: true)
                            }
                        }
                        .font(.system(size: fsCaption, weight: .semibold))
                        .foregroundStyle(studio.color(.surface))
                        .frame(minWidth: 44, minHeight: 44)
                        .padding(.horizontal, 12)
                        .background(studio.color(.accent))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .buttonStyle(FontPressStyle(scale: 0.92))
                        Button(AppLocalized("按编号删除")) {
                            outfitStore.delete(number: outfit.number)
                        }
                        .font(.system(size: fsCaption))
                        .foregroundStyle(studio.color(.secondaryText))
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                        .buttonStyle(FontPressStyle(scale: 0.92))
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


    /// v2's SYNCHRONIZED dot: accent colour, pulsing 2s infinite.
    /// The colour is passed in (the new palette's accent flips
    /// black/white with the mode) rather than a literal.
    private struct SyncDot: View {
        var color: Color
        /// [T-67] 嵌套类型读不到外层的环境值,自己取一份。
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var pulse = false
        var body: some View {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
                .scaleEffect(pulse ? 1.2 : 0.9)
                .opacity(pulse ? 1 : 0.3)
                .onAppear {
                    // [T-67] 减少动态效果时保持静态,不转圈。
                    guard !reduceMotion else { return }
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
            thinkingFontCard
                .padding(.top, fontSettings.density(FontSkin.sectionGap))
            fontListSection
                .padding(.top, fontSettings.density(FontSkin.sectionGap))
        }
        .padding(.bottom, fontSettings.density(44))
        // v2's spring on every size/font change: the whole section
        // (preview, cards, badges) eases 0.22s on the spring curve
        // instead of jumping. Font rendering itself cannot tween
        // glyphs, but layout, badge fades, and card borders do.
        .animation(reduceMotion ? nil : .timingCurve(0.22, 1, 0.36, 1, duration: 0.22), value: globalPointSize)
        .animation(reduceMotion ? nil : .timingCurve(0.22, 1, 0.36, 1, duration: 0.22), value: currentFontLabel.number)
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
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
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
    /// [T-68] 压色档位的大白话。0 = 不压，往上是浅/中/深。
    /// [T-39] 从死页搬来的三组贴图控件。
    ///
    /// 输入栏贴图 + 浓度、思考卡贴图 + 浓度、分类图。三者的写入接口
    /// （setInputBarImage / setThinkingCardImage / setCategoryImage 及其
    /// 浓度 setter）都在 `AppearanceThemePack` 里，一直是好的，只是入口
    /// 在死页上。这里用这一页已有的 PhotosPicker + 状态，不另起一套。
    @ViewBuilder
    private var deadPageImageSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            decalSectionTitle(AppLocalized("输入栏贴图"))
            HStack(spacing: 12) {
                Button(AppLocalized("选一张")) {
                    pickedDecalTarget = .inputBar
                    wallpaperPickerPresented = true
                }
                    .font(.system(size: fsCaption, weight: .semibold))
                    .foregroundStyle(studio.color(.accent))
                    .frame(minHeight: 44)
                Button(AppLocalized("去掉")) {
                    studio.removeInputBarImage()
                    decalMessage = AppLocalized("输入栏贴图已去掉。")
                }
                .font(.system(size: fsCaption))
                .foregroundStyle(studio.color(.secondaryText))
                .frame(minHeight: 44)
            }
            if studio.currentThemePack().inputBarImageOpacity < 1 {
                Text(AppLocalized("浓度 \(Int((studio.currentThemePack().inputBarImageOpacity * 100).rounded()))%"))
                    .font(.system(size: fsCaption))
                    .foregroundStyle(studio.color(.secondaryText))
            }
            Slider(value: Binding(
                get: { studio.currentThemePack().inputBarImageOpacity },
                set: { studio.setInputBarImageOpacity($0) }
            ), in: 0.05...1)
            .frame(minHeight: 44)
            .accessibilityLabel(AppLocalized("输入栏贴图浓度"))

            decalSectionTitle(AppLocalized("思考卡贴图"))
            HStack(spacing: 12) {
                Button(AppLocalized("选一张")) {
                    pickedDecalTarget = .thinkingCard
                    wallpaperPickerPresented = true
                }
                    .font(.system(size: fsCaption, weight: .semibold))
                    .foregroundStyle(studio.color(.accent))
                    .frame(minHeight: 44)
                Button(AppLocalized("去掉")) {
                    studio.removeThinkingCardImage()
                    decalMessage = AppLocalized("思考卡贴图已去掉。")
                }
                .font(.system(size: fsCaption))
                .foregroundStyle(studio.color(.secondaryText))
                .frame(minHeight: 44)
            }
            Slider(value: Binding(
                get: { studio.currentThemePack().thinkingCardImageOpacity },
                set: { studio.setThinkingCardImageOpacity($0) }
            ), in: 0.05...1)
            .frame(minHeight: 44)
            .accessibilityLabel(AppLocalized("思考卡贴图浓度"))

            // [T-39] 分类图：原来也只有死页能贴。分类键取自
            // `AppearanceThemePack.categoryKeys` 那张表，这里逐个列出可贴的项。
            decalSectionTitle(AppLocalized("分类图"))
            ForEach(AppearanceThemePack.categoryKeys, id: \.self) { key in
                HStack(spacing: 12) {
                    Text(dressingCategoryTitle(key))
                        .font(.system(size: fsSub))
                        .foregroundStyle(studio.color(.primaryText))
                    Spacer(minLength: 8)
                    Button(AppLocalized("选一张")) {
                        pickedDecalTarget = .category(key)
                        wallpaperPickerPresented = true
                    }
                    .font(.system(size: fsCaption, weight: .semibold))
                    .foregroundStyle(studio.color(.accent))
                    .frame(minHeight: 44)
                    Button(AppLocalized("去掉")) {
                        studio.removeCategoryImage(for: key)
                        decalMessage = AppLocalized("这张分类图已去掉。")
                    }
                    .font(.system(size: fsCaption))
                    .foregroundStyle(studio.color(.secondaryText))
                    .frame(minHeight: 44)
                }
            }
            // [T-39] 头像与立绘：死页删掉后无入口，补在这里。
            decalSectionTitle(AppLocalized("头像"))
            HStack(spacing: 12) {
                Button(AppLocalized("换我的头像")) {
                    pickedDecalTarget = .userAvatar
                    wallpaperPickerPresented = true
                }
                .font(.system(size: fsCaption, weight: .semibold))
                .foregroundStyle(studio.color(.accent))
                .frame(minHeight: 44)
                if !studio.userAvatar.isEmpty {
                    Button(AppLocalized("换回默认")) {
                        studio.removeUserAvatar()
                        decalMessage = AppLocalized("我的头像已换回默认。")
                    }
                    .font(.system(size: fsCaption))
                    .foregroundStyle(studio.color(.secondaryText))
                    .frame(minHeight: 44)
                }
                Button(AppLocalized("换 AI 头像")) {
                    pickedDecalTarget = .assistantAvatar
                    wallpaperPickerPresented = true
                }
                .font(.system(size: fsCaption, weight: .semibold))
                .foregroundStyle(studio.color(.accent))
                .frame(minHeight: 44)
                Button(AppLocalized("换立绘")) {
                    pickedDecalTarget = .characterArt
                    wallpaperPickerPresented = true
                }
                .font(.system(size: fsCaption, weight: .semibold))
                .foregroundStyle(studio.color(.accent))
                .frame(minHeight: 44)
            }
            Text(AppLocalized("立绘用在小说模式的对话框里。"))
                .font(.system(size: fsCaption))
                .foregroundStyle(studio.color(.secondaryText))

            // [T-39] 行图标：设置里那些能换图的条目。只列能换的那几种。
            decalSectionTitle(AppLocalized("设置行图标"))
            ForEach(QuietIconSlot.allCases) { slot in
                HStack(spacing: 12) {
                    Text(slot.title)
                        .font(.system(size: fsSub))
                        .foregroundStyle(studio.color(.primaryText))
                    Spacer(minLength: 8)
                    Button(AppLocalized("选一张")) {
                        pickedDecalTarget = .icon(slot.rawValue)
                        wallpaperPickerPresented = true
                    }
                    .font(.system(size: fsCaption, weight: .semibold))
                    .foregroundStyle(studio.color(.accent))
                    .frame(minHeight: 44)
                    if studio.customIcon(for: slot.rawValue) != nil {
                        Button(AppLocalized("换回默认")) {
                            _ = studio.removeIcon(for: slot.rawValue)
                            decalMessage = AppLocalized("这个图标已换回默认。")
                        }
                        .font(.system(size: fsCaption))
                        .foregroundStyle(studio.color(.secondaryText))
                        .frame(minHeight: 44)
                    }
                }
            }

            if let message = decalMessage {
                Text(message)
                    .font(.system(size: fsCaption))
                    .foregroundStyle(studio.color(.secondaryText))
            }
        }
    }

    /// [T-39] 小节标题。
    ///
    /// 用 `OtherSettingsContentView` 里那个同名方法不行——那是另一个类型的
    /// private 方法，从这里调不到，编译直接报 "cannot find sectionTitle"。
    /// 这一份用本类型的 `fsTitle`，和店里别处的小节标题同字号。
    private func decalSectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: fsTitle, weight: .bold))
            .foregroundStyle(studio.color(.primaryText))
            .padding(.top, fontSettings.density(22))
            .padding(.bottom, fontSettings.density(8))
    }

    /// [T-39] 分类键的显示名。键本身是英文标识（code/writing/...），
    /// 直接摆上去她看不懂，这里给中文。
    private func dressingCategoryTitle(_ key: String) -> String {
        switch key {
        case "code": return AppLocalized("写代码")
        case "writing": return AppLocalized("写作")
        case "research": return AppLocalized("查资料")
        case "analysis": return AppLocalized("分析")
        case "creative": return AppLocalized("创作")
        case "chat": return AppLocalized("闲聊")
        case "math": return AppLocalized("数学")
        case "translation": return AppLocalized("翻译")
        case "health": return AppLocalized("健康")
        case "finance": return AppLocalized("财务")
        case "travel": return AppLocalized("出行")
        case "education": return AppLocalized("学习")
        case "design": return AppLocalized("设计")
        case "productivity": return AppLocalized("效率")
        case "support": return AppLocalized("客服")
        default: return AppLocalized("其他")
        }
    }

    /// [T-46] 卡片透明度读成百分比，别吐小数——同一个页面里压色已经这么做了。
    private var cardOpacityLabel: String {
        "\(Int((studio.surfaceOpacity * 100).rounded()))%"
    }

    private var wallpaperShadeLabel: String {
        switch studio.wallpaperShade {
        case ..<0.08: return AppLocalized("不压")
        case ..<0.26: return AppLocalized("浅")
        case ..<0.46: return AppLocalized("中")
        default: return AppLocalized("深")
        }
    }

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
                        Text(AppLocalized("实时同步"))
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
                    Text(AppLocalized("改一下，全 App 立刻跟着变"))
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
                                // [六定-6] 气泡填主文字，里面的字跟着反色。
                                .foregroundStyle(FontSettings.contrastForeground(on: studio.hex(.primaryText, variant: studio.activeVariant)))
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
                    // [六定-6] 发送钮填主文字，图标跟着反色。
                    .foregroundStyle(FontSettings.contrastForeground(on: studio.hex(.primaryText, variant: studio.activeVariant)))
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

    // MARK: - thinking 字号卡（从死页搬过来）

    /// Bindings copied verbatim from `AppearanceStudioView`'s
    /// thinkingFontCard: same getters, same studio setters, so
    /// these sliders write the same live state the dead page's did.
    private var thinkingTitleSizeBinding: Binding<Double> {
        Binding(get: { studio.currentThemePack().thinkingTitleSize },
                set: { studio.setThinkingFont(title: $0) })
    }
    private var thinkingBodySizeBinding: Binding<Double> {
        Binding(get: { studio.currentThemePack().thinkingBodySize },
                set: { studio.setThinkingFont(body: $0) })
    }

    /// [B28 R7 醒醒分类] thinking 字号原来挂在死页「图标」页——
    /// 字号归字号。现在跟着正文/全局字号一起住在字体页，
    /// 在全局字号区下面。滑杆样式用店里现成的 styleSliderRow。
    private var thinkingFontCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(AppLocalized("thinking 字号"), jumpTo: .font)
            VStack(alignment: .leading, spacing: 12) {
                styleSliderRow(AppLocalized("标题字"), value: thinkingTitleSizeBinding, range: 10...22,
                               display: "\(Int(thinkingTitleSizeBinding.wrappedValue))")
                styleSliderRow(AppLocalized("正文字"), value: thinkingBodySizeBinding, range: 10...22,
                               display: "\(Int(thinkingBodySizeBinding.wrappedValue))")
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
            showFontToast(AppLocalized("字号已调到 \(pt) 号"))
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
                        // [六定-6] 徽标填主文字，字跟着反色。
                        .foregroundStyle(FontSettings.contrastForeground(on: studio.hex(.primaryText, variant: studio.activeVariant)))
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
    /// Toast text for outfit-apply pieces that no longer exist
    /// (deleted since the outfit was saved). Names each skipped
    /// piece in plain words; empty when nothing is missing.
    private func outfitMissingMessage(_ missing: [String]) -> String {
        let names = missing.compactMap { key -> String? in
            switch key {
            case "theme": return AppLocalized("主题")
            case "bubble": return AppLocalized("气泡")
            case "pendant": return AppLocalized("挂件")
            default: return nil
            }
        }
        guard !names.isEmpty else { return "" }
        return String(format: AppLocalized("%@找不到了，没换上。"), names.joined(separator: "、"))
    }

    /// Show a v2-style toast for 2.2s, replacing any toast already
    /// up (v2 clears its timer on every new toast, so rapid taps
    /// never stack pills). Pass warning: true and the pill shows
    /// a warning icon instead of the success checkmark.
    private func showFontToast(_ message: String, warning: Bool = false) {
        // [T-67] 提示条的进出也走同一个开关。
        withAnimation(reduceMotion ? nil : .timingCurve(0.22, 1, 0.36, 1, duration: 0.28)) {
            fontToastMessage = message
            fontToastIsWarning = warning
        }
        // [T-63] 主动播报。视觉上是一闪而过的黑条，读屏用户等不到它 ——
        // 操作结果必须能听见，所以这里直接发通告。
        UIAccessibility.post(notification: .announcement, argument: message)
        let shown = message
        // [T-63] 2.2 秒对低视力用户太短：跟着「减弱动态效果」一起放宽到 4 秒，
        // 否则刚看清就没了。
        let dwell: TimeInterval = reduceMotion ? 4.0 : 2.2
        DispatchQueue.main.asyncAfter(deadline: .now() + dwell) {
            if fontToastMessage == shown {
                withAnimation(reduceMotion ? nil : .timingCurve(0.22, 1, 0.36, 1, duration: 0.28)) {
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
        // Mood picked = a random Morandi roll in that mood's range;
        // no mood = the 11 curated sets, exactly as before.
        let rolled: (light: [AppearanceColorRole: String],
                     dark: [AppearanceColorRole: String],
                     name: String)
        if let mood = shakeMood {
            rolled = AppearanceThemeShuffle.shuffle(mood: mood)
        } else {
            rolled = AppearanceThemeShuffle.shufflePureRandom()
        }
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
            Picker(AppLocalized("摇法"), selection: $shakeMood) {
                Text(AppLocalized("11 套精选")).tag(AppearanceThemeShuffle.Mood?.none)
                ForEach(AppearanceThemeShuffle.Mood.allCases) { mood in
                    Text(mood.title).tag(AppearanceThemeShuffle.Mood?.some(mood))
                }
            }
            .pickerStyle(.menu)
            .tint(studio.color(.accent))
            .font(.system(size: fsSub))
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
                    .clipShape(Capsule())
            }
            .buttonStyle(FontPressStyle(scale: 0.97))
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
                        .clipShape(Capsule())
                }
                .buttonStyle(FontPressStyle(scale: 0.97))
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
                            .clipShape(Capsule())
                            .overlay(Capsule()
                                .stroke(studio.color(.border), lineWidth: 1))
                    }
                    .buttonStyle(FontPressStyle(scale: 0.97))
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
                    .buttonStyle(FontPressStyle(scale: 0.97))
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

    /// [T-20] 某一页压着全局的项数。用一个真正的结构体，不用元组——
    /// 元组不支持 keypath，`ForEach(id:)` 拿它没辙。
    private struct PageOverrideEntry: Identifiable {
        let scope: AppearanceScope
        let count: Int
        var id: String { scope.rawValue }
    }

    /// [T-20] 哪些页有自己的覆盖，一共几项。只读，不写。
    private var pageOverrideSummary: [PageOverrideEntry] {
        AppearanceScope.allCases
            .filter { $0 != .global && $0.supportsColour }
            .compactMap { scope in
                let count = AppearanceVariant.allCases.reduce(0) { sum, variant in
                    sum + studio.overrideCount(scope: scope, variant: variant)
                }
                return count > 0 ? PageOverrideEntry(scope: scope, count: count) : nil
            }
    }

    /// [T-20] 页级覆盖提示条。说清"这些页不听全局的"，并给清掉的按钮。
    private var pageOverrideNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(AppLocalized("这些页有自己的颜色，会压着上面的全局值："))
                .font(ChatFont.font(11, weight: .semibold))
                .foregroundStyle(studio.color(.warning))
            ForEach(pageOverrideSummary) { item in
                HStack(spacing: 8) {
                    Text(AppLocalized("\(item.scope.title) · \(item.count) 项"))
                        .font(ChatFont.font(11))
                        .foregroundStyle(studio.color(.secondaryText))
                    Spacer(minLength: 0)
                    Button(AppLocalized("清掉")) {
                        clearPageOverrides(item.scope)
                    }
                    .font(ChatFont.font(11, weight: .semibold))
                    .foregroundStyle(studio.color(.destructive))
                    .frame(minHeight: FontSettings.minHitTarget)
                    .buttonStyle(PressableStyle(scale: 0.94))
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(studio.color(.mutedSurface))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// [T-20] 清掉某一页的全部覆盖（明暗两套都清），清完如实报结果。
    private func clearPageOverrides(_ scope: AppearanceScope) {
        for variant in AppearanceVariant.allCases {
            studio.clearOverrides(scope: scope, variant: variant)
        }
        let left = AppearanceVariant.allCases.reduce(0) {
            $0 + studio.overrideCount(scope: scope, variant: $1)
        }
        showFontToast(left == 0
            ? AppLocalized("\(scope.title) 已回到跟随全局")
            : AppLocalized("\(scope.title) 还剩 \(left) 项没清掉"))
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
                // [T-20] 页级覆盖以前是暗层：这句话对某些页是假的，而唯一能看能清
                // 的入口在已死的旧页里。这里把"哪几页压着全局"直接摆出来，
                // 并给一键清掉的入口 —— 不改任何页的取色逻辑，只把暗层点亮。
                if pageOverrideSummary.isEmpty == false {
                    pageOverrideNotice
                }
                // [T-70] 思考卡那三色只有主题包能定，面板里没有对应行。
                // 不说清楚，用户会以为"我改了强调色，思考卡怎么没变"——
                // 那是包写了值，把跟随盖住了。本轮不加新面板行（规划定的），
                // 只把归属写明。
                Text(AppLocalized("思考卡的颜色只跟主题包走，不在这一页；包没写那三项时才跟强调色。"))
                    .font(ChatFont.font(11))
                    .foregroundStyle(studio.color(.tertiaryText))
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
                    .accessibilityLabel(AppLocalized("白天 / 黑夜"))
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
                    .accessibilityLabel(AppLocalized("正在编辑哪一套变量"))
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
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(group.title)
                                .font(ChatFont.font(15, weight: .bold))
                                .foregroundStyle(studio.color(.primaryText))
                            Text(group.hint)
                                .font(ChatFont.font(11))
                                .foregroundStyle(studio.color(.secondaryText))
                        }
                        Spacer(minLength: 0)
                        Text(editingVariant == .light ? AppLocalized("正在改白天那套") : AppLocalized("正在改黑夜那套"))
                            .font(ChatFont.font(10, weight: .semibold))
                            .foregroundStyle(studio.color(.primaryText))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(studio.color(.mutedSurface), in: Capsule())
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
            .buttonStyle(FontPressStyle(scale: 0.97))
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

    /// [T-44] 面板不再自带一份分组表。
    ///
    /// 原来这里写着第二份 `ColorVarGroup` 列表，和
    /// `AppearanceColorRoleGroup` 各覆盖各的：枚举 18 条、面板 20 条，
    /// 缺的还不是同样的几条。同一份「完整配色表」在两个界面条数不一样，
    /// 加个新角色必然漏一边。
    ///
    /// 现在标题、说明、成员全取自枚举，这边只负责画。
    private struct ColorVarGroup: Identifiable {
        var title: String
        var hint: String
        var roles: [AppearanceColorRole]
        var id: String { title }
    }

    private var colorVarGroups: [ColorVarGroup] {
        AppearanceColorRoleGroup.allCases.map { group in
            ColorVarGroup(title: group.title, hint: group.hint, roles: group.roles)
        }
    }

    /// Contrast warning for a colour-panel row, live values only.
    ///
    /// [T-23] Uses the same role→background table as the AI gate
    /// (AppearanceStudio.contrastPairs), so every text role is checked
    /// against the surface it actually sits on: body copy on canvas/card,
    /// bubble text on its own bubble, accent on canvas/card. Nil when the
    /// value passes, so passing rows show nothing. This never blocks: her
    /// own choice is respected, it just never lands silently unreadable.
    private func colorContrastWarning(for role: AppearanceColorRole) -> String? {
        let pairs = AppearanceStudio.contrastPairs(for: role)
        guard !pairs.isEmpty else { return nil }
        let fg = studio.hex(role, scope: .global, variant: editingVariant)
        var failing: [String] = []
        var strictest = 0.0
        for (bgRole, threshold) in pairs {
            let bg = studio.hex(bgRole, scope: .global, variant: editingVariant)
            let r = AppearanceContrast.ratio(fg, on: bg)
            strictest = max(strictest, threshold)
            if r < threshold {
                failing.append(String(format: AppLocalized("%@约 %.1f"),
                                      colorVarDisplayName(bgRole), r))
            }
        }
        guard !failing.isEmpty else { return nil }
        return String(format: AppLocalized("%@对比不够：%@（要 %.1f），个别地方可能看不清"),
                      colorVarDisplayName(role), failing.joined(separator: "、"), strictest)
    }

    /// Panel-local plain names for the colour rows (report §2.5).
    /// The role's own title/hint stay untouched — other screens
    /// read them — so the panel maps them here, in words a
    /// non-coder reads at a glance, no jargon.
    private func colorVarDisplayName(_ role: AppearanceColorRole) -> String {
        switch role {
        case .primaryText: return AppLocalized("大标题和正文的字")
        case .secondaryText: return AppLocalized("说明和小字的颜色")
        case .tertiaryText: return AppLocalized("最淡的小字")
        case .disabled: return AppLocalized("点不了的东西的颜色")
        case .shellText: return AppLocalized("黑卡里的字")
        case .canvas: return AppLocalized("整页的背景")
        case .surface: return AppLocalized("一块一块的卡片")
        case .raised: return AppLocalized("弹出来的小框")
        case .mutedSurface: return AppLocalized("淡淡的小底块")
        case .border: return AppLocalized("卡片的边和中间的线")
        case .userBubble: return AppLocalized("我的气泡")
        case .assistantBubble: return AppLocalized("AI 的气泡")
        case .bubbleText: return AppLocalized("我的气泡里的字")
        case .assistantBubbleText: return AppLocalized("AI 气泡里的字")
        case .field: return AppLocalized("打字框")
        case .iconTile: return AppLocalized("小图标的底色")
        case .chip: return AppLocalized("小标签的底色")
        case .accent: return AppLocalized("按钮和开关的颜色")
        case .success: return AppLocalized("成了")
        case .warning: return AppLocalized("小心")
        case .destructive: return AppLocalized("危险、删除")
        }
    }

    private func colorVarDisplayHint(_ role: AppearanceColorRole) -> String {
        switch role {
        case .primaryText: return AppLocalized("所有标题、正文都用这个颜色")
        case .secondaryText: return AppLocalized("说明、时间、副标题这种小字")
        case .tertiaryText: return AppLocalized("占位字、最淡的小字，只做标签，不做正文")
        case .disabled: return AppLocalized("按钮、开关不能点的时候显示的颜色")
        case .shellText: return AppLocalized("聊天里那张黑卡上打出来的字")
        case .canvas: return AppLocalized("每一页最底下的颜色；卡片和卡片之间的空地方也透出这个颜色")
        case .surface: return AppLocalized("设置里一格一格的选项、店里一张一张的卡，都是这个颜色")
        case .raised: return AppLocalized("弹窗、菜单、浮在页面上面的小面板")
        case .mutedSurface: return AppLocalized("图片位置空着时显示的浅色块、次要的小底块")
        case .border: return AppLocalized("每一张卡外面那一圈线，和行与行中间的分隔线")
        case .userBubble: return AppLocalized("我发出去的那只气泡")
        case .assistantBubble: return AppLocalized("AI 发过来的那只气泡")
        case .bubbleText: return AppLocalized("我气泡里面的字；没设的时候跟着大标题的字走")
        case .assistantBubbleText: return AppLocalized("AI 气泡里面的字；没设的时候跟着大标题的字走")
        case .field: return AppLocalized("打字的地方、搜索框的底色")
        case .iconTile: return AppLocalized("消息旁边一格一格的小图标底下的颜色")
        case .chip: return AppLocalized("用量、状态那种椭圆形小标签的底色")
        case .accent: return AppLocalized("所有按钮、开关、选中的那一项")
        case .success: return AppLocalized("成功、通过时用的颜色(就在上面“成了”那行)")
        case .warning: return AppLocalized("需要留意时用的颜色(就在上面“小心”那行)")
        case .destructive: return AppLocalized("删除、危险操作用色(就在上面“危险、删除”那行)")
        }
    }

    /// The colour a panel row (and its miniature) actually paints,
    /// in the set being edited. Bubble-text rows follow the main
    /// text colour while unset — the same rule hex() applies —
    /// so the miniature never shows a colour the app does not use.
    private func colorVarLiveColor(_ role: AppearanceColorRole) -> Color {
        if (role == .bubbleText || role == .assistantBubbleText)
            && !studio.hasOverride(role, scope: .global, variant: editingVariant) {
            return Color(hex: studio.hex(.primaryText, scope: .global, variant: editingVariant))
        }
        return Color(hex: studio.hex(role, scope: .global, variant: editingVariant))
    }

    /// Follow-state tags: bubble-text rows say they follow the main
    /// text while unset; the faintest text says editing it does
    /// not move chat. A set row shows no tag — it paints itself.
    private func colorVarFollowTag(_ role: AppearanceColorRole) -> String? {
        if role == .tertiaryText { return AppLocalized("聊天里不动") }
        if (role == .bubbleText || role == .assistantBubbleText)
            && !studio.hasOverride(role, scope: .global, variant: editingVariant) {
            return AppLocalized("跟着大标题的字走")
        }
        return nil
    }

    private func colorVarBar(width: CGFloat, height: CGFloat, color: Color, opacity: Double = 1) -> some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(color.opacity(opacity))
            .frame(width: width, height: height)
    }

    /// One row's miniature: the actual area the row paints, drawn
    /// in the row's live colour, so the link is visual. Text areas
    /// are bars, not text — the miniature is a picture, not a
    /// second label — and symbol sizes are glyph sizes, not text.
    @ViewBuilder
    private func colorVarMiniature(_ role: AppearanceColorRole) -> some View {
        let live = colorVarLiveColor(role)
        switch role {
        case .primaryText:
            VStack(alignment: .leading, spacing: 4) {
                colorVarBar(width: 56, height: 8, color: live)
                colorVarBar(width: 40, height: 5, color: live, opacity: 0.55)
            }
        case .secondaryText:
            VStack(alignment: .leading, spacing: 4) {
                colorVarBar(width: 52, height: 5, color: live)
                colorVarBar(width: 36, height: 5, color: live, opacity: 0.7)
            }
        case .tertiaryText:
            VStack(alignment: .leading, spacing: 4) {
                colorVarBar(width: 48, height: 5, color: live)
                colorVarBar(width: 32, height: 5, color: live, opacity: 0.7)
            }
        case .disabled:
            // [T-42] 小样直接画一个"按不动的按钮"：灰底 + 灰字。
            ZStack {
                Capsule().fill(live)
                colorVarBar(width: 28, height: 4, color: colorVarLiveColor(.secondaryText), opacity: 0.5)
            }
            .frame(width: 52, height: 20)
        case .shellText:
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.black)
                VStack(spacing: 4) {
                    colorVarBar(width: 26, height: 5, color: live)
                    colorVarBar(width: 18, height: 5, color: live, opacity: 0.7)
                }
            }
            .frame(width: 46, height: 28)
        case .canvas:
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(live)
                VStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(colorVarLiveColor(.surface)).frame(width: 58, height: 9)
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(colorVarLiveColor(.surface)).frame(width: 58, height: 9)
                }
            }
        case .surface:
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(live)
                VStack(alignment: .leading, spacing: 4) {
                    colorVarBar(width: 44, height: 6, color: colorVarLiveColor(.primaryText))
                    colorVarBar(width: 32, height: 5, color: colorVarLiveColor(.secondaryText))
                }
            }
        case .raised:
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(colorVarLiveColor(.surface)).frame(width: 58, height: 26)
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(live).frame(width: 44, height: 22)
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(colorVarLiveColor(.border).opacity(0.5), lineWidth: 0.5))
                    .offset(x: 10, y: -4)
            }
        case .mutedSurface:
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(live)
        case .border:
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(live, lineWidth: 1.5)
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(live).frame(width: 56, height: 1)
            }
        case .userBubble:
            HStack {
                Spacer(minLength: 0)
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(live)
                    colorVarBar(width: 26, height: 5, color: colorVarLiveColor(.bubbleText))
                }
                .frame(width: 46, height: 24)
            }
        case .assistantBubble:
            HStack {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(live)
                    colorVarBar(width: 26, height: 5, color: colorVarLiveColor(.assistantBubbleText))
                }
                .frame(width: 46, height: 24)
                Spacer(minLength: 0)
            }
        case .bubbleText:
            HStack {
                Spacer(minLength: 0)
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(colorVarLiveColor(.userBubble))
                    VStack(spacing: 4) {
                        colorVarBar(width: 26, height: 5, color: live)
                        colorVarBar(width: 18, height: 5, color: live, opacity: 0.7)
                    }
                }
                .frame(width: 46, height: 28)
            }
        case .assistantBubbleText:
            HStack {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(colorVarLiveColor(.assistantBubble))
                    VStack(spacing: 4) {
                        colorVarBar(width: 26, height: 5, color: live)
                        colorVarBar(width: 18, height: 5, color: live, opacity: 0.7)
                    }
                }
                .frame(width: 46, height: 28)
                Spacer(minLength: 0)
            }
        case .field:
            ZStack(alignment: .leading) {
                Capsule().fill(live)
                HStack(spacing: 4) {
                    colorVarBar(width: 2, height: 12, color: colorVarLiveColor(.primaryText))
                    colorVarBar(width: 24, height: 5, color: colorVarLiveColor(.secondaryText))
                }
                .padding(.leading, 10)
            }
            .frame(width: 62, height: 20)
        case .iconTile:
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { _ in
                    ZStack {
                        RoundedRectangle(cornerRadius: 4, style: .continuous).fill(live)
                        Circle().fill(colorVarLiveColor(.primaryText).opacity(0.6))
                            .frame(width: 4, height: 4)
                    }
                    .frame(width: 14, height: 14)
                }
            }
        case .chip:
            HStack(spacing: 4) {
                ForEach(0..<2, id: \.self) { _ in
                    ZStack {
                        Capsule().fill(live)
                        colorVarBar(width: 14, height: 4, color: colorVarLiveColor(.secondaryText))
                    }
                    .frame(width: 28, height: 14)
                }
            }
        case .accent:
            HStack(spacing: 6) {
                ZStack {
                    Capsule().fill(live)
                    colorVarBar(width: 16, height: 5, color: colorVarLiveColor(.surface))
                }
                .frame(width: 30, height: 18)
                ZStack {
                    Capsule().fill(live)
                    Circle().fill(colorVarLiveColor(.surface))
                        .frame(width: 12, height: 12)
                        .offset(x: 5)
                }
                .frame(width: 26, height: 16)
            }
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 22))
                .foregroundStyle(live)
        case .warning:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 22))
                .foregroundStyle(live)
        case .destructive:
            ZStack {
                Capsule().fill(live)
                colorVarBar(width: 20, height: 5, color: colorVarLiveColor(.surface))
            }
            .frame(width: 44, height: 20)
        }
    }

    /// One variable row: the miniature is the live preview (not a
    /// control), then the plain name, hint, follow tag, #hex, a visible
    /// 32x32 ColorPicker, and revert-when-overridden, bound to the
    /// GLOBAL scope and the set being edited.
    private func colorVarRow(_ role: AppearanceColorRole) -> some View {
        VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 12) {
            colorVarMiniature(role)
                .frame(width: 76, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .allowsHitTesting(false)
            VStack(alignment: .leading, spacing: 2) {
                Text(colorVarDisplayName(role))
                    .font(ChatFont.font(13, weight: .medium))
                    .foregroundStyle(studio.color(.primaryText))
                Text(colorVarDisplayHint(role))
                    .font(ChatFont.font(10))
                    .foregroundStyle(studio.color(.secondaryText).opacity(0.72))
                    .lineLimit(2)
                if let tag = colorVarFollowTag(role) {
                    Text(tag)
                        .font(ChatFont.font(10, weight: .semibold))
                        .foregroundStyle(studio.color(.primaryText))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(studio.color(.mutedSurface), in: Capsule())
                }
            }
            Spacer(minLength: 6)
            Text("#\(studio.hex(role, scope: .global, variant: editingVariant))")
                .font(.system(size: globalPointSize * 10 / 13, design: .monospaced))
                .foregroundStyle(studio.color(.secondaryText).opacity(0.55))
                .allowsHitTesting(false)
            // The colour control: a visible system well, same pattern as
            // AppearanceStudioView.paletteRow (32x32, direct HStack child).
            // The old invisible full-row picker in .background never
            // received taps: the name/hint text above it claimed them.
            // Do not move the picker back into .background.
            ColorPicker("", selection: studio.colorBinding(role, scope: .global, variant: editingVariant),
                        supportsOpacity: false)
                .labelsHidden()
                .frame(width: 32, height: 32)
                .accessibilityLabel(colorVarDisplayName(role))
                .accessibilityHint(AppLocalized("点一下打开取色器"))
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
                .buttonStyle(FontPressStyle(scale: 0.92))
                .accessibilityLabel(AppLocalized("恢复默认"))
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
        bubbleCloseToken += 1
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
        bubbleCloseToken += 1
        let token = bubbleCloseToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if token == bubbleCloseToken { detailPack = nil }
        }
    }

    private func bubbleDetailView(_ pack: BubbleStylePack) -> some View {
        VStack(spacing: 0) {
            ZStack {
                Text(AppLocalized("聊天气泡"))
                    .font(.system(size: fsTitle, weight: .bold, design: .serif))
                    .foregroundStyle(studio.color(.primaryText))
                HStack(spacing: 0) {
                    Button { closeDetail() } label: {
                        Image(systemName: "chevron.left")
                            .font(.headline)
                            .foregroundStyle(studio.color(.primaryText))
                            .padding(.leading, 16)
                            .frame(minWidth: 60, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(FontPressStyle(scale: 0.92))
                    Spacer(minLength: 0)
                }
                .padding(.trailing, 16)
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
                            outfitStore.save(bubblePack: pack, side: detailPackSide)
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
                        .buttonStyle(FontPressStyle(scale: 0.97))
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
                        .buttonStyle(FontPressStyle(scale: 0.97))
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
        .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: sheetUp)
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
                    .buttonStyle(FontPressStyle(scale: 0.98))
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
                        .buttonStyle(FontPressStyle(scale: 0.98))
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
