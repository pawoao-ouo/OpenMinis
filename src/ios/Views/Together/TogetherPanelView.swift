//
//  TogetherPanelView.swift
//  MinisApp
//
//  一起听 · 播放主界面。
//  彻底对齐现代音乐 App 架构（图1 & 图2）：
//  1. 顶栏：返回 + 心动共振小挂件 + 歌名/歌手 + 装扮中心 & 回声开关
//  2. 中间大视觉区：黑胶 ⇄ 原位歌词（点击原位无缝翻转切换，再点翻回）
//  3. 底部控制区：整体下沉沉底，动作行 + 进度条 + 控制器按键 + 播放队列 & 历史回声墙
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers
import PhotosUI

struct TogetherPanelView: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(\.togetherPersonaId) private var sessionPersonaId
    @ObservedObject private var player = TogetherPlayer.shared

    @State private var state = TogetherStore.shared.load()
    @State private var lyrics: TogetherLyrics?
    @State private var optimisticPosition: Double = 0
    @State private var isDragging = false

    /// 回声气泡
    @State private var echoOn = true
    @State private var echoBubbles: [EchoBubble] = []
    @State private var echoQueue: [TogetherNote] = []
    @State private var echoLastPosition: Double = 0
    @State private var echoCorner: Int = 0

    /// 抽屉与中心弹窗：同一视图只挂一个 .sheet，靠这个枚举切换。
    /// 以前四个 .sheet(isPresented:) 叠在同一个视图上会互相顶掉——
    /// 刻字弹窗被回声墙抽屉抢掉就是这么来的。
    @State private var activeSheet: PanelSheet?
    @State private var noteDraft = ""

    /// 小惊喜：心动共振光效脉冲
    @State private var resonancePulse = false

    private let ticker = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
    private var track: TogetherTrack? { state.track ?? player.track }
    private var aiName: String { ChatAddressing.assistant(sessionPersonaId: sessionPersonaId) }
    private var userName: String { ChatAddressing.user() }

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let s = min(1.15, max(0.85, h / 852))

            ZStack {
                pageBackground

                // 心动微光光环
                if resonancePulse {
                    Circle()
                        .fill(RadialGradient(
                            colors: [Color.pink.opacity(0.35), Color.clear],
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
                            discSection(s: s)

                            titleBlock(t, s)

                            // 歌词块：跟随进度滚、当前行加粗、点一行跳过去。
                            // 高度收死在这里，不许把下面的进度条和控制排顶出屏幕。
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
                            .frame(maxWidth: .infinity)
                            .frame(height: lyricBlockHeight(h: h, s: s))
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
        .onReceive(ticker) { _ in
            let fresh = TogetherStore.shared.load()
            if fresh.revision != state.revision { state = fresh }
        }
        .onChange(of: player.track?.id) { _ in
            state = TogetherStore.shared.load()
            lyrics = player.track.flatMap { TogetherStore.shared.lyrics(for: $0) }
            echoBubbles.removeAll()
            echoQueue.removeAll()
            echoLastPosition = player.currentTime
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

    // MARK: - 背景

    // 壁纸永远只当背景铺，绝不当 ZStack 的兄弟视图。
    //
    // 以前这里是 `ZStack { bg; Image.scaledToFill() }`，被塞进 body 的 ZStack 当兄弟。
    // scaledToFill 会把这个 ZStack 撑到「至少铺满且保持比例」——图比例和屏幕不一致时
    // 它比屏幕大，GeometryReader 又按左上角摆放，超出的部分全往右下挤，于是整页元素
    // 右移、压到唱片上，四功能行被顶出屏幕。换一张别的比例的图就必现。
    //
    // 改成 .background：只按宿主尺寸铺，不参与布局，图多大都撑不动任何子视图。
    // 标 @MainActor：压色走 TogetherSkin（@MainActor），从非隔离的 computed property 里调会编译不过。
    // 整页唯一一张壁纸：播放页和歌词页共用它，切模式时背景一动不动。
    // 铺法和其它页同一套（TogetherWallpaperLayer），不会再出现「这边 scaledToFill
    // 从左上铺、那边独立一层裁到中段」的两段错位。
    // 标 @MainActor：这层里读的是 TogetherImages（无隔离）但沿用调用方的隔离，不动它。
    @MainActor private var pageBackground: some View {
        TogetherWallpaperLayer(slot: TogetherImages.wallpaperNow)
    }

    // MARK: - 顶栏

    private func topBar(_ s: CGFloat) -> some View {
        HStack(alignment: .center, spacing: 12) {
            // 关闭键只由容器 TogetherRootView 那一颗负责（四个 tab 都要有关闭键）。
            // 这里原来又挂了一颗 chevron.down：同样 topLeading、36pt vs 容器 34pt，
            // 起算只差 2pt，两圈叠在一起、点击也互抢。删页内这颗，留容器那颗。
            Color.clear.frame(width: 36, height: 36)

            Spacer()

            Text(TogetherCopy.title)
                .font(ChatFont.font(11, weight: .medium))
                .tracking(3)
                .foregroundStyle(CSSThemeVariables.textDim(scope: .chat))

            Spacer()

            // 右侧：装扮中心调色盘 + 回声开关
            HStack(spacing: 8) {
                Button {
                    activeSheet = .theme
                } label: {
                    Image(systemName: "paintpalette.fill")
                        .font(ChatFont.font(13))
                        .foregroundStyle(CSSThemeVariables.accent(scope: .chat))
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(CSSThemeVariables.optionBg(scope: .chat).opacity(0.8)))
                }
                .buttonStyle(.plain)

                Button {
                    echoOn.toggle()
                    if !echoOn {
                        echoBubbles.removeAll()
                        echoQueue.removeAll()
                    }
                } label: {
                    Image(systemName: echoOn ? "bubble.left.and.bubble.right.fill" : "bubble.left.and.bubble.right")
                        .font(ChatFont.font(13))
                        .foregroundStyle(echoOn ? CSSThemeVariables.accent(scope: .chat) : CSSThemeVariables.textDim(scope: .chat))
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(CSSThemeVariables.optionBg(scope: .chat).opacity(0.8)))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
    }

    private var duoMiniBadge: some View {
        HStack(spacing: -5) {
            PersonaAvatarView(iconRef: TogetherIdentity.userIcon, size: 18)
                .clipShape(Circle())
            PersonaAvatarView(iconRef: TogetherIdentity.aiIcon(sessionPersonaId: sessionPersonaId), size: 18)
                .clipShape(Circle())
        }
        .padding(2)
        .background(Capsule().fill(CSSThemeVariables.card(scope: .chat)))
    }

    // MARK: - 黑胶（同页常驻，不再当切换开关）

    /// 黑胶和歌词同页同时出现，点唱片不再切页，所以 onTap 是空的、只留着点击判定。
    private func discSection(s: CGFloat) -> some View {
        ZStack {
            TogetherDiscView(
                size: 236 * s,
                spinDegrees: player.currentTime / 22.0 * 360,
                isPlaying: player.isPlaying
            ) {}

            // 回声弹幕浮在黑胶四周
            ForEach(echoBubbles) { bubble in
                EchoBubbleView(bubble: bubble)
                    .offset(x: bubble.dx * s, y: bubble.dy * s)
                    .allowsHitTesting(false)
            }
        }
        .frame(height: 244 * s)
    }


    // MARK: - 我们的头像

    private func duoHeader(_ s: CGFloat) -> some View {
        VStack(spacing: 9 * s) {
            HStack(spacing: -14 * s) {
                avatar(TogetherIdentity.aiIcon(sessionPersonaId: sessionPersonaId), size: 104 * s, ring: 3 * s)
                    .zIndex(1)
                avatar(TogetherIdentity.userIcon, size: 104 * s, ring: 3 * s)
            }
            .onTapGesture { triggerHeartbeat() }

            Text("\(aiName) & \(userName)")
                .font(ChatFont.font(11, weight: .medium))
                .tracking(1.4)
                .foregroundStyle(CSSThemeVariables.textDim(scope: .chat))
        }
        .padding(.top, 10 * s)
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
        // 壁纸原样亮着，标题和歌手就得自己站得住：只给文字做局部阴影，不压整页。
    }

    /// 歌词块高度：能看清当前行和前后几行，又不把进度条和控制排顶出屏幕。
    /// 屏大给得多，屏小收着给，永远留出底部控制区的位置。
    private func lyricBlockHeight(h: CGFloat, s: CGFloat) -> CGFloat {
        let reserved = (44 + 120 + 244 + 96 + 30 + 140) * s   // 顶栏/头像/黑胶/歌名/小图标排/控制区
        let spare = max(0, h - reserved - 40)
        return max(84, min(150 * s, spare))
    }

    // MARK: - 底部控制套件（沉底布局）

    private func bottomControlSuite(_ t: TogetherTrack, s: CGFloat) -> some View {
        VStack(spacing: 18 * s) {
            // 1. 进度条（喜欢、回声、刻字收在它上面那一排小图标里，不占大块）
            progressBar(s: s)

            // 2. 核心播放控制排（播放模式、上一首、播放/暂停、下一首、播放队列）
            mainControlsRow(s: s)
        }
        // 控制区整块给一圈局部阴影：不压整页，按键和时间在杂图上也看得清。
    }

    /// 喜欢 / 回声 / 刻字：收成一排小图标，夹在歌词块和进度条中间。
    /// 功能一个不少，只是不再一人占四分之一的宽度。
    private func actionRow(_ t: TogetherTrack, s: CGFloat) -> some View {
        let liked = state.liked.contains(t.id)
        let noteCount = state.notes.filter { $0.trackId == t.id }.count

        return HStack(spacing: 34 * s) {
            // 喜欢
            Button {
                TogetherStore.shared.toggleLike(trackId: t.id, by: .user)
                state = TogetherStore.shared.load()
            } label: {
                Image(systemName: liked ? "heart.fill" : "heart")
                    .font(ChatFont.font(16 * s))
                    .foregroundStyle(liked ? Color.red : CSSThemeVariables.textDim(scope: .chat))
                    .frame(width: 30 * s, height: 26 * s)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // 历史回声墙抽屉
            Button {
                activeSheet = .echo
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(ChatFont.font(15 * s))
                    if noteCount > 0 {
                        Text("\(noteCount)")
                            .font(ChatFont.font(9, weight: .bold))
                    }
                }
                .foregroundStyle(CSSThemeVariables.textDim(scope: .chat))
                .frame(height: 26 * s)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // 直接刻字（在这一秒留一句）
            Button {
                activeSheet = .note
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(ChatFont.font(15 * s))
                    .foregroundStyle(CSSThemeVariables.textDim(scope: .chat))
                    .frame(width: 30 * s, height: 26 * s)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
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
                        .fill(CSSThemeVariables.divider(scope: .chat).opacity(0.6))
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
                            isDragging = true
                            let r = min(1, max(0, value.location.x / max(width, 1)))
                            optimisticPosition = Double(r) * duration
                        }
                        .onEnded { value in
                            let r = min(1, max(0, value.location.x / max(width, 1)))
                            let target = Double(r) * duration
                            player.seek(to: target)
                            TogetherStore.shared.seek(to: target, by: .user)
                            isDragging = false
                        }
                )
            }
            .frame(height: 20)

            HStack {
                Text(mmss(pos))
                Spacer()
                Text(mmss(duration))
            }
            .font(ChatFont.font(10.5, weight: .medium))
            .foregroundStyle(CSSThemeVariables.textDim(scope: .chat).opacity(0.75))
        }
    }

    private func mainControlsRow(s: CGFloat) -> some View {
        HStack(spacing: 0) {
            // 播放模式切换（顺序 / 随机 / 单曲）
            Button {
                togglePlayMode()
            } label: {
                Image(systemName: playModeIcon)
                    .font(ChatFont.font(19 * s))
                    .foregroundStyle(isModeActive ? CSSThemeVariables.accent(scope: .chat) : CSSThemeVariables.textDim(scope: .chat))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)

            // 上一首
            Button {
                player.previousTrack()
                state = TogetherStore.shared.load()
            } label: {
                Image(systemName: "backward.fill")
                    .font(ChatFont.font(23 * s, weight: .medium))
                    .foregroundStyle(CSSThemeVariables.textMain(scope: .chat))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)

            // 播放/暂停大圆键
            Button {
                player.userToggle()
                state = TogetherStore.shared.load()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(ChatFont.font(26 * s, weight: .semibold))
                    .foregroundStyle(CSSThemeVariables.accentFg(scope: .chat))
                    .frame(width: 66 * s, height: 66 * s)
                    .background(CSSThemeVariables.accent(scope: .chat))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)

            // 下一首
            Button {
                player.nextTrack()
                state = TogetherStore.shared.load()
            } label: {
                Image(systemName: "forward.fill")
                    .font(ChatFont.font(23 * s, weight: .medium))
                    .foregroundStyle(CSSThemeVariables.textMain(scope: .chat))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)

            // 播放队列抽屉按钮
            Button {
                activeSheet = .queue
            } label: {
                Image(systemName: "list.bullet")
                    .font(ChatFont.font(19 * s))
                    .foregroundStyle(CSSThemeVariables.textDim(scope: .chat))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
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
        state = TogetherStore.shared.load()
        noteDraft = ""
        activeSheet = nil
    }

    private var playModeIcon: String {
        if state.playback.repeatOne { return "repeat.1" }
        if state.playback.shuffle { return "shuffle" }
        return "repeat"
    }

    private var isModeActive: Bool {
        state.playback.repeatOne || state.playback.shuffle
    }

    private func togglePlayMode() {
        if !state.playback.shuffle && !state.playback.repeatOne {
            // 顺序 -> 随机
            TogetherStore.shared.setShuffle(true)
            TogetherStore.shared.setRepeatOne(false)
        } else if state.playback.shuffle {
            // 随机 -> 单曲循环
            TogetherStore.shared.setShuffle(false)
            TogetherStore.shared.setRepeatOne(true)
        } else {
            // 单曲循环 -> 顺序
            TogetherStore.shared.setShuffle(false)
            TogetherStore.shared.setRepeatOne(false)
        }
        state = TogetherStore.shared.load()
    }

    private func triggerHeartbeat() {
        resonancePulse = true
        let whisper = String(format: AppLocalized("%@ nudged %@", comment: "一起听 · 心动共振低语"), userName, aiName)
        TogetherStore.shared.triggerResonance(from: .user, whisper: whisper)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            resonancePulse = false
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

        DispatchQueue.main.asyncAfter(deadline: .now() + 4.65) {
            echoBubbles.removeAll()
            pumpEchoQueue(trackId: trackId)
        }
    }

    private func bootstrap() {
        state = TogetherStore.shared.load()

        // 面板开着就说明两边都在线，别让"在线"永远停在离开。
        if !state.devices.user.online || !state.devices.ai.online {
            TogetherStore.shared.mutate(by: .user, event: "presence") { s in
                s.devices.user.online = true
                s.devices.user.lastSeen = TogetherStore.now()
                s.devices.ai.online = true
            }
            state = TogetherStore.shared.load()
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
            Image(systemName: "music.note")
                .font(ChatFont.font(48))
                .foregroundStyle(CSSThemeVariables.textDim(scope: .chat).opacity(0.4))
            Text(AppLocalized("Nothing playing right now", comment: "一起听 · 空态"))
                .font(ChatFont.font(14, weight: .medium))
                .foregroundStyle(CSSThemeVariables.textDim(scope: .chat))
            Spacer()
        }
    }
}

// MARK: - 原位滚动歌词视图（图1同款）

struct TogetherInlineLyricsView: View {

    let track: TogetherTrack
    let lyrics: TogetherLyrics?
    let loopLine: String?
    let position: Double
    let onSeek: (Double) -> Void

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
    /// 高度由调用方给定，块内自己跟随滚动，当前行居中加粗，点一行跳过去。
    var body: some View {
        GeometryReader { geo in
            let half = max(46, geo.size.height / 2)

            if let lines = timedLines, !lines.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: false) {
                        LazyVStack(spacing: 18) {
                            // 上下留白正好半个块高：第一句、最后一句也能停在正中
                            Color.clear.frame(height: max(10, half - 26))

                            ForEach(Array(lines.enumerated()), id: \.offset) { idx, line in
                                lyricLine(line, isCurrent: idx == currentIndex)
                                    .id(idx)
                            }

                            Color.clear.frame(height: max(10, half - 26))
                        }
                        .padding(.horizontal, 20)
                    }
                    .onAppear { center(proxy, animated: false) }
                    .onChange(of: currentIndex) { _ in center(proxy, animated: true) }
                }
            } else {
                // 没歌词：给一句能读的提示，不再占整页
                VStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Text(loopLine ?? TogetherCopy.noLyrics)
                        .font(ChatFont.font(15, weight: .medium))
                        .foregroundStyle(CSSThemeVariables.textMain(scope: .chat))
                        .multilineTextAlignment(.center)
                    Text(TogetherCopy.noLyricsHint)
                        .font(ChatFont.font(11))
                        .foregroundStyle(CSSThemeVariables.textDim(scope: .chat))
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity)
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
            .frame(maxWidth: .infinity)
            .scaleEffect(isCurrent ? 1.03 : 1.0)
            .animation(.easeOut(duration: 0.26), value: isCurrent)
            .contentShape(Rectangle())
            .onTapGesture { onSeek(line.at) }
    }

    /// 布局完成后再滚，否则 onAppear 时还没有尺寸，滚不动。
    private func center(_ proxy: ScrollViewProxy, animated: Bool) {
        let idx = currentIndex
        guard idx >= 0 else { return }
        DispatchQueue.main.async {
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
        .scaleEffect(scaleValue)
        .opacity(opacityValue)
        .blur(radius: blurValue)
        .offset(y: riseValue)
        .onAppear {
            withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 4.6)) { t = 1 }
        }
    }

    private var seg: CGFloat { t < 0.5 ? t / 0.5 : (t - 0.5) / 0.5 }
    private var scaleValue: CGFloat { t < 0.5 ? 0.35 + 0.65 * seg : 1 - 0.6 * seg }
    private var opacityValue: Double { t < 0.5 ? Double(seg) : Double(1 - seg) }
    private var blurValue: CGFloat { t < 0.5 ? 4 - 4 * seg : 3 * seg }
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


struct TogetherDiscView: View {
    let size: CGFloat
    let spinDegrees: Double
    let isPlaying: Bool
    let onTap: () -> Void

    var body: some View {
        ZStack {
            disc
                .rotationEffect(.degrees(spinDegrees))
                .animation(.linear(duration: 0.5), value: spinDegrees)
                .onTapGesture(perform: onTap)

            arm
        }
    }

    private var disc: some View {
        ZStack {
            Circle().fill(vinylFill)
            rings
            label
            hole
        }
        .frame(width: size, height: size)
    }

    private var vinylFill: RadialGradient {
        RadialGradient(colors: [TogetherSkin.vinyl.opacity(0.92),
                                TogetherSkin.vinyl,
                                TogetherSkin.vinyl],
                       center: .center, startRadius: 10, endRadius: size / 2)
    }

    private var rings: some View {
        ForEach(1..<26, id: \.self) { i in
            Circle()
                .strokeBorder(TogetherSkin.vinylRing, lineWidth: 1)
                .padding(size / 2 * CGFloat(i) / 26 * 0.94)
        }
    }

    private var label: some View {
        Circle()
            .fill(CSSThemeVariables.card(scope: .chat))
            .frame(width: size * 0.552, height: size * 0.552)
            .overlay(
                Image(systemName: "headphones")
                    .font(ChatFont.font(size * 0.16, weight: .light))
                    .foregroundStyle(CSSThemeVariables.textDim(scope: .chat))
            )
            .overlay(
                Circle().strokeBorder(CSSThemeVariables.bg(scope: .chat).opacity(0.25), lineWidth: 0.8)
            )
    }

    private var hole: some View {
        Circle()
            .fill(CSSThemeVariables.bg(scope: .chat).opacity(0.9))
            .frame(width: 6, height: 6)
    }

    private var arm: some View {
        HStack {
            Spacer()
            Capsule()
                .fill(CSSThemeVariables.textMain(scope: .chat).opacity(0.35))
                .frame(width: 2.5, height: size * 0.384)
                .rotationEffect(.degrees(21))
                .offset(x: -6, y: -size * 0.30)
        }
        .frame(width: size + 26)
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
    @State private var state = TogetherStore.shared.load()
    @State private var draft = ""

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
                            onSeek(note.at)
                            dismiss()
                        } label: {
                            Text(mmss(note.at))
                                .font(ChatFont.font(11, weight: .bold))
                                .foregroundStyle(CSSThemeVariables.accent(scope: .chat))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(CSSThemeVariables.accent(scope: .chat).opacity(0.12)))
                        }
                        .buttonStyle(.plain)

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
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
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
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
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
            .buttonStyle(.plain)
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
            state = TogetherStore.shared.load()
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

struct TogetherQueueDrawerView: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(\.togetherPersonaId) private var sessionPersonaId
    @ObservedObject private var player = TogetherPlayer.shared

    @State private var tracks: [TogetherTrack] = []

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { idx, track in
                        TogetherQueueRow(
                            track: track,
                            index: "\(idx + 1)",
                            isCurrent: player.track?.id == track.id
                        ) {
                            player.load(track)
                            TogetherStore.shared.play(trackId: track.id, at: 0, by: .user)
                            dismiss()
                        }
                    }
                } header: {
                    Text(String(format: AppLocalized("%d songs in this list", comment: "一起听 · 队列数量"), tracks.count))
                        .font(ChatFont.font(11))
                        .foregroundStyle(CSSThemeVariables.textDim(scope: .chat))
                }
            }
            .listStyle(.plain)
            .background(CSSThemeVariables.bg(scope: .chat).ignoresSafeArea())
            .navigationTitle(TogetherCopy.queueTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(AppLocalized("Done", comment: "完成")) { dismiss() }
                        .font(ChatFont.font(14, weight: .semibold))
                        .foregroundStyle(CSSThemeVariables.accent(scope: .chat))
                }
            }
            .onAppear {
                let lib = TogetherStore.shared.library()
                let ids = TogetherStore.shared.load().playback.queue
                let queued = ids.compactMap { lib.track(id: $0) }
                tracks = queued.isEmpty ? lib.tracks : queued
            }
        }
    }
}

private struct TogetherQueueRow: View {
    let track: TogetherTrack
    let index: String
    let isCurrent: Bool
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if isCurrent {
                Image(systemName: "speaker.wave.2.fill")
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
                Text(track.title)
                    .font(ChatFont.font(13.5, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? CSSThemeVariables.accent(scope: .chat) : CSSThemeVariables.textMain(scope: .chat))
                    .lineLimit(1)

                Text(track.artist)
                    .font(ChatFont.font(10.5))
                    .foregroundStyle(CSSThemeVariables.textDim(scope: .chat))
                    .lineLimit(1)
            }

            Spacer()

            Text(durationText)
                .font(ChatFont.font(11))
                .foregroundStyle(CSSThemeVariables.textDim(scope: .chat))
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }

    private var durationText: String {
        let total = max(0, Int(track.duration.rounded()))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

//
//  TogetherThemeCenterView.swift
//  MinisApp
//
//  一起听 · 独立装扮与壁纸中心。
//  彻底告别长按隐蔽手势。我和醒醒都能随时换，AI 在后台也能通过 together wallpaper 一键换。
//


struct TogetherThemeCenterView: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(\.togetherPersonaId) private var sessionPersonaId

    @State private var state = TogetherStore.shared.load()
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
                    state = TogetherStore.shared.load()
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
                .buttonStyle(.plain)

                if hasCustom {
                    Button {
                        TogetherStore.shared.clearImage(slot: slot.id)
                        state = TogetherStore.shared.load()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(ChatFont.font(18))
                            .foregroundStyle(CSSThemeVariables.danger(scope: .chat))
                            .background(Circle().fill(Color.white))
                            .padding(6)
                    }
                    .buttonStyle(.plain)
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
                activeSlot = slot.id
                showPicker = true
            } label: {
                Text(TogetherCopy.changeWallpaper)
                    .font(ChatFont.font(11, weight: .medium))
                    .foregroundStyle(CSSThemeVariables.accent(scope: .chat))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(CSSThemeVariables.optionBg(scope: .chat))
                    )
            }
            .buttonStyle(.plain)
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
