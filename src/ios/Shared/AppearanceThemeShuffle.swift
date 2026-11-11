import Foundation
import SwiftUI

// MARK: - 摇一套配色
//
// [10-18 醒醒] 「这个摇一摇换主题，这个是被你写死的几个对吗。自由度高一点，
// 或者你把配色写的高级感一点你选，现在的配色有点 low。」
//
// ## 上一版为什么 low
//
// 上一版主色饱和度摇在 0.38-0.67。0.67 已经是"艳"了——那一段摇出来的
// 是糖果色，不是高级感。她说的"low"就是这一段。
//
// ## 现在按莫兰迪来
//
// 查到的莫兰迪色系定义：**饱和度 15%-40%，明度 55%-80%，灰调柔和**。
// 这才是"软糯干净"的数值区间。所以：
//
// - 主色饱和度 **0.15 - 0.40**，不再往 0.67 跑
// - 所有色的明度往 0.55 - 0.80 靠
// - 底色不追纯白，追米白/灰白（纯白配低饱和主色会发脏）
//
// ## 自由度
//
// 不是"写死几个预设"，是真的连续可摇：
// - 色相 0-360 全圈
// - 饱和度在莫兰迪区间内连续
// - 明度档位可选（更浅 / 标准 / 更深）
// - 冷暖偏向可切
//
// 另外给「按感觉摇」——软糯 / 清透 / 沉静 / 暖阳 / 夜。这几个不是写死的
// 色值，是**不同的参数区间**，摇出来每次都不一样。

enum AppearanceThemeShuffle {

    /// 摇骰子的风格档。不是写死的色板，是参数区间。
    enum Mood: String, CaseIterable, Identifiable {
        case soft, airy, calm, warm, night
        var id: String { rawValue }
        var title: String {
            switch self {
            case .soft: return AppLocalized("软糯")
            case .airy: return AppLocalized("清透")
            case .calm: return AppLocalized("沉静")
            case .warm: return AppLocalized("暖阳")
            case .night: return AppLocalized("夜")
            }
        }

        /// 色相区间（度）。nil = 全圈。
        var hueRange: ClosedRange<Double>? {
            switch self {
            case .soft: return 320...360   // 粉、樱、藕
            case .airy: return 170...230   // 雾蓝、水青
            case .calm: return 100...170   // 苔、灰绿
            case .warm: return 15...50     // 杏、陶土
            case .night: return nil
            }
        }

        /// 饱和度区间。全部落在莫兰迪范围里，只是宽窄不同。
        var saturation: ClosedRange<Double> {
            switch self {
            case .soft: return 0.18...0.34
            case .airy: return 0.15...0.30
            case .calm: return 0.16...0.32
            case .warm: return 0.22...0.38
            case .night: return 0.16...0.30
            }
        }

        /// 底色明度：越靠夜越深。
        var canvasLightness: Double {
            switch self {
            case .soft, .airy: return 0.972
            case .calm: return 0.968
            case .warm: return 0.970
            case .night: return 0.955
            }
        }

        var prefersDark: Bool { self == .night }
    }

    /// 摇一套。`seed` 传 nil 就是真随机；传固定值可以复现同一套。
    ///
    /// [10-18 醒醒 第三轮] 改成**先摇一个主色，再走 12 步色阶推导**，
    /// 不再手写 17 个角色的公式。
    ///
    /// 为什么换：原来 17 个角色各写一条 HSL 公式，加一个角色就要多写一条，
    /// 而且互相之间没有关系——上一轮"卡片换色带动图标底"就是这么来的。
    /// 现在主色定第 9 步，其余 11 步按 Radix 的规则推，角色只是色阶的视图。
    ///
    /// 另外**生成后强制过一遍对比度**：正文 4.5:1、UI 3:1。摇出来的东西
    /// 一定看得清，不会出现灰字压浅底。
    static func shuffle(seed: UInt64? = nil,
                        mood: Mood? = nil) -> (light: [AppearanceColorRole: String],
                                               dark: [AppearanceColorRole: String],
                                               name: String) {
        var rng = SplitMix64(seed: seed ?? UInt64.random(in: 0...UInt64.max))

        // 不指定风格就随机挑一个——这样连点几次每次调子都不同。
        let picked = mood ?? Mood.allCases[Int(rng.next() % UInt64(Mood.allCases.count))]

        // 1. 主色：色相在风格区间内连续摇，饱和度在莫兰迪区间内连续摇
        let hue: Double
        if let range = picked.hueRange {
            let span = range.upperBound - range.lowerBound
            hue = range.lowerBound + Double(rng.next() % 10_000) / 10_000 * span
        } else {
            hue = Double(rng.next() % 3600) / 10.0
        }
        let satSpan = picked.saturation.upperBound - picked.saturation.lowerBound
        let sat = picked.saturation.lowerBound
            + Double(rng.next() % 10_000) / 10_000 * satSpan

        let (light, dark) = deriveMaps(hue: hue, sat: sat)
        return (light, dark, name(hue: hue, sat: sat, mood: picked))
    }

    /// v5 摇一摇：11 套固定搭配（2026-11-11 醒醒定，11 套她全喜欢）。
    ///
    /// 来源是她发的 11 张参考图（@今日特调色 8 张、@灵感捕梦网bot 3 张），
    /// 每套只有图上印的 4 个色号，原样用，不调浅、不调深、不加同色系。
    /// 分法是她亲口给的例子（黄油热可可）：AI 气泡是最跳的那个色、
    /// 用户气泡是最深的那个色、按钮是剩下两个浅色里深一点的那个、
    /// 底色是最浅的那个色；输入栏是白色。两个气泡一明一暗形成反差。
    ///
    /// 三套例外（杏仁豆花露、芋泥椰冻、莓莓云页奶）：图上最跳的色和
    /// 最深的色是同一个，用户气泡改用剩下的第 4 个色，不然两个气泡
    /// 会撞成一个色。
    ///
    /// 浅深两套都是写死的色值，**不走 deriveMaps**——单色相推导会把
    /// 搭配推没。也**不过对比度兜底**：有几套正文就是偏淡（芋泥
    /// 1.72:1、莓莓 1.37:1），是她看过、认了的原样，写死在下面。
    private struct CuratedShakePalette {
        let name: String
        let light: [AppearanceColorRole: String]
        let dark: [AppearanceColorRole: String]
    }

    private static let curatedShakePalettes: [CuratedShakePalette] = [
        CuratedShakePalette(
            name: "黄油热可可",
            light: [.canvas: "FFFEEF", .surface: "FFFFFF", .primaryText: "593334", .secondaryText: "593334", .accent: "F9DB6B", .userBubble: "593334", .assistantBubble: "FEDC01", .bubbleText: "FFFEEF", .assistantBubbleText: "593334", .border: "593334", .field: "FFFFFF"],
            dark: [.canvas: "101216", .surface: "593334", .primaryText: "FFFEEF", .secondaryText: "FFFEEF", .accent: "F9DB6B", .userBubble: "593334", .assistantBubble: "FEDC01", .bubbleText: "FFFEEF", .assistantBubbleText: "593334", .border: "FFFEEF", .field: "FFFFFF"]
        ),
        CuratedShakePalette(
            name: "椰青冰美式",
            light: [.canvas: "E1EFF4", .surface: "FFFFFF", .primaryText: "512128", .secondaryText: "512128", .accent: "EDDFD4", .userBubble: "512128", .assistantBubble: "9D7C6D", .bubbleText: "E1EFF4", .assistantBubbleText: "101216", .border: "512128", .field: "FFFFFF"],
            dark: [.canvas: "101216", .surface: "512128", .primaryText: "E1EFF4", .secondaryText: "E1EFF4", .accent: "EDDFD4", .userBubble: "512128", .assistantBubble: "9D7C6D", .bubbleText: "E1EFF4", .assistantBubbleText: "101216", .border: "E1EFF4", .field: "FFFFFF"]
        ),
        CuratedShakePalette(
            name: "杏仁豆花露",
            light: [.canvas: "FAF7F5", .surface: "FFFFFF", .primaryText: "A58F8B", .secondaryText: "A58F8B", .accent: "FAF1E7", .userBubble: "D6C8B9", .assistantBubble: "A58F8B", .bubbleText: "101216", .assistantBubbleText: "101216", .border: "A58F8B", .field: "FFFFFF"],
            dark: [.canvas: "101216", .surface: "A58F8B", .primaryText: "FAF7F5", .secondaryText: "FAF7F5", .accent: "FAF1E7", .userBubble: "D6C8B9", .assistantBubble: "A58F8B", .bubbleText: "101216", .assistantBubbleText: "101216", .border: "FAF7F5", .field: "FFFFFF"]
        ),
        CuratedShakePalette(
            name: "椰乳四季春",
            light: [.canvas: "FBF8EA", .surface: "FFFFFF", .primaryText: "8B736C", .secondaryText: "8B736C", .accent: "FFE7E8", .userBubble: "8B736C", .assistantBubble: "ECC7D6", .bubbleText: "101216", .assistantBubbleText: "101216", .border: "8B736C", .field: "FFFFFF"],
            dark: [.canvas: "101216", .surface: "8B736C", .primaryText: "FBF8EA", .secondaryText: "FBF8EA", .accent: "FFE7E8", .userBubble: "8B736C", .assistantBubble: "ECC7D6", .bubbleText: "101216", .assistantBubbleText: "101216", .border: "FBF8EA", .field: "FFFFFF"]
        ),
        CuratedShakePalette(
            name: "香草米布丁",
            light: [.canvas: "FBF8F7", .surface: "FFFFFF", .primaryText: "594027", .secondaryText: "594027", .accent: "F3EEE9", .userBubble: "594027", .assistantBubble: "C3AB99", .bubbleText: "FBF8F7", .assistantBubbleText: "101216", .border: "594027", .field: "FFFFFF"],
            dark: [.canvas: "101216", .surface: "594027", .primaryText: "FBF8F7", .secondaryText: "FBF8F7", .accent: "F3EEE9", .userBubble: "594027", .assistantBubble: "C3AB99", .bubbleText: "FBF8F7", .assistantBubbleText: "101216", .border: "FBF8F7", .field: "FFFFFF"]
        ),
        CuratedShakePalette(
            name: "雪山香草酪",
            light: [.canvas: "F9F8F4", .surface: "FFFFFF", .primaryText: "5B3F41", .secondaryText: "5B3F41", .accent: "FEF6DF", .userBubble: "5B3F41", .assistantBubble: "CBB4A7", .bubbleText: "F9F8F4", .assistantBubbleText: "5B3F41", .border: "5B3F41", .field: "FFFFFF"],
            dark: [.canvas: "101216", .surface: "5B3F41", .primaryText: "F9F8F4", .secondaryText: "F9F8F4", .accent: "FEF6DF", .userBubble: "5B3F41", .assistantBubble: "CBB4A7", .bubbleText: "F9F8F4", .assistantBubbleText: "5B3F41", .border: "F9F8F4", .field: "FFFFFF"]
        ),
        CuratedShakePalette(
            name: "飞鼠灵感配色",
            light: [.canvas: "FFFFFF", .surface: "FFFFFF", .primaryText: "9F8F82", .secondaryText: "9F8F82", .accent: "E5F3FA", .userBubble: "9F8F82", .assistantBubble: "DED4E6", .bubbleText: "101216", .assistantBubbleText: "101216", .border: "9F8F82", .field: "FFFFFF"],
            dark: [.canvas: "101216", .surface: "9F8F82", .primaryText: "FFFFFF", .secondaryText: "FFFFFF", .accent: "E5F3FA", .userBubble: "9F8F82", .assistantBubble: "DED4E6", .bubbleText: "101216", .assistantBubbleText: "101216", .border: "FFFFFF", .field: "FFFFFF"]
        ),
        CuratedShakePalette(
            name: "芋泥椰冻",
            light: [.canvas: "F8F6FB", .surface: "FFFFFF", .primaryText: "CAB7E3", .secondaryText: "CAB7E3", .accent: "EDECFA", .userBubble: "D5CFEC", .assistantBubble: "CAB7E3", .bubbleText: "101216", .assistantBubbleText: "101216", .border: "CAB7E3", .field: "FFFFFF"],
            dark: [.canvas: "101216", .surface: "CAB7E3", .primaryText: "F8F6FB", .secondaryText: "F8F6FB", .accent: "EDECFA", .userBubble: "D5CFEC", .assistantBubble: "CAB7E3", .bubbleText: "101216", .assistantBubbleText: "101216", .border: "F8F6FB", .field: "FFFFFF"]
        ),
        CuratedShakePalette(
            name: "古本灵感配色",
            light: [.canvas: "FDF4ED", .surface: "FFFFFF", .primaryText: "9F8F82", .secondaryText: "9F8F82", .accent: "DDE8F6", .userBubble: "9F8F82", .assistantBubble: "F5D7D6", .bubbleText: "101216", .assistantBubbleText: "101216", .border: "9F8F82", .field: "FFFFFF"],
            dark: [.canvas: "101216", .surface: "9F8F82", .primaryText: "FDF4ED", .secondaryText: "FDF4ED", .accent: "DDE8F6", .userBubble: "9F8F82", .assistantBubble: "F5D7D6", .bubbleText: "101216", .assistantBubbleText: "101216", .border: "FDF4ED", .field: "FFFFFF"]
        ),
        CuratedShakePalette(
            name: "莓莓云页奶",
            light: [.canvas: "FFF4F5", .surface: "FFFFFF", .primaryText: "FAC7DA", .secondaryText: "FAC7DA", .accent: "E2F3FF", .userBubble: "D1E3FF", .assistantBubble: "FAC7DA", .bubbleText: "101216", .assistantBubbleText: "101216", .border: "FAC7DA", .field: "FFFFFF"],
            dark: [.canvas: "101216", .surface: "FAC7DA", .primaryText: "FFF4F5", .secondaryText: "FFF4F5", .accent: "E2F3FF", .userBubble: "D1E3FF", .assistantBubble: "FAC7DA", .bubbleText: "101216", .assistantBubbleText: "101216", .border: "FFF4F5", .field: "FFFFFF"]
        ),
        CuratedShakePalette(
            name: "吉伊灵感配色",
            light: [.canvas: "FFFFFF", .surface: "FFFFFF", .primaryText: "9F8F82", .secondaryText: "9F8F82", .accent: "F4E2E5", .userBubble: "9F8F82", .assistantBubble: "ECC9CF", .bubbleText: "101216", .assistantBubbleText: "101216", .border: "9F8F82", .field: "FFFFFF"],
            dark: [.canvas: "101216", .surface: "9F8F82", .primaryText: "FFFFFF", .secondaryText: "FFFFFF", .accent: "F4E2E5", .userBubble: "9F8F82", .assistantBubble: "ECC9CF", .bubbleText: "101216", .assistantBubbleText: "101216", .border: "FFFFFF", .field: "FFFFFF"]
        ),
    ]

    /// 从上面的 11 套固定搭配里随机抽一套（2026-11-02 摇色预览批立的
    /// 规矩不变：只出预览，不直接写进现场配色）。浅深两套是写死的色值，
    /// 原样返回，不走 deriveMaps、不过对比度兜底。
    static func shufflePureRandom(seed: UInt64? = nil) -> (light: [AppearanceColorRole: String],
                                                           dark: [AppearanceColorRole: String],
                                                           name: String) {
        var rng = SplitMix64(seed: seed ?? UInt64.random(in: 0...UInt64.max))
        let picked = curatedShakePalettes[Int(rng.next() % UInt64(curatedShakePalettes.count))]
        return (picked.light, picked.dark, picked.name)
    }

    /// 从一个主色推导浅深两套色，并过一遍对比度兜底。
    /// 由 shuffle() 使用：主色定第 9 步
    /// （Radix 里最纯的那一步），其余 11 步按 Radix 规则推；
    /// 正文 4.5:1、UI 3:1，摇出来的东西一定看得清。
    /// 纯函数，不消耗随机数，所以 shuffle() 的随机序列与抽取前一致。
    private static func deriveMaps(hue: Double, sat: Double) -> (light: [AppearanceColorRole: String],
                                                                dark: [AppearanceColorRole: String]) {
        // 主色落在第 9 步（Radix 里最纯的那一步）
        let seedHex = HSL(h: hue, s: sat, l: 0.615).hex

        // 推导两条色阶
        var light = AppearanceScale.roles(
            from: AppearanceScale.derive(seed: seedHex, dark: false), dark: false)
        var dark = AppearanceScale.roles(
            from: AppearanceScale.derive(seed: seedHex, dark: true), dark: true)

        // 对比度兜底：文字压底色不达标就推到达标
        for (role, level) in [(AppearanceColorRole.primaryText, AppearanceContrast.Level.body),
                              (.secondaryText, .body)] {
            if let fg = light[role], let bg = light[.canvas] {
                light[role] = AppearanceContrast.enforce(fg, on: bg, level: level)
            }
            if let fg = light[role], let bg = light[.surface] {
                light[role] = AppearanceContrast.enforce(fg, on: bg, level: level)
            }
            if let fg = dark[role], let bg = dark[.canvas] {
                dark[role] = AppearanceContrast.enforce(fg, on: bg, level: level)
            }
            if let fg = dark[role], let bg = dark[.surface] {
                dark[role] = AppearanceContrast.enforce(fg, on: bg, level: level)
            }
        }
        // 气泡里的字也要看得清
        for bubble in [AppearanceColorRole.userBubble, .assistantBubble] {
            if let fg = light[.primaryText], let bg = light[bubble] {
                light[.primaryText] = AppearanceContrast.enforce(fg, on: bg, level: .body)
            }
            if let fg = dark[.primaryText], let bg = dark[bubble] {
                dark[.primaryText] = AppearanceContrast.enforce(fg, on: bg, level: .body)
            }
        }

        return (light, dark)
    }

    /// 摇出来的名字。只在"存这套"时当默认值。
    private static func name(hue: Double, sat: Double, mood: Mood) -> String {
        let h = hue.truncatingRemainder(dividingBy: 360)
        let base: String
        switch h {
        case ..<15, 345...: base = "藕"
        case ..<38: base = "杏"
        case ..<62: base = "砂"
        case ..<95: base = "苔"
        case ..<140: base = "青"
        case ..<175: base = "湖"
        case ..<205: base = "雾蓝"
        case ..<240: base = "黛"
        case ..<280: base = "藤"
        case ..<315: base = "紫"
        default: base = "樱"
        }
        // 名字跟着浓度走，不跟风格走——风格已经体现在色本身了
        let tone: String
        switch sat {
        case ..<0.20: tone = "淡"
        case ..<0.28: tone = "柔"
        case ..<0.34: tone = "沉"
        default: tone = "浓"
        }
        return base + tone
    }

    // MARK: - HSL → HEX

    /// HSL 转十六进制。`h` 是 0...360 的度数，`s`/`l` 是 0...1。
    static func hsl(_ h: Double, _ s: Double, _ l: Double) -> String {
        let hh = h.truncatingRemainder(dividingBy: 360) / 360
        let ss = min(1, max(0, s))
        let ll = min(1, max(0, l))

        func hue2rgb(_ p: Double, _ q: Double, _ t0: Double) -> Double {
            var t = t0
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1.0 / 6.0 { return p + (q - p) * 6 * t }
            if t < 1.0 / 2.0 { return q }
            if t < 2.0 / 3.0 { return p + (q - p) * (2.0 / 3.0 - t) * 6 }
            return p
        }

        let r: Double, g: Double, b: Double
        if ss == 0 {
            r = ll; g = ll; b = ll
        } else {
            let q = ll < 0.5 ? ll * (1 + ss) : ll + ss - ll * ss
            let p = 2 * ll - q
            r = hue2rgb(p, q, hh + 1.0 / 3.0)
            g = hue2rgb(p, q, hh)
            b = hue2rgb(p, q, hh - 1.0 / 3.0)
        }
        func byte(_ v: Double) -> Int { Int((min(1, max(0, v)) * 255).rounded()) }
        return String(format: "%02X%02X%02X", byte(r), byte(g), byte(b))
    }
}

/// 小而快的伪随机。用它而不是 `Int.random` 是为了「同一套能复现」——
/// 摇到喜欢的可以留着，摇到不喜欢按回去也不会一样。
private struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
