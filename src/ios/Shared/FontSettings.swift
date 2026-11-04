import Combine
import Foundation
import SwiftUI

extension Notification.Name {
    static let fontSettingsMessageBaseChanged = Notification.Name("fontSettingsMessageBaseChanged")
}

/// Font scale level — nine discrete steps, now reaching well
/// below the old minimum: the old smallest step (0.76, ~13pt
/// body) was still too big for the user, so two smaller steps
/// were added (0.65 and 0.56). The two new steps floor their
/// DynamicTypeSize / content-size mappings at the smallest
/// system values — there is no smaller system bucket — while
/// the multiplier itself keeps shrinking the scaled sizes.
enum FontScaleLevel: Int, CaseIterable, Identifiable, Comparable {
    case xxxxSmall = -5
    case xxxSmall = -4
    case xxSmall = -3
    case xSmall = -2
    case small = -1
    case `default` = 0
    case medium = 1
    case large = 2
    case extraLarge = 3

    var id: Int { rawValue }

    /// Explicit declaration so CaseIterable follows display order, not raw-value order.
    static var allCases: [FontScaleLevel] { [.xxxxSmall, .xxxSmall, .xxSmall, .xSmall, .small, .default, .medium, .large, .extraLarge] }

    var multiplier: CGFloat {
        switch self {
        case .xxxxSmall:  return 0.56   // ~10pt body
        case .xxxSmall:   return 0.65   // ~11pt body
        case .xxSmall:    return 0.76   // ~13pt body
        case .xSmall:     return 0.88   // ~15pt body
        case .small:      return 0.94   // ~16pt body
        case .default:    return 1.0    // 17pt body
        case .medium:     return 1.06
        case .large:      return 1.12
        case .extraLarge: return 1.21
        }
    }

    var label: String {
        switch self {
        case .xxxxSmall:  return "XXXXS"
        case .xxxSmall:   return "XXXS"
        case .xxSmall:    return "XXS"
        case .xSmall:     return "XS"
        case .small:      return "Small"
        case .default:    return "Default"
        case .medium:     return "Medium"
        case .large:      return "Large"
        case .extraLarge: return "Extra Large"
        }
    }

    /// Maps to SwiftUI `DynamicTypeSize` so semantic fonts (`.body`, `.caption`, etc.)
    /// scale automatically when this level is applied via `.dynamicTypeSize()`.
    var dynamicTypeSize: DynamicTypeSize {
        switch self {
        case .xxxxSmall:  return .xSmall
        case .xxxSmall:   return .xSmall
        case .xxSmall:    return .xSmall
        case .xSmall:     return .small
        case .small:      return .medium
        case .default:    return .large        // system default
        case .medium:     return .xLarge
        case .large:      return .xxLarge
        case .extraLarge: return .xxxLarge
        }
    }

    /// UIKit equivalent for applying to all UIWindows (including sheets).
    var contentSizeCategory: UIContentSizeCategory {
        switch self {
        case .xxxxSmall:  return .extraSmall
        case .xxxSmall:   return .extraSmall
        case .xxSmall:    return .extraSmall
        case .xSmall:     return .small
        case .small:      return .medium
        case .default:    return .large
        case .medium:     return .extraLarge
        case .large:      return .extraExtraLarge
        case .extraLarge: return .extraExtraExtraLarge
        }
    }

    static func < (lhs: FontScaleLevel, rhs: FontScaleLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Centralised font preferences for the app.
///
/// ONE global size drives message body, UI text, and input
/// text together: `messagePointSize` (10-15pt, default 13pt).
/// It is the stored message choice, so existing users keep
/// exactly the size they already picked — the migration rule
/// "when sizes differ, keep the message size" is this: the
/// old stepped axes below no longer drive any sizing, so
/// there is nothing left for the message size to disagree
/// with. The stepped properties stay stored (the config
/// registry still binds them) but are legacy: changing one
/// does not change any rendered size.
///
/// Usage: `scaledMessage` for message-body sites (written
/// against a 16.5pt base), `scaledApp` / `scaledChatInput`
/// for UI and input sites (written at their literal sizes,
/// so they anchor on the 13pt default for identity).
@MainActor
final class FontSettings: ObservableObject {
    static let shared = FontSettings()

    // MARK: - Published properties

    /// Legacy stepped axis, stored only. Kept so the config
    /// registry's key paths still compile; it no longer
    /// drives any size (see the class comment).
    @Published var chatInputScale: FontScaleLevel {
        didSet {
            guard chatInputScale != oldValue else { return }
            UserDefaults.standard.set(chatInputScale.rawValue, forKey: Keys.chatInput)
        }
    }
    /// Legacy stepped axis, stored only (same rule as above).
    @Published var messageBaseScale: FontScaleLevel {
        didSet {
            guard messageBaseScale != oldValue else { return }
            UserDefaults.standard.set(messageBaseScale.rawValue, forKey: Keys.messageBase)
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .fontSettingsMessageBaseChanged, object: nil)
            }
        }
    }

    /// Message body point size, the user's chosen main range:
    /// 10pt minimum, 15pt maximum, 13pt default — never 17pt.
    /// The old message-base multiplier no longer drives message
    /// text (it is kept stored for compatibility); message sizes
    /// come from this point size, scaled proportionally from
    /// the 16.5pt base the message sites were written against,
    /// so a 13pt setting renders body text at exactly 13pt.
    @Published var messagePointSize: CGFloat {
        didSet {
            let clamped = min(15, max(10, messagePointSize))
            if clamped != messagePointSize {
                messagePointSize = clamped
                return
            }
            guard messagePointSize != oldValue else { return }
            UserDefaults.standard.set(messagePointSize, forKey: Keys.messagePoint)
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .fontSettingsMessageBaseChanged, object: nil)
            }
            // The window content-size override follows the
            // global size now, not the legacy app-base axis.
            DispatchQueue.main.async { [weak self] in self?.applyAppScaleToAllWindows() }
            // [T-09] 字号档进小组件快照,桌面文字跟 App 一起变大变小。
            DispatchQueue.main.async { WidgetProfileBridge.scheduleThemeRefresh(delay: 0) }
        }
    }

    /// Alias for the one global size: message, UI, and input
    /// all read `messagePointSize`. The alias exists so call
    /// sites can say what they mean; the stored value (and
    /// the @Published observation) is `messagePointSize`.
    var globalPointSize: CGFloat {
        get { messagePointSize }
        set { messagePointSize = newValue }
    }

    /// Legacy stepped axis, stored only (same rule as above).
    @Published var appBaseScale: FontScaleLevel {
        didSet {
            guard appBaseScale != oldValue else { return }
            UserDefaults.standard.set(appBaseScale.rawValue, forKey: Keys.appBase)
            // Defer to next runloop to avoid layout feedback loop with Slider
            DispatchQueue.main.async { [weak self] in self?.applyAppScaleToAllWindows() }
        }
    }

    /// `true` when the global size differs from default.
    /// Legacy axes are deliberately excluded: they no longer
    /// change anything, so they must not keep a "reset" button
    /// visible for a difference the user cannot see.
    var isModified: Bool {
        messagePointSize != 13
    }

    // MARK: - Density

    /// One density factor for every settings-page row and
    /// card, derived from the global size alone: at the 13pt
    /// default it is exactly 1 (no layout change for existing
    /// users), at 12pt it is 0.92, at 10pt 0.77, so a small
    /// font also pulls padding and spacing in — the reported
    /// bug was text shrinking while rows stayed huge, which
    /// is what made small sizes still look like an old phone.
    /// Capped at the top so 15pt rooms the page out only
    /// slightly instead of blowing it up.
    var densityFactor: CGFloat {
        min(1.15, max(0.75, messagePointSize / 13))
    }

    /// Scale a padding / spacing / row-height base by the
    /// density factor. Font sizes never go through here;
    /// they go through `scaledApp` / `scaledMessage`.
    func density(_ base: CGFloat) -> CGFloat {
        base * densityFactor
    }

    func densityFloor(_ base: CGFloat, ratio: CGFloat = 0.85) -> CGFloat {
        max(base * ratio, density(base))
    }

    /// [六定-6] Picks the foreground that stays readable on a given fill:
    /// white on dark fills, black on light ones. The theme store's selected
    /// category capsule fills with `primaryText` (whatever the user picked →
    /// can be near-white in light mode or near-black in dark mode), so the
    /// label must invert against the *actual* fill instead of assuming a
    /// colour. `on` is a hex like "#RRGGBB".
    static func contrastForeground(on hex: String) -> Color {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard cleaned.count >= 6, let value = UInt64(cleaned.prefix(6), radix: 16) else {
            return .white
        }
        let r = Double((value >> 16) & 0xFF) / 255.0
        let g = Double((value >> 8) & 0xFF) / 255.0
        let b = Double(value & 0xFF) / 255.0
        // WCAG relative luminance; 0.179 is the sRGB mid-tone breakpoint
        // between black and white text.
        let lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
        return lum > 0.179 ? Color.black : Color.white
    }


    /// Semantic-size bucket for the global size, for the
    /// root `.dynamicTypeSize` pin and sheet scaling. 13pt
    /// maps to `.large` (the system default bucket), which is
    /// exactly what the old app-base-default pin produced.
    var globalDynamicTypeSize: DynamicTypeSize {
        // `DynamicTypeSize(_:)` is failable — an unknown category returns nil.
        // Every category this maps to is a real one, but fall back to `.large`
        // rather than force-unwrap: the root environment must always have a
        // value, and `.large` is the bucket 13pt is defined as.
        DynamicTypeSize(globalContentSizeCategory) ?? .large
    }

    /// UIKit equivalent of `globalDynamicTypeSize`, for the
    /// all-windows content-size override.
    ///
    /// [T-12] This is the single table. It used to disagree
    /// with `globalDynamicTypeSize` at 11pt and 12pt (one said
    /// `.extraSmall`/`.small`, the other `.small`/`.medium`), so the
    /// root pin and the window override scaled the same app by
    /// different amounts. `globalDynamicTypeSize` now derives from
    /// this, so 13pt is `.large` in both and every step moves them
    /// together.
    var globalContentSizeCategory: UIContentSizeCategory {
        switch Int(messagePointSize) {
        case ...10: return .extraSmall
        case 11: return .small
        case 12: return .medium
        case 13: return .large
        case 14: return .extraLarge
        default: return .extraExtraLarge
        }
    }

    // MARK: - Scaling helpers

    // ⚠️ [T-71] TWO ANCHORS, DO NOT MIX THEM.
    //
    //   scaledMessage    → ÷ 16.5   (message-body sites, written at the old 16.5pt base)
    //   scaledApp        → ÷ 13     (UI / chat-input sites, written at their literal size)
    //   scaledChatInput  → ÷ 13     (same anchor as scaledApp; kept as a named alias)
    //
    // Passing the same number to two of these does NOT give the same result:
    // at the 13pt default scaledMessage(13) = 10.2pt while scaledApp(13) = 13pt,
    // a silent ~21% difference. Pick the function that matches the base the
    // site was written against; when migrating a literal, scaledApp is the
    // usual choice and leaves the 13pt default pixel-identical.

    /// Scale an input-text size by the global size: a site
    /// written at its literal size renders unchanged at the
    /// 13pt default and moves with the global size elsewhere.
    /// Anchor 13 (see the warning above).
    func scaledChatInput(_ size: CGFloat) -> CGFloat {
        size * messagePointSize / 13
    }

    /// Scale a font size for message text: proportional to the
    /// user's message point size (10-15pt, default 13pt), so a
    /// site written at the old 16.5pt base renders at exactly
    /// the chosen point size, and smaller sites scale with it.
    /// Anchor 16.5 (see the warning above).
    ///
    /// Fact, not a defect: the input bar renders through
    /// `scaledChatInput(16.5)`, so at the default it is 16.5pt while the
    /// message body is 13pt — the composer text is deliberately larger
    /// than the body. The font-size page should say so rather than let the
    /// reader assume they are the same size.
    func scaledMessage(_ size: CGFloat) -> CGFloat {
        size * messagePointSize / 16.5
    }

    /// [T-17] Micro copy floor. Footnote / preview-label sizes used to ride
    /// the dial all the way down (4pt at the 10pt setting, ~3pt on screen).
    /// Anything in the tiny band goes through this so it stops at
    /// `microFloor` no matter how far the dial is pushed down. This is the
    /// lower guard rail the plan asks for; it never raises a size that is
    /// already at or above the floor.
    static let microFloor: CGFloat = 6

    func scaledMicro(_ size: CGFloat) -> CGFloat {
        max(FontSettings.microFloor, scaledApp(size))
    }

    /// [T-18] Floor for `minimumScaleFactor` on labels that sit in a fixed
    /// container and therefore cannot grow their layout instead of shrinking
    /// the text. The site still picks its own `wanted` factor, but the result
    /// never lets the rendered glyphs fall under `microFloor` (6pt): however
    /// far the dial is pushed, a one-line label cannot shrink out of sight.
    /// `size` is the *unscaled* literal the site hands to `ChatFont.font`, so
    /// the floor is evaluated against the dial-scaled size.
    ///
    /// Sites that *can* grow their layout should grow it instead — this is for
    /// the ones that genuinely cannot (nav title, fixed-size tiles, single-line
    /// rows in a fixed panel). Each use still needs a real-device pass at the
    /// 15pt dial with a long string.
    static func shrinkFloor(_ size: CGFloat, wanted: CGFloat) -> CGFloat {
        let scaled = FontSettings.shared.scaledApp(size)
        guard scaled > 0 else { return wanted }
        return max(wanted, min(1.0, FontSettings.microFloor / scaled))
    }

    /// [T-38/T-41] Touch-target floor. A control's *visual* size may follow the
    /// dial, but its tappable area must not: `density` bottoms out at 0.75, so a
    /// 44pt row scaled by it would fall to 33pt — under the 44pt minimum Apple
    /// and the plan both ask for. Apply to the interactive element
    /// (`.frame(minHeight:)`, `.contentShape(...)`), never to the label inside it.
    static let minHitTarget: CGFloat = 44

    /// Scale a UI-text size by the global size, same anchor
    /// as `scaledChatInput`: literal sizes are unchanged at
    /// the 13pt default. Anchor 13 (see the warning above).
    func scaledApp(_ size: CGFloat) -> CGFloat {
        size * messagePointSize / 13
    }

    /// [T-72] 非隔离的同一支换算。
    ///
    /// 代码块的 UILabel 是在 `NSTextAttachment` 里搭的，那个类不是
    /// `@MainActor`，碰不到实例方法。这里直接读 UserDefaults 里的同一个值
    /// （`messagePointSize` 的 setter 就是写这个键），所以两条路径给出的
    /// 数字一致，不需要在主线程上再转一圈。
    nonisolated static func scaledAppDetached(_ size: CGFloat) -> CGFloat {
        let stored = UserDefaults.standard.object(forKey: Keys.messagePoint) as? Double
        let point = min(15, max(10, CGFloat(stored ?? 13)))
        return size * point / 13
    }

    // MARK: - Init

    private init() {
        let ud = UserDefaults.standard
        // Capture everything into locals first: reading any stored
        // property (e.g. messageBaseScale) before all stored
        // properties are assigned is a compile error ('self' used
        // before stored properties initialized), so the
        // messagePointSize decision must use the local, not self.
        let chatInput = FontScaleLevel(rawValue: ud.integer(forKey: Keys.chatInput)) ?? .default
        let messageBase = FontScaleLevel(rawValue: ud.integer(forKey: Keys.messageBase)) ?? .default
        let appBase = FontScaleLevel(rawValue: ud.integer(forKey: Keys.appBase)) ?? .default
        // First launch with no stored point size: a user who
        // explicitly moved the old message slider keeps that
        // choice, capped into 10-15pt; everyone else gets 13pt
        // (never the old 17pt-era default).
        let point: CGFloat
        if ud.object(forKey: Keys.messagePoint) != nil {
            point = min(15, max(10, CGFloat(ud.double(forKey: Keys.messagePoint))))
        } else if messageBase != .default {
            point = min(15, max(10, 16.5 * messageBase.multiplier))
        } else {
            point = 13
        }
        chatInputScale = chatInput
        messageBaseScale = messageBase
        messagePointSize = point
        appBaseScale = appBase
        // Defer to after first window is available
        DispatchQueue.main.async { [weak self] in self?.applyAppScaleToAllWindows() }
        // Windows created later (new scene, external display, restoration)
        // missed the override entirely; re-apply whenever one activates.
        NotificationCenter.default.addObserver(
            forName: UIScene.didActivateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyAppScaleToAllWindows()
        }
    }

    // MARK: - UIKit global application

    /// Override the preferred content size category on all connected UIWindows.
    /// This affects UIKit views, SwiftUI sheets, and any presented view controllers.
    ///
    /// Re-applied on scene activation: a window created after the last slider
    /// move (a new scene, an iPad external display, a state restoration)
    /// started life with the system category and never picked the override up.
    func applyAppScaleToAllWindows() {
        guard #available(iOS 17.0, *) else { return }
        // Skip at the 13pt default — no need to override system traits
        guard messagePointSize != 13 else {
            // Remove any previous override
            for scene in UIApplication.shared.connectedScenes {
                guard let windowScene = scene as? UIWindowScene else { continue }
                for window in windowScene.windows {
                    if window.traitOverrides.contains(UITraitPreferredContentSizeCategory.self) {
                        window.traitOverrides.remove(UITraitPreferredContentSizeCategory.self)
                    }
                }
            }
            return
        }
        let category = globalContentSizeCategory
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                window.traitOverrides.preferredContentSizeCategory = category
            }
        }
    }

    // MARK: - Reset

    func resetToDefaults() {
        chatInputScale = .default
        messageBaseScale = .default
        messagePointSize = 13
        appBaseScale = .default
    }

    // MARK: - Notification

    /// Posted when `messageBaseScale` changes so view models can invalidate rendered caches.
    static let messageBaseChangedNotification = Notification.Name.fontSettingsMessageBaseChanged

    // MARK: - Keys

    private enum Keys {
        static let chatInput = "fontSettings.chatInputScale"
        static let messageBase = "fontSettings.messageBaseScale"
        static let messagePoint = "fontSettings.messagePointSize"
        static let appBase = "fontSettings.appBaseScale"
    }
}

// MARK: - View extension for app-wide font scaling

// MARK: - Chat font tokens

/// [P-06] 聊天页的字号统一入口。
///
/// 原来聊天页里 80 处 `.system(size: 11)` 这种**固定字号**，完全不吃
/// 「设置 → 字号」：`dynamicTypeSize` 只对语义字号（`.caption`/`.body`）生效，
/// 对写死的 `.system(size:)` 一点用都没有。所以用户调字号时只有消息气泡
/// （走 `scaledMessage`）变大，输入框、面板、抽屉、工具栏纹丝不动。
///
/// 这里把两件事绑在一起：
/// 1. 尺寸乘 `FontSettings.scaledApp`（全局字号，消息 / 界面 / 输入同一支）
/// 2. 字体族取全局字体（`MinisThemeShape.globalFontFamily`），上传字体走
///    全局上传字体（`globalCustomFontName`，消息侧优先）
///
/// 调用方都持有 `@ObservedObject fontSettings` 与 `@ObservedObject appearanceStudio`，
/// 两者变化都会重算 body，字体跟着刷新。
@MainActor
enum ChatFont {
    static func font(_ size: CGFloat,
                     weight: Font.Weight = .regular,
                     design: Font.Design? = nil) -> Font {
        resolved(FontSettings.shared.scaledApp(size), weight: weight, design: design)
    }

    /// [T-17] Micro-copy variant: identical to `font(_:)`, except the final
    /// size stops at `FontSettings.microFloor` (6pt) however far the dial is
    /// pushed down, so a footnote / status badge cannot shrink out of
    /// legibility. Use for anything written at 8pt or below.
    static func micro(_ size: CGFloat,
                      weight: Font.Weight = .regular,
                      design: Font.Design? = nil) -> Font {
        let scaled = max(FontSettings.microFloor, FontSettings.shared.scaledApp(size))
        return resolved(scaled, weight: weight, design: design)
    }

    private static func resolved(_ scaled: CGFloat,
                                 weight: Font.Weight,
                                 design: Font.Design?) -> Font {
        if let design {
            return .system(size: scaled, weight: weight, design: design)
        }
        // Global uploaded font wins when it resolves on this
        // device; otherwise the global family.
        if let name = MinisThemeShape.globalCustomFontName,
           let uiFont = UIFont(name: name, size: scaled) {
            return Font(uiFont)
        }
        return MinisThemeShape.globalFontFamily.font(size: scaled, weight: weight)
    }
}

/// Applies global-size scaling via `dynamicTypeSize`.
/// Use on sheet content and any view that doesn't inherit the root environment.
///
/// At the 13pt default this applies nothing. `.dynamicTypeSize(.large)` is a hard
/// pin, not a no-op — it overrode the reader's own iOS Dynamic Type setting,
/// so someone running Larger Text system-wide got it silently forced back to
/// the default inside every screen that used this modifier. Leaving the
/// environment untouched at default lets the system value through.
private struct AppFontScaleModifier: ViewModifier {
    @ObservedObject private var fontSettings = FontSettings.shared

    func body(content: Content) -> some View {
        if fontSettings.messagePointSize == 13 {
            content
        } else {
            content.dynamicTypeSize(fontSettings.globalDynamicTypeSize)
        }
    }
}

extension View {
    /// Applies the user's App Base font scale to this view hierarchy.
    func appFontScale() -> some View {
        modifier(AppFontScaleModifier())
    }
}
