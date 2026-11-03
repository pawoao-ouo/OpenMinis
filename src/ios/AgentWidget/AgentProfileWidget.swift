import WidgetKit
import SwiftUI
import Foundation

/// [B28 R13] 主屏小组件:把「她是谁 / AI 叫什么」摊在桌面上。
///
/// 数据来自 App Group 容器:主 App 写 `profile-widget.json`(称呼和最近
/// 一句,见 WidgetProfileBridge)和 `theme-widget.json`(主题快照,见
/// WidgetProfileBridge.refreshTheme)。小组件不读主 App 沙盒,也不自己
/// 解析 SOUL.md——那一层逻辑留在主 App,这里只负责显示。
///
/// [T-08] 上一版小组件在代码里写死 `#D4778B`,而且 profile-widget.json
/// 里根本没有 accent 这个键(主 App 从来没写过),所以 `?? fallback` 永远
/// 走 fallback:改主题、换强调色,桌面纹丝不动。现在强调色、文字色和底
/// 色都从主题快照读,读不到才回落到系统语义色(首次启动、还没写过快照
/// 时保持原来的样子)。
///
/// [T-09] 字号档也在同一份快照里。以前 15/11/16pt 全写死,App 里把字号
/// 拨大,桌面还是小字。
struct AgentProfileEntry: TimelineEntry {
    let date: Date
    let assistantName: String
    let userName: String
    let line: String
    let theme: WidgetTheme

    var accentHex: String? { theme.accentHex }
}

/// [T-08][T-09] 小组件侧的主题读取器。明暗两套都在快照里,按小组件自己
/// 的 colorScheme 挑一套——桌面可能和 App 当前明暗不一样,不能跟 App 走。
struct WidgetTheme: Equatable {
    /// 字号档 = 全局点号 ÷ 13pt,默认档正好 1.0。
    var fontScale: CGFloat = 1
    private var light: [String: String] = [:]
    private var dark: [String: String] = [:]

    /// 没写快照时的回落:强调色沿用老常量,其余走系统语义色。
    static let fallbackAccent = "#D4778B"

    static let empty = WidgetTheme()

    init() {}

    init(json: [String: Any]) {
        if let scale = json["fontScale"] as? Double, scale > 0 {
            fontScale = CGFloat(scale)
        } else if let scale = json["fontScale"] as? NSNumber {
            fontScale = CGFloat(scale.doubleValue)
        }
        light = json["light"] as? [String: String] ?? [:]
        dark = json["dark"] as? [String: String] ?? [:]
    }

    /// 快照里某个角色在当前外观下的 16 进制值;没有就是 nil(调用方回落到
    /// 系统语义色,而不是硬编一个可能和主题冲突的颜色)。
    func hex(_ role: String, dark isDark: Bool) -> String? {
        let map = isDark ? dark : light
        guard let value = map[role], !value.isEmpty else { return nil }
        return value
    }

    func accentHex(dark isDark: Bool) -> String {
        hex("accent", dark: isDark) ?? Self.fallbackAccent
    }

    /// 快照里的字号档 × 设计基准。默认档是恒等。
    func size(_ base: CGFloat) -> CGFloat { base * fontScale }
}

struct AgentProfileProvider: TimelineProvider {
    private let appGroup = "group.com.openminis.clone"

    private func payload() -> (String, String, String) {
        let fallback = ("小助手", "你", "今天还没聊")
        guard let url = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent("profile-widget.json"),
              let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return fallback }
        return (obj["assistant"] ?? fallback.0,
                obj["user"] ?? fallback.1,
                obj["line"] ?? fallback.2)
    }

    private func theme() -> WidgetTheme {
        guard let url = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent("theme-widget.json"),
              let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .empty }
        return WidgetTheme(json: obj)
    }

    private func entry() -> AgentProfileEntry {
        let p = payload()
        return AgentProfileEntry(date: Date(), assistantName: p.0, userName: p.1,
                                 line: p.2, theme: theme())
    }

    func placeholder(in context: Context) -> AgentProfileEntry {
        AgentProfileEntry(date: Date(), assistantName: "小助手", userName: "你",
                          line: "今天还没聊", theme: .empty)
    }

    func getSnapshot(in context: Context, completion: @escaping (AgentProfileEntry) -> Void) {
        completion(entry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<AgentProfileEntry>) -> Void) {
        // 半小时一刷:主 App 改档案/改主题时会主动 reload,这里是兜底。
        let next = Calendar.current.date(byAdding: .minute, value: 30, to: Date()) ?? Date().addingTimeInterval(1800)
        completion(Timeline(entries: [entry()], policy: .after(next)))
    }
}

struct AgentProfileWidget: Widget {
    let kind = "AgentProfileWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: AgentProfileProvider()) { entry in
            AgentProfileWidgetView(entry: entry)
        }
        .configurationDisplayName("她和我")
        .description("把称呼和最近一句摊在桌面上")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct AgentProfileWidgetView: View {
    let entry: AgentProfileEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var colorScheme

    private var isDark: Bool { colorScheme == .dark }

    /// 强调色:快照给了就用,没给就回落到老常量。文字和底色没给就用系统
    /// 语义色,自动适应明暗。
    private var accent: Color { Color(hex: entry.theme.accentHex(dark: isDark)) }
    private var textPrimary: Color {
        entry.theme.hex("primaryText", dark: isDark).map { Color(hex: $0) } ?? .primary
    }
    private var textSecondary: Color {
        entry.theme.hex("secondaryText", dark: isDark).map { Color(hex: $0) } ?? .secondary
    }
    private var background: Color {
        entry.theme.hex("canvas", dark: isDark).map { Color(hex: $0) }
            ?? Color(uiColor: .secondarySystemGroupedBackground)
    }
    private func size(_ base: CGFloat) -> CGFloat { entry.theme.size(base) }

    var body: some View {
        Group {
            if family == .systemSmall {
                VStack(alignment: .leading, spacing: 6) {
                    Text(entry.assistantName)
                        .font(.system(size: size(15), weight: .bold))
                        .foregroundStyle(textPrimary)
                        .lineLimit(1)
                    Text(entry.userName)
                        .font(.system(size: size(11), weight: .medium))
                        .foregroundStyle(accent)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(entry.line)
                        .font(.system(size: size(11)))
                        .foregroundStyle(textSecondary)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                HStack(alignment: .top, spacing: 12) {
                    Circle()
                        .fill(accent.opacity(0.18))
                        .frame(width: size(34), height: size(34))
                        .overlay(
                            Image(systemName: "sparkles")
                                .font(.system(size: size(15), weight: .semibold))
                                .foregroundStyle(accent)
                        )
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.assistantName)
                            .font(.system(size: size(16), weight: .bold))
                            .foregroundStyle(textPrimary)
                            .lineLimit(1)
                        Text(entry.userName)
                            .font(.system(size: size(11), weight: .medium))
                            .foregroundStyle(accent)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Text(entry.line)
                            .font(.system(size: size(11)))
                            .foregroundStyle(textSecondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .padding(14)
        .modifier(WidgetBackgroundCompat(color: background))
    }
}

/// iOS 17 的 containerBackground 必须加,否则桌面显示"无法加载";
/// 16.x 上退回普通背景。
private struct WidgetBackgroundCompat: ViewModifier {
    /// [T-08] 底色改成从主题快照传进来的一层;拿不到快照时仍然是原来的
    /// 系统分组底。
    let color: Color

    func body(content: Content) -> some View {
        if #available(iOSApplicationExtension 17.0, *) {
            content.containerBackground(for: .widget) { color }
        } else {
            content.background(color)
        }
    }
}

private extension Color {
    /// #RRGGBB → Color。小组件里没有主 App 那套主题对象,自己解一下。
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        let r = Double((value >> 16) & 0xFF) / 255.0
        let g = Double((value >> 8) & 0xFF) / 255.0
        let b = Double(value & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }
}
