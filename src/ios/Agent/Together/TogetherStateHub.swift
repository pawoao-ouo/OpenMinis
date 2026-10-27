//
//  TogetherStateHub.swift
//  MinisApp
//
//  一起听 · 唯一的观察点。
//
//  以前六个视图各开一个 2 秒轮询、播放器再开一个 1.5 秒跟随轮询，
//  每个轮询都在主线程做文件 I/O + 整份 JSON 解码，播着歌还每 3 秒
//  被进度回写叫醒一次——页面卡顿的根子就在这里。
//
//  现在只有一个地方读文件：这里。一个 2 秒定时器只做"变了没有"的
//  轻量判断（revision + 文件 mtime），变了才重读；任何一次有意义的
//  写盘还会立刻发通知，Hub 当场重读，不等轮询。进度回写不发通知、
//  不动 revision，所以播歌本身不再叫醒任何视图。
//
//  视图只观察 Hub：@ObservedObject + hub.state / hub.library。
//  播放器的跟随也挂在 hub.$state 上：状态变了才处理事件，不再按秒空转。
//

import Foundation
import Combine
import SwiftUI

extension Notification.Name {
    /// 一次有意义的 state.json 写盘（进度回写除外）。Hub 收到就当场重读。
    static let togetherStateDidChange = Notification.Name("together.state.didChange")
}

@MainActor
final class TogetherStateHub: ObservableObject {

    static let shared = TogetherStateHub()

    @Published private(set) var state: TogetherState
    @Published private(set) var library: TogetherLibrary

    private var timer: AnyCancellable?
    private var stateObserver: NSObjectProtocol?
    private var lastStateRevision: Int
    private var lastLibraryMtime: Date?
    private var lastMusicDirMtime: Date?

    private init() {
        let store = TogetherStore.shared
        let initial = store.load()
        self.state = initial
        self.lastStateRevision = initial.revision
        self.library = store.library()
        self.lastLibraryMtime = Self.mtime(of: store.libraryURL)
        self.lastMusicDirMtime = Self.mtime(of: store.musicDirectory)

        // 状态变了就重读。通知是主队列投递的，读盘在主线程——
        // 和以前每个视图轮询时做的事一样，只是从六次变成一次。
        stateObserver = NotificationCenter.default.addObserver(
            forName: .togetherStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.refreshNow()
        }

        timer = Timer.publish(every: 2, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.tick() }
    }

    deinit {
        timer?.cancel()
        if let observer = stateObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// 立刻重读一次（写完动作后调用方自己叫一声也行，通知本来就会叫）。
    func refreshNow() {
        let fresh = TogetherStore.shared.load()
        if fresh != state {
            state = fresh
        }
        lastStateRevision = fresh.revision
        refreshLibraryIfNeeded()
    }

    /// 曲库文件变了才重读（导入/删歌后调用，或轮询发现 mtime 变了）。
    func refreshLibraryNow() {
        lastLibraryMtime = nil
        lastMusicDirMtime = nil
        refreshLibraryIfNeeded()
    }

    // MARK: - 内部

    private func tick() {
        // 轻量判断先行：只读 revision 数字，没变就不解码整份文件。
        // revision 只在有意义的写盘时 +1，进度回写不算。
        if let rev = TogetherStore.shared.peekRevision(), rev == lastStateRevision {
            refreshLibraryIfNeeded()
            return
        }
        refreshNow()
    }

    private func refreshLibraryIfNeeded() {
        let store = TogetherStore.shared
        let libMtime = Self.mtime(of: store.libraryURL)
        let dirMtime = Self.mtime(of: store.musicDirectory)
        guard libMtime != lastLibraryMtime || dirMtime != lastMusicDirMtime else { return }
        lastLibraryMtime = libMtime
        lastMusicDirMtime = dirMtime
        let lib = store.library()
        if lib != library { library = lib }
    }

    private static func mtime(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}
