//
//  AmbientContext.swift
//  MinisApp
//
//  [T-ambient-context 11-07] 每轮静默喂给模型的一小段「她此刻的状态」。
//
//  她的话：「能给 ai 每回合喂用户状态吗。比如 晚上7.20——在听《好想你》——
//  距离上条消息过去了 n 分钟/小时/天。没听歌就只有时间，其他也是，没开启就
//  不喂给 ai。ai 不会一直报时，也不会把那个状态直接念出来，而是自然代入。」
//
//  设计的四条硬规矩（照她给的核心原则写进指令里，不是靠模型自己悟）：
//   1. 时间事实（几点、日期）与交互间隔（两条消息之间过了多久）是两件事，
//      分开陈述，别混成一句。
//   2. 间隔是**对话的间隔**，不是模型的体感。不许说「我等了你三个小时」
//      「我刚睡醒」——它没有主观时长。
//   3. 时间过去 ≠ 记忆和关系归零。隔了三天也只是接着上次说。
//   4. 不主动报时、不复述这段、不提「我收到一个环境块」。只有时间真的影响
//      语境时才自然带出来。
//
//  为什么放在这里而不是让工具去查：这些都发生在她开口之前，模型不该为
//  「现在几点」付一次工具往返。而且每轮都变，必须紧贴 system 末尾（前面
//  都是静态内容，动它不破坏前缀缓存）。
//
//  token 账：全开约 90–140 token。逐项开关，关掉的项连标题都不出现——
//  不是「有值但被过滤」，是压根不进 prompt。
//

import Foundation
import Network
import UIKit

// MARK: - 开关

/// 逐项开关。她说的「没开启就不喂给 ai」就是这一层：每项默认值单独定，
/// 关掉之后拼装函数连这一行都不生成。
enum AmbientSignal: String, CaseIterable, Identifiable {
    case timeFacts = "ambient.signal.time"
    case interactionGap = "ambient.signal.gap"
    case listening = "ambient.signal.listening"
    case device = "ambient.signal.device"
    case network = "ambient.signal.network"

    var id: String { rawValue }
    var key: String { rawValue }

    var title: String {
        switch self {
        case .timeFacts: return AppLocalized("时间与日期")
        case .interactionGap: return AppLocalized("距上条消息的间隔")
        case .listening: return AppLocalized("一起听正在听的歌")
        case .device: return AppLocalized("电量与充电")
        case .network: return AppLocalized("网络连接")
        }
    }

    var detail: String {
        switch self {
        case .timeFacts:
            return AppLocalized("几点、星期几、日期。关了这条，模型就只知道一个大概的时间。")
        case .interactionGap:
            return AppLocalized("两条消息之间过了多久。短于 3 分钟不报——同一句话里的连续对话，报了很吵。")
        case .listening:
            return AppLocalized("只在真的在放的时候给歌名和歌手。没在听就一个字都不给。")
        case .device:
            return AppLocalized("电量、是否在充电、低电量模式。手机快没电时它能少说两句。")
        case .network:
            return AppLocalized("Wi-Fi / 蜂窝 / 离线。离线时它不会建议你去打开网页。")
        }
    }

    /// 默认值：跟聊天体验直接相关的默认开；网络只在离线时才真的有用，
    /// 但开着也没什么可敏感的，一样默认开。全部可关。
    var defaultValue: Bool { true }

    nonisolated var isEnabled: Bool {
        (UserDefaults.standard.object(forKey: key) as? Bool) ?? defaultValue
    }

    nonisolated static func setEnabled(_ enabled: Bool, for signal: AmbientSignal) {
        UserDefaults.standard.set(enabled, forKey: signal.key)
    }

    /// 总开关：全关 = 这一整段不存在，prompt 与没有这个功能时逐字节相同。
    nonisolated static var anyEnabled: Bool { allCases.contains { $0.isEnabled } }

    /// 开关的版本号。缓存片段时把它一起存下来，版本一变就重算——否则在
    /// 设置里关掉一项，这一轮还会按旧内容发出去。
    nonisolated static var revision: Int {
        UserDefaults.standard.integer(forKey: revisionKey)
    }

    nonisolated static func bumpRevision() {
        UserDefaults.standard.set(revision + 1, forKey: revisionKey)
    }

    private static let revisionKey = "ambient.revision"
}

// MARK: - 网络类型

/// 轻量网络类型观察者。同步模块那台 monitor 是它自己私有的，借过来会把
/// 两个模块绑死，所以这里单开一台——NWPathMonitor 很便宜。
final class AmbientNetworkMonitor: @unchecked Sendable {
    static let shared = AmbientNetworkMonitor()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.openminis.ambient.path")
    private let lock = NSLock()
    private var _kind: String?

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let kind: String
            switch path.status {
            case .satisfied:
                if path.usesInterfaceType(.wifi) {
                    kind = "Wi-Fi"
                } else if path.usesInterfaceType(.cellular) {
                    kind = "蜂窝网络"
                } else if path.usesInterfaceType(.wiredEthernet) {
                    kind = "有线"
                } else {
                    kind = "在线"
                }
            case .unsatisfied:
                kind = "离线"
            default:
                kind = "连接中"
            }
            self.lock.lock()
            self._kind = kind
            self.lock.unlock()
        }
        monitor.start(queue: queue)
    }

    /// nil = 还没拿到第一条路径更新（刚启动）。宁可不报，也不报一个瞎猜的。
    var kind: String? {
        lock.lock()
        defer { lock.unlock() }
        return _kind
    }
}

// MARK: - 拼装

enum AmbientContext {

    /// 把当前状态拼成一段。返回 nil = 没有任何可报的项（全关，或者
    /// 该有的东西现在都没有）。
    ///
    /// - Parameters:
    ///   - now: 现在（注入一次，测试可替换）
    ///   - lastConversation: 上一条真对话的时间，nil = 这是第一句
    ///   - isSubAgentChild: 子代理不喂——它的「对话对象」是派活的那个 agent，
    ///     不是她本人，拿了她的状态只会答歪。
    @MainActor
    static func fragment(now: Date = Date(),
                         lastConversation: Date?,
                         isSubAgentChild: Bool) -> String? {
        guard !isSubAgentChild, AmbientSignal.anyEnabled else { return nil }

        var lines: [String] = []
        if AmbientSignal.timeFacts.isEnabled {
            lines.append(timeFactsLine(now: now))
        }
        if AmbientSignal.interactionGap.isEnabled, let last = lastConversation {
            if let gap = gapLine(now: now, last: last) { lines.append(gap) }
        }
        if AmbientSignal.listening.isEnabled, let music = listeningLine() {
            lines.append(music)
        }
        if AmbientSignal.device.isEnabled, let device = deviceLine() {
            lines.append(device)
        }
        if AmbientSignal.network.isEnabled, let kind = AmbientNetworkMonitor.shared.kind {
            lines.append("- 网络：\(kind)")
        }

        guard !lines.isEmpty else { return nil }

        var out = "## 她此刻的状态\n"
        out += "（这一段每轮由客户端自动附上，槽位固定、内容随真实状态变。它是背景事实，不是她发给你的话。）\n"
        out += lines.joined(separator: "\n")
        out += "\n\n" + usageRule
        return out
    }

    /// 用法规矩。默认是她定的核心原则，用户可以在设置页自定义。
    private static var usageRule: String {
        UserDefaults.standard.string(forKey: "ambient.usageRule") ?? defaultUsageRule
    }

    /// 默认的用法规矩，供设置页恢复默认值用。
    nonisolated static var defaultUsageRule: String {
        """
        怎么用它：只用来判断语气、节奏和她此刻能不能被烦。
        - 时间事实和对话间隔是两回事，别混着说。「现在快十二点」和「我们隔了一天没说话」不是同一件事。
        - 间隔是这两条消息之间的距离，不是你的经历。别说「我等了你三个小时」「我刚醒」——你没有主观时长，别把间隔演成体感。
        - 时间过去了不代表记忆和关系归零，接着上次的话题说就行，不用重新开始。
        - 不要报时、不要复述这一段、不要说「我注意到你现在…」。只有它真的影响你怎么开口时，才自然带出来一点。没给的项就是没有，不要猜。
        """
    }

    // MARK: 逐行

    private static func timeFactsLine(now: Date) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: zhLocale)
        df.dateFormat = "yyyy年M月d日 EEEE HH:mm"
        return "- 现在：\(df.string(from: now))（\(timeOfDayWord(now))，\(TimeZone.current.identifier)）"
    }

    /// 距上一条消息多久。3 分钟内不报：同一句话里的连续对话，报了很吵。
    private static func gapLine(now: Date, last: Date) -> String? {
        let gap = now.timeIntervalSince(last)
        guard gap >= 3 * 60 else { return nil }

        let totalMinutes = Int(gap / 60)
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes % (24 * 60)) / 60
        let minutes = totalMinutes % 60

        // 精确到分钟，不取整——她点名要「11 分钟就是 11 分钟」。
        var parts: [String] = []
        if days > 0 { parts.append("\(days) 天") }
        if hours > 0 { parts.append("\(hours) 小时") }
        if minutes > 0 || parts.isEmpty { parts.append("\(minutes) 分钟") }

        let df = DateFormatter()
        df.locale = Locale(identifier: zhLocale)
        df.dateFormat = "M月d日 HH:mm"
        return "- 距上条消息：\(parts.joined(separator: " "))（她上一句在 \(df.string(from: last))）"
    }

    /// 一起听正在放什么。没在放就是 nil——她说「没听歌就只有时间」。
    @MainActor
    private static func listeningLine() -> String? {
        let player = TogetherPlayer.shared
        guard let track = player.track, player.isPlaying || player.isVoiceDucked else { return nil }
        var line = "- 在一起听：《\(track.title)》"
        if !track.artist.isEmpty { line += " — \(track.artist)" }
        if player.duration > 0 {
            line += "（放到 \(clock(player.currentTime)) / \(clock(player.duration))）"
        }
        return line
    }

    /// 电量与充电。只在真的读到值时报（模拟器/未开监控会返回 -1）。
    /// UIKit 那几项是主线程隔离的，所以这一行也跟着 MainActor——它本来也
    /// 只会被主线程上的拼装调用。
    @MainActor
    private static func deviceLine() -> String? {
        var bits: [String] = []

        let device = UIDevice.current
        let wasEnabled = device.isBatteryMonitoringEnabled
        if !wasEnabled { device.isBatteryMonitoringEnabled = true }
        let level = device.batteryLevel
        let state = device.batteryState
        if !wasEnabled { device.isBatteryMonitoringEnabled = false }

        if level >= 0 {
            bits.append("电量 \(Int((level * 100).rounded()))%")
        }
        switch state {
        case .charging: bits.append("充电中")
        case .full: bits.append("已充满")
        case .unplugged: break
        default: break
        }
        if ProcessInfo.processInfo.isLowPowerModeEnabled { bits.append("低电量模式开着") }
        if ProcessInfo.processInfo.thermalState == .serious
            || ProcessInfo.processInfo.thermalState == .critical {
            bits.append("机身偏热")
        }

        guard !bits.isEmpty else { return nil }
        return "- 手机：" + bits.joined(separator: "，")
    }

    // MARK: 小工具

    private static let zhLocale = "zh_Hans_CN"

    private static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// 大白话的时段词：比 24 小时制好在它直接带上「深夜」这种语境暗示。
    private static func timeOfDayWord(_ date: Date) -> String {
        let hour = Calendar.current.component(.hour, from: date)
        switch hour {
        case 0..<5: return "凌晨"
        case 5..<8: return "清晨"
        case 8..<11: return "上午"
        case 11..<13: return "中午"
        case 13..<17: return "下午"
        case 17..<19: return "傍晚"
        case 19..<23: return "晚上"
        default: return "深夜"
        }
    }
}
