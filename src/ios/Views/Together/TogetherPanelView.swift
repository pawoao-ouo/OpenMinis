//
//  TogetherPanelView.swift
//  MinisApp
//
//  一起听 · 播放主界面。
//  同页常驻：黑胶 + 歌词 + 标题同屏，控制沉底，标签栏玻璃胶囊。
//  状态只从一个地方来（TogetherStateHub）：没有轮询，写盘即达。
//  这一页不许有阴影、不许有 emoji、不许有裸色值。
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers
import PhotosUI

struct TogetherPanelView: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(\.togetherPersonaId) private var sessionPersonaId
    @Environment(\.togetherSelectedTab) private var selectedTab
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var player = TogetherPlayer.shared
    @ObservedObject private var hub = TogetherStateHub.shared

    @State private var lyrics: TogetherLyrics?
    @State private var optimisticPosition: Double = 0
    @State private var isDragging = false
    /// 拖动开始时是哪首歌：拖着拖着换了歌，松手那一下不许落到新歌头上。
    @State private var dragTrackId: String?
    /// state.json 里那首歌的文件不见了（restore 装不上）：面板说实话，不摆死控件。
    @State private var restoreFailed = false

    /// 回声气泡
    @State private var echoOn = true
    @State private var echoBubbles: [EchoBubble] = []
    @State private var echoQueue: [TogetherNote] = []
    @State private var echoLastPosition: Double = 0
    @State private var echoCorner: Int = 0
    @State private var echoGen = 0

    /// 抽屉与中心弹窗：同一视图只挂一个 .sheet，靠这个枚举切换。
    /// 以前四个 .sheet(isPresented:) 叠在同一个视图上会互相顶掉——
    /// 刻字弹窗被回声墙抽屉抢掉就是这么来的。
    @State private var activeSheet: PanelSheet?
    @State private var noteDraft = ""

    /// 小惊喜：心动共振光效脉冲（一次性的进场，不是循环）
    @State private var resonancePulse = false
    @State private var heartbeatGen = 0
    /// 上一次共振写盘的时间：连点只写一次，光效照常跑（见 triggerHeartbeat）。
    @State private var lastResonanceWrite: Date?

    /// 唯一真源：Hub 的状态 + 本机播放器。当前这首歌以播放器为准
    /// （player.track），面板 / Sync / 微控条三处读同一处，
    /// 不会再出现面板一首歌、别处另一首歌。
    private var state: TogetherState { hub.state }
    /// 正在响的那首：播放器说了算。文件没了、播放器没装上时，
    /// 控件不许装作能用——emptyState 会说实话。
    private var track: TogetherTrack? { player.track }
    private var aiName: String { ChatAddressing.assistant(sessionPersonaId: sessionPersonaId) }
    private var userName: String { ChatAddressing.user() }

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let s = min(1.15, max(0.72, h / 852))

            ZStack {
                // 心动微光光环：一次性的进场光，1.2 秒就走，不循环、不挡手。
                if resonancePulse {
                    Circle()
                        .fill(RadialGradient(
                            colors: [CSSThemeVariables.accent(scope: .chat).opacity(0.35), Color.clear],
                            center: .center,
                            startRadius: 10,
                            endRadius: 280
                        ))
                        .scaleEffect(resonancePulse ? 1.4 : 0.8)
                        .opacity(resonancePulse ? 1 : 0)
                        .animation(.easeOut(duration: 1.2), value: resonancePulse)
                        .allowsHitTesting(false)
                }

                VStack(spacing: 0) {
                    topBar(s)

                    if let t = track {
                        // 我们的头像
                        duoHeader(s)

                        // 黑胶和歌词同页：上面唱片，下面滚动歌词，不用任何切换。
                        // 歌名歌手夹在两者中间，谁都不藏。
                        VStack(spacing: 12 * s) {
                            discSection(s: s, h: h, w: geo.size.width)

                            titleBlock(t, s)

                            // 歌词块：跟随进度滚、当前行加粗、点一行跳过去。
                            // 高度收死在这里，不许把下面的进度条和控制排顶出屏幕。
                            // 她手动翻歌词时自动滚停下，点"回到当前这一句"才回来。
                            TogetherInlineLyricsView(
                                track: t,
                                lyrics: lyrics,
                                loopLine: state.loopLines[t.id],
                                position: player.currentTime,
                                onSeek: { target in
                                    player.seek(to: target)
                                    TogetherStore.shared.seek(to: target, by: .user)
                                }
                            )
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .frame(minHeight: 0)
                            .clipped()
                            .padding(.horizontal, 20)
                        }
                        .frame(maxHeight: .infinity)

                        // 喜欢 / 回声 / 刻字：一排小图标，歌词下方、进度条上方
                        actionRow(t, s: s)

                        // 底部控制区：贴底
                        bottomControlSuite(t, s: s)
                            .padding(.horizontal, 24)
                            .padding(.bottom, max(8, geo.safeAreaInsets.bottom))
                    } else {
                        emptyState
                    }
                }
            }
        }
        .onAppear(perform: bootstrap)
        .onChange(of: player.track?.id) { _ in
            lyrics = player.track.flatMap { TogetherStore.shared.lyrics(for: $0) }
            restoreFailed = false
            echoBubbles.removeAll()
            echoQueue.removeAll()
            echoGen += 1
            echoLastPosition = player.currentTime
            // 换歌了：拖到一半的进度条作废，不给新歌留一个旧位置。
            dragTrackId = nil
            isDragging = false
            optimisticPosition = 0
        }
        .onChange(of: player.currentTime) { pos in
            checkEcho(at: pos)
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .echo:
                if let t = track {
                    TogetherEchoDrawerView(track: t) { target in
                        player.seek(to: target)
                        TogetherStore.shared.seek(to: target, by: .user)
                    }
                }
            case .note:
                noteComposer
            case .queue:
                TogetherQueueDrawerView()
            case .theme:
                TogetherThemeCenterView()
            }
        }
    }

    // MARK: - 顶栏

    /// 标题永远居中：左右两边等宽（左边留白 = 右边两颗 44pt 键 + 间距），
    /// 以前左边 36、右边 76，标题被顶偏 20pt。
    private func topBar(_ s: CGFloat) -> some View {
        ZStack {
            Text(TogetherCopy.title)
                .font(ChatFont.font(11, weight: .medium))
                .tracking(3)
                .foregroundStyle(CSSThemeVariables.textDim(scope: .chat))

            HStack(alignment: .center, spacing: 8) {
                // 关闭键只由容器 TogetherRootView 那一颗负责（四个 tab 都要有关闭键）。
                // 这里留等宽占位，标题才居得正。
                Color.clear.frame(width: 96, height: 44)

                Spacer()

                // 右侧：装扮中心调色盘 + 回声开关
                Button {
                    TogetherHaptics.select()
                    activeSheet = .theme
                } label: {
                    ZStack {
                        Circle().fill(CSSThemeVariables.optionBg(scope: .chat).opacity(0.8))
                            .frame(width: 34, height: 34)
                        Image(systemName: "paintpalette.fill")
                            .togetherIcon(13, dim: false)
                            .foregroundStyle(CSSThemeVariables.accent(scope: .chat))
                    }
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                }
                .togetherPress()
                .accessibilityLabel(TogetherCopy.themeCenter)

                Button {
                    TogetherHaptics.select()
                    echoOn.toggle()
                    if !echoOn {
                        echoBubbles.removeAll()
                        echoQueue.removeAll()
                    }
                } label: {
                    ZStack {
                        Circle().fill(CSSThemeVariables.optionBg(scope: .chat).opacity(0.8))
                            .frame(width: 34, height: 34)
                        Image(systemName: echoOn ? "bubble.left.and.bubble.right.fill" : "bubble.left.and.bubble.right")
                            .togetherIcon(13, dim: false)
                            .foregroundStyle(echoOn ? CSSThemeVariables.accent(scope: .chat) : CSSThemeVariables.textDim(scope: .chat))
                    }
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                }
                .togetherPress()
                .accessibilityLabel(TogetherCopy.historyEchoes)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
    }

    // MARK: - 黑胶（同页常驻，纯视觉，不可点）

    /// 黑胶直径：先按屏高分档，再按剩余高度预算封顶——
    /// 小屏上宁可唱片小一点，也不能把歌词和控制排挤出屏幕。
    private func discDiameter(h: CGFloat, s: CGFloat) -> CGFloat {
        let tier: CGFloat
        if h < 640 { tier = 136 * s }
        else if h < 720 { tier = 164 * s }
        else { tier = 210 * s }
        return min(tier, max(96, (h - 380) * 0.55))
    }

    private func discSection(s: CGFloat, h: CGFloat, w: CGFloat) -> some View {
        let d = discDiameter(h: h, s: s)
        return ZStack {
            TogetherDiscView(
                size: d,
                trackId: track?.id ?? "",
                isPlaying: player.isPlaying
            )

            // 回声弹幕浮在黑胶四周：偏移夹在屏幕里——气泡最宽 220，
            // 横向按屏幕宽夹，纵向夹在唱片区上下，不压住头像和歌名。
            ForEach(echoBubbles) { bubble in
                EchoBubbleView(bubble: bubble)
                    .offset(clampedEchoOffset(bubble, width: w, scale: s))
                    .allowsHitTesting(false)
            }
        }
        .frame(height: d)
        .allowsHitTesting(false)
    }

    /// 回声气泡的偏移夹取：横向保证整个气泡在屏幕里（半宽 110 + 8 边距），
    /// 纵向夹在唱片区——气泡是 4.65 秒的浮层，不交互，纵向只求不压住
    /// 上下两块内容，不求像素级不重叠。
    private func clampedEchoOffset(_ bubble: EchoBubble, width w: CGFloat, scale s: CGFloat) -> CGSize {
        let maxDx = max(0, w / 2 - 118)
        let maxDy: CGFloat = 96 * s
        return CGSize(
            width: min(max(bubble.dx * s, -maxDx), maxDx),
            height: min(max(bubble.dy * s, -maxDy), maxDy)
        )
    }


    // MARK: - 我们的头像

    private func duoHeader(_ s: CGFloat) -> some View {
        VStack(spacing: 7 * s) {
            Button {
                triggerHeartbeat()
            } label: {
                HStack(spacing: -14 * s) {
                    avatar(TogetherIdentity.aiIcon(sessionPersonaId: sessionPersonaId), size: 104 * s, ring: 3 * s)
                        .zIndex(1)
                    avatar(TogetherIdentity.userIcon, size: 104 * s, ring: 3 * s)
                }
            }
            .togetherPress()
            .accessibilityLabel("\(aiName) & \(userName)")

            Text("\(aiName) & \(userName)")
                .font(ChatFont.font(11, weight: .medium))
                .tracking(1.4)
                .foregroundStyle(CSSThemeVariables.textDim(scope: .chat))

            // 谁在带 + 他现在的心情：一行小字，不喊口号。
            driverLine(s)
            pendingHandoffLine(s)
        }
        .padding(.top, 10 * s)
    }

    /// "谁在掌控 · 心情词"。心情是他留下的一个词，只展示，不打分、不滑条。
    /// 谁在掌控还不知道（还没放过歌）时，不许默认说她在掌控——只写心情，
    /// 心情也没有就空着，不编一句。
    @ViewBuilder
    private func driverLine(_ s: CGFloat) -> some View {
        let mood = state.me.presence.mood?.word.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let by = state.playback.by
        let driverText: String? = by == TogetherActor.ai.rawValue ? TogetherCopy.driving(aiName)
            : by == TogetherActor.user.rawValue ? TogetherCopy.youDriving : nil
        if driverText != nil || !mood.isEmpty {
            HStack(spacing: 4) {
                if let driverText {
                    Text(driverText)
                }
                if driverText != nil, !mood.isEmpty {
                    Text("·")
                }
                if !mood.isEmpty {
                    Text(mood).italic()
                }
            }
            .font(ChatFont.font(11, weight: .medium))
            .foregroundStyle(CSSThemeVariables.textDim(scope: .chat))
        }
    }

    /// 遥控器正在递交：说一声在等谁，可取消。pending 期间旧持有人继续说了算。
    @ViewBuilder
    private func pendingHandoffLine(_ s: CGFloat) -> some View {
        if let pending = state.pendingHandoff, !pending.to.isEmpty {
            let name = pending.to == TogetherActor.ai.rawValue ? aiName : userName
            HStack(spacing: 8) {
                Text(TogetherCopy.waitingForHandoff(name))
                    .font(ChatFont.font(11))
                    .foregroundStyle(CSSThemeVariables.textDim(scope: .chat))
                Button(TogetherCopy.cancel) {
                    TogetherHaptics.select()
                    TogetherStore.shared.cancelHandoff(by: .user)
                    hub.refreshNow()
                }
                .font(ChatFont.font(11, weight: .semibold))
                .foregroundStyle(CSSThemeVariables.accent(scope: .chat))
                .padding(.horizontal, 6)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
                .togetherPress()
            }
        }
    }

    private func avatar(_ iconRef: String?, size: CGFloat, ring: CGFloat) -> some View {
        PersonaAvatarView(iconRef: iconRef, size: size)
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay(
                Circle().strokeBorder(CSSThemeVariables.bg(scope: .chat), lineWidth: ring)
            )
    }

    // MARK: - 歌名

    private func titleBlock(_ t: TogetherTrack, _ s: CGFloat) -> some View {
        VStack(spacing: 5 * s) {
            Text(t.title)
                .font(ChatFont.font(26 * s, weight: .semibold))
                .foregroundStyle(CSSThemeVariables.textMain(scope: .chat))
                .lineLimit(1)
                .minimumScaleFactor(0.6)

            if let en = t.titleEn, !en.isEmpty {
                Text(en)
                    .font(ChatFont.font(13.5 * s, design: .serif))
                    .italic()
                    .foregroundStyle(CSSThemeVariables.textDim(scope: .chat).opacity(0.85))
            }

            Text(t.artist)
                .font(ChatFont.font(11.5 * s, weight: .medium))
                .tracking(1.4)
                .foregroundStyle(CSSThemeVariables.textDim(scope: .chat))
        }
        .padding(.top, 8 * s)
        .padding(.horizontal, 24)
        // 壁纸原样亮着，标题和歌手靠深浅两套前景变量站住；阴影已经全部删掉。
    }

    // MARK: - 底部控制套件（沉底布局）

    private func bottomControlSuite(_ t: TogetherTrack, s: CGFloat) -> some View {
        VStack(spacing: 18 * s) {
            // 1. 进度条（喜欢、回声、刻字收在它上面那一排小图标里，不占大块）
            progressBar(s: s)

            // 2. 核心播放控制排（播放模式、上一首、播放/暂停、下一首、播放队列）
            mainControlsRow(s: s)
        }
        // 控制区不加任何阴影：按键和时间的可读性由前景变量负责。
    }

    /// 喜欢 / 回声 / 刻字：收成一排小图标，夹在歌词块和进度条中间。
    /// 功能一个不少，只是不再一人占四分之一的宽度。
    private func actionRow(_ t: TogetherTrack, s: CGFloat) -> some View {
        let liked = state.liked.contains(t.id)
        let noteCount = state.notes.filter { $0.trackId == t.id }.count

        return HStack(spacing: 34 * s) {
            // 喜欢
            Button {
                TogetherHaptics.select()
                TogetherStore.shared.toggleLike(trackId: t.id, by: .user)
                hub.refreshNow()
            } label: {
                Image(systemName: liked ? "heart.fill" : "heart")
                    .togetherIcon(16 * s, dim: false)
                    .foregroundStyle(liked ? CSSThemeVariables.accent(scope: .chat) : CSSThemeVariables.textDim(scope: .chat))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .togetherPress()
            .accessibilityLabel(liked ? TogetherCopy.a11yUnlike : TogetherCopy.a11yLike)

            // 历史回声墙抽屉
            Button {
                TogetherHaptics.select()
                activeSheet = .echo
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .togetherIcon(15 * s)
                    if noteCount > 0 {
                        Text("\(noteCount)")
                            .font(ChatFont.font(9, weight: .bold))
                    }
                }
                .foregroundStyle(CSSThemeVariables.textDim(scope: .chat))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            }
            .togetherPress()
            .accessibilityLabel(TogetherCopy.historyEchoes)

            // 直接刻字（在这一秒留一句）
            Button {
                TogetherHaptics.select()
                activeSheet = .note
            } label: {
                Image(systemName: "square.and.pencil")
                    .togetherIcon(15 * s)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .togetherPress()
            .accessibilityLabel(TogetherCopy.leaveALine)
        }
        .frame(maxWidth: .infinity)
    }

    private func progressBar(s: CGFloat) -> some View {
        let duration = max(player.duration, 1)
        let pos = isDragging ? optimisticPosition : player.currentTime

        return VStack(spacing: 6) {
            GeometryReader { geo in
                let width = geo.size.width
                let ratio = min(1, max(0, pos / duration))

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(CSSThemeVariables.textDim(scope: .chat).opacity(0.4))
                        .frame(height: 3.5)

                    Capsule()
                        .fill(CSSThemeVariables.accent(scope: .chat))
                        .frame(width: width * ratio, height: 3.5)

                    Circle()
                        .fill(CSSThemeVariables.accent(scope: .chat))
                        .frame(width: 10, height: 10)
                        .overlay(Circle().strokeBorder(Color.white, lineWidth: 1.5))
                        .offset(x: max(0, width * ratio - 5))
                }
                .frame(height: 20)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            // 拖动开始时钉住歌的身份：中途换歌，松手也不提交。
                            if dragTrackId == nil { dragTrackId = player.track?.id }
                            isDragging = true
                            let r = min(1, max(0, value.location.x / max(width, 1)))
                            optimisticPosition = Double(r) * duration
                        }
                        .onEnded { value in
                            let r = min(1, max(0, value.location.x / max(width, 1)))
                            let target = Double(r) * duration
                            // 还是拖动开始时那首歌才提交：播完切歌、AI 推歌
                            // 换了歌，这一拖就作废，不许落到新歌头上。
                            // dragTrackId 没钉上（没经过 onChanged）也不提交。
                            if dragTrackId != nil, dragTrackId == player.track?.id {
                                commitSeek(to: target)
                            }
                            dragTrackId = nil
                            isDragging = false
                        }
                )
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(TogetherCopy.progressLabel)
                .accessibilityValue("\(mmss(pos)) / \(mmss(duration))")
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: commitSeek(to: min(duration, player.currentTime + 5))
                    case .decrement: commitSeek(to: max(0, player.currentTime - 5))
                    @unknown default: break
                    }
                }
            }
            .frame(height: 20)

            HStack {
                Text(mmss(pos))
                Spacer()
                Text(mmss(duration))
            }
            .font(ChatFont.font(11, weight: .medium))
            .foregroundStyle(CSSThemeVariables.textDim(scope: .chat))
        }
    }

    /// 拖进度条只落一个点：本地 seek + 共享文件 + 触感。拖着不放不写盘，松手写一次。
    private func commitSeek(to target: Double) {
        player.seek(to: target)
        TogetherStore.shared.seek(to: target, by: .user)
        TogetherHaptics.tap()
    }

    private func mainControlsRow(s: CGFloat) -> some View {
        HStack(spacing: 0) {
            // 随机：独立开关，只管出牌顺序。亮 = 开。
            Button {
                TogetherHaptics.select()
                TogetherStore.shared.setModes(shuffle: !state.playback.shuffle)
                hub.refreshNow()
            } label: {
                Image(systemName: "shuffle")
                    .togetherIcon(19 * s, dim: false)
                    .foregroundStyle(state.playback.shuffle ? CSSThemeVariables.accent(scope: .chat)
                                                            : CSSThemeVariables.textDim(scope: .chat))
                    .frame(minWidth: 44, minHeight: 44)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
            }
            .togetherPress()
            .accessibilityLabel(TogetherCopy.a11yShuffle)
            .accessibilityValue(state.playback.shuffle ? TogetherCopy.shuffleEcho : TogetherCopy.inOrderEcho)

            // 上一首
            Button {
                TogetherHaptics.select()
                player.previousTrack()
                hub.refreshNow()
            } label: {
                Image(systemName: "backward")
                    .togetherIcon(22 * s, dim: false)
                    .frame(minWidth: 44, minHeight: 44)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
            }
            .togetherPress()
            .accessibilityLabel(TogetherCopy.a11yPrevious)

            // 播放/暂停大圆键
            Button {
                TogetherHaptics.tap()
                player.userToggle()
                hub.refreshNow()
            } label: {
                Image(systemName: player.showsPauseControl ? "pause.fill" : "play.fill")
                    .font(ChatFont.font(26 * s, weight: .semibold))
                    .foregroundStyle(CSSThemeVariables.accentFg(scope: .chat))
                    .frame(width: 62 * s, height: 62 * s)
                    .background(CSSThemeVariables.accent(scope: .chat))
                    .clipShape(Circle())
            }
            .togetherPress()
            .frame(minWidth: 44, minHeight: 44)
            .frame(maxWidth: .infinity)
            .accessibilityLabel(player.showsPauseControl ? TogetherCopy.a11yPause : TogetherCopy.a11yPlay)

            // 下一首
            Button {
                TogetherHaptics.select()
                player.nextTrack()
                hub.refreshNow()
            } label: {
                Image(systemName: "forward")
                    .togetherIcon(22 * s, dim: false)
                    .frame(minWidth: 44, minHeight: 44)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
            }
            .togetherPress()
            .accessibilityLabel(TogetherCopy.a11yNext)

            // 循环：关 → 全部循环 → 单曲循环 → 关。图标 + 字面状态一起变。
            Button {
                TogetherHaptics.select()
                cycleRepeatMode()
                hub.refreshNow()
            } label: {
                Image(systemName: repeatIcon)
                    .togetherIcon(19 * s, dim: false)
                    .foregroundStyle(isRepeatActive ? CSSThemeVariables.accent(scope: .chat)
                                                    : CSSThemeVariables.textDim(scope: .chat))
                    .frame(minWidth: 44, minHeight: 44)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
            }
            .togetherPress()
            .accessibilityLabel(TogetherCopy.a11yRepeat)
            .accessibilityValue(repeatEcho)

            // 播放队列抽屉按钮
            Button {
                TogetherHaptics.select()
                activeSheet = .queue
            } label: {
                Image(systemName: "list.bullet")
                    .togetherIcon(19 * s)
                    .frame(minWidth: 44, minHeight: 44)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
            }
            .togetherPress()
            .accessibilityLabel(TogetherCopy.a11yQueue)
        }
    }

    private var repeatIcon: String {
        state.playback.repeatOne ? "repeat.1" : "repeat"
    }

    private var isRepeatActive: Bool {
        state.playback.repeatOne || state.playback.repeatAll
    }

    private var repeatEcho: String {
        if state.playback.repeatOne { return TogetherCopy.repeatOneEcho }
        if state.playback.repeatAll { return TogetherCopy.repeatAllEcho }
        return TogetherCopy.inOrderEcho
    }

    /// 循环三态：关 → 全部循环 → 单曲循环 → 关。随机开关不动它。
    private func cycleRepeatMode() {
        let p = state.playback
        if p.repeatOne {
            TogetherStore.shared.setModes(repeatOne: false, repeatAll: false)
        } else if p.repeatAll {
            TogetherStore.shared.setModes(repeatOne: true, repeatAll: false)
        } else {
            TogetherStore.shared.setModes(repeatOne: false, repeatAll: true)
        }
    }

    // MARK: - 刻字

    private var noteComposer: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(String(format: AppLocalized("Engraved at %@", comment: "一起听 · 刻字位置"), mmss(player.currentTime)))
                .font(ChatFont.font(15, weight: .semibold))
                .foregroundStyle(CSSThemeVariables.textMain(scope: .chat))

            TextField(AppLocalized("Leave a line at this second", comment: "一起听 · 刻字输入占位"), text: $noteDraft, axis: .vertical)
                .font(ChatFont.font(14))
                .lineLimit(1...3)
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(CSSThemeVariables.optionBg(scope: .chat))
                )

            HStack(spacing: 10) {
                Button(AppLocalized("Cancel", comment: "取消")) {
                    noteDraft = ""
                    activeSheet = nil
                }
                .font(ChatFont.font(14))
                .foregroundStyle(CSSThemeVariables.textDim(scope: .chat))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Capsule().fill(CSSThemeVariables.optionBg(scope: .chat)))

                Button(AppLocalized("Save", comment: "保存")) {
                    commitNote()
                }
                .font(ChatFont.font(14, weight: .semibold))
                .foregroundStyle(CSSThemeVariables.accentFg(scope: .chat))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Capsule().fill(CSSThemeVariables.accent(scope: .chat)))
            }

            Spacer(minLength: 0)
        }
        .padding(22)
        .presentationDetents([.height(240)])
        .presentationBackground(CSSThemeVariables.bg(scope: .chat))
        .presentationDragIndicator(.visible)
    }

    private func commitNote() {
        let text = noteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let ok = TogetherStore.shared.addNote(at: player.currentTime, text: text, by: .user)
        guard ok else {
            MinisToast.show(TogetherCopy.oneLineOnly, systemImage: "exclamationmark.circle")
            return
        }
        hub.refreshNow()
        noteDraft = ""
        activeSheet = nil
    }

    private func triggerHeartbeat() {
        TogetherHaptics.select()
        heartbeatGen += 1
        let gen = heartbeatGen
        resonancePulse = true
        // 共振写盘节流：3 秒内连点只写一次。每一 tap 都全量写盘 + 记事件，
        // 是拿文件当鼓敲；光效和震动照常跑，点的手感不受影响。
        let now = Date()
        if lastResonanceWrite == nil || now.timeIntervalSince(lastResonanceWrite!) >= 3 {
            lastResonanceWrite = now
            let whisper = String(format: AppLocalized("%@ nudged %@", comment: "一起听 · 心动共振低语"), userName, aiName)
            TogetherStore.shared.triggerResonance(from: .user, whisper: whisper)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            if gen == heartbeatGen { resonancePulse = false }
        }
    }

    private func checkEcho(at pos: Double) {
        defer { echoLastPosition = pos }
        guard echoOn, let trackId = track?.id else { return }
        if pos < echoLastPosition - 1.5 || pos - echoLastPosition > 5 { return }

        let due = state.notes.filter { note in
            note.trackId == trackId && note.at > echoLastPosition && note.at <= pos
        }
        guard !due.isEmpty else { return }
        echoQueue.append(contentsOf: due)
        pumpEchoQueue(trackId: trackId)
    }

    private func pumpEchoQueue(trackId: String) {
        guard echoBubbles.isEmpty, !echoQueue.isEmpty else { return }
        let note = echoQueue.removeFirst()
        let corners: [(CGFloat, CGFloat)] = [(-72, -118), (78, -86), (-84, 74), (74, 104)]
        let corner = corners[echoCorner % corners.count]
        echoCorner += 1
        echoGen += 1
        let gen = echoGen

        let bubble = EchoBubble(
            id: note.id,
            text: note.text,
            name: note.from == TogetherActor.ai.rawValue ? ChatAddressing.assistant(sessionPersonaId: sessionPersonaId) : ChatAddressing.user(),
            time: TogetherEchoClock.label(note.ts),
            isAI: note.from == TogetherActor.ai.rawValue,
            dx: corner.0,
            dy: corner.1
        )
        echoBubbles = [bubble]

        // 只清掉"还是这一颗"的情况：换歌/新气泡/关回声后，旧的定时器不许动手。
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.65) {
            if gen == echoGen, echoBubbles.first?.id == bubble.id, player.track?.id == trackId {
                echoBubbles.removeAll()
                pumpEchoQueue(trackId: trackId)
            }
        }
    }

    private func bootstrap() {
        hub.refreshNow()
        // 她打开面板就是她在场：只刷新她这一方的 lastSeen，不替他报在线。
        TogetherStore.shared.markSeen(by: .user)
        player.restoreIfNeeded()
        if let t = hub.state.track, player.track == nil,
           let url = TogetherStore.shared.audioURL(for: t),
           !FileManager.default.fileExists(atPath: url.path) {
            restoreFailed = true
        }
        lyrics = player.track.flatMap { TogetherStore.shared.lyrics(for: $0) }
    }

    private func mmss(_ s: Double) -> String {
        let total = max(0, Int(s.rounded()))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: restoreFailed ? "exclamationmark.triangle" : "music.note")
                .font(ChatFont.font(48))
                .foregroundStyle(CSSThemeVariables.textDim(scope: .chat).opacity(0.4))
            Text(restoreFailed ? TogetherCopy.fileMissing : TogetherCopy.nothingPlaying)
                .font(ChatFont.font(14, weight: .medium))
                .foregroundStyle(CSSThemeVariables.textMain(scope: .chat))
                .multilineTextAlignment(.center)
            Text(TogetherCopy.emptyHint(aiName))
                .font(ChatFont.font(12))
                .foregroundStyle(CSSThemeVariables.textDim(scope: .chat))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button {
                TogetherHaptics.select()
                selectedTab.wrappedValue = .library
            } label: {
                Text(TogetherCopy.browseSongs)
                    .font(ChatFont.font(14, weight: .semibold))
                    .foregroundStyle(CSSThemeVariables.accentFg(scope: .chat))
                    .padding(.horizontal, 20)
                    .frame(minHeight: 44)
                    .background(Capsule().fill(CSSThemeVariables.accent(scope: .chat)))
            }
            .togetherPress()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 原位滚动歌词视图（图1同款）

struct TogetherInlineLyricsView: View {

    let track: TogetherTrack
    let lyrics: TogetherLyrics?
    let loopLine: String?
    let position: Double
    let onSeek: (Double) -> Void

    /// 她亲手在翻歌词：自动滚停下，不跟她抢。
    @State private var userBrowsing = false
    /// center() 的代次：旧的延迟滚动不许在换歌/点回正中后还动手。
    @State private var centerGen = 0

    private var timedLines: [TogetherLyricLine]? {
        guard let lyr = lyrics, lyr.timed, !lyr.lines.isEmpty else { return nil }
        return lyr.lines
    }

    private var currentIndex: Int {
        guard let lyr = lyrics, lyr.timed, !lyr.lines.isEmpty else { return -1 }
        let t = position - lyr.offset
        var hit = -1
        for (i, line) in lyr.lines.enumerated() {
            if line.at <= t { hit = i } else { break }
        }
        return hit
    }

    /// 歌词块：不再铺满整页、不再靠点击切回黑胶。
    /// 高度由外层给（跟随剩余空间），块内只显示整数行：
    /// 行高固定、显示区高度取行高的整数倍，所以上下边缘永远不出现半截字。
    var body: some View {
        GeometryReader { geo in
            // 行高跟着"整体字号"走：字大了行也长，永远不出现半截字。
            // ChatFont 按 FontSettings.scaledApp 放大，行高必须同比例放大才对得上。
            let scale = FontSettings.shared.scaledApp(17) / 17
            let rowH: CGFloat = (geo.size.height > 240 ? 26 : 22) * scale
            let rows = max(1, Int(geo.size.height / rowH))
            let visible = CGFloat(rows) * rowH

            if let lines = timedLines, !lines.isEmpty {
                ScrollViewReader { proxy in
                    ZStack(alignment: .bottom) {
                        ScrollView(showsIndicators: false) {
                            LazyVStack(spacing: 0) {
                                ForEach(Array(lines.enumerated()), id: \.offset) { idx, line in
                                    lyricLine(line, isCurrent: idx == currentIndex)
                                        .frame(height: rowH)
                                        .id(idx)
                                }
                            }
                            .scrollTargetLayout()
                            // 首尾各留半屏，第一句和最后一句也能停在正中
                            .padding(.vertical, (visible - rowH) / 2)
                        }
                        .frame(height: visible)
                        // 松手就对齐到整行：静止时边缘不会是半行
                        .scrollTargetBehavior(.viewAligned)
                        .onAppear { center(proxy, animated: false) }
                        .onChange(of: currentIndex) { _ in center(proxy, animated: true) }
                        .onChange(of: track.id) { _ in
                            userBrowsing = false
                            centerGen += 1
                        }
                        .onScrollPhaseChange { _, newPhase in
                            // 她亲手在翻：自动滚停下，等她点"回到当前这一句"。
                            // 程序自己滚（.animating）不算手动，不拦。
                            if newPhase == .interacting {
                                userBrowsing = true
                            }
                        }

                        // 回到当前这一句：只有她手动翻开后才出现，点一下回到正中。
                        if userBrowsing, currentIndex >= 0 {
                            Button {
                                TogetherHaptics.select()
                                userBrowsing = false
                                centerGen += 1
                                center(proxy, animated: true)
                            } label: {
                                Text(TogetherCopy.backToCurrent)
                                    .font(ChatFont.font(11, weight: .semibold))
                                    .foregroundStyle(CSSThemeVariables.accentFg(scope: .chat))
                                    .padding(.horizontal, 14)
                                    .frame(minHeight: 44)
                                    .background(Capsule().fill(CSSThemeVariables.accent(scope: .chat)))
                            }
                            .togetherPress()
                            .padding(.bottom, 4)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            } else {
                // 没歌词：一句能读的提示，不再占整页
                VStack(spacing: 8) {
                    Text(loopLine ?? TogetherCopy.noLyrics)
                        .font(ChatFont.font(15, weight: .medium))
                        .foregroundStyle(CSSThemeVariables.textMain(scope: .chat))
                        .multilineTextAlignment(.center)
                    Text(TogetherCopy.noLyricsHint)
                        .font(ChatFont.font(11))
                        .foregroundStyle(CSSThemeVariables.textDim(scope: .chat))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func lyricLine(_ line: TogetherLyricLine, isCurrent: Bool) -> some View {
        Text(line.text)
            .font(ChatFont.font(isCurrent ? 17 : 13, weight: isCurrent ? .bold : .regular))
            .foregroundStyle(
                isCurrent
                    ? CSSThemeVariables.textMain(scope: .chat)
                    : CSSThemeVariables.textDim(scope: .chat)
            )
            // 不压整页、不加阴影：靠字号和字重拉开当前行，颜色只用主题本色。
            .multilineTextAlignment(.center)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity)
            .animation(.easeOut(duration: 0.26), value: isCurrent)
            .contentShape(Rectangle())
            .onTapGesture {
                userBrowsing = false
                onSeek(line.at)
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(line.text)
    }

    /// 布局完成后再滚，否则 onAppear 时还没有尺寸，滚不动。
    /// 她在手动翻歌词时不滚；代次变了（换歌/点了回正中）旧调用作废。
    private func center(_ proxy: ScrollViewProxy, animated: Bool) {
        let idx = currentIndex
        guard idx >= 0, !userBrowsing else { return }
        centerGen += 1
        let gen = centerGen
        DispatchQueue.main.async {
            guard gen == centerGen, !userBrowsing, idx == currentIndex else { return }
            if animated {
                withAnimation(.easeOut(duration: 0.38)) {
                    proxy.scrollTo(idx, anchor: .center)
                }
            } else {
                proxy.scrollTo(idx, anchor: .center)
            }
        }
    }
}

// MARK: - 回声气泡视图

struct EchoBubble: Identifiable, Equatable {
    let id: String
    let text: String
    let name: String
    let time: String
    let isAI: Bool
    let dx: CGFloat
    let dy: CGFloat
}

struct EchoBubbleView: View {
    let bubble: EchoBubble
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var t: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(bubble.name).fontWeight(.semibold)
                Text(bubble.time)
            }
            .font(ChatFont.font(9))
            .foregroundStyle(CSSThemeVariables.textDim(scope: .chat))

            Text(bubble.text)
                .font(ChatFont.font(12))
                .foregroundStyle(CSSThemeVariables.textMain(scope: .chat))
                .lineLimit(4)
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .frame(maxWidth: 220, alignment: .leading)
        .background(
            Capsule().fill(
                bubble.isAI
                    ? CSSThemeVariables.card(scope: .chat).opacity(0.95)
                    : CSSThemeVariables.optionBg(scope: .chat)
            )
        )
        .overlay(
            Capsule().strokeBorder(CSSThemeVariables.bg(scope: .chat).opacity(0.95), lineWidth: 0.5)
        )
        // 进场一次：放大淡入、停住、淡出。没有模糊（糊的那一下最像卡顿），
        // 减弱动效时直接出现，不做动画。
        .scaleEffect(scaleValue)
        .opacity(opacityValue)
        .offset(y: riseValue)
        .onAppear {
            if reduceMotion {
                t = 0.5
            } else {
                withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 4.6)) { t = 1 }
            }
        }
    }

    private var seg: CGFloat { t < 0.5 ? t / 0.5 : (t - 0.5) / 0.5 }
    private var scaleValue: CGFloat { t < 0.5 ? 0.35 + 0.65 * seg : 1 - 0.6 * seg }
    private var opacityValue: Double { t < 0.5 ? Double(seg) : Double(1 - seg) }
    private var riseValue: CGFloat { t < 0.5 ? 12 - 12 * seg : -14 * seg }
}

enum TogetherEchoClock {
    static func label(_ ts: Int) -> String {
        guard ts > 0 else { return "" }
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        f.locale = Locale(identifier: "zh_CN")
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }
}


/// 系统玻璃唱片：纯视觉，不可点、不接手势。
///
/// 之前那版会"变大压住整屏"：玻璃层跟着 0.5 秒步进的旋转一起重绘，
/// 玻璃采样区画出了自己的 frame。这一版把玻璃层钉死不动——
/// 只有里面的纹路和中心标在转，玻璃层本身是静态的、裁进圆里的、
/// 不参与命中测试的。转速也不再靠 0.5 秒一跳的动画，
/// 而是 TimelineView 按真实播放时间连续算出来的角度，暂停就冻住，
/// 减弱动效时直接停转。
struct TogetherDiscView: View {
    let size: CGFloat
    let trackId: String
    let isPlaying: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 转动锚点：这轮转是从哪一刻开始的。暂停时把角度存下来，恢复时接上。
    @State private var anchorDate = Date()
    @State private var pausedAngle: Double = 0

    /// 一圈 22 秒，和旧版一致。
    private static let secondsPerRevolution = 22.0

    var body: some View {
        ZStack {
            // 盘身：玻璃层静态，纹路 + 中心标在里面转。
            ZStack {
                Circle()
                    .fill(Color.clear)
                    .glassEffect(.regular, in: .circle)
                    .allowsHitTesting(false)

                rotatingGroup
            }
            .frame(width: size, height: size)
            .clipShape(Circle())
            .contentShape(Circle())

            arm
        }
        .frame(width: size, height: size)
        .allowsHitTesting(false)
        .onChange(of: trackId) { _ in
            anchorDate = Date()
            pausedAngle = 0
        }
        .onChange(of: isPlaying) { playing in
            if playing {
                // 从冻住的角度接上转，不跳变。
                anchorDate = Date().addingTimeInterval(-pausedAngle / 360 * Self.secondsPerRevolution)
            } else {
                pausedAngle = rawAngle(at: Date())
            }
        }
    }

    /// 转动组：播着 + 不减弱动效时用 TimelineView 连续转；
    /// 停着或减弱动效时静态定格，不白占帧。
    @ViewBuilder
    private var rotatingGroup: some View {
        if isPlaying, !reduceMotion {
            TimelineView(.animation) { timeline in
                discInterior
                    .rotationEffect(.degrees(angle(at: timeline.date)))
            }
        } else {
            discInterior
                .rotationEffect(.degrees(reduceMotion ? 0 : pausedAngle))
        }
    }

    private var discInterior: some View {
        ZStack {
            rings
            label
            hole
        }
        .frame(width: size, height: size)
    }

    private func angle(at date: Date) -> Double {
        reduceMotion ? 0 : rawAngle(at: date)
    }

    /// 只看锚点算角度，不管播没播：暂停那一刻就是靠它把角度冻住的。
    private func rawAngle(at date: Date) -> Double {
        let elapsed = date.timeIntervalSince(anchorDate)
        return (elapsed / Self.secondsPerRevolution * 360).truncatingRemainder(dividingBy: 360)
    }

    /// 纹路用中性黑白极淡叠出来的，不取主题色：任何底上都看得见，也不改变玻璃的通透。
    /// 14 圈：210pt 的盘上和 25 圈肉眼无差，少一半描边。
    private var rings: some View {
        ForEach(1..<15, id: \.self) { i in
            Circle()
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.22), Color.black.opacity(0.12)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.8
                )
                .padding(size / 2 * CGFloat(i) / 15 * 0.94)
        }
    }

    /// 中心标：系统材质圆片，字用系统次级颜色，深浅底上都读得清。
    private var label: some View {
        Circle()
            .fill(.regularMaterial)
            .frame(width: size * 0.552, height: size * 0.552)
            .overlay(
                Image(systemName: "headphones")
                    .font(ChatFont.font(size * 0.16, weight: .regular))
                    .foregroundStyle(.secondary)
            )
    }

    private var hole: some View {
        Circle()
            .fill(Color.black.opacity(0.45))
            .frame(width: 6, height: 6)
    }

    private var arm: some View {
        HStack {
            Spacer()
            Capsule()
                // 唱臂也走中性色：跟着文字色走会在深底上消失。
                .fill(LinearGradient(colors: [Color.white.opacity(0.55), Color.black.opacity(0.28)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: 2.5, height: size * 0.384)
                .rotationEffect(.degrees(21))
                .offset(x: -6, y: -size * 0.30)
        }
        .frame(width: size + 26)
        .allowsHitTesting(false)
    }
}





//
//  TogetherDrawers.swift
//  MinisApp
//
//  一起听 · 底部抽屉组件：
//  1. 历史回声墙（整首歌我们所有的刻字，点击直达回声，底部带输入框）
//  2. 播放队列（查看下一首放什么，点歌切歌）
//


// MARK: - 1. 历史回声墙抽屉

struct TogetherEchoDrawerView: View {

    let track: TogetherTrack
    let onSeek: (Double) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.togetherPersonaId) private var sessionPersonaId
    @ObservedObject private var hub = TogetherStateHub.shared
    @State private var draft = ""

    private var state: TogetherState { hub.state }

    private var notes: [TogetherNote] {
        state.notes
            .filter { $0.trackId == track.id }
            .sorted { $0.at < $1.at }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if notes.isEmpty {
                    emptyView
                } else {
                    list
                }

                Divider().overlay(CSSThemeVariables.divider(scope: .chat))
                inputBar
            }
            .background(CSSThemeVariables.bg(scope: .chat).ignoresSafeArea())
            .navigationTitle("\(TogetherCopy.historyEchoes) (\(notes.count))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(AppLocalized("Close", comment: "关闭")) { dismiss() }
                        .font(ChatFont.font(14, weight: .medium))
                        .foregroundStyle(CSSThemeVariables.textDim(scope: .chat))
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                        .togetherPress()
                }
            }
        }
    }

    private var emptyView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "bubble.left.and.bubble.right")
                .font(ChatFont.font(40))
                .foregroundStyle(CSSThemeVariables.textDim(scope: .chat).opacity(0.4))
            Text(AppLocalized("No lines on this song yet", comment: "一起听 · 回声空态"))
                .font(ChatFont.font(14, weight: .medium))
                .foregroundStyle(CSSThemeVariables.textDim(scope: .chat))
            Text(AppLocalized("Tap the pen to leave a line at this second", comment: "一起听 · 回声引导"))
                .font(ChatFont.font(11.5))
                .foregroundStyle(CSSThemeVariables.textDim(scope: .chat).opacity(0.8))
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(notes) { note in
                    HStack(alignment: .top, spacing: 12) {
                        Button {
                            TogetherHaptics.select()
                            onSeek(note.at)
                            dismiss()
                        } label: {
                            Text(mmss(note.at))
                                .font(ChatFont.font(11, weight: .bold))
                                .foregroundStyle(CSSThemeVariables.accent(scope: .chat))
                                .padding(.horizontal, 10)
                                .frame(minHeight: 44)
                                .background(Capsule().fill(CSSThemeVariables.accent(scope: .chat).opacity(0.12)))
                                .contentShape(Rectangle())
                        }
                        .togetherPress()

                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(note.from == TogetherActor.ai.rawValue ? ChatAddressing.assistant(sessionPersonaId: sessionPersonaId) : ChatAddressing.user())
                                    .font(ChatFont.font(11, weight: .semibold))
                                    .foregroundStyle(CSSThemeVariables.textMain(scope: .chat))
                                Text(TogetherEchoClock.label(note.ts))
                                    .font(ChatFont.font(9.5))
                                    .foregroundStyle(CSSThemeVariables.textDim(scope: .chat))
                            }

                            Text(note.text)
                                .font(ChatFont.font(13))
                                .foregroundStyle(CSSThemeVariables.textMain(scope: .chat))
                                .lineLimit(nil)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer()
                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(CSSThemeVariables.card(scope: .chat))
                    )
                }
            }
            .padding(18)
        }
    }

    private var inputBar: some View {
        HStack(spacing: 10) {
            TextField(AppLocalized("Leave a line at this second...", comment: "一起听 · 回声输入占位"), text: $draft)
                .textFieldStyle(.plain)
                .font(ChatFont.font(13.5))
                .foregroundStyle(CSSThemeVariables.textMain(scope: .chat))
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(CSSThemeVariables.optionBg(scope: .chat))
                )

            Button {
                sendNote()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(ChatFont.font(26))
                    .foregroundStyle(draft.trimmingCharacters(in: .whitespaces).isEmpty
                        ? CSSThemeVariables.textDim(scope: .chat).opacity(0.4)
                        : CSSThemeVariables.accent(scope: .chat))
            }
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .togetherPress()
            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func sendNote() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let currentPos = TogetherPlayer.shared.currentTime
        let ok = TogetherStore.shared.addNote(at: currentPos, text: text, by: .user, trackId: track.id)
        if ok {
            hub.refreshNow()
            draft = ""
        } else {
            MinisToast.show(TogetherCopy.oneLineOnly, systemImage: "exclamationmark.circle")
        }
    }

    private func mmss(_ s: Double) -> String {
        let total = max(0, Int(s.rounded()))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

// MARK: - 2. 播放队列抽屉
//
// 抽屉只说真话：显示的是"接下来按什么顺序放"，不是"曲库里有什么"。
// 随机时显示洗好的那副牌，已播过的那段标出来、当前这首标出播/停；
// 队列是空的就直说空，并把曲库顺序标明身份列出来——
// 以前这里拿整个曲库冒充"当前列表"，喜欢页 7 首、抽屉说 1 首的 bug
// 就是这么来的。

struct TogetherQueueDrawerView: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(\.togetherSelectedTab) private var selectedTab
    @ObservedObject private var player = TogetherPlayer.shared
    @ObservedObject private var hub = TogetherStateHub.shared

    private var state: TogetherState { hub.state }
    private var library: TogetherLibrary { hub.library }

    /// 存着的队列（trackId 顺序）。空 = 按曲库顺序播。
    private var storedQueue: [String] { state.playback.queue }

    /// 展示顺序：随机时是洗好的那副牌（shuffleOrder），否则就是存着的队列。
    private var displayOrder: [TogetherTrack] {
        let queued = storedQueue.compactMap { library.track(id: $0) }
        guard !queued.isEmpty else { return [] }
        guard state.playback.shuffle else { return queued }
        let saved = state.playback.shuffleOrder.filter { storedQueue.contains($0) }
        let missing = storedQueue.filter { !saved.contains($0) }
        let order = saved + missing
        let mapped = order.compactMap { library.track(id: $0) }
        return mapped.isEmpty ? queued : mapped
    }

    /// 当前这首在展示顺序里的位置。-1 = 当前这首不在这个列表里。
    private var currentIndex: Int {
        guard let id = player.track?.id else { return -1 }
        return displayOrder.firstIndex(where: { $0.id == id }) ?? -1
    }

    private var modeEcho: String {
        if state.playback.repeatOne { return TogetherCopy.repeatOneEcho }
        if state.playback.repeatAll { return TogetherCopy.repeatAllEcho }
        if state.playback.shuffle { return TogetherCopy.shuffleEcho }
        return TogetherCopy.inOrderEcho
    }

    /// 队列顶上的模式开关：随机 / 循环，点一下就改，不用回面板。
    /// 和面板底下那排是同一套写盘口（setModes），状态永远一致。
    /// 来源标在同一行：只写真的记下来的来源，没记就什么都不写，不编一个出来。
    private var modeControls: some View {
        Section {
            HStack(spacing: 10) {
                modeButton(
                    label: TogetherCopy.shuffleEcho,
                    systemImage: "shuffle",
                    active: state.playback.shuffle
                ) {
                    TogetherHaptics.select()
                    TogetherStore.shared.setModes(shuffle: !state.playback.shuffle)
                    hub.refreshNow()
                }
                modeButton(
                    label: repeatButtonLabel,
                    systemImage: state.playback.repeatOne ? "repeat.1" : "repeat",
                    active: state.playback.repeatOne || state.playback.repeatAll
                ) {
                    TogetherHaptics.select()
                    cycleRepeatMode()
                    hub.refreshNow()
                }
                if let source = queueSourceLabel {
                    Spacer(minLength: 0)
                    Text(source)
                        .font(ChatFont.font(11))
                        .foregroundStyle(CSSThemeVariables.textDim(scope: .chat))
                        .lineLimit(1)
                }
            }
            .listRowBackground(CSSThemeVariables.bg(scope: .chat))
        }
    }

    private var repeatButtonLabel: String {
        if state.playback.repeatOne { return TogetherCopy.repeatOneEcho }
        if state.playback.repeatAll { return TogetherCopy.repeatAllEcho }
        return TogetherCopy.a11yRepeat
    }

    /// 循环三态：关 → 全部循环 → 单曲循环 → 关。和面板底下那颗键同一套。
    private func cycleRepeatMode() {
        let p = state.playback
        if p.repeatOne {
            TogetherStore.shared.setModes(repeatOne: false, repeatAll: false)
        } else if p.repeatAll {
            TogetherStore.shared.setModes(repeatOne: true, repeatAll: false)
        } else {
            TogetherStore.shared.setModes(repeatOne: false, repeatAll: true)
        }
    }

    private func modeButton(label: String, systemImage: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                Text(label)
            }
            .font(ChatFont.font(12, weight: .medium))
            .foregroundStyle(active ? CSSThemeVariables.accentFg(scope: .chat) : CSSThemeVariables.textMain(scope: .chat))
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .background(Capsule().fill(active ? CSSThemeVariables.accent(scope: .chat) : CSSThemeVariables.optionBg(scope: .chat)))
            .contentShape(Rectangle())
        }
        .togetherPress()
        .accessibilityLabel(label)
    }

    /// 队列来源：只认点歌时记下来的那份（"liked" / "all-songs" / "library" / 歌单 id）。
    /// 没记（老文件、AI 接歌）就不写；歌单删了、名字没了，也不写。
    private var queueSourceLabel: String? {
        switch state.playback.queueSource {
        case "liked":
            return AppLocalized("Liked songs", comment: "一起听 · 喜欢列表")
        case "all-songs":
            return TogetherCopy.allSongs
        case "library":
            return TogetherCopy.libraryOrderTitle
        case let id?:
            return hub.state.playlists.first { $0.id == id && !$0.deleted }?.name
        case nil:
            return nil
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if displayOrder.isEmpty {
                    emptyQueueView
                } else if state.playback.shuffle, currentIndex >= 0 {
                    shuffledList
                } else {
                    plainList
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(CSSThemeVariables.bg(scope: .chat).ignoresSafeArea())
            .navigationTitle(TogetherCopy.queueTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(AppLocalized("Done", comment: "完成")) { dismiss() }
                        .font(ChatFont.font(14, weight: .semibold))
                        .foregroundStyle(CSSThemeVariables.accent(scope: .chat))
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                        .togetherPress()
                }
            }
        }
    }

    /// 随机 + 知道当前在哪：已播过的那段 + 接下来那段，分两组，当前这首钉在交界。
    private var shuffledList: some View {
        List {
            modeControls
            if currentIndex > 0 {
                Section {
                    ForEach(Array(displayOrder[0..<currentIndex].enumerated()), id: \.element.id) { idx, track in
                        queueRow(track, index: "\(idx + 1)", section: .played)
                    }
                } header: {
                    sectionHeader(TogetherCopy.playedSection)
                }
            }
            Section {
                ForEach(Array(displayOrder[currentIndex...].enumerated()), id: \.element.id) { offset, track in
                    queueRow(track, index: "\(currentIndex + offset + 1)", section: .upNext)
                }
            } header: {
                sectionHeader("\(TogetherCopy.upNextSection) · \(modeEcho)")
            }
        }
    }

    /// 顺序播放（或当前这首不在列表里）：一组到底，当前这首标出来。
    private var plainList: some View {
        List {
            modeControls
            Section {
                ForEach(Array(displayOrder.enumerated()), id: \.element.id) { idx, track in
                    queueRow(track, index: "\(idx + 1)", section: .plain)
                }
            } header: {
                sectionHeader("\(String(format: AppLocalized("%d songs in this list", comment: "一起听 · 队列数量"), displayOrder.count)) · \(modeEcho)")
            }
        }
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(ChatFont.font(11))
            .foregroundStyle(CSSThemeVariables.textDim(scope: .chat))
    }

    private enum QueueSection { case played, upNext, plain }

    private func queueRow(_ track: TogetherTrack, index: String, section: QueueSection) -> some View {
        let isCurrent = player.track?.id == track.id
        let trackNotes = state.notes.filter { $0.trackId == track.id }
        let hasNote = !trackNotes.isEmpty
        // 两人都刻过字（from 两边都有）：才是"我们一起刻的"，配一枚不一样的标记。
        // 只有一方刻过，还是原来那枚小引号。
        let hasJointNote = trackNotes.contains { $0.from == TogetherActor.user.rawValue }
            && trackNotes.contains { $0.from == TogetherActor.ai.rawValue }
        return Button {
            TogetherHaptics.select()
            // 点哪首就从哪首开始，队列保持存着的那一份（随机时游标跟过去，
            // 不重洗）；队列是空的才用曲库顺序当队列。
            let queue = storedQueue.isEmpty ? library.tracks.map { $0.id } : storedQueue
            // 来源留着原来那份（没存队列时才是曲库顺序）：换一首不许把来源洗掉。
            let source = storedQueue.isEmpty ? "library" : state.playback.queueSource
            if TogetherPlayer.shared.start(track, by: .user, queue: queue, queueSource: source) {
                dismiss()
            }
        } label: {
            TogetherQueueRow(
                track: track,
                index: index,
                isCurrent: isCurrent,
                isPlaying: player.isPlaying,
                hasNote: hasNote,
                hasJointNote: hasJointNote
            )
            .opacity(section == .played ? 0.55 : 1)
        }
        .togetherPress()
        .listRowBackground(CSSThemeVariables.bg(scope: .chat))
    }

    /// 队列是空的：直说空，再把曲库顺序标明身份列出来，点一首就以曲库为队列开始播。
    private var emptyQueueView: some View {
        List {
            modeControls
            Section {
                VStack(spacing: 8) {
                    Image(systemName: "list.bullet")
                        .font(ChatFont.font(32))
                        .foregroundStyle(CSSThemeVariables.textDim(scope: .chat).opacity(0.5))
                    Text(TogetherCopy.queueEmptyTitle)
                        .font(ChatFont.font(14, weight: .medium))
                        .foregroundStyle(CSSThemeVariables.textMain(scope: .chat))
                    Text(TogetherCopy.queueEmptyHint)
                        .font(ChatFont.font(12))
                        .foregroundStyle(CSSThemeVariables.textDim(scope: .chat))
                        .multilineTextAlignment(.center)
                    Button {
                        TogetherHaptics.select()
                        dismiss()
                        selectedTab.wrappedValue = .library
                    } label: {
                        Text(TogetherCopy.browseSongs)
                            .font(ChatFont.font(13, weight: .semibold))
                            .foregroundStyle(CSSThemeVariables.accentFg(scope: .chat))
                            .padding(.horizontal, 18)
                            .frame(minHeight: 44)
                            .background(Capsule().fill(CSSThemeVariables.accent(scope: .chat)))
                    }
                    .togetherPress()
                    .padding(.top, 4)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .listRowBackground(CSSThemeVariables.bg(scope: .chat))
            }
            if !library.tracks.isEmpty {
                Section {
                    ForEach(Array(library.tracks.enumerated()), id: \.element.id) { idx, track in
                        queueRow(track, index: "\(idx + 1)", section: .plain)
                    }
                } header: {
                    sectionHeader("\(TogetherCopy.libraryOrderTitle) · \(String(format: AppLocalized("%d songs in this list", comment: "一起听 · 队列数量"), library.tracks.count))")
                } footer: {
                    Text(TogetherCopy.queueEmptyHint)
                        .font(ChatFont.font(11))
                        .foregroundStyle(CSSThemeVariables.textDim(scope: .chat))
                }
            }
        }
    }
}

private struct TogetherQueueRow: View {
    let track: TogetherTrack
    let index: String
    let isCurrent: Bool
    let isPlaying: Bool
    let hasNote: Bool
    /// 两人都刻过字：合刻标记，和单方刻字的引号不一样。
    let hasJointNote: Bool

    var body: some View {
        HStack(spacing: 12) {
            if isCurrent {
                Image(systemName: isPlaying ? "speaker.wave.2.fill" : "pause.fill")
                    .font(ChatFont.font(13))
                    .foregroundStyle(CSSThemeVariables.accent(scope: .chat))
                    .frame(width: 20)
            } else {
                Text(index)
                    .font(ChatFont.font(12, weight: .medium))
                    .foregroundStyle(CSSThemeVariables.textDim(scope: .chat))
                    .frame(width: 20)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title.isEmpty ? TogetherCopy.untitledTrack : track.title)
                    .font(ChatFont.font(13.5, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? CSSThemeVariables.accent(scope: .chat) : CSSThemeVariables.textMain(scope: .chat))
                    .lineLimit(1)

                Text(track.artist)
                    .font(ChatFont.font(10.5))
                    .foregroundStyle(CSSThemeVariables.textDim(scope: .chat))
                    .lineLimit(1)
            }

            Spacer()

            // 刻字标记：两人都刻过是一枚实心引号气泡（合刻），
            // 只有一方刻过是原来那枚小引号，不抢眼。
            if hasJointNote {
                Image(systemName: "quote.bubble.fill")
                    .font(ChatFont.font(12, weight: .semibold))
                    .foregroundStyle(CSSThemeVariables.accent(scope: .chat))
            } else if hasNote {
                Image(systemName: "text.quote")
                    .font(ChatFont.font(10, weight: .semibold))
                    .foregroundStyle(CSSThemeVariables.textDim(scope: .chat))
            }

            Text(durationText)
                .font(ChatFont.font(11))
                .foregroundStyle(CSSThemeVariables.textDim(scope: .chat))
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }

    private var durationText: String {
        let total = max(0, Int(track.duration.rounded()))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}


//  TogetherThemeCenterView.swift
//  MinisApp
//
//  一起听 · 独立装扮与壁纸中心。
//  彻底告别长按隐蔽手势。我和醒醒都能随时换，AI 在后台也能通过 together wallpaper 一键换。
//


struct TogetherThemeCenterView: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(\.togetherPersonaId) private var sessionPersonaId

    @State private var activeSlot: String?
    @State private var pickerItem: PhotosPickerItem?
    @State private var showPicker = false

    private var aiName: String { ChatAddressing.assistant(sessionPersonaId: sessionPersonaId) }
    private var userName: String { ChatAddressing.user() }

    private let slots: [(id: String, title: String, subtitle: String)] = [
        // 歌词页不再单独一张卡：播放页这张就是全屏唯一壁纸，歌词页共用它。
        (TogetherImages.wallpaperNow, TogetherCopy.nowPlayingWallpaper, AppLocalized("One full-screen wallpaper for the player and the lyrics", comment: "一起听 · 播放页壁纸说明")),
        (TogetherImages.wallpaperLibrary, TogetherCopy.libraryWallpaper, AppLocalized("Wallpaper behind your playlist lists", comment: "一起听 · 歌单库壁纸说明")),
        (TogetherImages.wallpaperSync, TogetherCopy.syncWallpaper, AppLocalized("Background for the together page", comment: "一起听 · 伴听页壁纸说明")),
        (TogetherImages.wallpaperLiked, TogetherCopy.likedWallpaper, AppLocalized("Wallpaper behind liked songs", comment: "一起听 · 喜欢页壁纸说明")),
    ]

    private let columns = [
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14)
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    headerBanner
                        .padding(.horizontal, 20)
                        .padding(.top, 14)

                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(slots, id: \.id) { slot in
                            slotCard(slot)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 30)
                }
            }
            .background(CSSThemeVariables.bg(scope: .chat).ignoresSafeArea())
            .navigationTitle(TogetherCopy.themeCenter)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(AppLocalized("Done", comment: "完成")) {
                        dismiss()
                    }
                    .font(ChatFont.font(14, weight: .semibold))
                    .foregroundStyle(CSSThemeVariables.accent(scope: .chat))
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
                    .togetherPress()
                }
            }
            // 坑:呈现条件不能挂在 activeSlot 上。相册一关,SwiftUI 会先把这里 set(false)
            // 跑掉、activeSlot 被清空,紧接着 onChange 才拿到选中的图,slot 已是 nil,
            // 直接静默 return —— 表现就是"能进相册,选完没反应"。两者解耦,只由按钮清。
            .photosPicker(isPresented: $showPicker, selection: $pickerItem, matching: .images)
            .onChange(of: pickerItem) { item in
                guard let item, let slot = activeSlot else { return }
                Task {
                    await TogetherPhotoImport.toSlot(item, slot: slot)
                    pickerItem = nil
                    activeSlot = nil
                }
            }
        }
    }

    private var headerBanner: some View {
        HStack(spacing: 14) {
            Image(systemName: "sparkles")
                .font(ChatFont.font(24))
                .foregroundStyle(CSSThemeVariables.accent(scope: .chat))

            VStack(alignment: .leading, spacing: 3) {
                Text(String(format: AppLocalized("%@ & %@'s music nook", comment: "一起听 · 装扮中心横幅标题"), userName, aiName))
                    .font(ChatFont.font(14, weight: .semibold))
                    .foregroundStyle(CSSThemeVariables.textMain(scope: .chat))
                Text(AppLocalized("Tap a picture to change it", comment: "一起听 · 装扮中心横幅说明"))
                    .font(ChatFont.font(11))
                    .foregroundStyle(CSSThemeVariables.textDim(scope: .chat))
            }
            Spacer()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(CSSThemeVariables.card(scope: .chat))
        )
    }

    private func slotCard(_ slot: (id: String, title: String, subtitle: String)) -> some View {
        let hasCustom = TogetherImages.url(for: slot.id) != nil

        return VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                // 图片区本身就是按钮：点预览图、点空占位，和下面那颗按钮完全等价。
                // 以前只有按钮能用，横幅却写着"点封面直接换"，文案和实际不符。
                Button {
                    activeSlot = slot.id
                    showPicker = true
                } label: {
                    if let url = TogetherImages.url(for: slot.id),
                       let img = TogetherImages.cachedImage(for: url) {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFill()
                            .frame(height: 120)
                            .frame(maxWidth: .infinity)
                            .clipped()
                    } else {
                        TogetherCover.fill(slot.id)
                            .frame(height: 120)
                            .frame(maxWidth: .infinity)
                            .overlay(
                                Image(systemName: "photo.on.rectangle")
                                    .font(ChatFont.font(26))
                                    .foregroundStyle(CSSThemeVariables.card(scope: .chat).opacity(0.8))
                            )
                    }
                }
                .togetherPress()

                if hasCustom {
                    Button {
                        TogetherHaptics.select()
                        TogetherStore.shared.clearImage(slot: slot.id)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(ChatFont.font(18))
                            .foregroundStyle(CSSThemeVariables.danger(scope: .chat))
                            // 叉号底下的实心圆：让红色在照片上读得出来，
                            // 用主题底色，不许硬写白——深色主题里白盘子会跳出来。
                            .background(Circle().fill(CSSThemeVariables.bg(scope: .chat)))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .togetherPress()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(slot.title)
                    .font(ChatFont.font(12, weight: .medium))
                    .foregroundStyle(CSSThemeVariables.textMain(scope: .chat))
                    .lineLimit(1)
                Text(slot.subtitle)
                    .font(ChatFont.font(9.5))
                    .foregroundStyle(CSSThemeVariables.textDim(scope: .chat))
                    .lineLimit(1)
            }

            Button {
                TogetherHaptics.select()
                activeSlot = slot.id
                showPicker = true
            } label: {
                Text(TogetherCopy.changeWallpaper)
                    .font(ChatFont.font(11, weight: .medium))
                    .foregroundStyle(CSSThemeVariables.accent(scope: .chat))
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 44)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(CSSThemeVariables.optionBg(scope: .chat))
                    )
            }
            .togetherPress()
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(CSSThemeVariables.card(scope: .chat))
        )
    }
}

private struct SlotItem: Identifiable {
    let id: String
}

/// 面板同一时刻只展示一个弹层，靠这个枚举切。
private enum PanelSheet: String, Identifiable {
    case echo, note, queue, theme
    var id: String { rawValue }
}
