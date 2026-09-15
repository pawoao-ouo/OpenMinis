import SwiftUI

// MARK: - Process Drawer [T-process-drawer 09-15]
//
// The "process row" is the single inline entry an assistant turn renders for
// ALL its process content (thinking + every tool call). While the turn runs
// it shows a live one-liner of what the agent is doing right now; when done
// it collapses to "Completed · Thought & acted · 38s". Tapping it opens the
// process drawer (a detented sheet with the step list).
//
// Tapping a step opens that step's FULL content as a stacked sheet on top of
// the drawer: thinking → full text; any tool → the existing ToolLiveSheet,
// reused verbatim (its own chrome, browser takeover, snapshots — zero
// reimplementation). A thinking-only turn skips the list and opens straight
// to the full text.
//
// Colors go through ChatColors / MinisThemeShape (the AppearanceStudio token
// system) — no hardcoded hexes anywhere in this file.

// MARK: Process row (inline, one line)

struct ProcessRowView: View {
    @ObservedObject var message: ChatMessage
    var isActiveMessage: Bool
    var onOpen: (() -> Void)?

    private var running: Bool {
        isActiveMessage && message.isTurnActive
    }

    var body: some View {
        Button {
            onOpen?()
        } label: {
            HStack(spacing: 8) {
                if running {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(ChatColors.accent)
                    if message.isThinkingNow {
                        Text(AppLocalized("Thinking"))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(MinisThemeShape.thinkingAccent)
                        if let chars = thinkingCharCount {
                            Text("\(chars)")
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(MinisThemeShape.thinkingAccent.opacity(0.6))
                        }
                    } else if let live = message.liveProcessText {
                        Text(live)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(ChatColors.primaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Text(AppLocalized("Running"))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(ChatColors.accent)
                    }
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(ChatColors.success)
                    Text(AppLocalized("Completed"))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(ChatColors.primaryText.opacity(0.85))
                    Text(AppLocalized("Thought & acted"))
                        .font(.system(size: 12))
                        .foregroundStyle(ChatColors.secondaryText)
                }

                Spacer(minLength: 0)

                if let secs = elapsedText {
                    Text(secs)
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundStyle(ChatColors.tertiaryText)
                }

                Image(systemName: "chevron.up")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(ChatColors.tertiaryText)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ChatColors.toolBg)
            .clipShape(RoundedRectangle(cornerRadius: 13))
            .overlay(
                RoundedRectangle(cornerRadius: 13)
                    .stroke(ChatColors.toolBorder, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("assistantProcessRow")
    }

    private var thinkingCharCount: Int? {
        guard let live = message.liveProcessBlock, case .thinking = live.kind else { return nil }
        let n = max(live.content.count, live.thinkingContentBuffer.count)
        return n > 0 ? n : nil
    }

    /// Rough elapsed text: first block timestamp → now. Meaningful only for
    /// live/recent turns; restored history has stale timestamps and is
    /// guarded by the 24h cap.
    private var elapsedText: String? {
        guard let first = message.blocks.first else { return nil }
        let dur = Date().timeIntervalSince(first.timestamp)
        guard dur >= 1, dur < 24 * 3600 else { return nil }
        if dur < 60 { return String(format: "%.0fs", dur) }
        let mins = Int(dur) / 60
        let secs = Int(dur) % 60
        return "\(mins)m \(secs)s"
    }
}

// MARK: Drawer sheet (step list)

struct ProcessDrawerView: View {
    @ObservedObject var message: ChatMessage
    var toolSnapshots: [ToolSnapshotItem] = []
    var browserPool: BrowserTabPool?
    var commandStartTime: Date?
    var onStop: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    /// The step whose full content is presented as a stacked sheet on top.
    @State private var pushedStep: AssistantBlock?

    /// Steps in display order: thinking first, then tools as they occurred.
    private var steps: [AssistantBlock] {
        message.blocks.filter { block in
            switch block.kind {
            case .thinking, .shellTool, .fileReadTool, .fileWriteTool,
                 .fileEditTool, .browserTool, .readImageTool, .memoryTool:
                return true
            case .text, .info:
                return false
            }
        }
    }

    /// A thinking-only turn (no tools at all) opens straight to the thinking page.
    private var hasToolSteps: Bool {
        steps.contains { block in
            switch block.kind {
            case .shellTool, .fileReadTool, .fileWriteTool, .fileEditTool,
                 .browserTool, .readImageTool, .memoryTool:
                return true
            default:
                return false
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(ChatColors.toolBorder)
                .frame(width: 36, height: 5)
                .padding(.top, 8)

            if hasToolSteps {
                listPage
            } else if let only = steps.first {
                thinkingPage(block: only, title: AppLocalized("Thinking"))
            } else {
                emptyState
            }
        }
        .background(ChatColors.background)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        // Stacked sheet: the tapped step's FULL content on top of the drawer.
        // Tools reuse ToolLiveSheet (its own chrome); thinking gets the
        // windowed full text with a Done bar.
        .sheet(item: $pushedStep) { step in
            if case .thinking = step.kind {
                thinkingPage(block: step, title: AppLocalized("Thinking"))
            } else {
                ToolLiveSheet(
                    toolBlocks: [step],
                    initialIdx: 0,
                    toolSnapshots: toolSnapshots,
                    browserPool: browserPool
                )
            }
        }
        .accessibilityIdentifier("processDrawer")
    }

    // MARK: List page

    private var listPage: some View {
        VStack(spacing: 0) {
            navBar(title: AppLocalized("Process"), showDone: true)
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(steps) { step in
                        Button {
                            pushedStep = step
                        } label: {
                            ProcessStepRow(block: step, running: isActiveStep(step))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 6)
            }
        }
    }

    // MARK: Thinking page (full text)

    private func thinkingPage(block: AssistantBlock, title: String) -> some View {
        VStack(spacing: 0) {
            navBar(title: title, showDone: true)
            ScrollView {
                let isStreaming = message.isAwaitingModelResponse
                    && message.blocks.last?.id == block.id
                let total = max(block.content.count, block.thinkingContentBuffer.count)
                let windowSize = isStreaming ? 2000 : 100_000
                let displayContent: String = {
                    let source = block.thinkingContentBuffer.count > block.content.count
                        ? block.thinkingContentBuffer : block.content
                    guard total > windowSize else { return source }
                    let startIdx = source.index(source.endIndex, offsetBy: -windowSize)
                    let cleanStart = source[startIdx...].firstIndex(of: "\n")
                        .map { source.index(after: $0) } ?? startIdx
                    return String(source[cleanStart...])
                }()
                VStack(alignment: .leading, spacing: 0) {
                    if total > windowSize {
                        Text(String(format: AppLocalized("Showing last %d of %d characters"), windowSize, total))
                            .font(.system(size: 11))
                            .foregroundStyle(ChatColors.tertiaryText)
                            .padding(.horizontal, 14)
                            .padding(.top, 10)
                    }
                    Text(displayContent)
                        .font(MinisThemeShape.fontFamily.font(size: MinisThemeShape.thinkingBodySize))
                        .foregroundStyle(ChatColors.secondaryText)
                        .textSelection(.enabled)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(ChatColors.background)
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
    }

    // MARK: Nav bar (in-house, token-colored — avoids NavigationStack
    // resizing fights inside a detented sheet)

    private func navBar(title: String, showDone: Bool) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(ChatColors.primaryText)
                .lineLimit(1)
            Spacer(minLength: 0)
            if showDone {
                Button(AppLocalized("Done")) {
                    dismiss()
                }
                .font(.system(size: 14))
                .foregroundStyle(ChatColors.accent)
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(ChatColors.background.opacity(0.96))
    }

    private func isActiveStep(_ block: AssistantBlock) -> Bool {
        switch block.toolStatus {
        case .streaming, .running: return true
        default:
            if case .thinking = block.kind {
                return message.isAwaitingModelResponse
            }
            return false
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray")
                .font(.system(size: 26))
                .foregroundStyle(ChatColors.tertiaryText)
            Text(AppLocalized("No steps yet"))
                .font(.system(size: 13))
                .foregroundStyle(ChatColors.secondaryText)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 40)
    }
}

// MARK: Step row (one line per step in the drawer list)

struct ProcessStepRow: View {
    @ObservedObject var block: AssistantBlock
    let running: Bool

    private var statusColor: Color {
        switch block.toolStatus {
        case .success: return ChatColors.success
        case .failed: return ChatColors.destructive
        case .cancelled: return ChatColors.secondaryText
        default: return ChatColors.accent
        }
    }

    private var icon: (String, Color) {
        switch block.kind {
        case .thinking: return ("lightbulb", MinisThemeShape.thinkingAccent)
        case .shellTool: return ("terminal", statusColor)
        case .fileReadTool: return ("doc.text", statusColor)
        case .fileWriteTool: return ("doc.text.fill", statusColor)
        case .fileEditTool: return ("square.and.pencil", statusColor)
        case .browserTool: return ("globe", statusColor)
        case .readImageTool: return ("photo", statusColor)
        case .memoryTool: return ("brain.head.profile", statusColor)
        case .text, .info: return ("circle", statusColor)
        }
    }

    private var titleText: String {
        switch block.kind {
        case .thinking:
            let n = max(block.content.count, block.thinkingContentBuffer.count)
            return n > 0
                ? AppLocalized("Thinking") + " · \(n)"
                : AppLocalized("Thinking")
        case .shellTool: return AppLocalized("Terminal")
        case .fileReadTool: return AppLocalized("Read file")
        case .fileWriteTool: return AppLocalized("Write file")
        case .fileEditTool: return AppLocalized("Edit file")
        case .browserTool: return AppLocalized("Browser")
        case .readImageTool: return AppLocalized("Read image")
        case .memoryTool: return AppLocalized("Memory")
        case .text, .info: return ""
        }
    }

    private var subtitle: String? {
        switch block.kind {
        case .thinking: return nil
        default:
            let s = block.toolSummary ?? block.toolDescription
            return s.isEmpty ? nil : s
        }
    }

    private var durationText: String? {
        guard let dur = block.toolDuration else { return nil }
        if dur < 1 { return String(format: "%.1fs", dur) }
        if dur < 60 { return String(format: "%.0fs", dur) }
        let mins = Int(dur) / 60
        let secs = Int(dur) % 60
        return "\(mins)m \(secs)s"
    }

    private var statusText: String? {
        switch block.toolStatus {
        case .success: return nil
        case .failed: return AppLocalized("Failed")
        case .cancelled: return AppLocalized("Cancelled")
        case .streaming, .running: return "…"
        case .none: return nil
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon.0)
                .font(.system(size: 15))
                .foregroundStyle(icon.1)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(titleText)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(ChatColors.primaryText)
                    .lineLimit(1)
                if let sub = subtitle {
                    Text(sub)
                        .font(.system(size: 11.5))
                        .foregroundStyle(ChatColors.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 0)

            if let status = statusText {
                Text(status)
                    .font(.system(size: 11))
                    .foregroundStyle(running ? ChatColors.accent : statusColor)
            } else if let dur = durationText {
                Text(dur)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(ChatColors.tertiaryText)
            }

            if running {
                ProgressView()
                    .controlSize(.mini)
                    .tint(ChatColors.accent)
            }

            Image(systemName: "chevron.forward")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(ChatColors.tertiaryText.opacity(0.6))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .accessibilityIdentifier("processStepRow")
    }
}
