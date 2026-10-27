//
//  TogetherImporter.swift
//  MinisApp
//
//  一起听 · 收歌。
//
//  这就是那个"口子"：MusicImporter 协议，本地文件是第一个实现。
//  将来要接别的来源（别的 App、网盘、流媒体），加一个实现，不动核心，
//  也不抢播放权——外部只负责把文件交进来，播还是 TogetherPlayer 播。
//

import Foundation
import AVFoundation
import UniformTypeIdentifiers

protocol MusicImporter {
    var name: String { get }
    func importFiles(_ urls: [URL]) async -> [TogetherTrack]
}

/// 本地文件：她选什么就收什么，视频抽音轨。
@MainActor
final class LocalFileImporter: MusicImporter {

    let name = "local"
    private let logger = AppLogger(category: "TogetherImport")

    private static let audioExtensions: Set<String> = [
        "mp3", "m4a", "aac", "wav", "flac", "aiff", "aif", "caf", "opus", "ogg"
    ]
    private static let videoExtensions: Set<String> = ["mp4", "m4v", "mov"]

    var allowedTypes: [UTType] {
        [.audio, .movie, .mpeg4Movie, .quickTimeMovie]
    }

    /// 一次导入里没收进来的文件：名字 + 原因（给界面报用，不存盘）。
    struct Failure {
        var name: String
        var reason: String
    }

    /// 最近一次导入里没收进来的文件（名字 + 原因，给界面报用，不存盘）。
    /// importFiles 开始时清零，之后每失败一个就记一个。
    private(set) var lastFailures: [Failure] = []

    /// 失败原因：只说卡在哪一步，不甩通用失败。
    private static var reasonUnsupported: String { AppLocalized("Unsupported file type", comment: "一起听 · 导入失败原因") }
    private static var reasonSaveFailed: String { AppLocalized("Couldn't save the file", comment: "一起听 · 导入失败原因") }
    private static var reasonUnplayable: String { AppLocalized("The file couldn't be played", comment: "一起听 · 导入失败原因") }

    func importFiles(_ urls: [URL]) async -> [TogetherTrack] {
        lastFailures = []
        var added: [TogetherTrack] = []
        for url in urls {
            switch await importOne(url) {
            case .success(let track):
                added.append(track)
            case .failure(let reason):
                lastFailures.append(Failure(name: url.lastPathComponent, reason: reason))
            }
        }
        return added
    }

    /// 收一首歌：成功给 track，失败给原因（调用方记名字 + 原因，界面报）。
    private func importOne(_ url: URL) async -> Result<TogetherTrack, String> {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let ext = url.pathExtension.lowercased()
        guard Self.audioExtensions.contains(ext) || Self.videoExtensions.contains(ext) else {
            logger.error("[TogetherImport] 不支持的类型 .\(ext)")
            return .failure(Self.reasonUnsupported)
        }

        let store = TogetherStore.shared

        let baseTitle = url.deletingPathExtension().lastPathComponent
        // slug 只当可读前缀，唯一性交给 UUID：以前同名同秒导入会撞 ID，后一首把前一首的文件盖掉。
        let stem = Self.slug(baseTitle)
        let id = stem.isEmpty ? UUID().uuidString : "\(stem)-\(UUID().uuidString)"

        // 落到内置 shared/music，扩展名按真实编码来。
        guard let dest = await writeIntoLibrary(from: url, id: id) else {
            logger.error("[TogetherImport] 落地失败 \(url.lastPathComponent)")
            return .failure(Self.reasonSaveFailed)
        }
        // 落地了还得真能播：播不了的字节不进库、不占一条记录。
        // 播不了就把刚落地的碎文件清掉，别留在 music 里。
        guard await Self.isPlayable(dest) else {
            try? FileManager.default.removeItem(at: dest)
            logger.error("[TogetherImport] 落地后播不了 \(url.lastPathComponent)")
            return .failure(Self.reasonUnplayable)
        }
        let destName = dest.lastPathComponent

        let duration = await Self.duration(of: dest)
        let asset = AVURLAsset(url: url)
        let meta = (try? await asset.load(.commonMetadata)) ?? []
        let title = await Self.stringValue(meta, identifier: .commonIdentifierTitle) ?? baseTitle
        let artist = await Self.stringValue(meta, identifier: .commonIdentifierArtist) ?? ""

        // 读库、算封面位、追加、写回，全部在 store 的锁内一次做完。
        // 分成「队列外读 → 追加 → 存回」的话，两个同时导入会各拿一份旧 index 互相覆盖。
        var track = TogetherTrack(
            id: id,
            title: title,
            artist: artist,
            duration: duration,
            cover: "cover-1",
            file: "music/\(destName)",
            lyrics: nil
        )
        let saved = store.mutateLibrary { lib in
            track.cover = "cover-\(lib.tracks.count % 4 + 1)"
            lib.tracks.append(track)
        }
        guard saved else {
            logger.error("[TogetherImport] 写 index 失败 \(url.lastPathComponent)")
            return .failure(Self.reasonSaveFailed)
        }

        // 收了歌就把歌词补上：同目录同名 .lrc 优先，没有就留空（抓词走 shell）。
        if let sidecar = Self.sidecarLyrics(for: url) {
            Self.copyLyrics(sidecar, for: id, store: store)
        }
        return .success(track)
    }

    // MARK: 落地

    /// 把选中的文件放进 shared/music。
    /// mp3 原样搬；其它先试抽成 m4a；抽不出来时只有音频才原样搬（扩展名是真的），
    /// 视频抽不出来就是失败——不能把一个 .mp4 原样搬进来：
    /// reconcile 只认音频扩展名，搬进来也播不了，还占着一条"已导入"的记录。
    /// 抽音轨失败不静默：返回失败原因，调用方记失败名 + 原因、界面报。
    private func writeIntoLibrary(from source: URL, id: String) async -> URL? {
        let fm = FileManager.default
        let dir = TogetherStore.shared.musicDirectory
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let srcExt = source.pathExtension.lowercased()

        if srcExt == "mp3" {
            let dest = dir.appendingPathComponent("\(id).mp3")
            try? fm.removeItem(at: dest)
            do {
                try fm.copyItem(at: source, to: dest)
                return dest
            } catch {
                return nil
            }
        }

        let asset = AVURLAsset(url: source)
        if let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) {
            let dest = dir.appendingPathComponent("\(id).m4a")
            try? fm.removeItem(at: dest)
            session.outputURL = dest
            session.outputFileType = .m4a
            await session.export()
            if session.status == .completed, fm.fileExists(atPath: dest.path) {
                return dest
            }
        }

        guard Self.audioExtensions.contains(srcExt) else { return nil }
        let dest = dir.appendingPathComponent("\(id).\(srcExt)")
        try? fm.removeItem(at: dest)
        do {
            try fm.copyItem(at: source, to: dest)
            return dest
        } catch {
            return nil
        }
    }

    /// 这份落地文件是不是真能播。只看 AVFoundation 的判断，不猜扩展名。
    private static func isPlayable(_ url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        return (try? await asset.load(.isPlayable)) ?? false
    }

    // MARK: 元数据

    private static func duration(of url: URL) async -> Double {
        let asset = AVURLAsset(url: url)
        guard let d = try? await asset.load(.duration) else { return 0 }
        let seconds = CMTimeGetSeconds(d)
        return seconds.isFinite ? (seconds * 100).rounded() / 100 : 0
    }

    private static func stringValue(_ items: [AVMetadataItem],
                                    identifier: AVMetadataIdentifier) async -> String? {
        guard let item = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: identifier).first,
              let value = try? await item.load(.stringValue) else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: 歌词

    private static func sidecarLyrics(for audio: URL) -> URL? {
        let lrc = audio.deletingPathExtension().appendingPathExtension("lrc")
        return FileManager.default.fileExists(atPath: lrc.path) ? lrc : nil
    }

    private static func copyLyrics(_ source: URL, for id: String, store: TogetherStore) {
        let dest = store.lyricsDirectory.appendingPathComponent("\(id).lrc")
        try? FileManager.default.createDirectory(at: store.lyricsDirectory, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.copyItem(at: source, to: dest)

        // 同样走锁内改：队列外读一份、改完存回，会把并发导入刚追加的那首冲掉。
        store.mutateLibrary { lib in
            guard let i = lib.tracks.firstIndex(where: { $0.id == id }) else { return }
            lib.tracks[i].lyrics = "lyrics/\(id).lrc"
        }
    }

    // MARK: 命名

    private static func slug(_ text: String) -> String {
        let ascii = text.applyingTransform(.toLatin, reverse: false)?
            .folding(options: .diacriticInsensitive, locale: .current)
            .lowercased() ?? ""
        let allowed = ascii.unicodeScalars.map { scalar -> Character in
            let v = scalar.value
            if (48...57).contains(v) || (97...122).contains(v) { return Character(scalar) }
            return "-"
        }
        let joined = String(allowed)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        if joined.count >= 2 { return String(joined.prefix(40)) }
        // 名字里一个能转写的字符都没有（全符号 / 全表情）就返回空，
        // 由调用方直接用 UUID 当 ID。以前这里回落到秒级时间戳，同秒会撞。
        return ""
    }
}