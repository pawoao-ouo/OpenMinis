import SwiftUI
import UIKit

// MARK: - Message action bar (kelivo-style)
//
// [T-message-action-bar 09-11→09-12] 醒醒要的 kelivo 式操作条,挂在 AI 消息气泡下:
//   [▶ 播放语音]  [↻ 重新回复]  [⧉ 复制]  [🗑 删除消息]
//
// 倍速不放这儿(她 09-12 拍板),去浮窗/设置里调。
//
// 播放按钮的状态跟全局播放状态走(不是 per-bubble):
//   空闲   → 用 TTS 服务层的当前声音读这一条气泡的文字
//   播放中 → 暂停
//   暂停中 → 继续
// 显式点播会强制开「朗读回复」总开关(手动点播 ≠ 自动跟读,总开关管自动)。

struct MessageActionBar: View {

    /// The bubble's plain text (already markdown-stripped for speech).
    let speakText: String
    /// Speaks ONLY this text via the service layer. Caller (vm) ensures the
    /// read-replies master switch is on before invoking.
    let onSpeak: (String) -> Void
    /// Global pause/resume/stop — the vm's SpeechControlling conformance.
    let controller: SpeechControlling
    /// Regenerate this assistant message (find preceding user msg → retry).
    let onRegenerate: () -> Void
    /// Delete this single assistant message.
    let onDelete: () -> Void

    @ObservedObject private var outputState = VoiceOutputState.shared

    private var isSpeaking: Bool { outputState.isReadingAloud }
    /// Cloud playback can be paused before/without a live VM state update; use
    /// the player latch too so the bubble never shows "pause" while it is held.
    private var isPaused: Bool { outputState.isPausedOrHeld }

    var body: some View {
        HStack(spacing: 20) {
            playPauseButton
            regenerateButton
            copyButton
            deleteButton
            Spacer(minLength: 0)
        }
        .padding(.top, 6)
        .animation(.easeInOut(duration: 0.18), value: isSpeaking)
    }

    // MARK: Play / pause / resume

    private var playPauseButton: some View {
        Button {
            if isSpeaking && !isPaused {
                // 正在播 → 暂停
                controller.toggleSpeechPause()
            } else if isPaused {
                // 暂停中 → 继续
                controller.toggleSpeechPause()
            } else {
                // 空闲 → 显式点播这条气泡
                onSpeak(speakText)
            }
        } label: {
            Group {
                if isSpeaking && !isPaused {
                    actionIcon("pause.fill", label: "Pause")
                } else if isPaused {
                    actionIcon("play.fill", label: "Resume")
                } else {
                    actionIcon("speaker.wave.2.fill", label: "Play")
                }
            }
        }
        .buttonStyle(.borderless)
    }

    // MARK: Regenerate

    private var regenerateButton: some View {
        Button { onRegenerate() } label: {
            actionIcon("arrow.clockwise", label: "Regenerate")
        }
        .buttonStyle(.borderless)
    }

    // MARK: Copy

    private var copyButton: some View {
        Button {
            UIPasteboard.general.string = speakText
            MinisToast.show(AppLocalized("Copied", comment: "Message action bar: copied toast"),
                            systemImage: "doc.on.doc")
        } label: {
            actionIcon("doc.on.doc", label: "Copy")
        }
        .buttonStyle(.borderless)
    }

    // MARK: Delete

    private var deleteButton: some View {
        Button(role: .destructive) { onDelete() } label: {
            actionIcon("trash", label: "Delete")
        }
        .buttonStyle(.borderless)
    }

    // MARK: Icon helper

    private func actionIcon(_ systemName: String, label: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(MinisTheme.secondaryText)
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
            .accessibilityLabel(label)
    }
}
