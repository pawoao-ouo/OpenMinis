import SwiftUI
import UIKit

// MARK: - Message action bar (kelivo-style)
//
// [T-message-action-bar 09-11] 醒醒的反馈:朗读入口埋在长按菜单第二屏,
// "这要咋用"——kelivo 的 AI 消息下面直接摆一排小图标(复制/重新回复/语音播放/
// 翻译/编辑),一眼可见。这里给 OpenMinis 的 assistant text 气泡做同款:
//
//   [⧉ 复制]  [▶/⏸ 播放本条]  [■ 停止]  [(read-aloud 开关状态)]
//
// 播放按钮的状态跟着 GLOBAL 播放状态走(不是 per-bubble 状态):正在播 → 暂停图标,
// 暂停中 → 播放图标,空闲 → 播放图标。点它:
//   空闲   → 用 TTS 服务层的当前声音读这一条气泡的文字(不读全文)
//   播放中 → 暂停
//   暂停中 → 继续
// 停止按钮只在有活动播放时出现。
//
// 这条 bar 只挂在 assistant 的 TEXT 气泡下(最后一个 text block 才带)——
// 工具块/错误块/音频块不挂,不抢戏。

struct MessageActionBar: View {

    /// The bubble's plain text (already markdown-stripped for speech).
    let speakText: String
    /// Fires the TTS: vm.speakText — speaks ONLY this text via the service layer.
    let onSpeak: (String) -> Void
    /// Global pause/resume/stop — the vm's SpeechControlling conformance.
    let controller: SpeechControlling

    @ObservedObject private var player = VoiceOutputPlayer.shared
    @ObservedObject private var outputState = VoiceOutputState.shared

    private var isSpeaking: Bool {
        player.isPlaying || player.isPaused || outputState.isReadingAloud
    }

    private var isPaused: Bool {
        player.isPaused || outputState.speechPaused
    }

    var body: some View {
        HStack(spacing: 20) {
            // Copy this bubble's text.
            Button {
                UIPasteboard.general.string = speakText
                MinisToast.show(AppLocalized("Copied", comment: "Message action bar: copied toast"),
                                systemImage: "doc.on.doc")
            } label: {
                actionIcon("doc.on.doc", label: "Copy")
            }
            .buttonStyle(.borderless)

            // Speak / pause / resume this bubble's text.
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

            // Stop — only when something is actually playing.
            if isSpeaking {
                Button {
                    controller.stopSpeech()
                } label: {
                    actionIcon("stop.fill", label: "Stop")
                }
                .buttonStyle(.borderless)
                .transition(.opacity.combined(with: .scale))
            }

            Spacer(minLength: 0)
        }
        .padding(.top, 6)
        .animation(.easeInOut(duration: 0.18), value: isSpeaking)
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
