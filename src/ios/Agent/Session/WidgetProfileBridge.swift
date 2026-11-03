import Foundation
import WidgetKit

/// [B28 R13] 主 App → 主屏小组件的桥。
///
/// 小组件跑在独立进程，读不到主 App 沙盒，所以这里把"她叫什么、AI 叫什么、
/// 最近一句"写成一份小 JSON 放进 App Group，再让 WidgetKit 刷新时间线。
/// 只写显示用的字符串，不写档案正文——小组件不需要，也不该碰。
enum WidgetProfileBridge {
    static let appGroup = "group.com.openminis.clone"
    static let fileName = "profile-widget.json"

    /// 档案/人设一变就调它。主线程读 PersonaStore，所以标 @MainActor。
    @MainActor
    static func refresh() {
        let assistant = SoulStore.displayName(for: PersonaStore.currentID())
        let user = SystemPromptBuilder.userProfileAddressingName()
        let line = SystemPromptBuilder.userProfileField(key: "正在做").isEmpty
            ? SystemPromptBuilder.userProfileField(key: "最近状态")
            : SystemPromptBuilder.userProfileField(key: "正在做")

        let payload: [String: String] = [
            "assistant": assistant,
            "user": user.isEmpty ? "你" : user,
            "line": line.isEmpty ? "点开和我说句话" : line
        ]

        guard let url = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent(fileName) else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        try? data.write(to: url, options: .atomic)
        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: - [T-08][T-09] Theme snapshot

    /// 主题快照文件名。小组件读它拿到强调色、文字色和字号档,
    /// 所以「她是谁」那块桌面的颜色和字大小跟主 App 一致。
    static let themeFileName = "theme-widget.json"

    /// [T-08] 主 App→小组件的主题快照。
    ///
    /// 上一版小组件自己在代码里写死 `#D4778B`(payload 里根本没有 accent
    /// 这个键,`obj["accent"] ?? fallback` 永远走 fallback),所以改主题
    /// 完全不影响桌面。这里把两套明暗的颜色和当前字号档写进 App Group,
    /// 小组件按系统外观挑一套、按字号档缩放文字。
    ///
    /// 只写显示需要的几个角色,不写整包主题——小组件不需要,也不该碰
    /// 用户的页级覆盖、壁纸和字体文件。
    ///
    /// [T-09] 字号档一起进快照:以前小组件把 15/11/16pt 写死,拨大盘时
    /// 桌面还是小字,和 App 里对不上。
    @MainActor
    static func refreshTheme() {

        // 明暗各写一套,让小组件按自己的 colorScheme 挑,而不是跟随 App
        // 当前模式——小组件常驻桌面,可能和 App 里的明暗不一样。
        func palette(_ variant: AppearanceVariant) -> [String: String] {
            let roles: [AppearanceColorRole] = [
                .accent, .primaryText, .secondaryText, .canvas, .surface, .userBubble
            ]
            var out: [String: String] = [:]
            for role in roles {
                out[role.rawValue] = studio.hex(role, scope: .global, variant: variant)
            }
            return out
        }

        let payload: [String: Any] = [
            "version": 1,
            // 字号档 = 全局点号 ÷ 13pt 基准,默认档正好是 1.0。
            "fontScale": Double(FontSettings.shared.messagePointSize / 13),
            "light": palette(.light),
            "dark": palette(.dark)
        ]

        guard let url = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent(themeFileName) else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        try? data.write(to: url, options: .atomic)
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// [T-08] 取色器每拖一帧都会写一次颜色,直接跟着刷小组件太浪费
    /// (系统本来也会限流)。隔 0.6 秒合并一次,拖完落一次快照。
    nonisolated(unsafe) private static var themeRefreshPending = false

    @MainActor
    static func scheduleThemeRefresh(delay: TimeInterval = 0.6) {
        guard !themeRefreshPending else { return }
        themeRefreshPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            themeRefreshPending = false
            refreshTheme()
        }
    }
}
