//
//  TogetherScreens.swift
//  MinisApp
//
//  一起听 · 歌单库 / 歌单详情 / 我喜欢的音乐 / 一起听 / 编辑面板。
//
//  复用清单（不另造轮子）：
//  头像 → PersonaAvatarView     颜色 → CSSThemeVariables
//  字体 → ChatFont              文案 → TogetherCopy
//  反馈 → MinisToast            数据 → TogetherStore
//

import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers

// MARK: - 共用：页面壁纸
//
// 主题中心每个壁纸槽位都得有页面真的去读，否则"换完没反应"。
// 这一层只干一件事：把那张图原样铺满整页，挂在内容底下，不参与布局。
//
// 以前它还在图上盖了一层全局主题底色（wallpaperShade 0.45），
// 结果是换主题会连带把壁纸压成别的颜色，App 里还没有开关；
// 也没图时悄悄兜到私藏图，删掉某页的图它还从别处冒出来，看着像删不掉。
// 现在：图上不压任何东西，没图就是主题底色。可读性交给前景变量按明暗切换。

struct TogetherWallpaperLayer: View {
    let slot: String

    /// 壁纸一变更就自增，逼这一层重读一遍文件。
    @State private var redrawToken = 0

    var body: some View {
        // GeometryReader 只吃父给的尺寸、绝不反过来撑大父视图——这是这层不参与布局的关键。
        // 以前是裸 ZStack 套 scaledToFill，图比屏幕宽时整块会变大，
        // 塞进 body 的 ZStack 当兄弟就会把内容往右下挤（换壁纸后整页错位就是这个）。
        GeometryReader { geo in
            ZStack {
                // 没图时露主题底色；有图就把图原样铺满，图上不压任何全局底色。
                if let url = TogetherImages.url(for: slot),
                   let img = TogetherImages.cachedImage(for: url) {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                }
            }
        }
        .ignoresSafeArea()
        // 换图 / 删图当场重画，不等页面的 2 秒轮询、不等切 tab。
        // 用 slot 当 id：值一变就强制这一层重建，读到的一定是新文件。
        .id(redrawToken)
        .onReceive(NotificationCenter.default.publisher(for: TogetherImages.didSetNotification)) { note in
            guard let changed = note.object as? String, changed == slot || changed.isEmpty else { return }
            redrawToken += 1
        }
    }
}

// MARK: - 共用：封面

@MainActor
enum TogetherCover {
    /// 五档灰度，明度递减。背景永远从主题里长出来，不写死色值。
    static func fill(_ key: String?) -> LinearGradient {
        let index: Int
        switch key {
        case "cover-1": index = 0
        case "cover-2": index = 1
        case "cover-3": index = 2
        case "cover-4": index = 3
        case "cover-now": index = 4
        default: index = 1
        }
        let steps: [Double] = [0.10, 0.24, 0.42, 0.62, 0.82]
        let base = CSSThemeVariables.textMain(scope: .chat)
        let top = base.opacity(steps[index] * 0.75)
        let bottom = base.opacity(min(0.95, steps[index] + 0.22))
        return LinearGradient(colors: [top, bottom], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static let keys = ["cover-1", "cover-2", "cover-3", "cover-4", "cover-now"]
}

/// 封面：槽位里有图就用图，没有才回落到主题渐变。
/// 图是 shared/together/images/<slot>.<ext>，我和她都能换。
struct TogetherCoverView: View {
    let key: String?
    var corner: CGFloat = 12
    /// 歌单自己的封面优先
    var imagePath: String? = nil

    var body: some View {
        ZStack {
            if let url = TogetherStore.shared.imageURL(imagePath),
               let img = TogetherImages.cachedImage(for: url) {
                Image(uiImage: img).resizable().scaledToFill()
            } else if let key, let url = TogetherImages.url(for: key),
                      let img = TogetherImages.cachedImage(for: url) {
                Image(uiImage: img).resizable().scaledToFill()
            } else {
                TogetherCover.fill(key)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }
}

// MARK: - 共用：一行歌

struct TogetherTrackRow: View {
    let track: TogetherTrack
    var isPlaying: Bool = false
    var noteCount: Int = 0
    var trailing: AnyView?
    var onTap: () -> Void = {}

    var body: some View {
        // 尾巴（爱心/菜单）是尾巴的兄弟，不是行按钮的孩子：
        // 按钮里套按钮，里层那下点不点得着要看系统心情——
        // 喜欢页爱心时灵时不灵就是这个结构。
        HStack(spacing: 8) {
            Button(action: onTap) {
                HStack(spacing: 12) {
                    TogetherCoverView(key: track.cover, corner: 9)
                        .frame(width: 40, height: 40)
                        .overlay(
                            Image(systemName: "music.note")
                                .font(ChatFont.font(13, weight: .medium))
                                .foregroundStyle(CSSThemeVariables.card(scope: .chat).opacity(0.85))
                        )

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text(track.title.isEmpty ? TogetherCopy.untitledTrack : track.title)
                                .font(ChatFont.font(14, weight: .medium))
                                .foregroundStyle(
                                    isPlaying
                                        ? CSSThemeVariables.accent(scope: .chat)
                                        : CSSThemeVariables.textMain(scope: .chat)
                                )
                                .lineLimit(1)

                            if noteCount > 0 {
                                Text("\"")
                                    .font(ChatFont.font(13, weight: .semibold))
                                    .foregroundStyle(CSSThemeVariables.textDim(scope: .chat).opacity(0.8))
                            }
                        }

                        Text("\(track.artist) · \(mmss(track.duration))")
                            .font(ChatFont.font(11.5))
                            .foregroundStyle(CSSThemeVariables.textDim(scope: .chat))
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .togetherPress()

            if let trailing { trailing }
        }
        .frame(minHeight: 44)
        .padding(.vertical, 8)
    }

    private func mmss(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "—" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - 歌单库

struct TogetherLibraryView: View {

    @Binding var editing: TogetherPlaylist?
    @Environment(\.togetherPersonaId) private var sessionPersonaId
    @ObservedObject private var hub = TogetherStateHub.shared

    @State private var showNew = false
    @State private var newName = ""
    @State private var showImporter = false
    @State private var importing = false
    /// copy 模式选择器先落到这里，等 sheet 收起再开始导入。
    @State private var pendingPicks: [URL] = []
    /// 正在换封面的那个歌单
    @State private var coverTarget: TogetherPlaylist?
    /// 删掉的歌单还能捡回来：这张单子就是后悔药。
    @State private var showDeleted = false
    private let importer = LocalFileImporter()

    /// 活着的歌单：Hub 推过来，AI 那边改了也跟着变，不用轮询。
    private var playlists: [TogetherPlaylist] {
        hub.state.playlists.filter { !$0.deleted }
    }
    private var deleted: [TogetherPlaylist] {
        hub.state.playlists.filter { $0.deleted }
    }

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                header
                    .padding(.top, 34)

                HStack {
                    Text(TogetherCopy.myPlaylists)
                        .font(ChatFont.font(15, weight: .semibold))
                        .foregroundStyle(CSSThemeVariables.textMain(scope: .chat))
                    Spacer()
                    Button {
                        TogetherHaptics.select()
                        showImporter = true
                    } label: {
                        if importing {
                            ProgressView().scaleEffect(0.7)
                        } else {
                            Image(systemName: "square.and.arrow.down")
                        }
                    }
                    .togetherPress()
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                    .padding(.trailing, 14)
                    // 侧载包上 .fileImporter 会「选中了但点了没反应」——那是
                    // FileProvider 的 security-scope 授权被静默拒了。
                    // DocumentCopyPicker 走 asCopy，把文件拷进 tmp 再给普通 URL。
                    .sheet(isPresented: $showImporter) {
                        DocumentCopyPicker(contentTypes: importer.allowedTypes,
                                           allowsMultipleSelection: true) { urls in
                            pendingPicks = urls
                        } onDone: {
                            showImporter = false
                            let urls = pendingPicks
                            pendingPicks = []
                            guard !urls.isEmpty else { return }
                            importing = true
                            Task {
                                let added = await importer.importFiles(urls)
                                importing = false
                                let failed = importer.lastFailedNames
                                hub.refreshLibraryNow()
                                hub.refreshNow()
                                if added.isEmpty, !failed.isEmpty {
                                    MinisToast.show(TogetherCopy.importFailed, systemImage: "exclamationmark.circle")
                                } else if !failed.isEmpty {
                                    // 进来几个、没进来几个，各说各的：只报"成功"会让她以为全进来了。
                                    MinisToast.show(TogetherCopy.importFailedCount(failed.count), systemImage: "exclamationmark.circle")
                                } else {
                                    MinisToast.show("\(added.count) \(TogetherCopy.importDone)")
                                }
                            }
                        }
                    }

                    Button {
                        TogetherHaptics.select()
                        newName = ""
                        showNew = true
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "plus")
                            Text(TogetherCopy.newPlaylist)
                        }
                        .font(ChatFont.font(12, weight: .medium))
                        .foregroundStyle(CSSThemeVariables.accent(scope: .chat))
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .togetherPress()
                }
                .padding(.horizontal, 22)
                .padding(.top, 22)

                allSongsEntry
                    .padding(.horizontal, 22)
                    .padding(.top, 14)

                if playlists.isEmpty {
                    emptyPlaylists
                } else {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(playlists) { playlist in
                            playlistCard(playlist)
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 14)
                    .sheet(item: $coverTarget) { playlist in
                        DocumentCopyPicker(contentTypes: [.image],
                                           allowsMultipleSelection: false) { urls in
                            guard let url = urls.first else { return }
                            _ = TogetherStore.shared.setPlaylistImage(id: playlist.id, from: url)
                        } onDone: {
                            coverTarget = nil
                            hub.refreshNow()
                        }
                    }
                }

                // 删掉的歌单一直能捡回来：入口常驻在列表底，不只在空态里。
                if !deleted.isEmpty {
                    Button {
                        TogetherHaptics.select()
                        showDeleted = true
                    } label: {
                        Text("\(TogetherCopy.deletedPlaylists) (\(deleted.count))")
                            .font(ChatFont.font(12, weight: .medium))
                            .foregroundStyle(CSSThemeVariables.textDim(scope: .chat))
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .togetherPress()
                    .padding(.top, 8)
                }
            }
            .padding(.bottom, 24)
        }
        .sheet(isPresented: $showDeleted) {
            deletedPlaylistsSheet
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
                .presentationBackground(CSSThemeVariables.bg(scope: .chat))
        }
        .navigationDestination(for: String.self) { id in
            if id == TogetherAllSongsView.routeID {
                TogetherAllSongsView()
            } else {
                TogetherPlaylistDetail(playlistId: id)
            }
        }
        .sheet(isPresented: $showNew) {
            newPlaylistSheet
                .presentationDetents([.height(220)])
                .presentationBackground(CSSThemeVariables.bg(scope: .chat))
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            HStack(spacing: -10) {
                PersonaAvatarView(iconRef: TogetherIdentity.aiIcon(sessionPersonaId: sessionPersonaId), size: 84)
                    .frame(width: 84, height: 84)
                    .clipShape(Circle())
                    .overlay(Circle().strokeBorder(CSSThemeVariables.bg(scope: .chat), lineWidth: 2.5))
                    .zIndex(1)
                PersonaAvatarView(iconRef: TogetherIdentity.userIcon, size: 84)
                    .frame(width: 84, height: 84)
                    .clipShape(Circle())
                    .overlay(Circle().strokeBorder(CSSThemeVariables.bg(scope: .chat), lineWidth: 2.5))
            }

            Text("\(ChatAddressing.assistant(sessionPersonaId: sessionPersonaId)) & \(ChatAddressing.user())")
                .font(ChatFont.font(15.5, weight: .medium))
                .foregroundStyle(CSSThemeVariables.textMain(scope: .chat))

            Text(summaryLine)
                .font(ChatFont.font(10.5))
                .tracking(0.5)
                .foregroundStyle(CSSThemeVariables.textDim(scope: .chat))
        }
    }

    private var summaryLine: String {
        let songs = hub.library.tracks.count
        let lists = playlists.count
        return String(format: AppLocalized("%1$d songs · %2$d playlists", comment: "一起听 · 库概览"), songs, lists)
    }

    /// 删掉的歌单：一行一个，点"恢复"就回来。删错了不用重建。
    private var deletedPlaylistsSheet: some View {
        NavigationStack {
            List {
                ForEach(deleted) { playlist in
                    HStack {
                        Text(playlist.name)
                            .font(ChatFont.font(14))
                            .foregroundStyle(CSSThemeVariables.textMain(scope: .chat))
                            .lineLimit(1)
                        Spacer()
                        Button(TogetherCopy.restore) {
                            TogetherHaptics.select()
                            TogetherStore.shared.restorePlaylist(id: playlist.id)
                            hub.refreshNow()
                        }
                        .font(ChatFont.font(13, weight: .semibold))
                        .foregroundStyle(CSSThemeVariables.accent(scope: .chat))
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                        .togetherPress()
                    }
                    .listRowBackground(CSSThemeVariables.bg(scope: .chat))
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(CSSThemeVariables.bg(scope: .chat).ignoresSafeArea())
            .navigationTitle(TogetherCopy.deletedPlaylists)
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func playlistCard(_ playlist: TogetherPlaylist) -> some View {
        NavigationLink(value: playlist.id) {
            VStack(alignment: .leading, spacing: 8) {
                TogetherCoverView(key: playlist.bg, corner: 19, imagePath: playlist.image)
                    .aspectRatio(1, contentMode: .fit)
                    .overlay(alignment: .topTrailing) {
                        if playlist.tracks.contains(TogetherPlayer.shared.track?.id ?? "") {
                            playingBars
                                .padding(10)
                        }
                    }

                Text(playlist.name)
                    .font(ChatFont.font(13, weight: .medium))
                    .foregroundStyle(CSSThemeVariables.textMain(scope: .chat))
                    .lineLimit(1)

                Text(String(format: AppLocalized("%d songs", comment: "一起听 · 歌曲数"), playlist.tracks.count))
                    .font(ChatFont.font(10.5))
                    .foregroundStyle(CSSThemeVariables.textDim(scope: .chat))
            }
        }
        .togetherPress()
        .contextMenu {
            Button(TogetherCopy.changeCover) { coverTarget = playlist }
            if playlist.image != nil {
                Button(TogetherCopy.resetCover, role: .destructive) {
                    TogetherStore.shared.clearPlaylistImage(id: playlist.id)
                    hub.refreshNow()
                }
            }
        }
    }

    /// 目录里的歌都能在这儿直接播。歌单只是分类，不是唯一入口。
    private var allSongsEntry: some View {
        NavigationLink(value: TogetherAllSongsView.routeID) {
            HStack(spacing: 12) {
                TogetherCoverView(key: "cover-1", corner: 12)
                    .frame(width: 46, height: 46)
                    .overlay(
                        Image(systemName: "music.note.list")
                            .font(ChatFont.font(16, weight: .medium))
                            .foregroundStyle(CSSThemeVariables.card(scope: .chat).opacity(0.9))
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(TogetherCopy.allSongs)
                        .font(ChatFont.font(14, weight: .medium))
                        .foregroundStyle(CSSThemeVariables.textMain(scope: .chat))
                    Text(String(format: AppLocalized("%d songs", comment: "一起听 · 歌曲数"), hub.library.tracks.count))
                        .font(ChatFont.font(11.5))
                        .foregroundStyle(CSSThemeVariables.textDim(scope: .chat))
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(ChatFont.font(12, weight: .semibold))
                    .foregroundStyle(CSSThemeVariables.textDim(scope: .chat).opacity(0.7))
            }
            .contentShape(Rectangle())
        }
        .togetherPress()
    }

    private var playingBars: some View {
        HStack(spacing: 2) {
            ForEach(0..<3, id: \.self) { i in
                Capsule()
                    .fill(CSSThemeVariables.card(scope: .chat).opacity(0.9))
                    .frame(width: 2.5, height: i == 1 ? 11 : 7)
            }
        }
    }

    private var emptyPlaylists: some View {
        VStack(spacing: 8) {
            Text(TogetherCopy.noSongsYet)
                .font(ChatFont.font(13))
                .foregroundStyle(CSSThemeVariables.textDim(scope: .chat))
            if !deleted.isEmpty {
                Button {
                    TogetherHaptics.select()
                    showDeleted = true
                } label: {
                    Text(TogetherCopy.deletedPlaylists)
                        .font(ChatFont.font(12, weight: .medium))
                        .foregroundStyle(CSSThemeVariables.accent(scope: .chat))
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .togetherPress()
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    private var newPlaylistSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(TogetherCopy.newPlaylist)
                .font(ChatFont.font(15, weight: .semibold))
                .foregroundStyle(CSSThemeVariables.textMain(scope: .chat))

            TextField(TogetherCopy.playlistName, text: $newName)
                .textFieldStyle(.plain)
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(CSSThemeVariables.optionBg(scope: .chat))
                )

            HStack {
                Spacer()
                Button(TogetherCopy.done) {
                    TogetherHaptics.select()
                    if let id = TogetherStore.shared.createPlaylist(name: newName),
                       let created = TogetherStore.shared.livePlaylists().first(where: { $0.id == id }) {
                        hub.refreshNow()
                        editing = created
                    }
                    showNew = false
                }
                .font(ChatFont.font(14, weight: .semibold))
                .foregroundStyle(CSSThemeVariables.accentFg(scope: .chat))
                .padding(.horizontal, 22)
                .frame(minHeight: 44)
                .background(Capsule().fill(CSSThemeVariables.accent(scope: .chat)))
                .togetherPress()
            }
        }
        .padding(22)
    }
}

// MARK: - 全部歌曲

/// 直接读 shared/music：目录里有什么就列什么。
/// 歌单是分类，不是唯一入口——不然导进来的歌没地方找。
struct TogetherAllSongsView: View {

    static let routeID = "all-songs"

    @Environment(\.togetherPersonaId) private var sessionPersonaId
    @Environment(\.togetherInSubpage) private var inSubpage
    @ObservedObject private var hub = TogetherStateHub.shared
    @ObservedObject private var player = TogetherPlayer.shared
    @State private var searchText = ""
    @State private var pendingDelete: TogetherTrack?
    @State private var showDeleteConfirm = false

    /// 曲库就是 Hub 的那一份：AI 删了歌、她导了歌，这里都跟着变。
    private var tracks: [TogetherTrack] { hub.library.tracks }

    private var filtered: [TogetherTrack] {
        guard !searchText.isEmpty else { return tracks }
        return tracks.filter {
            $0.title.localizedCaseInsensitiveContains(searchText) ||
            $0.artist.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Text(TogetherCopy.allSongs)
                    .font(ChatFont.font(21, weight: .semibold))
                    .foregroundStyle(CSSThemeVariables.textMain(scope: .chat))
                    .padding(.top, 26)

                Text(String(format: AppLocalized("%d songs", comment: "一起听 · 歌曲数"), tracks.count))
                    .font(ChatFont.font(11.5))
                    .foregroundStyle(CSSThemeVariables.textDim(scope: .chat))
                    .padding(.top, 6)

                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(ChatFont.font(13))
                        .foregroundStyle(CSSThemeVariables.textDim(scope: .chat))
                    TextField(TogetherCopy.searchSongOrArtist, text: $searchText)
                        .font(ChatFont.font(13))
                        .foregroundStyle(CSSThemeVariables.textMain(scope: .chat))
                    if !searchText.isEmpty {
                        Button { searchText = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(ChatFont.font(13))
                                .foregroundStyle(CSSThemeVariables.textDim(scope: .chat))
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .togetherPress()
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(CSSThemeVariables.optionBg(scope: .chat)))
                .padding(.horizontal, 22)
                .padding(.top, 14)

                VStack(spacing: 0) {
                    ForEach(filtered) { track in
                        TogetherTrackRow(
                            track: track,
                            isPlaying: player.track?.id == track.id,
                            noteCount: 0,
                            trailing: AnyView(
                                Menu {
                                    Button(role: .destructive) {
                                        deleteTrack(track)
                                    } label: {
                                        Label(TogetherCopy.deletePermanently, systemImage: "trash")
                                    }
                                } label: {
                                    Image(systemName: "ellipsis")
                                        .font(ChatFont.font(14))
                                        .foregroundStyle(CSSThemeVariables.textDim(scope: .chat))
                                        .frame(width: 44, height: 44)
                                        .contentShape(Rectangle())
                                }
                            ),
                            onTap: {
                                TogetherHaptics.select()
                                // 点哪首就从哪首开始，队列就是眼前这个列表（搜过就是搜到的列表）。
                                player.start(track, by: .user, queue: filtered.map { $0.id })
                            }
                        )
                        .contextMenu {
                            Button(role: .destructive) {
                                deleteTrack(track)
                            } label: {
                                Label(TogetherCopy.deletePermanently, systemImage: "trash")
                            }
                        }
                        Divider()
                            .overlay(CSSThemeVariables.divider(scope: .chat))
                            .padding(.leading, 52)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.top, 14)

                if tracks.isEmpty {
                    VStack(spacing: 6) {
                        Text(TogetherCopy.emptyTitle(ChatAddressing.assistant(sessionPersonaId: sessionPersonaId)))
                            .font(ChatFont.font(13.5, weight: .semibold))
                            .foregroundStyle(CSSThemeVariables.textMain(scope: .chat))
                        Text(TogetherCopy.emptyHint(ChatAddressing.assistant(sessionPersonaId: sessionPersonaId)))
                            .font(ChatFont.font(12.5))
                            .foregroundStyle(CSSThemeVariables.textDim(scope: .chat))
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, 32)
                    .padding(.top, 40)
                }
            }
            .padding(.bottom, 24)
        }
        .onAppear {
            inSubpage.wrappedValue = true
        }
        .onDisappear { inSubpage.wrappedValue = false }
        .alert(TogetherCopy.deletePermanently, isPresented: $showDeleteConfirm, presenting: pendingDelete) { track in
            Button(AppLocalized("Delete", comment: "删除"), role: .destructive) {
                performDelete(track)
            }
            Button(AppLocalized("Cancel", comment: "取消"), role: .cancel) {}
        } message: { _ in
            Text(TogetherCopy.deleteTrackMessage)
        }
    }

    private func deleteTrack(_ track: TogetherTrack) {
        // 删音频文件不可逆，先问一句，确认后才真删。
        pendingDelete = track
        showDeleteConfirm = true
    }

    private func performDelete(_ track: TogetherTrack) {
        showDeleteConfirm = false
        pendingDelete = nil
        if player.track?.id == track.id {
            player.stop()
        }
        TogetherStore.shared.deleteTrackPermanently(track.id, by: .user)
        hub.refreshLibraryNow()
        hub.refreshNow()
    }
}

// MARK: - 我喜欢的音乐

struct TogetherLikedView: View {

    @Environment(\.togetherPersonaId) private var sessionPersonaId
    @ObservedObject private var hub = TogetherStateHub.shared
    @ObservedObject private var player = TogetherPlayer.shared

    /// 喜欢的歌：Hub 的状态 + Hub 的曲库拼出来，喜欢了/取消了当场变。
    private var liked: [TogetherTrack] {
        hub.state.liked.compactMap { hub.library.track(id: $0) }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                cover
                    .padding(.top, 30)

                Text(AppLocalized("Liked songs", comment: "一起听 · 喜欢的音乐"))
                    .font(ChatFont.font(21, weight: .semibold))
                    .foregroundStyle(CSSThemeVariables.textMain(scope: .chat))
                    .padding(.top, 18)

                HStack(spacing: 8) {
                    HStack(spacing: -8) {
                        PersonaAvatarView(iconRef: TogetherIdentity.userIcon, size: 30)
                            .frame(width: 30, height: 30)
                            .clipShape(Circle())
                            .overlay(Circle().strokeBorder(CSSThemeVariables.bg(scope: .chat), lineWidth: 2))
                            .zIndex(1)
                        PersonaAvatarView(iconRef: TogetherIdentity.aiIcon(sessionPersonaId: sessionPersonaId), size: 30)
                            .frame(width: 30, height: 30)
                            .clipShape(Circle())
                            .overlay(Circle().strokeBorder(CSSThemeVariables.bg(scope: .chat), lineWidth: 2))
                    }
                    Text(String(format: AppLocalized("%d liked songs", comment: "一起听 · 喜欢的音乐数量"), liked.count))
                        .font(ChatFont.font(11.5, design: .serif))
                        .italic()
                        .foregroundStyle(CSSThemeVariables.textDim(scope: .chat))
                }
                .padding(.top, 8)

                HStack(spacing: 12) {
                    Button {
                        TogetherHaptics.tap()
                        guard let first = liked.first else { return }
                        // 从喜欢页点全部播放：队列就是喜欢页这个列表，不是整个曲库。
                        player.start(first, by: .user, queue: liked.map { $0.id })
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "play.fill")
                            Text(TogetherCopy.playAll)
                        }
                        .font(ChatFont.font(13, weight: .semibold))
                        .foregroundStyle(CSSThemeVariables.accentFg(scope: .chat))
                        .padding(.horizontal, 22)
                        .frame(minHeight: 44)
                        .background(Capsule().fill(CSSThemeVariables.accent(scope: .chat)))
                    }
                    .togetherPress()
                    .disabled(liked.isEmpty)

                    Spacer()
                }
                .padding(.horizontal, 22)
                .padding(.top, 18)

                VStack(spacing: 0) {
                    ForEach(liked) { track in
                        TogetherTrackRow(
                            track: track,
                            isPlaying: player.track?.id == track.id,
                            trailing: AnyView(
                                Button {
                                    TogetherHaptics.select()
                                    TogetherStore.shared.toggleLike(trackId: track.id, by: .user)
                                    hub.refreshNow()
                                } label: {
                                    Image(systemName: "heart.fill")
                                        .font(ChatFont.font(14))
                                        .foregroundStyle(CSSThemeVariables.accent(scope: .chat))
                                        .frame(width: 44, height: 44)
                                        .contentShape(Rectangle())
                                }
                                .togetherPress()
                            ),
                            onTap: {
                                TogetherHaptics.select()
                                player.start(track, by: .user, queue: liked.map { $0.id })
                            }
                        )
                        Divider()
                            .overlay(CSSThemeVariables.divider(scope: .chat))
                            .padding(.leading, 52)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.top, 14)

                if liked.isEmpty {
                    Text(TogetherCopy.likedEmpty)
                        .font(ChatFont.font(12.5))
                        .foregroundStyle(CSSThemeVariables.textDim(scope: .chat))
                        .padding(.top, 40)
                }
            }
            .padding(.bottom, 24)
        }
    }

    private var cover: some View {
        // 封面先用她给喜欢页挑的那张壁纸：喜欢页的脸就是她挑的那张图，
        // 没挑才回落到主题渐变。
        TogetherCoverView(key: TogetherImages.wallpaperLiked, corner: 22)
            .frame(width: 172, height: 172)
            .overlay(
                Image(systemName: "heart.fill")
                    .font(ChatFont.font(46, weight: .regular))
                    .foregroundStyle(CSSThemeVariables.card(scope: .chat).opacity(0.92))
            )
    }

}

// MARK: - 一起听（双人状态）

struct TogetherSyncView: View {

    @Environment(\.togetherPersonaId) private var sessionPersonaId
    @ObservedObject private var hub = TogetherStateHub.shared
    @ObservedObject private var player = TogetherPlayer.shared

    private var state: TogetherState { hub.state }
    /// 在场证明只看最近 10 分钟有没有动静：光写 online=true 不算数，
    /// 那两个布尔以前只会被写成 true，从没被写成 false。
    private var aiHere: Bool { state.devices.ai.seenRecently(now: TogetherStore.now()) }
    private var userHere: Bool { state.devices.user.seenRecently(now: TogetherStore.now()) }

    /// 伴听页自己的换壁纸入口：不绕装扮中心，当场换当场见效。
    @State private var showWallpaperPicker = false
    @State private var wallpaperItem: PhotosPickerItem?
    @State private var wallpaperError: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                duo
                    .padding(.top, 34)

                Text(driverLine)
                    .font(ChatFont.font(10.5))
                    .tracking(0.6)
                    .foregroundStyle(CSSThemeVariables.textDim(scope: .chat))
                    .padding(.top, 22)

                wallpaperBar
                    .padding(.top, 12)

                currentCard
                    .padding(.horizontal, 22)
                    .padding(.top, 18)

                deviceList
                    .padding(.horizontal, 22)
                    .padding(.top, 22)

                if let note = latestAINote {
                    aiLine(note)
                        .padding(.horizontal, 22)
                        .padding(.top, 20)
                }

                handoffButton
                    .padding(.horizontal, 22)
                    .padding(.top, 24)
            }
            .padding(.bottom, 30)
        }
        .onAppear {
            // 她打开这页就是她在场：刷新她这一侧的在场时间，AI 那边才能看见她来了。
            TogetherStore.shared.markSeen(by: .user)
            hub.refreshNow()
        }
        .photosPicker(isPresented: $showWallpaperPicker, selection: $wallpaperItem, matching: .images)
        .onChange(of: wallpaperItem) { item in
            guard let item else { return }
            wallpaperItem = nil
            Task {
                let ok = await TogetherPhotoImport.toSlot(item, slot: TogetherImages.wallpaperSync)
                wallpaperError = ok ? nil : TogetherPhotoImport.reason
            }
        }
    }

    /// 换壁纸按钮 + 失败原因。失败不说"换个图试试"，直接讲卡在哪一步。
    private var wallpaperBar: some View {
        VStack(spacing: 6) {
            Button {
                TogetherHaptics.select()
                wallpaperError = nil
                showWallpaperPicker = true
            } label: {
                Label(TogetherCopy.changeWallpaper, systemImage: "photo.on.rectangle.angled")
                    .font(ChatFont.font(12, weight: .medium))
                    .foregroundStyle(CSSThemeVariables.accent(scope: .chat))
                    .padding(.horizontal, 14)
                    .frame(minHeight: 44)
                    .background(
                        Capsule().fill(CSSThemeVariables.card(scope: .chat).opacity(0.75))
                    )
            }
            .togetherPress()

            if let wallpaperError {
                Text(wallpaperError)
                    .font(ChatFont.font(9.5))
                    .foregroundStyle(CSSThemeVariables.danger(scope: .chat))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)
            }
        }
    }

    private var duo: some View {
        HStack(spacing: 26) {
            side(.user, name: ChatAddressing.user(), size: 88)
                .frame(maxWidth: .infinity)

            wave
                .frame(width: 74, height: 26)

            side(.ai, name: ChatAddressing.assistant(sessionPersonaId: sessionPersonaId), size: 88)
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 30)
    }

    private func side(_ role: TogetherActor, name: String, size: CGFloat) -> some View {
        VStack(spacing: 9) {
            PersonaAvatarView(
                iconRef: role == .ai ? TogetherIdentity.aiIcon(sessionPersonaId: sessionPersonaId) : TogetherIdentity.userIcon,
                size: size
            )
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(CSSThemeVariables.bg(scope: .chat), lineWidth: 3.5))

            Text(name)
                .font(ChatFont.font(12, weight: .medium))
                .foregroundStyle(CSSThemeVariables.textMain(scope: .chat))
                .lineLimit(1)

            Text(role == .ai && state.playback.by == "ai"
                 ? AppLocalized("controlling", comment: "一起听 · 在控制")
                 : AppLocalized("following", comment: "一起听 · 跟着听"))
                .font(ChatFont.font(9.5, weight: .medium))
                .tracking(0.5)
                .foregroundStyle(CSSThemeVariables.textDim(scope: .chat))
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(Capsule().fill(CSSThemeVariables.optionBg(scope: .chat)))
        }
    }

    /// 两人之间的那道波纹：静态的，不转、不闪——这页是"在场"的证明，
    /// 不是等她看的动画。播着还是停着，看中间那张卡就够了。
    private var wave: some View {
        HStack(spacing: 4) {
            ForEach([6, 16, 10, 16, 6], id: \.self) { h in
                Capsule()
                    .fill(CSSThemeVariables.textDim(scope: .chat).opacity(0.55))
                    .frame(width: 2.5, height: CGFloat(h))
            }
        }
        .accessibilityHidden(true)
    }

    /// 谁在掌控 + 他现在的心情，一句话，不说"同步中"这种没法验证的话。
    /// 没心情就不写心情，安安静静一句话。
    private var driverLine: String {
        let driver = state.playback.by == "ai"
            ? ChatAddressing.assistant(sessionPersonaId: sessionPersonaId)
            : ChatAddressing.user()
        let driving = state.playback.by == "ai"
            ? TogetherCopy.driving(driver)
            : TogetherCopy.youDriving
        if let mood = state.me.presence.mood {
            return "\(driving) · \(mood.word)"
        }
        return driving
    }

    private var currentCard: some View {
        // 这张卡读的是共享状态里的那首歌（state.track），不是本机播放器的那首：
        // 两边说的必须同一首，面板、卡片、小卡三处才不会各说各的。
        // 本机还没跟上时（刚打开），先显示共享的那首，播放器随后会跟过来。
        let sharedTrack = state.track ?? player.track
        return HStack(spacing: 12) {
            TogetherCoverView(key: sharedTrack?.cover, corner: 12)
                .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 3) {
                Text(sharedTrack?.title ?? TogetherCopy.untitledTrack)
                    .font(ChatFont.font(14, weight: .medium))
                    .foregroundStyle(CSSThemeVariables.textMain(scope: .chat))
                    .lineLimit(1)
                Text(sharedTrack?.artist ?? "")
                    .font(ChatFont.font(11.5))
                    .foregroundStyle(CSSThemeVariables.textDim(scope: .chat))
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Button {
                TogetherHaptics.tap()
                player.userToggle()
                hub.refreshNow()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(ChatFont.font(14, weight: .semibold))
                    .foregroundStyle(CSSThemeVariables.accentFg(scope: .chat))
                    .frame(width: 44, height: 44)
                    .background(CSSThemeVariables.accent(scope: .chat))
                    .clipShape(Circle())
                    .contentShape(Rectangle())
            }
            .togetherPress()
            .accessibilityLabel(player.isPlaying ? TogetherCopy.a11yPause : TogetherCopy.a11yPlay)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(CSSThemeVariables.card(scope: .chat))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(CSSThemeVariables.optionBorder(scope: .chat), lineWidth: 0.5)
        )
    }

    private var deviceList: some View {
        VStack(spacing: 0) {
            deviceRow(
                name: "\(ChatAddressing.user())\(AppLocalized("'s iPhone", comment: "一起听 · 设备"))",
                detail: userHere ? TogetherCopy.onlineStatus : TogetherCopy.awayStatus,
                controlling: state.playback.by == "user"
            )
            Divider().overlay(CSSThemeVariables.divider(scope: .chat))
            deviceRow(
                name: ChatAddressing.assistant(sessionPersonaId: sessionPersonaId),
                detail: aiHere
                    ? (state.me.presence.mood.map { "\($0.word)" } ?? TogetherCopy.onlineStatus)
                    : TogetherCopy.awayStatus,
                controlling: state.playback.by == "ai"
            )
        }
    }

    private func deviceRow(name: String, detail: String, controlling: Bool) -> some View {
        HStack {
            Text(name)
                .font(ChatFont.font(13, weight: controlling ? .semibold : .regular))
                .foregroundStyle(
                    controlling
                        ? CSSThemeVariables.textMain(scope: .chat)
                        : CSSThemeVariables.textDim(scope: .chat)
                )
            Spacer()
            Text(detail)
                .font(ChatFont.font(11))
                .foregroundStyle(CSSThemeVariables.textDim(scope: .chat))
            if controlling {
                Image(systemName: "checkmark")
                    .font(ChatFont.font(11, weight: .semibold))
                    .foregroundStyle(CSSThemeVariables.accent(scope: .chat))
                    .padding(.leading, 6)
            }
        }
        .padding(.vertical, 13)
    }

    private var latestAINote: TogetherNote? {
        guard let trackId = state.track?.id ?? player.track?.id else { return nil }
        return state.notes
            .filter { $0.trackId == trackId && $0.from == TogetherActor.ai.rawValue }
            .max(by: { $0.ts < $1.ts })
    }

    private func aiLine(_ note: TogetherNote) -> some View {
        HStack(alignment: .top, spacing: 9) {
            PersonaAvatarView(iconRef: TogetherIdentity.aiIcon(sessionPersonaId: sessionPersonaId), size: 26)
                .frame(width: 26, height: 26)
                .clipShape(Circle())

            Text(note.text)
                .font(ChatFont.font(12.5))
                .foregroundStyle(CSSThemeVariables.textMain(scope: .chat))
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(CSSThemeVariables.optionBg(scope: .chat).opacity(0.6))
        )
    }

    /// 遥控器不是一按就翻的：先递出去，对方接了才算换手。
    /// 递给他的那 10 秒里，他接了就换、没接就原样——不会出现
    /// "她点了递出、他那边还在播旧的、状态却已经写成他的"那种错位。
    private var handoffButton: some View {
        VStack(spacing: 10) {
            if let pending = state.pendingHandoff {
                if pending.to == TogetherActor.user.rawValue {
                    Text(TogetherCopy.remoteOffered(ChatAddressing.user()))
                        .font(ChatFont.font(12))
                        .foregroundStyle(CSSThemeVariables.textDim(scope: .chat))
                    HStack(spacing: 12) {
                        Button {
                            TogetherHaptics.select()
                            _ = TogetherStore.shared.acceptHandoff()
                            hub.refreshNow()
                        } label: {
                            Text(AppLocalized("Take the remote", comment: "一起听 · 接过遥控器"))
                                .font(ChatFont.font(13, weight: .semibold))
                                .foregroundStyle(CSSThemeVariables.accentFg(scope: .chat))
                                .frame(maxWidth: .infinity)
                                .frame(minHeight: 44)
                                .background(Capsule().fill(CSSThemeVariables.accent(scope: .chat)))
                        }
                        .togetherPress()
                        Button {
                            TogetherHaptics.select()
                            TogetherStore.shared.cancelHandoff(by: .user)
                            hub.refreshNow()
                        } label: {
                            Text(TogetherCopy.cancel)
                                .font(ChatFont.font(13, weight: .medium))
                                .foregroundStyle(CSSThemeVariables.textMain(scope: .chat))
                                .frame(maxWidth: .infinity)
                                .frame(minHeight: 44)
                                .background(Capsule().fill(CSSThemeVariables.optionBg(scope: .chat)))
                        }
                        .togetherPress()
                    }
                } else {
                    Text(TogetherCopy.waitingForHandoff(ChatAddressing.assistant(sessionPersonaId: sessionPersonaId)))
                        .font(ChatFont.font(12))
                        .foregroundStyle(CSSThemeVariables.textDim(scope: .chat))
                    Button {
                        TogetherHaptics.select()
                        TogetherStore.shared.cancelHandoff(by: .user)
                        hub.refreshNow()
                    } label: {
                        Text(TogetherCopy.cancel)
                            .font(ChatFont.font(13, weight: .medium))
                            .foregroundStyle(CSSThemeVariables.textMain(scope: .chat))
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: 44)
                            .background(Capsule().fill(CSSThemeVariables.optionBg(scope: .chat)))
                    }
                    .togetherPress()
                }
            } else {
                Button {
                    TogetherHaptics.select()
                    let next = state.playback.by == TogetherActor.ai.rawValue ? TogetherActor.user : TogetherActor.ai
                    // 已经在他手里就不用递：requestHandoff 会拒绝，界面原样不动。
                    _ = TogetherStore.shared.requestHandoff(to: next.rawValue, by: .user)
                    hub.refreshNow()
                } label: {
                    Text("\(TogetherCopy.handoff) \(state.playback.by == "ai" ? ChatAddressing.user() : ChatAddressing.assistant(sessionPersonaId: sessionPersonaId))")
                        .font(ChatFont.font(13, weight: .medium))
                        .foregroundStyle(CSSThemeVariables.textMain(scope: .chat))
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 44)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(CSSThemeVariables.optionBg(scope: .chat))
                        )
                }
                .togetherPress()
            }
        }
    }
}

// MARK: - 编辑面板

struct TogetherPlaylistEditor: View {

    let playlist: TogetherPlaylist

    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    @State private var tags: [String] = []
    @State private var desc: String = ""
    @State private var bg: String = "cover-1"
    @State private var showCoverPicker = false
    @State private var coverItem: PhotosPickerItem?
    /// 草稿封面：只存在内存里，点了"保存"才落盘；点了"取消"就当没选过。
    /// 以前选完图当场就写盘，取消也撤不回——封面比名字先"保存"了。
    @State private var draftCover: UIImage?
    @State private var showTagSheet = false
    @State private var confirmDelete = false
    @State private var pendingDelete: TogetherTrack?
    @State private var showDeleteConfirm = false
    /// 打开时的背景值：保存时和它比，改过才写盘，别每次都多发一条 playlist.bg。
    @State private var originalBg: String = "cover-1"

    /// 预设标签存"键",不存译文:译文随语言变,存进歌单后一切语言就对不上。
    /// 旧数据存的是译文,displayTag 认不出来就原样显示,不丢。
    private static let presetTagKeys = [
        "pop", "sad", "healing", "romantic", "night", "drive",
        "electronic", "light", "whiteNoise", "rock", "acg", "instrumental",
    ]

    private func displayTag(_ raw: String) -> String {
        switch raw {
        case "pop": return AppLocalized("Pop", comment: "一起听 · 标签 流行")
        case "sad": return AppLocalized("Sad", comment: "一起听 · 标签 伤感")
        case "healing": return AppLocalized("Healing", comment: "一起听 · 标签 治愈")
        case "romantic": return AppLocalized("Romantic", comment: "一起听 · 标签 浪漫")
        case "night": return AppLocalized("Night", comment: "一起听 · 标签 夜晚")
        case "drive": return AppLocalized("Drive", comment: "一起听 · 标签 车载")
        case "electronic": return AppLocalized("Electronic", comment: "一起听 · 标签 电子")
        case "light": return AppLocalized("Light music", comment: "一起听 · 标签 轻音乐")
        case "whiteNoise": return AppLocalized("White noise", comment: "一起听 · 标签 白噪音")
        case "rock": return AppLocalized("Rock", comment: "一起听 · 标签 摇滚")
        case "acg": return AppLocalized("ACG", comment: "一起听 · 标签 ACG")
        case "instrumental": return AppLocalized("Instrumental", comment: "一起听 · 标签 纯音乐")
        default: return raw
        }
    }

    private var tagsLabel: String {
        tags.isEmpty ? TogetherCopy.noTags : tags.map(displayTag).joined(separator: " · ")
    }

    private var tagsColor: Color {
        tags.isEmpty ? CSSThemeVariables.textDim(scope: .chat) : CSSThemeVariables.accent(scope: .chat)
    }

    private var descCountString: String {
        "\(desc.count)/1000"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    cardSection
                    descSection
                    deleteSection
                }
                .padding(20)
            }
            .background(CSSThemeVariables.bg(scope: .chat).ignoresSafeArea())
            .navigationTitle(TogetherCopy.playlistInfo)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(AppLocalized("Cancel", comment: "取消")) { dismiss() }
                        .font(ChatFont.font(14))
                        .foregroundStyle(CSSThemeVariables.textDim(scope: .chat))
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                        .togetherPress()
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(AppLocalized("Save", comment: "保存")) {
                        save()
                        dismiss()
                    }
                    .font(ChatFont.font(14, weight: .bold))
                    .foregroundStyle(CSSThemeVariables.accent(scope: .chat))
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
                    .togetherPress()
                }
            }
            .onAppear(perform: reload)
            .alert(TogetherCopy.deletePlaylist, isPresented: $confirmDelete) {
                Button(AppLocalized("Delete", comment: "删除"), role: .destructive) {
                    TogetherStore.shared.deletePlaylist(id: playlist.id)
                    dismiss()
                }
                Button(AppLocalized("Cancel", comment: "取消"), role: .cancel) {}
            }
            .photosPicker(isPresented: $showCoverPicker,
                          selection: $coverItem,
                          matching: .images)
            .onChange(of: coverItem) { item in
                guard let item else { return }
                Task {
                    // 只读成图、留在草稿里：不写盘，取消键才作数。
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        draftCover = image
                    }
                    coverItem = nil
                }
            }
            .sheet(isPresented: $showTagSheet) {
                tagSelectionSheet
                    .presentationDetents([.height(300)])
                    .presentationBackground(CSSThemeVariables.bg(scope: .chat))
            }
            .alert(TogetherCopy.deletePermanently, isPresented: $showDeleteConfirm, presenting: pendingDelete) { track in
                Button(AppLocalized("Delete", comment: "删除"), role: .destructive) {
                    performDelete(track)
                }
                Button(AppLocalized("Cancel", comment: "取消"), role: .cancel) {}
            } message: { _ in
                Text(TogetherCopy.deleteTrackMessage)
            }
        }
    }

    private var cardSection: some View {
        VStack(spacing: 0) {
            HStack {
                Text(TogetherCopy.changeCoverTitle)
                    .font(ChatFont.font(14, weight: .medium))
                    .foregroundStyle(CSSThemeVariables.textMain(scope: .chat))
                Spacer()
                Button {
                    TogetherHaptics.select()
                    showCoverPicker = true
                } label: {
                    HStack(spacing: 8) {
                        // 有草稿就看草稿：预览的就是保存后会成的样子。
                        if let draftCover {
                            Image(uiImage: draftCover)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 44, height: 44)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        } else {
                            TogetherCoverView(key: bg, corner: 8, imagePath: playlist.image)
                                .frame(width: 44, height: 44)
                        }
                        Image(systemName: "chevron.right")
                            .font(ChatFont.font(12))
                            .foregroundStyle(CSSThemeVariables.textDim(scope: .chat))
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .togetherPress()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider().overlay(CSSThemeVariables.divider(scope: .chat)).padding(.leading, 16)

            HStack {
                Text(TogetherCopy.playlistName)
                    .font(ChatFont.font(14, weight: .medium))
                    .foregroundStyle(CSSThemeVariables.textMain(scope: .chat))
                Spacer()
                TextField(TogetherCopy.playlistName, text: $name)
                    .font(ChatFont.font(14))
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(CSSThemeVariables.textMain(scope: .chat))
                    .frame(maxWidth: 180)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            Divider().overlay(CSSThemeVariables.divider(scope: .chat)).padding(.leading, 16)

            HStack {
                Text(TogetherCopy.tags)
                    .font(ChatFont.font(14, weight: .medium))
                    .foregroundStyle(CSSThemeVariables.textMain(scope: .chat))
                Spacer()
                Button {
                    TogetherHaptics.select()
                    showTagSheet = true
                } label: {
                    HStack(spacing: 6) {
                        Text(tagsLabel)
                            .font(ChatFont.font(13))
                            .foregroundStyle(tagsColor)
                            .lineLimit(1)
                        Image(systemName: "chevron.right")
                            .font(ChatFont.font(12))
                            .foregroundStyle(CSSThemeVariables.textDim(scope: .chat))
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .togetherPress()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(CSSThemeVariables.card(scope: .chat))
        )
    }

    private var descSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(TogetherCopy.descTitle)
                .font(ChatFont.font(13, weight: .semibold))
                .foregroundStyle(CSSThemeVariables.textDim(scope: .chat))

            ZStack(alignment: .topLeading) {
                TextEditor(text: $desc)
                    .font(ChatFont.font(13.5))
                    .foregroundStyle(CSSThemeVariables.textMain(scope: .chat))
                    .scrollContentBackground(.hidden)
                    .background(Color.clear)
                    .frame(height: 110)
                    .padding(6)
                    .onChange(of: desc, perform: onDescChanged)

                // 占位字画在输入框上面、且不吃点击，不再被输入区盖掉。
                // 底下也不再垫一层灰板：那块灰就是"盖住输入区"的东西。
                if desc.isEmpty {
                    Text(TogetherCopy.descPlaceholder)
                        .font(ChatFont.font(13.5))
                        .foregroundStyle(CSSThemeVariables.textDim(scope: .chat).opacity(0.6))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .allowsHitTesting(false)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(CSSThemeVariables.divider(scope: .chat), lineWidth: 0.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            HStack {
                Spacer()
                Text(descCountString)
                    .font(ChatFont.font(11))
                    .foregroundStyle(CSSThemeVariables.textDim(scope: .chat))
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(CSSThemeVariables.card(scope: .chat))
        )
    }

    private var deleteSection: some View {
        Button {
            confirmDelete = true
        } label: {
            Text(TogetherCopy.deletePlaylist)
                .font(ChatFont.font(14, weight: .semibold))
                .foregroundStyle(CSSThemeVariables.danger(scope: .chat))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(CSSThemeVariables.dangerSoft(scope: .chat))
                )
        }
        .togetherPress()
        .padding(.top, 10)
    }

    private var tagSelectionSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(TogetherCopy.tags)
                .font(ChatFont.font(16, weight: .bold))
                .foregroundStyle(CSSThemeVariables.textMain(scope: .chat))

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 70))], spacing: 10) {
                ForEach(Self.presetTagKeys, id: \.self) { t in
                    tagPill(t)
                }
            }

            Spacer()

            Button(TogetherCopy.done) { showTagSheet = false }
                .font(ChatFont.font(14, weight: .semibold))
                .foregroundStyle(CSSThemeVariables.accent(scope: .chat))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Capsule().fill(CSSThemeVariables.optionBg(scope: .chat)))
        }
        .padding(22)
    }

    private func tagPill(_ t: String) -> some View {
        let isSelected = tags.contains(t)
        let fgColor = isSelected ? CSSThemeVariables.accent(scope: .chat) : CSSThemeVariables.textMain(scope: .chat)
        let bgColor = isSelected ? CSSThemeVariables.accent(scope: .chat).opacity(0.15) : CSSThemeVariables.optionBg(scope: .chat)

        return Button {
            TogetherHaptics.select()
            if isSelected {
                tags.removeAll { $0 == t }
            } else {
                tags.append(t)
            }
        } label: {
            Text(displayTag(t))
                .font(ChatFont.font(12, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(fgColor)
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .background(Capsule().fill(bgColor))
        }
        .togetherPress()
    }

    private func onDescChanged(_ val: String) {
        if val.count > 1000 {
            desc = String(val.prefix(1000))
        }
    }

    private func deleteTrack(_ track: TogetherTrack) {
        // 删音频文件不可逆，先问一句，确认后才真删。
        pendingDelete = track
        showDeleteConfirm = true
    }

    private func performDelete(_ track: TogetherTrack) {
        // 先把确认态收掉，再删；编辑器的 reload 没有列表轮询，删完直接重读即可。
        showDeleteConfirm = false
        pendingDelete = nil
        if TogetherPlayer.shared.track?.id == track.id {
            TogetherPlayer.shared.stop()
        }
        TogetherStore.shared.deleteTrackPermanently(track.id, by: .user)
        reload()
    }

    private func reload() {
        let live = TogetherStore.shared.livePlaylists().first { $0.id == playlist.id } ?? playlist
        name = live.name
        tags = live.tags
        desc = live.desc
        bg = live.bg ?? "cover-1"
        originalBg = bg
        draftCover = nil
    }

    private func save() {
        // 草稿封面在保存这一刻才落盘：先写图、再写文字，取消键全程作数。
        if let draftCover, let data = draftCover.jpegData(compressionQuality: 0.9) {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("together-playlist-\(playlist.id)-\(UUID().uuidString).jpg")
            defer { try? FileManager.default.removeItem(at: tmp) }
            if (try? data.write(to: tmp)) != nil {
                _ = TogetherStore.shared.setPlaylistImage(id: playlist.id, from: tmp)
            }
        }
        _ = TogetherStore.shared.updatePlaylistInfo(id: playlist.id, name: name, tags: tags, desc: desc, by: .user)
        // 背景不是名字的一部分，updatePlaylistInfo 不碰它；改过就单独存一次，否则退出再进会丢。
        if bg != originalBg {
            TogetherStore.shared.setPlaylistBackground(id: playlist.id, bg: bg, by: .user)
            originalBg = bg
        }
    }
}
// MARK: - 歌单详情
//
// 跟编辑面板分开：详情是"看和听"，编辑是"改"。
// 一条歌单点进来，第一件事是能播，不是能改。

struct TogetherPlaylistDetail: View {

    let playlistId: String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.togetherPersonaId) private var sessionPersonaId
    @Environment(\.togetherInSubpage) private var inSubpage
    @State private var searchText = ""
    @State private var showEditor = false
    @State private var showAddSongs = false
    @State private var pendingDelete: TogetherTrack?
    @State private var showDeleteConfirm = false
    @ObservedObject private var hub = TogetherStateHub.shared
    @ObservedObject private var player = TogetherPlayer.shared

    /// 活着的歌单 + 它的歌：Hub 推过来，删了歌单这里就变成 nil，
    /// 页面自己退场，不留一个空标题的僵尸页。
    private var playlist: TogetherPlaylist? {
        hub.state.playlists.first { $0.id == playlistId && !$0.deleted }
    }
    private var tracks: [TogetherTrack] {
        (playlist?.tracks ?? []).compactMap { hub.library.track(id: $0) }
    }

    private var filteredTracks: [TogetherTrack] {
        if searchText.isEmpty { return tracks }
        return tracks.filter {
            $0.title.localizedCaseInsensitiveContains(searchText) ||
            $0.artist.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        // 歌单已经删了：不留空页，退回歌单库。
        if playlist == nil {
            Color.clear
                .onAppear { dismiss() }
        } else {
        ScrollView {
            VStack(spacing: 0) {
                header
                    .padding(.top, 8)

                // 搜索栏
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(ChatFont.font(13))
                        .foregroundStyle(CSSThemeVariables.textDim(scope: .chat))
                    TextField(TogetherCopy.searchSongOrArtist, text: $searchText)
                        .font(ChatFont.font(13))
                        .foregroundStyle(CSSThemeVariables.textMain(scope: .chat))
                    if !searchText.isEmpty {
                        Button { searchText = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(ChatFont.font(13))
                                .foregroundStyle(CSSThemeVariables.textDim(scope: .chat))
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .togetherPress()
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(CSSThemeVariables.optionBg(scope: .chat)))
                .padding(.horizontal, 22)
                .padding(.top, 14)

                actionRow
                    .padding(.horizontal, 22)
                    .padding(.top, 14)

                VStack(spacing: 0) {
                    ForEach(filteredTracks) { track in
                        playlistTrackRow(track)
                        Divider()
                            .overlay(CSSThemeVariables.divider(scope: .chat))
                            .padding(.leading, 52)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.top, 18)

                if tracks.isEmpty {
                    VStack(spacing: 10) {
                        Text(TogetherCopy.noSongsYet)
                            .font(ChatFont.font(13))
                            .foregroundStyle(CSSThemeVariables.textDim(scope: .chat))
                        Button {
                            TogetherHaptics.select()
                            showAddSongs = true
                        } label: {
                            Text(TogetherCopy.addSongs)
                                .frame(minHeight: 44)
                                .contentShape(Rectangle())
                        }
                            .font(ChatFont.font(13, weight: .medium))
                            .foregroundStyle(CSSThemeVariables.accent(scope: .chat))
                            .togetherPress()
                    }
                    .padding(.top, 40)
                }
            }
            .padding(.bottom, 30)
        }
        // 歌单库壁纸：库页、全部歌曲页、详情页同一套，装扮中心那句才不虚。
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    TogetherHaptics.select()
                    showEditor = true
                } label: {
                    Text(TogetherCopy.edit)
                }
                    .font(ChatFont.font(14, weight: .medium))
                    .foregroundStyle(CSSThemeVariables.accent(scope: .chat))
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
                    .togetherPress()
            }
        }
        .onAppear {
            inSubpage.wrappedValue = true
        }
        .onDisappear { inSubpage.wrappedValue = false }
        .onChange(of: hub.state.revision) { _ in
            // 歌单在别处被删了：这页立刻退场，不留僵尸页。
            if playlist == nil { dismiss() }
        }
        .alert(TogetherCopy.deletePermanently, isPresented: $showDeleteConfirm, presenting: pendingDelete) { track in
            Button(AppLocalized("Delete", comment: "删除"), role: .destructive) {
                performDelete(track)
            }
            Button(AppLocalized("Cancel", comment: "取消"), role: .cancel) {}
        } message: { _ in
            Text(TogetherCopy.deleteTrackMessage)
        }
        .sheet(isPresented: $showEditor) {
            if let playlist {
                TogetherPlaylistEditor(playlist: playlist)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
                    .presentationBackground(CSSThemeVariables.bg(scope: .chat))
            }
        }
        .sheet(isPresented: $showAddSongs) {
            TogetherAddSongsSheet(playlistId: playlistId)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(CSSThemeVariables.bg(scope: .chat))
        }
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            // 头图跟编辑页同一套画法：有图就画图，没图才回落到主题渐变。
            TogetherCoverView(key: playlist?.bg, corner: 22, imagePath: playlist?.image)
                .frame(width: 118, height: 118)

            Text(playlist?.name ?? "")
                .font(ChatFont.font(22, weight: .semibold))
                .foregroundStyle(CSSThemeVariables.textMain(scope: .chat))
                .multilineTextAlignment(.center)

            HStack(spacing: 7) {
                HStack(spacing: -8) {
                    PersonaAvatarView(iconRef: TogetherIdentity.aiIcon(sessionPersonaId: sessionPersonaId), size: 30)
                        .frame(width: 30, height: 30)
                        .clipShape(Circle())
                        .overlay(Circle().strokeBorder(CSSThemeVariables.bg(scope: .chat), lineWidth: 2))
                        .zIndex(1)
                    PersonaAvatarView(iconRef: TogetherIdentity.userIcon, size: 30)
                        .frame(width: 30, height: 30)
                        .clipShape(Circle())
                        .overlay(Circle().strokeBorder(CSSThemeVariables.bg(scope: .chat), lineWidth: 2))
                }
                Text("\(ChatAddressing.assistant(sessionPersonaId: sessionPersonaId)) & \(ChatAddressing.user()) \(TogetherCopy.editedTogether)")
                    .font(ChatFont.font(10.5))
                    .foregroundStyle(CSSThemeVariables.textDim(scope: .chat))
            }
        }
    }

    private var actionRow: some View {
        HStack(spacing: 12) {
            Button {
                TogetherHaptics.tap()
                guard let first = tracks.first else { return }
                // 歌单详情全部播放：队列就是这个歌单
                player.start(first, by: .user, queue: tracks.map { $0.id })
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "play.fill")
                    Text(TogetherCopy.playAll)
                }
                .font(ChatFont.font(13, weight: .semibold))
                .foregroundStyle(CSSThemeVariables.accentFg(scope: .chat))
                .padding(.horizontal, 22)
                .frame(minHeight: 44)
                .background(Capsule().fill(CSSThemeVariables.accent(scope: .chat)))
            }
            .togetherPress()
            .disabled(tracks.isEmpty)

            Button {
                TogetherHaptics.select()
                guard let pick = tracks.randomElement() else { return }
                // 随机按钮要真的打开随机模式，不是"悄悄放一首随机的、模式还关着"。
                // 一次写完：随机开、两个循环关，状态里只记一条事件。
                TogetherStore.shared.setModes(shuffle: true, repeatOne: false, repeatAll: false, by: .user)
                player.start(pick, by: .user, queue: tracks.map { $0.id })
            } label: {
                Image(systemName: "shuffle")
                    .font(ChatFont.font(14, weight: .medium))
                    .foregroundStyle(CSSThemeVariables.textMain(scope: .chat))
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(CSSThemeVariables.optionBg(scope: .chat)))
                    .contentShape(Rectangle())
            }
            .togetherPress()
            .accessibilityLabel(TogetherCopy.a11yShuffle)

            Button {
                TogetherHaptics.select()
                showAddSongs = true
            } label: {
                Text(TogetherCopy.addSongs)
            }
                .font(ChatFont.font(12.5, weight: .medium))
                .foregroundStyle(CSSThemeVariables.textMain(scope: .chat))
                .padding(.horizontal, 15)
                .frame(minHeight: 44)
                .overlay(Capsule().strokeBorder(CSSThemeVariables.optionBorder(scope: .chat), lineWidth: 0.8))
                .togetherPress()

            Spacer()
        }
    }

    private func noteCount(for trackId: String) -> Int {
        hub.state.notes.filter { $0.trackId == trackId }.count
    }

    private func playlistTrackRow(_ track: TogetherTrack) -> some View {
        TogetherTrackRow(
            track: track,
            isPlaying: player.track?.id == track.id,
            noteCount: noteCount(for: track.id),
            trailing: AnyView(rowTrailing(track)),
            onTap: {
                TogetherHaptics.select()
                player.start(track, by: .user, queue: tracks.map { $0.id })
            }
        )
        .contextMenu { rowContextMenu(track) }
    }

    private func rowTrailing(_ track: TogetherTrack) -> some View {
        HStack(spacing: 12) {
            Button {
                TogetherHaptics.select()
                TogetherStore.shared.toggleLike(trackId: track.id, by: .user)
                hub.refreshNow()
            } label: {
                Image(systemName: hub.state.liked.contains(track.id) ? "heart.fill" : "heart")
                    .font(ChatFont.font(14))
                    .foregroundStyle(hub.state.liked.contains(track.id) ? CSSThemeVariables.accent(scope: .chat) : CSSThemeVariables.textDim(scope: .chat))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .togetherPress()
            .accessibilityLabel(hub.state.liked.contains(track.id) ? TogetherCopy.a11yUnlike : TogetherCopy.a11yLike)

            Menu {
                Button(TogetherCopy.removeFromPlaylist, role: .destructive) {
                    TogetherStore.shared.removeTrack(track.id, from: playlistId)
                    hub.refreshNow()
                }
                Button(TogetherCopy.deletePermanently, role: .destructive) {
                    deleteTrack(track)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(ChatFont.font(14))
                    .foregroundStyle(CSSThemeVariables.textDim(scope: .chat))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
        }
    }

    @ViewBuilder
    private func rowContextMenu(_ track: TogetherTrack) -> some View {
        Button {
            player.start(track, by: .user, queue: tracks.map { $0.id })
        } label: {
            Label(AppLocalized("Play", comment: "一起听 · 播放"), systemImage: "play.fill")
        }
        Button(role: .destructive) {
            TogetherStore.shared.removeTrack(track.id, from: playlistId)
            hub.refreshNow()
        } label: {
            Label(TogetherCopy.removeFromPlaylist, systemImage: "minus.circle")
        }
        Button(role: .destructive) {
            deleteTrack(track)
        } label: {
            Label(TogetherCopy.deletePermanently, systemImage: "trash")
        }
    }

    private func deleteTrack(_ track: TogetherTrack) {
        // 删音频文件不可逆，先问一句，确认后才真删。
        pendingDelete = track
        showDeleteConfirm = true
    }

    private func performDelete(_ track: TogetherTrack) {
        showDeleteConfirm = false
        pendingDelete = nil
        if player.track?.id == track.id {
            player.stop()
        }
        TogetherStore.shared.deleteTrackPermanently(track.id, by: .user)
        hub.refreshLibraryNow()
        hub.refreshNow()
    }
}

// MARK: - 加歌

struct TogetherAddSongsSheet: View {

    let playlistId: String

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var hub = TogetherStateHub.shared

    /// 这张单子只给活着的歌单加歌：歌单删了， sheet 里就直说，不再往死单子里加。
    private var playlistAlive: Bool {
        hub.state.playlists.contains { $0.id == playlistId && !$0.deleted }
    }
    private var all: [TogetherTrack] { hub.library.tracks }

    var body: some View {
        if !playlistAlive {
            VStack(spacing: 12) {
                Text(TogetherCopy.fileMissing)
                    .font(ChatFont.font(14, weight: .medium))
                    .foregroundStyle(CSSThemeVariables.textMain(scope: .chat))
                Button(TogetherCopy.cancel) { dismiss() }
                    .font(ChatFont.font(13, weight: .semibold))
                    .foregroundStyle(CSSThemeVariables.accentFg(scope: .chat))
                    .padding(.horizontal, 20)
                    .frame(minHeight: 44)
                    .background(Capsule().fill(CSSThemeVariables.accent(scope: .chat)))
                    .togetherPress()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
        VStack(alignment: .leading, spacing: 0) {
            Text(TogetherCopy.addSongs)
                .font(ChatFont.font(16, weight: .semibold))
                .foregroundStyle(CSSThemeVariables.textMain(scope: .chat))
                .padding(.horizontal, 22)
                .padding(.top, 20)
                .padding(.bottom, 12)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(all) { track in
                        Button {
                            TogetherHaptics.select()
                            TogetherStore.shared.addTrack(track.id, to: playlistId)
                            hub.refreshNow()
                        } label: {
                            HStack(spacing: 12) {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(TogetherCover.fill(track.cover))
                                    .frame(width: 36, height: 36)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(track.title)
                                        .font(ChatFont.font(13.5))
                                        .foregroundStyle(CSSThemeVariables.textMain(scope: .chat))
                                    Text(track.artist)
                                        .font(ChatFont.font(11))
                                        .foregroundStyle(CSSThemeVariables.textDim(scope: .chat))
                                }
                                Spacer()
                                Image(systemName: "plus.circle")
                                    .font(ChatFont.font(16))
                                    .foregroundStyle(CSSThemeVariables.accent(scope: .chat))
                            }
                            .padding(.horizontal, 22)
                            .padding(.vertical, 9)
                        }
                        .togetherPress()
                    }
                }
            }
        }
        }
    }
}


// MARK: - 相册选图

/// 从相册选一张，直接落到一起听的图片槽位。
/// 以前走的是文件选择器，会跳去「最近项目/文件夹」，这里改成真正的相册。
@MainActor
enum TogetherPhotoImport {

    static func data(_ item: PhotosPickerItem) async -> Data? {
        try? await item.loadTransferable(type: Data.self)
    }

    /// 落一张图到壁纸槽。失败要说清卡在哪一步，不能只甩一句通用失败。
    /// reason 留给调用方在当页再补一句，比如伴听页。
    @discardableResult
    static func toSlot(_ item: PhotosPickerItem, slot: String) async -> Bool {
        reason = nil
        guard let bytes = await data(item) else {
            return fail(AppLocalized("Couldn't read that picture from Photos",
                                     comment: "一起听 · 换壁纸失败 · 相册没给回数据"))
        }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("together-\(slot)-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: tmp) }
        do {
            try bytes.write(to: tmp)
        } catch {
            // 临时目录写不进：基本是沙盒权限或磁盘空间。
            return fail(AppLocalized("Couldn't prepare the picture",
                                     comment: "一起听 · 换壁纸失败 · 临时文件写不进") + ": " + error.localizedDescription)
        }
        guard TogetherStore.shared.setImage(slot: slot, from: tmp) != nil else {
            // 存不进 together/images：目录不可写，或图片记录没落盘。
            return fail(AppLocalized("Couldn't save the wallpaper",
                                     comment: "一起听 · 换壁纸失败 · 存不进图片目录"))
        }
        MinisToast.show(AppLocalized("Wallpaper updated", comment: "一起听 · 壁纸更新成功提示"),
                        systemImage: "checkmark.circle")
        return true
    }

    /// 上一次换壁纸失败的具体原因。
    private(set) static var reason: String?

    private static func fail(_ text: String) -> Bool {
        reason = text
        MinisToast.show(text, systemImage: "exclamationmark.circle")
        return false
    }

    @discardableResult
    static func toPlaylist(_ item: PhotosPickerItem, id: String) async -> Bool {
        guard let bytes = await data(item) else {
            MinisToast.show(TogetherCopy.importFailed, systemImage: "exclamationmark.circle")
            return false
        }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("together-playlist-\(id)-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: tmp) }
        do {
            try bytes.write(to: tmp)
            if TogetherStore.shared.setPlaylistImage(id: id, from: tmp) {
                MinisToast.show(AppLocalized("Cover updated", comment: "一起听 · 换图成功"), systemImage: "checkmark.circle")
                return true
            }
        } catch {}
        MinisToast.show(TogetherCopy.importFailed, systemImage: "exclamationmark.circle")
        return false
    }
}
