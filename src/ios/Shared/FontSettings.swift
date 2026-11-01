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

/// Centralised font-scale preferences for the app.
///
/// Three independent axes, each storing a scale multiplier:
/// - **chatInput**: the text-editor where the user types messages
/// - **messageBase**: assistant / user message body text (markdown base size)
/// - **appBase**: reserved for general UI text (labels, settings, etc.)
///
/// Usage: call `scaled(_:for:)` with the original hardcoded font size and the axis.
/// The returned value = originalSize × multiplier.
@MainActor
final class FontSettings: ObservableObject {
    static let shared = FontSettings()

    // MARK: - Published properties

    @Published var chatInputScale: FontScaleLevel {
        didSet {
            guard chatInputScale != oldValue else { return }
            UserDefaults.standard.set(chatInputScale.rawValue, forKey: Keys.chatInput)
        }
    }
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
        }
    }
    @Published var appBaseScale: FontScaleLevel {
        didSet {
            guard appBaseScale != oldValue else { return }
            UserDefaults.standard.set(appBaseScale.rawValue, forKey: Keys.appBase)
            // Defer to next runloop to avoid layout feedback loop with Slider
            DispatchQueue.main.async { [weak self] in self?.applyAppScaleToAllWindows() }
        }
    }

    /// `true` when any value differs from default.
    var isModified: Bool {
        chatInputScale != .default
            || messageBaseScale != .default
            || messagePointSize != 13
            || appBaseScale != .default
    }

    // MARK: - Scaling helpers

    /// Scale a font size by the chat-input multiplier.
    func scaledChatInput(_ size: CGFloat) -> CGFloat {
        size * chatInputScale.multiplier
    }

    /// Scale a font size for message text: proportional to the
    /// user's message point size (10-15pt, default 13pt), so a
    /// site written at the old 16.5pt base renders at exactly
    /// the chosen point size, and smaller sites scale with it.
    func scaledMessage(_ size: CGFloat) -> CGFloat {
        size * messagePointSize / 16.5
    }

    /// Scale a font size by the app-base multiplier.
    func scaledApp(_ size: CGFloat) -> CGFloat {
        size * appBaseScale.multiplier
    }

    // MARK: - Init

    private init() {
        let ud = UserDefaults.standard
        chatInputScale = FontScaleLevel(rawValue: ud.integer(forKey: Keys.chatInput)) ?? .default
        messageBaseScale = FontScaleLevel(rawValue: ud.integer(forKey: Keys.messageBase)) ?? .default
        // First launch with no stored point size: a user who
        // explicitly moved the old message slider keeps that
        // choice, capped into 10-15pt; everyone else gets 13pt
        // (never the old 17pt-era default).
        if ud.object(forKey: Keys.messagePoint) != nil {
            messagePointSize = min(15, max(10, CGFloat(ud.double(forKey: Keys.messagePoint))))
        } else if messageBaseScale != .default {
            messagePointSize = min(15, max(10, 16.5 * messageBaseScale.multiplier))
        } else {
            messagePointSize = 13
        }
        appBaseScale = FontScaleLevel(rawValue: ud.integer(forKey: Keys.appBase)) ?? .default
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
        // Skip if default — no need to override system traits
        guard appBaseScale != .default else {
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
        let category = appBaseScale.contentSizeCategory
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
/// 1. 尺寸乘 `FontSettings.scaledApp`（设置里的「整体字号」）
/// 2. 字体族取装扮页的主题字体（`MinisThemeShape.fontFamily`）
///
/// 调用方都持有 `@ObservedObject fontSettings` 与 `@ObservedObject appearanceStudio`，
/// 两者变化都会重算 body，字体跟着刷新。
@MainActor
enum ChatFont {
    static func font(_ size: CGFloat,
                     weight: Font.Weight = .regular,
                     design: Font.Design? = nil) -> Font {
        let scaled = FontSettings.shared.scaledApp(size)
        if let design {
            return .system(size: scaled, weight: weight, design: design)
        }
        // UI-part uploaded font wins when it resolves on this
        // device; otherwise the global family, as before.
        if let name = MinisThemeShape.uiCustomFontName,
           let uiFont = UIFont(name: name, size: scaled) {
            return Font(uiFont)
        }
        return MinisThemeShape.fontFamily.font(size: scaled, weight: weight)
    }
}

/// Applies app-base font scaling via `dynamicTypeSize`.
/// Use on sheet content and any view that doesn't inherit the root environment.
///
/// At `.default` this applies nothing. `.dynamicTypeSize(.large)` is a hard
/// pin, not a no-op — it overrode the reader's own iOS Dynamic Type setting,
/// so someone running Larger Text system-wide got it silently forced back to
/// the default inside every screen that used this modifier. Leaving the
/// environment untouched at default lets the system value through.
private struct AppFontScaleModifier: ViewModifier {
    @ObservedObject private var fontSettings = FontSettings.shared

    func body(content: Content) -> some View {
        if fontSettings.appBaseScale == .default {
            content
        } else {
            content.dynamicTypeSize(fontSettings.appBaseScale.dynamicTypeSize)
        }
    }
}

extension View {
    /// Applies the user's App Base font scale to this view hierarchy.
    func appFontScale() -> some View {
        modifier(AppFontScaleModifier())
    }
}
