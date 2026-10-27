//
//  TogetherRootView.swift
//  MinisApp
//
//  一起听 · 四屏容器。
//
//  底部标签栏：在听 / 歌单 / 一起 / 喜欢。
//  关掉只是收起面板，音乐不停，聊天页浮出小卡。
//

import SwiftUI

enum TogetherTab: Int, CaseIterable, Identifiable {
    case now, library, sync, liked
    var id: Int { rawValue }

    var title: String {
        switch self {
        case .now: return AppLocalized("Now", comment: "一起听 · 标签 在听")
        case .library: return AppLocalized("Playlists", comment: "一起听 · 标签 歌单")
        case .sync: return AppLocalized("Together", comment: "一起听 · 标签 一起")
        case .liked: return AppLocalized("Liked", comment: "一起听 · 标签 喜欢")
        }
    }

    var symbol: String {
        switch self {
        case .now: return "play.circle"
        case .library: return "square.stack"
        case .sync: return "person.2"
        case .liked: return "heart"
        }
    }

    var symbolFilled: String {
        switch self {
        case .now: return "play.circle.fill"
        case .library: return "square.stack.fill"
        case .sync: return "person.2.fill"
        case .liked: return "heart.fill"
        }
    }
}

struct TogetherRootView: View {

    @Environment(\.dismiss) private var dismiss
    @State private var tab: TogetherTab = .now
    @State private var showPlaylistEditor: TogetherPlaylist?

    /// 从哪个会话打开，就带哪个会话绑的人设；nil = 全局。
    var togetherPersonaId: String?

    var body: some View {
        ZStack(alignment: .bottom) {
            CSSThemeVariables.bg(scope: .chat).ignoresSafeArea()

            // 全屏壁纸铺在最底下，连标签栏后面一起铺。
            // 页面自己那层壁纸照旧，这一层只补底部和边角，避免标签栏后面露出纯色。
            TogetherWallpaperLayer(slot: wallpaperSlot)
                .allowsHitTesting(false)

            Group {
                switch tab {
                case .now:
                    TogetherPanelView()
                case .library:
                    NavigationStack { TogetherLibraryView(editing: $showPlaylistEditor) }
                case .sync:
                    TogetherSyncView()
                case .liked:
                    TogetherLikedView()
                }
            }
            .padding(.bottom, 92)

            tabBar
        }
        .overlay(alignment: .topLeading) { closeButton }
        .sheet(item: $showPlaylistEditor) { playlist in
            TogetherPlaylistEditor(playlist: playlist)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(CSSThemeVariables.bg(scope: .chat))
        }
        // 会话人设一路传给四个 tab 里的头像和名字。
        .environment(\.togetherPersonaId, togetherPersonaId)
        .onAppear {
            // 歌词页和播放页合成一张壁纸后的一次性搬迁：
            // 老数据只在 lyrics-cover 里、now 还空着 → 复制过去，存过的图不丢。
            // 幂等：now 已有图或两边都没有时什么都不做。
            TogetherStore.shared.mergeLyricsCoverIntoNow()
        }
    }

    /// 当前 tab 该铺哪张壁纸。和页面各自读的槽一致，谁都不另起一套。
    private var wallpaperSlot: String {
        switch tab {
        case .now: return TogetherImages.wallpaperNow
        case .library: return TogetherImages.wallpaperLibrary
        case .sync: return TogetherImages.wallpaperSync
        case .liked: return TogetherImages.wallpaperLiked
        }
    }

    private var closeButton: some View {
        Button { dismiss() } label: {
            Image(systemName: "chevron.down")
                .font(ChatFont.font(14, weight: .semibold))
                .foregroundStyle(CSSThemeVariables.textMain(scope: .chat))
                .frame(width: 34, height: 34)
                .background(CSSThemeVariables.optionBg(scope: .chat))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .padding(.leading, 22)
        .padding(.top, 10)
    }

    // MARK: 标签栏

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(TogetherTab.allCases) { item in
                Button {
                    withAnimation(.easeOut(duration: 0.18)) { tab = item }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: tab == item ? item.symbolFilled : item.symbol)
                            .font(ChatFont.font(17, weight: .medium))
                        Text(item.title)
                            .font(ChatFont.font(9.5, weight: .medium))
                            .tracking(0.6)
                    }
                    .foregroundStyle(
                        tab == item
                            ? CSSThemeVariables.accent(scope: .chat)
                            : CSSThemeVariables.textDim(scope: .chat).opacity(0.7)
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(height: 56)
        // 悬浮胶囊：左右留边、底部让出安全区，壁纸从胶囊四周透出来。
        // 不再画满宽实色条，也不再贴一条分界线——那都会把壁纸硬切断。
        .background(
            Capsule(style: .continuous)
                .fill(CSSThemeVariables.card(scope: .chat).opacity(0.55))
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(CSSThemeVariables.divider(scope: .chat).opacity(0.5), lineWidth: 0.5)
                )
        )
        .padding(.horizontal, 18)
        .padding(.bottom, 6)
    }
}