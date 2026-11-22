import ActivityKit
import SwiftUI
import UIKit
import WidgetKit

// MARK: - 活动卡配色（[theme-vars 11-22]）

/// 活动卡（灵动岛 + 锁屏）的取色器。
///
/// 这两个界面跑在小组件扩展里，读不到主 App 的 `AppearanceStudio`。以前它们
/// 整片写死 `.white.opacity(0.15)` / `.green` / `.blue` / `.secondary`：主题
/// 换了一套，App 里全变了，活动卡还是老样子。
///
/// 现在主题色随 `ContentState` 一起推过来（见 `AgentLiveActivityManager
/// .withThemePalette`），这个结构体只负责「按当前明暗挑一套、查不到就回落到
/// 系统语义色」——回落保证老版本推来的 ContentState（没有这两个字段）在
/// 升级后照常显示，不会变成一片黑。
@available(iOSApplicationExtension 16.2, *)
struct LiveActivityPalette {
    private let light: [String: String]
    private let dark: [String: String]

    init(state: AgentActivityAttributes.ContentState) {
        light = state.themeLight ?? [:]
        dark = state.themeDark ?? [:]
    }

    /// 明暗两套都交给系统，由 `UIColor` 的动态 provider 在渲染时按当前
    /// trait 解析。
    ///
    /// 为什么不在 init 里读 `UITraitCollection.current` 直接挑一套：灵动岛和
    /// 锁屏的内容是在 ViewBuilder 闭包里拼的，那里拿不到 `@Environment`，
    /// 而 `UITraitCollection.current` 在闭包求值时未必已经是卡片所在环境的
    /// 外观，读出来可能是系统默认值——深色锁屏上配浅色文字。动态 provider
    /// 由系统在真正绘制时逐次解析，不存在这个时机问题。
    private func color(_ role: String, lightFallback: Color) -> Color {
        let l = light[role].flatMap { $0.isEmpty ? nil : $0 }
        let d = dark[role].flatMap { $0.isEmpty ? nil : $0 }
        // 两套都没有（老版本推来的 ContentState）：原样用回退色，
        // SwiftUI 的语义色自己会跟着明暗走。
        guard l != nil || d != nil else { return lightFallback }
        return Color(UIColor { trait in
            let hex = trait.userInterfaceStyle == .dark ? (d ?? l) : (l ?? d)
            return UIColor(liveHex: hex ?? "")
        })
    }

    var accent: Color { color("accent", lightFallback: .blue) }
    var primaryText: Color { color("primaryText", lightFallback: .primary) }
    var secondaryText: Color { color("secondaryText", lightFallback: .secondary) }
    /// `Color.tertiary` 不存在（那是 ShapeStyle），用 secondary 淡一档代替。
    var tertiaryText: Color { color("tertiaryText", lightFallback: .secondary.opacity(0.7)) }
    var success: Color { color("success", lightFallback: .green) }
    /// 胶囊底。快照里没有就退回系统自带的填充，而不是写死的白 15%。
    var chipFill: Color { color("chip", lightFallback: Color.primary.opacity(0.08)) }
    /// [theme-vars 11-23] 锁屏卡的底。回落 `.clear`：老 ContentState 没有这个
    /// 角色时保持系统原本的材质，不糊一块黑上去。
    var canvas: Color { color("canvas", lightFallback: .clear) }
}

@available(iOSApplicationExtension 16.2, *)
private extension UIColor {
    /// #RRGGBB → UIColor。
    ///
    /// `AgentProfileWidget.swift` 里那份 `Color(hex:)` 是 `private extension`，
    /// 文件级可见，这个文件用不到，所以这里另写一个 `liveHex`（名字不同，
    /// 不会撞）。解析规则跟它保持一致：去掉 `#`，扫十六进制，扫不出来就是黑。
    convenience init(liveHex: String) {
        let cleaned = liveHex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        self.init(red: CGFloat((value >> 16) & 0xFF) / 255.0,
                  green: CGFloat((value >> 8) & 0xFF) / 255.0,
                  blue: CGFloat(value & 0xFF) / 255.0,
                  alpha: 1)
    }
}

@available(iOSApplicationExtension 16.2, *)
struct AgentLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AgentActivityAttributes.self) { context in
            AgentLockScreenView(
                attributes: context.attributes,
                state: context.state
            )
        } dynamicIsland: { context in
            // [theme-vars 11-22] 整片活动卡的取色器。以前这里的绿勾、蓝图标、
            // 白 15% 胶囊底全是写死的，主题换了它们不动。
            let palette = LiveActivityPalette(state: context.state)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 3) {
                        Image(systemName: "sparkles")
                            .font(.caption2)
                        Text(context.state.soulName.isEmpty ? "嘟嘟" : context.state.soulName)
                            .font(.caption.bold())
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(palette.chipFill, in: Capsule())
                    .padding(.leading, 8)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if context.state.allCompleted {
                        HStack(spacing: 3) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(palette.success)
                            Text("\(context.state.sessions.count)")
                                .font(.caption.bold())
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(palette.success.opacity(0.18), in: Capsule())
                        .padding(.trailing, 8)
                    } else {
                        HStack(spacing: 3) {
                            Text("\(context.state.activeSessionCount)")
                                .font(.caption.bold())
                                .contentTransition(.numericText())
                            Text(context.state.activeSessionCount == 1 ? "session" : "sessions")
                                .font(.caption.bold())
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(palette.chipFill, in: Capsule())
                        .padding(.trailing, 8)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if let session = context.state.currentSession {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 0) {
                                Image(systemName: "bubble.left.fill")
                                    .font(.caption)
                                    .foregroundStyle(palette.accent)
                                    .padding(.trailing, 5)
                                Text(session.title)
                                    .font(.callout.bold())
                                    .lineLimit(1)
                                if context.state.activeSessionCount > 1 {
                                    Text("\(context.state.carouselIndex + 1)/\(context.state.activeSessionCount)")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(palette.tertiaryText)
                                        .padding(.leading, 4)
                                }
                                Spacer(minLength: 6)
                                // [T-ios-live-activity-soft-finish] Hide the
                                // running timer once the task is completed — the
                                // soft-finished state is a resting view, so the
                                // .timer must stop ticking (it kept counting up
                                // even after "Completed" showed). Matches the Lock
                                // Screen view's guard.
                                if !session.isCompleted {
                                    Text("00:00")
                                        .font(.caption2.monospacedDigit())
                                        .hidden()
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .overlay {
                                            Text(context.attributes.startDate, style: .timer)
                                                .font(.caption2.monospacedDigit())
                                                .multilineTextAlignment(.center)
                                                .foregroundStyle(palette.secondaryText)
                                        }
                                        .background(palette.chipFill, in: Capsule())
                                } else if let finishedAt = context.state.finishedAt {
                                    // [T-ios-live-activity-privacy-duration]
                                    // Resting state: static total run time in
                                    // the slot the live timer occupied.
                                    Text(totalRunTime(from: context.attributes.startDate, to: finishedAt))
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(palette.secondaryText)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(palette.chipFill, in: Capsule())
                                }
                            }
                            if session.isCompleted {
                                HStack(alignment: .top, spacing: 5) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.caption)
                                        .foregroundStyle(palette.success)
                                    if !session.lastMessage.isEmpty {
                                        Text(session.lastMessage)
                                            .font(.caption)
                                            .foregroundStyle(palette.secondaryText)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    // [T-ios-live-activity-privacy-mode] Loop count is
                                    // agent activity metadata — hidden in Privacy Mode.
                                    if !context.state.privacyMode {
                                        Text("Loop \(session.loopIteration)")
                                            .font(.caption2.monospacedDigit())
                                            .foregroundStyle(palette.tertiaryText)
                                    }
                                }
                            } else {
                                HStack(spacing: 5) {
                                    Image(systemName: session.toolIcon)
                                        .font(.caption)
                                        .foregroundStyle(palette.accent)
                                        .id(session.toolIcon)
                                        .transition(.opacity.animation(.easeInOut(duration: 0.35)))
                                    Text(session.toolStatus)
                                        .font(.caption)
                                        .foregroundStyle(palette.secondaryText)
                                        .lineLimit(1)
                                        .contentTransition(.interpolate)
                                    Spacer()
                                    if !context.state.privacyMode {
                                        Text("Loop \(session.loopIteration)")
                                            .font(.caption2.monospacedDigit())
                                            .foregroundStyle(palette.tertiaryText)
                                    }
                                }
                            }
                        }
                        .padding(.leading, 8)
                        .padding(.trailing, 8)
                        .padding(.top, 4)
                    }
                }
            } compactLeading: {
                HStack(spacing: 3) {
                    Image(systemName: "list.bullet.circle")
                        .font(.callout)
                    Text("\(context.state.activeSessionCount)")
                        .font(.callout.bold())
                        .contentTransition(.numericText())
                }
            } compactTrailing: {
                CompactTrailingView(state: context.state)
            } minimal: {
                MinimalIconView(state: context.state)
            }
        }
    }
}

// MARK: - Audio Toggle Pill (T-ios-live-activity-audio-toggle)

/// Small capsule matching the Agent-identity pill's styling, showing the current
/// play/pause state of the app's audio narration. On iOS 17+ it's an interactive
/// `Button(intent:)` that toggles playback without opening the app; on iOS 16.x
/// (no `Button(intent:)` in Live Activities) it degrades to a status-only glyph.
@available(iOSApplicationExtension 16.2, *)
struct AudioTogglePill: View {
    let isPlaying: Bool
    /// [theme-vars 11-22] 活动卡的取色器。必填：两个调用点都在活动卡里，
    /// 留一个可选默认值只会让人以为还有第三条路。
    let palette: LiveActivityPalette

    private var glyph: some View {
        // Speaker glyphs, not the generic transport play/pause pair: this control
        // governs SPEECH (read-aloud), and a speaker reads as "voice" where
        // play/pause reads as "media player". State-indicating (what IS happening),
        // matching how Apple's own audio controls behave — wave = currently
        // speaking, slash = muted/paused.
        Image(systemName: isPlaying ? "speaker.wave.2.fill" : "speaker.slash.fill")
            .font(.caption2.bold())
            .foregroundStyle(palette.primaryText)
            // The two speaker glyphs have different intrinsic widths (the wave
            // variant is wider), so a fixed 16pt box would clip one of them and
            // make the capsule jump on toggle. Give it room and center.
            .frame(width: 20, height: 16)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(palette.chipFill, in: Capsule())
            // Swap the glyph with a fade so the icon flips smoothly when the
            // toggle intent lands. `.id` forces the transition per state.
            .id(isPlaying)
            .transition(.opacity.animation(.easeInOut(duration: 0.2)))
    }

    var body: some View {
        if #available(iOSApplicationExtension 17.0, *) {
            Button(intent: AudioTogglePlaybackIntent()) {
                glyph
            }
            .buttonStyle(.plain)
        } else {
            glyph
        }
    }
}

// MARK: - Lock Screen View

@available(iOSApplicationExtension 16.2, *)
struct AgentLockScreenView: View {
    let attributes: AgentActivityAttributes
    let state: AgentActivityAttributes.ContentState

    /// [theme-vars 11-22] 锁屏卡整片的取色器。
    private var palette: LiveActivityPalette { LiveActivityPalette(state: state) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                HStack(spacing: 3) {
                    Image(systemName: "sparkles")
                        .font(.caption2)
                    Text(state.soulName.isEmpty ? "嘟嘟" : state.soulName)
                        .font(.caption.bold())
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(palette.chipFill, in: Capsule())
                // [T-ios-live-activity-audio-toggle] Audio play/pause control on
                // the Lock Screen too, beside the identity capsule.
                if state.isAudioLoaded {
                    AudioTogglePill(isPlaying: state.isAudioPlaying, palette: palette)
                }
                Spacer()
                // [T-ios-live-activity-status-summary] Text-only progress.
                //
                // The green checkmark that used to sit here duplicated the one
                // already drawn on each completed task row below (see
                // `session.isCompleted` further down) — same glyph, same
                // colour, ~40pt apart. The row icon is the one that carries
                // per-task meaning, so this badge drops the icon and keeps only
                // the count, which is the thing the row cannot show.
                //
                // The capsule tint still distinguishes the two states, so
                // removing the glyph costs no information.
                if state.allCompleted {
                    Text(doneSummary(state.sessions.count))
                        .font(.caption.bold())
                        .contentTransition(.numericText())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(palette.success.opacity(0.18), in: Capsule())
                } else {
                    Text(doingSummary(state.activeSessionCount))
                        .font(.caption.bold())
                        .contentTransition(.numericText())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(palette.chipFill, in: Capsule())
                }
            }

            if let session = state.currentSession {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        Image(systemName: "bubble.left.fill")
                            .font(.caption)
                            .foregroundStyle(palette.accent)
                        Text(session.title)
                            .font(.subheadline.bold())
                            .lineLimit(1)
                        if state.activeSessionCount > 1 {
                            Text("\(state.carouselIndex + 1)/\(state.activeSessionCount)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(palette.tertiaryText)
                        }
                        Spacer(minLength: 6)
                        if !session.isCompleted {
                            Text("00:00")
                                .font(.caption2.monospacedDigit())
                                .hidden()
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .overlay {
                                    Text(attributes.startDate, style: .timer)
                                        .font(.caption2.monospacedDigit())
                                        .multilineTextAlignment(.center)
                                        .foregroundStyle(palette.secondaryText)
                                }
                                .background(palette.chipFill, in: Capsule())
                        } else if let finishedAt = state.finishedAt {
                            // [T-ios-live-activity-privacy-duration] Static
                            // total run time in the resting state.
                            Text(totalRunTime(from: attributes.startDate, to: finishedAt))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(palette.secondaryText)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(palette.chipFill, in: Capsule())
                        }
                    }
                    if session.isCompleted {
                        HStack(alignment: .top, spacing: 5) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(palette.success)
                            if !session.lastMessage.isEmpty {
                                Text(session.lastMessage)
                                    .font(.caption)
                                    .foregroundStyle(palette.secondaryText)
                                    .lineLimit(1)
                            }
                        }
                    } else {
                        HStack(spacing: 5) {
                            Image(systemName: session.toolIcon)
                                .font(.caption)
                                .foregroundStyle(palette.accent)
                                .id(session.toolIcon)
                                .transition(.opacity.animation(.easeInOut(duration: 0.35)))
                            Text(session.toolStatus)
                                .font(.caption)
                                .foregroundStyle(palette.secondaryText)
                                .lineLimit(1)
                                .contentTransition(.interpolate)
                            Spacer()
                            // [T-ios-live-activity-privacy-mode] Hide loop count.
                            if !state.privacyMode {
                                Text("Loop \(session.loopIteration)")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(palette.tertiaryText)
                            }
                        }
                    }
                }
            }
        }
        .padding()
        // [theme-vars 11-23] 锁屏卡的底跟着主题走。只铺一层半透明的主题
        // 画布色，让系统的玻璃材质还透得出来——整块实心会把 iOS 自己的
        // 卡片质感盖死，锁屏上一眼就是贴上去的。
        .background(palette.canvas.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

// MARK: - Minimal Icon (multi-Activity collapsed state)

/// When several Live Activities collapse into per-app minimal dots, this is the
/// single icon iOS shows for ours. It alternates each refresh between the
/// most-recently-invoked tool's icon and the session-count badge, so the user
/// gets both "what's running right now" and "how many tasks" over time.
@available(iOSApplicationExtension 16.2, *)
struct MinimalIconView: View {
    let state: AgentActivityAttributes.ContentState

    var body: some View {
        // [theme-vars 11-22] 工具图标原来写死 `.blue`。
        let palette = LiveActivityPalette(state: state)
        if state.minimalShowsTool && !state.latestToolIcon.isEmpty {
            Image(systemName: state.latestToolIcon)
                .font(.caption)
                .foregroundStyle(palette.accent)
                .id(state.latestToolIcon)
                .transition(.opacity.animation(.easeInOut(duration: 0.35)))
        } else {
            ZStack {
                Image(systemName: "list.bullet.circle")
                    .font(.caption)
                Text("\(state.activeSessionCount)")
                    .font(.system(size: 7, weight: .bold).monospacedDigit())
                    .offset(x: 6, y: -6)
            }
        }
    }
}

// MARK: - Compact Trailing

@available(iOSApplicationExtension 16.2, *)
struct CompactTrailingView: View {
    let state: AgentActivityAttributes.ContentState

    var body: some View {
        let icon = state.currentSession?.toolIcon ?? "ellipsis.circle"
        // [theme-vars 11-22] 同上。
        let palette = LiveActivityPalette(state: state)
        return Image(systemName: icon)
            .font(.body)
            .foregroundStyle(palette.accent)
            .id(icon)
            .transition(.opacity.animation(.easeInOut(duration: 0.35)))
    }
}

// MARK: - Duration formatting

/// [T-ios-live-activity-privacy-duration] Static "total run time" string for
/// the completed resting state (e.g. "3m 12s", "1h 5m"). System formatter →
/// localized unit abbreviations without any catalog dependency.
@available(iOSApplicationExtension 16.2, *)
func totalRunTime(from start: Date, to end: Date) -> String {
    let formatter = DateComponentsFormatter()
    let interval = end.timeIntervalSince(start)
    formatter.allowedUnits = interval >= 3600 ? [.hour, .minute] : [.minute, .second]
    formatter.unitsStyle = .abbreviated
    return formatter.string(from: max(0, interval)) ?? ""
}

// MARK: - ContentState helpers

@available(iOS 16.2, *)
extension AgentActivityAttributes.ContentState {
    var currentSession: LiveSessionSnapshot? {
        guard !sessions.isEmpty else { return nil }
        let idx = carouselIndex % sessions.count
        return sessions[idx]
    }

    var distinctToolIcons: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for s in sessions {
            if seen.insert(s.toolIcon).inserted {
                result.append(s.toolIcon)
            }
        }
        return result
    }
}

// MARK: - Status summary text

// [T-ios-live-activity-status-summary] The Lock Screen badge's progress text.
//
// Whole-phrase keys, not "\(n) " + a separate word. English puts the count
// first ("2 doing") and Chinese puts it last ("进行中 2"), so a
// number-plus-noun concatenation cannot express both — the count has to be an
// argument inside the localized string, letting each locale place it.
//
// `String.LocalizedStringResource` (not `String(localized:)`) because this runs
// in the widget extension: it resolves against the extension's own bundle at
// render time, which is what lets a Live Activity follow the device language.
//
// Plurals are handled by the catalog's plural rules rather than a Swift
// ternary, so a locale with more than two forms (ru has three) is expressible
// without touching this code.

/// "1 done" / "3 done" — English; "已完成 1" — Chinese.
@available(iOS 16.2, *)
private func doneSummary(_ count: Int) -> String {
    String(localized: "live_activity.status.done",
           defaultValue: "\(count) done",
           comment: "Lock Screen Live Activity badge: how many agent tasks finished. The number may be placed wherever the language needs it.")
}

/// "1 doing" / "2 doing" — English; "进行中 2" — Chinese.
@available(iOS 16.2, *)
private func doingSummary(_ count: Int) -> String {
    String(localized: "live_activity.status.doing",
           defaultValue: "\(count) doing",
           comment: "Lock Screen Live Activity badge: how many agent tasks are still running. The number may be placed wherever the language needs it.")
}
