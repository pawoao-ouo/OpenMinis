//
//  TogetherMiniBar.swift
//  MinisApp
//
//  一起听 · 聊天页里浮着的那枚小胶囊。
//
//  不是"挂在输入栏上的一条"：它浮在输入栏上方 2pt，左右各留 16pt 边，
//  系统玻璃胶囊，48pt 高——一眼看过去是"现在在放什么 + 播/停/下一首"，
//  不抢输入栏的地方，不挡消息，不跟悬浮按钮打架。
//  点左半边（胶囊 + 字）打开一起听整页；右边两个键各 44pt，亲手点得着。
//  上一首不在这儿：小卡上只有播/停和下一首（Apple 小播放器的规矩），
//  上一首回整页里按。胶囊不转、不闪、不走马灯：它是"看一眼"的东西，
//  动的只有进度那条细线和播/停那个图标。

import SwiftUI

struct TogetherMiniBar: View {

    /// 整条胶囊占的高度（含和输入栏之间的 2pt 间距）：
    /// 聊天页的消息列表、悬浮按钮、斜杠弹窗都拿这一个数算位置，
    /// 改了胶囊高度只改这里，别处不会错位。
    static let stackHeight: CGFloat = 50

    /// 点胶囊左半边打开全屏面板。
    var onOpen: () -> Void = {}

    @ObservedObject private var player = TogetherPlayer.shared
    @ObservedObject private var hub = TogetherStateHub.shared

    /// 当前这首歌的歌词：只在换歌时读一次文件，不跟着进度轮询读。
    @State private var lyrics: TogetherLyrics?

    private let capsuleHeight: CGFloat = 48

    var body: some View {
        HStack(spacing: 4) {
            openButton

            Spacer(minLength: 0)

            Button {
                TogetherHaptics.tap()
                player.userToggle()
            } label: {
                Image(systemName: player.showsPauseControl ? "pause.fill" : "play.fill")
                    .font(ChatFont.font(15, weight: .semibold))
                    .foregroundStyle(CSSThemeVariables.textMain(scope: .chat))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .togetherPress()
            .accessibilityLabel(player.showsPauseControl ? TogetherCopy.a11yPause : TogetherCopy.a11yPlay)

            Button {
                TogetherHaptics.select()
                player.nextTrack()
            } label: {
                Image(systemName: "forward.fill")
                    .font(ChatFont.font(14, weight: .medium))
                    .foregroundStyle(CSSThemeVariables.textMain(scope: .chat))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .togetherPress()
            .accessibilityLabel(TogetherCopy.a11yNext)
        }
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .frame(height: capsuleHeight)
        .frame(maxWidth: .infinity)
        // 系统玻璃胶囊：跟面板底栏同一套语言，壁纸从里面透出来。
        // 只有这一块玻璃，不叠别的玻璃，不用容器。
        .glassEffect(.regular.interactive(), in: .capsule)
        .overlay(alignment: .bottom) { progressBar }
        .padding(.horizontal, 16)
        .onAppear { loadLyrics() }
        .onChange(of: player.track?.id) { _ in loadLyrics() }
    }

    /// 左半边：静态小胶囊 + 两行字，一个按钮，没有嵌套。
    private var openButton: some View {
        Button {
            TogetherHaptics.select()
            onOpen()
        } label: {
            HStack(spacing: 10) {
                miniVinyl

                VStack(alignment: .leading, spacing: 2) {
                    Text(player.track?.title ?? TogetherCopy.title)
                        .font(ChatFont.font(13, weight: .semibold))
                        .foregroundStyle(CSSThemeVariables.textMain(scope: .chat))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(ChatFont.font(11))
                        .foregroundStyle(CSSThemeVariables.textDim(scope: .chat))
                        .lineLimit(1)
                }
            }
            .contentShape(Rectangle())
        }
        .togetherPress()
        .accessibilityLabel("\(TogetherCopy.title)：\(player.track?.title ?? "")")
    }

    /// 静态小胶囊：中性灰，不转，不取主题色——深壁纸浅壁纸上都是同一枚。
    private var miniVinyl: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color(white: 0.55), Color(white: 0.3), Color(white: 0.16)],
                        center: .center,
                        startRadius: 1,
                        endRadius: 12
                    )
                )
            Circle()
                .fill(Color(white: 0.12))
                .frame(width: 7, height: 7)
        }
        .frame(width: 24, height: 24)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// 第二行：有词显正在唱的那句，没词显循环的那句，都没有显歌手。
    /// 歌名永远在第一行——以前歌词一来歌名就没了，胶囊不知道在放哪首。
    private var subtitle: String {
        if let lyr = lyrics, lyr.timed,
           let line = lyr.line(at: player.currentTime)?.text,
           !line.trimmingCharacters(in: .whitespaces).isEmpty {
            return line
        }
        if let id = player.track?.id, let loop = hub.state.loopLines[id],
           !loop.trimmingCharacters(in: .whitespaces).isEmpty {
            return loop
        }
        return player.track?.artist ?? ""
    }

    /// 底部那条细进度线：只显示进度，不接手势（想拖回整页里拖）。
    private var progressBar: some View {
        GeometryReader { geo in
            Capsule()
                .fill(CSSThemeVariables.accent(scope: .chat).opacity(0.6))
                .frame(width: max(0, (geo.size.width - 48) * progressRatio), height: 2)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(.leading, 24)
                .padding(.bottom, 4)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var progressRatio: CGFloat {
        let d = max(player.duration, 1)
        return CGFloat(min(1, max(0, player.currentTime / d)))
    }

    private func loadLyrics() {
        lyrics = player.track.flatMap { TogetherStore.shared.lyrics(for: $0) }
    }
}
