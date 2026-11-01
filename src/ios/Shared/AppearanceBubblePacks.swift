import Foundation
import SwiftUI

// MARK: - Bubble style packs, step 1 (record + catalogue + grid + tap-apply)
//
// A pack is STRUCTURE only. It never carries a colour, a wallpaper, a
// remote image, or CSS — colours and wallpapers stay in the theme pack,
// so a pack composes with any theme and can never overwrite a user's
// colours when applied. Border "colour" is deliberately NOT a pack
// field: the pack sets border width/presence only, and the border
// colour keeps coming from the theme's `.border` role.
//
// Live chat wiring (fixer, step 1 review): apply() writes the FULL
// structural record to the live theme pack — display, both bubble
// styles, both radii, both surfaces, both border widths, both
// paddings, avatar size/border, message spacing, meta and name
// placement, corner preset, input-bar style and radius — and the
// chat rows read those fields (see MinisThemeShape). It never
// touches colours, opacity, text slots, wallpapers, avatar shape,
// or the theme library. Two honest exceptions, both visible in the
// samples too: assistant avatar placement stays inline (the AI
// header is a separate list cell and cannot overlap a bubble cell),
// and assistant name above/inline both render as the header name
// (the name cannot move into a bubble row in the split-cell list).
// Assistant meta below renders under the last text block; a
// tool-only turn has no text block, so it shows no meta line.

/// Bubble border chrome, shared by user and assistant bubbles.
/// Width 0 = no-op, so the default (no border) rendering is
/// identical to before: no clip, no stroke added.
struct BubbleBorderChrome: ViewModifier {
    let shape: MinisBubbleShape
    let width: CGFloat

    func body(content: Content) -> some View {
        if width > 0 {
            content
                .clipShape(shape)
                .overlay(shape.stroke(AppearanceStudio.shared.color(.border, scope: .chat),
                                      lineWidth: width))
        } else {
            content
        }
    }
}

/// Row-bubble = the bubble spans the message row; text-bubble = the
/// bubble hugs the text only.
enum BubbleSurface: String, CaseIterable, Codable {
    case row, text
    var title: String {
        switch self {
        case .row: return AppLocalized("整行气泡")
        case .text: return AppLocalized("文字气泡")
        }
    }
    static func parse(_ raw: String?) -> BubbleSurface {
        guard let raw, let value = BubbleSurface(rawValue: raw) else { return .row }
        return value
    }
}

/// Corner treatment. `asymmetric` = one outer corner near-sharp, the
/// rest rounded — the QQ/ST "tail direction" read, without a tail.
enum BubbleCornerPreset: String, CaseIterable, Codable {
    case even, asymmetric, pill, sharp
    var title: String {
        switch self {
        case .even: return AppLocalized("均匀圆角")
        case .asymmetric: return AppLocalized("不对称圆角")
        case .pill: return AppLocalized("胶囊")
        case .sharp: return AppLocalized("方一点")
        }
    }
    static func parse(_ raw: String?) -> BubbleCornerPreset {
        guard let raw, let value = BubbleCornerPreset(rawValue: raw) else { return .even }
        return value
    }
}

/// Where the avatar sits relative to the bubble.
enum BubbleAvatarPlacement: String, CaseIterable, Codable {
    case inline, overlapping
    var title: String {
        switch self {
        case .inline: return AppLocalized("行内头像")
        case .overlapping: return AppLocalized("压在气泡上")
        }
    }
    static func parse(_ raw: String?) -> BubbleAvatarPlacement {
        guard let raw, let value = BubbleAvatarPlacement(rawValue: raw) else { return .inline }
        return value
    }
}

/// Time/meta line placement for one role.
enum BubbleMetaPosition: String, CaseIterable, Codable {
    case hidden, above, below
    var title: String {
        switch self {
        case .hidden: return AppLocalized("不显示时间")
        case .above: return AppLocalized("时间在上")
        case .below: return AppLocalized("时间在下")
        }
    }
    static func parse(_ raw: String?) -> BubbleMetaPosition {
        guard let raw, let value = BubbleMetaPosition(rawValue: raw) else { return .below }
        return value
    }
}

/// Name row placement for one role.
enum BubbleNamePlacement: String, CaseIterable, Codable {
    case hidden, above, inline
    var title: String {
        switch self {
        case .hidden: return AppLocalized("不显示名字")
        case .above: return AppLocalized("名字在上")
        case .inline: return AppLocalized("名字在行内")
        }
    }
    static func parse(_ raw: String?) -> BubbleNamePlacement {
        guard let raw, let value = BubbleNamePlacement(rawValue: raw) else { return .above }
        return value
    }
}

/// Input-bar form. `flat` = minimal radius, no pill rounding.
enum BubbleInputBarForm: String, CaseIterable, Codable {
    case pill, rounded, flat
    var title: String {
        switch self {
        case .pill: return AppLocalized("胶囊输入栏")
        case .rounded: return AppLocalized("圆角输入栏")
        case .flat: return AppLocalized("平直输入栏")
        }
    }
    static func parse(_ raw: String?) -> BubbleInputBarForm {
        guard let raw, let value = BubbleInputBarForm(rawValue: raw) else { return .rounded }
        return value
    }
}

/// Structural style record. Tolerant decode: any unknown or missing
/// field falls back to the default value instead of discarding the
/// whole pack, mirroring the sticker catalogue pattern.
struct BubbleStyleRecord: Equatable, Codable {
    var display: AppearanceChatDisplay
    var userSurface: BubbleSurface
    var assistantSurface: BubbleSurface
    var tailOn: Bool
    var cornerPreset: BubbleCornerPreset
    var userRadius: Double
    var assistantRadius: Double
    var avatarPlacement: BubbleAvatarPlacement
    var avatarSize: Double
    var avatarBorderWidth: Double
    var userBorderWidth: Double
    var assistantBorderWidth: Double
    var userPadding: Double
    var assistantPadding: Double
    var messageSpacing: Double
    var userMeta: BubbleMetaPosition
    var assistantMeta: BubbleMetaPosition
    var userName: BubbleNamePlacement
    var assistantName: BubbleNamePlacement
    var inputBarForm: BubbleInputBarForm
    var inputBarRadius: Double

    static let `default` = BubbleStyleRecord(
        display: .bubbles,
        userSurface: .row, assistantSurface: .row,
        tailOn: false, cornerPreset: .even,
        userRadius: 18, assistantRadius: 16,
        avatarPlacement: .inline, avatarSize: 40, avatarBorderWidth: 0,
        userBorderWidth: 0, assistantBorderWidth: 0,
        userPadding: 14, assistantPadding: 14,
        messageSpacing: 10,
        userMeta: .below, assistantMeta: .below,
        userName: .hidden, assistantName: .above,
        inputBarForm: .rounded, inputBarRadius: 20
    )

    init(display: AppearanceChatDisplay = .bubbles,
         userSurface: BubbleSurface = .row, assistantSurface: BubbleSurface = .row,
         tailOn: Bool = false, cornerPreset: BubbleCornerPreset = .even,
         userRadius: Double = 18, assistantRadius: Double = 16,
         avatarPlacement: BubbleAvatarPlacement = .inline,
         avatarSize: Double = 40, avatarBorderWidth: Double = 0,
         userBorderWidth: Double = 0, assistantBorderWidth: Double = 0,
         userPadding: Double = 14, assistantPadding: Double = 14,
         messageSpacing: Double = 10,
         userMeta: BubbleMetaPosition = .below, assistantMeta: BubbleMetaPosition = .below,
         userName: BubbleNamePlacement = .hidden, assistantName: BubbleNamePlacement = .above,
         inputBarForm: BubbleInputBarForm = .rounded, inputBarRadius: Double = 20) {
        self.display = display
        self.userSurface = userSurface
        self.assistantSurface = assistantSurface
        self.tailOn = tailOn
        self.cornerPreset = cornerPreset
        self.userRadius = BubbleStyleRecord.clampRadius(userRadius)
        self.assistantRadius = BubbleStyleRecord.clampRadius(assistantRadius)
        self.avatarPlacement = avatarPlacement
        self.avatarSize = min(64, max(28, avatarSize))
        self.avatarBorderWidth = min(3, max(0, avatarBorderWidth))
        self.userBorderWidth = min(2, max(0, userBorderWidth))
        self.assistantBorderWidth = min(2, max(0, assistantBorderWidth))
        self.userPadding = min(20, max(8, userPadding))
        self.assistantPadding = min(20, max(8, assistantPadding))
        self.messageSpacing = min(24, max(4, messageSpacing))
        self.userMeta = userMeta
        self.assistantMeta = assistantMeta
        self.userName = userName
        self.assistantName = assistantName
        self.inputBarForm = inputBarForm
        self.inputBarRadius = BubbleStyleRecord.clampRadius(inputBarRadius)
    }

    static func clampRadius(_ value: Double) -> Double { min(32, max(4, value)) }

    private enum CodingKeys: String, CodingKey {
        case display, userSurface, assistantSurface, tailOn, cornerPreset
        case userRadius, assistantRadius, avatarPlacement, avatarSize, avatarBorderWidth
        case userBorderWidth, assistantBorderWidth, userPadding, assistantPadding
        case messageSpacing, userMeta, assistantMeta, userName, assistantName
        case inputBarForm, inputBarRadius
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = BubbleStyleRecord.default
        if let raw = try c.decodeIfPresent(String.self, forKey: .display),
           let parsed = AppearanceChatDisplay(rawValue: raw) {
            display = parsed
        } else {
            display = d.display
        }
        userSurface = BubbleSurface.parse(try c.decodeIfPresent(String.self, forKey: .userSurface))
        assistantSurface = BubbleSurface.parse(try c.decodeIfPresent(String.self, forKey: .assistantSurface))
        tailOn = try c.decodeIfPresent(Bool.self, forKey: .tailOn) ?? d.tailOn
        cornerPreset = BubbleCornerPreset.parse(try c.decodeIfPresent(String.self, forKey: .cornerPreset))
        userRadius = BubbleStyleRecord.clampRadius(try c.decodeIfPresent(Double.self, forKey: .userRadius) ?? d.userRadius)
        assistantRadius = BubbleStyleRecord.clampRadius(try c.decodeIfPresent(Double.self, forKey: .assistantRadius) ?? d.assistantRadius)
        avatarPlacement = BubbleAvatarPlacement.parse(try c.decodeIfPresent(String.self, forKey: .avatarPlacement))
        avatarSize = min(64, max(28, try c.decodeIfPresent(Double.self, forKey: .avatarSize) ?? d.avatarSize))
        avatarBorderWidth = min(3, max(0, try c.decodeIfPresent(Double.self, forKey: .avatarBorderWidth) ?? d.avatarBorderWidth))
        userBorderWidth = min(2, max(0, try c.decodeIfPresent(Double.self, forKey: .userBorderWidth) ?? d.userBorderWidth))
        assistantBorderWidth = min(2, max(0, try c.decodeIfPresent(Double.self, forKey: .assistantBorderWidth) ?? d.assistantBorderWidth))
        userPadding = min(20, max(8, try c.decodeIfPresent(Double.self, forKey: .userPadding) ?? d.userPadding))
        assistantPadding = min(20, max(8, try c.decodeIfPresent(Double.self, forKey: .assistantPadding) ?? d.assistantPadding))
        messageSpacing = min(24, max(4, try c.decodeIfPresent(Double.self, forKey: .messageSpacing) ?? d.messageSpacing))
        userMeta = BubbleMetaPosition.parse(try c.decodeIfPresent(String.self, forKey: .userMeta))
        assistantMeta = BubbleMetaPosition.parse(try c.decodeIfPresent(String.self, forKey: .assistantMeta))
        userName = BubbleNamePlacement.parse(try c.decodeIfPresent(String.self, forKey: .userName))
        assistantName = BubbleNamePlacement.parse(try c.decodeIfPresent(String.self, forKey: .assistantName))
        inputBarForm = BubbleInputBarForm.parse(try c.decodeIfPresent(String.self, forKey: .inputBarForm))
        inputBarRadius = BubbleStyleRecord.clampRadius(try c.decodeIfPresent(Double.self, forKey: .inputBarRadius) ?? d.inputBarRadius)
    }

    /// Bubble style the live theme pack understands, for one role.
    /// Asymmetric corners map to rounded live; the asymmetry itself
    /// now travels in the theme pack's bubbleCornerPreset and is
    /// drawn by MinisBubbleShape's per-corner radii (see
    /// MinisThemeShape.cornerRadii), so sample and live agree.
    func liveStyle() -> AppearanceBubbleStyle {
        if tailOn { return .tail }
        switch cornerPreset {
        case .pill: return .pill
        case .sharp: return .sharp
        case .even, .asymmetric: return .rounded
        }
    }

    func liveInputBarStyle() -> AppearanceBubbleStyle {
        switch inputBarForm {
        case .pill: return .pill
        case .rounded: return .rounded
        case .flat: return .sharp
        }
    }
}

/// One catalogue entry. `number` is the stable, never-reused
/// identifier (BUB-0001 style) shown next to the name in UI and used
/// by the AI instead of guessing from a name.
struct BubbleStylePack: Identifiable, Equatable, Codable {
    var number: String
    var title: String
    var category: String
    var useCount: Int
    var style: BubbleStyleRecord

    var id: String { number }

    private enum CodingKeys: String, CodingKey {
        case number, title, category, useCount, style
    }

    init(number: String, title: String, category: String, useCount: Int = 0,
         style: BubbleStyleRecord) {
        self.number = number
        self.title = title
        self.category = category
        self.useCount = max(0, useCount)
        self.style = style
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        number = try c.decodeIfPresent(String.self, forKey: .number) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        category = try c.decodeIfPresent(String.self, forKey: .category) ?? ""
        useCount = max(0, try c.decodeIfPresent(Int.self, forKey: .useCount) ?? 0)
        style = try c.decodeIfPresent(BubbleStyleRecord.self, forKey: .style) ?? .default
    }
}

private struct BubblePackCatalogData: Codable {
    var packs: [BubbleStylePack]
    var appliedNumber: String?
    var nextSerial: Int

    private enum CodingKeys: String, CodingKey {
        case packs, appliedNumber, nextSerial
    }

    init(packs: [BubbleStylePack], appliedNumber: String?, nextSerial: Int) {
        self.packs = packs
        self.appliedNumber = appliedNumber
        self.nextSerial = nextSerial
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        packs = try c.decodeIfPresent([BubbleStylePack].self, forKey: .packs) ?? []
        appliedNumber = try c.decodeIfPresent(String.self, forKey: .appliedNumber)
        nextSerial = max(1, try c.decodeIfPresent(Int.self, forKey: .nextSerial) ?? 1)
    }
}

/// Catalogue store, mirroring the sticker catalogue pattern:
/// tolerant decode, built-ins on first run, numbers never reused
/// (nextSerial only moves forward; step 1 has no delete, so no
/// tombstones are needed yet).
@MainActor
final class BubbleStylePackStore: ObservableObject {
    static let shared = BubbleStylePackStore()

    @Published private(set) var packs: [BubbleStylePack] = []
    @Published private(set) var appliedNumber: String?
    private var nextSerial = 5

    static let builtIns: [BubbleStylePack] = [
        BubbleStylePack(
            number: "BUB-0001", title: "今天的默认", category: "默认",
            style: .default),
        BubbleStylePack(
            number: "BUB-0002", title: "小尾巴", category: "气泡",
            style: BubbleStyleRecord(
                tailOn: true, cornerPreset: .asymmetric,
                userRadius: 18, assistantRadius: 16,
                inputBarForm: .pill, inputBarRadius: 20)),
        BubbleStylePack(
            number: "BUB-0003", title: "相框卡片", category: "卡片",
            style: BubbleStyleRecord(
                userSurface: .text, assistantSurface: .text,
                tailOn: false, cornerPreset: .even,
                userRadius: 12, assistantRadius: 12,
                avatarPlacement: .overlapping, avatarSize: 44, avatarBorderWidth: 1,
                userBorderWidth: 1, assistantBorderWidth: 1,
                userPadding: 16, assistantPadding: 16,
                messageSpacing: 14,
                userName: .above, assistantName: .above,
                inputBarForm: .rounded, inputBarRadius: 16)),
        BubbleStylePack(
            number: "BUB-0004", title: "安静文稿", category: "文稿",
            style: BubbleStyleRecord(
                display: .document,
                userSurface: .text, assistantSurface: .text,
                tailOn: false, cornerPreset: .even,
                userRadius: 8, assistantRadius: 8,
                avatarPlacement: .inline, avatarSize: 36, avatarBorderWidth: 0,
                userBorderWidth: 0, assistantBorderWidth: 0,
                userPadding: 10, assistantPadding: 10,
                messageSpacing: 16,
                userMeta: .below, assistantMeta: .below,
                userName: .hidden, assistantName: .hidden,
                inputBarForm: .flat, inputBarRadius: 8)),
    ]

    private var catalogURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first!
        let dir = base.appendingPathComponent("AppearanceStudio", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("bubble_packs_catalog.json")
    }

    private init() { load() }

    private func load() {
        if let data = try? Data(contentsOf: catalogURL),
           let catalog = try? JSONDecoder().decode(BubblePackCatalogData.self, from: data),
           !catalog.packs.isEmpty,
           !catalog.packs.contains(where: { $0.number.isEmpty }) {
            packs = catalog.packs
            appliedNumber = catalog.appliedNumber
            nextSerial = max(5, catalog.nextSerial)
            return
        }
        // First run, or an unreadable catalogue: built-ins in memory.
        // A corrupt file is left alone until the next save, so a bad
        // write never silently destroys a catalogue the user could
        // still recover by hand.
        packs = Self.builtIns
        appliedNumber = nil
        nextSerial = 5
    }

    private func save() {
        let catalog = BubblePackCatalogData(
            packs: packs, appliedNumber: appliedNumber, nextSerial: nextSerial)
        guard let data = try? JSONEncoder().encode(catalog) else { return }
        try? data.write(to: catalogURL, options: .atomic)
    }

    func pack(number: String) -> BubbleStylePack? {
        packs.first { $0.number == number }
    }

    /// Tap-apply. Writes the FULL structural record to the live
    /// theme pack (display, both bubble styles, both radii, both
    /// surfaces, both border widths, both paddings, avatar
    /// size/border/placement, message spacing, meta and name
    /// placement, corner preset, input-bar style/radius). Colours,
    /// opacity, both text slots, wallpapers, avatar shape, and the
    /// theme library are untouched. setBubbleStyle() resets the
    /// corner preset to even (a hand-picked style is not asymmetric),
    /// so the preset is written after those calls, in this final
    /// persist — order matters.
    func apply(_ pack: BubbleStylePack) {
        let studio = AppearanceStudio.shared
        studio.setChatDisplay(pack.style.display)
        let style = pack.style.liveStyle()
        studio.setBubbleStyle(style, user: true)
        studio.setBubbleStyle(style, user: false)
        var theme = studio.currentThemePack()
        let s = pack.style
        theme.userBubbleRadius = s.userRadius
        theme.assistantBubbleRadius = s.assistantRadius
        theme.userBubbleSurface = s.userSurface.rawValue
        theme.assistantBubbleSurface = s.assistantSurface.rawValue
        theme.userBubbleBorderWidth = s.userBorderWidth
        theme.assistantBubbleBorderWidth = s.assistantBorderWidth
        theme.userBubblePadding = s.userPadding
        theme.assistantBubblePadding = s.assistantPadding
        theme.avatarSize = s.avatarSize
        theme.avatarBorderWidth = s.avatarBorderWidth
        theme.avatarPlacement = s.avatarPlacement.rawValue
        theme.userMetaPosition = s.userMeta.rawValue
        theme.assistantMetaPosition = s.assistantMeta.rawValue
        theme.userNamePlacement = s.userName.rawValue
        theme.assistantNamePlacement = s.assistantName.rawValue
        theme.messageSpacing = s.messageSpacing
        theme.bubbleCornerPreset = s.cornerPreset.rawValue
        theme.inputBarRadius = s.inputBarRadius
        theme.inputBarStyle = s.liveInputBarStyle().rawValue
        studio.persistPack(theme)
        if let index = packs.firstIndex(where: { $0.number == pack.number }) {
            packs[index].useCount += 1
        }
        appliedNumber = pack.number
        save()
    }
}
