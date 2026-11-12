import SwiftUI
import UIKit
import Foundation

// MARK: - Context-menu preview

/// Opaque rounded-card preview shown under a message's long-press context menu.
///
/// [T-ios-longpress-menu-preview-background] The message cells are hosted with a
/// clear background (host.view / cell backgroundColor = .clear), and the message
/// `.contextMenu`s are attached either to a zero-size `Color.clear` overlay
/// (assistant block/footer) or to a bubble whose fill is the translucent
/// `tertiarySystemFill` (user). Without an explicit `preview:`, SwiftUI snapshots
/// that (transparent) attached view, so the long-press preview platter shows
/// through to the messages below — the reported "transparent preview" bug.
///
/// Supplying this as the `.contextMenu(preview:)` gives the platter an opaque
/// `systemBackground` rounded card with the message text, so it reads as a
/// floating card. System colors only, so dark mode stays correct.
///
/// [T-ios-longpress-preview-full-content-card] The earlier version hard-capped
/// the text at 1500 chars with a trailing "…", which is what users saw as a
/// "truncated" preview on long assistant messages. It now renders the FULL
/// message content inside a vertical ScrollView: short messages size to their
/// content, long ones are capped to a fraction of the screen height and scroll
/// inside the platter (Telegram/iMessage-style), so the preview is both opaque
/// and complete. An explicit measured height is required because a ScrollView
/// has no intrinsic height — without it the context-menu platter would collapse.
struct MessageContextMenuPreview: View {
    let text: String

    /// [T-ios-usermsg-preview-adaptive-width] Width is now a CAP, not a fixed
    /// size. A short user bubble ("ok") previously lifted into a full 360pt
    /// platter; the platter now hugs the laid-out text width (measured by the
    /// same GeometryReader that already measured height) and only long lines
    /// wrap at this cap, iMessage-style.
    private let maxCardWidth: CGFloat = 360
    /// Long messages cap the platter to this fraction of screen height and
    /// scroll inside; short messages size to content (min of the two).
    private var maxCardHeight: CGFloat { UIScreen.main.bounds.height * 0.55 }

    @State private var contentSize: CGSize = .zero

    /// [audit-F4 / T-ios-ctxmenu-preview-watchdog] Hard cap on the characters
    /// handed to the preview's `Text`.
    ///
    /// This platter is a lift-to-peek preview: it is capped to 55% of screen
    /// height and scrolls, so only the first screenful is ever readable. But
    /// the `Text` was given the WHOLE reply, and the `GeometryReader` below
    /// forces SwiftUI to typeset all of it through CoreText — on the main
    /// thread — just to produce `contentSize`. Cost is super-linear in length.
    /// Measured at this exact font (16.5pt) and wrap width (360 - 2*16 = 328pt):
    ///
    ///      4,000 chars   0.25s
    ///      8,000 chars   0.98s
    ///     12,000 chars   1.63s
    ///     20,000 chars   4.50s
    ///     24,000 chars   6.48s     <- the reported 5591ms hang lands here
    ///     30,000 chars  10.14s
    ///     40,000 chars  17.96s
    ///
    /// which is the foreground SIGKILL a long reply once caused: a main-thread
    /// hang in CTLineCreateWithAttributedString → ResolvedStyledText.draw,
    /// watchdog kill, memory normal (not an OOM).
    ///
    /// Note the cost is driven by LENGTH, not by LaTeX: raw LaTeX source
    /// measured FASTER than prose at equal length (40,000 chars of formula
    /// source = 0.178s), because its long unspaced backslash runs produce far
    /// fewer line-break opportunities than CJK, where nearly every character is
    /// a break candidate. Capping the string keeps this flat at ~0.06s for any
    /// input size.
    private static let maxPreviewChars = 2000

    var body: some View {
        let shown = text.isEmpty ? " " : String(text.prefix(Self.maxPreviewChars))
        ScrollView(.vertical, showsIndicators: true) {
            // No `.frame(maxWidth: .infinity)` here — the Text must report its
            // NATURAL width so short messages yield a narrow platter. The wrap
            // width comes from the ScrollView's width (the outer .frame below),
            // which starts at the cap and shrinks to the measured content.
            Text(shown)
                .font(MinisThemeShape.messageFont(size: FontSettings.shared.scaledMessage(16.5)))
                .foregroundStyle(ChatColors.primaryText)
                .multilineTextAlignment(.leading)
                .padding(16)
                .background(
                    // Measure the laid-out text size so the platter can hug
                    // content (short) or cap + wrap/scroll (long).
                    GeometryReader { geo in
                        Color.clear
                            .preference(key: PreviewContentSizeKey.self, value: geo.size)
                    }
                )
        }
        .onPreferenceChange(PreviewContentSizeKey.self) { contentSize = $0 }
        // Size = content size, capped. Falls back to the caps until the first
        // measurement lands so the platter never collapses to zero. The small
        // width floor keeps an (attachment-only) empty-text preview from
        // rendering as a sliver.
        .frame(
            width: contentSize.width > 0 ? min(max(contentSize.width, 60), maxCardWidth) : maxCardWidth,
            height: contentSize.height > 0 ? min(contentSize.height, maxCardHeight) : maxCardHeight
        )
        .modifier(ContextMenuPreviewSurface())
    }
}

/// Background for the long-press preview platter.
///
/// Matches `UserBubbleSurface` so lifting a bubble doesn't jump from Liquid
/// Glass to a flat colour card — the shape (`RoundedRectangle(cornerRadius: 16)`,
/// non-`.continuous`) is deliberately the same one the bubble and the row's
/// `.contentShape(.contextMenuPreview, …)` already use.
///
/// **The opaque base stays.** [T-ios-longpress-menu-preview-background] exists
/// because the platter was showing through to the messages underneath: cells are
/// hosted on a clear background and the menus hang off either a zero-size
/// `Color.clear` overlay or a `tertiarySystemFill` bubble, so SwiftUI's snapshot
/// of the attached view was effectively transparent. Glass is a translucent
/// material, so using it ALONE would risk re-opening exactly that bug. Painting
/// it over `ChatColors.background` keeps the platter opaque no matter what the
/// system composites behind it, while the material still supplies the glass
/// highlight and edge that make it read as continuous with the bubble.
private struct ContextMenuPreviewSurface: ViewModifier {
    private var shape: MinisBubbleShape { MinisThemeShape.userBubble }
    // [glass-switch] The platter's glass follows the global switch.
    @ObservedObject private var appearanceStudio = AppearanceStudio.shared

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *), appearanceStudio.glassEnabled {
            content
                // Opaque floor first — see the note above.
                .background(shape.fill(ChatColors.background))
                .glassEffect(.regular, in: shape)
        } else {
            // Glass off: the opaque floor stays, so the platter never
            // shows through to the messages underneath.
            content.background(shape.fill(ChatColors.background))
        }
    }
}

/// Preference key carrying the laid-out preview text size up to the platter.
/// Background for the user message bubble.
///
/// Two states that must stay tellable apart at a glance:
///
///  - **Sent** (`isQueued == false`) — Liquid Glass on iOS 26+. These bubbles
///    scroll over other messages, images and code blocks, so the material has
///    genuinely varied content to sample; this is the case glass is for, the
///    same as the tool-status bar and unlike `FolderSurface`, which had to fall
///    back to a sampled constant for want of anything behind it.
///  - **Queued** (`isQueued == true`) — deliberately NOT glass, on either OS.
///    Glass reads as a settled, physical surface, which is the opposite of what
///    a not-yet-sent message means. It keeps the existing empty fill + dashed
///    border, so "queued" still looks provisional next to the solid glass of
///    everything already sent.
///
/// The text is the modified content rather than an `.overlay`, which is what
/// keeps it above the material: `.glassEffect` composites the material over the
/// view it modifies, so an overlaid label would be painted underneath it and
/// disappear (the FAB regression).
// [B28 R5] internal（原 private）：装扮页样张复用真气泡皮肤本体 ——
// 平铺/气泡/文稿三形态和 Liquid Glass 判定全在这里，复制=双维护=撒谎。
// MARK: - 正文视图

struct UserMessageText: View {
    let text: String
    let isQueued: Bool
    var isDelivering: Bool = false
    /// [T-user-bubble-plain 11-10] 醒醒：用户气泡不要自动折叠，也不要自动
    /// 把我的话判成代码块。以前这两件事都做，长文折成 8 行要点「展开全文」，
    /// 发一段不像代码的东西（清单、诗歌、带缩进的段落）被判成代码块套上等宽字体
    /// 和灰底。判得准不准都是干扰——用户发的话就照原样显示。
    /// messageId 仍然保留：代码块、链接这些子视图还要用它。
    var messageId: UUID? = nil

    @ObservedObject private var appearanceStudio = AppearanceStudio.shared

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            // [T-user-bubble-plain 11-10 / 11-11] 用户气泡里不认代码块:
            // 不自动判、也不因为她自己写了 ``` 就套成代码卡。
            // 她的话一律照原样全文显示,不折叠、不打码、不换字体。
            // (2026-11-11 她点名:「用户气泡里代码块也不要」——
            //  之前还留着"自己写围栏才当代码"的口子,那条也删了。)
            Text(text)
                .font(MinisThemeShape.messageFont(size: FontSettings.shared.scaledMessage(16.5)))
                .foregroundStyle(isQueued ? ChatColors.secondaryText : ChatColors.bubbleText)
                .fixedSize(horizontal: false, vertical: true)
                .id(appearanceStudio.themePackRevision)
        }
        .padding(.horizontal, AppearanceChatDisplay.parse(
            AppearanceStudio.shared.currentThemePack().chatDisplay) == .bubbles
            ? MinisThemeShape.userPadding : 14)
        .padding(.vertical, 10)
        .modifier(UserBubbleSurface(isQueued: isQueued))
        .modifier(QueuedStatusDot(isQueued: isQueued, isDelivering: isDelivering))
    }
}

/// One meta (time) line, as the pack samples show it: HH:mm,
/// secondary text, same for user and assistant rows.
@MainActor
private func bubbleMetaText(_ date: Date) -> Text {
    Text(BubbleMetaTimeFormatter.shared.string(from: date))
        .font(ChatFont.font(10))
        .foregroundStyle(ChatColors.secondaryText.opacity(0.8))
}

private enum BubbleMetaTimeFormatter {
    static let shared: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()
}

// MARK: - 用户气泡皮肤

struct UserBubbleSurface: ViewModifier {
    let isQueued: Bool

    /// Matches `.contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 16))`
    /// on the row exactly — including the default (non-`.continuous`) corner
    /// style. A `.continuous` bubble against a circular-arc preview clip would
    /// show the corners subtly change shape as the long-press lift begins.
    private var shape: MinisBubbleShape { MinisThemeShape.userBubble }

    func body(content: Content) -> some View {
        // [10-18 醒醒 第五轮] 消息形态：平铺 / 气泡 / 文稿。
        //
        // - `.flat`    不要底色，像聊天记录一样平铺，靠留白分开
        // - `.document` 跟 flat 一样没有底色，但外层还会去掉头像和缩进
        // - `.bubbles` 保持原样
        let display = AppearanceChatDisplay.parse(
            AppearanceStudio.shared.currentThemePack().chatDisplay)
        // [bubble-packs] Row surface: the bubble stretches to the
        // full row width (trailing-aligned) instead of hugging the
        // text. Only in .bubbles mode; flat/document keep hugging.
        let surfaced: AnyView = (display == .bubbles && MinisThemeShape.userSurface == .row)
            ? AnyView(content.frame(maxWidth: .infinity, alignment: .trailing))
            : AnyView(content)

        if isQueued {
            // [10-20 醒醒] 排队消息不再画虚线——她要看的是「真气泡」，
            // 状态交给气泡旁边那颗小圆点（灰=待注入/蓝=送达中/消失=已进上下文）。
            // 底色仍压到 0.72，跟已发送的实心气泡留一线可辨。
            surfaced
                .background(userPackBackground(dim: 0.72))
                .modifier(BubbleBorderChrome(shape: shape, width: MinisThemeShape.userBorderWidth))
                .overlay(BubblePackDecorationsView(decorations: MinisThemeShape.packDecorations(user: true)))
        } else if display == .flat || display == .document {
            surfaced
        } else if #available(iOS 26.0, *) {
            // [T-bubble-opacity-slider][v3 09-10] The slider STILL didn't read
            // on this bubble: `Glass.tint` alpha modulates the material's
            // brightness, not its coverage — at slider 0.2 the tint is pale
            // but the glass itself stays its own translucent white, so the
            // bubble never actually gets more see-through (醒醒: "无法根据我
            // 调整的透明度对应相应的透明度").
            //
            // Fix: the SAME construction the assistant bubble uses — a plain
            // themed fill whose alpha is the slider value (ChatColors.userBubble
            // already carries it), with ONE untinted glass layer OVER the fill
            // for the highlight/edge. Both bubbles now respond to the slider
            // identically: slider = how see-through the coloured surface is.
            // #3 醒醒: 跟 AI 气泡一样，纯实心主题色——去掉 Liquid Glass（玻璃调高亮度刺眼）。
            // 透明度滑杆仍生效（ChatColors.userBubble 自带 alpha）。
            surfaced
                .background(userPackBackground())
                .modifier(BubbleBorderChrome(shape: shape, width: MinisThemeShape.userBorderWidth))
                .overlay(BubblePackDecorationsView(decorations: MinisThemeShape.packDecorations(user: true)))
        } else {
            surfaced
                .background(userPackBackground())
                .modifier(BubbleBorderChrome(shape: shape, width: MinisThemeShape.userBorderWidth))
                .overlay(BubblePackDecorationsView(decorations: MinisThemeShape.packDecorations(user: true)))
        }
    }

    /// [bubble-foundation] The one shared surface for live user
    /// bubbles: solid theme colour, then the applied pack's image
    /// background and pattern, all clipped to the same shape the
    /// shop and detail previews draw. On today's packs every
    /// foundation field is unset, so this is exactly the old solid
    /// fill — the shape.fill call it replaces, plus the image /
    /// pattern layers that are absent until a pack sets them.
    private func userPackBackground(dim: Double = 1) -> some View {
        BubblePackSurfaceBackground(
            shape: shape, colour: ChatColors.userBubble,
            imageFile: MinisThemeShape.packBackgroundImageFile(user: true),
            pattern: MinisThemeShape.packPattern(user: true),
            patternOpacity: MinisThemeShape.packPatternOpacity(user: true),
            textColour: ChatColors.bubbleText, dim: dim)
    }
}

/// [10-20 醒醒] 排队消息的状态点，叠在气泡右上角。
///
/// 用 overlay 而不是塞进 HStack：塞进去会改气泡的可用宽度，
/// 再多一个元素就得同步改量高代码，容易漏。overlay 不参与布局，零风险。
/// 撤回不在气泡边挂按钮了，只走长按菜单（红叉长得像第二个停止键）。
///
/// 灰 = 还在队列里等注入；蓝 = 正在送进上下文；isQueued 翻 false 就整颗消失。
private struct QueuedStatusDot: ViewModifier {
    let isQueued: Bool
    let isDelivering: Bool

    func body(content: Content) -> some View {
        content.overlay(alignment: .topTrailing) {
            if isQueued {
                Circle()
                    .fill(isDelivering
                          ? ChatColors.accent
                          : ChatColors.secondaryText.opacity(0.55))
                    .frame(width: 6, height: 6)
                    .offset(x: 3, y: -3)
                    .accessibilityLabel(isDelivering ? "正在送达" : "等待发送")
            }
        }
    }
}

private struct PreviewContentSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        value = CGSize(width: max(value.width, next.width), height: max(value.height, next.height))
    }
}

// MARK: - Chat Message Row

struct ChatMessageRow: View {
    @ObservedObject var message: ChatMessage
    @ObservedObject private var appearanceStudio = AppearanceStudio.shared
    /// Only the actively streaming message needs vm access (for typing indicator & stop button).
    let isActiveMessage: Bool
    var commandStartTime: Date?
    var onStop: (() -> Void)?
    var onRetry: (() -> Void)?
    var onEdit: (() -> Void)?
    /// [T-ios-delete-from-message] Delete this user message and everything
    /// after it. Only set for non-queued user bubbles when idle.
    var onDeleteFrom: (() -> Void)?
    /// [T-chat-single-delete 10-20] Remove ONLY this message; later messages stay.
    var onDeleteSingle: (() -> Void)?
    var onWithdraw: (() -> Void)?
    var autoRetryAttempt: Int = 0
    var autoRetryCountdown: Int = 0
    /// Attempts the current ladder allows (5, or 10 while the upstream throttles).
    var autoRetryBudget: Int = 0
    var canResume: Bool = false
    var onResume: (() -> Void)?
    var onCompact: (() -> Void)?
    var onCopyScreenshot: (() -> Void)?
    /// Read this whole reply aloud from the start (clears any in-progress TTS).
    /// Wired from AIChatView (which owns the view model). Disabled while the
    /// message is still streaming to avoid fighting the live streaming TTS.
    var onReadAloud: (() -> Void)?
    /// When set, presents the compact summary sheet outside the cell tree (V3).
    /// Falls back to a local .sheet when nil (non-V3 / standalone usage).
    var onShowCompactSummary: ((String) -> Void)?
    /// Triggers AIChatViewModel.revertCompact(). Wired from AIChatView so the
    /// row + sheet stay free of view-model imports.
    var onRevertCompact: (() -> Void)?
    /// [s20] 浏览器接管回调，透传给本行弹出的 ToolLiveSheet（语义同
    /// CellStateBridgeV2 上的同名字段）。nil 时接管按钮不显示（BR-2）。
    var onBrowserTakeover: (() -> Void)?
    var onTakeoverDone: (() -> Void)?
    var browserPool: BrowserTabPool?
    var toolSnapshots: [ToolSnapshotItem] = []
    /// [batch9d / W1C-08] 会话绑定人设 id——气泡名/正则显示按它取；
    /// nil（草稿态/未传）回退全局当前人设。
    var sessionPersonaId: String? = nil
    /// [audit-C1] 本行所属会话 id——回调卡点开详情时随通知带上，
    /// 只让「来源会话」的宿主弹 sheet（分屏/多标签下可能有多个聊天界面活着）。
    /// 由 bridge 在 cell 配置时从 VM 复制（与 sessionPersonaId 同路）。
    var sessionId: String? = nil
    @State private var showUsage = false
    @State private var showCompactSummary = false
    /// [T-ios-delete-from-message] Confirmation gate for the suffix delete.
    @State private var showDeleteFromConfirm = false
    @State private var showDeleteSingleConfirm = false
    /// Two-phase token usage reveal: space expands first, then content fades in.
    @State private var usageContentVisible = false
    /// Row frame in window coordinates — used to gate token-usage tap to bottom zone.
    @State private var rowFrameInWindow: CGRect = .zero
    private let usageTapLogger = AppLogger(category: "UsageTap")
    /// ID of the block currently highlighted after a copy action.
    @State private var highlightedBlockId: UUID?
    /// The tool block whose detail sheet is currently presented.
    /// Lifted out of ToolCapsuleView so ForEach item changes don't reset it.
    @State private var detailBlock: AssistantBlock?
    /// The message whose turn summary drawer is currently presented.
    @State private var turnSheetMessage: ChatMessage?

    /// All text block contents joined, for "Copy All".
    private var fullReplyText: String {
        message.blocks
            .filter { if case .text = $0.kind { return true }; return false }
            .map(\.content)
            .joined(separator: "\n\n")
    }

    /// Full message including tool calls and their results, for clipboard export.
    private var fullMessageText: String {
        var parts: [String] = []
        for block in message.blocks {
            switch block.kind {
            case .text:
                if !block.content.isEmpty { parts.append(block.content) }
            case .shellTool(let command):
                let cmd = command.isEmpty ? block.toolDescription : command
                var s = "$ \(cmd)"
                if !block.content.isEmpty {
                    // content is "$ cmd\noutput…", strip the command line
                    let output = block.content.hasPrefix("$ ") ?
                        String(block.content.drop(while: { $0 != "\n" }).dropFirst()) : block.content
                    if !output.isEmpty { s += "\n\(output)" }
                }
                parts.append(s)
            case .fileReadTool(let path):
                parts.append("Read: \(path)\n\(block.content)")
            case .fileWriteTool(let path):
                parts.append("Write: \(path)\n\(block.content)")
            case .fileEditTool(let path):
                parts.append("Edit: \(path)\n\(block.content)")
            case .browserTool(let action):
                parts.append("Browser: \(action)\n\(block.content)")
            case .readImageTool(let path):
                parts.append("Image: \(path)")
            case .memoryTool(let action):
                parts.append("Memory: \(action)\n\(block.content)")
            case .delegateTool(let t):
                // [batch7] Copy keeps the card's title when it has one; the
                // content is the progress line / result JSON as-is.
                parts.append(t.isEmpty ? "Sub agent:\n\(block.content)" : "\(t):\n\(block.content)")
            case .askUserTool:
                parts.append("Ask user:\n\(block.content)")
            case .genericTool(let name):
                parts.append("\(name)\n\(block.content)")
            case .thinking:
                if !block.content.isEmpty { parts.append("[Thinking]\n\(block.content)") }
            case .info:
                if !block.content.isEmpty { parts.append(block.content) }
            }
        }
        return parts.joined(separator: "\n\n")
    }

    var body: some View {
        switch message.role {
        case .user:
            if message.isSystemReminderOnly {
                EmptyView()
            } else if let callback = message.agentCallback {
                // [audit-C5] The 隐身 / 脉搏-card decision lives INSIDE the cell
                // now (AgentCallbackCellView.isPulsePresentation) — one judgment,
                // shared with the list's height precalc. This branch used to
                // re-decide from the registry, which both duplicated the rule
                // and let a cleared job fall between the two copies.
                AgentCallbackCellView(callback: callback, sessionId: sessionId)
                    .opacity(message.isCompactedHistory ? 0.5 : 1.0)
            } else {
                userRow
                    .opacity(message.isCompactedHistory ? 0.5 : 1.0)
            }
        case .assistant:
            assistantRow
                .opacity(message.isCompactedHistory ? 0.5 : 1.0)
        case .compactDivider:
            compactDividerRow
        case .systemInfo:
            systemDividerRow(icon: message.isCompactLoading ? nil : (message.systemIcon ?? "info.circle.fill"),
                             loading: message.isCompactLoading, compact: false)
        }
    }

    // MARK: Compact Divider Row

    private var compactDividerRow: some View {
        HStack(spacing: 10) {
            VStack { Divider() }
            HStack(spacing: 5) {
                if message.isCompactLoading {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 12, height: 12)
                } else {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                        .font(.system(size: 10))
                }
                Text(message.content)
                    .font(ChatFont.font(12, weight: .medium))
                if !message.isCompactLoading && message.compactSummary != nil {
                    Button {
                        let summary = message.compactSummary ?? ""
                        if let onShowCompactSummary {
                            onShowCompactSummary(summary)
                        } else {
                            showCompactSummary = true
                        }
                    } label: {
                        Image(systemName: "info.circle.fill")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                }
            }
            .foregroundStyle(MinisTheme.secondaryText)
            .lineLimit(1)
            .fixedSize()
            VStack { Divider() }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .sheet(isPresented: $showCompactSummary) {
            CompactSummarySheet(summary: message.compactSummary ?? "", onRevert: onRevertCompact)
        }
    }

    // MARK: System Divider Row

    /// Shared divider-style row for system info messages.
    private func systemDividerRow(icon: String?, loading: Bool, compact: Bool) -> some View {
        HStack(spacing: 10) {
            VStack { Divider() }
            HStack(spacing: 5) {
                if loading {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 12, height: 12)
                } else if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 10))
                }
                Text(message.content)
                    .font(ChatFont.font(12, weight: .medium))
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(MinisTheme.secondaryText)
            // [T-browser-download-ux-v4] No .lineLimit(1).fixedSize() here:
            // fixedSize forced the text to its full ideal width, so a long
            // systemInfo line (e.g. pre-v3 "Downloaded … to /var/minis/… —
            // minis-clone://…" rows persisted in history) overflowed BOTH screen
            // edges from this centered row. layoutPriority keeps the flexible
            // dividers from squeezing the text; past the available width the
            // text wraps (UIKit breaks unspaced tokens like paths/URLs
            // mid-word) instead of clipping.
            .layoutPriority(1)
            VStack { Divider() }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, compact ? 16 : 6)
    }

    // MARK: User Row

    /// User message text with `<user-attached-files>` metadata stripped out.
    private var userDisplayText: String {
        var text = message.content
        if let start = text.range(of: "<user-attached-files>") {
            let end = text.range(of: "</user-attached-files>")
            let endBound = end?.upperBound ?? text.endIndex
            text = String(text[text.startIndex..<start.lowerBound] + text[endBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    private var userRow: some View {
        HStack(alignment: .top, spacing: 10) {
            // Keep the bubble width identical to the original 60pt leading
            // spacer: 12pt breathing room + 10pt gap + avatar (38pt by
            // default, pack avatarSize when a pack is applied).
            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 6) {
                // User-attached files above the text bubble
                if !message.attachments.isEmpty {
                    UserAttachmentList(attachments: message.attachments)
                } else if !message.inputAttachments.isEmpty {
                    // Queued message: show previews from cache before queue drain
                    QueuedAttachmentPreview(attachments: message.inputAttachments)
                }

                // [bubble-packs] Meta (time) and name rows, in the same
                // order the pack samples show them: meta above, then
                // name above, then the bubble, then meta below.
                if MinisThemeShape.userMeta == .above {
                    bubbleMetaText(message.createdAt)
                }
                if MinisThemeShape.userName == .above {
                    Text(appearanceStudio.userDisplayName.isEmpty ? AppLocalized("我") : appearanceStudio.userDisplayName)
                        .font(ChatFont.font(9, weight: .medium))
                        .foregroundStyle(ChatColors.secondaryText)
                }

                if !userDisplayText.isEmpty {
                    let (cleanUserText, stickerMatch) = StickerParser.parseFirst(in: userDisplayText)
                    if let stickerMatch, let sticker = StickerStore.shared.sticker(for: stickerMatch.id) {
                        VStack(alignment: .trailing, spacing: 6) {
                            if !cleanUserText.isEmpty {
                                HStack(spacing: 6) {
                                    Text(cleanUserText)
                                        .font(MinisThemeShape.messageFont(size: FontSettings.shared.scaledMessage(16.5)))
                                        .foregroundStyle(message.isQueued ? ChatColors.secondaryText : ChatColors.bubbleText)
                                        .padding(.horizontal, AppearanceChatDisplay.parse(
                                            AppearanceStudio.shared.currentThemePack().chatDisplay) == .bubbles
                                            ? MinisThemeShape.userPadding : 14)
                                        .padding(.vertical, 10)
                                        .modifier(UserBubbleSurface(isQueued: message.isQueued))
                                        .modifier(QueuedStatusDot(isQueued: message.isQueued,
                                                                  isDelivering: message.isDelivering))
                                        .id(appearanceStudio.themePackRevision)
                                }
                            }
                            StickerThumbnailView(sticker: sticker)
                        }
                    } else if let stickerMatch, StickerStore.shared.isDeleted(id: stickerMatch.id) {
                        VStack(alignment: .trailing, spacing: 6) {
                            if !cleanUserText.isEmpty {
                                HStack(spacing: 6) {
                                    Text(cleanUserText)
                                        .font(MinisThemeShape.messageFont(size: FontSettings.shared.scaledMessage(16.5)))
                                        .foregroundStyle(message.isQueued ? ChatColors.secondaryText : ChatColors.bubbleText)
                                        .padding(.horizontal, AppearanceChatDisplay.parse(
                                            AppearanceStudio.shared.currentThemePack().chatDisplay) == .bubbles
                                            ? MinisThemeShape.userPadding : 14)
                                        .padding(.vertical, 10)
                                        .modifier(UserBubbleSurface(isQueued: message.isQueued))
                                        .modifier(QueuedStatusDot(isQueued: message.isQueued,
                                                                  isDelivering: message.isDelivering))
                                        .id(appearanceStudio.themePackRevision)
                                }
                            }
                            StickerDeletedPlaceholderView()
                        }
                    } else {
                        HStack(spacing: 6) {
                            // [T-user-bubble-plain 11-10] 不再折叠、不再自动判代码块；
                            // 只有她自己写了围栏才当代码显示。
                            UserMessageText(text: userDisplayText,
                                            isQueued: message.isQueued,
                                            isDelivering: message.isDelivering,
                                            messageId: message.id)
                        }
                    }
                }
                // [bubble-packs] Meta below removed: the per-bubble
                // time line under a bubble is gone; only the centred
                // time divider capsule remains.
                // [batch2 / W1A-13] Visible hint when the local write failed —
                // an orphan answer above a vanished question is worse than
                // knowing immediately.
                if message.persistenceFailed {
                    Text("消息未保存到本地")
                        .font(ChatFont.font(11))
                        .foregroundStyle(ChatColors.destructive)
                        .padding(.trailing, 4)
                        .accessibilityLabel("这条消息未保存到本地数据库")
                }
            }
            .modifier(MinisOpenURLHandler())
            .contentShape(Rectangle())
            // [T-ios-usermsg-contextmenu-preview-shape] The hit-test shape above
            // stays a full Rectangle (so the whole row is long-pressable), but
            // the context-menu PREVIEW must clip to the bubble's rounded shape —
            // otherwise the lifted preview shows square corners while the bubble
            // is RoundedRectangle(cornerRadius: 16). iOS 16+ lets us specify the
            // preview clip shape independently from the interaction shape.
            .contentShape(.contextMenuPreview, MinisThemeShape.userBubble)
            .contextMenu {
                Button {
                    UIPasteboard.general.string = message.content
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                if let onCopyScreenshot {
                    Button {
                        onCopyScreenshot()
                    } label: {
                        Label(AppLocalized("Copy Screenshot"), systemImage: "camera.viewfinder")
                    }
                }
                if let onEdit {
                    Button {
                        onEdit()
                    } label: {
                        Label("Edit", systemImage: "square.and.pencil")
                    }
                }
                if let onRetry {
                    Button {
                        onRetry()
                    } label: {
                        Label("Retry", systemImage: "arrow.counterclockwise")
                    }
                }
                // [T-composer-queue-withdraw] 排队消息的撤回只在这里：气泡边
                // 不再挂红叉（长得像第二个停止键）。状态只看气泡右上角那颗
                // 6pt 小圆点（灰=等注入/蓝=送达中）。
                if message.isQueued, let onWithdraw {
                    Button(role: .destructive) {
                        onWithdraw()
                    } label: {
                        Label(AppLocalized("撤回排队消息"), systemImage: "arrow.uturn.backward")
                    }
                }
                if onDeleteFrom != nil || onCompact != nil {
                    Divider()
                }
                // [T-chat-single-delete 10-20] Two distinct deletes, because
                // "delete this message" and "delete everything from here down"
                // are different intentions and used to be one action:
                //   • Delete This Message — removes just this row; the replies
                //     after it stay.
                //   • Delete From Here — removes this row and every message
                //     after it.
                if let onDeleteSingle {
                    Button(role: .destructive) {
                        showDeleteSingleConfirm = true
                    } label: {
                        Label(AppLocalized("Delete This Message"), systemImage: "trash")
                    }
                }
                if onDeleteFrom != nil {
                    Button(role: .destructive) {
                        showDeleteFromConfirm = true
                    } label: {
                        Label("Delete From Here", systemImage: "trash.fill")
                    }
                }
                if let onCompact {
                    Button(role: .destructive) {
                        onCompact()
                    } label: {
                        Label("Compact Above", systemImage: "arrow.down.right.and.arrow.up.left")
                    }
                }
            } preview: {
                // [T-ios-longpress-menu-preview-background] Opaque card so the
                // long-press preview isn't transparent (see MessageContextMenuPreview).
                MessageContextMenuPreview(text: message.content)
            }

            // [bubble-packs] Name in the row (between bubble and
            // avatar, vertically centred by the spacers), and the
            // avatar itself: pack size, and the overlapping placement
            // lifts it 4pt above the bubble top (padding 2 + offset -6),
            // exactly as the sample renders it.
            if MinisThemeShape.userName == .inline {
                VStack {
                    Spacer(minLength: 0)
                    Text(appearanceStudio.userDisplayName.isEmpty ? AppLocalized("我") : appearanceStudio.userDisplayName)
                        .font(ChatFont.font(9, weight: .medium))
                        .foregroundStyle(ChatColors.secondaryText)
                    Spacer(minLength: 0)
                }
            }
            PersonAvatarView(kind: .user, size: MinisThemeShape.avatarSize)
                .padding(.top, 2)
                .offset(y: MinisThemeShape.avatarPlacement == .overlapping ? -6 : 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        // [T-ios-delete-from-message] Suffix deletion is irreversible and takes
        // the following replies with it, so it gets an explicit confirmation
        // rather than firing straight off the menu.
        .alert(AppLocalized("Delete Message?"), isPresented: $showDeleteSingleConfirm) {
            Button(AppLocalized("Cancel"), role: .cancel) {}
            Button(AppLocalized("Delete"), role: .destructive) {
                onDeleteSingle?()
            }
        } message: {
            Text(AppLocalized("Only this message will be deleted. The messages after it stay."))
        }
        .alert(AppLocalized("Delete Message?"), isPresented: $showDeleteFromConfirm) {
            Button(AppLocalized("Cancel"), role: .cancel) {}
            Button(AppLocalized("Delete"), role: .destructive) {
                onDeleteFrom?()
            }
        } message: {
            Text("This message and all messages after it will be deleted. This cannot be undone.")
        }
    }

    // MARK: Assistant Row

    private var assistantRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Assistant label. [bubble-packs] Name hidden hides the
            // name text (avatar stays); name above/inline both show
            // it here — the header is a separate row above the
            // bubbles, so the two placements cannot be distinguished
            // in live chat (see the sample note). Meta above shows
            // the time under the header, before the blocks.
            HStack(spacing: 8) {
                // [问题12] 头像和名字都跟会话绑定的人设走，与人设列表同源。
                PersonAvatarView(kind: .assistant, size: MinisThemeShape.avatarSize,
                                 personaID: SoulStore.displayPersonaId(sessionPersonaId))
                if MinisThemeShape.assistantName != .hidden {
                    AssistantSoulName(personaId: sessionPersonaId)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(ChatColors.primaryText)
                }
                // [醒醒 10-18] 名字旁边的小猫咪去掉了（同 V3 header）。
            }
            .padding(.top, 2)
            if MinisThemeShape.assistantMeta == .above {
                bubbleMetaText(message.createdAt)
            }

            ForEach(TurnSummarySegments.segments(for: message.blocks)) { segment in
                switch segment {
                case .single(let block):
                    AssistantBlockView(
                        block: block,
                    message: message,
                    isActiveMessage: isActiveMessage,
                    commandStartTime: commandStartTime,
                    onStop: onStop,
                    onTapBlank: message.usage != nil ? { windowPoint in
                        // Only respond to taps in the bottom 100pt of the message row
                        let bottomZoneTop = rowFrameInWindow.maxY - 100
                        let inZone = windowPoint.y >= bottomZoneTop
                        usageTapLogger.debug("[usageTap] windowPt=\(String(format: "%.0f,%.0f", windowPoint.x, windowPoint.y)) rowBottom=\(String(format: "%.0f", rowFrameInWindow.maxY)) zoneTop=\(String(format: "%.0f", bottomZoneTop)) inZone=\(inZone) showUsage=\(showUsage)")
                        guard inZone else { return }

                        if showUsage {
                            withAnimation(.easeInOut(duration: 0.15)) { usageContentVisible = false }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                                showUsage = false
                            }
                        } else {
                            showUsage = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                withAnimation(.easeInOut(duration: 0.2)) { usageContentVisible = true }
                            }
                        }
                    } : nil,
                    onCopyScreenshot: onCopyScreenshot,
                    sessionPersonaId: sessionPersonaId,
                    browserPool: browserPool,
                    toolSnapshots: toolSnapshots,
                    highlightedBlockId: $highlightedBlockId,
                    detailBlock: $detailBlock
                )
                case .thinkingTools(let blocks):
                    TurnSummaryRow(
                        message: message,
                        memberIDs: blocks.map(\.id),
                        isWorking: isActiveMessage,
                        onTap: { turnSheetMessage = message }
                    )
                }
            }

            // Typing indicator — "request out, nothing back yet", evaluated per
            // ROUND. See `ChatMessage.shouldShowTypingIndicator`.
            if isActiveMessage && message.shouldShowTypingIndicator {
                TypingIndicator(personaId: sessionPersonaId)
            }

            // Inline error + retry
            if let error = message.error {
                inlineError(error)
            }

            // Resume banner for interrupted sessions
            if canResume && message.error == nil {
                resumeBanner
            }

            // Token usage — two-phase reveal: space expands first, then content fades in
            if message.streamInterruptCount > 0 || showUsage {
                HStack(spacing: 6) {
                    if message.streamInterruptCount > 0 {
                        streamInterruptBadge(message.streamInterruptCount)
                    }
                    if showUsage, let usage = message.usage {
                        usageCapsule(usage)
                            .opacity(usageContentVisible ? 1 : 0)
                    }
                    Spacer()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        // [T-ios-geometry-observer-crash] THE crasher from the v1.8b13 IPS:
        // onChange(of: geo.frame(in: .global)) wrote state inside the
        // geometry-observer path and tripped the async renderer
        // (ViewGraphGeometryObservers.needsUpdate SIGTRAP). onGeometryChange
        // measures the same row bounds the background GeometryReader did,
        // and its initial fire covers the old onAppear seed.
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .global)
        } action: { rowFrameInWindow = $0 }
        .background {
            // Context menu on the background layer so it only fires on
            // blank areas — UITextView link taps in the foreground take priority.
            Color.clear
                .contentShape(Rectangle())
                .contextMenu {
                    // [T-ios-msg-contextmenu-recursion-crash] Gate the eager menu
                    // tree behind an Equatable key so the cell body churn during
                    // `gh`/shell streaming output doesn't rebuild + re-diff the
                    // whole menu subtree every frame — the deep ContextMenuModifier
                    // / UnwrapConditional recursion that blew the update stack into
                    // unmapped heap (incident 98E8805F). Copy actions read
                    // `fullReplyText` lazily at TAP time, so the menu structure
                    // only needs rebuilding when the key changes: which optional
                    // actions exist + the streaming-disabled state.
                    EquatableMenuGate(key: AssistantMenuKey(
                        messageId: message.id,
                        hasReadAloud: onReadAloud != nil,
                        hasCopyScreenshot: onCopyScreenshot != nil,
                        hasCompact: onCompact != nil,
                        isActive: isActiveMessage
                    )) {
                        Button {
                            UIPasteboard.general.string = fullReplyText
                        } label: {
                            Label("Copy All", systemImage: "doc.on.doc")
                        }
                        Button {
                            UIPasteboard.general.string = fullReplyText
                        } label: {
                            Label("Copy Markdown", systemImage: "text.quote")
                        }
                        if let onReadAloud {
                            Button {
                                onReadAloud()
                            } label: {
                                Label(AppLocalized("Read from Start"), systemImage: "play.circle")
                            }
                            // Greyed out while streaming so it can't clash with the
                            // live streaming TTS of the same reply.
                            .disabled(isActiveMessage)
                        }
                        if let onCopyScreenshot {
                            Button {
                                onCopyScreenshot()
                            } label: {
                                Label(AppLocalized("Copy Screenshot"), systemImage: "camera.viewfinder")
                            }
                        }
                        if let onCompact {
                            Divider()
                            Button(role: .destructive) {
                                onCompact()
                            } label: {
                                Label("Compact Above", systemImage: "arrow.down.right.and.arrow.up.left")
                            }
                        }
                    }
                    .equatable()
                } preview: {
                    // [T-ios-longpress-menu-preview-background] Opaque card for
                    // this Color.clear-attached contextMenu (see
                    // MessageContextMenuPreview).
                    MessageContextMenuPreview(text: fullReplyText)
                }
        }
        .sheet(item: $detailBlock) { block in
            ToolLiveSheet(toolBlocks: message.blocks.filter { $0.toolStatus != nil },
                          initialIdx: message.blocks.filter({ $0.toolStatus != nil }).firstIndex(where: { $0.id == block.id }) ?? 0,
                          toolSnapshots: toolSnapshots, browserPool: browserPool,
                          onBrowserTakeover: onBrowserTakeover,
                          onTakeoverDone: onTakeoverDone)
        }
        .sheet(item: $turnSheetMessage) { msg in
            TurnDetailSheet(
                message: msg,
                toolSnapshots: toolSnapshots,
                browserPool: browserPool,
                onExpandBrowser: nil,
                onBrowserTakeover: onBrowserTakeover,
                onTakeoverDone: onTakeoverDone
            )
            .presentationDetents([.fraction(2/3), .large])
            .presentationDragIndicator(.visible)
        }
    }

    @ViewBuilder
    private func usageCapsule(_ usage: TokenUsage) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "speedometer")
                .font(.system(size: 9))
            Text(usageSummary(usage))
                .font(ChatFont.font(10, design: .monospaced))
        }
        .foregroundStyle(ChatColors.tertiaryText)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(ChatColors.chipBg)
        .clipShape(Capsule())
        .transition(.opacity.combined(with: .scale(scale: 0.8)))
    }

    @ViewBuilder
    private func streamInterruptBadge(_ count: Int) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 9, weight: .semibold))
            Text("\(count)")
                .font(ChatFont.font(10, design: .monospaced))
        }
        .foregroundStyle(ChatColors.warning.opacity(0.8))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(ChatColors.warning.opacity(0.12))
        .clipShape(Capsule())
    }

    private func usageSummary(_ u: TokenUsage) -> String {
        var parts: [String] = []
        if u.latestContextTokens > 0 {
            parts.append("ctx:\(formatTokenCount(u.latestContextTokens))")
        }
        parts.append("in:\(formatTokenCount(u.inputTokens))")
        parts.append("out:\(formatTokenCount(u.outputTokens))")
        if u.cacheReadTokens > 0 {
            parts.append("cache:\(formatTokenCount(u.cacheReadTokens))")
        }
        if u.cacheCreationTokens > 0 {
            parts.append("+cache:\(formatTokenCount(u.cacheCreationTokens))")
        }
        return parts.joined(separator: " ")
    }

    private func formatTokenCount(_ count: Int) -> String {
        if count >= 1000 {
            let k = Double(count) / 1000.0
            return k.truncatingRemainder(dividingBy: 1) == 0
                ? "\(Int(k))k"
                : String(format: "%.1fk", k)
        }
        return "\(count)"
    }

    @ViewBuilder
    private func inlineError(_ error: String) -> some View {
        HStack(alignment: .center, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(ChatColors.destructive)
                Text(error)
                    .font(.caption)
                    .foregroundStyle(ChatColors.destructive)
                    .lineLimit(2)
            }
            .contentShape(Rectangle())
            .contextMenu {
                Button {
                    UIPasteboard.general.string = error
                } label: {
                    Label(AppLocalized("Copy Error"), systemImage: "doc.on.doc")
                }
            }

            Spacer()

            if autoRetryAttempt > 0 {
                Text("Retry in \(autoRetryCountdown)s (\(autoRetryAttempt)/\(autoRetryBudget > 0 ? autoRetryBudget : AIChatViewModel.retryDelays.count))")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(MinisTheme.secondaryText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(Capsule())
            } else if let onRetry {
                Button(action: onRetry) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption.weight(.semibold))
                        Text("Retry")
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(ChatColors.primaryText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(ChatColors.primaryText.opacity(0.15))
                    .clipShape(Capsule())
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ChatColors.destructive.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var resumeBanner: some View {
        HStack(alignment: .center, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "pause.circle.fill")
                    .font(.caption)
                    .foregroundStyle(ChatColors.warning)
                Text("Interrupted — tap Resume to continue")
                    .font(.caption)
                    .foregroundStyle(ChatColors.secondaryText)
            }

            Spacer()

            if let onResume {
                Button(action: onResume) {
                    HStack(spacing: 4) {
                        Image(systemName: "play.fill")
                            .font(.caption.weight(.semibold))
                        Text("Resume")
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(ChatColors.primaryText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(ChatColors.warning)
                    .clipShape(Capsule())
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ChatColors.warning.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // [T-ios-typing-indicator-scope] The local `hasVisibleContent` that used to
    // live here is gone: the typing indicator's predicate now has exactly one
    // definition, `ChatMessage.shouldShowTypingIndicator`. Keeping a private
    // copy per view is what let the four call sites drift apart in the first
    // place.
}


