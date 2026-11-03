import Foundation
import SwiftUI
import UIKit

extension Notification.Name {
    /// [10-20 醒醒] 代码块换行/折叠阈值变了，渲染层要重排。
    static let codeBlockLayoutSettingsChanged = Notification.Name("codeBlockLayoutSettingsChanged")
}

/// Shape + thinking chrome that a theme pack can swap.
/// Colors stay in AppearanceStudio; this file owns radii, bubble style,
/// thinking card image, pack identity.
struct AppearanceThemePack: Equatable, Codable, Identifiable {
    var id: String
    var name: String
    var userBubbleRadius: Double
    var assistantBubbleRadius: Double
    var thinkingRadius: Double
    var thinkingFillHex: String
    var thinkingStrokeHex: String
    var thinkingAccentHex: String
    var userBubbleStyle: String
    var assistantBubbleStyle: String
    var thinkingCardJPEGBase64: String?
    var thinkingCardImageOpacity: Double
    var listRowFillHex: String?
    var listIconShape: String
    var categoryIcons: [String: String]
    var categoryColors: [String: String]
    var categoryImages: [String: String]
    var inputBarRadius: Double
    var inputBarStyle: String
    var inputBarJPEGBase64: String?
    var inputBarImageOpacity: Double
    var thinkingTitleSize: Double
    var thinkingBodySize: Double
    var fontFamily: String
    /// Legacy message-part font family override. Fonts are
    /// ONE global choice now: `unifiedFonts` folds a set
    /// override into `fontFamily` (message wins) and clears
    /// this, so a stored "" here means "follow the global
    /// family" exactly as before. Kept as a field so old
    /// packs still decode; nothing new writes a non-empty
    /// value here.
    var messageFontFamily: String
    /// Uploaded-font postScript names. ONE global uploaded
    /// font now: `unifiedFonts` keeps both fields in sync
    /// (message wins when they differ), so either field
    /// reads as the global choice. Nil = no uploaded font;
    /// the family above is the fallback. An uploaded font is
    /// a file the user supplied, so it is stored by name,
    /// never by guessing.
    var messageCustomFont: String?
    var uiCustomFont: String?
    var wallpaperShade: Double?
    var surfaceOpacity: Double?
    var colorsLight: [String: String]
    var colorsDark: [String: String]
    var wallpaperJPEGBase64: String?
    // [page-state] Page-scope colour overrides carried by the pack,
    // keyed by scope raw value, then role raw value. Nil = this pack
    // says nothing about page colours (old packs, partial merges):
    // replace clears them, merge leaves them alone. A non-nil map
    // is an explicit statement: replace results in exactly the
    // scopes it lists. Only actually-set overrides are ever put
    // here — never a resolved inherited value, so "this page
    // follows global" survives a save/apply round trip.
    var pageColorsLight: [String: [String: String]]?
    var pageColorsDark: [String: [String: String]]?
    // [page-state] Page-scope wallpapers, keyed by scope raw value.
    // A base64 JPEG means "this page has this image"; an empty
    // string means "this page was explicitly cleared to no
    // background" (cut global inheritance), which is a different
    // state from merely having no file. Same nil rule as the
    // colours. Transport only, like the global wallpaper field:
    // applyThemePack nils this on the stored pack before
    // persisting, so image bytes never live in UserDefaults.
    var pageWallpapers: [String: String]?
    // [10-18 醒醒 第五轮] 五个新的可调维度，补的是"结构"自由度，
    // 之前只有颜色和圆角。
    /// 头像形状：圆 / 方 / 圆角方 / 竖矩形
    var avatarShape: String
    /// 消息形态：平铺 / 气泡 / 文稿
    var chatDisplay: String
    /// 正文行高倍数。1.0 = 系统默认。
    var lineHeight: Double
    /// 正文字距，单位 pt。可以是负数。
    var letterSpacing: Double
    /// 选项行背景。nil = 跟随 surface。
    var rowBackgroundHex: String?
    /// [10-19 醒醒] 视觉小说模式：关 / 立绘 / 对话框。
    var novelMode: String
    /// 立绘模式用的角色全身图（base64 JPEG）。nil = 退回头像放大。
    var characterArtBase64: String?
    /// 代码块超过多少行自动折叠。默认 12。
    var codeBlockCollapseLines: Int
    // [bubble-packs] 气泡款式包的结构字段（颜色、透明度、壁纸、
    // 字色一律不在这里，仍走主题颜色系统）。默认值 = 款式包之前
    // 的聊天现状：文字气泡、无边框、用户横向内边距 14 / AI 12、
    // 头像 38pt / 0.7pt 边框、行内头像、用户无名字 / AI 名字在上、
    // 无时间行、列表间距 8、均匀圆角。款式包 apply() 全量写这些
    // 字段；主题包 apply / reset 回到这里的默认值。
    /// 气泡面：整行 / 文字。用户、AI 各自。
    var userBubbleSurface: String
    var assistantBubbleSurface: String
    /// 气泡边框宽度（颜色仍走主题 .border）。用户、AI 各自。
    var userBubbleBorderWidth: Double
    var assistantBubbleBorderWidth: Double
    /// 气泡横向内边距。用户、AI 各自。
    var userBubblePadding: Double
    var assistantBubblePadding: Double
    /// 头像尺寸、头像边框宽度、头像位置（行内 / 压在气泡上）。
    /// 头像位置只在用户行生效：AI 头像在独立的 header cell 里，
    /// 压不到气泡上，见样张注释。
    var avatarSize: Double
    var avatarBorderWidth: Double
    var avatarPlacement: String
    /// 时间行位置：不显示 / 在上 / 在下。用户、AI 各自。
    var userMetaPosition: String
    var assistantMetaPosition: String
    /// 名字行位置：不显示 / 在上 / 在行内。用户、AI 各自。
    /// AI 名字在上与在行内在 live 里都显示为 header 名字（header
    /// 是独立 cell，名字进不了气泡行），见样张注释。
    var userNamePlacement: String
    var assistantNamePlacement: String
    /// 消息间距（列表 cell 间距）。
    var messageSpacing: Double
    /// 圆角预设：均匀 / 不对称 / 胶囊 / 方一点。live 形状只在
    /// 圆角/连续圆角且非小尾巴时用它画不对称角。
    var bubbleCornerPreset: String
    /// 气泡款式包的整体形状：瓷白圆润 / 云朵 / 信纸 / 波浪 /
    /// 方章 / 丝带针脚。由款式包 apply() 写，AI 工具层锁死
    /// （见 aiApplyLockedFields），用户只能在装扮店里点款式改。
    var bubblePackShape: String
    // [bubble-foundation] Future complex packs, carried by the
    // live theme so live chat reads the same record the shop
    // applied. All unset on today's six packs (nil / none / [] /
    // nil), so live chat renders exactly as before until a pack
    // actually sets one. Image file = bare file name in
    // BubblePackImageStore.directory; pattern = BubblePattern raw
    // value; decorations = BubbleDecoration JSON string; text hexes
    // = per-role bubble text colour, nil = theme bubble text slot.
    var bubbleBackgroundImageFile: String?
    var bubblePattern: String
    var bubblePatternOpacity: Double
    var bubbleDecorationsJSON: String?
    var userBubblePackTextHex: String?
    var assistantBubblePackTextHex: String?
    // [per-side bubbles] The same shape / foundation fields,
    // split by side. Live chat reads THESE (MinisThemeShape's
    // per-side accessors), so the user side can wear one pack
    // shape while the AI side wears another. The shared fields
    // above stay as the legacy fallback: decode() fills a
    // missing per-side field from its shared twin, so a theme
    // pack saved before this split still renders exactly as it
    // did, and a both-sides pack apply keeps the shared fields
    // in step with the per-side ones. A one-side apply writes
    // only that side's fields here and never touches the shared
    // ones — writing the shared shape for one side would move
    // the other side's bubbles too.
    // Image / decorations nil here means "this side has none"
    // (a pack with no image), NOT "fall back to shared": the
    // fallback only happens at decode time, when the per-side
    // key is absent from the stored JSON altogether. That is
    // why asJSONObject() writes these two as explicit nulls
    // instead of omitting them.
    var userBubblePackShape: String
    var assistantBubblePackShape: String
    var userBubbleBackgroundImageFile: String?
    var assistantBubbleBackgroundImageFile: String?
    var userBubblePattern: String
    var assistantBubblePattern: String
    var userBubblePatternOpacity: Double
    var assistantBubblePatternOpacity: Double
    var userBubbleDecorationsJSON: String?
    var assistantBubbleDecorationsJSON: String?

    static let currentKey = "appearanceStudio.themePack.v1"
    static let schemaVersion = 5
    static let categoryKeys = [
        "code", "writing", "research", "analysis", "creative", "chat", "math",
        "translation", "health", "finance", "travel", "education", "design",
        "productivity", "support", "other",
    ]

    /// 行高倍数的安全取值。越界就夹回 0.9...2.2。
    static func parseLineHeight(_ raw: Double) -> Double {
        min(2.2, max(0.9, raw))
    }

    /// 从 UserDefaults 直接读行高，**不经过 MainActor**。
    ///
    /// `SelectableMarkdownView` 的排版类不是 MainActor，调
    /// `AppearanceStudio.shared.currentThemePack()` 会报
    /// "main actor-isolated instance method in a synchronous nonisolated context"。
    /// 主题包本来就是 JSON 存在 UserDefaults 里的，这里直接解一下就好。
    nonisolated static func storedLineHeight() -> Double {
        guard let data = UserDefaults.standard.data(forKey: currentKey),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = obj["lineHeight"] as? Double else {
            return 1.0
        }
        return parseLineHeight(raw)
    }

    /// 同上，读消息间距（列表 cell 间距）。UIViewController 的
    /// viewDidLoad 不在 MainActor 上，不能读 MinisThemeShape，
    /// 所以这里直接读 UserDefaults，与 storedLineHeight 同 pattern。
    nonisolated static func storedMessageSpacing() -> Double {
        guard let data = UserDefaults.standard.data(forKey: currentKey),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = obj["messageSpacing"] as? Double else {
            return 8
        }
        return min(24, max(4, raw))
    }

    /// 同上，读字距。
    nonisolated static func storedLetterSpacing() -> Double {
        guard let data = UserDefaults.standard.data(forKey: currentKey),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = obj["letterSpacing"] as? Double else {
            return 0
        }
        return parseLetterSpacing(raw)
    }

    /// Nonisolated snapshot of the applied pack's assistant text
    /// hex, for non-MainActor callers (SelectableMarkdownTheme).
    /// Same UserDefaults JSON pattern as storedLineHeight: absent
    /// or invalid means "no pack text colour", i.e. the theme slot.
    nonisolated static func storedAssistantBubblePackTextHex() -> String? {
        guard let data = UserDefaults.standard.data(forKey: currentKey),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = obj["assistantBubblePackTextHex"] as? String else {
            return nil
        }
        return BubbleStyleRecord.normalizedPackHex(raw)
    }

    /// 字距的安全取值，单位 pt。
    static func parseLetterSpacing(_ raw: Double) -> Double {
        min(3, max(-1, raw))
    }


    static let `default` = AppearanceThemePack(
        id: "warm-paper",
        name: "暖纸",
        userBubbleRadius: 18,
        assistantBubbleRadius: 16,
        thinkingRadius: 12,
        // [B28 B-3] 空串 = "没设过，跟 accent 走"。老版本这三个字段是 accent
        // 的副本；写死一个 hex 会把新装用户钉在旧主色上（D4778B 是 10-18
        // 改配色之前的主色）。
        thinkingFillHex: "",
        thinkingStrokeHex: "",
        thinkingAccentHex: "",
        userBubbleStyle: AppearanceBubbleStyle.rounded.rawValue,
        assistantBubbleStyle: AppearanceBubbleStyle.rounded.rawValue,
        thinkingCardJPEGBase64: nil,
        thinkingCardImageOpacity: 0.28,
        listRowFillHex: nil,
        listIconShape: AppearanceListIconShape.circle.rawValue,
        categoryIcons: [:],
        categoryColors: [:],
        categoryImages: [:],
        inputBarRadius: 20,
        inputBarStyle: AppearanceBubbleStyle.rounded.rawValue,
        inputBarJPEGBase64: nil,
        inputBarImageOpacity: 0.28,
        thinkingTitleSize: 13,
        thinkingBodySize: 13,
        fontFamily: AppearanceFontFamily.system.rawValue,
        messageFontFamily: "",
        messageCustomFont: nil,
        uiCustomFont: nil,
        wallpaperShade: 0.08,
        surfaceOpacity: 0.88,
        colorsLight: [:],
        colorsDark: [:],
        wallpaperJPEGBase64: nil,
        pageColorsLight: nil,
        pageColorsDark: nil,
        pageWallpapers: nil,
        avatarShape: AppearanceAvatarShape.circle.rawValue,
        chatDisplay: AppearanceChatDisplay.bubbles.rawValue,
        lineHeight: 1.0,
        letterSpacing: 0,
        rowBackgroundHex: nil,
        novelMode: AppearanceNovelMode.off.rawValue,
        characterArtBase64: nil,
        codeBlockCollapseLines: 12,
        userBubbleSurface: BubbleSurface.text.rawValue,
        assistantBubbleSurface: BubbleSurface.text.rawValue,
        userBubbleBorderWidth: 0,
        assistantBubbleBorderWidth: 0,
        userBubblePadding: 14,
        assistantBubblePadding: 12,
        avatarSize: 38,
        avatarBorderWidth: 0.7,
        avatarPlacement: BubbleAvatarPlacement.inline.rawValue,
        userMetaPosition: BubbleMetaPosition.hidden.rawValue,
        assistantMetaPosition: BubbleMetaPosition.hidden.rawValue,
        userNamePlacement: BubbleNamePlacement.hidden.rawValue,
        assistantNamePlacement: BubbleNamePlacement.above.rawValue,
        messageSpacing: 8,
        bubbleCornerPreset: BubbleCornerPreset.even.rawValue,
        bubblePackShape: BubblePackKind.porcelain.rawValue,
        bubbleBackgroundImageFile: nil,
        bubblePattern: BubblePattern.none.rawValue,
        bubblePatternOpacity: 0.15,
        bubbleDecorationsJSON: nil,
        userBubblePackTextHex: nil,
        assistantBubblePackTextHex: nil,
        userBubblePackShape: BubblePackKind.porcelain.rawValue,
        assistantBubblePackShape: BubblePackKind.porcelain.rawValue,
        userBubbleBackgroundImageFile: nil,
        assistantBubbleBackgroundImageFile: nil,
        userBubblePattern: BubblePattern.none.rawValue,
        assistantBubblePattern: BubblePattern.none.rawValue,
        userBubblePatternOpacity: 0.15,
        assistantBubblePatternOpacity: 0.15,
        userBubbleDecorationsJSON: nil,
        assistantBubbleDecorationsJSON: nil
    )

    var userStyle: AppearanceBubbleStyle { AppearanceBubbleStyle.parse(userBubbleStyle) }
    var assistantStyle: AppearanceBubbleStyle { AppearanceBubbleStyle.parse(assistantBubbleStyle) }

    func radius(_ kind: AppearanceShapeKind) -> CGFloat {
        switch kind {
        case .userBubble: return CGFloat(clampRadius(userBubbleRadius))
        case .assistantBubble: return CGFloat(clampRadius(assistantBubbleRadius))
        case .thinking: return CGFloat(clampRadius(thinkingRadius))
        }
    }

    func thinkingFill(opacity: Double) -> Color {
        Color(hex: thinkingFillHex).opacity(opacity)
    }

    var thinkingStroke: Color { Color(hex: thinkingStrokeHex).opacity(0.15) }
    var thinkingAccent: Color { Color(hex: thinkingAccentHex) }

    func asJSONObject() -> [String: Any] {
        var obj: [String: Any] = [
            "schema": Self.schemaVersion,
            "id": id,
            "name": name,
            "userBubbleRadius": userBubbleRadius,
            "assistantBubbleRadius": assistantBubbleRadius,
            "thinkingRadius": thinkingRadius,
            "thinkingFillHex": thinkingFillHex,
            "thinkingStrokeHex": thinkingStrokeHex,
            "thinkingAccentHex": thinkingAccentHex,
            "userBubbleStyle": userStyle.rawValue,
            "assistantBubbleStyle": assistantStyle.rawValue,
            "thinkingCardImageOpacity": thinkingCardImageOpacity,
            "listIconShape": AppearanceListIconShape.parse(listIconShape).rawValue,
            "categoryIcons": categoryIcons,
            "categoryColors": categoryColors,
            "categoryImages": categoryImages,
            "inputBarRadius": inputBarRadius,
            "inputBarStyle": AppearanceBubbleStyle.parse(inputBarStyle).rawValue,
            "inputBarImageOpacity": inputBarImageOpacity,
            "thinkingTitleSize": thinkingTitleSize,
            "thinkingBodySize": thinkingBodySize,
            "fontFamily": AppearanceFontFamily.parse(fontFamily).rawValue,
            "messageFontFamily": messageFontFamily,
            "messageCustomFont": messageCustomFont,
            "uiCustomFont": uiCustomFont,
            "colorsLight": colorsLight,
            "colorsDark": colorsDark,
            "avatarShape": AppearanceAvatarShape.parse(avatarShape).rawValue,
            "chatDisplay": AppearanceChatDisplay.parse(chatDisplay).rawValue,
            "lineHeight": lineHeight,
            "letterSpacing": letterSpacing,
            "codeBlockCollapseLines": codeBlockCollapseLines,
            "userBubbleSurface": BubbleSurface.parse(userBubbleSurface).rawValue,
            "assistantBubbleSurface": BubbleSurface.parse(assistantBubbleSurface).rawValue,
            "userBubbleBorderWidth": userBubbleBorderWidth,
            "assistantBubbleBorderWidth": assistantBubbleBorderWidth,
            "userBubblePadding": userBubblePadding,
            "assistantBubblePadding": assistantBubblePadding,
            "avatarSize": avatarSize,
            "avatarBorderWidth": avatarBorderWidth,
            "avatarPlacement": BubbleAvatarPlacement.parse(avatarPlacement).rawValue,
            "userMetaPosition": BubbleMetaPosition.parse(userMetaPosition).rawValue,
            "assistantMetaPosition": BubbleMetaPosition.parse(assistantMetaPosition).rawValue,
            "userNamePlacement": BubbleNamePlacement.parse(userNamePlacement).rawValue,
            "assistantNamePlacement": BubbleNamePlacement.parse(assistantNamePlacement).rawValue,
            "messageSpacing": messageSpacing,
            "bubbleCornerPreset": BubbleCornerPreset.parse(bubbleCornerPreset).rawValue,
            "bubblePackShape": BubblePackKind.parse(bubblePackShape).rawValue,
            "bubblePattern": BubblePattern.parse(bubblePattern).rawValue,
            "bubblePatternOpacity": min(0.6, max(0, bubblePatternOpacity)),
        ]
        if let bubbleBackgroundImageFile { obj["bubbleBackgroundImageFile"] = bubbleBackgroundImageFile }
        if let bubbleDecorationsJSON { obj["bubbleDecorationsJSON"] = bubbleDecorationsJSON }
        // Per-side fields are always written. Shape / pattern /
        // opacity are non-optional, so they are always present;
        // image / decorations use an explicit null for "none",
        // so decode() can tell "this side has no image" apart
        // from "this key predates the per-side split" (absent =
        // fall back to the shared field).
        obj["userBubblePackShape"] = BubblePackKind.parse(userBubblePackShape).rawValue
        obj["assistantBubblePackShape"] = BubblePackKind.parse(assistantBubblePackShape).rawValue
        obj["userBubbleBackgroundImageFile"] = userBubbleBackgroundImageFile ?? NSNull()
        obj["assistantBubbleBackgroundImageFile"] = assistantBubbleBackgroundImageFile ?? NSNull()
        obj["userBubblePattern"] = BubblePattern.parse(userBubblePattern).rawValue
        obj["assistantBubblePattern"] = BubblePattern.parse(assistantBubblePattern).rawValue
        obj["userBubblePatternOpacity"] = min(0.6, max(0, userBubblePatternOpacity))
        obj["assistantBubblePatternOpacity"] = min(0.6, max(0, assistantBubblePatternOpacity))
        obj["userBubbleDecorationsJSON"] = userBubbleDecorationsJSON ?? NSNull()
        obj["assistantBubbleDecorationsJSON"] = assistantBubbleDecorationsJSON ?? NSNull()
        if let userBubblePackTextHex { obj["userBubblePackTextHex"] = userBubblePackTextHex }
        if let assistantBubblePackTextHex { obj["assistantBubblePackTextHex"] = assistantBubblePackTextHex }
        if let rowBackgroundHex { obj["rowBackgroundHex"] = rowBackgroundHex }
        obj["novelMode"] = AppearanceNovelMode.parse(novelMode).rawValue
        if let characterArtBase64 { obj["characterArtBase64"] = characterArtBase64 }
        if let listRowFillHex { obj["listRowFillHex"] = listRowFillHex }
        if let wallpaperShade { obj["wallpaperShade"] = wallpaperShade }
        if let surfaceOpacity { obj["surfaceOpacity"] = surfaceOpacity }
        if let wallpaperJPEGBase64 { obj["wallpaperJPEGBase64"] = wallpaperJPEGBase64 }
        // [page-state] Written only when non-nil, so an old pack
        // (keys absent) stays distinguishable from a new pack
        // that explicitly carries empty page state. Wallpaper
        // entries include "" for explicitly-cleared pages.
        if let pageColorsLight { obj["pageColorsLight"] = pageColorsLight }
        if let pageColorsDark { obj["pageColorsDark"] = pageColorsDark }
        if let pageWallpapers { obj["pageWallpapers"] = pageWallpapers }
        if let thinkingCardJPEGBase64 { obj["thinkingCardJPEGBase64"] = thinkingCardJPEGBase64 }
        if let inputBarJPEGBase64 { obj["inputBarJPEGBase64"] = inputBarJPEGBase64 }
        return obj
    }

    /// Keys that mark JSON as an Appearance theme pack (partial / legacy OK).
    private static let themePackSignalKeys: Set<String> = [
        "schema",
        "userBubbleRadius", "assistantBubbleRadius", "thinkingRadius",
        "thinkingFillHex", "thinkingStrokeHex", "thinkingAccentHex",
        "userBubbleStyle", "assistantBubbleStyle",
        "thinkingCardJPEGBase64", "thinkingCardImageOpacity",
        "listRowFillHex", "listIconShape",
        "categoryIcons", "categoryColors", "categoryImages",
        "inputBarRadius", "inputBarStyle", "inputBarJPEGBase64", "inputBarImageOpacity",
        "thinkingTitleSize", "thinkingBodySize", "fontFamily",
        "messageFontFamily", "messageCustomFont", "uiCustomFont",
        "wallpaperShade", "surfaceOpacity",
        "colorsLight", "colorsDark", "wallpaperJPEGBase64",
        "pageColorsLight", "pageColorsDark", "pageWallpapers",
        "avatarShape", "chatDisplay", "lineHeight", "letterSpacing", "rowBackgroundHex",
        "novelMode", "characterArtBase64",
        "userBubbleSurface", "assistantBubbleSurface",
        "userBubbleBorderWidth", "assistantBubbleBorderWidth",
        "userBubblePadding", "assistantBubblePadding",
        "avatarSize", "avatarBorderWidth", "avatarPlacement",
        "userMetaPosition", "assistantMetaPosition",
        "userNamePlacement", "assistantNamePlacement",
        "messageSpacing", "bubbleCornerPreset", "bubblePackShape",
        "bubbleBackgroundImageFile", "bubblePattern", "bubblePatternOpacity",
        "bubbleDecorationsJSON", "userBubblePackTextHex", "assistantBubblePackTextHex",
        "userBubblePackShape", "assistantBubblePackShape",
        "userBubbleBackgroundImageFile", "assistantBubbleBackgroundImageFile",
        "userBubblePattern", "assistantBubblePattern",
        "userBubblePatternOpacity", "assistantBubblePatternOpacity",
        "userBubbleDecorationsJSON", "assistantBubbleDecorationsJSON",
    ]

    /// True when `raw` carries at least one known theme-pack field.
    /// Missing fields are filled from `.default` during decode (migrate / upgrade path).
    static func looksLikeThemePack(_ raw: [String: Any]) -> Bool {
        raw.keys.contains { themePackSignalKeys.contains($0) }
    }

    /// Fold a per-part font pack into ONE global font, the
    /// batch's migration rule: when the message part and the
    /// UI part differ, the message choice wins and becomes the
    /// global choice; the per-part fields are then normalised
    /// to agree with it, so every reader — including ones that
    /// still read the stored `fontFamily` field directly —
    /// sees the same font. A pack that already agrees comes
    /// back unchanged. Numbers are untouched: this only moves
    /// family / uploaded-font fields, never FON numbering.
    static func unifiedFonts(_ pack: AppearanceThemePack) -> AppearanceThemePack {
        var p = pack
        // Family: a message override, when set, is the global family.
        if !p.messageFontFamily.isEmpty, p.messageFontFamily != p.fontFamily {
            p.fontFamily = p.messageFontFamily
        }
        p.messageFontFamily = ""
        // Uploaded font: message wins when set; when only the
        // UI side had one, it becomes the single global font
        // rather than being dropped.
        let messageCustom = (p.messageCustomFont ?? "").isEmpty ? nil : p.messageCustomFont
        let uiCustom = (p.uiCustomFont ?? "").isEmpty ? nil : p.uiCustomFont
        if let messageCustom {
            p.messageCustomFont = messageCustom
            p.uiCustomFont = messageCustom
        } else if let uiCustom {
            p.messageCustomFont = uiCustom
            p.uiCustomFont = uiCustom
        }
        return p
    }

    /// AI apply allowlist (tool-layer lock, 2026-11-01 standing rule).
    /// The in-app AI may change ONLY colours, wallpaper/surface images,
    /// font sizes, and avatar shape. Everything else is layout and is
    /// locked: the user changes it in the UI, the AI cannot.
    /// Presence is the test, not the value: a locked key in the JSON is
    /// rejected even if its value equals the live one, because merge
    /// decode cannot tell "reaffirming" from "changing", and a full
    /// exported pack re-fed to apply must not silently smuggle layout
    /// changes back in. The caller must strip locked keys first.
    /// `avatarShape` is allowed EXCEPT `rectangle`: circle / square /
    /// roundedSquare only change the corner fraction at a fixed size,
    /// while rectangle narrows the avatar (aspect 0.78) and therefore
    /// resizes layout. `fontFamily` is rejected as ambiguous: it is not
    /// a font size, and different families reflow text at the same size.
    static let aiApplyLockedFields: Set<String> = [
        // Corner radii (layout dimensions).
        "userBubbleRadius", "assistantBubbleRadius", "thinkingRadius", "inputBarRadius",
        // Bubble / bar / list shapes (layout, not colour).
        "userBubbleStyle", "assistantBubbleStyle", "inputBarStyle", "listIconShape",
        // Spacing / text metrics (layout dimensions).
        "lineHeight", "letterSpacing",
        // Bubble-pack structure (layout, not colour): the AI may not
        // set any of these; only the user, via a pack tap in the UI.
        // The pack text hexes are pack-owned colours, locked with
        // the pack for the same reason — they must only arrive
        // together with the pack that carries them.
        "userBubbleSurface", "assistantBubbleSurface",
        "userBubbleBorderWidth", "assistantBubbleBorderWidth",
        "userBubblePadding", "assistantBubblePadding",
        "avatarSize", "avatarBorderWidth", "avatarPlacement",
        "userMetaPosition", "assistantMetaPosition",
        "userNamePlacement", "assistantNamePlacement",
        "messageSpacing", "bubbleCornerPreset", "bubblePackShape",
        "bubbleBackgroundImageFile", "bubblePattern", "bubblePatternOpacity",
        "bubbleDecorationsJSON", "userBubblePackTextHex", "assistantBubblePackTextHex",
        // Per-side shape / foundation fields are layout, locked
        // exactly like their shared twins: the AI may not set
        // them, only the user via a pack tap in the UI.
        "userBubblePackShape", "assistantBubblePackShape",
        "userBubbleBackgroundImageFile", "assistantBubbleBackgroundImageFile",
        "userBubblePattern", "assistantBubblePattern",
        "userBubblePatternOpacity", "assistantBubblePatternOpacity",
        "userBubbleDecorationsJSON", "assistantBubbleDecorationsJSON",
        // Opacities and shade (locked surface treatment, not colour).
        "surfaceOpacity", "wallpaperShade", "thinkingCardImageOpacity", "inputBarImageOpacity",
        // Display modes and line-count layout.
        "chatDisplay", "novelMode", "codeBlockCollapseLines",
        // Ambiguous between font size and layout: rejected, see above.
        "fontFamily", "messageFontFamily", "messageCustomFont", "uiCustomFont",
        // Icons / symbols and the standee image: not colours, wallpaper,
        // font sizes, or avatar shape.
        "categoryIcons", "categoryImages", "characterArtBase64",
        // Page-scope state: the AI may change global colours and
        // the global wallpaper, but never a page's colours or
        // wallpaper — those are the user's per-page tuning.
        "pageColorsLight", "pageColorsDark", "pageWallpapers",
    ]

    /// Locked keys present in `raw`, sorted. Empty means the AI apply
    /// carries only allowed fields (colours, wallpaper/surface images,
    /// thinkingTitleSize / thinkingBodySize, avatarShape other than
    /// rectangle, plus id / name / schema metadata).
    static func aiApplyRejectedFields(in raw: [String: Any]) -> [String] {
        var rejected = aiApplyLockedFields.intersection(raw.keys)
        if let shape = raw["avatarShape"] as? String {
            // [T-51] Unknown shape names used to sail through and quietly
            // parse into a circle — the AI reported a change that never
            // happened. Reject anything that is not a real shape, and keep
            // rectangle locked (it resizes the avatar frame).
            let known = Set(AppearanceAvatarShape.allCases.map(\.rawValue))
            if shape == "rectangle" || !known.contains(shape) {
                rejected.insert("avatarShape")
            }
        }
        return rejected.sorted()
    }

    /// - Parameter base: Pack supplying every key `raw` does not carry.
    ///   Pass the pack currently on screen for partial updates (AI `minis-theme
    ///   apply`, clipboard import) so untouched fields — the category image
    ///   markers in particular — survive. Keep `.default` when decoding a
    ///   complete snapshot: a stored pack, or a saved theme in the library.
    static func decode(_ raw: [String: Any],
                       merging base: AppearanceThemePack = .default) throws -> AppearanceThemePack {
        // Old / partial packs: fill missing keys from `base` and treat as schema 5.
        // Reject only JSON that does not look like a theme pack at all.
        guard looksLikeThemePack(raw) else {
            throw AppearanceThemePackError.notAThemePack
        }
        func str(_ k: String, fallback: String) -> String {
            (raw[k] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? (raw[k] as! String) : fallback
        }
        func num(_ k: String, fallback: Double) -> Double {
            if let d = raw[k] as? Double { return d }
            if let i = raw[k] as? Int { return Double(i) }
            if let s = raw[k] as? String, let d = Double(s) { return d }
            return fallback
        }
        func map(_ k: String, fallback: [String: String]) -> [String: String] {
            if let typed = raw[k] as? [String: String] { return typed }
            guard let anyMap = raw[k] as? [String: Any] else { return fallback }
            var out: [String: String] = [:]
            for (key, val) in anyMap {
                if let s = val as? String { out[key] = s }
            }
            return out
        }
        // Per-side field resolution: a present per-side key wins
        // (including an explicit null for image / decorations,
        // which decodes to nil = "this side has none"); an
        // absent per-side key falls back to the shared field,
        // so pre-split packs migrate with their shape intact;
        // a pack with neither falls back to base. Note str()
        // treats a present-but-blank string as absent, which is
        // the right behaviour for shape / pattern names.
        func sideStr(_ sideKey: String, _ sharedKey: String, fallback: String) -> String {
            raw[sideKey] != nil ? str(sideKey, fallback: fallback)
                : str(sharedKey, fallback: fallback)
        }
        func sideNum(_ sideKey: String, _ sharedKey: String, fallback: Double) -> Double {
            raw[sideKey] != nil ? num(sideKey, fallback: fallback)
                : num(sharedKey, fallback: fallback)
        }
        func sideImage(_ sideKey: String, _ sharedKey: String, fallback: String?) -> String? {
            if raw[sideKey] != nil {
                return (raw[sideKey] as? String).flatMap { $0.isEmpty ? nil : $0 }
            }
            if raw[sharedKey] != nil {
                return (raw[sharedKey] as? String).flatMap { $0.isEmpty ? nil : $0 }
            }
            return fallback
        }
        func sideDecorations(_ sideKey: String, _ sharedKey: String, fallback: String?) -> String? {
            if raw[sideKey] != nil { return raw[sideKey] as? String }
            if raw[sharedKey] != nil { return raw[sharedKey] as? String }
            return fallback
        }
        // [page-state] Presence-sensitive decoding, deliberately
        // NOT filled from base: an absent key means "this pack
        // says nothing about page state" (old packs, partial
        // merges), while a present key — even one whose scopes
        // all come out empty — is an explicit statement. Filling
        // from base would smuggle the live pack's page state
        // into a partial apply and revert page edits made since
        // that pack was applied. Unknown scopes and
        // wallpaper-only scopes (bottomBar, terminal) are
        // dropped from colour maps; the global scope is dropped
        // from both maps (it has its own fields).
        func pageColorMap(_ k: String) -> [String: [String: String]]? {
            guard let outer = raw[k] as? [String: Any] else { return nil }
            var out: [String: [String: String]] = [:]
            for (scopeRaw, inner) in outer {
                guard let scope = AppearanceScope(rawValue: scopeRaw),
                      scope != .global, scope.supportsColour else { continue }
                let innerMap: [String: String]
                if let typed = inner as? [String: String] { innerMap = typed }
                else if let anyMap = inner as? [String: Any] {
                    var m: [String: String] = [:]
                    for (rk, rv) in anyMap { if let s = rv as? String { m[rk] = s } }
                    innerMap = m
                } else { continue }
                let normalized = normalizeHexMap(innerMap)
                if !normalized.isEmpty { out[scopeRaw] = normalized }
            }
            return out
        }
        func pageWallpaperMap() -> [String: String]? {
            guard let outer = raw["pageWallpapers"] as? [String: Any] else { return nil }
            var out: [String: String] = [:]
            for (scopeRaw, v) in outer {
                guard AppearanceScope(rawValue: scopeRaw) != nil,
                      scopeRaw != AppearanceScope.global.rawValue,
                      let s = v as? String else { continue }
                // "" is the explicitly-cleared sentinel, kept;
                // a non-empty string is a base64 JPEG.
                out[scopeRaw] = s
            }
            return out
        }
        var pack = AppearanceThemePack(
            id: str("id", fallback: base.id),
            name: str("name", fallback: base.name),
            userBubbleRadius: clampRadius(num("userBubbleRadius", fallback: base.userBubbleRadius)),
            assistantBubbleRadius: clampRadius(num("assistantBubbleRadius", fallback: base.assistantBubbleRadius)),
            thinkingRadius: clampRadius(num("thinkingRadius", fallback: base.thinkingRadius)),
            thinkingFillHex: normalizeOptionalHex(str("thinkingFillHex", fallback: base.thinkingFillHex)),
            thinkingStrokeHex: normalizeOptionalHex(str("thinkingStrokeHex", fallback: base.thinkingStrokeHex)),
            thinkingAccentHex: normalizeOptionalHex(str("thinkingAccentHex", fallback: base.thinkingAccentHex)),
            userBubbleStyle: AppearanceBubbleStyle.parse(str("userBubbleStyle", fallback: base.userBubbleStyle)).rawValue,
            assistantBubbleStyle: AppearanceBubbleStyle.parse(str("assistantBubbleStyle", fallback: base.assistantBubbleStyle)).rawValue,
            thinkingCardJPEGBase64: raw["thinkingCardJPEGBase64"] as? String,
            thinkingCardImageOpacity: min(1, max(0.05, num("thinkingCardImageOpacity", fallback: base.thinkingCardImageOpacity))),
            listRowFillHex: (raw["listRowFillHex"] as? String).map(normalizeHex),
            listIconShape: AppearanceListIconShape.parse(str("listIconShape", fallback: base.listIconShape)).rawValue,
            categoryIcons: filterCategoryMap(map("categoryIcons", fallback: base.categoryIcons), symbols: true),
            categoryColors: filterCategoryMap(map("categoryColors", fallback: base.categoryColors), symbols: false),
            categoryImages: filterCategoryMap(map("categoryImages", fallback: base.categoryImages), symbols: true),
            inputBarRadius: clampRadius(num("inputBarRadius", fallback: base.inputBarRadius)),
            inputBarStyle: AppearanceBubbleStyle.parse(str("inputBarStyle", fallback: base.inputBarStyle)).rawValue,
            inputBarJPEGBase64: raw["inputBarJPEGBase64"] as? String,
            inputBarImageOpacity: min(1, max(0.05, num("inputBarImageOpacity", fallback: base.inputBarImageOpacity))),
            thinkingTitleSize: min(22, max(10, num("thinkingTitleSize", fallback: base.thinkingTitleSize))),
            thinkingBodySize: min(22, max(10, num("thinkingBodySize", fallback: base.thinkingBodySize))),
            fontFamily: AppearanceFontFamily.parse(str("fontFamily", fallback: base.fontFamily)).rawValue,
            messageFontFamily: str("messageFontFamily", fallback: base.messageFontFamily),
            messageCustomFont: (raw["messageCustomFont"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? base.messageCustomFont,
            uiCustomFont: (raw["uiCustomFont"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? base.uiCustomFont,
            wallpaperShade: raw["wallpaperShade"] == nil ? nil : min(0.65, max(0, num("wallpaperShade", fallback: 0.08))),
            surfaceOpacity: raw["surfaceOpacity"] == nil ? nil : min(1, max(0.35, num("surfaceOpacity", fallback: 0.88))),
            colorsLight: normalizeHexMap(map("colorsLight", fallback: base.colorsLight)),
            colorsDark: normalizeHexMap(map("colorsDark", fallback: base.colorsDark)),
            wallpaperJPEGBase64: raw["wallpaperJPEGBase64"] as? String,
            pageColorsLight: pageColorMap("pageColorsLight"),
            pageColorsDark: pageColorMap("pageColorsDark"),
            pageWallpapers: pageWallpaperMap(),
            avatarShape: AppearanceAvatarShape.parse(str("avatarShape", fallback: base.avatarShape)).rawValue,
            chatDisplay: AppearanceChatDisplay.parse(str("chatDisplay", fallback: base.chatDisplay)).rawValue,
            lineHeight: min(2.2, max(0.9, num("lineHeight", fallback: base.lineHeight))),
            letterSpacing: min(3, max(-1, num("letterSpacing", fallback: base.letterSpacing))),
            rowBackgroundHex: (raw["rowBackgroundHex"] as? String).map(normalizeHex),
            novelMode: AppearanceNovelMode.parse(str("novelMode", fallback: base.novelMode)).rawValue,
            characterArtBase64: raw["characterArtBase64"] as? String,
            codeBlockCollapseLines: min(40, max(4, Int(num("codeBlockCollapseLines", fallback: Double(base.codeBlockCollapseLines))))),
            userBubbleSurface: BubbleSurface.parse(str("userBubbleSurface", fallback: base.userBubbleSurface)).rawValue,
            assistantBubbleSurface: BubbleSurface.parse(str("assistantBubbleSurface", fallback: base.assistantBubbleSurface)).rawValue,
            userBubbleBorderWidth: min(2, max(0, num("userBubbleBorderWidth", fallback: base.userBubbleBorderWidth))),
            assistantBubbleBorderWidth: min(2, max(0, num("assistantBubbleBorderWidth", fallback: base.assistantBubbleBorderWidth))),
            userBubblePadding: min(20, max(8, num("userBubblePadding", fallback: base.userBubblePadding))),
            assistantBubblePadding: min(20, max(8, num("assistantBubblePadding", fallback: base.assistantBubblePadding))),
            avatarSize: min(64, max(28, num("avatarSize", fallback: base.avatarSize))),
            avatarBorderWidth: min(3, max(0, num("avatarBorderWidth", fallback: base.avatarBorderWidth))),
            avatarPlacement: BubbleAvatarPlacement.parse(str("avatarPlacement", fallback: base.avatarPlacement)).rawValue,
            userMetaPosition: BubbleMetaPosition.parse(str("userMetaPosition", fallback: base.userMetaPosition)).rawValue,
            assistantMetaPosition: BubbleMetaPosition.parse(str("assistantMetaPosition", fallback: base.assistantMetaPosition)).rawValue,
            userNamePlacement: BubbleNamePlacement.parse(str("userNamePlacement", fallback: base.userNamePlacement)).rawValue,
            assistantNamePlacement: BubbleNamePlacement.parse(str("assistantNamePlacement", fallback: base.assistantNamePlacement)).rawValue,
            messageSpacing: min(24, max(4, num("messageSpacing", fallback: base.messageSpacing))),
            bubbleCornerPreset: BubbleCornerPreset.parse(str("bubbleCornerPreset", fallback: base.bubbleCornerPreset)).rawValue,
            bubblePackShape: BubblePackKind.parse(str("bubblePackShape", fallback: base.bubblePackShape)).rawValue,
            // Foundation fields, partial-merge safe: an absent key
            // keeps the base value (an AI colour apply must never
            // silently clear the applied pack's background); a
            // present key, even an empty one, replaces it.
            bubbleBackgroundImageFile: raw["bubbleBackgroundImageFile"] == nil
                ? base.bubbleBackgroundImageFile
                : (raw["bubbleBackgroundImageFile"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            bubblePattern: BubblePattern.parse(str("bubblePattern", fallback: base.bubblePattern)).rawValue,
            bubblePatternOpacity: min(0.6, max(0, num("bubblePatternOpacity", fallback: base.bubblePatternOpacity))),
            bubbleDecorationsJSON: raw["bubbleDecorationsJSON"] == nil
                ? base.bubbleDecorationsJSON : (raw["bubbleDecorationsJSON"] as? String),
            userBubblePackTextHex: raw["userBubblePackTextHex"] == nil
                ? base.userBubblePackTextHex
                : BubbleStyleRecord.normalizedPackHex(raw["userBubblePackTextHex"] as? String),
            assistantBubblePackTextHex: raw["assistantBubblePackTextHex"] == nil
                ? base.assistantBubblePackTextHex
                : BubbleStyleRecord.normalizedPackHex(raw["assistantBubblePackTextHex"] as? String),
            userBubblePackShape: BubblePackKind.parse(sideStr("userBubblePackShape", "bubblePackShape", fallback: base.userBubblePackShape)).rawValue,
            assistantBubblePackShape: BubblePackKind.parse(sideStr("assistantBubblePackShape", "bubblePackShape", fallback: base.assistantBubblePackShape)).rawValue,
            userBubbleBackgroundImageFile: sideImage("userBubbleBackgroundImageFile", "bubbleBackgroundImageFile", fallback: base.userBubbleBackgroundImageFile),
            assistantBubbleBackgroundImageFile: sideImage("assistantBubbleBackgroundImageFile", "bubbleBackgroundImageFile", fallback: base.assistantBubbleBackgroundImageFile),
            userBubblePattern: BubblePattern.parse(sideStr("userBubblePattern", "bubblePattern", fallback: base.userBubblePattern)).rawValue,
            assistantBubblePattern: BubblePattern.parse(sideStr("assistantBubblePattern", "bubblePattern", fallback: base.assistantBubblePattern)).rawValue,
            userBubblePatternOpacity: min(0.6, max(0, sideNum("userBubblePatternOpacity", "bubblePatternOpacity", fallback: base.userBubblePatternOpacity))),
            assistantBubblePatternOpacity: min(0.6, max(0, sideNum("assistantBubblePatternOpacity", "bubblePatternOpacity", fallback: base.assistantBubblePatternOpacity))),
            userBubbleDecorationsJSON: sideDecorations("userBubbleDecorationsJSON", "bubbleDecorationsJSON", fallback: base.userBubbleDecorationsJSON),
            assistantBubbleDecorationsJSON: sideDecorations("assistantBubbleDecorationsJSON", "bubbleDecorationsJSON", fallback: base.assistantBubbleDecorationsJSON)
        )
        if pack.id.isEmpty { pack.id = base.id }
        if pack.name.isEmpty { pack.name = pack.id }
        return pack
    }
}

enum AppearanceThemePackError: LocalizedError {
    case notAThemePack

    var errorDescription: String? {
        switch self {
        case .notAThemePack:
            return "Not a theme pack."
        }
    }
}

enum AppearanceShapeKind {
    case userBubble, assistantBubble, thinking
}

enum AppearanceListIconShape: String, CaseIterable, Identifiable {
    case circle, squircle, rounded
    var id: String { rawValue }
    var title: String {
        switch self {
        case .circle: return AppLocalized("圆")
        case .squircle: return AppLocalized("方圆")
        case .rounded: return AppLocalized("圆角方")
        }
    }
    static func parse(_ raw: String) -> AppearanceListIconShape {
        AppearanceListIconShape(rawValue: raw) ?? .circle
    }
}

fileprivate func filterCategoryMap(_ map: [String: String], symbols: Bool) -> [String: String] {
    let allowed = Set(AppearanceThemePack.categoryKeys)
    var out: [String: String] = [:]
    for (k, v) in map {
        guard allowed.contains(k) else { continue }
        let trimmed = v.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { continue }
        out[k] = symbols ? trimmed : normalizeHex(trimmed)
    }
    return out
}

enum AppearanceFontFamily: String, CaseIterable, Identifiable {
    case system, rounded, serif, mono
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return AppLocalized("系统")
        case .rounded: return AppLocalized("圆体")
        case .serif: return AppLocalized("衬线")
        case .mono: return AppLocalized("等宽")
        }
    }
    var design: Font.Design {
        switch self {
        case .system: return .default
        case .rounded: return .rounded
        case .serif: return .serif
        case .mono: return .monospaced
        }
    }
    var uiDesign: UIFontDescriptor.SystemDesign {
        switch self {
        case .system: return .default
        case .rounded: return .rounded
        case .serif: return .serif
        case .mono: return .monospaced
        }
    }
    static func parse(_ raw: String) -> AppearanceFontFamily {
        AppearanceFontFamily(rawValue: raw) ?? .system
    }

    func uiFont(size: CGFloat, weight: UIFont.Weight = .regular) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        if let descriptor = base.fontDescriptor.withDesign(uiDesign) {
            return UIFont(descriptor: descriptor, size: size)
        }
        return base
    }

    func font(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: design)
    }

    /// The global family for UIKit input text: the stored
    /// message override wins when present (same rule as
    /// `MinisThemeShape.globalFontFamily`), so the input box
    /// follows the same single choice as messages and UI.
    static func resolved() -> AppearanceFontFamily {
        guard let data = UserDefaults.standard.data(forKey: AppearanceThemePack.currentKey),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .system
        }
        if let override = obj["messageFontFamily"] as? String, !override.isEmpty {
            return parse(override)
        }
        guard let raw = obj["fontFamily"] as? String else {
            return .system
        }
        return parse(raw)
    }
}

enum AppearanceBubbleStyle: String, CaseIterable, Identifiable {
    case rounded, squircle, pill, tail, sharp
    var id: String { rawValue }
    var title: String {
        switch self {
        case .rounded: return AppLocalized("圆角")
        case .squircle: return AppLocalized("连续圆角")
        case .pill: return AppLocalized("胶囊")
        case .tail: return AppLocalized("小尾巴")
        case .sharp: return AppLocalized("方一点")
        }
    }
    static func parse(_ raw: String) -> AppearanceBubbleStyle {
        AppearanceBubbleStyle(rawValue: raw) ?? .rounded
    }
}

fileprivate func clampRadius(_ value: Double) -> Double {
    min(32, max(4, value))
}

/// [B28 B-3] 三个 thinking 字段允许空串，表示"跟 accent 走"。
/// `normalizeHex("")` 会回落到 808080 灰，所以这几个字段单独走这里。
fileprivate func normalizeOptionalHex(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "" : normalizeHex(trimmed)
}

fileprivate func normalizeHex(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: CharacterSet.alphanumerics.inverted).uppercased()
    guard trimmed.count == 6 || trimmed.count == 8 else { return "808080" }
    // Length alone let "ZZZZZZ" through, which scanned to 0 and painted
    // black. Require actual hex digits so a typo lands on neutral grey.
    guard trimmed.allSatisfy({ $0.isHexDigit }) else { return "808080" }
    return trimmed
}

fileprivate func normalizeHexMap(_ map: [String: String]) -> [String: String] {
    var out: [String: String] = [:]
    let allowed = Set(AppearanceColorRole.allCases.map(\.rawValue))
    for (k, v) in map {
        guard allowed.contains(k) else { continue }
        out[k] = normalizeHex(v)
    }
    return out
}

/// Chat bubble / thinking card clip. Tail sits on the outer side
/// (user = trailing, assistant = leading).
struct MinisBubbleShape: Shape {
    var style: AppearanceBubbleStyle
    var radius: CGFloat
    var tailOnTrailing: Bool
    /// Per-corner radii, used only for .rounded/.squircle (non-tail).
    /// nil = uniform radius. The asymmetric pack preset supplies this:
    /// the outer corner near-sharp (4pt), the rest at `radius`.
    var cornerRadii: RectangleCornerRadii?
    /// Dressing-shop pack shape. When set to a non-porcelain
    /// kind, it owns the outline (cloud / wave / cut / letter /
    /// stitch) and the base style only supplies the radius — so
    /// shop samples, detail previews, and live chat all draw the
    /// same outline. Porcelain falls through (see path()).
    var packKind: BubblePackKind?

    func path(in rect: CGRect) -> Path {
        // Porcelain falls through to the existing style/corner
        // logic on purpose: a hand-picked asymmetric preset (old
        // bubbles page) must still draw its asymmetric corners,
        // and porcelain's live style is already pill. Only the
        // non-porcelain kinds own the outline.
        if let kind = packKind, kind != .porcelain {
            return BubblePackOutlineShape(kind: kind, radius: radius).path(in: rect)
        }
        let r = min(max(radius, 4), min(rect.width, rect.height) / 2)
        switch style {
        case .rounded:
            if let corners = cornerRadii {
                return Path(UnevenRoundedRectangle(cornerRadii: corners, style: .circular).path(in: rect).cgPath)
            }
            return rounded(rect, r, continuous: false)
        case .squircle:
            if let corners = cornerRadii {
                return Path(UnevenRoundedRectangle(cornerRadii: corners, style: .continuous).path(in: rect).cgPath)
            }
            return rounded(rect, r, continuous: true)
        case .pill:
            // Fixed radius, not a capsule that grows with the text:
            // `r` above is already capped by the theme's radius
            // field (4...32), so a long multi-line message stays a
            // rounded rectangle and only grows downward, instead of
            // ballooning into an ellipse that clips its own text.
            return rounded(rect, r, continuous: true)
        case .sharp:
            return rounded(rect, min(6, r * 0.35), continuous: false)
        case .tail:
            return tailedPath(in: rect, corner: r)
        }
    }

    private func rounded(_ rect: CGRect, _ r: CGFloat, continuous: Bool) -> Path {
        Path(RoundedRectangle(cornerRadius: r, style: continuous ? .continuous : .circular).path(in: rect).cgPath)
    }

    private func tailedPath(in rect: CGRect, corner: CGFloat) -> Path {
        let tail: CGFloat = 7
        let body = tailOnTrailing
            ? CGRect(x: rect.minX, y: rect.minY, width: max(1, rect.width - tail), height: rect.height)
            : CGRect(x: rect.minX + tail, y: rect.minY, width: max(1, rect.width - tail), height: rect.height)
        var path = rounded(body, corner, continuous: true)
        let baseY = body.maxY - max(10, corner)
        if tailOnTrailing {
            path.move(to: CGPoint(x: body.maxX - 1, y: baseY - 7))
            path.addLine(to: CGPoint(x: rect.maxX, y: baseY))
            path.addLine(to: CGPoint(x: body.maxX - 1, y: baseY + 5))
            path.closeSubpath()
        } else {
            path.move(to: CGPoint(x: body.minX + 1, y: baseY - 7))
            path.addLine(to: CGPoint(x: rect.minX, y: baseY))
            path.addLine(to: CGPoint(x: body.minX + 1, y: baseY + 5))
            path.closeSubpath()
        }
        return path
    }
}

extension AppearanceStudio {
    private static let packKey = AppearanceThemePack.currentKey

    func loadStoredPack() -> AppearanceThemePack {
        currentThemePack()
    }

    func currentThemePack() -> AppearanceThemePack {
        themePackLock.lock()
        defer { themePackLock.unlock() }
        if !themePackLoaded {
            cachedThemePack = loadStoredPackUnlocked()
            themePackLoaded = true
        }
        return cachedThemePack
    }

    func loadStoredPackUnlocked() -> AppearanceThemePack {
        guard let data = UserDefaults.standard.data(forKey: Self.packKey),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var pack = try? AppearanceThemePack.decode(obj) else {
            return .default
        }
        // Font-unification healing, same one-time pattern as
        // the bubble-surface fix below: a pack stored when
        // fonts were per part (message vs UI) folds to ONE
        // global font on first launch after update (message
        // wins), and is written back, so every reader sees
        // the same global choice with no re-tap needed.
        // Direct UserDefaults set, same as the schema upgrade
        // below — avoid persistPack (would re-enter themePackLock).
        let unified = AppearanceThemePack.unifiedFonts(pack)
        if unified.fontFamily != pack.fontFamily
            || unified.messageFontFamily != pack.messageFontFamily
            || unified.messageCustomFont != pack.messageCustomFont
            || unified.uiCustomFont != pack.uiCustomFont {
            pack = unified
            if let healed = try? JSONSerialization.data(withJSONObject: pack.asJSONObject()) {
                UserDefaults.standard.set(healed, forKey: Self.packKey)
            }
        }
        // Bubble-width fix, one-time healing: the three packs whose
        // records used to be .row (porcelain BUB-0001, wave
        // BUB-0004, stitch BUB-0006) wrote .row surfaces into the
        // live theme, so already-applied users kept full-width
        // bubbles even after the catalogue was fixed — changing
        // built-ins alone only helps the next tap-apply. Rewrite
        // those surfaces to .text here, so live chat hugs its text
        // on the first launch after update, with no re-tap needed.
        // No UI picker ever writes .row (only pack apply does), and
        // no pack writes .row anymore, so this cannot clobber a
        // deliberate user choice. Direct UserDefaults set, same as
        // the schema upgrade below — avoid persistPack (would
        // re-enter themePackLock).
        if (pack.bubblePackShape == BubblePackKind.porcelain.rawValue
            || pack.bubblePackShape == BubblePackKind.wave.rawValue
            || pack.bubblePackShape == BubblePackKind.stitch.rawValue)
            && (pack.userBubbleSurface == BubbleSurface.row.rawValue
                || pack.assistantBubbleSurface == BubbleSurface.row.rawValue) {
            pack.userBubbleSurface = BubbleSurface.text.rawValue
            pack.assistantBubbleSurface = BubbleSurface.text.rawValue
            if let healed = try? JSONSerialization.data(withJSONObject: pack.asJSONObject()) {
                UserDefaults.standard.set(healed, forKey: Self.packKey)
            }
        }
        // Persist upgraded schema 5 when stored JSON had missing/old schema.
        // Direct UserDefaults set — avoid persistPack (would re-enter themePackLock).
        let storedSchema: Int? = {
            guard let raw = obj["schema"] else { return nil }
            if let i = raw as? Int { return i }
            if let d = raw as? Double { return Int(d) }
            if let s = raw as? String {
                return Int(s.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return nil
        }()
        if storedSchema != AppearanceThemePack.schemaVersion,
           let upgraded = try? JSONSerialization.data(withJSONObject: pack.asJSONObject()) {
            UserDefaults.standard.set(upgraded, forKey: Self.packKey)
        }
        // [B28 A-1] 老 pack 把立绘整张 base64 存在这里。搬到文件、字段置 nil，
        // 顺手把 defaults 里那份也重写掉 —— 否则每次读还是把几百 KB 搬进内存。
        // 只在字段非空时跑一次，之后永远为 nil。
        if let inline = pack.characterArtBase64, !inline.isEmpty,
           let art = Data(base64Encoded: inline) {
            writeEncodedImage(art, to: characterArtURL(), maxEdge: 1600, quality: 0.82)
            var cleaned = pack
            cleaned.characterArtBase64 = nil
            if let data = try? JSONSerialization.data(withJSONObject: cleaned.asJSONObject()) {
                UserDefaults.standard.set(data, forKey: Self.packKey)
            }
            return cleaned
        }
        return pack
    }

    func persistPack(_ pack: AppearanceThemePack) {
        // Packs arriving here from an import or a theme apply
        // never passed the load-time healing above, so fold
        // per-part fonts to the global choice here too — a
        // stored pack can never diverge again after any write.
        let pack = AppearanceThemePack.unifiedFonts(pack)
        guard let data = try? JSONSerialization.data(withJSONObject: pack.asJSONObject()) else { return }
        UserDefaults.standard.set(data, forKey: Self.packKey)
        // [10-20 醒醒] 代码块的换行/折叠阈值要给 UIKit 侧读。那条链路不能碰
        // @MainActor 的 AppearanceStudio，所以额外写一份扁平快照。
        UserDefaults.standard.set([
                                   "collapseLines": pack.codeBlockCollapseLines],
                                  forKey: "appearanceStudio.codeBlock.v1")
        themePackLock.lock()
        cachedThemePack = pack
        themePackLoaded = true
        themePackLock.unlock()
        themePackRevision += 1
        objectWillChange.send()
    }

    /// How a pack apply treats fields the pack does not carry.
    ///
    /// - replace: a theme switch. The new pack IS the whole theme, so
    ///   images, global colours, and page-scope colours and
    ///   wallpapers it does not carry are cleared, not inherited
    ///   from the old pack. Used by theme-library apply and
    ///   clipboard import — the paths a user means as "switch theme".
    /// - merge: a partial update. Only the fields carried change; anything
    ///   omitted stays. Only the AI local-update path
    ///   (`minis-theme apply --file`) uses merge, and it is labelled
    ///   partial-only at its call site.
    enum ThemeApplyMode { case replace, merge }

    /// Applies a pack to the live studio.
    ///
    /// Merge mode keeps the old rule: a nil base64 means "this call does
    /// not carry that image", so the file on disk stays. Replace mode
    /// inverts it: a nil/empty base64 means "this theme has no such
    /// image", so the old file is deleted — otherwise switching from a
    /// rich pack to a sparse pack would leave the old wallpaper, thinking
    /// card, input-bar, character-art and category images on screen.
    /// [B28 R3-5 / F-2] 图吃不下以前也照样应用成功 —— 应用方（UI/CLI/AI）
    /// 需要知道哪些字段没落住，返回值就是那份实话。
    @discardableResult
    func applyThemePack(_ pack: AppearanceThemePack, wallpaper: UIImage? = nil,
                        mode: ThemeApplyMode = .merge) -> [String] {
        var warnings: [String] = []
        let replace = (mode == .replace)
        var stored = pack
        stored.wallpaperJPEGBase64 = nil
        stored.thinkingCardJPEGBase64 = nil
        stored.inputBarJPEGBase64 = nil
        // [page-state] Page wallpapers are transport only, like
        // the global one: files on disk, never base64 in defaults.
        // Page colours stay on the stored pack, like the global
        // colour maps — they are hex, not image bytes.
        stored.pageWallpapers = nil
        // [B28 A-1] 立绘也不再进 defaults：落成文件，字段置 nil。
        stored.characterArtBase64 = nil
        // Merge mode keeps markers for category images the caller did
        // not mention. Replace mode starts from exactly what the new
        // pack carries; applyCategoryImages below (fed "" for missing
        // keys) deletes the rest from disk.
        if replace {
            stored.categoryImages = pack.categoryImages
        } else {
            let mentioned = Set(pack.categoryImages.keys)
            var markers = currentThemePack().categoryImages
            for key in mentioned { markers[key] = pack.categoryImages[key] }
            stored.categoryImages = markers
        }
        // Replace pre-clear atomicity: persist the new pack BEFORE
        // deleting anything the old theme left behind, and abort if the
        // persist did not land — otherwise a failure between clear and
        // persist would leave deleted files recorded under the old pack.
        // persistPack sets cachedThemePack on success, so a mismatch
        // here means it failed; nothing has been deleted or written yet
        // (all image writes happen below), so returning now is safe.
        persistPack(stored)
        if replace, currentThemePack() != stored {
            warnings.append("pack")
            return warnings
        }
        // Replace mode: clear every slot the new pack does not carry.
        // The writes below then put back only what the new pack actually
        // carries. (A payload that is present but undecodable still
        // keeps the old file plus a warning — a corrupt pack must not
        // destroy a good image.)
        if replace {
            if wallpaper == nil, !(pack.wallpaperJPEGBase64?.isEmpty == false) {
                removeWallpaper(.global)
            }
            // User packs now carry per-page wallpapers, written back
            // in the page paint below; this pre-clear still removes
            // every page wallpaper first, so a scope the new pack does
            // not carry does not survive the switch. The "never
            // carries" claim now holds only for the AI merge path,
            // where page fields are stripped before apply.
            for scope in AppearanceScope.allCases where scope != .global {
                removeWallpaper(scope)
            }
            if !(pack.thinkingCardJPEGBase64?.isEmpty == false) {
                removeThinkingCardImage()
            }
            if !(pack.inputBarJPEGBase64?.isEmpty == false) {
                removeInputBarImage()
            }
            if !(pack.characterArtBase64?.isEmpty == false) {
                removeCharacterArt()
            }
            // [page-state-fix] Replace means the new pack IS the whole
            // theme, page state included — but only when the pack
            // actually speaks about page colours. A nil page table
            // means "this pack says nothing about page colours",
            // not "page colours are empty" (merge mode already
            // treats nil that way), so an old pack (both page
            // colour tables nil) must NOT wipe colours the user
            // tuned on a page on purpose: the P0-4 preserve rule
            // still applies to it, and the apply path has no undo
            // snapshot to give them back. Only a pack that carries
            // page colours gets the wipe-then-repaint below, so
            // its page state ends up exactly the pack's.
            if pack.pageColorsLight == nil, pack.pageColorsDark == nil {
                // P0-4 (restored): page-scope overrides are kept,
                // so a theme switch does not silently wipe a page
                // the user tuned on purpose. The global paint below
                // repaints globals from the pack; a colourless pack
                // therefore falls back to the built-in palette
                // instead of keeping the old one.
                let globalPrefix = AppearanceScope.global.rawValue + "."
                let keptPageColours = exportColorOverrides().filter {
                    !$0.key.hasPrefix(globalPrefix)
                }
                restoreColorOverrides(keptPageColours)
            } else {
                restoreColorOverrides([:])
            }
        }
        // Character-art write moved after the persist+guard above, so a
        // persist failure cannot leave a half-written character art
        // behind while the old pack is still recorded.
        if let b64 = pack.characterArtBase64 {
            if let data = Data(base64Encoded: b64) {
                if !writeEncodedImage(data, to: characterArtURL(), maxEdge: 1600, quality: 0.82) {
                    warnings.append("characterArt")
                }
            } else { warnings.append("characterArt") }
        }
        if !pack.colorsLight.isEmpty || !pack.colorsDark.isEmpty {
            applyPackColors(light: pack.colorsLight, dark: pack.colorsDark)
        }
        if let opacity = pack.surfaceOpacity { surfaceOpacity = opacity }
        else if replace { surfaceOpacity = 0.88 }
        if let shade = pack.wallpaperShade { wallpaperShade = shade }
        else if replace { wallpaperShade = 0.08 }
        // A saved pack never carries bubbleOpacity, so in replace mode
        // it reverts to the built-in 1.0 instead of keeping the old
        // theme's value — same rule as surfaceOpacity/wallpaperShade.
        if replace { bubbleOpacity = 1.0 }
        if let wallpaper {
            if !setWallpaper(wallpaper, for: .global) { warnings.append("wallpaper") }
        } else if let b64 = pack.wallpaperJPEGBase64 {
            if let data = Data(base64Encoded: b64) {
                if !setWallpaperEncoded(data, for: .global) { warnings.append("wallpaper") }
            } else { warnings.append("wallpaper") }
        }
        if let b64 = pack.thinkingCardJPEGBase64 {
            if let data = Data(base64Encoded: b64) {
                if !setThinkingCardImageEncoded(data) { warnings.append("thinkingCard") }
            } else { warnings.append("thinkingCard") }
        }
        if let b64 = pack.inputBarJPEGBase64 {
            if let data = Data(base64Encoded: b64) {
                if !setInputBarImageEncoded(data) { warnings.append("inputBar") }
            } else { warnings.append("inputBar") }
        }
        // [page-state] Page colours and wallpapers carried by the
        // pack. The same code serves both modes, because the
        // maps only ever list carried scopes: in replace mode
        // the wipes above already cleared everything, so writing
        // the carried scopes leaves exactly the pack's page
        // state; in merge mode unlisted scopes are untouched.
        // A nil map (old pack, partial merge) writes nothing.
        if let pageColors = pack.pageColorsLight {
            applyPageColors(pageColors, variant: .light)
        }
        if let pageColors = pack.pageColorsDark {
            applyPageColors(pageColors, variant: .dark)
        }
        if let wallpapers = pack.pageWallpapers {
            for (scopeRaw, b64) in wallpapers {
                guard let scope = AppearanceScope(rawValue: scopeRaw),
                      scope != .global else { continue }
                if b64.isEmpty {
                    // Explicitly cleared: cut global inheritance,
                    // not just the file (removeWallpaper would
                    // drop the cleared flag and re-inherit).
                    clearWallpaper(scope)
                    continue
                }
                guard let data = Data(base64Encoded: b64) else {
                    warnings.append("wallpaper:\(scopeRaw)")
                    continue
                }
                if !setWallpaperEncoded(data, for: scope) {
                    warnings.append("wallpaper:\(scopeRaw)")
                }
            }
        }
        if replace {
            // Missing key = "this theme has no image for this slot" →
            // delete it. applyCategoryImages treats "" as delete, so
            // feed it a complete map instead of the pack's sparse one.
            // (Merge mode passes the pack map unchanged: missing = leave.)
            var completeMap = pack.categoryImages
            for key in AppearanceThemePack.categoryKeys where completeMap[key] == nil {
                completeMap[key] = ""
            }
            warnings.append(contentsOf: applyCategoryImages(completeMap))
        } else {
            warnings.append(contentsOf: applyCategoryImages(pack.categoryImages))
        }
        configureUIKitSurfaces()
        return warnings
    }

    func exportThemePack(includeWallpaper: Bool) -> AppearanceThemePack {
        var pack = loadStoredPack()
        pack.colorsLight = exportColors(variant: .light)
        pack.colorsDark = exportColors(variant: .dark)
        // [page-state] Page colours always export (they are hex,
        // not images); page wallpapers only when images are asked
        // for, exactly like the global wallpaper below.
        pack.pageColorsLight = exportPageColors(variant: .light)
        pack.pageColorsDark = exportPageColors(variant: .dark)
        pack.surfaceOpacity = surfaceOpacity
        pack.wallpaperShade = wallpaperShade
        // [B28 B-3] 三个字段以前被硬写成 accent 的副本 —— 导出一次，用户
        // 自己设的 thinking 颜色就被抹平，而且导出/应用来回一趟就把「跟 accent
        // 走」永久钉死成当时那个 hex。现在不写：空串就是「跟 accent 走」，
        // 设过的原样带出去。
        // [T-theme-reexport-inflate] Export used to re-encode every image from
        // its decoded UIImage at a fixed quality. A pack that went
        // export → apply → export came back ~3x larger (340B → 1005B, and
        // 964B → 2156B for the wallpaper) and lost detail on every pass, even
        // though apply had stored the bytes verbatim.
        //
        // The file on disk IS the original bytes — `writeEncodedImage` writes
        // them untouched when no downscale is needed — so read those instead
        // of round-tripping through UIImage. The UIImage path stays as the
        // fallback for anything not backed by a file.
        if includeWallpaper, let data = originalImageData(fileName: "wallpaper-\(AppearanceScope.global.rawValue).jpg") {
            pack.wallpaperJPEGBase64 = data.base64EncodedString()
        } else if includeWallpaper, let image = wallpaper(for: .global),
                  let data = image.jpegData(compressionQuality: 0.82) {
            pack.wallpaperJPEGBase64 = data.base64EncodedString()
        } else {
            pack.wallpaperJPEGBase64 = nil
        }
        if includeWallpaper {
            if let data = originalImageData(fileName: "thinking-card.jpg") {
                pack.thinkingCardJPEGBase64 = data.base64EncodedString()
            } else if let image = thinkingCardImage(),
                      let data = image.jpegData(compressionQuality: 0.82) {
                pack.thinkingCardJPEGBase64 = data.base64EncodedString()
            }
        }
        if includeWallpaper {
            if let data = originalImageData(fileName: "input-bar.jpg") {
                pack.inputBarJPEGBase64 = data.base64EncodedString()
            } else if let image = inputBarImage(),
                      let data = image.jpegData(compressionQuality: 0.82) {
                pack.inputBarJPEGBase64 = data.base64EncodedString()
            }
        }
        // [B28 A-1] 立绘跟壁纸同一条路：`includeWallpaper: true` 才带整张图，
        // 平时（`minis-theme get`）字段是 nil，AI 不会吃进几百 KB base64。
        if includeWallpaper, let data = originalImageData(fileName: "character-art.jpg") {
            pack.characterArtBase64 = data.base64EncodedString()
        } else {
            pack.characterArtBase64 = nil
        }
        // [page-state] Page wallpapers, file bytes only: a page
        // with no own file exports nothing for that scope, so it
        // keeps inheriting global on re-apply instead of getting
        // a copy of the global image frozen in as its own. A page
        // explicitly cleared to no background exports "" (see the
        // field comment), so cleared and inherited stay distinct.
        if includeWallpaper {
            var pageWallpapers: [String: String] = [:]
            for scope in AppearanceScope.allCases where scope != .global {
                if wallpaperClearsGlobal(scope) {
                    pageWallpapers[scope.rawValue] = ""
                } else if let data = originalImageData(fileName: "wallpaper-\(scope.rawValue).jpg") {
                    pageWallpapers[scope.rawValue] = data.base64EncodedString()
                }
            }
            pack.pageWallpapers = pageWallpapers
        } else {
            pack.pageWallpapers = nil
        }
        if includeWallpaper {
            var images: [String: String] = [:]
            for key in AppearanceThemePack.categoryKeys {
                // Category icons are rendered tiles, not user files, so the
                // original-bytes path only applies to a real file on disk.
                if let data = originalImageData(fileName: "category-\(key).jpg") {
                    images[key] = data.base64EncodedString()
                } else if let image = categoryImage(for: key),
                          let data = image.jpegData(compressionQuality: 0.86) {
                    images[key] = data.base64EncodedString()
                }
            }
            pack.categoryImages = images
        }
        return pack
    }

    /// Bytes of an image file exactly as stored, or nil when there is no file.
    ///
    /// Deliberately not `UIImage(contentsOfFile:)`: decoding and re-encoding is
    /// what inflated exported packs.
    private func originalImageData(fileName: String) -> Data? {
        let url = appearanceDirectory.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        return data
    }

    /// Snapshot directory for the most recent destructive theme operation.
    ///
    /// `reset` deletes every user image and the whole pack. It used to be a
    /// one-way door, and `minis-theme reset` put that door behind an AI
    /// command. Everything wiped here is first copied aside so `undoReset`
    /// can put it back.
    var themeUndoDirectory: URL {
        // Dot-prefixed on purpose: the backup tree exporter walks this
        // directory with `.skipsHiddenFiles`, so a snapshot never doubles the
        // size of an appearance backup.
        let dir = appearanceDirectory.appendingPathComponent(".undo", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Files a reset would destroy: pack JSON plus every image the pack owns.
    ///
    /// Built in a scratch directory and swapped in at the end, so a capture
    /// that fails halfway cannot leave the previous undo snapshot destroyed
    /// and the new one empty.
    private func captureThemeUndoSnapshot(includeWallpapers: Bool = false) -> URL? {
        let dir = themeUndoDirectory
        let scratch = dir.deletingLastPathComponent()
            .appendingPathComponent(".undo-staging", isDirectory: true)
        try? FileManager.default.removeItem(at: scratch)
        guard (try? FileManager.default.createDirectory(at: scratch,
                                                        withIntermediateDirectories: true)) != nil else {
            return nil
        }
        if let data = UserDefaults.standard.data(forKey: Self.packKey) {
            try? data.write(to: scratch.appendingPathComponent("pack.json"), options: .atomic)
        }
        let overrides: [String: String] = exportColorOverrides()
        if let colors = try? JSONEncoder().encode(overrides) {
            try? colors.write(to: scratch.appendingPathComponent("colors.json"), options: .atomic)
        }
        // [B28 R2-12] resetColors 顺手重置 surface/bubble/shade 三个滑杆，
        // 但快照原来只存 pack.json + colors.json —— 「撤销」救不回这三个值，
        // 撤销条就成了谎言。bubbleOpacity 是独立 UserDefaults 键，尤其容易漏。
        let opacity: [String: Double] = [
            "surface": surfaceOpacity,
            "bubble": bubbleOpacity,
            "shade": wallpaperShade,
        ]
        if let data = try? JSONEncoder().encode(opacity) {
            try? data.write(to: scratch.appendingPathComponent("opacity.json"), options: .atomic)
        }
        for key in AppearanceThemePack.categoryKeys {
            let src = categoryImageURL(key)
            if FileManager.default.fileExists(atPath: src.path) {
                try? FileManager.default.copyItem(at: src, to: scratch.appendingPathComponent("category-\(key).jpg"))
            }
        }
        for (name, src) in [("thinking-card.jpg", thinkingCardURL()),
                            ("input-bar.jpg", inputBarImageURL()),
                            ("character-art.jpg", characterArtURL())] {
            if FileManager.default.fileExists(atPath: src.path) {
                try? FileManager.default.copyItem(at: src, to: scratch.appendingPathComponent(name))
            }
        }
        // Reset snapshots also capture every scope wallpaper plus the
        // cleared-fallback list, so undo can put wallpapers back too.
        // Palette-only snapshots (default) deliberately do not, so an
        // undo of a palette reset cannot wipe live wallpapers.
        if includeWallpapers {
            captureWallpapers(into: scratch)
        }
        // Only replace the live snapshot once the new one is complete.
        guard FileManager.default.fileExists(atPath: scratch.appendingPathComponent("pack.json").path) else {
            try? FileManager.default.removeItem(at: scratch)
            return nil
        }
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.moveItem(at: scratch, to: dir)
        return dir
    }

    /// True when a reset snapshot is on disk and can be restored.
    /// A colours-only snapshot (clear-all page overrides) counts too:
    /// it carries a `colors-only` marker plus `colors.json`, and undo
    /// restores exactly those colours, never a pack.
    var canUndoThemeReset: Bool {
        let dir = themeUndoDirectory
        let hasPack = FileManager.default.fileExists(atPath: dir.appendingPathComponent("pack.json").path)
        let hasColorsOnly = FileManager.default.fileExists(atPath: dir.appendingPathComponent("colors-only").path)
            && FileManager.default.fileExists(atPath: dir.appendingPathComponent("colors.json").path)
        return hasPack || hasColorsOnly
    }

    /// Restores the pack and images captured by the last `resetThemePack`.
    @discardableResult
    func undoThemeReset() -> Bool {
        let dir = themeUndoDirectory
        // [F1] Colours-only snapshot from clear-all page overrides:
        // restore exactly the colour map it captured, and nothing else.
        // In particular, never restore a pack, image, opacity, or
        // wallpaper from an older snapshot — this snapshot replaced it.
        if FileManager.default.fileExists(atPath: dir.appendingPathComponent("colors-only").path) {
            guard let colors = try? Data(contentsOf: dir.appendingPathComponent("colors.json")),
                  let decoded = try? JSONDecoder().decode([String: String].self, from: colors) else {
                return false
            }
            restoreColorOverrides(decoded)
            objectWillChange.send()
            return true
        }
        let packURL = dir.appendingPathComponent("pack.json")
        guard let data = try? Data(contentsOf: packURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let restored = try? AppearanceThemePack.decode(obj) else {
            return false
        }
        UserDefaults.standard.set(data, forKey: Self.packKey)
        themePackLock.lock()
        cachedThemePack = restored
        themePackLoaded = true
        themePackLock.unlock()
        themePackRevision += 1

        if let colors = try? Data(contentsOf: dir.appendingPathComponent("colors.json")),
           let decoded = try? JSONDecoder().decode([String: String].self, from: colors) {
            restoreColorOverrides(decoded)
        }
        // [B28 R2-12] 配套：快照里有 opacity.json 就如实恢复三个滑杆。
        // 旧快照没这个文件时保持现值 —— 不假装恢复到没记录过的状态。
        if let data = try? Data(contentsOf: dir.appendingPathComponent("opacity.json")),
           let op = try? JSONDecoder().decode([String: Double].self, from: data) {
            if let v = op["surface"] { surfaceOpacity = v }
            if let v = op["bubble"] { bubbleOpacity = v }
            if let v = op["shade"] { wallpaperShade = v }
        }
        for key in AppearanceThemePack.categoryKeys {
            let src = dir.appendingPathComponent("category-\(key).jpg")
            if FileManager.default.fileExists(atPath: src.path) {
                let dst = categoryImageURL(key)
                try? FileManager.default.removeItem(at: dst)
                try? FileManager.default.copyItem(at: src, to: dst)
                ThumbnailCache.shared.removeThumbnail(for: dst.path)
            }
        }
        for (name, dst) in [("thinking-card.jpg", thinkingCardURL()),
                            ("input-bar.jpg", inputBarImageURL()),
                            ("character-art.jpg", characterArtURL())] {
            let src = dir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: src.path) {
                try? FileManager.default.removeItem(at: dst)
                try? FileManager.default.copyItem(at: src, to: dst)
                ThumbnailCache.shared.removeThumbnail(for: dst.path)
            }
        }
        // No-op for snapshots without wallpaper-cleared.json (older or
        // palette-only snapshots); reset snapshots restore wallpapers
        // and the cleared-fallback list exactly.
        restoreWallpapers(from: dir)
        objectWillChange.send()
        return true
    }

    /// [B28 R2-1] 「恢复默认色盘」先抓快照再清 —— 和整包重置同一套撤销机制，
    /// 撤销条承诺「撤销上一次恢复」时，色盘重置也要真的能撤。
    func resetPaletteWithUndo() {
        _ = captureThemeUndoSnapshot()
        resetColors()
    }

    /// [F1] Colours-only undo snapshot for clear-all page overrides.
    /// Unlike `captureThemeUndoSnapshot`, this does NOT depend on a
    /// pack JSON existing: it captures exactly the colour map the clear
    /// is about to wipe, so undo works even when no pack exists, and
    /// the snapshot it swaps in can never be a stale pre-reset pack.
    /// Returns false only on a real capture failure (scratch dir or
    /// colour write); the caller must then invalidate the snapshot.
    private func captureColorOnlyUndoSnapshot() -> Bool {
        let dir = themeUndoDirectory
        let scratch = dir.deletingLastPathComponent()
            .appendingPathComponent(".undo-staging", isDirectory: true)
        try? FileManager.default.removeItem(at: scratch)
        guard (try? FileManager.default.createDirectory(at: scratch,
                                                        withIntermediateDirectories: true)) != nil else {
            return false
        }
        let overrides: [String: String] = exportColorOverrides()
        guard let colors = try? JSONEncoder().encode(overrides),
              (try? colors.write(to: scratch.appendingPathComponent("colors.json"), options: .atomic)) != nil,
              (try? "1".write(to: scratch.appendingPathComponent("colors-only"), atomically: true, encoding: .utf8)) != nil else {
            try? FileManager.default.removeItem(at: scratch)
            return false
        }
        // Only replace the live snapshot once the new one is complete.
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.moveItem(at: scratch, to: dir)
        return FileManager.default.fileExists(atPath: dir.appendingPathComponent("colors.json").path)
    }

    /// [P0-4] Clear every non-global colour override, with undo that
    /// restores exactly the overrides this clear wiped. The snapshot is
    /// colours-only (no pack, images, opacity, or wallpapers), so
    /// undoing this clear cannot wipe live wallpapers or resurrect a
    /// pack the user never touched in this round, and it touches
    /// colours only — global palette, wallpapers, library themes,
    /// chats, and backups are untouched.
    /// Returns true when an undo snapshot was captured; on false the
    /// stale snapshot (if any) is invalidated and the caller must show
    /// the no-undo toast instead of promising undo.
    @discardableResult
    func clearNonGlobalColorOverridesWithUndo() -> Bool {
        guard captureColorOnlyUndoSnapshot() else {
            try? FileManager.default.removeItem(at: themeUndoDirectory)
            return false
        }
        clearNonGlobalColorOverrides()
        return true
    }

    /// Resets to the default pack. Returns true when this reset captured
    /// its own undo snapshot; false when no pack JSON existed to snapshot
    /// (the reset still runs, but `minis-theme undo` cannot restore the
    /// theme this reset removed — callers must say so, not promise undo).
    /// The return is discardable for the settings-UI caller, which shows
    /// its own undo button from `canUndoThemeReset`.
    @discardableResult
    func resetThemePack() -> Bool {
        let snapshotCaptured = captureThemeUndoSnapshot(includeWallpapers: true) != nil
        // [F1] A failed capture (no pack JSON on disk) must not leave an
        // older snapshot in place: the bridge reports undoAvailable:false
        // for this reset, the settings undo button reads
        // canUndoThemeReset, and `minis-theme undo` reads the same
        // directory — if the old snapshot survived, all three would
        // disagree with the bridge and undo would restore a theme this
        // reset never captured. Invalidate before proceeding, so no path
        // can restore an older theme after a reset that reported no undo.
        if !snapshotCaptured {
            try? FileManager.default.removeItem(at: themeUndoDirectory)
        }
        // The proper removers persist the live pack (with the image
        // fields nilled), so they must run BEFORE the pack key is
        // removed — after removal they would resurrect the old pack.
        // They also clear the thumbnail caches, so a deleted red
        // thinking-card / input-bar image cannot keep rendering.
        removeThinkingCardImage()
        removeInputBarImage()
        UserDefaults.standard.removeObject(forKey: Self.packKey)
        // [B28 A-1] 立绘也是 pack 里的图，跟 thinking 卡片/输入栏一样回默认。
        // (No dedicated remover exists; file + thumbnail deletion as before.)
        try? FileManager.default.removeItem(at: characterArtURL())
        ThumbnailCache.shared.removeThumbnail(for: characterArtURL().path)
        wipeCategoryImageFiles()
        // A real reset clears every scope wallpaper through the proper
        // path (file + cleared-fallback flag + cache + revision), not
        // just colours and pack fields.
        removeAllScopeWallpapers()
        themePackLock.lock()
        cachedThemePack = .default
        themePackLoaded = true
        themePackLock.unlock()
        themePackRevision += 1
        resetColors()
        objectWillChange.send()
        return snapshotCaptured
    }

    func setBubbleStyle(_ style: AppearanceBubbleStyle, user: Bool) {
        var pack = currentThemePack()
        if user { pack.userBubbleStyle = style.rawValue }
        else { pack.assistantBubbleStyle = style.rawValue }
        // A hand-picked style is a plain shape, not an asymmetric
        // preset: clear it here. BubbleStylePackStore.apply() no
        // longer goes through this setter (it writes the style
        // straight into the theme struct, so a one-side apply
        // cannot clear shared layout); the both-sides apply
        // writes the pack's preset in its final persist, see
        // apply() in AppearanceBubblePacks.swift.
        pack.bubbleCornerPreset = BubbleCornerPreset.even.rawValue
        persistPack(pack)
    }

    func setListIconShape(_ shape: AppearanceListIconShape) {
        var pack = currentThemePack()
        pack.listIconShape = shape.rawValue
        persistPack(pack)
    }

    func setInputBarRadius(_ value: Double) {
        var pack = currentThemePack()
        pack.inputBarRadius = min(32, max(4, value))
        persistPack(pack)
    }

    func setInputBarStyle(_ style: AppearanceBubbleStyle) {
        var pack = currentThemePack()
        pack.inputBarStyle = style.rawValue
        persistPack(pack)
    }

    /// The ONE global family: writing it also clears any
    /// legacy message override, so the message side can never
    /// keep disagreeing with the global choice afterwards.
    func setFontFamily(_ family: AppearanceFontFamily) {
        var pack = currentThemePack()
        pack.fontFamily = family.rawValue
        pack.messageFontFamily = ""
        persistPack(pack)
    }

    /// The ONE global uploaded font (nil = none, family
    /// fallback): written to both legacy per-part fields so
    /// they stay in sync as the single global choice.
    func setGlobalCustomFont(_ postScriptName: String?) {
        var pack = currentThemePack()
        pack.messageCustomFont = postScriptName
        pack.uiCustomFont = postScriptName
        persistPack(pack)
    }

    /// Legacy message-part family setter. Kept so old call
    /// sites still compile; `persistPack` folds the value
    /// into the global family, so it now behaves exactly
    /// like `setFontFamily`.
    func setMessageFontFamily(_ family: AppearanceFontFamily) {
        var pack = currentThemePack()
        pack.messageFontFamily = family.rawValue
        persistPack(pack)
    }

    /// Legacy message-part uploaded font setter. Kept for
    /// compatibility; `persistPack` folds it into the global
    /// uploaded font, so it now behaves like `setGlobalCustomFont`.
    func setMessageCustomFont(_ postScriptName: String?) {
        var pack = currentThemePack()
        pack.messageCustomFont = postScriptName
        persistPack(pack)
    }

    /// Legacy UI-part uploaded font setter. Kept for
    /// compatibility; `persistPack` folds it into the global
    /// uploaded font, so it now behaves like `setGlobalCustomFont`.
    func setUICustomFont(_ postScriptName: String?) {
        var pack = currentThemePack()
        pack.uiCustomFont = postScriptName
        persistPack(pack)
    }

    // MARK: - 第五轮新增的维度

    func setAvatarShape(_ shape: AppearanceAvatarShape) {
        var pack = currentThemePack()
        pack.avatarShape = shape.rawValue
        persistPack(pack)
    }

    func setChatDisplay(_ display: AppearanceChatDisplay) {
        var pack = currentThemePack()
        pack.chatDisplay = display.rawValue
        persistPack(pack)
    }

    // MARK: [10-19 醒醒] 视觉小说模式

    func setNovelMode(_ mode: AppearanceNovelMode) {
        var pack = currentThemePack()
        pack.novelMode = mode.rawValue
        persistPack(pack)
    }

    /// 立绘图。传 nil 清掉。
    ///
    /// [B28 A-1] 立绘以前是唯一一张"图片却当普通字段存"的资源：整张
    /// base64（1600px JPEG，几百 KB）进 pack JSON → UserDefaults → 每次拖
    /// 任何滑杆都重写一遍 → 还进备份。其余三张图早就走"落文件、字段置 nil"。
    ///
    /// 现在立绘也落文件（`character-art.jpg`）。pack 里的字段只作为
    /// 一次性的搬运工存在：apply 时解码落盘，然后立刻置 nil。
    func setCharacterArt(_ base64: String?) {
        var pack = currentThemePack()
        pack.characterArtBase64 = base64
        if let base64, let data = Data(base64Encoded: base64) {
            writeEncodedImage(data, to: characterArtURL(), maxEdge: 1600, quality: 0.82)
            pack.characterArtBase64 = nil
        } else if base64 == nil {
            removeCharacterArt()
            return
        }
        persistPack(pack)
    }

    /// [B28 A-1] 直接从 UIImage 落盘。UI 走这条，不经过 base64。
    func setCharacterArtImage(_ image: UIImage) {
        writeDownscaledJPEG(image, to: characterArtURL(), maxEdge: 1600, quality: 0.82)
        var pack = currentThemePack()
        pack.characterArtBase64 = nil
        persistPack(pack)
    }

    private func characterArtURL() -> URL {
        appearanceDirectory.appendingPathComponent("character-art.jpg")
    }

    /// 立绘原图。没有就返回 nil（渲染层会退回"头像放大"占位）。
    func characterArtImage() -> UIImage? {
        let path = characterArtURL().path
        if let hit = ThumbnailCache.shared.cachedThumbnail(for: path) { return hit }
        guard let image = UIImage(contentsOfFile: path) else { return nil }
        ThumbnailCache.shared.store(image, for: path)
        return image
    }

    /// 有没有立绘。UI 和 CLI 都该看这个，而不是看 pack 字段。
    var hasCharacterArt: Bool {
        FileManager.default.fileExists(atPath: characterArtURL().path)
    }

    func removeCharacterArt() {
        try? FileManager.default.removeItem(at: characterArtURL())
        ThumbnailCache.shared.removeThumbnail(for: characterArtURL().path)
        var pack = currentThemePack()
        pack.characterArtBase64 = nil
        persistPack(pack)
    }

    func setLineHeight(_ value: Double) {
        var pack = currentThemePack()
        pack.lineHeight = min(2.2, max(0.9, value))
        persistPack(pack)
    }

    func setLetterSpacing(_ value: Double) {
        var pack = currentThemePack()
        pack.letterSpacing = min(3, max(-1, value))
        persistPack(pack)
    }

    // MARK: [10-20 醒醒] 代码块

    func setCodeBlockCollapseLines(_ lines: Int) {
        var pack = currentThemePack()
        pack.codeBlockCollapseLines = min(40, max(4, lines))
        persistPack(pack)
        NotificationCenter.default.post(name: .codeBlockLayoutSettingsChanged, object: nil)
    }

    func setRowBackground(_ hex: String?) {
        var pack = currentThemePack()
        pack.rowBackgroundHex = hex.map { $0.uppercased() }
        persistPack(pack)
    }

    /// 一次把 ST 主题包解析出来的东西全应用上。
    /// 颜色走 `applyThemePack`，几何走这里。
    func applySillyTavern(_ imported: SillyTavernTheme.Imported) {
        // ST 字号只在包里明确写了 font_scale 时才动：默认 13 × 缩放，
        // 四舍五入后夹在 10–15；包里没写就一字不动，绝不把缺省当成“要 13”。
        if let scale = imported.fontScale {
            FontSettings.shared.messagePointSize = CGFloat(min(15, max(10, (13 * scale).rounded())))
        }
        var pack = currentThemePack()
        pack.name = imported.name
        pack.avatarShape = imported.avatarShape.rawValue
        pack.chatDisplay = imported.chatDisplay.rawValue
        // [10-19 醒醒] waifuMode → 立绘模式
        pack.novelMode = imported.novelMode.rawValue
        if let lh = imported.lineHeight { pack.lineHeight = min(2.2, max(0.9, lh)) }
        if let ls = imported.letterSpacing { pack.letterSpacing = min(3, max(-1, ls)) }
        if let r = imported.bubbleRadius {
            // ST 的 border-radius 是 px，我们的圆角是 pt，比例大致 1:1
            pack.userBubbleRadius = min(32, max(0, r))
            pack.assistantBubbleRadius = min(32, max(0, r))
            pack.inputBarRadius = min(32, max(4, r))
        }
        persistPack(pack)

        // 颜色走 `setColor` —— 真正生效的是 `customColors`，不是 pack 里的
        // `colorsLight`/`colorsDark` 那两张表（那两张是导出用的快照）。
        // 上一版写错了地方，导入完颜色不变，这里修正。
        //
        // [10-18 醒醒 第五轮] 导入时**也过一遍对比度**。
        // 实测她那六个真实包里，有三个的文字对比度不够：
        //   小猫文件夹 4.12、给你的信 3.01、面包狗 3.22，都低于 WCAG 的 4.5。
        // ST 是网页，作者用 CSS 调位置和装饰，文字偏淡是常态。我们不照抄
        // 看不清的组合——推到达标为止，色相不变只动明度。
        for (role, hex) in imported.light {
            setColor(Color(hex: hex), role: role, scope: .global, variant: .light)
        }
        for (role, hex) in imported.dark {
            setColor(Color(hex: hex), role: role, scope: .global, variant: .dark)
        }

        for variant in [AppearanceVariant.light, .dark] {
            let bgRole = AppearanceColorRole.canvas
            let bg = hex(bgRole, scope: .global, variant: variant)
            let surface = hex(.surface, scope: .global, variant: variant)
            for role in [AppearanceColorRole.primaryText, .secondaryText] {
                var fg = hex(role, scope: .global, variant: variant)
                fg = AppearanceContrast.enforce(fg, on: bg, level: .body)
                fg = AppearanceContrast.enforce(fg, on: surface, level: .body)
                if fg != hex(role, scope: .global, variant: variant) {
                    setColor(Color(hex: fg), role: role, scope: .global, variant: variant)
                }
            }
            // [contrast-20261102] Accent used to be written verbatim, so
            // an ST pack could import an accent nobody can read. Enforce
            // it the same way, but at the accent bar (3.0, level .ui) —
            // never 4.5, which would push the accent further than its
            // own rule allows. Hue is preserved, only lightness moves.
            var accent = hex(.accent, scope: .global, variant: variant)
            accent = AppearanceContrast.enforce(accent, on: bg, level: .ui)
            accent = AppearanceContrast.enforce(accent, on: surface, level: .ui)
            if accent != hex(.accent, scope: .global, variant: variant) {
                setColor(Color(hex: accent), role: .accent, scope: .global, variant: variant)
            }
        }
    }

    func setThinkingFont(title: Double? = nil, body: Double? = nil) {
        var pack = currentThemePack()
        if let title { pack.thinkingTitleSize = min(22, max(10, title)) }
        if let body { pack.thinkingBodySize = min(22, max(10, body)) }
        persistPack(pack)
    }

    func setCategorySymbol(_ symbol: String, for key: String) {
        guard AppearanceThemePack.categoryKeys.contains(key) else { return }
        var pack = currentThemePack()
        let trimmed = symbol.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            pack.categoryIcons.removeValue(forKey: key)
        } else {
            pack.categoryIcons[key] = trimmed
        }
        persistPack(pack)
    }

    func setCategoryColor(_ color: Color, for key: String) {
        guard AppearanceThemePack.categoryKeys.contains(key) else { return }
        var pack = currentThemePack()
        pack.categoryColors[key] = UIColor(color).hexRGB
        persistPack(pack)
    }

    func clearCategoryChrome(for key: String) {
        guard AppearanceThemePack.categoryKeys.contains(key) else { return }
        var pack = currentThemePack()
        pack.categoryIcons.removeValue(forKey: key)
        pack.categoryColors.removeValue(forKey: key)
        persistPack(pack)
    }

    private func categoryImageURL(_ key: String) -> URL {
        appearanceDirectory.appendingPathComponent("category-\(key).jpg")
    }

    func categoryImage(for key: String) -> UIImage? {
        // [PIC-1] Memory-cached read; the key already embeds size+mtime,
        // so replacing the file invalidates without an explicit clear —
        // the explicit clear in setCategoryImage covers the same-tick
        // re-read before the filesystem settles.
        let path = categoryImageURL(key).path
        if let hit = ThumbnailCache.shared.cachedThumbnail(for: path) { return hit }
        guard let image = UIImage(contentsOfFile: path) else { return nil }
        ThumbnailCache.shared.store(image, for: path)
        return image
    }

    @discardableResult
    func setCategoryImage(_ image: UIImage, for key: String) -> Bool {
        guard AppearanceThemePack.categoryKeys.contains(key) else { return false }
        guard writeDownscaledJPEG(image, to: categoryImageURL(key), maxEdge: 256, quality: 0.86) else {
            return false
        }
        var pack = currentThemePack()
        pack.categoryImages[key] = "file"
        persistPack(pack)
        return true
    }

    func removeCategoryImage(for key: String) {
        try? FileManager.default.removeItem(at: categoryImageURL(key))
        var pack = currentThemePack()
        pack.categoryImages.removeValue(forKey: key)
        persistPack(pack)
    }

    private func wipeCategoryImageFiles() {
        for key in AppearanceThemePack.categoryKeys {
            try? FileManager.default.removeItem(at: categoryImageURL(key))
        }
    }

    /// Applies the pack's category-image map.
    ///
    /// Missing key = "not mentioned" → leave the file and its marker alone.
    /// This used to treat a missing key as a delete request, so any partial
    /// pack (an AI call carrying colors only, a legacy JSON without the map)
    /// wiped every user-supplied category image. Explicit removal has to say
    /// so: an empty string for that key.
    /// Returns the category keys whose payload was undecodable and
    /// whose old image was therefore kept, matching the other slots'
    /// warning behaviour in applyThemePack.
    private func applyCategoryImages(_ map: [String: String]) -> [String] {
        var warnings: [String] = []
        var pack = currentThemePack()
        for key in AppearanceThemePack.categoryKeys {
            guard let value = map[key] else { continue }
            if value.isEmpty {
                try? FileManager.default.removeItem(at: categoryImageURL(key))
                ThumbnailCache.shared.removeThumbnail(for: categoryImageURL(key).path)
                pack.categoryImages.removeValue(forKey: key)
                continue
            }
            if value == "file" {
                if FileManager.default.fileExists(atPath: categoryImageURL(key).path) {
                    pack.categoryImages[key] = "file"
                } else {
                    pack.categoryImages.removeValue(forKey: key)
                }
                continue
            }
            guard let data = Data(base64Encoded: value), UIImage(data: data) != nil else {
                // Undecodable payload: keep whatever is already on disk
                // rather than silently dropping the user's image, but
                // say so — the caller reports this key as a warning.
                warnings.append(key)
                continue
            }
            writeEncodedImage(data, to: categoryImageURL(key), maxEdge: 256, quality: 0.86)
            pack.categoryImages[key] = "file"
        }
        persistPack(pack)
        return warnings
    }

    /// Writes a downscaled JPEG and drops the cached thumbnail for that path.
    @discardableResult
    private func writeDownscaledJPEG(_ image: UIImage, to url: URL,
                                    maxEdge: CGFloat, quality: CGFloat) -> Bool {
        let size = image.size
        let scale = min(1, maxEdge / max(size.width, size.height, 1))
        let target = CGSize(width: max(1, size.width * scale), height: max(1, size.height * scale))
        let format = UIGraphicsImageRendererFormat()
        format.opaque = true
        format.scale = 1
        let rendered = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        // [B28 R2-2] 编码失败 / 写盘失败以前全是静默的。现在如实上抛。
        guard let data = rendered.jpegData(compressionQuality: quality) else {
            appearanceLog.warning("jpeg encode failed for \(url.lastPathComponent)")
            return false
        }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            appearanceLog.warning("image write failed \(url.lastPathComponent): \(error.localizedDescription)")
            return false
        }
        ThumbnailCache.shared.removeThumbnail(for: url.path)
        return true
    }

    /// Stores an image payload that already arrived as encoded bytes.
    ///
    /// Round-tripping through UIImage and re-encoding a second time cost
    /// roughly 3x the bytes and a visible generation loss on every apply.
    /// The bytes are only re-encoded when they exceed the target edge, which
    /// is the one case where re-encoding actually buys something.
    @discardableResult
    private func writeEncodedImage(_ data: Data, to url: URL,
                                   maxEdge: CGFloat, quality: CGFloat) -> Bool {
        if let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 {
            let longest = max(image.size.width, image.size.height)
            if longest > maxEdge {
                return writeDownscaledJPEG(image, to: url, maxEdge: maxEdge, quality: quality)
            }
        }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            appearanceLog.warning("image write failed \(url.lastPathComponent): \(error.localizedDescription)")
            return false
        }
        ThumbnailCache.shared.removeThumbnail(for: url.path)
        return true
    }

    private func thinkingCardURL() -> URL {
        appearanceDirectory.appendingPathComponent("thinking-card.jpg")
    }

    func thinkingCardImage() -> UIImage? {
        // [PIC-1] Same cached-read pattern as categoryImage above.
        let path = thinkingCardURL().path
        if let hit = ThumbnailCache.shared.cachedThumbnail(for: path) { return hit }
        guard let image = UIImage(contentsOfFile: path) else { return nil }
        ThumbnailCache.shared.store(image, for: path)
        return image
    }

    func hasThinkingCardImage() -> Bool {
        FileManager.default.fileExists(atPath: thinkingCardURL().path)
    }

    @discardableResult
    func setThinkingCardImage(_ image: UIImage) -> Bool {
        guard writeDownscaledJPEG(image, to: thinkingCardURL(), maxEdge: 1400, quality: 0.82) else { return false }
        var pack = currentThemePack()
        pack.thinkingCardJPEGBase64 = nil
        persistPack(pack)
        return true
    }

    /// Stores an already-encoded thinking-card image without a re-encode round trip.
    @discardableResult
    func setThinkingCardImageEncoded(_ data: Data) -> Bool {
        guard writeEncodedImage(data, to: thinkingCardURL(), maxEdge: 1400, quality: 0.82) else { return false }
        var pack = currentThemePack()
        pack.thinkingCardJPEGBase64 = nil
        persistPack(pack)
        return true
    }

    func removeThinkingCardImage() {
        try? FileManager.default.removeItem(at: thinkingCardURL())
        ThumbnailCache.shared.removeThumbnail(for: thinkingCardURL().path)
        var pack = currentThemePack()
        pack.thinkingCardJPEGBase64 = nil
        persistPack(pack)
    }

    func setThinkingCardImageOpacity(_ value: Double) {
        var pack = currentThemePack()
        pack.thinkingCardImageOpacity = min(1, max(0.05, value))
        persistPack(pack)
    }

    private func inputBarImageURL() -> URL {
        appearanceDirectory.appendingPathComponent("input-bar.jpg")
    }

    func inputBarImage() -> UIImage? {
        // [PIC-1] Same cached-read pattern as categoryImage above.
        let path = inputBarImageURL().path
        if let hit = ThumbnailCache.shared.cachedThumbnail(for: path) { return hit }
        guard let image = UIImage(contentsOfFile: path) else { return nil }
        ThumbnailCache.shared.store(image, for: path)
        return image
    }

    func hasInputBarImage() -> Bool {
        FileManager.default.fileExists(atPath: inputBarImageURL().path)
    }

    @discardableResult
    func setInputBarImage(_ image: UIImage) -> Bool {
        guard writeDownscaledJPEG(image, to: inputBarImageURL(), maxEdge: 1400, quality: 0.82) else { return false }
        var pack = currentThemePack()
        pack.inputBarJPEGBase64 = nil
        persistPack(pack)
        return true
    }

    /// Stores an already-encoded input-bar image without a re-encode round trip.
    @discardableResult
    func setInputBarImageEncoded(_ data: Data) -> Bool {
        guard writeEncodedImage(data, to: inputBarImageURL(), maxEdge: 1400, quality: 0.82) else { return false }
        var pack = currentThemePack()
        pack.inputBarJPEGBase64 = nil
        persistPack(pack)
        return true
    }

    func removeInputBarImage() {
        try? FileManager.default.removeItem(at: inputBarImageURL())
        ThumbnailCache.shared.removeThumbnail(for: inputBarImageURL().path)
        var pack = currentThemePack()
        pack.inputBarJPEGBase64 = nil
        persistPack(pack)
    }

    func setInputBarImageOpacity(_ value: Double) {
        var pack = currentThemePack()
        pack.inputBarImageOpacity = min(1, max(0.05, value))
        persistPack(pack)
    }

    fileprivate func applyPackColors(light: [String: String], dark: [String: String]) {
        func paint(_ map: [String: String], variant: AppearanceVariant) {
            for (raw, hex) in map {
                guard let role = AppearanceColorRole(rawValue: raw) else { continue }
                setColor(Color(hex: hex), role: role, scope: .global, variant: variant)
            }
        }
        paint(light, variant: .light)
        paint(dark, variant: .dark)
    }

    /// [page-state] Paints one variant of a pack's page colours.
    /// Only scopes listed in the map change; setColor silently
    /// ignores wallpaper-only scopes, so a stray bottomBar or
    /// terminal entry can never write an unreadable key.
    fileprivate func applyPageColors(_ map: [String: [String: String]], variant: AppearanceVariant) {
        for (scopeRaw, roles) in map {
            guard let scope = AppearanceScope(rawValue: scopeRaw),
                  scope != .global else { continue }
            for (raw, hex) in roles {
                guard let role = AppearanceColorRole(rawValue: raw) else { continue }
                setColor(Color(hex: hex), role: role, scope: scope, variant: variant)
            }
        }
    }

    fileprivate func exportColors(variant: AppearanceVariant) -> [String: String] {
        var out: [String: String] = [:]
        for role in AppearanceColorRole.allCases {
            // [fixer-F2] Bubble text slots follow primaryText when unset.
            // Exporting their resolved hex would freeze them into explicit
            // overrides on import, killing the follow behaviour. Skip an
            // unset slot; a set slot still exports like any other role.
            if (role == .bubbleText || role == .assistantBubbleText),
               !hasOverride(role, scope: .global, variant: variant) {
                continue
            }
            out[role.rawValue] = hex(role, scope: .global, variant: variant)
        }
        return out
    }

    /// [page-state] Page-scope colour overrides actually set, keyed
    /// by scope raw value then role raw value. Only keys present
    /// in the raw override map are exported — resolving through
    /// hex() would freeze every unset role to its current
    /// inherited value and turn "this page follows global" into
    /// a pinned value on re-apply. Legacy page keys migrate to
    /// the new role name (input/searchField -> field, toolCard ->
    /// surface), with the new key winning when both exist.
    /// Wallpaper-only scopes carry no colours and are skipped;
    /// a scope with no overrides is omitted from the map.
    fileprivate func exportPageColors(variant: AppearanceVariant) -> [String: [String: String]] {
        let raw = exportColorOverrides()
        var out: [String: [String: String]] = [:]
        for scope in AppearanceScope.allCases where scope != .global && scope.supportsColour {
            let prefix = "\(scope.rawValue).\(variant.rawValue)."
            var roles: [String: String] = [:]
            for (key, value) in raw where key.hasPrefix(prefix) {
                let roleRaw = String(key.dropFirst(prefix.count))
                if AppearanceColorRole(rawValue: roleRaw) != nil {
                    roles[roleRaw] = normalizeHex(value)
                }
            }
            // Legacy keys, only when the new role is not set.
            if roles[AppearanceColorRole.field.rawValue] == nil {
                if let v = raw[prefix + "input"] ?? raw[prefix + "searchField"] {
                    roles[AppearanceColorRole.field.rawValue] = normalizeHex(v)
                }
            }
            if roles[AppearanceColorRole.surface.rawValue] == nil {
                if let v = raw[prefix + "toolCard"] {
                    roles[AppearanceColorRole.surface.rawValue] = normalizeHex(v)
                }
            }
            if !roles.isEmpty { out[scope.rawValue] = roles }
        }
        return out
    }
}

@MainActor
enum MinisThemeShape {
    static var pack: AppearanceThemePack { AppearanceStudio.shared.loadStoredPack() }
    static var userBubbleRadius: CGFloat { pack.radius(.userBubble) }
    static var assistantBubbleRadius: CGFloat { pack.radius(.assistantBubble) }
    static var thinkingRadius: CGFloat { pack.radius(.thinking) }

    // MARK: - [T-41] Font-linked visual tokens (stage-4 subset)
    //
    // These four shapes are the ones the plan calls out as "must move with the
    // font": a container built around scaled text that keeps a fixed corner or
    // a fixed line height looks wrong as soon as the dial leaves the default.
    // Every token below is an identity at the 13pt default (the number is the
    // design value) and rides the same density factor the settings pages use,
    // so a control around scaled text stays proportional. The remaining bare
    // literals across the app (the ~250 corner sites, the scattered shadow and
    // spacing numbers) stay for the stage-8 sweep — this is only the subset the
    // font work needs.
    static var cardRadius: CGFloat { FontSettings.shared.density(16) }
    static var buttonRadius: CGFloat { FontSettings.shared.density(12) }
    static var capsuleRadius: CGFloat { FontSettings.shared.density(12) }
    /// Input-bar corner keeps its own pack field, but follows the dial too.
    static var inputRadius: CGFloat { FontSettings.shared.density(inputBarRadius) }

    /// [T-41] Proportional line height: the font size × 1.4 plus a fixed
    /// leading, so a computed height follows the dial instead of drifting out
    /// from under the text it wraps.
    static func lineHeight(_ size: CGFloat, fixedLeading: CGFloat = 3) -> CGFloat {
        FontSettings.shared.scaledApp(size) * 1.4 + fixedLeading
    }

    /// [T-41] Scale a design-time `.lineSpacing` value by the same factor the
    /// font above it scales by, so leading stays in proportion instead of
    /// staying fixed while the glyphs grow. `anchor` is the unscaled literal
    /// the font was built with; at the 13pt default the result is `design`.
    static func lineSpacing(_ design: CGFloat, anchor: CGFloat) -> CGFloat {
        guard anchor > 0 else { return design }
        return design * (FontSettings.shared.scaledApp(anchor) / anchor)
    }

    /// [B28 B-3] 三个 thinking 颜色字段原来写了不生效：`MinisThemeShape`
    /// 直接取 `AppearanceStudio.color(.accent, scope: .chat)`，而 pack 里的
    /// `thinkingFillHex / thinkingStrokeHex / thinkingAccentHex` 只有序列化，
    /// 零读取。导出还把三个都硬写成 accent，AI 写这三个字段会以为生效了。
    ///
    /// 现在真读。空串回落到 accent —— 老 pack 里这三个字段是 accent 的副本，
    /// 行为不变；`resetThemePack` 清掉 defaults 后 `.default` 带的是暖色值，
    /// 也和内置配色对得上。
    static var thinkingFill: Color {
        let hex = pack.thinkingFillHex
        guard !hex.isEmpty else {
            return AppearanceStudio.shared.color(.accent, scope: .chat).opacity(0.06)
        }
        return Color(hex: hex).opacity(0.06)
    }
    static var thinkingStroke: Color {
        let hex = pack.thinkingStrokeHex
        guard !hex.isEmpty else {
            return AppearanceStudio.shared.color(.accent, scope: .chat).opacity(0.15)
        }
        return Color(hex: hex).opacity(0.15)
    }
    static var thinkingAccent: Color {
        let hex = pack.thinkingAccentHex
        guard !hex.isEmpty else {
            return AppearanceStudio.shared.color(.accent, scope: .chat)
        }
        return Color(hex: hex)
    }
    static var userStyle: AppearanceBubbleStyle { pack.userStyle }
    static var assistantStyle: AppearanceBubbleStyle { pack.assistantStyle }
    // [bubble-packs] Live accessors for the pack structure fields.
    // All read the current theme pack, so a pack tap (which persists
    // the pack and bumps themePackRevision) re-renders live chat.
    static var userSurface: BubbleSurface { BubbleSurface.parse(pack.userBubbleSurface) }
    static var assistantSurface: BubbleSurface { BubbleSurface.parse(pack.assistantBubbleSurface) }
    static var userBorderWidth: CGFloat { CGFloat(min(2, max(0, pack.userBubbleBorderWidth))) }
    static var assistantBorderWidth: CGFloat { CGFloat(min(2, max(0, pack.assistantBubbleBorderWidth))) }
    static var userPadding: CGFloat { CGFloat(min(20, max(8, pack.userBubblePadding))) }
    static var assistantPadding: CGFloat { CGFloat(min(20, max(8, pack.assistantBubblePadding))) }
    static var avatarSize: CGFloat { CGFloat(min(64, max(28, pack.avatarSize))) }
    static var avatarBorderWidth: CGFloat { CGFloat(min(3, max(0, pack.avatarBorderWidth))) }
    static var avatarPlacement: BubbleAvatarPlacement { BubbleAvatarPlacement.parse(pack.avatarPlacement) }
    static var userMeta: BubbleMetaPosition { BubbleMetaPosition.parse(pack.userMetaPosition) }
    static var assistantMeta: BubbleMetaPosition { BubbleMetaPosition.parse(pack.assistantMetaPosition) }
    static var userName: BubbleNamePlacement { BubbleNamePlacement.parse(pack.userNamePlacement) }
    static var assistantName: BubbleNamePlacement { BubbleNamePlacement.parse(pack.assistantNamePlacement) }
    static var messageSpacing: CGFloat { CGFloat(min(24, max(4, pack.messageSpacing))) }
    /// Asymmetric corner radii for one role, or nil when the preset
    /// is not asymmetric / the style is not a plain rounded shape
    /// (pill, sharp and tail draw their own corners, exactly as the
    /// sample shape does).
    static func cornerRadii(user: Bool) -> RectangleCornerRadii? {
        guard BubbleCornerPreset.parse(pack.bubbleCornerPreset) == .asymmetric else { return nil }
        let style = user ? pack.userStyle : pack.assistantStyle
        guard style == .rounded || style == .squircle else { return nil }
        let radius = CGFloat(user ? pack.userBubbleRadius : pack.assistantBubbleRadius)
        let r = min(max(radius, 4), 32)
        // Outer corner = the side the bubble sits on: user = trailing
        // bottom, assistant = leading bottom. Matches BubblePackSampleShape.
        if user {
            return RectangleCornerRadii(topLeading: r, bottomLeading: r, bottomTrailing: 4, topTrailing: r)
        }
        return RectangleCornerRadii(topLeading: r, bottomLeading: 4, bottomTrailing: r, topTrailing: r)
    }
    static var thinkingCardOpacity: Double { pack.thinkingCardImageOpacity }
    static var inputBarStyle: AppearanceBubbleStyle { AppearanceBubbleStyle.parse(pack.inputBarStyle) }
    static var inputBarImageOpacity: Double { pack.inputBarImageOpacity }
    static var fontFamily: AppearanceFontFamily { AppearanceFontFamily.parse(pack.fontFamily) }

    /// ONE global family: the legacy message override wins
    /// when a stored pack still carries one (storage healing
    /// folds it into `fontFamily` on load / persist, so this
    /// and `fontFamily` agree for every pack the app wrote).
    static var globalFontFamily: AppearanceFontFamily {
        pack.messageFontFamily.isEmpty ? fontFamily : AppearanceFontFamily.parse(pack.messageFontFamily)
    }

    /// Legacy alias for `globalFontFamily`, kept so old call
    /// sites still compile.
    static var messageFontFamily: AppearanceFontFamily { globalFontFamily }

    /// ONE global uploaded font: the message side wins when
    /// set, otherwise the UI side's — so a pack stored before
    /// unification still renders one font everywhere, and
    /// storage healing then writes that winner to both fields.
    static var globalCustomFontName: String? {
        if let name = pack.messageCustomFont, !name.isEmpty { return name }
        guard let name = pack.uiCustomFont, !name.isEmpty else { return nil }
        return name
    }

    /// Message-part font, now the global font: an uploaded
    /// font wins when its postScript name resolves on this
    /// device; otherwise the global family. Weight is honoured
    /// for family fonts; for an uploaded font the file's own
    /// weight is used (UIFont(name:) carries no weight
    /// parameter).
    static func messageFont(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        if let name = globalCustomFontName,
           let uiFont = UIFont(name: name, size: size) {
            return Font(uiFont)
        }
        return globalFontFamily.font(size: size, weight: weight)
    }

    /// Legacy alias for `globalCustomFontName`, kept so old
    /// call sites still compile.
    static var uiCustomFontName: String? { globalCustomFontName }

    /// Live pack shape for ONE side, from that side's theme
    /// field the shop's per-side apply() writes (parse falls
    /// back to porcelain, so an old theme pack without the field
    /// draws the plain pill exactly as before; porcelain itself
    /// falls through to the existing style/corner logic in
    /// MinisBubbleShape.path). There is deliberately no single
    /// packKind anymore: a caller that draws a side's bubble
    /// must say which side, or the two sides could never differ.
    static func packKind(user: Bool) -> BubblePackKind {
        BubblePackKind.parse(user ? pack.userBubblePackShape : pack.assistantBubblePackShape)
    }
    /// Foundation accessors, per side: nil / none / [] / nil on
    /// today's packs, so every live surface below renders exactly
    /// as before until a pack actually sets a field for that side.
    static func packBackgroundImageFile(user: Bool) -> String? {
        user ? pack.userBubbleBackgroundImageFile : pack.assistantBubbleBackgroundImageFile
    }
    static func packPattern(user: Bool) -> BubblePattern {
        BubblePattern.parse(user ? pack.userBubblePattern : pack.assistantBubblePattern)
    }
    static func packPatternOpacity(user: Bool) -> Double {
        min(0.6, max(0, user ? pack.userBubblePatternOpacity : pack.assistantBubblePatternOpacity))
    }
    static func packDecorations(user: Bool) -> [BubbleDecoration] {
        BubbleStyleRecord.decodeDecorations(user ? pack.userBubbleDecorationsJSON : pack.assistantBubbleDecorationsJSON)
    }
    static func packTextColor(user: Bool) -> Color? {
        let hex = user ? pack.userBubblePackTextHex : pack.assistantBubblePackTextHex
        guard let hex else { return nil }
        return Color(hex: hex)
    }
    static var userBubble: MinisBubbleShape {
        MinisBubbleShape(style: userStyle, radius: userBubbleRadius, tailOnTrailing: true,
                         cornerRadii: cornerRadii(user: true), packKind: packKind(user: true))
    }
    static var assistantBubble: MinisBubbleShape {
        MinisBubbleShape(style: assistantStyle, radius: assistantBubbleRadius, tailOnTrailing: false,
                         cornerRadii: cornerRadii(user: false), packKind: packKind(user: false))
    }
    static var thinkingCard: MinisBubbleShape {
        MinisBubbleShape(style: .squircle, radius: thinkingRadius, tailOnTrailing: false)
    }
    static var inputBar: MinisBubbleShape {
        MinisBubbleShape(style: inputBarStyle, radius: inputBarRadius, tailOnTrailing: false)
    }
    /// [T-14] Pack value is a *base*, not the final size: the global dial
    /// scales it (13pt dial = the pack value itself, exactly as the rest of
    /// the app is anchored). Before this the thinking card was the one place
    /// the dial did nothing at all, with no user-facing note saying so.
    static var thinkingTitleSize: CGFloat {
        FontSettings.shared.scaledApp(CGFloat(min(22, max(10, pack.thinkingTitleSize))))
    }
    static var thinkingBodySize: CGFloat {
        FontSettings.shared.scaledApp(CGFloat(min(22, max(10, pack.thinkingBodySize))))
    }
    static var inputBarRadius: CGFloat {
        CGFloat(min(32, max(4, pack.inputBarRadius)))
    }
}

@MainActor
enum MinisThemeList {
    static var pack: AppearanceThemePack { AppearanceStudio.shared.loadStoredPack() }

    static var title: Color { AppearanceStudio.shared.color(.primaryText, scope: .home) }
    static var subtitle: Color { AppearanceStudio.shared.color(.secondaryText, scope: .home) }
    static var meta: Color { AppearanceStudio.shared.color(.secondaryText, scope: .home).opacity(0.72) }
    static var accent: Color { AppearanceStudio.shared.color(.accent, scope: .home) }
    static var rowFill: Color {
        if let hex = pack.listRowFillHex {
            return Color(hex: hex).opacity(AppearanceStudio.shared.surfaceOpacity)
        }
        return AppearanceStudio.shared.color(.surface, scope: .home)
            .opacity(AppearanceStudio.shared.surfaceOpacity)
    }
    static var iconShape: AppearanceListIconShape {
        AppearanceListIconShape.parse(pack.listIconShape)
    }

    static func categoryIcon(for category: String?) -> (systemName: String, color: Color) {
        // [batch8d / W1B2-06] Category colors retired app-wide: the glyph name
        // still resolves per category, but the color is the theme accent now —
        // imported or legacy `categoryColors` no longer reach rendering.
        let fallback = sessionCategoryIconBuiltin(for: category)
        let key = category ?? "other"
        let name = pack.categoryIcons[key] ?? fallback.systemName
        return (name, accent)
    }
}
