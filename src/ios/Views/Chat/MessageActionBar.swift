import SwiftUI
import UIKit

// MARK: - Message action bar (kelivo-style)
//
// [T-message-action-bar 09-11] 醒醒要的 kelivo 式操作条,挂在 AI 消息气泡下:
//   [▶ 播放语音]  [↻ 重新回复]  [⧉ 复制]  [🗑 删除消息]
//
// 语音按钮的状态跟全局播放状态走(不是 per-bubble):正在播 → 暂停图标,
// 暂停中 → 播放图标,空闲 → 播放图标。点它:
//   空闲   → 用 TTS 服务层的当前声音读这一条气泡的文字
//   播放中 → 暂停
//   暂停中 → 继续
// 播放按钮右侧挂一个语速 chip(1.0× / 1.25× / 1.5× / 1.75× / 2.0× 循环),
// 点切换语速——只影响后续朗读,不重读当前正在读的。

struct MessageActionBar: View {

    /// The bubble's plain text (already markdown-stripped for speech).
    let speakText: String
    /// Speaks ONLY this text via the service layer.
    let onSpeak: (String) -> Void
    /// Global pause/resume/stop — the vm's SpeechControlling conformance.
    let controller: SpeechControlling
    /// Regenerate this assistant message (find preceding user msg → retry).
    let onRegenerate: () -> Void
    /// Delete this single assistant message.
    let onDelete: () -> Void

    @ObservedObject private var outputState = VoiceOutputState.shared

    private var isSpeaking: Bool { outputState.isReadingAloud }
    private var isPaused: Bool { outputState.isPausedOrHeld }

    private let speedSteps: [Float] = [1.0, 1.25, 1.5, 1.75, 2.0]
    private var speedLabel: String {
        let v = outputState.speechSpeed
        // snap to nearest step for display
        let nearest = speedSteps.min(by: { abs($0 - v) < abs($1 - v) }) ?? v
        return nearest == 1.0 ? "1×" : String(format: "%.2g×", nearest)
    }

    var body: some View {
        HStack(spacing: 18) {
            // Play / pause / resume this bubble's text.
            Button {
                if isSpeaking && !isPaused {
                    controller.toggleSpeechPause()
                } else if isSpeaking && isPaused {
                    controller.toggleSpeechPause()
                } else {
                    onSpeak(speakText)
                }
            } label: {
                Group {
                    if isSpeaking && !isPaused {
                        actionIcon("pause.fill", label: "Pause")
                    } else if isPaused {
                        actionIcon("play.fill", label: "Resume")
                    } else {
                        actionIcon("speaker.wave.2", label: "Play")
                    }
                }
            }
            .buttonStyle(.borderless)

            // Speed chip — tap cycles 1× → 1.25× → 1.5× → 1.75× → 2.0× → 1×.
            Button {
                cycleSpeed()
            } label: {
                Text(speedLabel)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(MinisTheme.secondaryText)
                    .frame(minWidth: 32)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(MinisTheme.mutedSurface, in: Capsule())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Speech speed")

            // Regenerate this assistant message.
            Button { onRegenerate() } label: {
                actionIcon("arrow.clockwise", label: "Regenerate")
            }
            .buttonStyle(.borderless)

            // Copy this bubble's text.
            Button {
                UIPasteboard.general.string = speakText
                MinisToast.show(AppLocalized("Copied", comment: "Message action bar: copied toast"),
                                systemImage: "doc.on.doc")
            } label: {
                actionIcon("doc.on.doc", label: "Copy")
            }
            .buttonStyle(.borderless)

            // Delete this message.
            Button(role: .destructive) { onDelete() } label: {
                actionIcon("trash", label: "Delete")
            }
            .buttonStyle(.borderless)

            Spacer(minLength: 0)
        }
        .padding(.top, 6)
        .animation(.easeInOut(duration: 0.18), value: isSpeaking)
    }

    private func cycleSpeed() {
        let v = outputState.speechSpeed
        guard let idx = speedSteps.firstIndex(where: { abs($0 - v) < 0.01 }) else {
            outputState.speechSpeed = 1.25; return
        }
        let next = speedSteps[(idx + 1) % speedSteps.count]
        outputState.speechSpeed = next
        controller.nextSpeechSpeed()
    }

    private func actionIcon(_ systemName: String, label: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(MinisTheme.secondaryText)
            .frame(width: 26, height: 26)
            .contentShape(Rectangle())
            .accessibilityLabel(label)
    }
}
