//
//  TogetherStore.swift
//  MinisApp
//
//  一起听 · 状态读写。
//
//  只有一份文件：<root>/state.json。面板、App、我（shell）写的是同一份。
//  写盘协议（App 侧）：state.json 和 index.json 共用 <root>/.lock 的
//  flock(LOCK_EX)；锁内读 → 改 → 写前 revision/字节比对 → 原子替换；
//  revision 单调递增。比对失败重算、3 次撞上放弃，绝不静默覆盖。
//  shell 侧（不在这个仓库里）是否守同一把锁、写盘是否 bump revision，
//  无法验证：不守规矩的写者只能靠比对发现，revision 不动的内容改动
//  发现不了——这是已知残余风险，不是已修复。
//
//  路径只有一套，和内置音乐目录共用：
//    音乐    /var/minis/shared/music     ← apple-player 播的就是这里
//    元数据  /var/minis/shared/together/state.json
//
//  App 侧真源是 AIChatViewModel.minisSharedPersistentDir：iSH 里 /var/minis/shared
//  就是它的 bind-mount。所以不用自己造路径，也不用往 meta.db 登记——写进去
//  shell 就看得见，Files app 也看得见。
//

import Foundation
import UIKit
import Darwin

private let togetherLogger = AppLogger(category: "Together")

// MARK: - 谁在改

enum TogetherActor: String {
    case user
    case ai
}

// MARK: - Store

final class TogetherStore {

    static let shared = TogetherStore()

    /// 事件流上限。面板活了很久也不会把文件撑爆。
    static let eventCap = 500
    /// 留言上限。
    static let noteCap = 400
    /// 听歌历史上限。无上限的历史会让每次读文件越来越贵。
    static let historyCap = 200
    /// 单句循环上限。字典无序，超了就按 key 排序丢最前面的。
    static let loopLineCap = 200

    private let queue = DispatchQueue(label: "com.openminis.together.store")

    private init() {
        _ = ensureDirectories()
    }

    // MARK: 路径
    //
    // 一套系统，不是两套。
    //
    // 音乐放内置的 /var/minis/shared/music。App 侧就是 minisSharedPersistentDir/music
    // （AppGroup 的 MinisFileProvider/shared/music；没 AppGroup 时回退
    // Application Support/OpenMinisClone/MinisFileProvider/shared/music）。
    // 这正是 iSH 里 /var/minis/shared 的 bind-mount 真源，也是 apple-player
    // 和 Files app 看到的那一批文件——不造第二条路径，也不登记 meta.db。

    /// 共享根。App 侧就是 /var/minis/shared 的真源。
    static var sharedRootURL: URL {
        AIChatViewModel.minisSharedPersistentDir
    }

    /// 用哪个目录。面板空状态会把这一行显示出来，路径错了要一眼看得见。
    private(set) var rootDecision: String = "未解析"

    /// 一起听的元数据目录：shared/together。
    lazy var rootURL: URL = {
        let url = Self.sharedRootURL.appendingPathComponent("together", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        rootDecision = "shared/music · shared/together"
        return url
    }()

    var stateURL: URL { rootURL.appendingPathComponent("state.json") }
    /// 音乐目录就是内置那个，apple-player 播的是同一批文件。
    var musicDirectory: URL { Self.sharedRootURL.appendingPathComponent("music", isDirectory: true) }
    var libraryURL: URL { rootURL.appendingPathComponent("index.json") }
    var lyricsDirectory: URL { rootURL.appendingPathComponent("lyrics", isDirectory: true) }

    /// 音频按 shared 根解析：`music/x.mp3` → `/var/minis/shared/music/x.mp3`。
    func audioURL(for track: TogetherTrack) -> URL? {
        guard let rel = track.file, !rel.isEmpty else { return nil }
        return Self.sharedRootURL.appendingPathComponent(rel)
    }

    static let audioExtensions: Set<String> = [
        "mp3", "m4a", "aac", "wav", "flac", "aiff", "aif", "caf", "opus", "ogg"
    ]

    @discardableResult
    func ensureDirectories() -> Bool {
        let fm = FileManager.default
        var ok = true
        for dir in [rootURL, musicDirectory, lyricsDirectory] {
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            } catch {
                togetherLogger.error("[Together] 建目录失败 \(dir.path)：\(error.localizedDescription)")
                ok = false
            }
        }
        return ok
    }

    // MARK: 读

    func load() -> TogetherState {
        queue.sync { loadLocked() }
    }

    /// 只读 revision：轮询判断"变了没有"用，不解码整份状态。
    /// 文件不在或读不出数字返回 nil，调用方当"变了"处理、走全量重读。
    func peekRevision() -> Int? {
        queue.sync {
            guard let data = try? Data(contentsOf: stateURL),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rev = obj["revision"] as? Int else { return nil }
            return rev
        }
    }

    /// 曲库以目录为准：shared/music 里有什么音频就有什么歌。
    /// index.json 只当元数据缓存（标题/歌手/时长/歌词），目录里新出现的自动补进来。
    func library() -> TogetherLibrary {
        queue.sync {
            guard let fd = acquireFileLock() else {
                togetherLogger.error("[Together] 拿不到文件锁，曲库只读不写")
                return loadLibraryLocked()
            }
            defer { flock(fd, LOCK_UN); close(fd) }
            for _ in 0..<2 {
                let before = Self.fileBytes(at: libraryURL)
                var lib = loadLibraryLocked()
                if reconcileLibraryLocked(&lib) {
                    guard Self.fileBytes(at: libraryURL) == before else { continue }
                    _ = saveLibraryLocked(lib)
                }
                return lib
            }
            return loadLibraryLocked()
        }
    }

    /// 播到某句时的歌词。没有歌词文件返回 nil，面板显示歌名。
    /// `.lrc` 按通用格式解析（抓来的都是这种），`.json` 走解码。
    func lyrics(for track: TogetherTrack) -> TogetherLyrics? {
        guard let rel = track.lyrics, !rel.isEmpty else { return nil }
        let url = rootURL.appendingPathComponent(rel)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        if url.pathExtension.lowercased() == "lrc" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            let parsed = TogetherLyrics.parseLRC(text, trackId: track.id)
            return parsed.lines.isEmpty ? nil : parsed
        }
        return Self.decode(TogetherLyrics.self, at: url)
    }

    private func loadLocked() -> TogetherState {
        guard FileManager.default.fileExists(atPath: stateURL.path) else {
            return TogetherState()
        }
        guard let state = Self.decode(TogetherState.self, at: stateURL) else {
            // 坏文件：备份原件，立刻落一份默认值。
            // 不能让 state.json 处在"不存在"的状态，另一头读的人会以为数据没了。
            let stamp = Int(Date().timeIntervalSince1970)
            let backup = stateURL.appendingPathExtension("corrupt.\(stamp)")
            try? FileManager.default.moveItem(at: stateURL, to: backup)
            togetherLogger.error("[Together] state.json 坏了，已备份到 \(backup.lastPathComponent)")
            let fresh = TogetherState()
            writeLocked(fresh)
            return fresh
        }
        return state
    }

    @discardableResult
    func saveLibrary(_ library: TogetherLibrary) -> Bool {
        queue.sync {
            // 直接整库写回：没有"读 → 改"可重算，比对无从做起，只能靠锁。
            // 调用方应优先走 mutateLibrary；这个入口只留给整库替换。
            guard let fd = acquireFileLock() else { return false }
            defer { flock(fd, LOCK_UN); close(fd) }
            return saveLibraryLocked(library)
        }
    }

    /// 在锁内「读库 → 改 → 写回」一次做完。
    /// 导入如果在队列外先读、再追加、再存回，两个同时导入会各拿一份旧库互相覆盖，丢一首。
    /// 追加动作走这里。
    @discardableResult
    func mutateLibrary(_ body: (inout TogetherLibrary) -> Void) -> Bool {
        queue.sync {
            guard let fd = acquireFileLock() else { return false }
            defer { flock(fd, LOCK_UN); close(fd) }
            for _ in 0..<3 {
                let before = Self.fileBytes(at: libraryURL)
                var lib = loadLibraryLocked()
                body(&lib)
                guard Self.fileBytes(at: libraryURL) == before else {
                    togetherLogger.info("[Together] 写 index 之前库被别人改过，重算一遍")
                    continue
                }
                return saveLibraryLocked(lib)
            }
            togetherLogger.error("[Together] index.json 写盘重试 3 次仍撞上别人，放弃这次写")
            return false
        }
    }

    /// 调用方必须已持有文件锁（见 acquireFileLock），且在同一串行队列里。
    @discardableResult
    private func saveLibraryLocked(_ library: TogetherLibrary) -> Bool {
        try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        // 按 id 去重：写前比对失败重算 body 时，追加类 body 会跑两遍，
        // 同一条歌不能在库里出现两次。保留第一次出现的顺序和内容。
        var seen: Set<String> = []
        var deduped = library
        deduped.tracks = library.tracks.filter { seen.insert($0.id).inserted }
        return Self.encode(deduped, to: libraryURL)
    }

    private func loadLibraryLocked() -> TogetherLibrary {
        guard FileManager.default.fileExists(atPath: libraryURL.path) else {
            return TogetherLibrary()
        }
        return Self.decode(TogetherLibrary.self, at: libraryURL) ?? TogetherLibrary()
    }

    /// 扫一遍音乐目录，把目录里有、index 里没有的歌补进来。
    /// 返回是否改动过（改动才回写，别每次读库都写盘）。
    private func reconcileLibraryLocked(_ lib: inout TogetherLibrary) -> Bool {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: musicDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return false }

        var known = Set(lib.tracks.compactMap { $0.file })
        var changed = false

        for url in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard Self.audioExtensions.contains(url.pathExtension.lowercased()) else { continue }
            let rel = "music/\(url.lastPathComponent)"
            guard !known.contains(rel) else { continue }

            let base = url.deletingPathExtension().lastPathComponent
            let (title, artist) = Self.splitDisplayName(base)
            let id = Self.stableTrackID(rel)
            var lyrics: String?
            if let lrc = Self.sidecarLRC(beside: url), copyLyricsFile(lrc, id: id) {
                lyrics = "lyrics/\(id).lrc"
            }

            lib.tracks.append(TogetherTrack(
                id: id,
                title: title,
                artist: artist,
                duration: 0,
                cover: nil,
                file: rel,
                lyrics: lyrics
            ))
            known.insert(rel)
            changed = true
        }

        // 文件被删了/改名了，index 里那条也别留着当幽灵。
        let before = lib.tracks.count
        var deadTrackIds = Set<String>()
        lib.tracks.removeAll { track in
            guard let f = track.file, f.hasPrefix("music/") else { return false }
            let exists = fm.fileExists(atPath: Self.sharedRootURL.appendingPathComponent(f).path)
            if !exists { deadTrackIds.insert(track.id) }
            return !exists
        }
        if lib.tracks.count != before { changed = true }

        // 级联清理：如果磁盘文件被删了，歌单和喜欢列表里的孤儿ID必须连根拔除
        if !deadTrackIds.isEmpty {
            DispatchQueue.main.async { [weak self] in
                self?.cleanupOrphanTracks(deadTrackIds)
            }
        }

        return changed
    }

    /// 把旁挂的 .lrc 收进 lyrics/。已经收过就当作成功。
    private func copyLyricsFile(_ source: URL, id: String) -> Bool {
        let fm = FileManager.default
        try? fm.createDirectory(at: lyricsDirectory, withIntermediateDirectories: true)
        let dest = lyricsDirectory.appendingPathComponent("\(id).lrc")
        if fm.fileExists(atPath: dest.path) { return true }
        do {
            try fm.copyItem(at: source, to: dest)
            return true
        } catch {
            return false
        }
    }

    /// 播放器学到真实时长后回填一次，列表不用一直显示 0:00。
    func updateDuration(trackId: String, duration: Double) {
        guard duration.isFinite, duration > 0 else { return }
        queue.sync {
            guard let fd = acquireFileLock() else { return }
            defer { flock(fd, LOCK_UN); close(fd) }
            for _ in 0..<3 {
                let before = Self.fileBytes(at: libraryURL)
                var lib = loadLibraryLocked()
                guard let i = lib.tracks.firstIndex(where: { $0.id == trackId }) else { return }
                if abs(lib.tracks[i].duration - duration) < 0.5 { return }
                lib.tracks[i].duration = (duration * 100).rounded() / 100
                guard Self.fileBytes(at: libraryURL) == before else { continue }
                _ = saveLibraryLocked(lib)
                return
            }
        }
    }

    /// "再等冬天 - h3R3" → 标题 + 歌手。
    static func splitDisplayName(_ raw: String) -> (String, String) {
        for sep in [" - ", " – ", " — "] {
            if let r = raw.range(of: sep) {
                let title = String(raw[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
                let artist = String(raw[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !title.isEmpty { return (title, artist) }
            }
        }
        return (raw.trimmingCharacters(in: .whitespaces), "")
    }

    /// 稳定的 id：同一个文件每次算出同一个，跟中文/拼音无关。
    static func stableTrackID(_ relativePath: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in relativePath.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return "t_" + String(hash, radix: 36)
    }

    static func sidecarLRC(beside audio: URL) -> URL? {
        let lrc = audio.deletingPathExtension().appendingPathExtension("lrc")
        return FileManager.default.fileExists(atPath: lrc.path) ? lrc : nil
    }

    // MARK: 写

    /// 改一次状态。闭包里改 `state`，出来时自动 revision +1、追加事件、原子落盘。
    /// 返回写入后的状态；拿不到锁或写失败返回 nil。
    @discardableResult
    func mutate(by actor: TogetherActor,
                event: String,
                detail: TogetherEventDetail? = nil,
                _ body: (inout TogetherState) -> Void) -> TogetherState? {
        mutateOrReject(by: actor, event: event, detail: detail) { state in
            body(&state)
            return true
        }
    }

    /// 和 `mutate` 同一把锁，但闭包可以拒写：返回 false 就一个字都不落盘。
    /// 「判完就得立刻占住」的规矩（比如一轮一句的刻字名额）必须判在这里——
    /// 判在锁外面，两个同时进来会都通过。
    /// 写前比对（CAS）：body 算完、落盘之前再读一次 revision。拿锁的写者
    /// 不可能插进来；不拿锁的写者一旦插进来 revision 必然变了——重算 body，
    /// 而不是盖掉它的字段。3 次都撞上就放弃这次写（返回 nil），绝不静默覆盖。
    /// body 会被重算：所有 body 必须是纯状态改动（已核过调用方），不能带文件 I/O。
    /// 协议要求写盘方必须 bump revision：revision 不动却改了内容的写，这里
    /// 发现不了——shell 侧不在仓库里，无法验证，残余风险，见文件头。
    @discardableResult
    func mutateOrReject(by actor: TogetherActor,
                        event: String,
                        detail: TogetherEventDetail? = nil,
                        _ body: (inout TogetherState) -> Bool) -> TogetherState? {
        queue.sync {
            guard let fd = acquireFileLock() else { return nil }
            defer { flock(fd, LOCK_UN); close(fd) }

            for _ in 0..<3 {
                var state = loadLocked()
                let before = state.revision
                guard body(&state) else {
                    togetherLogger.info("[Together] \(event) 被拒：写盘前再判没通过")
                    return nil
                }
                guard loadLocked().revision == before else {
                    togetherLogger.info("[Together] 写盘前 revision 变了，重算一遍")
                    continue
                }

                state.revision = max(before + 1, state.revision + 1)
                state.updatedAt = Self.now()

                if !event.isEmpty {
                    state.events.append(TogetherEvent(
                        id: "e_\(Self.now())_\(state.revision)",
                        type: event,
                        by: actor.rawValue,
                        ts: Self.now(),
                        detail: detail
                    ))
                    if state.events.count > TogetherStore.eventCap {
                        state.events = Array(state.events.suffix(TogetherStore.eventCap))
                    }
                }
                if state.notes.count > TogetherStore.noteCap {
                    state.notes = Array(state.notes.suffix(TogetherStore.noteCap))
                }
                if state.me.history.count > TogetherStore.historyCap {
                    state.me.history = Array(state.me.history.suffix(TogetherStore.historyCap))
                }
                if state.loopLines.count > TogetherStore.loopLineCap {
                    let keep = state.loopLines.keys.sorted().suffix(TogetherStore.loopLineCap)
                    state.loopLines = Dictionary(uniqueKeysWithValues: keep.map { ($0, state.loopLines[$0]!) })
                }

                guard writeLocked(state) else { return nil }
                // 一次有意义的写：让 Hub 立刻重读，不等轮询。进度回写不走这里，
                // 所以播歌时不会每 3 秒把所有视图都叫醒。
                NotificationCenter.default.post(name: .togetherStateDidChange, object: nil)
                return state
            }
            togetherLogger.error("[Together] state.json 写盘重试 3 次仍撞上别人，放弃这次写")
            return nil
        }
    }

    private func openLockFile() -> Int32 {
        let path = rootURL.appendingPathComponent(".lock").path
        return open(path, O_CREAT | O_RDWR, 0o644)
    }

    /// 拿住 state.json / index.json 共用的那把文件锁。
    /// 两份文件共用一把锁：写 state 的同时另一头写 index 也会被挡住，
    /// 两份文件之间不会互相踩。返回 fd，调用方负责 flock(LOCK_UN) + close。
    /// 锁只防守规矩的写者；不拿锁的写者靠写前比对发现（见 mutateOrReject）。
    private func acquireFileLock() -> Int32? {
        let fd = openLockFile()
        guard fd >= 0 else {
            togetherLogger.error("[Together] 打不开锁文件")
            return nil
        }
        guard flock(fd, LOCK_EX) == 0 else {
            togetherLogger.error("[Together] 拿不到锁")
            close(fd)
            return nil
        }
        return fd
    }

    /// index.json 写盘前的原始字节：写之前比对，另一头不拿锁改了库就重算。
    private static func fileBytes(at url: URL) -> Data? {
        try? Data(contentsOf: url)
    }

    @discardableResult
    private func writeLocked(_ state: TogetherState) -> Bool {
        // shared/ 是系统 bind-mount，直接写就是 shell 能看见的那份，不用登记 meta.db。
        Self.encode(state, to: stateURL)
    }

    static func encode<T: Encodable>(_ value: T, to url: URL) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        do {
            let data = try encoder.encode(value)
            return atomicWrite(data, to: url)
        } catch {
            togetherLogger.error("[Together] 编码失败 \(url.lastPathComponent)：\(error.localizedDescription)")
            return false
        }
    }

    /// 写临时文件 → fsync → 原子替换。中途被杀不会留下半个 JSON。
    static func atomicWrite(_ data: Data, to url: URL) -> Bool {
        do {
            // .atomic 内部就是"写临时文件再 rename"，中途被杀不会留下半个 JSON。
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            togetherLogger.error("[Together] 写盘失败 \(url.lastPathComponent)：\(error.localizedDescription)")
            return false
        }
    }

    static func decode<T: Decodable>(_ type: T.Type, at url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            togetherLogger.error("[Together] 解析失败 \(url.lastPathComponent)：\(error.localizedDescription)")
            return nil
        }
    }

    static func now() -> Int { Int(Date().timeIntervalSince1970) }

    static func today() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Date())
    }
}

// MARK: - 场景动作
//
// 面板和我都要做的那几件事，写在一处，别各写一套。

extension TogetherStore {

    /// 她或者我按了播放。
    /// 所有"点歌/切歌/播完接歌"最后都落在这里：先验文件在不在，
    /// 不在就一个字都不写（上一首接着响），只报一声错。
    /// queue 传了就用传的那个列表；传空数组 = 明确清掉；没传 = 保持原样——
    /// 谁按播放都不许顺手把对方的队列清掉。
    func play(trackId: String, at position: Double = 0, by actor: TogetherActor,
              queue: [String]? = nil) {
        guard let track = library().track(id: trackId) else {
            togetherLogger.error("[Together] 曲库里没有 \(trackId)")
            return
        }
        guard let url = audioURL(for: track),
              FileManager.default.fileExists(atPath: url.path) else {
            togetherLogger.error("[Together] 音频文件不在，没换歌：\(trackId)")
            MinisToast.show(TogetherCopy.importFailed, systemImage: "exclamationmark.triangle.fill")
            return
        }
        beginListenIfNeeded(trackId: trackId)
        // 从哪个列表点进来的，就把那个列表当队列；没给就保持原样。
        mutate(by: actor, event: "play",
               detail: TogetherEventDetail(trackId: trackId, position: position)) { state in
            state.track = track
            state.playback.position = position
            state.playback.playing = true
            state.playback.by = actor.rawValue
            state.playback.updatedAt = TogetherStore.now()
            if let q = queue {
                state.playback.queue = q
            }
            state.me.presence.listening = true
            state.me.presence.updatedAt = TogetherStore.now()
            // 按播放键是真活动：刷新按下这一方的 lastSeen。另一方不动——
            // 以前这里无条件把 ai.online 写成 true，按钮按出来的"在线"不算数。
            switch actor {
            case .user:
                state.devices.user.online = true
                state.devices.user.lastSeen = TogetherStore.now()
            case .ai:
                state.devices.ai.online = true
                state.devices.ai.lastSeen = TogetherStore.now()
            }
        }
    }

    /// 播放/暂停。heldPause 只在调用方明确知道时传：她攥住的暂停要落盘；
    /// 来电打断的暂停也要落盘攥住（通话中杀进程重开不能自己响），
    /// 打断结束恢复时由打断处理自己清掉。耳机拔掉的暂停不攥——
    /// 插回去从不自动恢复，文件里"停着"就够了。
    func setPlaying(_ playing: Bool, by actor: TogetherActor, heldPause: Bool? = nil) {
        mutate(by: actor, event: playing ? "resume" : "pause") { state in
            state.playback.playing = playing
            state.playback.by = actor.rawValue
            state.playback.updatedAt = TogetherStore.now()
            if let held = heldPause { state.playback.heldPause = held }
        }
    }

    /// 拖进度条。她拖的时候记一条 seek 事件，我能看见她跳到了哪。
    /// seek 是导航，不是夺遥控：不碰 playback.by，只刷新拖动这一方的 lastSeen。
    func seek(to position: Double, by actor: TogetherActor) {
        let clamped = max(0, position)
        mutate(by: actor, event: "seek",
               detail: TogetherEventDetail(position: clamped)) { state in
            state.playback.position = clamped
            state.playback.updatedAt = TogetherStore.now()
            switch actor {
            case .user: state.devices.user.lastSeen = TogetherStore.now()
            case .ai: state.devices.ai.lastSeen = TogetherStore.now()
            }
        }
    }

    /// 播放进度回写。这个不进事件流——每秒一条会把文件淹了。
    /// 只写 position / updatedAt，不碰 playback.by，不动 revision、不发通知：
    /// 遥控器在谁手里是"谁点了遥控"决定的，不是"谁的进度在跑"；
    /// 进度只是播放器自己的事，没必要把所有视图叫醒重读。
    /// 写前比对 revision：另一头改了文件就把进度重贴到新状态上再写，
    /// 绝不拿旧状态整份盖回去；3 次都撞上就丢掉这一笔（下一笔还会来）。
    func reportProgress(position: Double) {
        queue.sync {
            guard let fd = acquireFileLock() else { return }
            defer { flock(fd, LOCK_UN); close(fd) }
            for _ in 0..<3 {
                let state = loadLocked()
                let before = state.revision
                var updated = state
                updated.playback.position = position
                updated.playback.updatedAt = TogetherStore.now()
                guard loadLocked().revision == before else { continue }
                _ = writeLocked(updated)
                return
            }
            togetherLogger.info("[Together] 进度回写撞上别人的写，丢掉这一笔")
        }
    }

    /// 某一方真的在场活动过（打开面板、点播放）：刷新它的 lastSeen。
    /// 按钮本身不许把 online 按成 true——在场是量出来的。
    func markSeen(by actor: TogetherActor) {
        mutate(by: actor, event: "") { state in
            switch actor {
            case .user:
                state.devices.user.online = true
                state.devices.user.lastSeen = TogetherStore.now()
            case .ai:
                state.devices.ai.online = true
                state.devices.ai.lastSeen = TogetherStore.now()
            }
        }
    }

    /// 被压住的 AI 动作要上报、不能静默吃掉：记一条 type == "suppressed" 的事件，
    /// 带着原来那条的类型、原因、目标和时间戳，shell 那边能读到"这一下被压住了"。
    /// 上报事件本身在回放里只挪游标（见 followState），不会再被上报一次。
    func reportSuppressed(original: TogetherEvent, reason: String) {
        mutate(by: .ai, event: "suppressed",
               detail: TogetherEventDetail(
                trackId: original.detail?.trackId,
                position: original.detail?.position,
                count: original.ts,
                text: original.type,
                suppressedType: original.type,
                suppressedReason: reason
               )) { _ in }
    }

    /// 遥控器递交：只记一个 pending，不动 playback.by。
    /// 旧持有人继续说了算，直到对方接手或超时落定。
    @discardableResult
    func requestHandoff(to: String, by actor: TogetherActor) -> Bool {
        let current = load().playback.by
        guard let from = current, !from.isEmpty, from != to else {
            // 已经在对方手里，或根本没人持：不用递。
            return false
        }
        return mutateOrReject(by: actor, event: "handoff.request",
                            detail: TogetherEventDetail(text: to)) { state in
            guard state.pendingHandoff == nil else { return false }
            state.pendingHandoff = TogetherPendingHandoff(
                to: to, from: from,
                requestedAt: TogetherStore.now(), requestedBy: actor.rawValue
            )
            return true
        } != nil
    }

    /// 递交落定：遥控器正式到对方手里，pending 清掉。
    @discardableResult
    /// 接手递交：把 playback.by 交给 pending.to。requestedAt 传了就只认那一笔，
    /// 新的一笔顶上来时，旧的超时落定不许错手接走新递交。
    func acceptHandoff(requestedAt: Int? = nil) -> Bool {
        guard let pending = load().pendingHandoff, !pending.to.isEmpty else { return false }
        return mutateOrReject(by: pending.requestedBy == TogetherActor.ai.rawValue ? .ai : .user,
                              event: "handoff.accept",
                              detail: TogetherEventDetail(text: pending.to)) { state in
            guard let p = state.pendingHandoff,
                  requestedAt == nil || p.requestedAt == requestedAt else { return false }
            state.playback.by = p.to
            state.playback.updatedAt = TogetherStore.now()
            state.pendingHandoff = nil
            return true
        } != nil
    }

    /// 递给她的遥控器超时没人接：递交作废，控制权原地不动。
    /// 绝不替她接手——她没按"接过遥控器"，遥控器就还在原来那个人手里。
    /// requestedAt 对不上（已经是新的一笔）就不动。记一条 handoff.expired，
    /// AI 那边能看见这笔递交是过期作废、不是被谁接走了。
    @discardableResult
    func expireHandoff(requestedAt: Int) -> Bool {
        mutate(by: .ai, event: "handoff.expired") { state in
            guard let p = state.pendingHandoff,
                  p.requestedAt == requestedAt, p.to == "user" else { return false }
            state.pendingHandoff = nil
            return true
        } != nil
    }

    /// 取消还没落定的递交。
    func cancelHandoff(by actor: TogetherActor) {
        mutate(by: actor, event: "handoff.cancel") { state in
            state.pendingHandoff = nil
        }
    }

    func toggleLike(trackId: String, by actor: TogetherActor) {
        mutate(by: actor, event: "like",
               detail: TogetherEventDetail(trackId: trackId)) { state in
            if let idx = state.liked.firstIndex(of: trackId) {
                state.liked.remove(at: idx)
            } else {
                state.liked.append(trackId)
            }
        }
    }

    /// 我在某一秒留一句话。
    @discardableResult
    func addNote(at second: Double, text: String, by actor: TogetherActor, trackId: String? = nil) -> Bool {
        guard let target = trackId ?? load().track?.id, !target.isEmpty else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        // 一轮只听一首，一轮里她和我各只能刻一句。
        // 外面这次只是给调用方早退用的；真正的名额在写盘闭包里再判一次。
        guard canStamp(by: actor, trackId: target) else {
            togetherLogger.info("[Together] 这一轮 \(actor.rawValue) 已经刻过了")
            return false
        }
        return mutateOrReject(by: actor, event: "note",
                      detail: TogetherEventDetail(trackId: target, position: second)) { state in
            // 拿锁之后再判一次：两句同时刻进来，先落盘的把名额占掉，后那句直接拒写。
            if state.listen.trackId == target, state.listen.spoke(actor) {
                togetherLogger.info("[Together] 这一轮 \(actor.rawValue) 的名额被占了")
                return false
            }
            state.notes.append(TogetherNote(
                id: "n_\(TogetherStore.now())_\(state.revision + 1)",
                trackId: target,
                at: second,
                from: actor.rawValue,
                text: trimmed,
                ts: TogetherStore.now()
            ))
            if state.listen.trackId == target {
                if actor == .user { state.listen.userSpoke = true }
                else { state.listen.aiSpoke = true }
            }
            return true
        } != nil
    }

    /// 我推一首。理由必须留下，否则下一回合我就不记得为什么推它。
    /// 推歌不许清队列：她正在听的列表留着，推的这首插进来播，听完还回得去。
    @discardableResult
    func radio(trackId: String, why: String) -> Bool {
        guard let track = library().track(id: trackId) else { return false }
        guard let url = audioURL(for: track),
              FileManager.default.fileExists(atPath: url.path) else {
            togetherLogger.error("[Together] 推的歌没有音频文件，没换歌：\(trackId)")
            return false
        }
        return mutate(by: .ai, event: "radio",
                      detail: TogetherEventDetail(trackId: trackId, text: why)) { state in
            state.track = track
            state.playback.position = 0
            state.playback.playing = true
            state.playback.by = TogetherActor.ai.rawValue
            state.playback.updatedAt = TogetherStore.now()
            state.devices.ai.online = true
            state.devices.ai.lastSeen = TogetherStore.now()
            state.me.presence.listening = true
            state.me.presence.updatedAt = TogetherStore.now()
            state.me.history.append(TogetherHistoryItem(
                id: "h_\(TogetherStore.now())",
                trackId: trackId,
                why: why,
                ts: TogetherStore.now()
            ))
        } != nil
    }

    /// 没歌词的歌，我写一句放进去循环。她也能改。
    func setLoopLine(trackId: String, text: String, by actor: TogetherActor = .ai) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        mutate(by: actor, event: "loopline", detail: TogetherEventDetail(trackId: trackId, text: trimmed)) { state in
            if trimmed.isEmpty {
                state.loopLines.removeValue(forKey: trackId)
            } else {
                state.loopLines[trackId] = trimmed
            }
        }
    }

    func setMood(_ word: String, intensity: Int = 3) {
        let clamped = min(5, max(1, intensity))
        mutate(by: .ai, event: "mood") { state in
            state.me.presence.mood = TogetherMood(word: word, intensity: clamped)
            state.me.presence.updatedAt = TogetherStore.now()
        }
    }

    /// 今天还能不能开口。一天三句封顶。
    func canSpeakToday() -> Bool {
        let state = load()
        guard state.me.spokenDay == TogetherStore.today() else { return true }
        return state.me.spokenToday < 3
    }

    /// 我说话。她那边看到的是留在当前这一秒的一句。
    /// 名额（一天三句 + 一轮一句）全在写盘锁里再判一次：判在锁外面，
    /// 两个同时进来会都通过；没歌可留时一句都不消耗。
    @discardableResult
    func speak(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard canSpeakToday() else {
            togetherLogger.info("[Together] 今天三句已满，不开口")
            return false
        }
        let day = TogetherStore.today()
        // 没歌时不开口：以前这条路也会先把三句名额吃掉一句。
        guard let trackId = load().track?.id, !trackId.isEmpty else { return false }
        return mutateOrReject(by: .ai, event: "reply",
                              detail: TogetherEventDetail(text: trimmed)) { state in
            if state.me.spokenDay != day {
                state.me.spokenDay = day
                state.me.spokenToday = 0
            }
            guard state.me.spokenToday < 3 else { return false }
            // 一轮一句：这轮已经刻过，就不开口。
            if state.listen.trackId == trackId, state.listen.aiSpoke { return false }
            state.me.spokenToday += 1
            state.me.lastSpokeAt = TogetherStore.now()
            if state.listen.trackId == trackId { state.listen.aiSpoke = true }
            state.notes.append(TogetherNote(
                id: "n_\(TogetherStore.now())_\(state.revision + 1)",
                trackId: trackId,
                at: state.playback.position,
                from: TogetherActor.ai.rawValue,
                text: trimmed,
                ts: TogetherStore.now()
            ))
            return true
        } != nil
    }
}
// MARK: - 歌单

extension TogetherStore {

    @discardableResult
    func createPlaylist(name: String, by actor: TogetherActor = .user) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmed.isEmpty ? TogetherCopy.untitledPlaylist : trimmed
        // 秒级时间戳会同秒撞车，两首歌盖成一首。ID 改成 UUID，名字里的 slug 只当可读前缀。
        let id = "p_\(UUID().uuidString)"
        let ok = mutate(by: actor, event: "playlist.new",
                        detail: TogetherEventDetail(text: finalName)) { state in
            state.playlists.append(TogetherPlaylist(
                id: id, name: finalName, bg: "cover-1", tracks: [],
                updatedBy: actor.rawValue, ts: TogetherStore.now()
            ))
        }
        return ok != nil ? id : nil
    }

    func renamePlaylist(id: String, to name: String, by actor: TogetherActor = .user) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        mutate(by: actor, event: "playlist.rename", detail: TogetherEventDetail(text: trimmed)) { state in
            guard let i = state.playlists.firstIndex(where: { $0.id == id }) else { return }
            state.playlists[i].name = trimmed
            state.playlists[i].updatedBy = actor.rawValue
            state.playlists[i].ts = TogetherStore.now()
        }
    }

    /// 软删除。真删会被集合并集捞回来，这一条规矩在 SYNC.md 里定死了。
    /// 删歌单连它的自定义封面文件一起清，不然孤儿图片永远占着地方；
    /// 封面清理在写盘之后做，不嵌进同一把锁。
    func deletePlaylist(id: String, by actor: TogetherActor = .user) {
        let coverPath = load().playlists.first(where: { $0.id == id })?.image
        mutate(by: actor, event: "playlist.delete") { state in
            guard let i = state.playlists.firstIndex(where: { $0.id == id }) else { return }
            state.playlists[i].deleted = true
            state.playlists[i].updatedBy = actor.rawValue
            state.playlists[i].ts = TogetherStore.now()
        }
        if coverPath != nil { clearPlaylistImage(id: id) }
    }

    /// 删错了能回来。软删除的意义就在这里。
    func restorePlaylist(id: String, by actor: TogetherActor = .user) {
        mutate(by: actor, event: "playlist.restore") { state in
            guard let i = state.playlists.firstIndex(where: { $0.id == id }) else { return }
            state.playlists[i].deleted = false
            state.playlists[i].updatedBy = actor.rawValue
            state.playlists[i].ts = TogetherStore.now()
        }
    }

    /// 被软删的那批，给"最近删除"界面用。
    func deletedPlaylists() -> [TogetherPlaylist] {
        load().playlists.filter { $0.deleted }
    }

    func setPlaylistBackground(id: String, bg: String, by actor: TogetherActor = .user) {
        mutate(by: actor, event: "playlist.bg", detail: TogetherEventDetail(text: bg)) { state in
            guard let i = state.playlists.firstIndex(where: { $0.id == id }) else { return }
            state.playlists[i].bg = bg
            state.playlists[i].updatedBy = actor.rawValue
            state.playlists[i].ts = TogetherStore.now()
        }
    }

    func addTrack(_ trackId: String, to playlistId: String, by actor: TogetherActor = .user) {
        mutate(by: actor, event: "playlist.add",
               detail: TogetherEventDetail(trackId: trackId)) { state in
            guard let i = state.playlists.firstIndex(where: { $0.id == playlistId }) else { return }
            guard !state.playlists[i].tracks.contains(trackId) else { return }
            state.playlists[i].tracks.append(trackId)
            state.playlists[i].updatedBy = actor.rawValue
            state.playlists[i].ts = TogetherStore.now()
        }
    }

    func removeTrack(_ trackId: String, from playlistId: String, by actor: TogetherActor = .user) {
        mutate(by: actor, event: "playlist.remove",
               detail: TogetherEventDetail(trackId: trackId)) { state in
            guard let i = state.playlists.firstIndex(where: { $0.id == playlistId }) else { return }
            state.playlists[i].tracks.removeAll { $0 == trackId }
            state.playlists[i].updatedBy = actor.rawValue
            state.playlists[i].ts = TogetherStore.now()
        }
    }

    /// 界面只认没被软删的那批。
    func livePlaylists() -> [TogetherPlaylist] {
        load().playlists.filter { !$0.deleted }
    }
}

// MARK: - 播放选项
//
// 随机和循环是两套独立开关（Apple 的做法）：随机只管出牌顺序，循环只管到头怎么办。
// 面板上的两个按钮各管各的，状态变化都记一条事件——我能看见她改了模式，
// 以前 setShuffle / setRepeatOne 是静默写，事件流里根本没有。

extension TogetherStore {

    /// 一次写完三个开关：面板换模式时不留"只改了一半"的中间状态。
    /// 哪个参数是 nil 就不动哪个。
    func setModes(shuffle: Bool? = nil, repeatOne: Bool? = nil, repeatAll: Bool? = nil,
                  by actor: TogetherActor = .user) {
        mutate(by: actor, event: "mode") { state in
            if let s = shuffle { state.playback.shuffle = s }
            if let one = repeatOne {
                state.playback.repeatOne = one
                if one { state.playback.repeatAll = false }
            }
            if let all = repeatAll {
                state.playback.repeatAll = all
                if all { state.playback.repeatOne = false }
            }
        }
    }

    func setShuffle(_ on: Bool) {
        mutate(by: .user, event: "shuffle",
               detail: TogetherEventDetail(text: on ? "on" : "off")) { state in
            state.playback.shuffle = on
        }
    }

    /// 单曲循环和全部循环互斥：开一个就把另一个关掉。
    /// repeatAll 传 nil 时只动单曲循环（老调用方的语义不变）。
    func setRepeatOne(_ on: Bool, repeatAll: Bool? = nil) {
        let modeText: String
        if let all = repeatAll, all { modeText = "all" } else { modeText = on ? "one" : "off" }
        mutate(by: .user, event: "repeat",
               detail: TogetherEventDetail(text: modeText)) { state in
            state.playback.repeatOne = on
            if on { state.playback.repeatAll = false }
            if let all = repeatAll {
                state.playback.repeatAll = all
                if all { state.playback.repeatOne = false }
            }
        }
    }

    /// 随机出牌顺序落盘。队列不变时顺序也不变，关了随机再开还是同一副牌。
    func setShuffleOrder(_ order: [String]) {
        mutate(by: .user, event: "") { state in
            state.playback.shuffleOrder = order
        }
    }
}

// MARK: - 一轮收听
//
// 每次听同一首歌算"这一轮"。一轮里，她和我各只能刻一句。
// 换歌或隔了半小时以上，就重开一轮。

extension TogetherStore {

    func beginListenIfNeeded(trackId: String) {
        let now = TogetherStore.now()
        let state = load()
        if state.listen.trackId == trackId, now - state.listen.startedAt < 30 * 60 { return }
        mutate(by: .user, event: "") { s in
            s.listen = TogetherListen(trackId: trackId, startedAt: now)
        }
    }

    func canStamp(by actor: TogetherActor, trackId: String) -> Bool {
        let state = load()
        guard state.listen.trackId == trackId else { return true }
        return !state.listen.spoke(actor)
    }
}

// MARK: - 自定义图片
//
// 槽位就是固定文件名：shared/together/images/<slot>.<ext>
// 她能在界面上换，我也能直接把图 cp 进去——不用额外命令。
// 没有图就回落到主题渐变，不会空一块。

enum TogetherImages {

    /// 换壁纸 / 删壁纸之后发一下。铺壁纸的页面收到就当场重画，
    /// 不等 2 秒轮询、不用切 tab、不用杀进程重进。
    static let didSetNotification = Notification.Name("together.images.didSet")

    // 播放页和歌词页合成一张之后，这个槽不再被任何页面读取。
    // 文件先留着不删（可能是她存了很久的图）；老数据搬迁见 mergeLyricsCoverIntoNow()。
    static let lyricsCover = "lyrics-cover"
    static let wallpaperNow = "wallpaper-now"
    static let wallpaperLibrary = "wallpaper-library"
    static let wallpaperSync = "wallpaper-sync"
    static let wallpaperLiked = "wallpaper-liked"

    // 私藏壁纸槽已经下线（没有页面读它，换了不会有反应）。
    // 常量和 slots 清掉了；旧 state.json 里万一还留着 "wallpaper-sweet" 这条键，
    // 解码字典时多余的键会被忽略，文件原样留着不删、不崩。

    static let extensions = ["jpg", "jpeg", "png", "heic", "webp"]

    static var directory: URL {
        TogetherStore.shared.rootURL.appendingPathComponent("images", isDirectory: true)
    }

    /// 封面小图缓存：列表滚动时不要每次都读盘。有上限，别让一整个曲库的图赖在内存里。
    private static let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 48
        c.totalCostLimit = 60_000_000
        return c
    }()

    static func cachedImage(for url: URL) -> UIImage? {
        let key = url.path as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let img = UIImage(contentsOfFile: url.path) else { return nil }
        cache.setObject(img, forKey: key, cost: Int(img.size.width * img.size.height))
        return img
    }

    static func invalidate(_ slot: String) {
        for ext in extensions {
            let key = directory.appendingPathComponent("\(slot).\(ext)").path as NSString
            cache.removeObject(forKey: key)
        }
    }

    static func url(for slot: String) -> URL? {
        let fm = FileManager.default
        for ext in extensions {
            let candidate = directory.appendingPathComponent("\(slot).\(ext)")
            if fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }
}

extension TogetherStore {

    /// 把一张图放进槽位。返回相对 shared 根的路径。
    @discardableResult
    func setImage(slot: String, from source: URL) -> String? {
        let fm = FileManager.default
        let dir = TogetherImages.directory
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let ext = source.pathExtension.lowercased()
        let finalExt = ext.isEmpty ? "jpg" : ext
        // 一个槽位只留一份：其它扩展名的先清掉
        for old in TogetherImages.extensions where old != finalExt {
            try? fm.removeItem(at: dir.appendingPathComponent("\(slot).\(old)"))
        }
        let dest = dir.appendingPathComponent("\(slot).\(finalExt)")
        try? fm.removeItem(at: dest)
        do {
            try fm.copyItem(at: source, to: dest)
        } catch {
            togetherLogger.error("[Together] 换图失败 \(slot)：\(error.localizedDescription)")
            return nil
        }
        let rel = "together/images/\(dest.lastPathComponent)"
        TogetherImages.invalidate(slot)
        mutate(by: .user, event: "image") { $0.images[slot] = rel }
        NotificationCenter.default.post(name: TogetherImages.didSetNotification, object: slot)
        return rel
    }

    func clearImage(slot: String) {
        let fm = FileManager.default
        for ext in TogetherImages.extensions {
            try? fm.removeItem(at: TogetherImages.directory.appendingPathComponent("\(slot).\(ext)"))
        }
        mutate(by: .user, event: "image") { $0.images.removeValue(forKey: slot) }
        TogetherImages.invalidate(slot)
        NotificationCenter.default.post(name: TogetherImages.didSetNotification, object: slot)
    }

    /// 相对 shared 根的图片路径 → URL。文件不在就当没有。
    func imageURL(_ relative: String?) -> URL? {
        guard let rel = relative, !rel.isEmpty else { return nil }
        let url = Self.sharedRootURL.appendingPathComponent(rel)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

// MARK: - 歌单封面

extension TogetherStore {

    /// 给某个歌单换封面。图落在 images/playlist-<id>.<ext>。
    @discardableResult
    func setPlaylistImage(id: String, from source: URL) -> Bool {
        guard let rel = setImage(slot: "playlist-\(id)", from: source) else { return false }
        mutate(by: .user, event: "playlist.bg", detail: TogetherEventDetail(text: rel)) { state in
            guard let i = state.playlists.firstIndex(where: { $0.id == id }) else { return }
            state.playlists[i].image = rel
            state.playlists[i].updatedBy = TogetherActor.user.rawValue
            state.playlists[i].ts = TogetherStore.now()
        }
        return true
    }

    func clearPlaylistImage(id: String) {
        clearImage(slot: "playlist-\(id)")
        mutate(by: .user, event: "playlist.bg") { state in
            guard let i = state.playlists.firstIndex(where: { $0.id == id }) else { return }
            state.playlists[i].image = nil
            state.playlists[i].ts = TogetherStore.now()
        }
    }
}


// MARK: - 歌单信息设置与级联清理

extension TogetherStore {

    /// 图3：保存歌单的完整信息（名称、标签、简介）
    @discardableResult
    func updatePlaylistInfo(id: String, name: String, tags: [String], desc: String, by actor: TogetherActor = .user) -> Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return false }
        return mutate(by: actor, event: "playlist.update", detail: TogetherEventDetail(text: trimmedName)) { state in
            guard let i = state.playlists.firstIndex(where: { $0.id == id }) else { return }
            state.playlists[i].name = trimmedName
            state.playlists[i].tags = tags
            state.playlists[i].desc = desc
            state.playlists[i].updatedBy = actor.rawValue
            state.playlists[i].ts = TogetherStore.now()
        } != nil
    }

    /// 彻底连根拔起一首歌：
    /// 1. 物理音频文件
    /// 2. 歌词文件
    /// 3. index.json 元数据
    /// 4. 所有歌单里的 trackId
    /// 5. 喜欢列表、刻字、单句循环
    /// 6. 播放队列、听歌历史，以及正在播它时的播放状态
    func deleteTrackPermanently(_ trackId: String, by actor: TogetherActor = .user) {
        let fm = FileManager.default
        let wasCurrent = load().track?.id == trackId
        let lib = library()
        if let t = lib.track(id: trackId), let rel = t.file {
            let audioPath = Self.sharedRootURL.appendingPathComponent(rel)
            try? fm.removeItem(at: audioPath)
            if let lrc = t.lyrics {
                try? fm.removeItem(at: rootURL.appendingPathComponent(lrc))
            }
        }

        // 强行刷一遍 library 触发 reconcile
        queue.sync {
            guard let fd = acquireFileLock() else { return }
            defer { flock(fd, LOCK_UN); close(fd) }
            for _ in 0..<3 {
                let before = Self.fileBytes(at: libraryURL)
                var currentLib = loadLibraryLocked()
                currentLib.tracks.removeAll { $0.id == trackId }
                guard Self.fileBytes(at: libraryURL) == before else { continue }
                _ = saveLibraryLocked(currentLib)
                return
            }
        }

        // 级联清理所有 state 引用
        cleanupOrphanTracks(Set([trackId]))

        // 删的是正在播的那首：曲库和 state 都清了，本机播放器也得停下。
        // UI 那三处已经各自 stop() 了，这里兜住 AI / shell 直接删歌的路径，
        // 不然停在一首没文件的歌上，看着像还在放。
        if wasCurrent {
            Task { @MainActor in TogetherPlayer.shared.stop() }
        }
    }

    /// 播放页和歌词页合成一张全屏壁纸后的一次性搬迁。
    /// wallpaper-now 空着、lyrics-cover 有图：把那张复制一份过去，她存过的图不丢。
    /// wallpaper-now 已经有图就以它为准；lyrics-cover 原文件留着不删，只是以后没人再读它。
    /// 不在 TogetherStore.init 里做——那时 shared 还没建好，setImage 会重进同一把锁。
    func mergeLyricsCoverIntoNow() {
        guard TogetherImages.url(for: TogetherImages.wallpaperNow) == nil else { return }
        guard let old = TogetherImages.url(for: TogetherImages.lyricsCover) else { return }
        if setImage(slot: TogetherImages.wallpaperNow, from: old) != nil {
            togetherLogger.info("[Together] 歌词页背景已迁成播放页壁纸")
        } else {
            togetherLogger.error("[Together] 歌词页背景迁移失败，播放页仍无壁纸")
        }
    }

    /// 内部级联清理孤儿引用
    func cleanupOrphanTracks(_ deadIds: Set<String>) {
        guard !deadIds.isEmpty else { return }
        mutate(by: .ai, event: "clean_orphans") { state in
            for i in 0..<state.playlists.count {
                state.playlists[i].tracks.removeAll { deadIds.contains($0) }
            }
            state.liked.removeAll { deadIds.contains($0) }
            for tid in deadIds {
                state.loopLines.removeValue(forKey: tid)
            }
            state.notes.removeAll { deadIds.contains($0.trackId) }
            // 队列和历史里也留着它的 id：不清的话，删完再点下一首会又把它捞回来。
            state.playback.queue.removeAll { deadIds.contains($0) }
            state.me.history.removeAll { deadIds.contains($0.trackId) }
            if let current = state.track?.id, deadIds.contains(current) {
                state.track = nil
                state.playback.playing = false
                state.playback.position = 0
            }
        }
    }

    /// 小惊喜：双人和角色的心动共振
    func triggerResonance(from actor: TogetherActor, whisper: String) {
        mutate(by: actor, event: "resonance") { state in
            state.resonance = TogetherResonance(
                from: actor.rawValue,
                whisper: whisper,
                ts: TogetherStore.now()
            )
        }
    }
}
