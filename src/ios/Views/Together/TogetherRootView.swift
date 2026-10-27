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
    /// 当前 tab 是不是进了子页（歌单详情这类）。进了就藏关闭键，只留返回。
    @State private var inSubpage = false

    /// 从哪个会话打开，就带哪个会话绑的人设；nil = 全局。
    var togetherPersonaId: String?

    var body: some View {
        ZStack(alignment: .bottom) {
            CSSThemeVariables.bg(scope: .chat).ignoresSafeArea()

            // 全屏壁纸只有这一层。各页自己不再各画一层——
            // 每层按自己那页的高度单独裁一遍，裁法不一样，页面底边就会接出一条缝。
            TogetherWallpaperLayer(slot: wallpaperSlot)
                .allowsHitTesting(false)
                // 壁纸换了、切了 tab，都重算一次深浅，前景色跟着换。
                .id(wallpaperSlot)

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
        .overlay(alignment: .topLeading) {
            // 一个角只留一个键：进了子页只留系统返回，顶层才留关闭一起听。
            if !inSubpage {
                closeButton
                    .transition(.opacity)
            }
        }
        .sheet(item: $showPlaylistEditor) { playlist in
            TogetherPlaylistEditor(playlist: playlist)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(CSSThemeVariables.bg(scope: .chat))
        }
        // 会话人设一路传给四个 tab 里的头像和名字。
        .environment(\.togetherPersonaId, togetherPersonaId)
        .environment(\.togetherInSubpage, $inSubpage)
        .onAppear {
            syncForegroundTone()
            // 歌词页和播放页合成一张壁纸后的一次性搬迁：
            // 老数据只在 lyrics-cover 里、now 还空着 → 复制过去，存过的图不丢。
            // 幂等：now 已有图或两边都没有时什么都不做。
            TogetherStore.shared.mergeLyricsCoverIntoNow()
        }
        .onChange(of: tab) { _ in
            syncForegroundTone()
        }
        .onReceive(NotificationCenter.default.publisher(for: TogetherImages.didSetNotification)) { _ in
            syncForegroundTone()
        }
        .onDisappear {
            // 关掉一起听立刻还原，聊天页和别的地方一个像素都不受影响。
            CSSThemeVariables.togetherVariant = nil
        }
    }

    /// 读当前壁纸的明暗，接到一起听这一页的前景变量上。
    private func syncForegroundTone() {
        CSSThemeVariables.togetherVariant = TogetherTone.variant(for: wallpaperSlot)
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
// MARK: - 子页标记
//
// 一个角只留一个键：子页里要系统返回，就不要那个关一起听的下箭头。
// 子页自己 onAppear/onDisappear 拨这个开关，根视图只读它。

struct TogetherSubpageKey: EnvironmentKey {
    static let defaultValue: Binding<Bool> = .constant(false)
}

extension EnvironmentValues {
    var togetherInSubpage: Binding<Bool> {
        get { self[TogetherSubpageKey.self] }
        set { self[TogetherSubpageKey.self] = newValue }
    }
}
