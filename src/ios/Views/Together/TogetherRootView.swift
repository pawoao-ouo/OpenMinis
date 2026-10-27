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
            .padding(.bottom, 78)

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
        // 半透之后字坐在壁纸上，给一圈局部阴影保住可读性。
        .togetherWallText()
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background(
            Rectangle()
                // 之前 0.94 几乎是一块实色板，壁纸铺到这儿被硬切掉。
                // 现在半透，壁纸从标签栏后面透出来。不加模糊：SwiftUI 的 material
                // 不是只糊这一块，会把整页背景都糊上，比透出色板更难看。
                .fill(CSSThemeVariables.card(scope: .chat).opacity(0.55))
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(CSSThemeVariables.divider(scope: .chat))
                        .frame(height: 0.5)
                }
                .ignoresSafeArea(edges: .bottom)
        )
    }
}