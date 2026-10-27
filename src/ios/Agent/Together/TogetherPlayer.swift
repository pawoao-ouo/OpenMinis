//
//  TogetherPlayer.swift
//  MinisApp
//
//  一起听 · 音频引擎。
//
//  为什么不复用 GlobalAudioPlayer：那是语音气泡的引擎，逻辑绑在
//  "tts-xxx" 文件名和续听上，音乐需要的是换歌从头、长播、精确 seek。
//  两个引擎各管各的，锁屏那一层（VoiceNowPlaying）统一路由。
//
//  后台播放不靠这里：AudioSessionCoordinator 管 session，
//  Info.plist 的 audio background mode 已经在。这里只负责"声音从哪出"。
//

import Foundation
import AVFoundation
import Combine

@MainActor
final class TogetherPlayer: ObservableObject {

    static let shared = TogetherPlayer()
    private init() {
        // 一启动就跟：面板关着的时候我换歌，她那边也该听见。
        startFollowing()
    }

    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var track: TogetherTrack?

    /// 真有一个播放器活着（暂停也算）。锁屏那一层靠这个判断该听谁的。
    var isActive: Bool { player != nil }

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endToken: NSObjectProtocol?
    private var lastReportedSecond: Double = -1
    private var didSuspendSilentAudio = false
    /// 跟随：上一次处理过的事件 id。
    /// 不能用 revision——播放进度回写也会涨 revision，会把同一条 play 反复触发。
    private var seenEventId = ""
    private var followTimer: Timer?
    /// 语音播报让过路：记下"是我暂停的"，说完才敢自动接着放。
    private var duckedForVoice = false
    /// 用户最后一次亲手动作的时间（秒）。只在内存里，不进 state.json。
    /// AI 的命令要跟它比时间：比它旧的、或者落在它后面两秒内的，一律压住。
    private var lastUserIntentAt: Int = 0
    /// 用户亲手按了暂停、还没自己恢复：这期间 AI 推什么都不执行，等她恢复再说。
    private var userHeldPause: Bool?
    /// 随机播放的固定顺序（只在本机内存里，不写盘）。
    /// 上一首照着它往回走，下一首只在没播过的里面抽。
    private var shufflePlan: [String] = []
    private var shuffleCursor: Int = -1
    private var shuffleQueueKey: String = ""
    private var voiceObservers: [NSObjectProtocol] = []
    private var didStartFollow = false
    private let store = TogetherStore.shared
    private let logger = AppLogger(category: "TogetherPlayer")
    /// 用户手动动作之后，AI 的静默窗口（秒）。这两秒里 AI 不许把歌顶回去。
    static let aiQuietSeconds = 2

    // MARK: 播放

    /// 换一首。position 是起始秒数。
    /// autoplay 为 false 时只装载不发声——恢复"上次是暂停"的状态要用它，
    /// 否则先播一下再暂停，杀进程重开会听到"响一下"，暂停就没粘住。
    func load(_ newTrack: TogetherTrack, from position: Double = 0, autoplay: Bool = true) {
        guard let url = store.audioURL(for: newTrack) else {
            logger.error("[Together] \(newTrack.title) 没有音频文件")
            return
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            logger.error("[Together] 文件不存在：\(url.path)")
            return
        }

        teardown()
        track = newTrack
        duration = newTrack.duration > 0 ? newTrack.duration : 0

        let item = AVPlayerItem(url: url)
        let p = AVPlayer(playerItem: item)
        p.actionAtItemEnd = .pause
        player = p

        // 后台被系统续命靠这条静音轨；开始播才拿，停就还回去。
        if !didSuspendSilentAudio {
            BackgroundKeepAliveManager.shared.suspendSilentAudioForMedia()
            didSuspendSilentAudio = true
        }
        AudioSessionCoordinator.shared.begin(.mediaAttachment)

        addPeriodicObserver()
        addEndObserver()

        if position > 0 {
            p.seek(to: CMTime(seconds: position, preferredTimescale: 600),
                   toleranceBefore: .zero, toleranceAfter: .zero)
            currentTime = position
        } else {
            currentTime = 0
        }
        if autoplay {
            p.play()
            isPlaying = true
        } else {
            isPlaying = false
        }
        VoiceNowPlaying.shared.refresh()

        // 扫目录进来的歌没有时长，读一次回填，列表就不会一直显示 0:00。
        let trackId = newTrack.id
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let d = try? await item.asset.load(.duration) {
                let secs = d.seconds
                if secs.isFinite, secs > 0 {
                    if self.duration < secs { self.duration = secs }
                    self.store.updateDuration(trackId: trackId, duration: secs)
                }
            }
        }
    }

    /// 唯一的换歌口子：所有点歌、切歌、播完接歌都走这里。
    /// 先看音频文件在不在——不在就一个字都不改、不打断当前这首，只报一声错。
    @discardableResult
    func start(_ newTrack: TogetherTrack, from position: Double = 0,
               by actor: TogetherActor, queue: [String]? = nil) -> Bool {
        guard let url = store.audioURL(for: newTrack),
              FileManager.default.fileExists(atPath: url.path) else {
            logger.error("[Together] \(newTrack.title) 的音频文件不在，没换歌")
            MinisToast.show(TogetherCopy.importFailed, systemImage: "exclamationmark.triangle.fill")
            return false
        }
        load(newTrack, from: position)
        store.play(trackId: newTrack.id, at: position, by: actor, queue: queue)
        return true
    }

    func play() {
        guard let p = player else { return }
        if let d = p.currentItem?.duration.seconds, !d.isNaN, d > 0 {
            duration = d
        }
        // 播完了再点播放，从头开始
        if duration > 0, currentTime >= duration - 0.2 {
            p.seek(to: .zero)
            currentTime = 0
        }
        p.play()
        isPlaying = true
        VoiceNowPlaying.shared.refresh()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        reportProgress(force: true)
        VoiceNowPlaying.shared.refresh()
    }

    func toggle() {
        if isPlaying { pause() } else { play() }
    }

    /// 用户亲手按的播放/暂停：本地状态和 state.json 一起改，重启后还是她按的那一下。
    /// AI 派来的 pause / resume 也走 stop 或 followTick，不经过这里，免得把控制权记成用户。
    /// 面板、微控条、同步页、锁屏、控制中心、耳机都走这一个入口，暂停才会真的粘住。
    func userToggle() {
        if isPlaying { userPause() } else { userPlay() }
    }

    /// 用户亲手按的播放（锁屏 play / 耳机播放键）。
    func userPlay() {
        markUserIntent()
        userHeldPause = false          // 她自己恢复了，AI 可以再说话
        play()
        if isPlaying, !store.load().playback.playing {
            store.setPlaying(true, by: .user)
        }
    }

    /// 用户亲手按的暂停（锁屏 pause / 耳机暂停键）。没在放就不写，免得平白把 by 改成 user。
    func userPause() {
        guard isPlaying else { return }
        markUserIntent()
        userHeldPause = true           // 她亲手停的，AI 推歌一律压住
        pause()
        store.setPlaying(false, by: .user)
    }

    /// 记下"用户亲手动过"，AI 的命令要拿时间跟它比。
    private func markUserIntent() {
        lastUserIntentAt = Int(Date().timeIntervalSince1970)
    }

    func seek(to seconds: Double) {
        guard let p = player else { return }
        let maxTime = duration > 0 ? min(seconds, duration) : seconds
        let clamped = max(0, maxTime)
        p.seek(to: CMTime(seconds: clamped, preferredTimescale: 600),
               toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = clamped
        reportProgress(force: true)
        VoiceNowPlaying.shared.refresh()
    }

    /// 锁屏 / 控制中心切歌。和面板、微控条用同一套队列规则。
    func nextTrack() { skipTrack(+1) }
    func previousTrack() { skipTrack(-1) }

    /// 手动切歌。手里的遥控器这一下是她的，所以 by 记 user、时间也记下来——
    /// AI 在接下来两秒里想顶回去，会被时间戳压住。
    private func skipTrack(_ delta: Int) {
        let lib = store.library()
        guard !lib.tracks.isEmpty else { return }

        markUserIntent()
        userHeldPause = false          // 她自己在换歌，不算"暂停着等 AI 别动"

        let state = store.load()
        let currentId = track?.id ?? ""

        // 上一首的规矩：播了 3 秒以上，先从头重放这首（一起写回状态）；
        // 3 秒之内才真的换上一首。
        if delta < 0, currentTime >= 3, let cur = lib.track(id: currentId) {
            start(cur, from: 0, by: .user)
            return
        }

        if let next = pickNext(in: state, lib: lib, delta: delta, currentId: currentId) {
            start(next, from: 0, by: .user)
            return
        }

        // 队列里只剩当前这一首有效歌：手动下一首和播完同一条规矩——重放这首。
        let live = liveQueueIds(state, lib)
        if live.count <= 1, let only = lib.track(id: live.first ?? currentId) ?? lib.track(id: currentId) {
            start(only, from: 0, by: .user)
            return
        }

        // 上一首走到队列开头：歌不换，从头重放（和音乐 App 一样）。
        if delta < 0, let cur = lib.track(id: currentId) {
            start(cur, from: 0, by: .user)
            return
        }

        // 下一首走到队列末尾、又没开全部循环：停下，不绕回第一首。
        if isPlaying {
            pause()
            store.setPlaying(false, by: .user)
        }
    }

    /// 队列来源只有一处：`playback.queue` 非空就用它，空才按曲库顺序。
    /// 手动切歌和一首播完共用这一个口子，两边不会各长一套规则。
    private func queueIds(_ state: TogetherState, _ lib: TogetherLibrary) -> [String] {
        state.playback.queue.isEmpty ? lib.tracks.map { $0.id } : state.playback.queue
    }

    /// 队列里真的还在的（跳过已删歌留下的孤儿 ID）。
    private func liveQueueIds(_ state: TogetherState, _ lib: TogetherLibrary) -> [String] {
        queueIds(state, lib).filter { lib.track(id: $0) != nil }
    }

    /// 按队列、按方向找下一首有效歌，跳过已删的孤儿 ID。
    /// 顺序走不绕圈：走到头且没开全部循环就返回 nil（停住），
    /// 队列里除了当前这首没别的有效歌也返回 nil，由调用方决定重放当前这首。
    private func pickNext(in state: TogetherState, lib: TogetherLibrary,
                          delta: Int, currentId: String) -> TogetherTrack? {
        let ids = liveQueueIds(state, lib)
        guard !ids.isEmpty else { return nil }

        if state.playback.shuffle {
            return delta >= 0
                ? shuffleForward(ids, currentId: currentId, lib: lib,
                                 repeatAll: state.playback.repeatAll)
                : shuffleBackward(ids, currentId: currentId, lib: lib,
                                  repeatAll: state.playback.repeatAll)
        }

        guard let start = ids.firstIndex(of: currentId) else {
            // 当前歌不在队列里（比如队列刚被清过）：往后取第一首，往前取最后一首。
            return delta >= 0 ? lib.track(id: ids[0]) : lib.track(id: ids[ids.count - 1])
        }

        var pos = start + delta
        while pos >= 0, pos < ids.count {
            if let t = lib.track(id: ids[pos]), t.id != currentId { return t }
            pos += delta
        }

        // 只有开了全部循环，走到头才绕回另一头；关着就停在最后一首。
        guard state.playback.repeatAll else { return nil }

        var wrap = delta >= 0 ? 0 : ids.count - 1
        for _ in 0..<ids.count {
            if let t = lib.track(id: ids[wrap]), t.id != currentId { return t }
            wrap += delta
            if wrap < 0 { wrap = ids.count - 1 }
            if wrap >= ids.count { wrap = 0 }
        }
        return nil
    }

    // MARK: 随机播放的固定顺序
    //
    // 随机也得有"上一首"：抽出来就按抽到的顺序记着，往回走是上一首播过的，
    // 往前只在没播过的里面抽，一轮抽完才重排。
    // 这份顺序只放内存，state.json 一个字段都不加。

    /// 队列变了、或者当前歌不在计划里，就重排一次。
    private func syncShufflePlan(_ ids: [String], currentId: String) {
        let key = ids.joined(separator: ",")
        if key != shuffleQueueKey {
            shuffleQueueKey = key
            var rest = ids.filter { $0 != currentId }.shuffled()
            if !currentId.isEmpty {
                rest.insert(currentId, at: 0)
                shuffleCursor = 0
            } else {
                shuffleCursor = -1
            }
            shufflePlan = rest
            return
        }
        if shuffleCursor < 0 || shuffleCursor >= shufflePlan.count
            || shufflePlan[shuffleCursor] != currentId,
           let i = shufflePlan.firstIndex(of: currentId) {
            // 她直接点了别的歌：游标跟过去，已经播过的顺序还留着
            shuffleCursor = i
        }
    }

    private func shuffleForward(_ ids: [String], currentId: String,
                                lib: TogetherLibrary, repeatAll: Bool) -> TogetherTrack? {
        syncShufflePlan(ids, currentId: currentId)

        if shuffleCursor + 1 < shufflePlan.count {
            shuffleCursor += 1
            return lib.track(id: shufflePlan[shuffleCursor])
        }

        // 这一轮还没播过的，接在后面，不重抽已经播过的
        let unplayed = ids.filter { !shufflePlan.contains($0) }
        if !unplayed.isEmpty {
            shufflePlan.append(contentsOf: unplayed.shuffled())
            shuffleCursor += 1
            return lib.track(id: shufflePlan[shuffleCursor])
        }

        guard repeatAll else { return nil }
        // 全部循环：重排一轮，从没播过的头一首接着来
        var nextPlan = ids.shuffled()
        nextPlan.removeAll { $0 == currentId }
        guard !nextPlan.isEmpty else { return nil }
        shufflePlan = nextPlan
        shuffleCursor = 0
        return lib.track(id: shufflePlan[0])
    }

    private func shuffleBackward(_ ids: [String], currentId: String,
                                 lib: TogetherLibrary, repeatAll: Bool) -> TogetherTrack? {
        syncShufflePlan(ids, currentId: currentId)

        if shuffleCursor > 0 {
            shuffleCursor -= 1
            let id = shufflePlan[shuffleCursor]
            return id == currentId ? nil : lib.track(id: id)
        }

        guard repeatAll, shufflePlan.count > 1 else { return nil }
        shuffleCursor = shufflePlan.count - 1
        let id = shufflePlan[shuffleCursor]
        return id == currentId ? nil : lib.track(id: id)
    }

    func stop() {
        teardown()
        track = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        VoiceNowPlaying.shared.refresh()
    }

    /// App 重开时把上次那首装回来。
    /// 只有 state 记着"在放"才真的响——记着暂停就装好不响，别自己冒出来。
    func restoreIfNeeded() {
        guard !isActive else { return }
        let state = store.load()
        guard let t = state.track, t.file != nil else { return }
        // 恢复时按上次记的状态装载：记着在放才出声，记着暂停就只装载不响。
        load(t, from: state.playback.position, autoplay: state.playback.playing)
    }

    // MARK: 跟随 AI
    //
    // 我把遥控器递过去之后，她那边得真的换歌——面板关着也要跟。
    // 不轮询进度（进度是本机播出来的事实，反过来写会把播放器拽回去），
    // 只跟三个动作：换歌 / 播停 / 拖动。这三个的 by == "ai" 才动。

    func startFollowing() {
        observeVoice()
        guard !didStartFollow else { return }
        didStartFollow = true
        seenEventId = store.load().events.last?.id ?? ""
        followTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.followTick() }
        }
    }

    func stopFollowing() {
        followTimer?.invalidate()
        followTimer = nil
        didStartFollow = false
    }

    private func followTick() {
        let state = store.load()
        guard let last = state.events.last, last.id != seenEventId else { return }

        // 遥控器在谁手里，就听谁的。
        var controller = state.playback.by

        // 1.5 秒里 AI 连着推几条（换歌、拖动、暂停）时，只吃最后一条会把
        // 中间那次拖动吞掉。从上次吃到的那条往后按顺序逐条应用，游标最后才挪。
        let pending: [TogetherEvent]
        if let i = state.events.firstIndex(where: { $0.id == seenEventId }) {
            pending = Array(state.events[(i + 1)...])
        } else {
            // 游标那条被事件上限挤掉了：只补最近一条，不把历史整串重放。
            pending = [last]
        }

        // 冷启动时先认盘上的状态：上一轮是"她亲手按的暂停"，这轮继续压着 AI。
        if userHeldPause == nil {
            userHeldPause = (state.playback.by == "user" && !state.playback.playing)
        }

        // 用户刚亲手动过（按暂停 / 切歌）：这一刻起两秒内到的 AI 命令一律压住。
        // 她暂停期间 AI 推的歌也压住，等她恢复再说。
        let userBusyUntil = lastUserIntentAt + TogetherPlayer.aiQuietSeconds

        for ev in pending {
            seenEventId = ev.id
            // 递遥控器本身就是一条事件：谁接手本机就归谁，不单独触发播停。
            // 递过来的人当场拿到控制权，那一条之后的命令按新控制权判。
            if ev.type == "handoff" {
                if let next = ev.detail?.text, !next.isEmpty {
                    controller = next
                }
                continue
            }
            // 遥控器递在 AI 手上才吃 AI 的命令；by 只是第一道门，
            // 真正决定"这一下算不算数"的是下面三个时间戳护栏。
            guard controller == "ai", ev.by == "ai" else { continue }

            // 三个护栏，全部按时间戳判，不靠 by 一个人说了算：
            // 1) 比用户最后一次手动动作还旧的命令，压住；
            // 2) 用户暂停期间到的命令，压住，等她恢复再说；
            // 3) 用户刚动过手的两秒内，AI 不许把歌顶回去。
            if ev.ts < lastUserIntentAt { continue }
            if userHeldPause == true, ev.type != "pause" { continue }
            if ev.ts < userBusyUntil { continue }

            applyRemote(ev, state: state)
        }
    }

    /// AI 遥控器的四种动作，按事件自己带的信息落地。
    private func applyRemote(_ ev: TogetherEvent, state: TogetherState) {
        switch ev.type {
        case "play", "radio":
            // 逐条回放时不能拿 state.track 当目标——那是最后一条事件的歌，
            // 中间那次换歌会被顶掉。事件里带了 id 就按 id 取。
            let target: TogetherTrack?
            if let tid = ev.detail?.trackId, !tid.isEmpty {
                target = store.library().track(id: tid)
            } else {
                target = state.track
            }
            guard let t = target else { return }
            let pos = ev.detail?.position ?? state.playback.position
            if track?.id != t.id {
                load(t, from: pos)
            } else if abs(currentTime - pos) > 2 {
                seek(to: pos)
            }
            if !isPlaying { play() }

        case "pause":
            if isPlaying { pause() }

        case "resume":
            if !isPlaying { play() }

        case "seek":
            if let pos = ev.detail?.position, abs(currentTime - pos) > 1.5 {
                seek(to: pos)
            }

        default:
            break
        }
    }

    // MARK: 内部

    private func addPeriodicObserver() {
        guard let p = player else { return }
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = p.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                let seconds = time.seconds
                guard !seconds.isNaN else { return }
                self.currentTime = seconds
                if let d = p.currentItem?.duration.seconds, !d.isNaN, d > 0 {
                    self.duration = d
                }
                // 每跨过一整秒才往盘上写一次：面板要的是"歌还在放、进度还在"，
                // 不是每秒一条。
                if abs(seconds - self.lastReportedSecond) >= 3 {
                    self.lastReportedSecond = seconds
                    self.reportProgress()
                }
            }
        }
    }

    // MARK: 语音让路
    //
    // 语音播报和音乐抢同一个 AVAudioSession：不处理就是语音一响音乐乱跳，
    // 说完了也回不来。规矩是——语音开始我暂停，语音结束我接着放，
    // 只在我本来是"在放"的时候才恢复，她手动停的不要自己响。

    private func observeVoice() {
        guard voiceObservers.isEmpty else { return }
        let center = NotificationCenter.default
        voiceObservers.append(center.addObserver(
            forName: AudioSessionCoordinator.replyTTSStartedNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isPlaying else { return }
                self.duckedForVoice = true
                self.pause()
            }
        })
        voiceObservers.append(center.addObserver(
            forName: AudioSessionCoordinator.replyTTSEndedNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.duckedForVoice else { return }
                self.duckedForVoice = false
                self.play()
            }
        })
    }

    private func addEndObserver() {
        guard let item = player?.currentItem else { return }
        endToken = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleTrackEnd()
            }
        }
    }

    /// 一首放完：单曲循环就重放；否则按队列接下一首（全部循环才绕回开头）。
    /// 自动接歌不抢遥控器：原来是 AI 在放，接完还是 AI；原来是用户在放，还是用户。
    private func handleTrackEnd() {
        let state = store.load()
        // 保留原控制权，不许硬写成 user。
        let actor = TogetherActor(rawValue: state.playback.by ?? "") ?? .user

        if state.playback.repeatOne {
            seek(to: 0)
            play()
            store.reportProgress(position: 0)
            return
        }

        let lib = store.library()
        let currentId = track?.id ?? ""
        let live = liveQueueIds(state, lib)

        // 播完走哪首和手动点下一首是同一套规则，两边不会各长一套。
        if let next = pickNext(in: state, lib: lib, delta: 1, currentId: currentId) {
            start(next, from: 0, by: actor)
            return
        }

        // 队列里只剩这一首有效歌：手动下一首也重放它，这里同样重放，两处一致。
        if live.count <= 1, let cur = lib.track(id: currentId) {
            start(cur, from: 0, by: actor)
            return
        }

        // 队列到头、没开全部循环：停在这儿，不自己绕回第一首。
        // "停下"也要落盘，不然重开 App 又自己响起来。
        isPlaying = false
        currentTime = duration
        store.setPlaying(false, by: actor)
        reportProgress(force: true)
        VoiceNowPlaying.shared.refresh()
    }

    private func reportProgress(force: Bool = false) {
        // 面板关着、App 在后台的时候也要把进度落盘，冷启动才能接着放
        guard force || lastReportedSecond >= 0 else { return }
        store.reportProgress(position: currentTime)
    }

    private func teardown() {
        // 换歌不能把语音让路的监听一起摘掉：这两个通知只认"播放器还在不在放"，
        // 和具体某一首歌无关。以前每 load 一次就清空，第一首之后监听就永久没了，
        // 语音一响音乐不暂停、说完也不续播。观察者跟 App 同寿命,由 startFollowing()
        // 幂等装一次(observeVoice 里有 isEmpty 守卫),不再随换歌清理。
        if let token = endToken {
            NotificationCenter.default.removeObserver(token)
            endToken = nil
        }
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }
        player?.pause()
        player = nil
        if didSuspendSilentAudio {
            BackgroundKeepAliveManager.shared.resumeSilentAudioForMedia()
            didSuspendSilentAudio = false
        }
    }
}

// MARK: - 锁屏用的标题

extension TogetherPlayer {
    var nowPlayingTitle: String {
        let t = track?.title ?? ""
        return t.isEmpty ? TogetherCopy.title : t
    }

    var nowPlayingArtist: String {
        let a = track?.artist ?? ""
        return a.isEmpty ? TogetherCopy.title : a
    }
}