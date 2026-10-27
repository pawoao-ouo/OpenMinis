//
//  TogetherSkin.swift
//  MinisApp
//
//  一起听 · 文案层 + 壁纸明暗层。
//
//  结构层定死（六屏布局、坐标、动效曲线），颜色一律从 App 主题派生：
//  换 minis-theme 这一页跟着变，代码里没有裸色值。
//  曾经还有一层自己的覆盖 together/skin.json（vinylDepth 等）：
//  没有任何代码读它，shell 侧的 `together set skin.xxx` 在仓库里也没有实现——
//  调不到的配置不是配置，是藏 bug 的地方，整层删了（2026-10-27 重建）。
//  全局主题管基础色，这一层管"这一间屋子"的味道。
//

import SwiftUI
import UIKit

// MARK: - 身份
//
// 头像引用只在这里取一次。AI 走通讯录当前人设（SOUL.icon 只是镜像），
// 用户走「我自己」档案。别的地方不许再各写一套取法。

// 会话人设注入：AIChatView 打开一起听时把当前会话绑的人设带进来，
// 没带（或别处直接摞 TogetherRootView）就回落全局当前人设，行为不变。
private struct TogetherPersonaIDKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    var togetherPersonaId: String? {
        get { self[TogetherPersonaIDKey.self] }
        set { self[TogetherPersonaIDKey.self] = newValue }
    }
}

@MainActor
enum TogetherIdentity {
    /// 回答的人的头像：会话人设优先（avatar → SOUL icon），
    /// 只有会话和全局都没定才落到全局缓存图标。绝不写死。
    static func aiIcon(sessionPersonaId: String? = nil) -> String? {
        let id = SoulStore.displayPersonaId(sessionPersonaId)
        if let p = PersonaStore.shared.personas.first(where: { $0.id == id }),
           let a = p.avatar, !a.isEmpty {
            return a
        }
        return SoulStore.displayIcon(for: id) ?? SoulStore.cachedMetadata.icon
    }

    static var userIcon: String? {
        PersonaStore.shared.personas
            .first(where: { $0.id == PersonaStore.userProfilePersonaID })?
            .avatar
    }
}

// MARK: - 文案
//
// 一处集中，全部走本地化。改文案只改这里，不在六个视图里找。
// 名字永远是变量：出现人的地方用 ChatAddressing，不写死。

enum TogetherCopy {
    static var title: String { AppLocalized("Together", comment: "一起听 · 面板标题") }
    /// 空状态里的"回答的人"从调用方传进来，跟同一个会话人设。
    /// TogetherCopy 是静态的、读不到环境变量，不许在这里偷偷读全局人设名。
    @MainActor static func emptyTitle(_ aiName: String) -> String {
        String(format: AppLocalized("%@'s library is empty", comment: "一起听 · 空状态标题"), aiName)
    }
    @MainActor static func emptyHint(_ aiName: String) -> String {
        String(format: AppLocalized("Add a song, or ask %@ to add one.", comment: "一起听 · 空状态说明"), aiName)
    }
    /// 喜欢列表空了 ≠ 歌库空了,不能共用一句。
    static var likedEmpty: String { AppLocalized("Nothing liked yet", comment: "一起听 · 喜欢空态") }
    /// 单曲缺标题时的占位,与"歌库为空"不是一回事,拆开。
    static var untitledTrack: String { AppLocalized("Untitled track", comment: "一起听 · 缺标题占位") }
    static var untitledPlaylist: String { AppLocalized("Untitled", comment: "一起听 · 新歌单默认名") }
    static var newPlaylist: String { AppLocalized("New playlist", comment: "一起听 · 新建") }
    static var myPlaylists: String { AppLocalized("My playlists", comment: "一起听 · 歌单库标题") }
    static var playAll: String { AppLocalized("Play all", comment: "一起听 · 播放全部") }
    static var edit: String { AppLocalized("Edit", comment: "一起听 · 编辑") }
    static var done: String { AppLocalized("Done", comment: "一起听 · 完成") }
    static var deletePlaylist: String { AppLocalized("Delete this playlist", comment: "一起听 · 删歌单") }
    static var playlistName: String { AppLocalized("Playlist name", comment: "一起听 · 歌单名") }
    static var addSongs: String { AppLocalized("Add songs", comment: "一起听 · 加歌") }
    static var editedTogether: String { AppLocalized("edited this together", comment: "一起听 · 共同编辑") }
    static var importDone: String { AppLocalized("added", comment: "一起听 · 导入成功") }
    static var importFailed: String { AppLocalized("Couldn't read that file", comment: "一起听 · 导入失败") }
    static var handoff: String { AppLocalized("Hand the remote to", comment: "一起听 · 递遥控器") }
    static var noSongsYet: String { AppLocalized("Nothing here yet", comment: "一起听 · 空列表") }
    static var allSongs: String { AppLocalized("All songs", comment: "一起听 · 全部歌曲（目录直读）") }
    static var noLyrics: String { AppLocalized("No lyrics for this one", comment: "一起听 · 没有歌词") }
    static var noLyricsHint: String { AppLocalized("Leave a line and it will loop here", comment: "一起听 · 没歌词时的提示") }
    static var changeCover: String { AppLocalized("Change cover", comment: "一起听 · 换封面") }
    static var resetCover: String { AppLocalized("Reset cover", comment: "一起听 · 恢复默认封面") }
    static var oneLineOnly: String { AppLocalized("One line per listen — you've already left one", comment: "一起听 · 本轮已经刻过一句") }
    static var playlistInfo: String { AppLocalized("Playlist Info", comment: "一起听 · 歌单信息") }
    static var changeCoverTitle: String { AppLocalized("Change cover", comment: "一起听 · 更换封面") }
    /// 壁纸槽的按钮：换的是壁纸，不是封面，文案不许混。
    static var changeWallpaper: String { AppLocalized("Change wallpaper", comment: "一起听 · 更换壁纸") }
    static var tags: String { AppLocalized("Tags", comment: "一起听 · 标签") }
    static var noTags: String { AppLocalized("None", comment: "一起听 · 暂无") }
    static var descTitle: String { AppLocalized("Description", comment: "一起听 · 简介") }
    static var descPlaceholder: String { AppLocalized("Write a brief introduction...", comment: "一起听 · 简介占位") }
    static var removeFromPlaylist: String { AppLocalized("Remove from playlist", comment: "一起听 · 从歌单移除") }
    static var deletePermanently: String { AppLocalized("Delete file permanently", comment: "一起听 · 彻底删除") }
    /// 删歌不可逆，确认框必须把后果说清楚。
    static var deleteTrackMessage: String { AppLocalized("This permanently deletes the audio file and can't be undone.", comment: "一起听 · 删歌确认说明") }
    static var searchSongOrArtist: String { AppLocalized("Search title or artist", comment: "一起听 · 搜索歌名或歌手") }
    static var themeCenter: String { AppLocalized("Theme Center", comment: "一起听 · 装扮中心") }
    static var nowPlayingWallpaper: String { AppLocalized("Now Playing Wallpaper", comment: "一起听 · 播放页壁纸") }
    static var libraryWallpaper: String { AppLocalized("Playlist Library Wallpaper", comment: "一起听 · 歌单库壁纸") }
    static var syncWallpaper: String { AppLocalized("Together Wallpaper", comment: "一起听 · 伴听页壁纸") }
    static var likedWallpaper: String { AppLocalized("Liked Songs Wallpaper", comment: "一起听 · 喜欢页壁纸") }
    static var queueTitle: String { AppLocalized("Playing Queue", comment: "一起听 · 播放队列") }
    static var historyEchoes: String { AppLocalized("Echo Wall", comment: "一起听 · 历史回声墙") }
    // MARK: - 重建新增文案（全部走本地化，不许在视图里写死）
    static var endOfQueue: String { AppLocalized("End of the queue", comment: "一起听 · 到队尾了") }
    static var unplayableTrack: String { AppLocalized("Couldn't play this song", comment: "一起听 · 播不出来的歌") }
    static var cancel: String { AppLocalized("Cancel", comment: "一起听 · 取消") }
    static var restore: String { AppLocalized("Restore", comment: "一起听 · 恢复") }
    static var deletedPlaylists: String { AppLocalized("Deleted playlists", comment: "一起听 · 已删除的歌单") }
    static var browseSongs: String { AppLocalized("Browse songs", comment: "一起听 · 去曲库看看") }
    static var nothingPlaying: String { AppLocalized("Nothing playing", comment: "一起听 · 什么都没在放") }
    static var onlineStatus: String { AppLocalized("Online", comment: "一起听 · 在线状态") }
    static var awayStatus: String { AppLocalized("Away", comment: "一起听 · 不在状态") }
    static var fileMissing: String { AppLocalized("This song's file is missing", comment: "一起听 · 文件不见了") }
    static var queueEmptyTitle: String { AppLocalized("Queue is empty", comment: "一起听 · 队列空态") }
    static var queueEmptyHint: String { AppLocalized("Play something from a list and it will show up here.", comment: "一起听 · 队列空态说明") }
    static var libraryOrderTitle: String { AppLocalized("Library order", comment: "一起听 · 曲库顺序") }
    static var playedSection: String { AppLocalized("Played", comment: "一起听 · 已播分组") }
    static var upNextSection: String { AppLocalized("Up next", comment: "一起听 · 接下来分组") }
    static var shuffleEcho: String { AppLocalized("Shuffle", comment: "一起听 · 随机模式") }
    static var repeatAllEcho: String { AppLocalized("Repeat all", comment: "一起听 · 全部循环") }
    static var repeatOneEcho: String { AppLocalized("Repeat one", comment: "一起听 · 单曲循环") }
    static var inOrderEcho: String { AppLocalized("In order", comment: "一起听 · 顺序播放") }
    static var backToCurrent: String { AppLocalized("Back to the current line", comment: "一起听 · 回到当前歌词") }
    @MainActor static func driving(_ name: String) -> String {
        String(format: AppLocalized("%@ is driving", comment: "一起听 · 谁在掌控"), name)
    }
    static var youDriving: String { AppLocalized("You're driving", comment: "一起听 · 你在掌控") }
    @MainActor static func waitingForHandoff(_ name: String) -> String {
        String(format: AppLocalized("Waiting for %@ to take the remote…", comment: "一起听 · 等待接手遥控器"), name)
    }
    @MainActor static func remoteOffered(_ name: String) -> String {
        String(format: AppLocalized("Remote offered to %@", comment: "一起听 · 遥控器已递出"), name)
    }
    @MainActor static func importFailedCount(_ count: Int) -> String {
        String(format: AppLocalized("%d file(s) couldn't be added", comment: "一起听 · 导入部分失败"), count)
    }
    // 无障碍标签：图标按钮不能只有图形。
    static var a11yPlay: String { AppLocalized("Play", comment: "一起听 · 无障碍：播放") }
    static var a11yPause: String { AppLocalized("Pause", comment: "一起听 · 无障碍：暂停") }
    static var a11yPrevious: String { AppLocalized("Previous", comment: "一起听 · 无障碍：上一首") }
    static var a11yNext: String { AppLocalized("Next", comment: "一起听 · 无障碍：下一首") }
    static var a11yShuffle: String { AppLocalized("Shuffle", comment: "一起听 · 无障碍：随机") }
    static var a11yRepeat: String { AppLocalized("Repeat", comment: "一起听 · 无障碍：循环") }
    static var a11yQueue: String { AppLocalized("Queue", comment: "一起听 · 无障碍：队列") }
    static var a11yLike: String { AppLocalized("Like", comment: "一起听 · 无障碍：喜欢") }
    static var a11yUnlike: String { AppLocalized("Unlike", comment: "一起听 · 无障碍：取消喜欢") }
    static var leaveALine: String { AppLocalized("Leave a line at this second", comment: "一起听 · 无障碍：留一句话") }
    static var progressLabel: String { AppLocalized("Playback progress", comment: "一起听 · 无障碍：播放进度") }
}

// MARK: - 一起听：壁纸明暗 → 前景变量

/// 壁纸是深是浅，决定这一页用哪套前景变量。
/// 不看整张图的平均色——一张上亮下暗的照片，平均出来是中灰，
/// 两套字都看不清。按上/中/下三条带分别取平均色（标题、歌词、控制区
/// 各自待的地方），选"最差的那条带也读得清"的那套前景。
/// 没图就返回 nil：这时页面底就是主题底色，前景回主题那套，字和底永远成套。
/// 结果按图片实例缓存：换图才重算，tab 切换不重算。
@MainActor
enum TogetherTone {

    private static var cache: [String: (image: ObjectIdentifier, variant: AppearanceVariant?)] = [:]

    /// 当前槽位该配哪套前景。图不在返回 nil。
    static func variant(for slot: String) -> AppearanceVariant? {
        guard let url = TogetherImages.url(for: slot),
              let img = TogetherImages.cachedImage(for: url) else {
            cache.removeValue(forKey: slot)
            return nil
        }
        let key = ObjectIdentifier(img)
        if let hit = cache[slot], hit.image == key { return hit.variant }
        let result = variant(for: img)
        cache[slot] = (key, result)
        return result
    }

    /// 一张图该配哪套前景：三条带的平均色，取最差带对比度更高的那套。
    static func variant(for image: UIImage) -> AppearanceVariant? {
        let bands = bandHexes(of: image)
        guard !bands.isEmpty else { return nil }
        // 深色那套 = 浅字，浅色那套 = 深字。
        let lightText = AppearanceStudio.snapshotHex(.primaryText, scope: .chat, variant: .dark)
        let darkText = AppearanceStudio.snapshotHex(.primaryText, scope: .chat, variant: .light)
        let worstLight = bands.map { AppearanceContrast.ratio(lightText, on: $0) }.min() ?? 0
        let worstDark = bands.map { AppearanceContrast.ratio(darkText, on: $0) }.min() ?? 0
        return worstLight >= worstDark ? .dark : .light
    }

    /// 把图缩到 48×48，取上/中/下三条带的平均色（十六进制）。
    private static func bandHexes(of image: UIImage) -> [String] {
        guard let cg = image.cgImage else { return [] }
        let w = 48, h = 48
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &pixels, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return []
        }
        ctx.interpolationQuality = .low
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var hexes: [String] = []
        for band in 0..<3 {
            let y0 = band * h / 3, y1 = (band + 1) * h / 3
            var r = 0, g = 0, b = 0, count = 0
            for y in y0..<y1 {
                for x in 0..<w {
                    let i = (y * w + x) * 4
                    r += Int(pixels[i]); g += Int(pixels[i + 1]); b += Int(pixels[i + 2])
                    count += 1
                }
            }
            guard count > 0 else { continue }
            hexes.append(String(format: "#%02X%02X%02X", r / count, g / count, b / count))
        }
        return hexes
    }
}


extension View {
    /// 一起听图标：实心变体 + 变量层定的字重、尺寸、前景色。
    /// 图标自己不许再写死 font 和 foregroundStyle。
    func togetherIcon(_ base: CGFloat, dim: Bool = true) -> some View {
        self
            .symbolVariant(.fill)
            .font(ChatFont.font(base * CSSThemeVariables.togetherIconScale,
                                weight: CSSThemeVariables.togetherIconWeight))
            .foregroundStyle(dim ? CSSThemeVariables.textDim(scope: .chat)
                                 : CSSThemeVariables.textMain(scope: .chat))
    }
}
