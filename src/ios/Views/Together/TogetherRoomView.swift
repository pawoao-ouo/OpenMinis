//
//  TogetherRoomView.swift
//  MinisApp
//
//  一起听 · 完整播放页(重做版)
//
//  设计语言直接沿用音乐小胶囊那一套(见 TogetherMiniBar):
//   · 瓷面 + 一道发丝描边，不用厚投影、不用渐变卡片
//   · 衬线斜体做曲名，等宽大写做注脚，其余克制
//   · 键是 32/44pt 方角或圆，细线图形，颜色只吃 TogetherSpec 三档
//   · 动画统一走 TogetherCurve.springPhysics，不自己造曲线
//
//  一个"只画不接"的件都没有。接线表：
//   读  TogetherStateHub.shared.state   曲 / 进度 / 歌单 / 刻字 / 遥控 / 在线 / 回声
//   读  TogetherPlayer.shared           播放实况、上一首、下一首、播放暂停、seek
//   写  TogetherStore.shared            play / seek / setModes / toggleLike /
//                                        addNote / setLoopLine / createPlaylist /
//                                        renamePlaylist / deletePlaylist /
//                                        restorePlaylist / addTrack / removeTrack /
//                                        requestHandoff / acceptHandoff / cancelHandoff /
//                                        setImage / markSeen
//
//  壁纸只认 wallpaper-now 这一槽：歌单 / 曲库 / 喜欢那三张壁纸原本挂的页面已经删了，
//  那几个槽位现在是休眠资产，这一页不碰、也不假装能换。
//

import SwiftUI
import UIKit
import PhotosUI

struct TogetherRoomView: View {
    let sessionPersonaId: String?
    var onClose: () -> Void = {}

    @ObservedObject private var player = TogetherPlayer.shared
    @ObservedObject private var hub = TogetherStateHub.shared

    // 壁纸换过要重画一次：图片缓存按 URL 复用，同名文件不会自己通知界面
    @State private var imageRev = 0
    @State private var lyrics: TogetherLyrics?
    @State private var lyricsShown = false
    @State private var scrub: Double?
    @State private var queueShown = false
    @State private var expanded: String?
    @State private var songsFor: String?
    @State private var stampDraft = ""
    @State private var loopDraft = ""
    @State private var newName = ""
    @State private var renaming: String?
    @State private var creating = false
    @State private var pickerItem: PhotosPickerItem?
    @State private var restoreFailed = false
    @FocusState private var stampFocused: Bool

    private var state: TogetherState { hub.state }
    private var aiName: String { ChatAddressing.assistant(sessionPersonaId: sessionPersonaId) }
    private var userName: String { ChatAddressing.user() }
    private var track: TogetherTrack? { player.track ?? state.track }
    private var livePlaylists: [TogetherPlaylist] { state.playlists.filter { !$0.deleted } }
    private var gonePlaylists: [TogetherPlaylist] { state.playlists.filter { $0.deleted } }
    private var likedIds: [String] { state.liked }

    var body: some View {
        ZStack {
            page
            backdrop
            VStack(spacing: 0) {
                topBar
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 22) {
                        hero
                        shelf
                        echoes
                        stamps
                        remote
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 2)
                    .padding(.bottom, 42)
                    .frame(maxWidth: 560)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .task(id: track?.id) {
            // 歌词跟曲走：换歌就重取，不在这里轮询
            lyrics = track.flatMap { TogetherStore.shared.lyrics(for: $0) }
            loopDraft = ""
            stampDraft = ""
        }
        .sheet(isPresented: $lyricsShown) {
            TogetherRoomLyrics(
                track: track,
                lyrics: lyrics,
                position: player.currentTime,
                engraved: state.loopLines[track?.id ?? ""],
                engrave: { line in
                    guard let id = track?.id else { return }
                    TogetherStore.shared.setLoopLine(trackId: id, text: line, by: .user)
                },
                seekTo: { at in
                    _ = TogetherStore.shared.seek(to: at, by: .user)
                    player.seek(to: at)
                    lyricsShown = false
                }
            )
        }
        .onAppear(perform: bootstrap)
        .onReceive(NotificationCenter.default.publisher(for: TogetherImages.didSetNotification)) { _ in
            // 槽位里的图被换掉时清一次渲染，不然壁纸还是旧那张
            hub.refreshNow()
            imageRev &+= 1
        }
        .onChange(of: pickerItem) { item in
            guard let item else { return }
            importWallpaper(item)
        }
        .sheet(isPresented: $queueShown) {
            TogetherRoomQueueSheet(sessionPersonaId: sessionPersonaId)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: Binding(
            get: { songsFor != nil },
            set: { if !$0 { songsFor = nil } }
        )) {
            if let id = songsFor {
                TogetherRoomSongsSheet(playlistId: id)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
        }
    }

    // MARK: - 底板

    private var page: some View {
        TogetherSpec.capsuleSurface
            .ignoresSafeArea()
    }

    private var backdrop: some View {
        Group {
            if let url = TogetherImages.url(for: TogetherImages.wallpaperNow),
               let image = TogetherImages.cachedImage(for: url) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(height: 330)
                    .blur(radius: 30)
                    .opacity(0.34)
                    .mask(
                        LinearGradient(
                            colors: [.white, .white.opacity(0.35), .clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .ignoresSafeArea(edges: .top)
                    .allowsHitTesting(false)
            }
        }
        .id(imageRev)
    }

    // MARK: - 顶栏

    private var topBar: some View {
        HStack(spacing: 10) {
            roomKey("chevron.down", label: TogetherCopy.a11yCollapse) { onClose() }
            Text(TogetherCopy.title.uppercased())
                .font(ChatFont.font(9.5, weight: .semibold, design: .monospaced))
                .tracking(2.2)
                .foregroundStyle(TogetherSpec.muted)
            Spacer(minLength: 8)
            roomKey("list.bullet", label: TogetherCopy.a11yQueue, active: queueShown) {
                queueShown = true
            }
            PhotosPicker(selection: $pickerItem, matching: .images) {
                roomKeyLabel("photo.on.rectangle")
            }
            .accessibilityLabel(TogetherCopy.changeWallpaper)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .frame(maxWidth: 600)
        .frame(maxWidth: .infinity)
    }

    // MARK: - 开场

    private func bootstrap() {
        hub.refreshNow()
        TogetherStore.shared.markSeen(by: .user)
        player.restoreIfNeeded()
        // 曲子在、文件没了：这不是"没事发生"，要明说
        if let restored = state.track, player.track == nil,
           let url = TogetherStore.shared.audioURL(for: restored),
           !FileManager.default.fileExists(atPath: url.path) {
            restoreFailed = true
        }
    }

    private func importWallpaper(_ item: PhotosPickerItem) {
        Task {
            defer { pickerItem = nil }
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data),
                  let jpeg = image.jpegData(compressionQuality: 0.92),
                  let target = TogetherImages.url(for: TogetherImages.wallpaperNow) else {
                await MainActor.run {
                    MinisToast.show(AppLocalized("Couldn't prepare the picture", comment: "一起听 · 壁纸导入失败"), systemImage: "exclamationmark.circle.fill")
                }
                return
            }
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("together-wallpaper-\(UUID().uuidString).jpg")
            try? jpeg.write(to: tmp)
            _ = TogetherStore.shared.setImage(slot: TogetherImages.wallpaperNow, from: tmp)
            try? FileManager.default.removeItem(at: tmp)
            await MainActor.run {
                hub.refreshNow()
                imageRev &+= 1
                TogetherHaptics.select()
                MinisToast.show(AppLocalized("Wallpaper updated", comment: "一起听 · 壁纸已更新"), systemImage: "photo")
            }
        }
    }
// MARK: - 此刻

    private var hero: some View {
        VStack(spacing: 16) {
            presenceRow
            art
            titleBlock
            lyricPeek
            progressBlock
            transportRow
            modeRow
        }
        .padding(.top, 4)
    }

    // 谁在听、现在谁在按
    private var presenceRow: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                personaChip(TogetherIdentity.userIcon, online: userOnline)
                hairline
                personaChip(TogetherIdentity.aiIcon(sessionPersonaId: sessionPersonaId), online: aiOnline)
            }
            HStack(spacing: 7) {
                Text(driverLine)
                if let word = moodWord {
                    Circle().fill(TogetherSpec.ink(0.22)).frame(width: 2, height: 2)
                    Text(word)
                }
            }
            .font(ChatFont.font(10, design: .monospaced))
            .tracking(1.3)
            .foregroundStyle(TogetherSpec.muted)
            .lineLimit(1)
        }
    }

    private var hairline: some View {
        Rectangle()
            .fill(TogetherSpec.ink(0.10))
            .frame(maxWidth: 46)
            .frame(height: 0.7)
    }

    private func personaChip(_ icon: String?, online: Bool) -> some View {
        HStack(spacing: 7) {
            PersonaAvatarView(iconRef: icon, size: 22)
            Circle()
                .fill(online ? TogetherSpec.charcoal.opacity(0.85) : TogetherSpec.muted.opacity(0.42))
                .frame(width: 5, height: 5)
        }
    }

    // 有封面用封面,没有就转黑胶
    private var art: some View {
        Group {
            if let cover = track?.cover, !cover.isEmpty,
               let url = TogetherStore.shared.imageURL(cover),
               let image = TogetherImages.cachedImage(for: url) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 208, height: 208)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .strokeBorder(TogetherSpec.ink(0.08), lineWidth: 0.8)
                    )
            } else {
                TogetherVinylDisc(size: 208, spinning: player.isPlaying)
            }
        }
        .frame(height: 208)
        .accessibilityHidden(true)
    }

    private var titleBlock: some View {
        VStack(spacing: 6) {
            Text(displayTitle)
                .font(ChatFont.font(23, weight: .medium, design: .serif).italic())
                .foregroundStyle(TogetherSpec.charcoal)
                .multilineTextAlignment(.center)
                .lineLimit(2)
            if let meta = metaLine {
                Text(meta)
                    .font(ChatFont.font(9.5, design: .monospaced))
                    .tracking(1.6)
                    .foregroundStyle(TogetherSpec.muted)
                    .lineLimit(1)
            }
        }
    }

    private var displayTitle: String {
        let title = track?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? TogetherCopy.nothingPlaying : title
    }

    private var metaLine: String? {
        guard let t = track else { return nil }
        var parts: [String] = []
        let artist = t.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        if !artist.isEmpty { parts.append(artist.uppercased()) }
        if t.duration > 0 { parts.append(timeText(t.duration)) }
        return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
    }

    // 有歌词跟着唱,没歌词就在秒上刻一句(写进 state.loopLines)
    private var lyricPeek: some View {
        VStack(spacing: 6) {
            if let t = track {
                if let lines = lyrics?.lines, !lines.isEmpty {
                    Button {
                        withAnimation(TogetherCurve.springPhysics) { lyricsShown = true }
                    } label: {
                        VStack(spacing: 4) {
                            Text(currentLyricText)
                                .font(ChatFont.font(15.5, weight: .medium, design: .serif).italic())
                                .foregroundStyle(TogetherSpec.charcoal.opacity(0.92))
                            if !nextLyricText.isEmpty {
                                Text(nextLyricText)
                                    .font(ChatFont.font(11.5, design: .serif))
                                    .foregroundStyle(TogetherSpec.muted)
                            }
                        }
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(TogetherPressStyle())
                    .accessibilityLabel(TogetherCopy.a11yOpenLyrics)
                } else {
                    loopLinePanel(t)
                }
            } else {
                Text(TogetherCopy.browseSongs)
                    .font(ChatFont.font(12, design: .serif))
                    .foregroundStyle(TogetherSpec.muted)
            }
        }
        .frame(minHeight: 38)
    }

    private func loopLinePanel(_ t: TogetherTrack) -> some View {
        VStack(spacing: 9) {
            Text(loopLine(t.id) ?? TogetherCopy.noLyrics)
                .font(ChatFont.font(13.5, weight: .medium, design: .serif).italic())
                .foregroundStyle(loopLine(t.id) == nil ? TogetherSpec.muted : TogetherSpec.charcoal.opacity(0.9))
                .multilineTextAlignment(.center)
                .lineLimit(2)
            HStack(spacing: 8) {
                TextField(TogetherCopy.noLyricsHint, text: $loopDraft)
                    .textFieldStyle(.plain)
                    .font(ChatFont.font(11.5, design: .serif))
                    .foregroundStyle(TogetherSpec.sub)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(TogetherSpec.ink(0.05), in: Capsule())
                    .submitLabel(.done)
                    .onSubmit { commitLoopLine(t.id) }
                roomKey("arrow.up", label: AppLocalized("Save", comment: "一起听 · 存这一句")) {
                    commitLoopLine(t.id)
                }
            }
            .frame(maxWidth: 300)
        }
    }

    private func commitLoopLine(_ trackId: String) {
        let text = loopDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        TogetherStore.shared.setLoopLine(trackId: trackId, text: text, by: .user)
        loopDraft = ""
        hub.refreshNow()
        TogetherHaptics.select()
    }

    private func loopLine(_ trackId: String) -> String? {
        let text = state.loopLines[trackId]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }

    private var currentLyricText: String {
        guard let lines = lyrics?.lines, !lines.isEmpty else { return "" }
        let at = player.currentTime
        var line = lines[0]
        for item in lines where item.at <= at + 0.2 { line = item }
        return line.text
    }

    private var nextLyricText: String {
        guard let lines = lyrics?.lines, !lines.isEmpty else { return "" }
        let at = player.currentTime
        if let next = lines.first(where: { $0.at > at + 0.2 }) { return next.text }
        return ""
    }

    // 进度:拖的时候本地显示,松手才写回 state 和播放器
    private var progressBlock: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                scrubBar(width: geo.size.width)
            }
            .frame(height: 16)
            HStack {
                Text(timeText(shownPosition))
                Spacer()
                Text("-" + timeText(remaining))
            }
            .font(ChatFont.font(9.5, design: .monospaced))
            .foregroundStyle(TogetherSpec.muted)
        }
    }

    private func scrubBar(width: CGFloat) -> some View {
        let total = max(player.duration, 0.001)
        let pct = min(max(shownPosition / total, 0), 1)
        return ZStack(alignment: .leading) {
            Capsule()
                .fill(TogetherSpec.ink(0.09))
                .frame(height: 3)
            Capsule()
                .fill(TogetherSpec.charcoal.opacity(scrub == nil ? 0.5 : 0.78))
                .frame(width: max(width * pct, 3), height: 3)
            Circle()
                .fill(TogetherSpec.charcoal)
                .frame(width: 9, height: 9)
                .offset(x: max(width * pct - 4.5, 0))
                .opacity(scrub == nil ? 0 : 1)
        }
        .frame(height: 16)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard player.duration > 0 else { return }
                    scrub = min(max(value.location.x / max(width, 1), 0), 1) * player.duration
                }
                .onEnded { value in
                    guard player.duration > 0 else {
                        scrub = nil
                        return
                    }
                    let target = min(max(value.location.x / max(width, 1), 0), 1) * player.duration
                    commitSeek(target)
                }
        )
        .accessibilityLabel(TogetherCopy.progressLabel)
    }

    private func commitSeek(_ target: Double) {
        player.seek(to: target)
        TogetherStore.shared.seek(to: target, by: .user)
        hub.refreshNow()
        TogetherHaptics.tap()
        scrub = nil
    }

    private var transportRow: some View {
        HStack(spacing: 34) {
            transportKey("backward.end.fill", label: TogetherCopy.a11yPrevious) {
                player.previousTrack()
                hub.refreshNow()
                TogetherHaptics.tap()
            }
            Button {
                player.userToggle()
                hub.refreshNow()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(TogetherSpec.capsuleSurface)
                    .frame(width: 62, height: 62)
                    .background(TogetherSpec.charcoal, in: Circle())
            }
            .buttonStyle(TogetherPressStyle())
            .accessibilityLabel(player.isPlaying ? TogetherCopy.a11yPause : TogetherCopy.a11yPlay)
            transportKey("forward.end.fill", label: TogetherCopy.a11yNext) {
                player.nextTrack()
                hub.refreshNow()
                TogetherHaptics.tap()
            }
        }
    }

    private func transportKey(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14.5, weight: .medium))
                .foregroundStyle(TogetherSpec.sub)
                .frame(width: 46, height: 46)
                .contentShape(Rectangle())
        }
        .buttonStyle(TogetherPressStyle())
        .accessibilityLabel(label)
    }

    private var modeRow: some View {
        HStack(spacing: 8) {
            modeKey("shuffle", active: state.playback.shuffle) {
                TogetherStore.shared.setShuffle(!state.playback.shuffle)
                hub.refreshNow()
                TogetherHaptics.select()
            }
            modeKey(state.playback.repeatOne ? "repeat.1" : "repeat",
                    active: state.playback.repeatOne || state.playback.repeatAll) {
                cycleRepeat()
            }
            Spacer(minLength: 0)
            modeKey("text.alignleft", active: lyricsShown) { lyricsShown = true }
            modeKey(likedCurrent ? "heart.fill" : "heart", active: likedCurrent) {
                toggleLike()
            }
        }
        .padding(.top, 2)
    }

    private func modeKey(_ symbol: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(active ? TogetherSpec.charcoal : TogetherSpec.muted)
                .frame(width: 32, height: 28)
                .background(
                    active ? TogetherSpec.ink(0.07) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                )
        }
        .buttonStyle(TogetherPressStyle())
    }

    private func cycleRepeat() {
        if state.playback.repeatOne {
            TogetherStore.shared.setModes(repeatOne: false, repeatAll: true, by: .user)
        } else if state.playback.repeatAll {
            TogetherStore.shared.setModes(repeatOne: false, repeatAll: false, by: .user)
        } else {
            TogetherStore.shared.setModes(repeatOne: true, repeatAll: false, by: .user)
        }
        hub.refreshNow()
        TogetherHaptics.select()
    }

    private func toggleLike() {
        guard let id = track?.id, !id.isEmpty else { return }
        TogetherStore.shared.toggleLike(trackId: id, by: .user)
        hub.refreshNow()
        TogetherHaptics.select()
    }

    private var now: Int { Int(Date().timeIntervalSince1970) }
    private var userOnline: Bool { state.devices.user.seenRecently(now: now) }
    private var aiOnline: Bool { state.devices.ai.seenRecently(now: now) }
    private var moodWord: String? {
        guard let mood = state.me.presence.mood, !mood.word.isEmpty else { return nil }
        return mood.word
    }
    private var driverLine: String {
        guard let by = state.playback.by else { return TogetherCopy.nothingPlaying }
        return by == TogetherActor.ai.rawValue ? TogetherCopy.driving(aiName) : TogetherCopy.youDriving
    }
    private var likedCurrent: Bool {
        guard let id = track?.id else { return false }
        return likedIds.contains(id)
    }
    private var shownPosition: Double { scrub ?? player.currentTime }
    private var remaining: Double { max(player.duration - shownPosition, 0) }
    // MARK: - 仓:喜欢的歌、歌单

    private var shelf: some View {
        VStack(alignment: .leading, spacing: 16) {
            likedCard
            playlistsCard
        }
    }

    private var likedCard: some View {
        roomCard {
            Button { openLiked() } label: {
                HStack(spacing: 12) {
                    rowGlyph("heart.fill")
                    VStack(alignment: .leading, spacing: 3) {
                        Text(AppLocalized("Liked songs", comment: "一起听 · 喜欢的歌"))
                            .font(ChatFont.font(14.5, weight: .medium, design: .serif))
                            .foregroundStyle(TogetherSpec.charcoal)
                        Text(likedIds.isEmpty ? TogetherCopy.likedEmpty : TogetherCopy.playAll)
                            .font(ChatFont.font(10, design: .monospaced))
                            .tracking(1.1)
                            .foregroundStyle(TogetherSpec.muted)
                    }
                    Spacer(minLength: 8)
                    Text("\(likedIds.count)")
                        .font(ChatFont.font(11, design: .monospaced))
                        .foregroundStyle(TogetherSpec.muted)
                    chevronGlyph
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(TogetherPressStyle())
        }
    }

    private var playlistsCard: some View {
        roomCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    sectionTitle(TogetherCopy.myPlaylists)
                    Spacer(minLength: 8)
                    Button {
                        withAnimation(TogetherCurve.springPhysics) {
                            creating.toggle()
                            if !creating { newName = "" }
                        }
                    } label: {
                        Image(systemName: creating ? "xmark" : "plus")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(TogetherSpec.sub)
                            .frame(width: 26, height: 26)
                            .background(TogetherSpec.ink(0.05), in: Circle())
                    }
                    .buttonStyle(TogetherPressStyle())
                    .accessibilityLabel(TogetherCopy.newPlaylist)
                }
                if creating { newPlaylistField }
                if livePlaylists.isEmpty && !creating {
                    Text(TogetherCopy.noSongsYet)
                        .font(ChatFont.font(11.5, design: .serif))
                        .foregroundStyle(TogetherSpec.muted)
                }
                ForEach(Array(livePlaylists.enumerated()), id: \.element.id) { index, list in
                    if index > 0 { divider }
                    playlistBlock(list)
                }
                if !gonePlaylists.isEmpty { goneBlock }
            }
        }
    }

    private func playlistBlock(_ list: TogetherPlaylist) -> some View {
        let open = expanded == list.id
        return VStack(spacing: 4) {
            HStack(spacing: 6) {
                Button { takeQueue(list) } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(list.name.isEmpty ? TogetherCopy.untitledPlaylist : list.name)
                            .font(ChatFont.font(14.5, weight: .medium, design: .serif))
                            .foregroundStyle(TogetherSpec.charcoal)
                            .lineLimit(1)
                        Text(list.tracks.isEmpty ? TogetherCopy.noSongsYet : TogetherCopy.playAll)
                            .font(ChatFont.font(10, design: .monospaced))
                            .tracking(1.1)
                            .foregroundStyle(TogetherSpec.muted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(TogetherPressStyle())
                playlistMenu(list)
                Button {
                    withAnimation(TogetherCurve.springPhysics) {
                        expanded = open ? nil : list.id
                    }
                } label: {
                    Image(systemName: open ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(TogetherSpec.muted)
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(TogetherPressStyle())
            }
            if renaming == list.id { renameField(list) }
            if open { expandedTracks(list) }
        }
        .padding(.vertical, 6)
    }

    private func playlistMenu(_ list: TogetherPlaylist) -> some View {
        Menu {
            Button { takeQueue(list) } label: {
                Label(TogetherCopy.playAll, systemImage: "play.fill")
            }
            Button { songsFor = list.id } label: {
                Label(TogetherCopy.addSongs, systemImage: "plus.circle")
            }
            Button {
                newName = list.name
                renaming = list.id
                creating = false
            } label: {
                Label(TogetherCopy.edit, systemImage: "pencil")
            }
            Divider()
            Button(role: .destructive) {
                TogetherStore.shared.deletePlaylist(id: list.id, by: .user)
                collapsedIfNeeded(list.id)
                hub.refreshNow()
                TogetherHaptics.select()
                MinisToast.show(TogetherCopy.deletePlaylist, systemImage: "trash")
            } label: {
                Label(TogetherCopy.deletePlaylist, systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(TogetherSpec.muted)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
    }

    private func renameField(_ list: TogetherPlaylist) -> some View {
        HStack(spacing: 8) {
            TextField(TogetherCopy.playlistName, text: $newName)
                .textFieldStyle(.plain)
                .font(ChatFont.font(13, design: .serif))
                .foregroundStyle(TogetherSpec.charcoal)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(TogetherSpec.ink(0.05), in: Capsule())
                .submitLabel(.done)
                .onSubmit { commitRename(list.id) }
            roomKey("checkmark", label: TogetherCopy.done) { commitRename(list.id) }
        }
        .padding(.top, 4)
    }

    private func expandedTracks(_ list: TogetherPlaylist) -> some View {
        VStack(spacing: 0) {
            if list.tracks.isEmpty {
                Text(TogetherCopy.noSongsYet)
                    .font(ChatFont.font(11.5, design: .serif))
                    .foregroundStyle(TogetherSpec.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                ForEach(Array(list.tracks.enumerated()), id: \.offset) { index, trackId in
                    trackLine(trackId, index: index, playlistId: list.id)
                }
            }
            Button { songsFor = list.id } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                        .font(.system(size: 9.5, weight: .semibold))
                    Text(TogetherCopy.addSongs)
                        .font(ChatFont.font(10.5, weight: .medium, design: .monospaced))
                        .tracking(1)
                }
                .foregroundStyle(TogetherSpec.sub)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(TogetherPressStyle())
        }
        .padding(.leading, 2)
    }

    private func trackLine(_ trackId: String, index: Int, playlistId: String) -> some View {
        let item = lib.track(id: trackId)
        let isCurrent = track?.id == trackId
        return Button {
            if let item {
                player.start(item, by: .user, queue: queueIds(of: playlistId), queueSource: playlistId)
                hub.refreshNow()
                TogetherHaptics.tap()
            } else {
                MinisToast.show(TogetherCopy.unplayableTrack, systemImage: "exclamationmark.triangle")
            }
        } label: {
            HStack(spacing: 10) {
                Text(String(format: "%02d", index + 1))
                    .font(ChatFont.font(9.5, design: .monospaced))
                    .foregroundStyle(TogetherSpec.muted)
                    .frame(width: 20, alignment: .leading)
                Text(trackTitle(item))
                    .font(ChatFont.font(12.5, weight: isCurrent ? .semibold : .regular, design: .serif))
                    .foregroundStyle(isCurrent ? TogetherSpec.charcoal : TogetherSpec.sub)
                    .lineLimit(1)
                Spacer(minLength: 6)
                if isCurrent {
                    Image(systemName: player.isPlaying ? "waveform" : "pause")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(TogetherSpec.charcoal.opacity(0.7))
                }
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(TogetherPressStyle())
        .contextMenu {
            Button(role: .destructive) {
                TogetherStore.shared.removeTrack(trackId, from: playlistId, by: .user)
                hub.refreshNow()
                TogetherHaptics.select()
            } label: {
                Label(TogetherCopy.removeFromPlaylist, systemImage: "minus.circle")
            }
        }
    }

    private var newPlaylistField: some View {
        HStack(spacing: 8) {
            TextField(TogetherCopy.playlistName, text: $newName)
                .textFieldStyle(.plain)
                .font(ChatFont.font(13, design: .serif))
                .foregroundStyle(TogetherSpec.charcoal)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(TogetherSpec.ink(0.05), in: Capsule())
                .submitLabel(.done)
                .onSubmit { commitCreate() }
            roomKey("checkmark", label: TogetherCopy.done) { commitCreate() }
        }
    }

    private var goneBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            divider
            sectionTitle(TogetherCopy.deletedPlaylists)
            ForEach(gonePlaylists, id: \.id) { list in
                HStack(spacing: 8) {
                    Text(list.name.isEmpty ? TogetherCopy.untitledPlaylist : list.name)
                        .font(ChatFont.font(12.5, design: .serif))
                        .foregroundStyle(TogetherSpec.muted)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Button {
                        TogetherStore.shared.restorePlaylist(id: list.id, by: .user)
                        hub.refreshNow()
                        TogetherHaptics.select()
                    } label: {
                        Text(TogetherCopy.restore)
                            .font(ChatFont.font(10.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(TogetherSpec.sub)
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(TogetherPressStyle())
                }
            }
        }
        .padding(.top, 4)
    }

    // MARK: - 回声:它为什么放了这一首

    private var echoes: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle(TogetherCopy.historyEchoes)
            if echoItems.isEmpty {
                Text(TogetherCopy.likedEmpty)
                    .font(ChatFont.font(11.5, design: .serif))
                    .foregroundStyle(TogetherSpec.muted)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(echoItems.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { divider }
                        echoRow(item)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var echoItems: [TogetherHistoryItem] {
        Array(state.me.history.reversed().prefix(6))
    }

    private func echoRow(_ item: TogetherHistoryItem) -> some View {
        Button {
            if let song = lib.track(id: item.trackId) {
                player.start(song, by: .user)
                hub.refreshNow()
                TogetherHaptics.tap()
            } else {
                MinisToast.show(TogetherCopy.unplayableTrack, systemImage: "exclamationmark.triangle")
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(trackTitle(lib.track(id: item.trackId)))
                    .font(ChatFont.font(13, weight: .medium, design: .serif))
                    .foregroundStyle(TogetherSpec.charcoal.opacity(0.9))
                    .lineLimit(1)
                if !item.why.isEmpty {
                    Text(item.why)
                        .font(ChatFont.font(11.5, design: .serif))
                        .foregroundStyle(TogetherSpec.muted)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(TogetherPressStyle())
    }

    // MARK: - 刻字:在这个秒上留一句

    private var stamps: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle(TogetherCopy.leaveALine)
            if track == nil {
                Text(TogetherCopy.nothingPlaying)
                    .font(ChatFont.font(11.5, design: .serif))
                    .foregroundStyle(TogetherSpec.muted)
            } else if stampAllowed {
                stampEditor
            } else {
                Text(TogetherCopy.oneLineOnly)
                    .font(ChatFont.font(11.5, design: .serif))
                    .foregroundStyle(TogetherSpec.muted)
            }
            if !myNotes.isEmpty {
                VStack(spacing: 0) {
                    ForEach(myNotes, id: \.id) { note in
                        noteRow(note)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var myNotes: [TogetherNote] {
        guard let id = track?.id else { return [] }
        return state.notes.filter { $0.trackId == id }.sorted { $0.at < $1.at }
    }

    private var stampEditor: some View {
        HStack(spacing: 8) {
            Text(timeText(player.currentTime))
                .font(ChatFont.font(10, design: .monospaced))
                .foregroundStyle(TogetherSpec.muted)
                .frame(width: 40, alignment: .leading)
            TextField(TogetherCopy.leaveALine, text: $stampDraft)
                .textFieldStyle(.plain)
                .focused($stampFocused)
                .font(ChatFont.font(12.5, design: .serif))
                .foregroundStyle(TogetherSpec.charcoal)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(TogetherSpec.ink(0.05), in: Capsule())
                .submitLabel(.done)
                .onSubmit { commitStamp() }
            roomKey("checkmark", label: TogetherCopy.done) { commitStamp() }
        }
    }

    private func noteRow(_ note: TogetherNote) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(timeText(note.at))
                .font(ChatFont.font(10, design: .monospaced))
                .foregroundStyle(TogetherSpec.muted)
                .frame(width: 40, alignment: .leading)
            Text(note.text)
                .font(ChatFont.font(12.5, design: .serif))
                .foregroundStyle(TogetherSpec.sub)
                .frame(maxWidth: .infinity, alignment: .leading)
                .multilineTextAlignment(.leading)
            Text(note.from == TogetherActor.ai.rawValue ? aiName : userName)
                .font(ChatFont.font(9.5, design: .monospaced))
                .foregroundStyle(TogetherSpec.muted)
        }
        .padding(.vertical, 8)
    }
    // MARK: - 遥控:这台在放,谁都能按

    private enum RemoteStage { case idle, lost, offered }

    private var stage: RemoteStage {
        guard let pending = state.pendingHandoff, !pending.to.isEmpty else { return .idle }
        return pending.to == TogetherActor.ai.rawValue ? .lost : .offered
    }

    private var remote: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle(TogetherCopy.handoff)
            switch stage {
            case .idle:    idleRemote
            case .lost:    waitingRemote
            case .offered: offeredRemote
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var idleRemote: some View {
        Button { askRemote() } label: {
            HStack(spacing: 10) {
                Image(systemName: "hand.raised")
                    .font(.system(size: 12, weight: .medium))
                Text(TogetherCopy.handoff)
                    .font(ChatFont.font(12, weight: .medium, design: .monospaced))
                    .tracking(1.2)
                Spacer(minLength: 8)
                Image(systemName: "arrow.right")
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(TogetherSpec.sub)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(TogetherSpec.ink(0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(TogetherPressStyle())
    }
    private var waitingRemote: some View {
        HStack(spacing: 10) {
            Text(TogetherCopy.waitingForHandoff(aiName))
                .font(ChatFont.font(11.5, design: .serif))
                .foregroundStyle(TogetherSpec.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button { cancelRemote() } label: {
                Text(TogetherCopy.cancel)
                    .font(ChatFont.font(10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(TogetherSpec.sub)
            }
            .buttonStyle(TogetherPressStyle())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(TogetherSpec.ink(0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var offeredRemote: some View {
        Button { takeRemote() } label: {
            HStack(spacing: 10) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 12, weight: .medium))
                Text(TogetherCopy.remoteOffered(aiName))
                    .font(ChatFont.font(12, weight: .medium, design: .monospaced))
                    .tracking(1.1)
                    .lineLimit(2)
                Spacer(minLength: 8)
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
            }
            .foregroundStyle(TogetherSpec.charcoal.opacity(0.85))
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(TogetherSpec.ink(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(TogetherPressStyle())
    }

    // MARK: - 共用零件(跟小胶囊同一套:玻璃面、发丝线、等宽注脚)

    private var lib: TogetherLibrary { hub.library }

    @ViewBuilder
    private func roomCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(TogetherSpec.glass(0.55), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(TogetherSpec.ink(0.06), lineWidth: 0.8)
            )
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text.uppercased())
            .font(ChatFont.font(9.5, weight: .semibold, design: .monospaced))
            .tracking(1.9)
            .foregroundStyle(TogetherSpec.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var divider: some View {
        Rectangle()
            .fill(TogetherSpec.ink(0.06))
            .frame(height: 0.7)
    }

    private func rowGlyph(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(TogetherSpec.charcoal.opacity(0.75))
            .frame(width: 28, height: 28)
            .background(TogetherSpec.ink(0.05), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func timeText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func trackTitle(_ item: TogetherTrack?) -> String {
        guard let item else { return TogetherCopy.untitledTrack }
        let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? TogetherCopy.untitledTrack : title
    }

    private func roomKey(_ symbol: String, label: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(active ? TogetherSpec.charcoal : TogetherSpec.sub)
                .frame(width: 32, height: 32)
                .background(active ? TogetherSpec.ink(0.08) : TogetherSpec.ink(0.04),
                            in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(TogetherSpec.ink(0.07), lineWidth: 0.7)
                )
                .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(TogetherPressStyle())
        .accessibilityLabel(label)
    }

    // MARK: - 动作(每一下都落盘,别让界面自己演)

    private var stampAllowed: Bool {
        guard let t = track, !t.id.isEmpty else { return false }
        return TogetherStore.shared.canStamp(by: .user, trackId: t.id)
    }

    private func takeQueue(_ list: TogetherPlaylist) {
        guard let firstId = list.tracks.first, let first = lib.track(id: firstId) else {
            MinisToast.show(TogetherCopy.noSongsYet, systemImage: "music.note")
            return
        }
        if !player.start(first, by: .user, queue: list.tracks, queueSource: list.id) {
            MinisToast.show(TogetherCopy.unplayableTrack, systemImage: "exclamationmark.triangle")
        }
        hub.refreshNow()
        TogetherHaptics.select()
    }

    private func queueIds(of playlistId: String) -> [String] {
        livePlaylists.first { $0.id == playlistId }?.tracks ?? []
    }

    private func collapsedIfNeeded(_ id: String) {
        guard expanded == id else { return }
        withAnimation(TogetherCurve.springPhysics) { expanded = nil }
    }

    private func openLiked() {
        guard !likedIds.isEmpty else {
            MinisToast.show(TogetherCopy.likedEmpty, systemImage: "heart")
            return
        }
        songsFor = "__liked__"
    }

    private func commitCreate() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        guard let id = TogetherStore.shared.createPlaylist(name: name, by: .user) else { return }
        newName = ""
        creating = false
        expanded = id
        hub.refreshNow()
        TogetherHaptics.select()
        MinisToast.show(TogetherCopy.newPlaylist, systemImage: "text.badge.plus")
    }

    private func commitRename(_ id: String) {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        TogetherStore.shared.renamePlaylist(id: id, to: name, by: .user)
        newName = ""
        renaming = nil
        hub.refreshNow()
        TogetherHaptics.select()
    }

    private func commitStamp() {
        guard let t = track else { return }
        let text = stampDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if TogetherStore.shared.addNote(at: player.currentTime, text: text, by: .user, trackId: t.id) {
            stampDraft = ""
            stampFocused = false
            hub.refreshNow()
            TogetherHaptics.select()
            MinisToast.show(TogetherCopy.leaveALine, systemImage: "quote.bubble")
        } else {
            MinisToast.show(TogetherCopy.oneLineOnly, systemImage: "quote.bubble")
        }
    }

    private func askRemote() {
        if TogetherStore.shared.requestHandoff(to: TogetherActor.ai.rawValue, by: .user) {
            hub.refreshNow()
            TogetherHaptics.select()
            MinisToast.show(TogetherCopy.handoff, systemImage: "hand.raised")
        } else {
            MinisToast.show(TogetherCopy.fileMissing, systemImage: "exclamationmark.triangle")
        }
    }

    private func cancelRemote() {
        TogetherStore.shared.cancelHandoff(by: .user)
        hub.refreshNow()
        TogetherHaptics.select()
    }

    private func takeRemote() {
        TogetherStore.shared.acceptHandoff()
        hub.refreshNow()
        TogetherHaptics.select()
        MinisToast.show(TogetherCopy.youDriving, systemImage: "hand.point.right")
    }
}

// MARK: - 队列:这一刻往后要放的

struct TogetherRoomQueueSheet: View {
    let sessionPersonaId: String?

    @ObservedObject private var player = TogetherPlayer.shared
    @ObservedObject private var hub = TogetherStateHub.shared
    @Environment(\.dismiss) private var dismiss

    private var lib: TogetherLibrary { hub.library }

    // 队列来源只有一处:playback.queue 非空就用它,空就按曲库顺序
    private var ids: [String] {
        let queued = hub.state.playback.queue
        let list = queued.isEmpty ? lib.tracks.map { $0.id } : queued
        return list.filter { lib.track(id: $0) != nil }
    }

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader(title: TogetherCopy.queueTitle, count: ids.count)
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        ForEach(Array(ids.enumerated()), id: \.offset) { index, id in
                            row(id: id, index: index)
                                .id(index)
                        }
                        Text(TogetherCopy.endOfQueue)
                            .font(ChatFont.font(10, design: .monospaced))
                            .tracking(1.4)
                            .foregroundStyle(TogetherSpec.muted)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 20)
                    }
                    .padding(.horizontal, 20)
                }
                .onAppear {
                    // 一进来停在正在放的那首上,不从头开始翻
                    if let at = ids.firstIndex(where: { $0 == player.track?.id }) {
                        proxy.scrollTo(at, anchor: .center)
                    }
                }
            }
        }
    }

    private func row(id: String, index: Int) -> some View {
        let item = lib.track(id: id)
        let playing = player.track?.id == id
        return Button {
            guard let item else { return }
            _ = player.start(item, by: .user, queue: ids, queueSource: hub.state.playback.queueSource)
            hub.refreshNow()
            TogetherHaptics.select()
        } label: {
            HStack(spacing: 10) {
                Text("\(index + 1)")
                    .font(ChatFont.font(10, design: .monospaced))
                    .foregroundStyle(TogetherSpec.muted)
                    .frame(width: 20, alignment: .trailing)
                VStack(alignment: .leading, spacing: 3) {
                    Text(togetherRoomTitle(item?.title))
                        .font(ChatFont.font(12.5, weight: playing ? .semibold : .regular))
                        .foregroundStyle(TogetherSpec.charcoal)
                        .lineLimit(1)
                    if let artist = item?.artist, !artist.isEmpty {
                        Text(artist)
                            .font(ChatFont.font(10, design: .monospaced))
                            .foregroundStyle(TogetherSpec.muted)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if playing {
                    Image(systemName: "waveform")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(TogetherSpec.charcoal.opacity(0.7))
                        .symbolEffect(.variableColor.iterative, options: .repeating)
                } else if let item {
                    Text(togetherRoomDuration(item.duration))
                        .font(ChatFont.font(10, design: .monospaced))
                        .foregroundStyle(TogetherSpec.muted)
                }
            }
            .contentShape(Rectangle())
            .padding(.vertical, 10)
        }
        .buttonStyle(TogetherPressStyle())
    }

    private func sheetHeader(title: String, count: Int) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(ChatFont.font(13, weight: .semibold, design: .serif))
                .foregroundStyle(TogetherSpec.charcoal)
            Text("\(count)")
                .font(ChatFont.font(10, design: .monospaced))
                .foregroundStyle(TogetherSpec.muted)
            Spacer(minLength: 8)
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(TogetherSpec.sub)
                    .frame(width: 30, height: 30)
                    .background(TogetherSpec.ink(0.05), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(TogetherPressStyle())
            .accessibilityLabel(TogetherCopy.cancel)
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 12)
    }
}
// MARK: - 歌单里放什么

// 喜欢不是一个能往里塞的歌单,它只是曲库的一个过滤面
let togetherRoomLikedId = "__liked__"

struct TogetherRoomSongsSheet: View {
    let playlistId: String

    @ObservedObject private var hub = TogetherStateHub.shared
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var lib: TogetherLibrary { hub.library }
    private var isLiked: Bool { playlistId == togetherRoomLikedId }

    // 已在歌单里的曲目 id,加过的显示减号
    private var chosen: Set<String> {
        Set(hub.state.playlists.first { $0.id == playlistId }?.tracks ?? [])
    }

    private var pool: [TogetherTrack] {
        var base = lib.tracks
        if isLiked {
            let ids = Set(hub.state.liked)
            base = base.filter { ids.contains($0.id) }
        }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return base }
        return base.filter {
            $0.title.lowercased().contains(q) || $0.artist.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(isLiked ? AppLocalized("Liked songs", comment: "一起听 · 喜欢的歌") : TogetherCopy.addSongs)
                    .font(ChatFont.font(13, weight: .semibold, design: .serif))
                    .foregroundStyle(TogetherSpec.charcoal)
                Text("\(pool.count)")
                    .font(ChatFont.font(10, design: .monospaced))
                    .foregroundStyle(TogetherSpec.muted)
                Spacer(minLength: 8)
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(TogetherSpec.sub)
                        .frame(width: 30, height: 30)
                        .background(TogetherSpec.ink(0.05), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(TogetherPressStyle())
                .accessibilityLabel(TogetherCopy.cancel)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 12)
            searchField
            songList
        }
        .background(TogetherSpec.capsuleSurface.ignoresSafeArea())
    }
}

extension TogetherRoomSongsSheet {

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(TogetherSpec.muted)
            TextField(TogetherCopy.searchSongOrArtist, text: $query)
                .font(ChatFont.font(12))
                .foregroundStyle(TogetherSpec.charcoal)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(TogetherSpec.ink(0.045), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .padding(.horizontal, 20)
        .padding(.bottom, 6)
    }

    private var songList: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: 0) {
                ForEach(pool, id: \.id) { t in
                    row(t)
                }
                if pool.isEmpty {
                    Text(isLiked ? TogetherCopy.likedEmpty : TogetherCopy.queueEmptyHint)
                        .font(ChatFont.font(11))
                        .foregroundStyle(TogetherSpec.muted)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 26)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
    }
}

extension TogetherRoomSongsSheet {

    private func row(_ t: TogetherTrack) -> some View {
        let chosen = chosen.contains(t.id)
        return Button {
            // 喜欢是过滤面,不是容器,这里只读
            guard !isLiked else { return }
            if chosen {
                TogetherStore.shared.removeTrack(t.id, from: playlistId)
            } else {
                TogetherStore.shared.addTrack(t.id, to: playlistId)
            }
            hub.refreshNow()
            TogetherHaptics.tap()
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(togetherRoomTitle(t.title))
                        .font(ChatFont.font(12, weight: .medium))
                        .foregroundStyle(TogetherSpec.charcoal)
                        .lineLimit(1)
                    if !t.artist.isEmpty {
                        Text(t.artist)
                            .font(ChatFont.font(10, design: .monospaced))
                            .foregroundStyle(TogetherSpec.muted)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if !isLiked {
                    Image(systemName: chosen ? "minus.circle" : "plus.circle")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(chosen ? TogetherSpec.charcoal.opacity(0.55) : TogetherSpec.sub)
                }
            }
            .contentShape(Rectangle())
            .padding(.vertical, 9)
        }
        .buttonStyle(TogetherPressStyle())
    }
}

// MARK: - 房间和弹层共用的小零件

// 曲名和歌手都可能空,给一个统一的兜底,免得三处各写一遍
func togetherRoomTitle(_ raw: String?) -> String {
    let text = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? TogetherCopy.untitledTrack : text
}

func togetherRoomDuration(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds > 0 else { return "" }
    let total = Int(seconds.rounded())
    return String(format: "%d:%02d", total / 60, total % 60)
}

// MARK: - 还差两颗小零件

extension TogetherRoomView {

    // 歌单名后面那颗小箭头:暗示这行能推进去看里面有什么
    private var chevronGlyph: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(TogetherSpec.muted)
    }

    // 相册选图那行要的是 label,不能是 Button,所以单独画一遍同款皮
    private func roomKeyLabel(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(TogetherSpec.sub)
            .frame(width: 32, height: 32)
            .background(TogetherSpec.ink(0.04), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(TogetherSpec.ink(0.07), lineWidth: 0.7)
            )
    }
}
// MARK: - 歌词幕(房间自己的一层)

/// 整页歌词。点一行就跳过去,长按一行把它刻在这首歌上。
struct TogetherRoomLyrics: View {
    let track: TogetherTrack?
    let lyrics: TogetherLyrics?
    let position: Double
    let engraved: String?
    let engrave: (String) -> Void
    var seekTo: (Double) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var pinned = false
    @State private var jumpTicket = 0

    private var lines: [TogetherLyricLine] { lyrics?.lines ?? [] }

    var body: some View {
        ZStack {
            TogetherSpec.charcoal.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                if lines.isEmpty {
                    empty
                } else {
                    list
                }
            }
        }
        .presentationBackground(TogetherSpec.charcoal)
    }
}

extension TogetherRoomLyrics {

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(togetherRoomTitle(track?.title))
                    .font(ChatFont.font(14, weight: .semibold))
                    .foregroundStyle(TogetherSpec.ink(0.92))
                    .lineLimit(1)
                Text(togetherRoomTitle(track?.artist))
                    .font(ChatFont.font(11))
                    .foregroundStyle(TogetherSpec.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if pinned {
                // 你拨开了,想回去再点一下;不回去就停在这句
                Button {
                    TogetherHaptics.tap()
                    pinned = false
                    jumpTicket += 1
                } label: {
                    Text(TogetherCopy.followNow)
                        .font(ChatFont.font(11, weight: .medium))
                        .foregroundStyle(TogetherSpec.sub)
                        .padding(.horizontal, 9)
                        .frame(height: 26)
                        .background(TogetherSpec.ink(0.05), in: Capsule())
                }
                .buttonStyle(.plain)
            }
            Button {
                TogetherHaptics.tap()
                dismiss()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(TogetherSpec.sub)
                    .frame(width: 30, height: 30)
                    .background(TogetherSpec.ink(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(TogetherCopy.a11yCollapse)
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 10)
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "text.alignleft")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(TogetherSpec.ink(0.18))
            Text(TogetherCopy.noLyricsHint)
                .font(ChatFont.font(12))
                .foregroundStyle(TogetherSpec.muted)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { idx, line in
                        row(idx: idx, line: line)
                            .id(idx)
                    }
                    Color.clear.frame(height: 120)
                }
                .padding(.horizontal, 22)
                .padding(.top, 10)
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 6).onChanged { _ in
                    if !pinned { pinned = true }
                }
            )
            .onChange(of: jumpTicket) { _, _ in follow(proxy, animated: true) }
            .onAppear { follow(proxy, animated: false) }
            .onChange(of: currentIndex) { _, _ in follow(proxy, animated: true) }
        }
    }
}extension TogetherRoomLyrics {

    /// 当前唱到哪一句。没有时间戳就当作没有当前句,不硬编。
    private var currentIndex: Int {
        guard !lines.isEmpty else { return -1 }
        var hit = -1
        for (i, line) in lines.enumerated() where line.time <= position + 0.15 {
            hit = i
        }
        return hit
    }

    private func row(idx: Int, line: TogetherLyricLine) -> some View {
        let isNow = idx == currentIndex
        let isEngraved = engraved?.isEmpty == false && engraved == line.text
        return VStack(alignment: .leading, spacing: 4) {
            Text(line.text)
                .font(ChatFont.font(isNow ? 17 : 14.5, weight: isNow ? .semibold : .regular))
                .foregroundStyle(isNow ? TogetherSpec.ink(0.95) : TogetherSpec.ink(0.34))
                .fixedSize(horizontal: false, vertical: true)
            if isEngraved {
                Text(TogetherCopy.engravedMark)
                    .font(ChatFont.font(9.5))
                    .foregroundStyle(TogetherSpec.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            TogetherHaptics.tap()
            seekTo(line.time)
        }
        .onLongPressGesture(minimumDuration: 0.45) {
            TogetherHaptics.select()
            engrave(line.text)
        }
    }

    private func follow(_ proxy: ScrollViewProxy, animated: Bool) {
        guard !pinned, currentIndex >= 0 else { return }
        if animated {
            withAnimation(TogetherCurve.springPhysics) {
                proxy.scrollTo(currentIndex, anchor: .center)
            }
        } else {
            proxy.scrollTo(currentIndex, anchor: .center)
        }
    }
}