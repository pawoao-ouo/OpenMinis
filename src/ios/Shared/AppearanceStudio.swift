import PhotosUI
import SwiftUI
import UIKit

/// [B28 R2-2] 图片写失败不再静默：留一条可查的日志。
let appearanceLog = AppLogger(category: "Appearance")

// MARK: - Wallpaper pipeline

/// 所有壁纸走同一条管线：同一个长边上限、同一种压色、同一套格式判定。
///
/// [T-55] 以前主壁纸和一起听壁纸各写一份——两份 2200 常量、两个几乎逐行
/// 相同的缩放 + JPEG 函数、两套扩展名嗅探。数值碰巧一样，改一处漏一处只是
/// 时间问题；"并系统"在这层才算真的并上。现在只剩这一份，两处都调它。
///
/// 不标 `@MainActor`：`UIImage` 与 `UIGraphicsImageRenderer` 都不是主线程
/// 独占的，而一起听的写入路径在外层已经隔离，多挂一层反而挡住它。
enum WallpaperPipeline {

    /// 长边上限，像素。超过的一律缩到这个尺寸再编码。
    /// 全仓壁纸只认这一个数。
    static let maxEdge: CGFloat = 2200

    /// 压过之后的质量。0.86 是肉眼看不出、体积又明显下来的位置。
    static let jpegQuality: CGFloat = 0.86

    /// 认得的扩展名白名单。落盘只写这几种。
    static let extensions = ["jpg", "jpeg", "png", "heic", "webp"]

    /// 缩到 `maxEdge` 以内并编码成 JPEG。
    ///
    /// `matte` 是透明区域垫的底色——JPEG 没有 alpha，不垫会变黑边。主壁纸
    /// 垫画布色（跟着明暗走），一起听垫白，两者靠这个参数分开，不再各写一份。
    static func jpeg(_ image: UIImage,
                     maxEdge: CGFloat = WallpaperPipeline.maxEdge,
                     matte: UIColor) -> Data? {
        guard let cg = image.cgImage else { return nil }
        let source = CGSize(width: cg.width, height: cg.height)
        guard source.width > 0, source.height > 0 else { return nil }
        let scale = min(1, maxEdge / max(source.width, source.height))
        let canvas = CGSize(width: max(1, (source.width * scale).rounded()),
                            height: max(1, (source.height * scale).rounded()))
        let format = UIGraphicsImageRendererFormat()
        format.opaque = true
        format.scale = 1
        let rendered = UIGraphicsImageRenderer(size: canvas, format: format).image { _ in
            matte.setFill()
            UIBezierPath(rect: CGRect(origin: .zero, size: canvas)).fill()
            image.draw(in: CGRect(origin: .zero, size: canvas))
        }
        return rendered.jpegData(compressionQuality: jpegQuality)
    }

    /// Canvas matte for JPEG re-encodes: the colour that sits behind the
    /// image in the UI. Light canvas by default — the same matte
    /// `backgroundJPEG` uses for wallpapers (theme canvas from the
    /// palette book, falling back to the system greys).
    nonisolated static func canvasMatte(dark: Bool = false) -> UIColor {
        // `darkDefaults` / `lightDefaults` are statics on `AppearanceStudio`
        // (@MainActor), so the bare names do not resolve in this enum and
        // qualifying them would hit actor isolation — read the book
        // directly instead (the two aliases are exactly these values).
        let book = dark ? AppearancePaletteBook.dark : AppearancePaletteBook.light
        return UIColor(hex: book[.canvas] ?? (dark ? "000000" : "F5F5F7"))
    }

    /// 这张图该存成什么扩展名。先看真实文件头，再看源文件名，最后回落 jpg。
    /// 三者都不认识时返回 nil，让调用方如实报错，而不是写一个解不出来的文件。
    static func fileExtension(for image: UIImage, source: URL) -> String? {
        var headData = Data()
        if let handle = try? FileHandle(forReadingFrom: source) {
            if let chunk = try? handle.read(upToCount: 16) {
                headData = chunk
            }
            try? handle.close()
        }
        return fileExtension(forHead: [UInt8](headData),
                             fallbackPathExtension: source.pathExtension)
    }

    /// 只看字节的版本，方便单测直接喂 Data。
    static func fileExtension(forHead bytes: [UInt8],
                              fallbackPathExtension: String? = nil) -> String? {
        if bytes.count >= 12 {
            // PNG 的 89 50 4E 47、JPEG 的 FF D8、webp 的 RIFF…WEBP、
            // HEIC/HEIF 的 ftyp box、GIF 的 GIF8。
            if bytes[0] == 0x89, bytes[1] == 0x50, bytes[2] == 0x4E, bytes[3] == 0x47 { return "png" }
            if bytes[0] == 0xFF, bytes[1] == 0xD8 { return "jpg" }
            if bytes[0] == 0x52, bytes[1] == 0x49, bytes[2] == 0x46, bytes[3] == 0x46,
               bytes[8] == 0x57, bytes[9] == 0x45, bytes[10] == 0x42, bytes[11] == 0x50 { return "webp" }
            if bytes[4] == 0x66, bytes[5] == 0x74, bytes[6] == 0x79, bytes[7] == 0x70 { return "heic" }
            if bytes[0] == 0x47, bytes[1] == 0x49, bytes[2] == 0x46 { return "gif" }
        }
        if let ext = fallbackPathExtension?.lowercased(), extensions.contains(ext) { return ext }
        // 头也不认、名字也不认：用 jpg 兜底，UIImage 仍然读得懂。
        return extensions.contains("jpg") ? "jpg" : nil
    }

    /// 解码验证。写盘前和写盘后各用一次：解不出来就是解不出来，不许报成功。
    static func decodedImage(_ data: Data) -> UIImage? {
        guard let image = UIImage(data: data),
              image.size.width > 0, image.size.height > 0 else { return nil }
        return image
    }

    /// 解码验证（落盘后按文件读）。
    static func decodedImage(at url: URL) -> UIImage? {
        guard let image = UIImage(contentsOfFile: url.path),
              image.size.width > 0, image.size.height > 0 else { return nil }
        return image
    }

    /// Returns `data` with metadata segments stripped, pixels untouched.
    ///
    /// [P2-13] Imported images used to land on disk byte-for-byte, EXIF
    /// included — GPS + device tags rode into the sandbox and back out on
    /// export. Uniform re-encoding would cost a generation loss on every
    /// apply (see `writeEncodedImage`'s doc), so instead this drops only
    /// the metadata segments: JPEG APP1 (Exif + XMP), PNG eXIf/text
    /// chunks, and WebP EXIF/XMP chunks. HEIC and GIF have no byte-level
    /// strip here and MUST NOT be written as-is — callers route them
    /// through the re-encode paths (`backgroundJPEG` /
    /// `writeDownscaledJPEG`), which drop metadata by construction
    /// (see `byteLevelStrippable`). The old comment's claim that they
    /// "only reach disk via the re-encode paths" was wrong: there was
    /// no format gate, so an under-limit HEIC landed with its EXIF.
    /// Any malformed input returns the original bytes untouched: never
    /// corrupt a file to strip a tag.
    nonisolated static func strippedMetadata(_ data: Data) -> Data {
        if data.starts(with: [0xFF, 0xD8]) { return stripJPEGMetadata(data) }
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return stripPNGMetadata(data) }
        if isWebP(data) { return stripWebPMetadata(data) }
        return data
    }

    /// Whether `strippedMetadata` actually strips this data. JPEG, PNG
    /// and WebP are covered byte-for-byte; HEIC (BMFF item tables — no
    /// safe byte-level cut exists at this layer) and GIF (no EXIF
    /// segment, and its comment/application extensions are not walked
    /// here) are not. Callers must re-encode those instead of landing
    /// the raw bytes, or EXIF rides in unchanged.
    nonisolated static func byteLevelStrippable(_ data: Data) -> Bool {
        data.starts(with: [0xFF, 0xD8])
            || data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
            || isWebP(data)
    }

    /// Bytes safe to embed in an exported pack or to keep on disk:
    /// metadata stripped, pixels intact.
    ///
    /// [P1-1] `exportThemePack` used to embed raw disk bytes, so images
    /// saved before the strip gate (P2-13) leaked their EXIF (GPS +
    /// model) on export. Every export read goes through this gate now:
    /// JPEG/PNG/WebP whose EXIF orientation is "up" are byte-stripped
    /// (format and pixels untouched); anything else — HEIC/GIF, or any
    /// image whose orientation is not "up" — is re-encoded, which bakes
    /// the orientation into the pixels and drops the metadata by
    /// construction. The orientation check matters: stripping deletes
    /// the Orientation tag the renderer relies on, so a stripped file
    /// with orientation 6 would come back rotated on re-apply (P2-4) —
    /// those go through the re-encode instead. PNG keeps PNG so alpha
    /// survives; everything else becomes JPEG, padded with the theme
    /// canvas (matte) so transparent regions do not go black. Returns
    /// nil when non-strippable bytes cannot be decoded at all —
    /// undecodable bytes never land (T-29). That nil guarantee covers
    /// non-strippable formats only: when UIImage cannot decode a
    /// strippable format at all (e.g. WebP), there is no orientation
    /// to bake, so it is stripped at byte level exactly like
    /// `writeEncodedImage` does.
    nonisolated static func exportableImageData(_ data: Data, matte: UIColor = canvasMatte()) -> Data? {
        if byteLevelStrippable(data) {
            if let image = UIImage(data: data),
               image.size.width > 0, image.size.height > 0,
               image.imageOrientation != .up {
                // Orientation must be baked into the pixels before the
                // metadata is dropped — fall through to the re-encode.
            } else {
                return strippedMetadata(data)
            }
        }
        guard let image = UIImage(data: data),
              image.size.width > 0, image.size.height > 0 else { return nil }
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
            return image.pngData()
        }
        // [P2-1/P3-3] JPEG has no alpha: pad transparent regions with the
        // theme canvas (matte) instead of letting them go black. The
        // matte is the canvas colour — the image is drawn over it, so
        // padded pixels look exactly like transparent ones.
        let format = UIGraphicsImageRendererFormat()
        format.opaque = true
        format.scale = 1
        let rendered = UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            matte.setFill()
            UIBezierPath(rect: CGRect(origin: .zero, size: image.size)).fill()
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
        return rendered.jpegData(compressionQuality: 0.82)
    }

    /// "RIFF" + size + "WEBP". Kept separate so both `strippedMetadata`
    /// and `byteLevelStrippable` sniff the same 12 bytes.
    nonisolated private static func isWebP(_ data: Data) -> Bool {
        guard data.count >= 12 else { return false }
        let head = [UInt8](data.prefix(12))
        return head[0] == 0x52 && head[1] == 0x49 && head[2] == 0x46 && head[3] == 0x46
            && head[8] == 0x57 && head[9] == 0x45 && head[10] == 0x42 && head[11] == 0x50
    }

    /// JPEG: walk segments, drop APP1 (0xFFE1, Exif + XMP), copy the rest
    /// byte-for-byte. Stops parsing at SOS — scan data is copied verbatim.
    nonisolated private static func stripJPEGMetadata(_ data: Data) -> Data {
        var out = Data()
        out.reserveCapacity(data.count)
        guard data.count >= 4 else { return data }
        var i = data.startIndex
        out.append(data[i..<data.index(i, offsetBy: 2)]) // SOI
        i = data.index(i, offsetBy: 2)
        while i < data.endIndex {
            guard data[i] == 0xFF, data.index(after: i) < data.endIndex else { return data }
            let marker = data[data.index(after: i)]
            if marker == 0xFF { i = data.index(after: i); continue } // fill byte, carries nothing
            if marker == 0xD9 { // EOI: copy and finish
                out.append(data[i..<data.index(i, offsetBy: 2)])
                return out
            }
            if marker == 0xDA { // SOS: scan data follows — copy the rest verbatim
                out.append(data[i...])
                return out
            }
            // Segment with a 2-byte length (length includes its own 2 bytes).
            guard data.distance(from: i, to: data.endIndex) >= 4 else { return data }
            let len = Int(data[data.index(i, offsetBy: 2)]) << 8
                | Int(data[data.index(i, offsetBy: 3)])
            guard len >= 2, data.distance(from: i, to: data.endIndex) >= 2 + len else { return data }
            // Drop APP1 (Exif/XMP), APP13 (Photoshop IRB — IPTC location
            // data rides here) and COM (free-form comment): none of them
            // affects rendering, and all three can carry location data.
            if marker != 0xE1 && marker != 0xED && marker != 0xFE {
                out.append(data[i..<data.index(i, offsetBy: 2 + len)])
            }
            i = data.index(i, offsetBy: 2 + len)
        }
        return out
    }

    /// PNG: walk chunks, drop eXIf + text chunks, copy the rest whole
    /// (length + type + data + CRC move as one unit, so CRCs stay valid).
    nonisolated private static func stripPNGMetadata(_ data: Data) -> Data {
        var out = Data()
        out.reserveCapacity(data.count)
        guard data.count >= 8 else { return data }
        var i = data.index(data.startIndex, offsetBy: 8)
        out.append(data[data.startIndex..<i]) // signature
        while i < data.endIndex {
            guard data.distance(from: i, to: data.endIndex) >= 8 else { return data }
            let len = (Int(data[i]) << 24) | (Int(data[data.index(i, offsetBy: 1)]) << 16)
                | (Int(data[data.index(i, offsetBy: 2)]) << 8) | Int(data[data.index(i, offsetBy: 3)])
            let type = data[data.index(i, offsetBy: 4)..<data.index(i, offsetBy: 8)]
            guard len >= 0, data.distance(from: i, to: data.endIndex) >= 12 + len else { return data }
            let typeString = String(decoding: type, as: UTF8.self)
            if typeString != "eXIf" && typeString != "tEXt" && typeString != "iTXt" && typeString != "zTXt" {
                out.append(data[i..<data.index(i, offsetBy: 12 + len)])
            }
            i = data.index(i, offsetBy: 12 + len)
        }
        return out
    }

    /// WebP: RIFF container — walk chunks, drop EXIF + XMP, copy the
    /// rest whole (id + size + payload + pad move as one unit, so the
    /// image data is untouched). Chunks are id-first, unlike PNG's
    /// size-first layout. The RIFF size field (bytes 4-7, file size
    /// minus 8) is rewritten to match, and a VP8X chunk's EXIF/XMP
    /// flags are cleared when their chunks were dropped, so the flags
    /// never claim metadata that is no longer there.
    nonisolated private static func stripWebPMetadata(_ data: Data) -> Data {
        var out = Data()
        out.reserveCapacity(data.count)
        guard data.count >= 12 else { return data }
        var i = data.index(data.startIndex, offsetBy: 12)
        out.append(data[data.startIndex..<i]) // RIFF + size + WEBP
        var vp8xFlagOffset: Int? = nil
        var droppedEXIF = false
        var droppedXMP = false
        var sawChunk = false
        while i < data.endIndex {
            guard data.distance(from: i, to: data.endIndex) >= 8 else { return data }
            let type = data[i..<data.index(i, offsetBy: 4)]
            let len = Int(data[data.index(i, offsetBy: 4)])
                | (Int(data[data.index(i, offsetBy: 5)]) << 8)
                | (Int(data[data.index(i, offsetBy: 6)]) << 16)
                | (Int(data[data.index(i, offsetBy: 7)]) << 24)
            guard len >= 0, data.distance(from: i, to: data.endIndex) >= 8 + len else { return data }
            let typeString = String(decoding: type, as: UTF8.self)
            // Chunks are padded to even size with one pad byte.
            let chunkLen = 8 + len + (len % 2)
            guard data.distance(from: i, to: data.endIndex) >= chunkLen else { return data }
            sawChunk = true
            if typeString == "VP8X", len == 10 {
                vp8xFlagOffset = out.count + 8
            }
            if typeString != "EXIF" && typeString != "XMP " {
                out.append(data[i..<data.index(i, offsetBy: chunkLen)])
            } else if typeString == "EXIF" {
                droppedEXIF = true
            } else {
                droppedXMP = true
            }
            i = data.index(i, offsetBy: chunkLen)
        }
        // Header-only input (no chunks at all) is structurally
        // abnormal: return the original bytes instead of rewriting
        // the RIFF size field to 4.
        guard sawChunk else { return data }
        // VP8X flags must match the chunks that survived: EXIF = 0x08,
        // XMP = 0x04 (verified against Pillow-written WebPs: RGBA flags
        // 0x10, +EXIF 0x18).
        if let flagOffset = vp8xFlagOffset {
            var flags = out[flagOffset]
            if droppedEXIF { flags &= ~0x08 }
            if droppedXMP { flags &= ~0x04 }
            out[flagOffset] = flags
        }
        // Rewrite the RIFF size field: total size minus 8.
        let newSize = UInt32(out.count - 8)
        out[4] = UInt8(newSize & 0xFF)
        out[5] = UInt8((newSize >> 8) & 0xFF)
        out[6] = UInt8((newSize >> 16) & 0xFF)
        out[7] = UInt8((newSize >> 24) & 0xFF)
        return out
    }
}

// MARK: - Semantic appearance system

enum AppearanceScope: String, CaseIterable, Identifiable {
    // [10-18 醒醒 第五轮] `terminal` 保留。
    //
    // 我一度以为它是死的，因为七个 `Terminal*.swift` 里没有主题引用——
    // 但 `ISHTerminalView.swift:95` 确实挂了
    // `AppearanceBackdrop(scope: .terminal)`。所以它能改**壁纸**，
    // 只是终端文字是 ANSI 16 色，role 对它无效。
    //
    // 结论：`terminal` 能挂壁纸、不能调色，跟 `bottomBar` 同一类。
    // [B28 R4 · 醒醒拍板 B] `persona` 通讯录独立槽位：能单独挂壁纸、
    // 能调色。之前这页压根没接进主题系统，换什么背景都不动 ——
    // 「冷冰冰」的根在这，不在圆角和标签。
    case global, home, chat, settings, browser, files, terminal, bottomBar, persona

    var id: String { rawValue }
    var title: String {
        switch self {
        case .global: return AppLocalized("全部页面")
        case .home: return AppLocalized("首页")
        case .bottomBar: return AppLocalized("底部栏")
        case .chat: return AppLocalized("聊天")
        // [T-68] 变量名里混着英文，就这一处最显眼。
        case .settings: return AppLocalized("设置")
        case .browser: return AppLocalized("浏览器")
        case .files: return AppLocalized("文件")
        case .terminal: return AppLocalized("终端")
        case .persona: return AppLocalized("通讯录")
        }
    }

    /// 这个 scope 能不能调颜色。
    ///
    /// `bottomBar` 和 `terminal` 只承载壁纸：底部栏图标走
    /// `MinisThemeList.accent`，终端是 ANSI 16 色渲染，role 对它们没意义。
    var supportsColour: Bool { self != .bottomBar && self != .terminal }

    /// 能挂壁纸的 scope（全部都能）。
    var supportsWallpaper: Bool { true }
}

enum AppearanceVariant: String, CaseIterable, Identifiable {
    case light, dark
    var id: String { rawValue }
    var title: String {
        // [B28 E-1] 三元里的裸中文 Text() 也查不到表。
        // [T-68] 浅深两档的名字也一直挂着英文。
        self == .light ? AppLocalized("浅色") : AppLocalized("深色")
    }
}

enum AppearanceColorRole: String, CaseIterable, Identifiable {
    // [10-18 醒醒] 「卡片换颜色，AI 消息下面的图标也换颜色了」。
    //
    // 根因不是分组名字起错，是**同一个控件用了两个角色**：消息操作栏的
    // 小图标底走 surface（卡片），聊天输入栏的图标底走 mutedSurface（浅底）。
    // 两个都是"小方块图标底"，却挂在不同的角色上，所以无论怎么调都只能
    // 对一半。
    //
    // 为什么会有这种事：老的十六个角色是按"它是什么层"分的（底 / 卡 /
    // 浮层 / 浅底），不是按"它是什么控件"分的。于是"一个图标底到底算卡片
    // 还是浅底"没有答案，全看当初谁写的。Apple HIG 原话就禁止这个：
    // "Avoid using the same color to mean different things."
    //
    // 补三个控件级角色（iconTile / chip / field），并把 searchField 并进
    // field、把死角色 toolCard 删掉。见下方 legacy 映射。
    case canvas, surface, raised, mutedSurface
    case primaryText, secondaryText
    /// Third-level text: placeholder, the faintest captions, timestamps
    /// (v2 font page `--c-ink-tertiary: #8E8E93`). Label-level only — it
    /// is NOT body text and is never claimed to pass the 4.5:1 body
    /// contrast audit, which still covers primary/secondary/bubble text.
    case tertiaryText
    case accent, userBubble, assistantBubble, border
    /// [fixer-F1] Base bc659d7 added only a comment here and never
    /// declared the case, so .bubbleText did not exist and the commit
    /// could not compile. Declaring both text slots here.
    case bubbleText
    /// [fixer-F1] AI-bubble text, the mirror of bubbleText. Unset, it
    /// follows primaryText exactly like bubbleText, so existing themes
    /// behave exactly as before until the user sets it on the bubble page.
    case assistantBubbleText
    /// Shell output text on the black tool card: the body text of
    /// ShellOutputView. It is text, not accent — it must not share
    /// the accent colour (buttons/switches), and its default is
    /// bright because the card background is unconditionally black.
    case shellText
    /// [bubble-grouping] My-bubble text, separate from global text.
    /// Unset, it follows primaryText (see hex()/snapshotHex() below),
    /// so existing themes behave exactly as before until the user
    /// sets it on the bubble page.
    /// 输入类底：输入框、搜索栏、任何单行输入面
    case field
    /// 小方块图标底：消息操作栏、输入栏图标、工具条按钮
    case iconTile
    /// 胶囊/徽章底：用量、状态、标签
    case chip
    /// [T-42] 不可用态。以前没有这个角色，按钮变灰只能借用次文字或者
    /// 硬压透明度 —— 用户把次文字调亮，不可用的按钮看着就跟能点一样。
    /// 现在它有自己的位置：默认取"次文字再淡一档"，但可以被单独调。
    case disabled
    case success, warning, destructive

    var id: String { rawValue }
    var title: String {
        switch self {
        case .canvas: return AppLocalized("页面背景")
        case .surface: return AppLocalized("卡片")
        case .raised: return AppLocalized("浮层")
        case .mutedSurface: return AppLocalized("浅底")
        case .primaryText: return AppLocalized("主文字")
        case .secondaryText: return AppLocalized("次文字")
        case .tertiaryText: return AppLocalized("三级文字")
        case .shellText: return AppLocalized("终端黑卡里的字")
        case .accent: return AppLocalized("强调色")
        case .userBubble: return AppLocalized("我的气泡")
        case .assistantBubble: return AppLocalized("AI 气泡")
        case .bubbleText: return AppLocalized("我的气泡文字")
        case .assistantBubbleText: return AppLocalized("AI 气泡文字")
        case .border: return AppLocalized("边线")
        case .field: return AppLocalized("输入框")
        case .iconTile: return AppLocalized("图标底")
        case .chip: return AppLocalized("胶囊底")
        case .disabled: return AppLocalized("不可用")
        case .success: return AppLocalized("成功")
        case .warning: return AppLocalized("警告")
        case .destructive: return AppLocalized("危险")
        }
    }

    /// Where this role actually paints — shown under each 色盘 row so the
    /// mapping is unambiguous ("调色的时候对应的地方准确一点").
    var hint: String {
        switch self {
        case .canvas: return AppLocalized("每页底衬，卡片间隙和空区透出")
        case .surface: return AppLocalized("大块卡片：设置卡片、会话列表、工具卡")
        case .raised: return AppLocalized("浮层：弹窗、菜单、悬浮面板")
        case .mutedSurface: return AppLocalized("浅底小组件：图片占位、次要底块")
        case .primaryText: return AppLocalized("主文字：标题、正文")
        case .secondaryText: return AppLocalized("次文字：说明、时间戳")
        case .tertiaryText: return AppLocalized("三级文字：占位、最淡说明，只做标签不做正文")
        case .shellText: return AppLocalized("聊天里黑卡上的终端输出文字")
        case .accent: return AppLocalized("强调色：按钮、选中、开关")
        case .userBubble: return AppLocalized("你的聊天气泡")
        case .assistantBubble: return AppLocalized("AI 聊天气泡")
        case .bubbleText: return AppLocalized("我的气泡里的字，默认跟主文字走")
        case .assistantBubbleText: return AppLocalized("AI 气泡里的字，默认跟主文字走")
        case .border: return AppLocalized("分隔线、卡片描边")
        case .field: return AppLocalized("输入框、搜索栏")
        case .iconTile: return AppLocalized("小方块图标底：消息操作栏、输入栏图标")
        case .chip: return AppLocalized("胶囊底：用量、状态、标签")
        case .disabled: return AppLocalized("点不了的按钮和开关：按钮灰掉、禁用文字")
        case .success: return AppLocalized("成功状态（绿）")
        case .warning: return AppLocalized("警告状态（黄）")
        case .destructive: return AppLocalized("危险操作（红）")
        }
    }
}

/// The twenty-one colour roles, grouped by what they paint.
///
/// The palette used to be one flat list of sixteen rows. That is why picking a
/// colour felt like "一选一片都是那个颜色" — with no grouping, the only visible
/// structure was the order they happened to be declared in, and every row
/// wrote to the same global scope. Grouping makes the shape of the palette
/// legible before you touch anything.
/// [问题5c] 色盘分组按"这个东西是什么"来分，不按"它在哪个页面"分。
///
/// 她原话：「我想字管字的颜色，卡片管卡片的颜色，按钮管按键的。
/// 好不好就是简单一点，然后统一化，我这边换什么颜色对应的东西就全部变色。」
///
/// 10-18 再改：上一版五组里「按钮与选中」只有一个 accent，分组比内容还多；
/// 而真正的问题是角色本身缺「控件」这一层（图标底/胶囊底/输入类没有自己的
/// 位置，只好去蹭卡片和浅底）。现在按"你看到的东西"分六组，每组里装的是
/// 同一种东西。
enum AppearanceColorRoleGroup: String, CaseIterable, Identifiable {
    case text, backgrounds, controls, accentGroup, chat, status

    var id: String { rawValue }

    var title: String {
        switch self {
        case .text: return AppLocalized("文字")
        case .backgrounds: return AppLocalized("背景与卡片")
        case .controls: return AppLocalized("控件")
        case .accentGroup: return AppLocalized("强调")
        case .chat: return AppLocalized("聊天")
        case .status: return AppLocalized("Status")
        }
    }

    /// 这一组管什么，写在分组标题下面，省得再猜。
    var hint: String {
        switch self {
        case .text: return AppLocalized("标题、正文、说明、时间戳——所有字")
        case .backgrounds: return AppLocalized("页面底衬、大块卡片、弹窗浮层、次要底块")
        case .controls: return AppLocalized("图标底、胶囊底、输入框、边线——小零件")
        case .accentGroup: return AppLocalized("按钮、开关、选中态")
        case .chat: return AppLocalized("聊天气泡、工具卡")
        case .status: return AppLocalized("成功、警告、危险")
        }
    }

    /// [T-44] 这是**唯一**一份角色分组表。
    ///
    /// 以前有两套：这个枚举覆盖 18 个角色，装扮店那一页自己另写一份覆盖
    /// 20 个。两套各缺各的——枚举缺壳字和两个气泡字，面板缺 disabled——
    /// 于是同一份「完整配色表」在两个界面上条数不一样，加新角色时必然
    /// 漏掉一边。
    ///
    /// 现在 `allRoles` 和 `AppearanceColorRole.allCases` 必须一致，断言会查。
    var roles: [AppearanceColorRole] {
        switch self {
        case .text: return [.primaryText, .secondaryText, .tertiaryText, .shellText]
        case .backgrounds: return [.canvas, .surface, .raised, .mutedSurface]
        case .controls: return [.iconTile, .chip, .field, .border, .disabled]
        case .accentGroup: return [.accent]
        case .chat: return [.userBubble, .assistantBubble, .bubbleText, .assistantBubbleText]
        case .status: return [.success, .warning, .destructive]
        }
    }

    /// 全部分组摊平后的角色，按分组顺序。断言拿它和 `allCases` 对。
    static var allRoles: [AppearanceColorRole] { allCases.flatMap(\.roles) }
}

// MARK: - 旧角色兼容

extension AppearanceColorRole {
    /// 老版本存下来的角色名 → 现在该落到哪个角色。
    ///
    /// 角色是按字符串持久化的（UserDefaults 的 `colors.v1`、主题包 JSON 的
    /// `colorsLight`/`colorsDark`、云同步、备份），所以删掉的 `input` /
    /// `searchField` / `toolCard` 必须继续认，否则老主题包和老备份里这三项
    /// 的颜色会被静默丢掉。
    ///
    /// 合并方向：
    /// - `input` / `searchField` → `field`（本来就是同一类）
    /// - `toolCard` → `surface`（上一轮已经把工具卡改成走卡片了，角色是空壳）
    static func resolvingLegacy(_ raw: String) -> AppearanceColorRole? {
        switch raw {
        case "input", "searchField": return .field
        case "toolCard": return .surface
        default: return AppearanceColorRole(rawValue: raw)
        }
    }

    /// 老角色名是否还需要在读取时重定向。
    static var legacyRawValues: [String] { ["input", "searchField", "toolCard"] }
}

/// [T-07] 明暗模式：一个键、一个枚举、一个换算。
///
/// 以前 `appearanceMode` 是裸键，`1=浅 / 2=深` 这套映射在五处各写一遍
/// （MinisApp、MinisMediaViews、WebPreviewSheet ×2、AppearanceStudio ×2）。
/// 任一处写歪就是"主界面浅色、某张表深色"；写了个 3 之类的非法值，五处
/// 全部静默回落跟随系统，谁也不知道。
///
/// 现在只有这里定义。别处只许调 `AppearanceMode.current` 和 `.colorScheme`，
/// 不许再写 `== 1 ? ... : == 2 ? ...`。放在类型外面是因为它要在非隔离
/// 上下文里读（UIKit 回调、非主线程快照），挂在 `@MainActor` 类里反而
/// 得为它开一堆洞。
enum AppearanceMode: Int, CaseIterable {
    /// 跟随系统。0 是默认值，也是任何认不出的整数该落到的位置。
    case system = 0
    case light = 1
    case dark = 2

    static let defaultsKey = "appearanceMode"

    /// 认不出的整数一律当跟随系统。
    static func parse(_ raw: Int) -> AppearanceMode { AppearanceMode(rawValue: raw) ?? .system }

    /// 写入口拿它校验：非法值要当场报，不能悄悄变成"跟随系统"。
    static func isLegal(_ raw: Int) -> Bool { AppearanceMode(rawValue: raw) != nil }

    /// 当前档位。读和写都走这里，不再各自 `integer(forKey:)`。
    static var current: AppearanceMode {
        get { parse(UserDefaults.standard.integer(forKey: defaultsKey)) }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }

    /// 给 `.preferredColorScheme` 用：`system` 返回 nil，让系统自己决定。
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    /// 给 `overrideUserInterfaceStyle` 用。
    var interfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .system: return .unspecified
        case .light: return .light
        case .dark: return .dark
        }
    }
}

@MainActor
final class AppearanceStudio: ObservableObject {
    static let shared = AppearanceStudio()

    private enum Keys {
        static let colors = "appearanceStudio.colors.v1"
        /// [P1-8] 预设“正在用”标记的落盘：最后一次应用的预设、应用那一刻
        /// 整张颜色表的快照、当时的壁纸版本号。三者缺一不可，见 `isPresetActive`。
        static let activePreset = "appearanceStudio.activePreset.v1"
        static let activePresetColors = "appearanceStudio.activePresetColors.v1"
        static let activePresetWallpaperRevision = "appearanceStudio.activePresetWallpaperRevision.v1"
        /// [P1-8-fix] The live wallpaper revision itself, persisted so the
        /// preset marker can be checked across a relaunch. Absent = the
        /// revision was never persisted (old build / fresh install):
        /// `liveWallpaperRevision` stays nil and `isPresetActive` is
        /// false until a preset is re-applied.
        static let wallpaperRevision = "appearanceStudio.wallpaperRevision.v1"
        /// [composer-icons] 金色按键卡片的落盘：最后一次选了哪套（"gold" 或没选）。
        /// live 校验在 `isComposerIconSetActive` 里。
        static let composerIconSet = "appearanceStudio.composerIconSet.v1"
        static let userAvatar = "appearanceStudio.userAvatar.v1"
        /// [B28 R10] 用户自定义称呼。界面/提示里要提到"说话的人"时用它，
        /// 不写死任何具体名字——没填就回落到中性称呼。
        static let userDisplayName = "appearanceStudio.userDisplayName.v1"
        static let surfaceOpacity = "appearanceStudio.surfaceOpacity"
        static let bubbleOpacity = "appearanceStudio.bubbleOpacity"
        static let wallpaperShade = "appearanceStudio.wallpaperShade"
        /// [glass-switch] 全局玻璃感开关。开 = 输入栏/预览都走玻璃，
        /// 关 = 都回实底。默认开——现在本来就是玻璃。
        static let glassEnabled = "appearanceStudio.glassEnabled.v1"
        static let icons = "appearanceStudio.icons.v1"
        /// [T-07] 明暗模式原来是个裸键，散在五处各读各写。收进来之后只有
        /// `AppearanceStudio.mode` 一处碰它。
        static let appearanceMode = AppearanceMode.defaultsKey
    }

    /// Custom values only. Missing values inherit from the built-in palette;
    /// page values inherit from global before falling back to built-in.
    @Published private var customColors: [String: String]
    /// Snapshot for UIKit / off-main reads. Written on persist.
    /// [T-73b] 快照在主线程写(`persistColors`),却由动态色的闭包在任意线程
    /// 读。原来标 `nonisolated(unsafe)` 只是把编译器按住,读写之间是真的在
    /// 赛跑 —— 读到半张表会让同一屏的卡片取到新旧各一半的颜色。改成一把锁
    /// 保护的盒子:读写都串行,读取侧拿到的一定是一份完整的旧表或新表。
    /// [T-33] 非隔离上下文的透明度读取。`surfaceOpacity` 是 `@Published`，
    /// 只能在主线程读；而卡片底那几个 static computed property 不在
    /// `@MainActor` 里。直接读 UserDefaults 拿到的是同一个值——它本来就是
    /// 这个属性的落盘源，写的时候 didSet 立刻写。
    /// 拖动中的例外：live 拖动（`setSurfaceOpacityLive`）故意跳过
    /// didSet 写盘，拖动全程快照读到的是旧值；松手时
    /// `commitOpacityDials()` 写盘后发 `objectWillChange`，快照读者
    /// （HelperBlockView 的 barBg/cardBg）随重算收回新值。抽屉盖着
    /// 聊天页拖动时，拖动中的旧值本身看不见，只有松手那下要保证。
    nonisolated static var surfaceOpacitySnapshot: Double {
        (UserDefaults.standard.object(forKey: Keys.surfaceOpacity) as? Double) ?? 0.88
    }

    nonisolated(unsafe) private static let colorSnapshotLock = NSLock()
    nonisolated(unsafe) private static var colorSnapshotStorage: [String: String] = [:]

    nonisolated static var colorSnapshot: [String: String] {
        get {
            colorSnapshotLock.lock()
            defer { colorSnapshotLock.unlock() }
            return colorSnapshotStorage
        }
        set {
            colorSnapshotLock.lock()
            defer { colorSnapshotLock.unlock() }
            colorSnapshotStorage = newValue
        }
    }
    @Published private(set) var wallpaperRevision = 0
    /// [P2-5] Per-scope view revision: `wallpaperRevision` above still
    /// advances on every wallpaper write (the preset marker compares
    /// against it), but a backdrop's `.id()` only reads its own scope's
    /// counter, so one page's write no longer tears down every other
    /// page's backdrop (including its blur-28 layer). Not persisted:
    /// a relaunch rebuilds every backdrop anyway.
    @Published private(set) var wallpaperRevisionByScope: [AppearanceScope: Int] = [:]

    /// The revision a scope's backdrop `.id()` reads.
    func wallpaperRevision(for scope: AppearanceScope) -> Int {
        wallpaperRevisionByScope[scope] ?? 0
    }
    /// [P1-8] 预设“正在用”标记的内存态。只在 `applyPreset` 里写（见
    /// `recordActivePreset`），启动时从 UserDefaults 读回。`activePresetColors`
    /// 是应用那一刻整张 `customColors` 的快照——任何一处改色（全局或分页）、
    /// 换一套预设、摇色、恢复默认、应用存档、撤销，都会让 live 的表和快照
    /// 对不上，标记随即消失；壁纸只看版本号，任何一张壁纸写坏/换掉/清掉
    /// 都会让版本号前进，标记同样消失。所以标记不靠“上次点了哪个”，
    /// 靠“现在的状态是不是就是那次应用留下的状态”，重启后也一样准。
    /// 颜色落盘有 0.4 秒合并延迟，万一在那 0.4 秒内被系统杀掉，盘上的色
    /// 表是旧的、快照是新的，对不上——标记消失，不撒谎，只少标一次。
    private var activePresetRaw: String? = UserDefaults.standard.string(forKey: Keys.activePreset)
    private var activePresetColors: [String: String]? = {
        guard let data = UserDefaults.standard.data(forKey: Keys.activePresetColors),
              let value = try? JSONDecoder().decode([String: String].self, from: data) else { return nil }
        return value
    }()
    private var activePresetWallpaperRevision: Int = UserDefaults.standard.object(forKey: Keys.activePresetWallpaperRevision) as? Int ?? -1
    /// [P1-8-fix] The live wallpaper revision, restored from disk. Nil
    /// means unknown (never persisted): the old build never wrote it, so
    /// after an update from that build the marker must stay off rather
    /// than compare against a counter that restarted at 0. `recordActivePreset`
    /// materializes it (and persists it) at record time; every later bump
    /// goes through `bumpWallpaperRevision`, which keeps both in step.
    private var liveWallpaperRevision: Int? = UserDefaults.standard.object(forKey: Keys.wallpaperRevision) as? Int
    @Published private(set) var iconRevision = 0
    @Published private(set) var userAvatar: String
    /// [B28 R10] 她自己填的称呼。空 = 没设置，调用方自己回落到中性词。
    @Published private(set) var userDisplayName: String
    @Published private var customIcons: [String: String]
    /// Drag-time only: while true, the three opacity dials' `didSet`
    /// skips the UserDefaults write (see `setSurfaceOpacityLive` and
    /// friends). The in-memory value still updates and observers are
    /// still notified, so the live preview follows; the final value is
    /// persisted once on release by `commitOpacityDials()`. Only ever
    /// flipped on the main actor around a single synchronous assignment,
    /// never left set — every other writer (reset, theme apply, undo,
    /// restore) goes through the normal setter and persists as before.
    private var suppressDialPersist = false
    @Published var surfaceOpacity: Double {
        didSet { if !suppressDialPersist { UserDefaults.standard.set(surfaceOpacity, forKey: Keys.surfaceOpacity) } }
    }
    /// [T-bubble-opacity-slider] Bubble-only transparency, separate from the
    /// global surfaceOpacity so dialling bubbles down doesn't wash out cards,
    /// tool capsules and the input bar. User + assistant bubbles both read it.
    @Published var bubbleOpacity: Double {
        didSet { if !suppressDialPersist { UserDefaults.standard.set(bubbleOpacity, forKey: Keys.bubbleOpacity) } }
    }
    @Published var wallpaperShade: Double {
        didSet { if !suppressDialPersist { UserDefaults.standard.set(wallpaperShade, forKey: Keys.wallpaperShade) } }
    }
    /// [glass-switch] 全局玻璃感：开 = 输入栏/预览都走玻璃，关 = 都回实底。
    /// 默认开——现在本来就是玻璃，缺省不能把现成的样子换掉。
    @Published var glassEnabled: Bool {
        didSet { UserDefaults.standard.set(glassEnabled, forKey: Keys.glassEnabled) }
    }
    @Published var themePackRevision = 0

    /// [T-56] 以前是普通字典,只有写/删操作会清:9 个作用域各背一张
    /// 约 19MB 的图,理论上限约 170MB,谁都不主动回收。改成带 cost 上限的
    /// NSCache,内存吃紧时由系统自己丢,不用我们猜什么时候清。
    private let wallpaperCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 48 * 1024 * 1024
        return cache
    }()
    /// [T-54] 缓存键要带档位：同一作用域浅/深两份文件现在是两张不同的图，
    /// 只按作用域缓存会把浅色那份当成深色的继续用。
    private func cacheKey(_ scope: AppearanceScope) -> NSString {
        "\(scope.rawValue).\(activeVariant.rawValue)" as NSString
    }
    /// [T-31] Scopes whose wallpaper file exists but does not decode.
    private var wallpaperUnreadable: Set<AppearanceScope> = []
    /// [T-wallpaper-clear][09-10 醒醒] Scopes whose own wallpaper was CLEARED
    /// with "清除当前背景" — they do NOT fall back to the global image, so the
    /// page returns to its plain initial canvas colour. Removing the global
    /// image clears the block list too (a global clear resets everything).
    private var wallpaperClearedFallback: Set<AppearanceScope> = []
    private static let wallpaperClearedKey = "appearanceStudio.wallpaperClearedFallback"
    var cachedThemePack: AppearanceThemePack = .default
    var themePackLoaded = false
    let themePackLock = NSLock()

    private init() {
        // [T-47] 调色板完整性：少配一个角色就是一块灰，且编译时不报。
        // 这里在启动时当场断，开发期第一眼就看见。
        assert(AppearancePaletteBook.missingRoles.isEmpty,
               "AppearancePaletteBook is missing roles: \(AppearancePaletteBook.missingRoles)")
        if let data = UserDefaults.standard.data(forKey: Keys.colors),
           let value = try? JSONDecoder().decode([String: String].self, from: data) {
            customColors = value
        } else {
            customColors = [:]
        }
        // [avatar-file] Migrate-on-read for the user avatar, inlined here:
        // Swift forbids self calls before all stored properties are
        // initialized, so init cannot call loadUserAvatar() (which stays
        // for reloadAfterRestore(), where self is complete).
        let rawAvatar = UserDefaults.standard.string(forKey: Keys.userAvatar) ?? ""
        if SoulIconImage.isDataURI(rawAvatar),
           let path = SoulIconImage.migrateDataURIToFile(rawAvatar, named: "user") {
            UserDefaults.standard.set(path, forKey: Keys.userAvatar)
            userAvatar = path
        } else {
            userAvatar = rawAvatar
        }
        userDisplayName = (UserDefaults.standard.string(forKey: Keys.userDisplayName) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // [PIC-6] Custom icons used to live in UserDefaults as one JSON blob
        // of base64 data URIs (23 slots × ~1MB of PNG = a multi-MB plist
        // the system rewrites on every sync). They now live as PNG files
        // under the appearance directory; the in-memory dictionary is kept
        // as the read cache and `customIcon(for:)`'s data-URI contract is
        // unchanged.
        Self.migrateCustomIconsFromUserDefaults()
        customIcons = Self.loadCustomIconsFromDisk()
        let storedOpacity = UserDefaults.standard.object(forKey: Keys.surfaceOpacity) as? Double
        let storedShade = UserDefaults.standard.object(forKey: Keys.wallpaperShade) as? Double
        surfaceOpacity = storedOpacity ?? 0.88
        let storedBubbleOpacity = UserDefaults.standard.object(forKey: Keys.bubbleOpacity) as? Double
        bubbleOpacity = storedBubbleOpacity ?? 1.0
        wallpaperShade = storedShade ?? 0.08
        glassEnabled = (UserDefaults.standard.object(forKey: Keys.glassEnabled) as? Bool) ?? true
        loadWallpaperCleared()
        // [P1-8-fix] Resume the wallpaper revision from disk so the
        // counter keeps advancing instead of restarting at 0 after every
        // launch. When nothing was ever persisted (old build / fresh
        // install) `liveWallpaperRevision` stays nil and the preset marker
        // stays off until a preset is re-applied.
        if let savedRevision = liveWallpaperRevision {
            wallpaperRevision = savedRevision
        }
        cachedThemePack = loadStoredPackUnlocked()
        themePackLoaded = true
        // 2026-11-02: move stored old-default yellows to the new
        // monochrome defaults (global scope, exact matches only —
        // see migratedFromWarmDefaults). Runs once per launch but
        // is a no-op after the first pass, and only writes back
        // when something actually moved.
        let migrated = Self.migratedFromWarmDefaults(customColors)
        if migrated != customColors {
            customColors = migrated
            if let data = try? JSONEncoder().encode(customColors) {
                UserDefaults.standard.set(data, forKey: Keys.colors)
            }
        }
        Self.colorSnapshot = customColors
        configureUIKitSurfaces()
        // [P1-1] Strip EXIF left on disk by pre-gate saves (see
        // `migrateThemeImageMetadata`): detached so launch never waits
        // on image work; idempotent, safe to run every launch.
        Task.detached(priority: .utility) {
            Self.migrateThemeImageMetadata()
        }
    }

    fileprivate static let lightDefaults = AppearancePaletteBook.light
    fileprivate static let darkDefaults = AppearancePaletteBook.dark

    /// One-time move from the old warm defaults to the new
    /// monochrome ones, global scope only. A stored value moves
    /// ONLY if it exactly equals an old default (case-insensitive):
    /// that value was never a choice of hers, it was the default
    /// (including via the old "暖纸" preset, which wrote the same
    /// values). Anything she picked herself — any value that
    /// differs from the old defaults — is left alone, as are all
    /// page-scoped overrides and every saved library pack, which
    /// this function never sees. Pure function so the rule can
    /// be checked without running the app.
    static func migratedFromWarmDefaults(_ map: [String: String]) -> [String: String] {
        let oldLight: [AppearanceColorRole: String] = [
            .canvas: "F7F4F1", .surface: "FDFCFA", .raised: "FFFFFF",
            .mutedSurface: "F1EBE6", .primaryText: "3A322E", .secondaryText: "8A7B74",
            .accent: "B98591", .userBubble: "EFE0DE", .assistantBubble: "FDFCFA",
            .border: "E3DAD4",
            .field: "FCFAF7", .iconTile: "F2EAE4", .chip: "EDE2DC",
            .success: "7C9A83", .warning: "C0A176", .destructive: "B87C7C"
        ]
        let oldDark: [AppearanceColorRole: String] = [
            .canvas: "1A1716", .surface: "242020", .raised: "2C2725",
            .mutedSurface: "2F2A28", .primaryText: "F2EDE9", .secondaryText: "B5A8A1",
            .accent: "C99BA6", .userBubble: "4A3A3B", .assistantBubble: "242020",
            .border: "403836",
            .field: "262221", .iconTile: "2F2A28", .chip: "362F2C",
            .success: "93B09A", .warning: "CDB183", .destructive: "CB9292"
        ]
        var out = map
        for variant in AppearanceVariant.allCases {
            let oldBook = variant == .light ? oldLight : oldDark
            let newBook = variant == .light ? AppearancePaletteBook.light : AppearancePaletteBook.dark
            for (role, oldValue) in oldBook {
                let key = "global.\(variant.rawValue).\(role.rawValue)"
                if let stored = out[key], stored.uppercased() == oldValue,
                   let newValue = newBook[role] {
                    out[key] = newValue
                }
            }
            // Legacy keys the resolver still honours: a stored old
            // `input`/`searchField` is the old field colour, a stored
            // old `toolCard` is the old surface colour.
            if let stored = out["global.\(variant.rawValue).input"],
               stored.uppercased() == oldBook[.field],
               let newValue = newBook[.field] {
                out["global.\(variant.rawValue).input"] = newValue
            }
            if let stored = out["global.\(variant.rawValue).searchField"],
               stored.uppercased() == oldBook[.field],
               let newValue = newBook[.field] {
                out["global.\(variant.rawValue).searchField"] = newValue
            }
            if let stored = out["global.\(variant.rawValue).toolCard"],
               stored.uppercased() == oldBook[.surface],
               let newValue = newBook[.surface] {
                out["global.\(variant.rawValue).toolCard"] = newValue
            }
        }
        return out
    }

    private func key(_ role: AppearanceColorRole, scope: AppearanceScope,
                     variant: AppearanceVariant) -> String {
        "\(scope.rawValue).\(variant.rawValue).\(role.rawValue)"
    }

    /// 老角色名的键。删掉的 `input` / `searchField` / `toolCard` 只用来读，
    /// 不再写——写的时候一律落到新角色上。
    private func keyString(_ legacyRole: String, scope: AppearanceScope,
                           variant: AppearanceVariant) -> String {
        "\(scope.rawValue).\(variant.rawValue).\(legacyRole)"
    }

    func hex(_ role: AppearanceColorRole, scope: AppearanceScope = .global,
             variant: AppearanceVariant) -> String {
        // 新角色先读自己的键，再读它继承的旧键。
        //
        // 角色是按字符串存进 UserDefaults 的（"<scope>.<variant>.<role>"），
        // 所以 `field` 必须能接住老用户存过的 `input` / `searchField`；
        // `surface` 必须能接住 `toolCard`（上一轮把工具卡并进卡片时留的壳）。
        // 顺序：自己的 → 旧键 → 全局 → 内置。
        if let value = customColors[key(role, scope: scope, variant: variant)] { return value }
        if let legacy = legacyKey(for: role, scope: scope, variant: variant),
           let value = customColors[legacy] { return value }
        if scope != .global {
            if let value = customColors[key(role, scope: .global, variant: variant)] { return value }
            if let legacy = legacyKey(for: role, scope: .global, variant: variant),
               let value = customColors[legacy] { return value }
        }
        // [bubble-grouping] bubbleText / assistantBubbleText have no
        // built-in palette entry on purpose: unset, they follow
        // primaryText for the same scope and variant, so old themes and
        // old saved values render exactly as before. Recursion
        // terminates: primaryText is neither bubble text role.
        if role == .bubbleText || role == .assistantBubbleText {
            return hex(.primaryText, scope: scope, variant: variant)
        }
        return (variant == .light ? Self.lightDefaults : Self.darkDefaults)[role] ?? "808080"
    }

    /// 老键名，按"新角色 → 它继承的旧角色"查。
    private func legacyKey(for role: AppearanceColorRole, scope: AppearanceScope,
                           variant: AppearanceVariant) -> String? {
        switch role {
        case .field:
            // 两个旧角色都是输入类，谁有值用谁——input 更常见，先问它。
            return customColors[keyString("input", scope: scope, variant: variant)] != nil
                ? keyString("input", scope: scope, variant: variant)
                : keyString("searchField", scope: scope, variant: variant)
        case .surface:
            return keyString("toolCard", scope: scope, variant: variant)
        default:
            return nil
        }
    }

    /// 取一个语义色。
    ///
    /// [T-dynamic-color] 不传 `variant` 时返回的是**动态色**：它同时带着
    /// 浅色和深色两套值，由 UIKit 在解析时按当前 trait collection 选。
    ///
    /// 为什么要这样：原来这个函数用 `activeVariant` 自己判明暗（读
    /// `appearanceMode` + `UITraitCollection.current`），而 `CSSThemeVariables`
    /// 又让调用方传 `colorScheme == .dark` 进来 —— 两个判定源。用户在设置里
    /// 强制浅色、系统是深色时，两者给出相反的答案，同一屏的卡片和文字就分成
    /// 两种配色。
    ///
    /// 动态色只有一个判定源：`preferredColorScheme` 改的就是 trait
    /// collection，所以"跟随系统"和"强制浅/深"走的是同一条路，不可能打架。
    /// 顺带：切系统外观不用重建视图，UIKit 自己重解析。
    ///
    /// 传了 `variant` 的调用方（主题包预览、对比度体检）要的就是一个确定的
    /// 值，原样返回静态色。
    func color(_ role: AppearanceColorRole, scope: AppearanceScope = .global,
               variant: AppearanceVariant? = nil) -> Color {
        if let variant { return Color(hex: hex(role, scope: scope, variant: variant)) }
        return Color(uiColor: uiColor(role, scope: scope))
    }

    /// 一整页所有角色的当前值。对比度体检用。
    func allColors(scope: AppearanceScope = .global,
                   variant: AppearanceVariant) -> [AppearanceColorRole: String] {
        var out: [AppearanceColorRole: String] = [:]
        for role in AppearanceColorRole.allCases {
            out[role] = hex(role, scope: scope, variant: variant)
        }
        return out
    }

    /// 语义色的 UIKit 形式，同样是动态色。
    ///
    /// `UIColor(dynamicProvider:)` 的闭包在每次 trait 变化时被调用，闭包里读
    /// `trait.userInterfaceStyle` —— 这是 UIKit 唯一认可的判定源，和
    /// `preferredColorScheme` 是同一条链。
    ///
    /// 不用 `UITraitCollection.current`：它在后台线程是未定义值，动态色的
    /// 闭包恰好可能被非主线程调用。闭包给的 `trait` 永远是本次解析对应的
    /// 那一套。
    func uiColor(_ role: AppearanceColorRole, scope: AppearanceScope = .global,
                 variant: AppearanceVariant? = nil) -> UIColor {
        if let variant {
            return UIColor(hex: hex(role, scope: scope, variant: variant))
        }
        return UIColor { trait in
            let resolved: AppearanceVariant = trait.userInterfaceStyle == .dark ? .dark : .light
            // 闭包可能不在主线程跑，走快照而不是 @MainActor 的 self。
            return UIColor(hex: AppearanceStudio.snapshotHex(role, scope: scope, variant: resolved))
        }
    }

    /// [T-36] 栅格化渲染器(KaTeX / SwiftMath)要一个**确定的**明暗值,因为
    /// 它要把这个决定烘进画好的图里 —— 动态色做不到这件事。
    ///
    /// 判定源和 `uiColor` 是同一条链:窗口上的 `overrideUserInterfaceStyle`
    /// 优先(设置里的强制浅/深就是写在这儿),否则看窗口自己的 trait。这样
    /// 用户在 App 里强制浅色、系统是深色时,公式区不会和正文分成两种配色。
    ///
    /// 没有窗口(后台线程、启动早期)就退回 `UITraitCollection.current`;
    /// 样式进了缓存键,猜错一次会自纠。
    nonisolated static var renderInterfaceStyle: UIUserInterfaceStyle {
        guard Thread.isMainThread else { return UITraitCollection.current.userInterfaceStyle }
        let window = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first
        guard let window else { return UITraitCollection.current.userInterfaceStyle }
        if window.overrideUserInterfaceStyle != .unspecified {
            return window.overrideUserInterfaceStyle
        }
        return window.traitCollection.userInterfaceStyle
    }

    var activeVariant: AppearanceVariant {
        // [T-07] 五处重复的映射收到一处：合法档位照它走，跟随系统才问
        // trait collection。非法整数按"跟随系统"处理。
        switch AppearanceMode.current {
        case .light: return .light
        case .dark: return .dark
        case .system: return UITraitCollection.current.userInterfaceStyle == .dark ? .dark : .light
        }
    }

    // MARK: - Shared AI contrast gate (F1/F2)

    /// WCAG contrast helpers, shared by every AI theme path so the gate
    /// is literally the same check, not three copies that can drift.
    /// Thresholds: primaryText 4.5:1, accent 3:1, against canvas and
    /// surface. `proposed` holds only the colours this call would change;
    /// every other role resolves through `hex`, i.e. the scope's own
    /// override, then the global override, then the built-in palette —
    /// so a chat-scoped change is judged against the chat page's
    /// effective canvas/surface, not the global page's.
    private static func rgb(_ hex: String) -> (Double, Double, Double)? {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        let digits = cleaned.count == 8 ? String(cleaned.prefix(6)) : cleaned
        guard digits.count == 6, let value = Int(digits, radix: 16) else { return nil }
        return (Double((value >> 16) & 0xFF) / 255,
                Double((value >> 8) & 0xFF) / 255,
                Double(value & 0xFF) / 255)
    }

    private static func luminance(_ hex: String) -> Double? {
        guard let (r, g, b) = rgb(hex) else { return nil }
        func lin(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    private static func contrastRatio(_ a: String, _ b: String) -> Double? {
        guard let la = luminance(a), let lb = luminance(b) else { return nil }
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// Alpha byte of an 8-digit colour, nil for the usual 6-digit form.
    ///
    /// [T-24] `rgb()` deliberately works on RGB only, so #00000000 scanned
    /// as opaque black and scored 21:1 — while the renderer honours the
    /// alpha byte and paints fully transparent text. A pack could therefore
    /// make the whole app's body copy invisible and pass the gate.
    private static func alphaByte(_ hex: String) -> Int? {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard cleaned.count == 8, let value = Int(cleaned.suffix(2), radix: 16) else { return nil }
        return value
    }

    /// Failures for one scope+variant after applying `proposed`, or []
    /// when the call touches none of primaryText/accent/canvas/surface.
    /// A call that only changes e.g. secondaryText is never blocked by a
    /// pre-existing bad palette the user set in the UI. Returns [] for a
    /// scope that cannot carry colours (bottomBar/terminal); those are
    /// wallpaper-only and `setColor` ignores them anyway.
    func contrastFailures(scope: AppearanceScope, variant: AppearanceVariant,
                          proposed: [AppearanceColorRole: String]) -> [String] {
        guard scope.supportsColour else { return [] }
        // [T-24] Reject see-through values before any ratio is computed: a
        // ratio can only judge RGB, and alpha < 1 renders the text invisible
        // no matter how good that ratio looks.
        var failures: [String] = []
        for (role, value) in proposed {
            if let alpha = Self.alphaByte(value), alpha < 255 {
                failures.append("\(variant.rawValue) \(role.rawValue) alpha \(String(format: "%.2f", Double(alpha) / 255)) < 1 (text would be see-through)")
            }
        }
        // [T-23] 以前只查主文字和强调色：次文字、最淡小字、气泡字、黑卡字
        // 都能被设到看不见而零警告，气泡字对他那块气泡底的对比度更是从没
        // 算过。现在每个文字角色对自己实际坐的那块底算。
        var checked = 0
        for (role, value) in proposed {
            for (bg, threshold) in Self.contrastPairs(for: role) {
                checked += 1
                let bgHex = proposed[bg] ?? hex(bg, scope: scope, variant: variant)
                guard let ratio = Self.contrastRatio(value, bgHex), ratio < threshold else { continue }
                failures.append("\(variant.rawValue) \(role.rawValue)/\(bg.rawValue) \(String(format: "%.2f", ratio)) < \(threshold)")
            }
        }
        _ = checked
        return failures
    }

    /// [T-23] 每个文字角色实际坐在哪块底上，以及要求多少。
    ///
    /// 面板警告和 AI 关卡共用这一张表：两处各写一份，迟早又只查两个角色。
    /// `shellText` 不在这里——黑卡底是写死的黑，不跟主题，也就没有"改配色
    /// 把它改糊"这条路。
    static func contrastPairs(for role: AppearanceColorRole) -> [(bg: AppearanceColorRole, threshold: Double)] {
        switch role {
        case .primaryText, .secondaryText, .tertiaryText:
            return [(.canvas, 4.5), (.surface, 4.5)]
        case .bubbleText:
            return [(.userBubble, 4.5)]
        case .assistantBubbleText:
            return [(.assistantBubble, 4.5)]
        case .accent:
            return [(.canvas, 3.0), (.surface, 3.0)]
        default:
            return []
        }
    }

    // MARK: - Shared AI merge leftovers (F3)

    /// What a partial AI apply leaves untouched, labelled by scope.
    /// Global entries keep the pre-existing bare format
    /// (`primaryText (light)`); non-global entries are prefixed with
    /// their scope (`chat.primaryText (light)`, `wallpaper:chat`), because
    /// a pack apply only ever paints global colours — a chat override is
    /// untouched even when the same role was named globally. Per-scope
    /// wallpapers are listed by own file (`hasOwnWallpaper`), never by
    /// inheritance: a chat page showing the global image does not own a
    /// wallpaper file, and listing it would invent one.
    func aiApplyLeftovers(changedLightRoles: Set<String>, changedDarkRoles: Set<String>,
                          carriesWallpaper: Bool, carriesThinkingCard: Bool,
                          carriesInputBar: Bool) -> (images: [String], colours: [String]) {
        var images: [String] = []
        if !carriesWallpaper, wallpaper(for: .global) != nil { images.append("wallpaper") }
        if !carriesThinkingCard, thinkingCardImage() != nil { images.append("thinkingCard") }
        if !carriesInputBar, inputBarImage() != nil { images.append("inputBar") }
        for scope in AppearanceScope.allCases where scope != .global {
            if hasOwnWallpaper(scope) { images.append("wallpaper:\(scope.rawValue)") }
        }
        var colours: [String] = []
        for variant in AppearanceVariant.allCases {
            let changed = variant == .light ? changedLightRoles : changedDarkRoles
            for role in AppearanceColorRole.allCases {
                guard hasOverride(role, scope: .global, variant: variant),
                      !changed.contains(role.rawValue) else { continue }
                colours.append("\(role.rawValue) (\(variant.rawValue))")
            }
        }
        for scope in AppearanceScope.allCases where scope != .global && scope.supportsColour {
            for variant in AppearanceVariant.allCases {
                for role in AppearanceColorRole.allCases {
                    guard hasOverride(role, scope: scope, variant: variant) else { continue }
                    colours.append("\(scope.rawValue).\(role.rawValue) (\(variant.rawValue))")
                }
            }
        }
        return (images, colours)
    }

    /// Returns false when the scope cannot carry colours (bottomBar / terminal
    /// are wallpaper-only). The AI command path reports that as an error
    /// instead of claiming a change that never happened (T-22); the settings
    /// UI ignores the result, exactly as before.
    @discardableResult
    func setColor(_ color: Color, role: AppearanceColorRole,
                  scope: AppearanceScope, variant: AppearanceVariant) -> Bool {
        // 底部栏只挂壁纸，不收颜色。静默忽略，不报错——旧数据或 AI 传进来
        // 也不会写出一个永远读不到的键。
        guard scope.supportsColour else { return false }
        customColors[key(role, scope: scope, variant: variant)] = UIColor(color).hexRGB
        persistColors()
        configureUIKitSurfaces()
        return true
    }

    func colorBinding(_ role: AppearanceColorRole, scope: AppearanceScope,
                      variant: AppearanceVariant) -> Binding<Color> {
        Binding(
            get: { self.color(role, scope: scope, variant: variant) },
            set: { self.setColor($0, role: role, scope: scope, variant: variant) }
        )
    }

    func hasOverride(_ role: AppearanceColorRole, scope: AppearanceScope,
                     variant: AppearanceVariant) -> Bool {
        customColors[key(role, scope: scope, variant: variant)] != nil
    }

    /// 这一页有几项和全局不一样。给「高级」里的页级覆盖显示用——
    /// 不显示这个数，她永远不知道自己改过哪一层。
    func overrideCount(scope: AppearanceScope, variant: AppearanceVariant) -> Int {
        guard scope != .global else { return 0 }
        let prefix = "\(scope.rawValue).\(variant.rawValue)."
        return customColors.keys.filter { $0.hasPrefix(prefix) }.count
    }

    /// 把这一页的覆盖全部清掉，回到跟随全局。
    func clearOverrides(scope: AppearanceScope, variant: AppearanceVariant) {
        guard scope != .global else { return }
        let prefix = "\(scope.rawValue).\(variant.rawValue)."
        for key in customColors.keys where key.hasPrefix(prefix) {
            customColors.removeValue(forKey: key)
        }
        persistColors()
        configureUIKitSurfaces()
    }

    /// [P1-8-fix] The only place that advances the wallpaper revision:
    /// bump the in-memory counter (which drives view refresh via
    /// `@Published`) and persist the new value, so the revision survives
    /// a relaunch. A bare `wallpaperRevision += 1` would silently fork
    /// the persisted timeline and make `isPresetActive` lie after a
    /// restart — every wallpaper write path must go through here.
    private func bumpWallpaperRevision() {
        wallpaperRevision += 1
        liveWallpaperRevision = wallpaperRevision
        UserDefaults.standard.set(wallpaperRevision, forKey: Keys.wallpaperRevision)
    }

    /// [P2-5] Advance the global counter (the preset marker) and the
    /// per-scope counter(s) the backdrops' `.id()` reads. A global write
    /// bumps every scope — any page inheriting the global image shows a
    /// different picture. A single-scope write bumps only that scope.
    private func bumpWallpaperRevision(for scope: AppearanceScope) {
        bumpWallpaperRevision()
        if scope == .global {
            for s in AppearanceScope.allCases { wallpaperRevisionByScope[s, default: 0] += 1 }
        } else {
            wallpaperRevisionByScope[scope, default: 0] += 1
        }
    }

    /// Same as above for a multi-scope change (restore / reload).
    private func bumpAllWallpaperRevisions() {
        bumpWallpaperRevision()
        for s in AppearanceScope.allCases { wallpaperRevisionByScope[s, default: 0] += 1 }
    }

    /// [P2-5] Clear only the cache entry a write can stale. A scope's
    /// cached image is decoded from its own file or the global file, so
    /// a non-global write cannot stale any other scope's entry; a global
    /// write can stale every inheriting scope's, so it clears all. (`nil`
    /// results are never cached, so a cleared-fallback scope needs no
    /// clearing when the global image changes.)
    private func clearWallpaperCache(for scope: AppearanceScope) {
        if scope == .global {
            wallpaperCache.removeAllObjects()
        } else {
            wallpaperCache.removeObject(forKey: cacheKey(scope))
        }
    }

    /// [P1-8] 记下“刚应用了哪套预设、应用完颜色表长什么样、壁纸版本号
    /// 是多少”。只在这里写，所以 `isPresetActive` 的三项条件不会被
    /// 别的路悄悄改掉；任何一处改色、改壁纸，都会让 live 状态和这份
    /// 记录对不上，标记随即消失。
    private func recordActivePreset(_ preset: AppearancePreset) {
        activePresetRaw = preset.rawValue
        activePresetColors = customColors
        activePresetWallpaperRevision = wallpaperRevision
        // [P1-8-fix] Materialize the live side at record time: from here
        // on both legs of the comparison are known and equal.
        liveWallpaperRevision = wallpaperRevision
        UserDefaults.standard.set(wallpaperRevision, forKey: Keys.wallpaperRevision)
        UserDefaults.standard.set(preset.rawValue, forKey: Keys.activePreset)
        if let data = try? JSONEncoder().encode(customColors) {
            UserDefaults.standard.set(data, forKey: Keys.activePresetColors)
        }
        UserDefaults.standard.set(wallpaperRevision, forKey: Keys.activePresetWallpaperRevision)
    }

    /// 这套预设现在是不是还正在用：三项全中才算——（1）它是最后一次
    /// 应用的预设；（2）整张颜色表和应用那一刻一模一样（任何一处改色，
    /// 哪怕只改某一页的一个角色，表都会变）；（3）壁纸版本号没前进过
    /// （任何一张壁纸写/换/清都会让它前进）。版本号本身也落盘，重启后
    /// 接着比；老版本升上来、从没落盘过时这一项是 nil，标记直接消失，
    /// 不撒谎。纯靠 live 状态算，不存“正在用”这个结论本身，所以改色、
    /// 改壁纸、重启，都不会留下一个过期的标记。
    func isPresetActive(_ preset: AppearancePreset) -> Bool {
        guard preset.rawValue == activePresetRaw,
              let snapshot = activePresetColors,
              snapshot == customColors,
              liveWallpaperRevision == activePresetWallpaperRevision else { return false }
        return true
    }

    /// [composer-icons] 金色按键卡片的内存态：最后一次选了哪套。只在
    /// `applyComposerIcons` / `clearComposerIcons` 里写，启动时从
    /// UserDefaults 读回。标记本身不存“正在用”这个结论——`isComposerIconSetActive`
    /// 要记录和 pack 上的四个图字段都对上才算，换主题包清掉图字段时标记自己消失。
    private var activeComposerIconSetRaw: String? = UserDefaults.standard.string(forKey: Keys.composerIconSet)

    /// [composer-icons] 只写 pack 上的四个图字段，别的字段一行不动；
    /// 不走 applyThemePack 全量（那条会整包替换）。persistPack 会 bump
    /// themePackRevision 并发 objectWillChange，输入栏当场重画。
    func applyComposerIcons(_ set: ComposerIconSet) {
        var pack = currentThemePack()
        pack.composerMicImage = set.micImage
        pack.composerEmojiImage = set.emojiImage
        pack.composerSendImage = set.sendImage
        pack.composerPauseImage = set.pauseImage
        persistPack(pack)
        activeComposerIconSetRaw = set.rawValue
        UserDefaults.standard.set(set.rawValue, forKey: Keys.composerIconSet)
    }

    /// [composer-icons] 只清四个图字段，回到默认干净界面（系统符号）。
    func clearComposerIcons() {
        var pack = currentThemePack()
        pack.composerMicImage = nil
        pack.composerEmojiImage = nil
        pack.composerSendImage = nil
        pack.composerPauseImage = nil
        persistPack(pack)
        activeComposerIconSetRaw = nil
        UserDefaults.standard.removeObject(forKey: Keys.composerIconSet)
    }

    /// [composer-icons] 这套按键图现在是不是还正在用：记录和 live 的四个
    /// 图字段都对上才算。换主题包、恢复默认清掉图字段时标记随即消失。
    func isComposerIconSetActive(_ set: ComposerIconSet) -> Bool {
        guard set.rawValue == activeComposerIconSetRaw else { return false }
        let pack = currentThemePack()
        return pack.composerMicImage == set.micImage
            && pack.composerEmojiImage == set.emojiImage
            && pack.composerSendImage == set.sendImage
            && pack.composerPauseImage == set.pauseImage
    }

    /// [P0-4] 只清这一页 + 这一深浅的覆盖，带纯颜色撤销快照——和
    /// `clearNonGlobalColorOverridesWithUndo` 同一套机制（先抓整张颜色
    /// 表快照再清，撤销时原样恢复）。不能直接走那个 variant：它清的是
    /// 全部非全局覆盖，会把别的页也清掉。快照抓失败时不做任何清除，
    /// 旧快照作废，调用方必须报清除失败，不能谎称已清除。
    @discardableResult
    func clearOverridesWithUndo(scope: AppearanceScope, variant: AppearanceVariant) -> Bool {
        guard scope != .global else { return false }
        guard captureColorsUndoSnapshot() else {
            try? FileManager.default.removeItem(at: themeUndoDirectory)
            return false
        }
        clearOverrides(scope: scope, variant: variant)
        return true
    }

    func clearOverride(_ role: AppearanceColorRole, scope: AppearanceScope,
                       variant: AppearanceVariant) {
        customColors.removeValue(forKey: key(role, scope: scope, variant: variant))
        persistColors()
    }

    /// [audit-D6] True when any page-scoped (non-global) color override exists.
    /// Legacy builds' per-page editors wrote these, and the resolver still
    /// lets them win over the global palette; the theme page's Advanced
    /// section now lists them (see `nonGlobalColorOverrideSummaries`).
    var hasNonGlobalColorOverrides: Bool {
        let prefix = AppearanceScope.global.rawValue + "."
        return customColors.keys.contains { !$0.hasPrefix(prefix) }
    }

    /// One row per page that has colour overrides, for the theme page's
    /// override list (standing P0-4). Computed live from `customColors`,
    /// so it stays accurate after a library switch — replace mode keeps
    /// non-global colours, and a surviving chat-scoped red shows here
    /// instead of looking like the switch cleared it. Counts are per
    /// variant; role titles follow role order, legacy role names last.
    struct PageColorOverrideSummary: Identifiable {
        let scope: AppearanceScope
        let lightCount: Int
        let darkCount: Int
        let roleTitles: [String]
        var id: String { scope.rawValue }
    }

    func nonGlobalColorOverrideSummaries() -> [PageColorOverrideSummary] {
        AppearanceScope.allCases.filter { $0 != .global && $0.supportsColour }.compactMap { scope in
            var lightRoles = Set<String>()
            var darkRoles = Set<String>()
            for key in customColors.keys {
                let parts = key.split(separator: ".")
                guard parts.count == 3, parts[0] == scope.rawValue else { continue }
                if parts[1] == AppearanceVariant.light.rawValue {
                    lightRoles.insert(String(parts[2]))
                } else if parts[1] == AppearanceVariant.dark.rawValue {
                    darkRoles.insert(String(parts[2]))
                }
            }
            guard !lightRoles.isEmpty || !darkRoles.isEmpty else { return nil }
            let ordered = AppearanceColorRole.allCases
                .filter { lightRoles.contains($0.rawValue) || darkRoles.contains($0.rawValue) }
                .map { $0.title }
            let legacy = lightRoles.union(darkRoles)
                .filter { AppearanceColorRole(rawValue: $0) == nil }
                .sorted()
            return PageColorOverrideSummary(
                scope: scope,
                lightCount: lightRoles.count,
                darkCount: darkRoles.count,
                roleTitles: ordered + legacy)
        }
    }

    /// [audit-D6] Drop every non-global color override, keeping the user's
    /// global palette. Before this, the only way to clear a stray page-scope
    /// key was「恢复默认色盘」, which wipes the whole palette with it.
    func clearNonGlobalColorOverrides() {
        let prefix = AppearanceScope.global.rawValue + "."
        customColors = customColors.filter { $0.key.hasPrefix(prefix) }
        persistColors()
        configureUIKitSurfaces()
    }

    /// Replaces the whole color override map. Used by theme undo, which has
    /// to put back the exact palette a reset wiped — including its absence.
    func restoreColorOverrides(_ overrides: [String: String]) {
        customColors = overrides
        persistColors()
        configureUIKitSurfaces()
    }

    /// Read-only view of the raw override map, for the theme undo snapshot.
    /// `exportColors` cannot serve here: it resolves every role to a concrete
    /// hex, which would turn "never overridden" into a hard-coded value and
    /// make the restored palette diverge from the original.
    func exportColorOverrides() -> [String: String] {
        customColors
    }

    func applyPreset(_ preset: AppearancePreset) {
        // [T-05] 以前只写预设表里列出的角色：上一套设过的壳字、最淡小字
        // 会原样留着，切完预设等于两套颜色混在一起。预设是「整套配色」，
        // 先把全局覆盖清干净再写（页级覆盖不动——那是另一层）。
        for variant in AppearanceVariant.allCases {
            let prefix = "\(AppearanceScope.global.rawValue).\(variant.rawValue)."
            for key in customColors.keys where key.hasPrefix(prefix) {
                customColors.removeValue(forKey: key)
            }
        }
        let palettes = preset.colors
        for variant in AppearanceVariant.allCases {
            let values = variant == .light ? palettes.light : palettes.dark
            for (role, hex) in values {
                customColors[key(role, scope: .global, variant: variant)] = hex
            }
        }
        persistColors()
        recordActivePreset(preset)
        configureUIKitSurfaces()
    }

    /// [10-18 醒醒] 摇一套配色。只写全局键，不碰页级覆盖——
    /// 她单独调过的某一页不该被一次"摇骰子"冲掉。
    ///
    /// `mood` 传 nil 就随机挑一个风格（连点几次每次调子都不同）。
    /// 返回这套的默认名字，页面上可以拿它当"存这套"的默认值。
    @discardableResult
    func shuffleTheme(seed: UInt64? = nil,
                      mood: AppearanceThemeShuffle.Mood? = nil) -> String {
        let rolled = AppearanceThemeShuffle.shuffle(seed: seed, mood: mood)
        for variant in AppearanceVariant.allCases {
            let values = variant == .light ? rolled.light : rolled.dark
            for (role, hex) in values {
                customColors[key(role, scope: .global, variant: variant)] = hex
            }
        }
        persistColors()
        configureUIKitSurfaces()
        return rolled.name
    }

    /// 把预览过的两套色写进全局配色并持久化（2026-11-02 摇色预览批：
    /// 摇色预览的"留下来"走这里）。只写全局键，不碰页级覆盖——
    /// 她单独调过的某一页不该被一次"摇骰子"冲掉；写色循环与
    /// shuffleTheme 同一条，语义一致。
    func applyRolledPalette(light: [AppearanceColorRole: String],
                            dark: [AppearanceColorRole: String]) {
        for variant in AppearanceVariant.allCases {
            let values = variant == .light ? light : dark
            for (role, hex) in values {
                customColors[key(role, scope: .global, variant: variant)] = hex
            }
        }
        persistColors()
        configureUIKitSurfaces()
    }

    /// [T-46] 恢复默认配色**不再碰**透明度和压色。
    ///
    /// 原来这三行会悄悄把它们改回 0.88 / 1.0 / 0.08，而界面上根本没有入口
    /// （唯一那根滑杆在死页里），所以她永远看不到自己调过的值被抹掉，也
    /// 不知道为什么卡片忽然变实了。现在只清颜色，三个旋钮各归各的按钮改。
    func resetColors() {
        customColors.removeAll()
        persistColors()
        configureUIKitSurfaces()
    }

    /// 三个旋钮回到出厂值。单独一个动作，界面上有按钮，改之前问一声。
    func resetOpacityDials() {
        surfaceOpacity = 0.88
        bubbleOpacity = 1.0
        wallpaperShade = 0.08
    }

    /// Drag-time only: set one opacity dial's in-memory value and notify
    /// observers (live preview follows) without writing UserDefaults on
    /// every tick. Pair with `commitOpacityDials()` on release so the
    /// final value is persisted exactly once. A crash mid-drag loses at
    /// most the in-flight drag value; the last committed value is kept.
    func setSurfaceOpacityLive(_ value: Double) {
        suppressDialPersist = true
        surfaceOpacity = value
        suppressDialPersist = false
    }

    /// Same drag-time contract as `setSurfaceOpacityLive(_:)`, for the
    /// bubble dial.
    func setBubbleOpacityLive(_ value: Double) {
        suppressDialPersist = true
        bubbleOpacity = value
        suppressDialPersist = false
    }

    /// Same drag-time contract as `setSurfaceOpacityLive(_:)`, for the
    /// wallpaper-shade dial.
    func setWallpaperShadeLive(_ value: Double) {
        suppressDialPersist = true
        wallpaperShade = value
        suppressDialPersist = false
    }

    /// Persist the three opacity dials' current in-memory values to
    /// UserDefaults, once (slider release). Writing all three is
    /// harmless: only one dial moves at a time, the other two write
    /// back the value they already hold. Also notifies observers:
    /// `surfaceOpacitySnapshot` reads UserDefaults directly, and the
    /// live-drag path deliberately skipped the didSet write, so
    /// without this send the snapshot readers (HelperBlockView's
    /// barBg/cardBg) would keep the pre-drag value until some
    /// unrelated notification re-rendered them.
    func commitOpacityDials() {
        UserDefaults.standard.set(surfaceOpacity, forKey: Keys.surfaceOpacity)
        UserDefaults.standard.set(bubbleOpacity, forKey: Keys.bubbleOpacity)
        UserDefaults.standard.set(wallpaperShade, forKey: Keys.wallpaperShade)
        objectWillChange.send()
    }

    /// Clear ONLY the global colour overrides, back to the built-in
    /// palette. Unlike `resetColors()` (which also wipes every
    /// page-scoped override and the opacity/shade dials), this is
    /// what the shop colour panel's "恢复默认配色" means: her
    /// per-page tweaks stay, the global palette goes neutral.
    func resetGlobalColors() {
        let prefix = AppearanceScope.global.rawValue + "."
        customColors = customColors.filter { !$0.key.hasPrefix(prefix) }
        persistColors()
        configureUIKitSurfaces()
    }

    /// [F3] 只清全局配色、带撤销：中心页底部「恢复默认调色板」接这里。
    /// 先抓一份纯颜色撤销快照（和 `clearNonGlobalColorOverridesWithUndo`
    /// 同一套机制：只存当前颜色表 + "colors-only" 标记），再清全局键，
    /// 这样 toast 里的「（可撤销）」还是真的，撤销时原样恢复这一刀
    /// 清掉的颜色表——包括她的分页微调。抓快照失败时不留下旧快照
    /// （否则撤销会恢复一次根本没抓过的旧状态），重置本身照常跑，
    /// 和现在按钮的行为一致。
    /// Returns true when an undo snapshot was captured; on false the stale
    /// snapshot (if any) is invalidated and the caller must show the
    /// no-undo toast instead of promising undo.
    @discardableResult
    func resetGlobalColorsWithUndo() -> Bool {
        if !captureColorsUndoSnapshot() {
            try? FileManager.default.removeItem(at: themeUndoDirectory)
            resetGlobalColors()
            return false
        }
        resetGlobalColors()
        return true
    }

    /// 纯颜色撤销快照，和 AppearanceThemePack.swift 里
    /// `captureColorOnlyUndoSnapshot` 同款（那个是 private，只能在
    /// 那个文件里用，所以全局重置这条路要自己抓一份）：当前颜色表
    /// 写进暂存目录再原子换进快照目录。只在真抓失败（建不出暂存
    /// 目录、颜色写不进去）时返回 false。
    private func captureColorsUndoSnapshot() -> Bool {
        let dir = themeUndoDirectory
        let scratch = dir.deletingLastPathComponent()
            .appendingPathComponent(".undo-staging", isDirectory: true)
        try? FileManager.default.removeItem(at: scratch)
        guard (try? FileManager.default.createDirectory(at: scratch,
                                                        withIntermediateDirectories: true)) != nil else {
            return false
        }
        let overrides: [String: String] = exportColorOverrides()
        guard let colors = try? JSONEncoder().encode(overrides),
              (try? colors.write(to: scratch.appendingPathComponent("colors.json"), options: .atomic)) != nil,
              (try? "1".write(to: scratch.appendingPathComponent("colors-only"), atomically: true, encoding: .utf8)) != nil else {
            try? FileManager.default.removeItem(at: scratch)
            return false
        }
        // 快照完整了再换掉旧的，抓一半失败不会毁掉上一次的撤销。
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.moveItem(at: scratch, to: dir)
        return FileManager.default.fileExists(atPath: dir.appendingPathComponent("colors.json").path)
    }

    private func persistColors() {
        // [T-73c] 拖色盘时每一帧都会走这里：以前每次都把整张颜色表编码
        // 一次、写一次 UserDefaults（几十个键的字典，主线程上）。屏幕上
        // 立刻要变的部分（快照 + 视图刷新）照旧同步做，落盘合并成一次 ——
        // 停下来 0.4 秒后才写，中途被系统杀掉最多丢最后 0.4 秒的拖动。
        Self.colorSnapshot = customColors
        objectWillChange.send()
        // [T-08] 颜色一变就把主题快照写进 App Group,桌面小组件才跟得上。
        // 这里是唯一一处写颜色的出口(用户面板、AI、主题包都走 setColor),
        // 所以挂在这儿不会漏。
        WidgetProfileBridge.scheduleThemeRefresh()
        scheduleColorPersist()
    }

    /// [T-73c] 合并落盘。非拖动场景（AI 一次写一个色）只多等 0.4 秒。
    private var colorPersistPending = false

    private func scheduleColorPersist() {
        guard !colorPersistPending else { return }
        colorPersistPending = true
        // Swift 6：用 Task 回到主 actor，别在非隔离的 DispatchQueue 闭包里
        // 直接调 @MainActor 的方法。
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard let self, self.colorPersistPending else { return }
            self.colorPersistPending = false
            self.writeColorsNow()
        }
    }

    /// 真的写盘。退出/切后台时也该调它，免得最后 0.4 秒丢掉。
    func flushColorPersist() {
        guard colorPersistPending else { return }
        colorPersistPending = false
        writeColorsNow()
    }

    private func writeColorsNow() {
        guard let data = try? JSONEncoder().encode(customColors) else { return }
        UserDefaults.standard.set(data, forKey: Keys.colors)
    }

    /// Safe for UIKit callbacks. Resolves chat-scoped roles without hopping the actor.
    nonisolated static func uiColorSnapshot(_ role: AppearanceColorRole,
                                            scope: AppearanceScope = .chat) -> UIColor {
        let variant: AppearanceVariant = {
            switch AppearanceMode.current {
            case .light: return .light
            case .dark: return .dark
            case .system: return UITraitCollection.current.userInterfaceStyle == .dark ? .dark : .light
            }
        }()
        return UIColor(hex: snapshotHex(role, scope: scope, variant: variant))
    }

    /// 快照解析：给非主线程和 UIKit 动态色闭包用的纯函数。
    ///
    /// 和 `hex(_:scope:variant:)` 必须保持同一套回退规则（自己的键 → 老键 →
    /// 全局 → 内置），否则同一块颜色在主线程和快照路径会不一样。老键回退
    /// 那条注释就是上一轮踩出来的，别删。
    nonisolated static func snapshotHex(_ role: AppearanceColorRole,
                                        scope: AppearanceScope = .global,
                                        variant: AppearanceVariant) -> String {
        let snap = colorSnapshot
        let scoped = "\(scope.rawValue).\(variant.rawValue).\(role.rawValue)"
        let global = "\(AppearanceScope.global.rawValue).\(variant.rawValue).\(role.rawValue)"
        // 老键回退：field 接 input/searchField，surface 接 toolCard。
        func legacy(_ raw: String) -> String? {
            let s = "\(scope.rawValue).\(variant.rawValue).\(raw)"
            let g = "\(AppearanceScope.global.rawValue).\(variant.rawValue).\(raw)"
            return snap[s] ?? snap[g]
        }
        let legacyValue: String? = {
            switch role {
            case .field: return legacy("input") ?? legacy("searchField")
            case .surface: return legacy("toolCard")
            default: return nil
            }
        }()
        // [bubble-grouping] Same primaryText fallback as hex(), so the
        // snapshot path (UIKit dynamic colours, non-main threads) agrees
        // with the main-thread path. Recursion terminates at primaryText.
        if role == .bubbleText || role == .assistantBubbleText {
            return snap[scoped] ?? snap[global] ?? snapshotHex(.primaryText, scope: scope, variant: variant)
        }
        return snap[scoped] ?? snap[global] ?? legacyValue
            ?? (variant == .light ? AppearancePaletteBook.light : AppearancePaletteBook.dark)[role]
            ?? "808080"
    }

    // MARK: Wallpaper

    var appearanceDirectory: URL { Self.appearanceDirectoryURL }

    /// Static twin of `appearanceDirectory`: init-time helpers that run
    /// before all stored properties are initialized (the PIC-6 icon
    /// migration/load) resolve the same directory without touching `self`.
    /// `nonisolated`: the body is a pure path computation plus an
    /// idempotent directory creation, and off-main callers (the backup
    /// system) need the path without an actor hop.
    private nonisolated static var appearanceDirectoryURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first!
        let dir = base.appendingPathComponent("AppearanceStudio", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// [PIC-2] The directory the backup system archives wholesale for the
    /// Appearance category: every wallpaper, category / card image,
    /// custom icon and saved-theme pack lives under it.
    nonisolated static var appearanceAssetsDirectory: URL { appearanceDirectoryURL }

    private func wallpaperURL(_ scope: AppearanceScope) -> URL {
        appearanceDirectory.appendingPathComponent("wallpaper-\(scope.rawValue).jpg")
    }

    /// [T-54] 分档壁纸文件。
    ///
    /// 审计的原症状：透明 PNG 只在**拾取那一刻**垫一次底色。那时候垫的是
    /// 当时的档位色，之后切成另一档，文件里留的还是旧档配色，暗色内容
    /// 周围就是一圈惨白。修法取"存分档文件"：拾取时检测到 alpha，就按浅/
    /// 深两档的画布色各压一份，渲染时按当前档位挑。不依赖源文件还在。
    private func wallpaperURL(_ scope: AppearanceScope, variant: AppearanceVariant) -> URL {
        appearanceDirectory.appendingPathComponent("wallpaper-\(scope.rawValue)-\(variant.rawValue).jpg")
    }

    /// [T-54] 一个作用域可能的三个文件：旧单文件 + 浅/深两档。
    /// 快照、恢复、清除都必须按这三个来，漏一个就是"清了还在"。
    private func wallpaperURLs(_ scope: AppearanceScope) -> [URL] {
        [wallpaperURL(scope),
         wallpaperURL(scope, variant: .light),
         wallpaperURL(scope, variant: .dark)]
    }

    /// 这张图带不带透明区域。带的话单份 JPEG 一定会把某一种档位垫错。
    /// [P2-3] Pure pixel-format check; safe to call off the main thread.
    nonisolated private static func hasAlpha(_ image: UIImage) -> Bool {
        guard let cg = image.cgImage else { return false }
        switch cg.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: return true
        }
    }

    /// [T-31] "有壁纸"以能不能解码为准，不以文件在不在为准。
    ///
    /// 零字节或坏文件以前让文案说"有壁纸"、渲染却是纯色底，用户只能自己
    /// 找到清除才恢复。这里共用 wallpaper(for:) 的解码结果（带着缓存，
    /// 不会每次调用都真解一遍图）。
    func hasWallpaper(_ scope: AppearanceScope) -> Bool {
        wallpaper(for: scope) != nil
    }

    func hasOwnWallpaper(_ scope: AppearanceScope) -> Bool {
        let fm = FileManager.default
        return [wallpaperURL(scope),
                wallpaperURL(scope, variant: .light),
                wallpaperURL(scope, variant: .dark)].contains { fm.fileExists(atPath: $0.path) }
    }

    /// [T-25] 这一页自己的壁纸文件叫什么。给 AI 子命令报原值用——
    /// 只说"会覆盖这一页的图"不够，得说清盖掉的是哪一张。没有就 nil。
    func ownWallpaperFileName(_ scope: AppearanceScope) -> String? {
        // [T-54 r2] 带透明的壁纸只存分档文件，旧单文件被删掉了。只看旧
        // 名字就会答"这一页没有自己的图"，可它明明有——AI 报原值时说的是
        // 假话，`hadOwnWallpaper` 也跟着假。先当前档，再另一档，最后旧名。
        let fm = FileManager.default
        for variant in [activeVariant, .light, .dark] {
            let url = wallpaperURL(scope, variant: variant)
            if fm.fileExists(atPath: url.path) { return url.lastPathComponent }
        }
        let legacy = wallpaperURL(scope)
        return fm.fileExists(atPath: legacy.path) ? legacy.lastPathComponent : nil
    }

    func wallpaper(for scope: AppearanceScope) -> UIImage? {
        if let cached = wallpaperCache.object(forKey: cacheKey(scope)) { return cached }
        // [T-54] 先看当前档位的那一份；没有才回落到旧的单文件。
        let fm = FileManager.default
        let ownVariant = wallpaperURL(scope, variant: activeVariant)
        let own = fm.fileExists(atPath: ownVariant.path) ? ownVariant : wallpaperURL(scope)
        // [T-wallpaper-clear] A cleared page never inherits the global image.
        // [batch7 用户-P2-9] 底部栏同样永不继承：无专属图时返回 nil（纯透明），
        // 不拿全局图来凑。
        let globalVariant = wallpaperURL(.global, variant: activeVariant)
        let globalLegacy = wallpaperURL(.global)
        let globalURL = fm.fileExists(atPath: globalVariant.path) ? globalVariant : globalLegacy
        let fallbackURL = (scope == .global || scope == .bottomBar
                           || wallpaperClearedFallback.contains(scope))
            ? nil : globalURL
        // [T-31] 解不出来的文件记一笔，免得每次渲染都重新解码一张坏图。
        if wallpaperUnreadable.contains(scope) { return nil }
        let url = FileManager.default.fileExists(atPath: own.path)
            ? own
            : (fallbackURL.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil })
        guard let url else { return nil }
        guard let data = try? Data(contentsOf: url),
              let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 else {
            wallpaperUnreadable.insert(scope)
            return nil
        }
        wallpaperCache.setObject(image, forKey: cacheKey(scope), cost: image.cacheCost)
        return image
    }

    /// [P3-1] `setWallpaper(_ image:)` 的接班人：同一个写盘结果，解码 +
    /// 渲染 + 编码离主线程。UIImage 不是 Sendable（Swift 6），不能进
    /// detached 任务 —— 过边界的只有文件 URL，UIImage 在任务里现解。
    /// 返回合同与旧方法一字不差：解不出 / 编不出 / 写不进都回 false，
    /// 调用方照旧如实失败（B28 R2-2：不再撒谎的沉默）。
    @discardableResult
    func setWallpaperFile(at url: URL, for scope: AppearanceScope, dark: Bool = false) async -> Bool {
        // [T-54] 与旧方法同一条写盘顺序：带透明的图按档位各存一份，
        // 不透的图维持单文件。只进不退的差别是渲染在 detached 任务里做。
        let prepared = await Task.detached(priority: .utility) { () -> (light: Data, dark: Data?)? in
            guard let image = WallpaperPipeline.decodedImage(at: url) else { return nil }
            if Self.hasAlpha(image) {
                guard let light = Self.backgroundJPEG(image, dark: false),
                      let darkData = Self.backgroundJPEG(image, dark: true) else { return nil }
                return (light, darkData)
            }
            guard let data = Self.backgroundJPEG(image, dark: dark) else { return nil }
            return (data, nil)
        }.value
        guard let prepared else { return false }
        // 局部变量名与旧方法一致：T-54 测试断言钉的就是
        // "writeWallpaperData(light, for: scope, variant: .light)" 这两行。
        let light = prepared.light
        let darkData = prepared.dark
        if let darkData {
            guard writeWallpaperData(light, for: scope, variant: .light),
                  writeWallpaperData(darkData, for: scope, variant: .dark) else { return false }
            // 旧单文件必须删掉，否则它会先被读到、又是旧配色。
            try? FileManager.default.removeItem(at: wallpaperURL(scope))
            return true
        }
        // [P2-6] 返回写盘的真实结果，不再无条件回 true。
        return writeWallpaperData(light, for: scope)
    }

    /// Stores wallpaper bytes that are already encoded.
    ///
    /// A pack carries a JPEG; decoding it into a UIImage and re-encoding
    /// threw away a generation and inflated the file. Re-encoding now only
    /// happens when the image is larger than the wallpaper edge limit, or
    /// when the format has no byte-level strip (HEIC/GIF).
    /// Under-limit bytes land as-is, metadata stripped (P2-13).
    ///
    /// [P2-3] Decode + downscale + encode run off the main thread (a 48MP
    /// pick used to expand to ~200MB of bitmap on MainActor). Only the
    /// prepared bytes cross back; the disk write + revision bump stay on
    /// the main actor, in the same order, with the same return values.
    @discardableResult
    func setWallpaperEncoded(_ data: Data, for scope: AppearanceScope,
                             darkData: Data? = nil) async -> Bool {
        // [T-29] 解不出来的字节不许落盘。以前原样写进 wallpaper-<scope>.jpg
        // 再回 true：文件在、hasWallpaper 也真，渲染却是纯色底，只有手动
        // 清除能救回来。现在直接失败，让调用方（主题包流程）追加 warning。
        // [T-55] 解码验证和一起听同一个入口（`WallpaperPipeline.decodedImage`）。
        let prepared = await Task.detached(priority: .utility) {
            Self.prepareWallpaper(data, darkData: darkData)
        }.value
        switch prepared {
        case .badLight:
            appearanceLog.warning("wallpaper bytes for \(scope.rawValue) do not decode; nothing written")
            return false
        case .badDark:
            appearanceLog.warning("dark wallpaper bytes for \(scope.rawValue) do not decode; nothing written")
            return false
        case .encodeFailed:
            return false
        case let .ready(lightJPEG, darkJPEG):
            // [T-54 r2] 主题包带了第二档：两档各写各的文件，再删旧单文件。
            // 只写单份的话，浅色档导出、别人导入、切深色档，读到的还是浅色
            // 垫的那张——T-54 的原症状换了个入口。
            if let darkJPEG {
                guard writeWallpaperData(lightJPEG, for: scope, variant: .light),
                      writeWallpaperData(darkJPEG, for: scope, variant: .dark) else { return false }
                try? FileManager.default.removeItem(at: wallpaperURL(scope))
                return true
            }
            return writeWallpaperData(lightJPEG, for: scope)
        }
    }

    /// Result of off-main-thread wallpaper preparation: decode +
    /// downscale + encode. Only Data crosses back to the main actor — a
    /// UIImage must never cross into a detached task (Swift 6: UIImage is
    /// not Sendable; the BubblePacks store keeps the same Data-only rule).
    private enum WallpaperPrep {
        case ready(light: Data, dark: Data?)
        case badLight, badDark, encodeFailed
    }

    /// Pure preparation for `setWallpaperEncoded`, run on a detached task:
    /// decode validation, oversize downscale + re-encode. Write order and
    /// return values are unchanged — this only decides which bytes the
    /// main actor writes. The oversize-single rule mirrors `setWallpaper`:
    /// an alpha image needs both variants, otherwise one light file.
    nonisolated private static func prepareWallpaper(_ data: Data, darkData: Data?) -> WallpaperPrep {
        guard let image = WallpaperPipeline.decodedImage(data) else { return .badLight }
        if let darkData {
            guard let darkImage = WallpaperPipeline.decodedImage(darkData) else { return .badDark }
            // [P2-4] Orientation must be baked before the tag is stripped:
            // a stripped file with orientation != up would come back rotated.
            let lightJPEG = max(image.size.width, image.size.height) > WallpaperPipeline.maxEdge
                || !WallpaperPipeline.byteLevelStrippable(data)
                || image.imageOrientation != .up
                ? backgroundJPEG(image, dark: false) : WallpaperPipeline.strippedMetadata(data)
            let darkJPEG = max(darkImage.size.width, darkImage.size.height) > WallpaperPipeline.maxEdge
                || !WallpaperPipeline.byteLevelStrippable(darkData)
                || darkImage.imageOrientation != .up
                ? backgroundJPEG(darkImage, dark: true) : WallpaperPipeline.strippedMetadata(darkData)
            guard let lightJPEG, let darkJPEG else { return .encodeFailed }
            return .ready(light: lightJPEG, dark: darkJPEG)
        }
        // [P2-4] Orientation must be baked before the tag is stripped (same
        // as the pair above): an under-limit photo with orientation != up
        // takes this re-encode branch instead of the strip below.
        if max(image.size.width, image.size.height) > WallpaperPipeline.maxEdge
            || !WallpaperPipeline.byteLevelStrippable(data)
            || image.imageOrientation != .up {
            if hasAlpha(image) {
                guard let light = backgroundJPEG(image, dark: false),
                      let dark = backgroundJPEG(image, dark: true) else { return .encodeFailed }
                return .ready(light: light, dark: dark)
            }
            guard let jpeg = backgroundJPEG(image, dark: false) else { return .encodeFailed }
            return .ready(light: jpeg, dark: nil)
        }
        // [P2-13] Under-limit JPEG/PNG/WebP bytes land as-is, metadata
        // stripped byte-for-byte — pixels untouched, no re-encode, no
        // quality change. HEIC/GIF have no byte-level strip, so they
        // took the re-encode branch above instead: otherwise their EXIF
        // would ride in unchanged. An image whose orientation is not up
        // takes that branch too (P2-4), so the bytes stripped here are
        // always orientation-up.
        // Suffix note: wallpaper files are always named *.jpg. HEIC/GIF
        // now land as real JPEG bytes, so the name is honest for them;
        // WebP/PNG still land as their own bytes under a .jpg name —
        // the same as PNG always did — and every reader sniffs content
        // (`fileExtension(forHead:)`), never the suffix.
        return .ready(light: WallpaperPipeline.strippedMetadata(data), dark: nil)
    }

    @discardableResult
    private func writeWallpaperData(_ data: Data, for scope: AppearanceScope,
                                    variant: AppearanceVariant? = nil) -> Bool {
        // [B28 R2-2] 写失败（磁盘满、目录异常）以前被 try? 吃掉。现在报出去。
        do {
            let dest = variant.map { wallpaperURL(scope, variant: $0) } ?? wallpaperURL(scope)
            try data.write(to: dest, options: .atomic)
        } catch {
            appearanceLog.warning("wallpaper write failed for \(scope.rawValue): \(error.localizedDescription)")
            return false
        }
        // [T-54 r2] 单文件落盘＝这一页没有分档。旧的 -light/-dark 必须
        // 一起删，否则读取时它们排在前面，用户换了不透明图、切档看到的
        // 还是上一张透明图垫出来的样子。
        if variant == nil {
            for stale in [wallpaperURL(scope, variant: .light),
                          wallpaperURL(scope, variant: .dark)] {
                try? FileManager.default.removeItem(at: stale)
            }
        }
        // [T-wallpaper-clear] Choosing a new image re-enables global
        // fallback for this scope (the clear only sticks until overridden).
        // A new GLOBAL image re-enables it for every page: a page cleared
        // earlier must not keep ignoring the global wallpaper the user
        // just picked (same removeAll() removeWallpaper(.global) does).
        if scope == .global {
            wallpaperClearedFallback.removeAll()
        } else {
            wallpaperClearedFallback.remove(scope)
        }
        persistWallpaperCleared()
        // [P1-1] A successful write clears ALL unreadable marks, not just
        // this scope's: the mark records the requesting scope even when
        // the file that failed to decode was the global fallback, so a
        // scope-only clear leaves poisoned scopes behind forever. Same
        // removeAll() removeWallpaper / clearWallpaper already use; a
        // still-broken file is simply re-marked on the next read.
        wallpaperUnreadable.removeAll()
        clearWallpaperCache(for: scope)
        bumpWallpaperRevision(for: scope)
        return true
    }

    func removeWallpaper(_ scope: AppearanceScope) {
        // [T-54] 三份都要删：单文件 + 浅/深两档。漏一份就是"清了还在"。
        try? FileManager.default.removeItem(at: wallpaperURL(scope))
        try? FileManager.default.removeItem(at: wallpaperURL(scope, variant: .light))
        try? FileManager.default.removeItem(at: wallpaperURL(scope, variant: .dark))
        // [B28 R2-9] 恢复继承就得把"不继承"标记一起清掉 —— 以前只删文件
        // 不清标记，用户选了"跟随全局"，全局图却不出现：状态和承诺不符。
        if scope == .global {
            wallpaperClearedFallback.removeAll()
        } else {
            wallpaperClearedFallback.remove(scope)
        }
        persistWallpaperCleared()
        wallpaperUnreadable.removeAll()
        clearWallpaperCache(for: scope)
        bumpWallpaperRevision(for: scope)
    }

    /// Removes every scope's wallpaper through the proper path, so a
    /// theme reset cannot leave a per-scope image behind: each call
    /// deletes the file, clears that scope's cleared-fallback flag,
    /// clears the wallpaper cache, and bumps the revision. Calling
    /// removeWallpaper(.global) also clears every fallback flag, so
    /// order over allCases does not matter for the final state.
    func removeAllScopeWallpapers() {
        for scope in AppearanceScope.allCases {
            removeWallpaper(scope)
        }
    }

    /// Copies every scope's own wallpaper file plus the cleared-fallback
    /// list into a reset snapshot directory. The cleared list is written
    /// even when empty: its presence is the marker that this snapshot
    /// captured wallpapers, so an older snapshot (or a palette-only
    /// snapshot) without it is never mistaken for one.
    func captureWallpapers(into dir: URL) {
        for scope in AppearanceScope.allCases where hasOwnWallpaper(scope) {
            // [T-54] 三份都搬，只搬旧单文件的话，透明图快照回来就丢了分档。
            for src in wallpaperURLs(scope) where FileManager.default.fileExists(atPath: src.path) {
                try? FileManager.default.copyItem(
                    at: src, to: dir.appendingPathComponent(src.lastPathComponent))
            }
        }
        let cleared = Array(wallpaperClearedFallback.map(\.rawValue))
        if let data = try? JSONEncoder().encode(cleared) {
            try? data.write(to: dir.appendingPathComponent("wallpaper-cleared.json"),
                            options: .atomic)
        }
    }

    /// Restores wallpapers from a reset snapshot, exactly: captured
    /// files are copied back, scopes with no captured file have any
    /// current file removed, and the cleared-fallback list is restored.
    /// No-ops entirely when the snapshot has no wallpaper-cleared.json
    /// (older or palette-only snapshots must not wipe live wallpapers).
    func restoreWallpapers(from dir: URL) {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("wallpaper-cleared.json")),
              let raw = try? JSONDecoder().decode([String].self, from: data) else {
            return
        }
        wallpaperClearedFallback = Set(raw.compactMap(AppearanceScope.init(rawValue:)))
        persistWallpaperCleared()
        for scope in AppearanceScope.allCases {
            // [T-54] 逐份对齐：快照里有就恢复，没有就把本机那份删掉。
            for dst in wallpaperURLs(scope) {
                let src = dir.appendingPathComponent(dst.lastPathComponent)
                if FileManager.default.fileExists(atPath: src.path) {
                    try? FileManager.default.removeItem(at: dst)
                    try? FileManager.default.copyItem(at: src, to: dst)
                } else {
                    try? FileManager.default.removeItem(at: dst)
                }
            }
        }
        // [P1-1] Restoring files makes old unreadable marks stale (a
        // restored-but-broken file is re-marked on the next read), so
        // clear them like removeWallpaper / clearWallpaper already do.
        wallpaperUnreadable.removeAll()
        wallpaperCache.removeAllObjects()
        bumpAllWallpaperRevisions()
    }

    /// [T-wallpaper-clear] "清除当前背景" — drop this page's wallpaper AND
    /// cut the global inheritance so the page returns to its initial plain
    /// canvas. Distinct from `removeWallpaper` ("改用继承的背景"), which only
    /// drops the page's own image and lets the global one take over.
    /// [B28 R2-9] UI 三选一的状态查询：这一页是不是主动掐了继承。
    func wallpaperClearsGlobal(_ scope: AppearanceScope) -> Bool {
        wallpaperClearedFallback.contains(scope)
    }

    func clearWallpaper(_ scope: AppearanceScope) {
        for url in wallpaperURLs(scope) { try? FileManager.default.removeItem(at: url) }
        if scope != .global { wallpaperClearedFallback.insert(scope) }
        persistWallpaperCleared()
        wallpaperUnreadable.removeAll()
        clearWallpaperCache(for: scope)
        bumpWallpaperRevision(for: scope)
    }

    /// [batch7 用户-P2-11] 恢复对齐：清除标记为准。恢复是 merge 语义（包里
    /// 没提的文件原位保留），但清除标记恢复回来后、标记对应的本机壁纸文件
    /// 若还在，"清除"就被悄悄撤销、标记变死标记。所以：包里没带某 scope
    /// 壁纸文件、清除标记里却有它时，把本机残留的该文件删掉；包里带了的
    /// scope 不动（显式内容优先）。
    func reconcileClearedWallpapersAfterRestore(packagedScopes: Set<AppearanceScope>) {
        var removed = false
        for scope in wallpaperClearedFallback where scope != .global {
            guard !packagedScopes.contains(scope) else { continue }
            for url in wallpaperURLs(scope) where FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.removeItem(at: url)
                removed = true
            }
        }
        if removed {
            wallpaperCache.removeAllObjects()
            bumpAllWallpaperRevisions()
        }
    }

    private func persistWallpaperCleared() {
        let raw = wallpaperClearedFallback.map(\.rawValue)
        UserDefaults.standard.set(raw, forKey: Self.wallpaperClearedKey)
    }

    private func loadWallpaperCleared() {
        let raw = UserDefaults.standard.stringArray(forKey: Self.wallpaperClearedKey) ?? []
        wallpaperClearedFallback = Set(raw.compactMap(AppearanceScope.init(rawValue:)))
    }

    /// [T-8/T-54/T-55] 主壁纸编码。缩放、压色、质量全在 `WallpaperPipeline`
    /// 那一份里，这里只负责挑垫底的颜色。
    ///
    /// [PIC-8] Matte follows the color scheme: a transparent PNG set in dark
    /// mode used to be flattened onto the light canvas color, leaving a pale
    /// fringe around dark content. [T-54] 这一条就是审计说的"透明 PNG 烘焙
    /// 底色"——垫的是画布色而不是写死的白，所以换明暗不会留下一圈亮边。
    /// [P2-3] Runs off the main thread (see `prepareWallpaper`): only
    /// immutable statics are read here, no actor state.
    nonisolated private static func backgroundJPEG(_ image: UIImage, dark: Bool = false) -> Data? {
        let book = dark ? darkDefaults : lightDefaults
        let matte = UIColor(hex: book[.canvas] ?? (dark ? "000000" : "F5F5F7"))
        return WallpaperPipeline.jpeg(image, matte: matte)
    }

    // MARK: Paired avatars

    /// Load the user avatar, migrating a legacy inline data URI to a file
    /// once. After migration UserDefaults holds only the relative path.
    private func loadUserAvatar() {
        let raw = UserDefaults.standard.string(forKey: Keys.userAvatar) ?? ""
        if SoulIconImage.isDataURI(raw),
           let path = SoulIconImage.migrateDataURIToFile(raw, named: "user") {
            UserDefaults.standard.set(path, forKey: Keys.userAvatar)
            userAvatar = path
        } else {
            userAvatar = raw
        }
    }

    func setUserAvatar(_ image: UIImage) {
        if case .success(let path) = SoulIconImage.store(image, named: "user") {
            userAvatar = path
            UserDefaults.standard.set(path, forKey: Keys.userAvatar)
        }
    }

    func removeUserAvatar() {
        // 只清引用不够：文件还躺在 Application Support/avatars/user.png。
        // userAvatar 是相对路径引用，fileURL 会校验格式（avatars/<名>.png，
        // 无 ..、无嵌套），删不到别处；删失败就静默跳过，引用照样清掉。
        if let url = SoulIconImage.fileURL(forReference: userAvatar) {
            try? FileManager.default.removeItem(at: url)
        }
        userAvatar = ""
        UserDefaults.standard.removeObject(forKey: Keys.userAvatar)
    }

    /// [B28 R10] 存她填的称呼。空串 = 清掉，回到"没有自定义称呼"的状态。
    func setUserDisplayName(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        userDisplayName = trimmed
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: Keys.userDisplayName)
        } else {
            UserDefaults.standard.set(trimmed, forKey: Keys.userDisplayName)
        }
    }

    func setAssistantAvatar(_ image: UIImage) throws {
        let name = SoulIconImage.storedName(prefix: "soul", id: PersonaStore.currentID())
        guard case .success(let path) = SoulIconImage.store(image, named: name) else { return }
        var soul = SoulStore.load() ?? SoulFile(metadata: .default, body: "")
        soul.metadata.icon = path
        try SoulStore.save(soul)
    }

    func removeAssistantAvatar() throws {
        var soul = SoulStore.load() ?? SoulFile(metadata: .default, body: "")
        soul.metadata.icon = ""
        try SoulStore.save(soul)
    }

    // MARK: Replaceable icons

    func customIcon(for id: String) -> String? {
        customIcons[id]
    }

    /// [B28 R2-7/A-3] 以前 encode 失败静默、删不存在的 slot 也报成功。
    /// CLI 和用户都需要知道「做了」还是「没做」。
    @discardableResult
    func setIcon(_ image: UIImage, for id: String) -> Bool {
        guard case .success(let value) = SoulIconImage.encode(image) else { return false }
        // [PIC-6] File first, memory second: the PNG file is the source
        // of truth; the dictionary is only the read cache.
        try? FileManager.default.createDirectory(at: customIconsDirectory,
                                                 withIntermediateDirectories: true)
        if let png = SoulIconImage.pngData(from: value) {
            do {
                try png.write(to: customIconURL(for: id), options: .atomic)
            } catch {
                appearanceLog.warning("icon write failed for \(id): \(error.localizedDescription)")
                return false
            }
        }
        customIcons[id] = value
        persistIcons()
        return true
    }

    /// [P3-3] Detached twin of `setIcon(_:for:)`: decode + encode + write
    /// run off the main thread (a 12MP photo used to block it ~100-300ms);
    /// only the read-cache update + revision bump run on the main actor.
    /// Same contract as `setIcon`: false when the bytes do not decode,
    /// encode fails, or the write fails.
    @discardableResult
    func setIconEncoded(_ data: Data, for id: String) async -> Bool {
        // The URL is plain path-joining; compute it here so the detached
        // task only carries Sendable values (URL + String + Data).
        let url = customIconURL(for: id)
        let value = await Task.detached(priority: .utility) { () -> String? in
            guard let image = UIImage(data: data),
                  case .success(let encoded) = SoulIconImage.encode(image),
                  let png = SoulIconImage.pngData(from: encoded) else { return nil }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            do {
                try png.write(to: url, options: .atomic)
            } catch {
                appearanceLog.warning("icon write failed for \(id): \(error.localizedDescription)")
                return nil
            }
            return encoded
        }.value
        guard let value else { return false }
        customIcons[id] = value
        persistIcons()
        return true
    }

    /// Returns whether an icon was actually there to remove (A-3:
    /// removing a nonexistent slot used to answer "removed: true").
    @discardableResult
    func removeIcon(for id: String) -> Bool {
        let existed = customIcons[id] != nil
            || FileManager.default.fileExists(atPath: customIconURL(for: id).path)
        try? FileManager.default.removeItem(at: customIconURL(for: id))
        customIcons.removeValue(forKey: id)
        persistIcons()
        return existed
    }

    private func persistIcons() {
        // [PIC-6] The dictionary is now only the in-memory read cache; the
        // files are the source of truth (setIcon/removeIcon write them).
        iconRevision += 1
    }

    // MARK: - [PIC-6] Custom icons on disk

    private var customIconsDirectory: URL { Self.customIconsDirectoryURL }

    private static var customIconsDirectoryURL: URL {
        appearanceDirectoryURL.appendingPathComponent("icons", isDirectory: true)
    }

    private func customIconURL(for id: String) -> URL {
        Self.customIconFileURL(for: id)
    }

    /// [B28 A-2] `id` 拼路径前必须消毒。
    ///
    /// 原来直接 `appendingPathComponent("\(id).png")`，而 CLI 侧
    /// `minis-theme icon --slot ../../x` 接受任意字符串 —— 能写出
    /// `Application Support/AppearanceStudio/icons/` 之外。UI 侧是枚举所以
    /// 安全，两条入口共用一个不消毒的函数，防的只有一条路。
    ///
    /// 照 `SoulStore.storedName` 的做法：只留字母数字，截断 64。
    static func sanitizedIconID(_ id: String) -> String {
        let allowed = id.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        let cleaned = String(String.UnicodeScalarView(allowed))
        return String(cleaned.prefix(64))
    }

    private static func customIconFileURL(for id: String) -> URL {
        let safe = sanitizedIconID(id)
        // 全被滤掉（例如 `../../`）时不能拼出 `".png"`，那会撞到目录里的
        // 同名文件；给一个不可能来自枚举的名字。
        let name = safe.isEmpty ? "_invalid" : safe
        return customIconsDirectoryURL.appendingPathComponent(name + ".png")
    }

    private static let customIconsMigratedKey = "appearanceStudio.customIconsMigrated.v1"

    /// One-time migration: UserDefaults JSON blob → one PNG file per slot.
    /// Runs once; the UserDefaults key is removed afterwards.
    /// Static because init calls it before all stored properties are
    /// initialized; it only touches UserDefaults and the icons directory.
    ///
    /// [batch7 用户-P2-12] 原子化：全部文件写完才删旧键、打已迁移标记。
    /// 中途任何一张写失败（目录建不出来、编码失败、落盘抛错）都不删键、
    /// 不打标记，下次启动重跑——不再是"defer 无条件清掉 + try? 静默吞错"。
    private static func migrateCustomIconsFromUserDefaults() {
        guard !UserDefaults.standard.bool(forKey: Self.customIconsMigratedKey) else { return }
        guard let data = UserDefaults.standard.data(forKey: Keys.icons) else {
            // 从来没有旧 blob：无事可做，直接标记完成。
            UserDefaults.standard.set(true, forKey: Self.customIconsMigratedKey)
            return
        }
        // 旧 blob 存在但解不开：不删、不标记，留着证据等以后处理，
        // 不像以前那样 defer 一把清掉。
        guard let value = try? JSONDecoder().decode([String: String].self, from: data),
              !value.isEmpty else { return }
        do {
            try FileManager.default.createDirectory(at: customIconsDirectoryURL,
                                                    withIntermediateDirectories: true)
        } catch {
            return // 目录都建不出来：下次启动重试。
        }
        var failed = false
        for (id, uri) in value {
            guard let png = SoulIconImage.pngData(from: uri) else {
                failed = true
                continue
            }
            do {
                try png.write(to: customIconFileURL(for: id), options: .atomic)
            } catch {
                failed = true
            }
        }
        // 有一张没写完就不算完：旧键和标记都留着，下次启动重跑。
        guard !failed else { return }
        UserDefaults.standard.removeObject(forKey: Keys.icons)
        UserDefaults.standard.set(true, forKey: Self.customIconsMigratedKey)
    }

    private static func loadCustomIconsFromDisk() -> [String: String] {
        var loaded: [String: String] = [:]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: customIconsDirectoryURL,
            includingPropertiesForKeys: nil) else { return loaded }
        for url in files where url.pathExtension.lowercased() == "png" {
            let id = url.deletingPathExtension().lastPathComponent
            guard !id.isEmpty, let data = try? Data(contentsOf: url) else { continue }
            loaded[id] = "data:image/png;base64," + data.base64EncodedString()
        }
        return loaded
    }

    /// [P1-1] One-time EXIF migration for theme images saved before the
    /// strip gate (P2-13): old files still carry full EXIF (GPS + model)
    /// on disk, in Application Support. Runs from `init` in a detached
    /// task so launch never waits on image work.
    ///
    /// Why here and not in `migrateLegacyLibrary`: that function only
    /// fires for v1 library data in UserDefaults, so most users would
    /// never get the migration. `init` is the real startup path — it
    /// already hosts the avatar and custom-icon migrate-on-read work.
    ///
    /// Idempotent and safe to run every launch: a file whose cleaned
    /// bytes are identical to its current bytes is not rewritten, so an
    /// already-clean file costs one read and no write. Files that cannot
    /// be decoded are left alone — the export gate drops them from packs
    /// instead (T-29), and deleting a user's file for being unreadable
    /// would destroy data a future decoder might still read. Rewrites
    /// are atomic, and the thumbnail cache entry is dropped so a
    /// re-encoded file never keeps showing stale pixels.
    ///
    /// Deliberate deviation from the brief's literal prescription
    /// ("rewrite via writeEncodedImageIfDecodable"): that function strips
    /// the Orientation tag without baking it (P2-4, fixed in the next
    /// batch), so it would rotate old portrait photos on disk
    /// permanently. The migration uses the same orientation-aware gate
    /// as the export path instead (`WallpaperPipeline.exportableImageData`).
    nonisolated static func migrateThemeImageMetadata() {
        var urls: [URL] = []
        for scope in AppearanceScope.allCases {
            urls.append(appearanceDirectoryURL.appendingPathComponent("wallpaper-\(scope.rawValue).jpg"))
            urls.append(appearanceDirectoryURL.appendingPathComponent("wallpaper-\(scope.rawValue)-light.jpg"))
            urls.append(appearanceDirectoryURL.appendingPathComponent("wallpaper-\(scope.rawValue)-dark.jpg"))
        }
        for name in ["thinking-card.jpg", "input-bar.jpg", "character-art.jpg"] {
            urls.append(appearanceDirectoryURL.appendingPathComponent(name))
        }
        for key in AppearanceThemePack.categoryKeys {
            urls.append(appearanceDirectoryURL.appendingPathComponent("category-\(key).jpg"))
        }
        for url in urls {
            guard let data = try? Data(contentsOf: url), !data.isEmpty,
                  // [P3-11] Matte by filename suffix, same pattern as
                  // `originalImageData`: "-dark.jpg" files are padded with
                  // the dark canvas, everything else with the light one —
                  // the default light matte used to pad dark-variant
                  // transparent wallpapers light.
                  let clean = WallpaperPipeline.exportableImageData(
                      data, matte: WallpaperPipeline.canvasMatte(
                          dark: url.lastPathComponent.hasSuffix("-dark.jpg"))),
                  clean != data else { continue }
            // [P3-1] Re-read before writing: a picker may have swapped this
            // file between the read above and this write — never clobber a
            // newer image with cleaned old bytes.
            guard let current = try? Data(contentsOf: url), current == data else { continue }
            try? clean.write(to: url, options: .atomic)
            ThumbnailCache.shared.removeThumbnail(for: url.path)
        }
    }

    // MARK: UIKit-backed surfaces

    func configureUIKitSurfaces() {
        UITableView.appearance().backgroundColor = .clear
        UICollectionView.appearance().backgroundColor = .clear
        let nav = UINavigationBarAppearance()
        nav.configureWithTransparentBackground()
        nav.backgroundColor = uiColor(.raised).withAlphaComponent(surfaceOpacity)
        nav.shadowColor = uiColor(.border).withAlphaComponent(0.65)
        nav.titleTextAttributes = [.foregroundColor: uiColor(.primaryText)]
        nav.largeTitleTextAttributes = [.foregroundColor: uiColor(.primaryText)]
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
        UINavigationBar.appearance().compactAppearance = nav
    }
}

struct AppearancePalette {
    let light: [AppearanceColorRole: String]
    let dark: [AppearanceColorRole: String]
}

private enum AppearancePaletteBook {
    // 2026-11-02 theme-colour batch (user: the warm palette was
    // "黄不拉几", unbearable). The built-in default is now the same
    // monochrome language as the approved Gemini font page (v2
    // `:root`): neutral grey-white canvas, white surfaces, ink
    // #111113, secondary #636366, tertiary #8E8E93, black as the
    // only accent. No yellow / cream / beige tint anywhere in the
    // default, light or dark. The old warm book is kept verbatim
    // in `migratedFromWarmDefaults` below so stored values that
    // exactly equal an old default can be moved to the new one.
    //
    // Light tokens map v2 one-to-one where v2 has the slot:
    // canvas F5F5F7, panel/stage white, chat-bg F7F7F9 (muted),
    // pill EBEBEF (chip), badge F2F2F5 (iconTile), tag ECECEF,
    // border-regular ~E8E8E8. Bubbles deliberately do NOT copy
    // v2's black me-bubble: this app's bubble text defaults to
    // primaryText, so a black bubble with unset bubble text
    // would be black-on-black; the user bubble is system grey 5
    // (E5E5EA, black text) and the accent stays the only black.
    //
    // Dark is NOT v2 inverted: v2 has no dark set. It follows
    // HIG's two-tier dark surfaces (base #000000, elevated
    // #1C1C1E / #2C2C2E) with the accent flipped to white, because
    // a black accent on a black surface is invisible. Status
    // colours keep their hue (green / amber / red) at lower
    // saturation: they are small badges and prompts, and hue is
    // how they mean anything; every surface, text, and accent
    // token stays black / white / neutral grey.
    // [T-43] 浅色档原来 canvas/surface/raised/field 里三个是同一个 FFFFFF，
    // 卡片、浮层、输入框在白底上完全没有层次——她说的"看不出哪层是哪层"。
    // 现在按"canvas 最灰 → raised 次之 → surface 最白"排，输入框单独一档
    // 灰（iOS 的 search field 语言），四层各差一点点。
    static let light: [AppearanceColorRole: String] = [
        .canvas: "F5F5F7", .surface: "FFFFFF", .raised: "FBFBFD",
        .mutedSurface: "F7F7F9", .primaryText: "111113", .secondaryText: "636366",
        .tertiaryText: "8E8E93", .shellText: "E5E5EA",
        .accent: "111113", .userBubble: "E5E5EA", .assistantBubble: "FFFFFF",
        .border: "E8E8E8",
        .field: "F4F4F7", .iconTile: "F2F2F5", .chip: "EBEBEF",
        .disabled: "B8B8BD",
        .success: "5A8F6A",
        .warning: "B7791F", .destructive: "D9383A"
    ]
    // [T-43] 深色档原来 raised 和 mutedSurface 都是 2C2C2E、field 和 surface
    // 都是 1C1C1E，同样是撞车。浮层保持最高一档，浅底块下移到卡片与浮层
    // 之间，输入框单独一档——HIG 的两层深色面拉开成四档。
    // [T-47] 调色板是字典——少一个键不会编译报错，会在运行时静默渲染
    // 808080 灰。这条断言把"每个角色都有值"变成启动即失败，不再等人看图
    // 才发现某个新角色是灰的。
    //
    // 故意缺席的是两个气泡文字角色：它们跟主文字走，不在表里配。这里把
    // 这份例外写清楚，别让后来的人以为是漏配。
    static let rolesWithoutOwnEntry: Set<AppearanceColorRole> = [.bubbleText, .assistantBubbleText]

    static var missingRoles: [AppearanceColorRole] {
        let expected = AppearanceColorRole.allCases.filter { !rolesWithoutOwnEntry.contains($0) }
        return expected.filter { light[$0] == nil || dark[$0] == nil }
    }

    static let dark: [AppearanceColorRole: String] = [
        .canvas: "000000", .surface: "1C1C1E", .raised: "2C2C2E",
        .mutedSurface: "242426", .primaryText: "FFFFFF", .secondaryText: "AEAEB2",
        .tertiaryText: "8E8E93", .shellText: "E5E5EA",
        .accent: "FFFFFF", .userBubble: "3A3A3C", .assistantBubble: "1C1C1E",
        .border: "38383A",
        .field: "262628", .iconTile: "2C2C2E", .chip: "3A3A3C",
        .disabled: "5A5A5F",
        .success: "7FBF8F",
        .warning: "D9A441", .destructive: "FF453A"
    ]
}

enum AppearancePreset: String, CaseIterable, Identifiable {
    case warmPaper, cleanAir, nightCocoa
    var id: String { rawValue }
    var title: String {
        switch self {
        case .warmPaper: return AppLocalized("纯净")
        case .cleanAir: return AppLocalized("清气")
        case .nightCocoa: return AppLocalized("夜可可")
        }
    }
    var colors: AppearancePalette {
        switch self {
        case .warmPaper:
            return AppearancePalette(light: AppearancePaletteBook.light, dark: AppearancePaletteBook.dark)
        case .cleanAir:
            return AppearancePalette(
                light: [.canvas:"F6F8FA",.surface:"FFFFFF",.raised:"FFFFFF",.mutedSurface:"EDF2F5",.primaryText:"26323A",.secondaryText:"6F7E87",.accent:"6F93A8",.userBubble:"DDEAF0",.assistantBubble:"FFFFFF",.field:"FFFFFF",.border:"DCE5E9",.iconTile:"FFFFFF",.chip:"EDF2F5",.success:"638F76",.warning:"C9A36A",.destructive:"BC6262"],
                dark: [.canvas:"151A1D",.surface:"20272B",.raised:"273035",.mutedSurface:"2B353A",.primaryText:"EDF3F5",.secondaryText:"AAB8BE",.accent:"8CB2C5",.userBubble:"334B57",.assistantBubble:"20272B",.field:"252D31",.border:"3B484E",.iconTile:"20272B",.chip:"2B353A",.success:"82AF91",.warning:"D4B07A",.destructive:"DA8181"])
        case .nightCocoa:
            return AppearancePalette(
                light: [.canvas:"FBF6EF",.surface:"FFFDF8",.raised:"FFFFFF",.mutedSurface:"F2E7DA",.primaryText:"44362E",.secondaryText:"8D7868",.accent:"A77965",.userBubble:"EAD8CE",.assistantBubble:"FFFDF8",.field:"FFFBF5",.border:"E5D7C9",.iconTile:"FFFDF8",.chip:"F2E7DA",.success:"728E70",.warning:"C9A36A",.destructive:"B86565"],
                dark: [.canvas:"171311",.surface:"241E1A",.raised:"2E2621",.mutedSurface:"362B25",.primaryText:"F2E9E1",.secondaryText:"B9A79B",.accent:"C99B84",.userBubble:"513B31",.assistantBubble:"241E1A",.field:"2A231F",.border:"493B33",.iconTile:"241E1A",.chip:"362B25",.success:"91AE8B",.warning:"D4B07A",.destructive:"D17A7A"])
        }
    }
}

/// [composer-icons] 输入栏四颗键的图片套装。现在只有一套：金色。
/// 卡片只换四张图，不碰颜色、壁纸、气泡、字体——见 `applyComposerIcons`。
enum ComposerIconSet: String, CaseIterable, Identifiable {
    case gold
    var id: String { rawValue }
    var title: String {
        switch self {
        case .gold: return AppLocalized("金色按键")
        }
    }
    /// 四张图的资源名。`applyComposerIcons` 原样写进 pack 的四个字段。
    var micImage: String { "ComposerMicGold" }
    var emojiImage: String { "ComposerEmojiCat" }
    var sendImage: String { "ComposerSendGold" }
    var pauseImage: String { "ComposerPauseGold" }
    /// 卡片预览里四张图按这个顺序排：话筒、表情、发送、暂停。
    var previewImages: [String] { [micImage, emojiImage, sendImage, pauseImage] }
}

extension Color {
    init(hex: String) {
        self.init(UIColor(hex: hex))
    }
}

extension UIColor {
    /// Parses `RRGGBB` / `RRGGBBAA` / `#RGB` style hex.
    ///
    /// The scanner used to be asked for a number and never checked whether it
    /// got one, so `"ZZZZZZ"` scanned to 0 and rendered pure black while `""`
    /// rendered grey — two different wrong answers, neither reported. A value
    /// that does not parse now falls back to the same neutral grey the pack
    /// normalizer uses, so a bad hex is visible as one consistent colour
    /// instead of silently turning text black.
    convenience init(hex: String) {
        let raw = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        let scanner = Scanner(string: raw)
        let parsed = scanner.scanHexInt64(&value)
        guard parsed, scanner.isAtEnd, raw.count == 6 || raw.count == 8 else {
            self.init(red: 0x80 / 255, green: 0x80 / 255, blue: 0x80 / 255, alpha: 1)
            return
        }
        let r, g, b, a: CGFloat
        switch raw.count {
        case 8:
            r = CGFloat((value >> 24) & 0xff) / 255
            g = CGFloat((value >> 16) & 0xff) / 255
            b = CGFloat((value >> 8) & 0xff) / 255
            a = CGFloat(value & 0xff) / 255
        default:
            r = CGFloat((value >> 16) & 0xff) / 255
            g = CGFloat((value >> 8) & 0xff) / 255
            b = CGFloat(value & 0xff) / 255
            a = 1
        }
        self.init(red: r, green: g, blue: b, alpha: a)
    }

    var hexRGB: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        let resolved = resolvedColor(with: UITraitCollection.current)
        guard resolved.getRed(&r, green: &g, blue: &b, alpha: &a) else { return "808080" }
        return String(format: "%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }
}

// MARK: - Theme access and backgrounds

/// [T-06] 每类界面固定一层颜色。
///
/// 以前四个取色入口各有各的默认：`MinisTheme` 默认 `.global`、`ChatColors`
/// 全 `.chat`、`CSSThemeVariables` 默认 `.chat`、`MinisThemeList` 全 `.home`。
/// 同一个角色在不同层读到不同作用域，页级覆盖生不生效取决于调用方随手挑了
/// 哪一层——这不叫灵活，是没定规矩。
///
/// 现在规矩只写在这一个地方：每类界面对应一层，入口不再自己写作用域字面量。
/// 旧签名一律保留（`scope:` 仍可显式传），所以这是一轮"包一层"——下一轮才
/// 合并入口本身。
///
/// 表面透明度只一套算法:`MinisTheme` / `ChatColors` 与
/// `CSSThemeVariables.card` 都无条件乘 `surfaceOpacity`,装扮中心三颗旋钮
/// 里「卡片表面透光」那颗就是这一个值。没壁纸时卡片也不再是不透明——
/// 视觉会比以前略透一点(默认 0.88 对原来写死的 0.85),要真机比图。
enum ThemeColorLayer {
    /// 聊天消息区：气泡、消息操作栏、输入栏。
    static let chat: AppearanceScope = .chat
    /// 弹窗、表单、面板：跟着聊天页走，不单独成层。
    static let sheet: AppearanceScope = .chat
    /// 设置、装扮店、主题面板。
    static let settings: AppearanceScope = .global
    /// Minis 首页列表。
    static let home: AppearanceScope = .home
    /// 一起听：**没有独立作用域**。它复用聊天层取色，壁纸另走
    /// `TogetherImages`（见 T-55 的 `WallpaperPipeline`）。这里只留一行
    /// 说明，不定义常量——定义了就有人去用，然后发现读到的还是 chat。
    /// 没写明自己属于哪类界面的调用方拿到的层。
    static let fallback: AppearanceScope = .global
}

@MainActor
enum MinisTheme {
    static func color(_ role: AppearanceColorRole,
                      scope: AppearanceScope = ThemeColorLayer.fallback) -> Color {
        AppearanceStudio.shared.color(role, scope: scope)
    }
    static var canvas: Color { color(.canvas) }
    static var surface: Color { color(.surface).opacity(AppearanceStudio.shared.surfaceOpacity) }
    static var raised: Color { color(.raised).opacity(AppearanceStudio.shared.surfaceOpacity) }
    static var mutedSurface: Color { color(.mutedSurface).opacity(AppearanceStudio.shared.surfaceOpacity) }
    /// 小方块图标底 / 胶囊底 / 输入类底。设置页与首页也走这套，
    /// 免得"卡片"一个角色被拿去画图标底。
    static var iconTile: Color { color(.iconTile).opacity(AppearanceStudio.shared.surfaceOpacity) }
    static var chip: Color { color(.chip).opacity(AppearanceStudio.shared.surfaceOpacity) }
    static var field: Color { color(.field).opacity(AppearanceStudio.shared.surfaceOpacity) }
    static var primaryText: Color { color(.primaryText) }
    static var secondaryText: Color { color(.secondaryText) }
    static var accent: Color { color(.accent) }
    static var border: Color { color(.border) }
    // [T-tokenize-all-colors] Semantic trio for settings pages, mirrors
    // ChatColors so the whole app speaks the same token vocabulary.
    static var success: Color { color(.success) }
    static var warning: Color { color(.warning) }
    static var destructive: Color { color(.destructive) }
}

/// [T-57] 谁在画页层壁纸。根层那层全局 backdrop 只在**没有**页层 backdrop
/// 时才需要画:页层那层是不透明底色 + 同一张图,盖在根层上面,根层画的那份
/// 一帧都看不见,纯属白烧一次全屏栅格化。
///
/// 用一个计数而不是布尔:页与页之间有转场,可能短暂同时挂两层;只要还有
/// 一层在,根层就让开。计数回到 0 根层自动回来,所以没有页层壁纸的页面
/// (以及启动早期)行为完全不变。
@MainActor
final class PageBackdropPresence: ObservableObject {
    static let shared = PageBackdropPresence()
    @Published private(set) var count = 0

    var isCovered: Bool { count > 0 }

    func add() { count += 1 }
    func remove() { count = max(0, count - 1) }
}

struct AppearanceBackdrop: View {
    let scope: AppearanceScope
    /// 只给根层用:有页层 backdrop 在画的时候,这一层不画。
    var standsDownWhenCovered: Bool = false
    @ObservedObject private var studio = AppearanceStudio.shared
    @ObservedObject private var presence = PageBackdropPresence.shared

    var body: some View {
        Group {
            if standsDownWhenCovered && presence.isCovered {
                Color.clear
            } else {
                layers
            }
        }
        .onAppear { if scope != .global { PageBackdropPresence.shared.add() } }
        .onDisappear { if scope != .global { PageBackdropPresence.shared.remove() } }
    }

    /// [T-28] 一张图要不要走双层。判据是"按原比例塞进屏幕时，放大倍数超过
    /// 一点点"——iPhone 竖屏宽 393pt 起，200×200 的图要放大两倍多，必须走
    /// 双层；够大的照片直接铺满，不额外画一层、不额外栅格化。
    @MainActor
    static func needsDoubleLayer(_ image: UIImage) -> Bool {
        let screenWidth = UIScreen.main.bounds.width
        guard screenWidth > 0, image.size.width > 0, image.size.height > 0 else { return false }
        let upscale = screenWidth / image.size.width
        return upscale > 1.35
    }

    private var layers: some View {
        ZStack {
            studio.color(.canvas, scope: scope)
            if let image = studio.wallpaper(for: scope) {
                // [T-home-wallpaper-fullbleed][10-02 醒醒改口径] 底部栏预览与真机一致（24pt 条样式）。
                if scope == .bottomBar {
                    VStack(spacing: 0) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity)
                            .frame(height: 24)
                            .clipped()
                            .overlay(studio.color(.canvas, scope: .bottomBar).opacity(studio.wallpaperShade))
                        Spacer(minLength: 0)
                    }
                } else {
                    // [T-28] 小图双层：图比屏幕小的时候，单层 scaledToFill 会把
                    // 它拉糊。垫底那层同图拉伸 + 模糊（只压这一层，原图不压），
                    // 上面原图清晰、按比例居中适配。图够大就还是原来的单层铺满，
                    // 像素不变。壁纸归属不变：这条只决定一张图怎么画。
                    if AppearanceBackdrop.needsDoubleLayer(image) {
                        ZStack {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                                .blur(radius: 28, opaque: true)
                                .clipped()
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                        }
                        studio.color(.canvas, scope: scope)
                            .opacity(studio.wallpaperShade)
                    } else {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .clipped()
                        studio.color(.canvas, scope: scope)
                            .opacity(studio.wallpaperShade)
                    }
                }
            }
        }
        .id(studio.wallpaperRevision(for: scope))
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

private struct AppearancePageModifier: ViewModifier {
    let scope: AppearanceScope
    @ObservedObject private var studio = AppearanceStudio.shared

    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .foregroundStyle(studio.color(.primaryText, scope: scope))
            .tint(studio.color(.accent, scope: scope))
            // [T-composer-wallpaper-stable] Pin the page wallpaper to the WINDOW.
            //
            // It used to be a plain `.background(AppearanceBackdrop(...))`, so
            // the backdrop was sized by the page's own frame — and the page's
            // frame changes when the keyboard appears, so `scaledToFill` picked
            // a new scale and the wallpaper visibly zoomed ~1.25-1.5x every time
            // the input bar came up. Here the backdrop gets an explicit
            // full-window frame and is positioned at the window centre, with
            // the host's global origin compensated via GeometryReader (so an
            // iPad split-view inset doesn't shift it). The rendered rect is
            // therefore invariant: keyboard / safe-area / page resizes only
            // re-run the arithmetic, never the picture. Only the page path is
            // pinned — AppearanceBackdrop itself stays host-sized, so the 150pt
            // wallpaper preview card in the studio keeps its own crop.
            .background(
                GeometryReader { proxy in
                    AppearanceBackdrop(scope: scope)
                        .frame(width: UIScreen.main.bounds.width, height: UIScreen.main.bounds.height)
                        .position(
                            x: UIScreen.main.bounds.width / 2 - proxy.frame(in: .global).minX,
                            y: UIScreen.main.bounds.height / 2 - proxy.frame(in: .global).minY
                        )
                }
            )
            // Wallpaper-fullscreen pages: the nav bar sits transparently over
            // the backdrop instead of a material/opaque band at the top, so
            // the wallpaper runs edge to edge under the title.
            .toolbarBackground(.hidden, for: .navigationBar)
    }
}

private struct SettingsListRowBackgroundModifier: ViewModifier {
    @ObservedObject private var studio = AppearanceStudio.shared

    func body(content: Content) -> some View {
        // [10-18 醒醒 第五轮] 「连选项的背景都可以改颜色或者图片，
        // 而不是一直纯白色的那种。」
        //
        // 有自定义行背景色就用它，没有就跟随 surface——旧主题包不带这个
        // 字段，会自动走 surface，不会突然变白。
        let pack = studio.currentThemePack()
        if let hex = pack.rowBackgroundHex, !hex.isEmpty {
            content.listRowBackground(Color(hex: hex))
        } else {
            content.listRowBackground(studio.color(.surface, scope: .settings))
        }
    }
}

extension View {
    func appearancePage(_ scope: AppearanceScope) -> some View {
        modifier(AppearancePageModifier(scope: scope))
    }

    /// One-line theming for a settings-scope page: palette canvas/accent/text
    /// + transparent nav bar (via appearancePage) + List section cards that
    /// follow the palette "卡片" (surface) color instead of the system
    /// grouped background — so the 色盘 卡片 row actually controls them.
    func settingsPage() -> some View {
        self
            .appearancePage(.settings)
            .modifier(SettingsListRowBackgroundModifier())
    }
}

// MARK: - [3-4 醒醒] 统一卡片修饰器 (MinisStandardCard)
// 标准卡片：surface + 16pt (或 12pt 行内) 连续圆角 + 16x12 内距 + 0.5pt border 描边

public struct MinisStandardCard: ViewModifier {
    public var cornerRadius: CGFloat = 16
    public var paddingHorizontal: CGFloat = 16
    public var paddingVertical: CGFloat = 12
    public var strokeOpacity: Double = 0.35

    public func body(content: Content) -> some View {
        content
            .padding(.horizontal, paddingHorizontal)
            .padding(.vertical, paddingVertical)
            .background(
                AppearanceStudio.shared.color(.surface),
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(AppearanceStudio.shared.color(.border).opacity(strokeOpacity), lineWidth: 0.5)
            )
    }
}

public extension View {
    func minisStandardCard(cornerRadius: CGFloat = 16, hPadding: CGFloat = 16, vPadding: CGFloat = 12) -> some View {
        modifier(MinisStandardCard(cornerRadius: cornerRadius, paddingHorizontal: hPadding, paddingVertical: vPadding))
    }
}

struct PersonAvatarView: View {
    enum Kind { case user, assistant }
    let kind: Kind
    let size: CGFloat
    /// [问题12] 这个头像属于哪个人设。nil → 回落到全局当前人设。
    ///
    /// 聊天页原来固定读 `SoulStore.cachedMetadata.icon`，那是**当前人设**
    /// 的缓存——会话绑的是别人时，对话框就显示错的人，看着就是"两套"。
    /// 传进来之后按会话绑定的人设取，跟列表同源。
    var personaID: String?
    /// Show this side's applied pendant ring. Default true: live
    /// chat, lists, and headers all wear their side's ring. A
    /// preview that overlays a not-yet-applied pendant itself
    /// (the shop's pendant detail) passes false, so the preview
    /// ring is the only ring on that avatar — never a double ring
    /// of applied + preview.
    var showPendant: Bool = true
    /// Theme-set preview override ONLY. Default nil: shape follows
    /// the current theme pack, exactly as today, so every existing
    /// call site is unaffected. A non-nil value draws the avatar
    /// in that shape instead of the current-pack shape.
    var shapeOverride: AppearanceAvatarShape? = nil
    @ObservedObject private var studio = AppearanceStudio.shared
    // 人设一改（换头像）就让所有头像视图重画，不等重进页面。
    @ObservedObject private var personaStore = PersonaStore.shared
    @State private var soulIcon = SoulStore.cachedMetadata.icon

    /// [10-18 醒醒 第五轮] 头像形状跟着主题包走。
    /// A preview override, when provided, wins over the current
    /// pack; nil keeps today's behaviour exactly.
    private var avatarShape: AppearanceAvatarShape {
        shapeOverride ?? AppearanceAvatarShape.parse(studio.currentThemePack().avatarShape)
    }

    private var resolvedIcon: String? {
        guard let pid = personaID else {
            return soulIcon.isEmpty ? nil : soulIcon
        }
        // [B28 R14] 通讯录改的头像存在 Persona.avatar，聊天这边原来只读 SOUL.md 的
        // icon —— 两套存储，改了头像对话框不动。现在以通讯录为准，SOUL 兜底。
        if let stored = PersonaStore.shared.personas.first(where: { $0.id == pid })?.avatar,
           !stored.isEmpty, avatarFileExists(stored) {
            return stored
        }
        let soul = SoulStore.displayIcon(for: pid)
        // 路径指向的文件可能早没了（换过图又清过缓存），当没有处理，别留白块。
        return soul.flatMap { avatarFileExists($0) ? $0 : nil }
    }

    /// 只有真能读到的图才算头像。
    private func avatarFileExists(_ value: String) -> Bool {
        guard SoulIconImage.isPathReference(value) else { return true }
        guard let url = SoulIconImage.fileURL(forReference: value) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    var body: some View {
        Group {
            // [B28 R12] 她自己的头像以通讯录「我自己」档案为准——
            // 情头页删掉后 userAvatar 没有入口了，只能回退用。
            let meAvatarRaw = PersonaStore.shared.personas
                .first { $0.id == PersonaStore.userProfilePersonaID }?.avatar ?? ""
            let meAvatar = avatarFileExists(meAvatarRaw) ? meAvatarRaw : ""
            let icon = kind == .user
                ? (meAvatar.isEmpty ? studio.userAvatar : meAvatar)
                : (resolvedIcon ?? "")
            // [avatar] Only an image counts as an avatar. A legacy
            // non-image value (an emoji stored by an older build) is
            // treated as unset and falls through to the default tile.
            if SoulIconImage.isImageReference(icon) {
                SoulIconView(icon: icon, size: size, shape: avatarShape)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: size * avatarShape.cornerFraction, style: .continuous)
                        .fill(kind == .user
                              ? studio.color(.userBubble, scope: .chat)
                              : studio.color(.assistantBubble, scope: .chat))
                    Image(systemName: kind == .user ? "person.fill" : "sparkles")
                        .font(.system(size: size * 0.42, weight: .medium))
                        .foregroundStyle(studio.color(.accent, scope: .chat))
                }
                .frame(width: size, height: size)
            }
        }
        .frame(width: size, height: size)
        // [avatar-pendant] THAT SIDE's applied ring, if any,
        // hugs the avatar edge exactly (same view the shop
        // preview draws, so live chat can never show a different
        // ring; the glow spills outside the edge, the ring
        // itself has no gap). kind == .user is the user side, anything else is
        // the AI side: a user avatar can never borrow the AI
        // side's ring, and vice versa. The avatar image itself
        // still resolves dynamically above (session / current
        // persona for the AI side, user-profile persona for the
        // user side), so a persona change re-points the ring to
        // the new avatar with no stored name involved.
        .avatarPendantRing(size: size, side: showPendant ? (kind == .user ? .user : .assistant) : nil)
        .overlay(
            RoundedRectangle(cornerRadius: size * avatarShape.cornerFraction, style: .continuous)
                .stroke(studio.color(.border, scope: .chat),
                        lineWidth: MinisThemeShape.avatarBorderWidth)
        )
        .onReceive(NotificationCenter.default.publisher(for: .soulMdChanged)) { _ in
            soulIcon = SoulStore.cachedMetadata.icon
        }
    }
}

struct QuietAppIcon: View {
    let id: String
    let systemName: String
    var size: CGFloat = 21
    @ObservedObject private var studio = AppearanceStudio.shared

    var body: some View {
        Group {
            if let custom = studio.customIcon(for: id) {
                SoulIconView(icon: custom, size: size)
            } else {
                // [问题6] 她定的规范：「全部白底 + 黑色图标，图标全部变成实体的
                // 稍微偏圆润感一点的，白底边框也是圆角的，色彩方面也跟着css
                // 全局变量」。
                //
                // 改了三处，都是照她的原话：
                // 1. 底色从 .surface（跟着卡片色走，深色模式下会变暗）改成真正的
                //    白色——她要的是"白底"，不是"跟主题的卡片底"。深色模式也
                //    保持白底，这是她点名要的视觉锚点。
                // 2. 图标色从 .primaryText 改成固定黑：白底上的黑，不随主题文字色
                //    漂移，否则深色模式下会变成浅灰。
                // 3. weight 从 .medium 改成 .semibold 并配合 SF Symbols 的
                //    .fill 变体——"实心"和"圆润"。
                //
                // 圆角沿用原来的 8pt（size 21 时约 0.38 倍，比 0.25 更圆润），
                // 不动，因为它本来就在她要的"圆润"一侧。
                Image(systemName: Self.filledSymbolName(systemName))
                    .font(.system(size: max(9, size * 0.44), weight: .semibold))
                    .foregroundStyle(Color.black)
                    .frame(width: size, height: size)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.black.opacity(0.08), lineWidth: 0.6)
                    )
            }
        }
        .id(studio.iconRevision)
    }

    /// [问题6] 把 SF Symbol 名换成实心变体。
    ///
    /// 不能无脑加 ".fill"：`sparkles`、`brain.head.profile`、
    /// `arrow.triangle.2.circlepath`、`magnifyingglass`、
    /// `clock.arrow.circlepath`、`antenna.radiowaves.left.and.right`
    /// 这几个本身就没有 fill 变体，加后缀会渲染成空白图标。
    /// 所以用一张显式表：表里有就用表里的，已经带 .fill 的原样返回，
    /// 其余才试加后缀。新加图标忘了进表也不会变成空白——最坏是保持线框。
    static func filledSymbolName(_ name: String) -> String {
        if let mapped = solidSymbolMap[name] { return mapped }
        if name.hasSuffix(".fill") { return name }
        return name + ".fill"
    }

    /// 例外表：这些名字不能简单加 ".fill"。
    ///
    /// 左边是要传入的名字，右边是实际该渲染的。没有 fill 变体的原样返回——
    /// 加后缀会渲染成空白图标，比线框更糟。她要的是"全部实体"，所以这几个
    /// 挑的是本身就偏实心的符号（sparkles 本身就是实心形状）。
    private static let solidSymbolMap: [String: String] = [
        "sparkles": "sparkles",
        "brain.head.profile": "brain.head.profile",
        "arrow.triangle.2.circlepath": "arrow.triangle.2.circlepath",
        "magnifyingglass": "magnifyingglass",
        "clock.arrow.circlepath": "clock.arrow.circlepath",
        "antenna.radiowaves.left.and.right": "antenna.radiowaves.left.and.right",
    ]
}

enum QuietIconSlot: String, CaseIterable, Identifiable {
    case decorate, appearance, skills, soul, memory, mcp, env, terminal, rootfs, browser
    /// [batch1] Settings → Agent Runtime 的「Agent Tools」行（工具开关页）。
    case agentTools
    case storage, shared, mounts, icloud, backup, permissions, lock
    case logs, about, privacy, feedback
    /// [merge step18a] Settings → Agent Runtime 的「桥·对外连接」行。
    case bridgeRelay
    /// [s2-search] Settings 的「联网搜索」行（第 18 条）。
    case webSearch
    /// [T-user-manual 09-11] Settings → About section's 使用手册 row.
    case manual
    /// [AUD-20] Settings → Agent Runtime 的「定时任务与脉搏」行。 Was sharing
    /// `.terminal`, so customising the terminal icon silently changed this
    /// row's icon too — two features, one slot.
    case scheduled
    /// [batch7] Settings → Agent Runtime 的「Sub Agents」行（子代理设置页）。
    case subAgents
    /// [T-ambient-context 11-07] Settings → Agent Runtime 的「她此刻的状态」行。
    case ambient

    var id: String { rawValue }
    var title: String {
        switch self {
        case .decorate: return AppLocalized("装扮")
        case .appearance: return AppLocalized("Appearance")
        case .skills: return AppLocalized("技能")
        case .soul: return "Soul"
        case .memory: return AppLocalized("记忆")
        case .mcp: return "MCP"
        case .env: return AppLocalized("Environment Variables")
        case .storage: return AppLocalized("Storage")
        case .shared: return AppLocalized("Shared folders")
        case .mounts: return AppLocalized("外部文件夹")
        case .icloud: return AppLocalized("iCloud Sync")
        case .backup: return AppLocalized("Backup & Restore")
        case .permissions: return AppLocalized("Permissions")
        case .lock: return AppLocalized("锁定")
        case .logs: return AppLocalized("Logs")
        case .about: return AppLocalized("About")
        case .privacy: return AppLocalized("Privacy Policy")
        case .feedback: return AppLocalized("反馈")
        case .manual: return AppLocalized("手册")
        case .terminal: return AppLocalized("终端")
        case .rootfs: return AppLocalized("Rootfs Management")
        case .browser: return AppLocalized("浏览器")
        case .bridgeRelay: return AppLocalized("桥·对外连接")
        case .webSearch: return AppLocalized("联网搜索")
        case .scheduled: return AppLocalized("定时任务与脉搏")
        case .subAgents: return AppLocalized("Sub agent")
        case .ambient: return AppLocalized("她此刻的状态")
        case .agentTools: return AppLocalized("工具开关")
        }
    }
    var systemName: String {
        switch self {
        case .decorate: return "paintpalette.fill"
        case .appearance: return "paintbrush.fill"
        case .skills: return "puzzlepiece.extension.fill"
        case .soul: return "sparkles"
        case .memory: return "brain.head.profile"
        case .mcp: return "square.stack.3d.up.fill"
        case .env: return "terminal.fill"
        case .storage: return "archivebox.fill"
        case .shared: return "folder.fill"
        case .mounts: return "externaldrive.fill"
        case .icloud: return "icloud.fill"
        case .backup: return "arrow.triangle.2.circlepath"
        case .permissions: return "lock.shield.fill"
        case .lock: return "lock.fill"
        case .logs: return "doc.text.fill"
        case .about: return "info.circle.fill"
        case .privacy: return "hand.raised.fill"
        case .feedback: return "bubble.left.and.bubble.right.fill"
        case .manual: return "book.closed.fill"
        case .terminal: return "terminal.fill"
        case .rootfs: return "externaldrive.fill"
        case .browser: return "globe.fill"
        case .bridgeRelay: return "antenna.radiowaves.left.and.right"
        case .webSearch: return "magnifyingglass"
        case .scheduled: return "clock.arrow.circlepath"
        case .subAgents: return "person.2.fill"
        case .ambient: return "clock.arrow.circlepath"
        case .agentTools: return "wrench.and.screwdriver.fill"
        }
    }
}

// MARK: - Backup ([PIC-2])

extension AppearanceStudio {
    /// Every UserDefaults key holding appearance state. The image FILES
    /// are archived as a tree (see `appearanceAssetsDirectory`); these
    /// keys are the half that lives in defaults — custom colours, the
    /// user avatar, opacities, the wallpaper-cleared list, the
    /// theme-library list and the current theme pack. Single source of
    /// truth for both directions, and the restore side's whitelist: a
    /// package may only ever write THESE keys, never arbitrary defaults.
    static var backupDefaultsKeys: [String] {
        [Keys.colors, Keys.userAvatar, Keys.surfaceOpacity, Keys.bubbleOpacity,
         Keys.wallpaperShade, wallpaperClearedKey,
         AppearanceSavedTheme.libraryKey, AppearanceThemePack.currentKey]
    }

    /// Snapshot the keys above into the package's wire shape. Absent keys
    /// stay absent, so restoring an old or sparse package never invents
    /// values the source device didn't have.
    func collectBackupDefaults() -> [String: BackupDefaultsValue] {
        let defaults = UserDefaults.standard
        var out: [String: BackupDefaultsValue] = [:]
        for key in Self.backupDefaultsKeys {
            guard let raw = defaults.object(forKey: key) else { continue }
            if let data = raw as? Data {
                out[key] = BackupDefaultsValue(kind: "data", data: data.base64EncodedString())
            } else if let string = raw as? String {
                out[key] = BackupDefaultsValue(kind: "string", string: string)
            } else if let strings = raw as? [String] {
                out[key] = BackupDefaultsValue(kind: "strings", strings: strings)
            } else if let number = raw as? NSNumber {
                out[key] = BackupDefaultsValue(kind: "double", double: number.doubleValue)
            }
        }
        return out
    }

    /// Write a restored package's values back into UserDefaults (only the
    /// whitelisted keys; unknown kinds are skipped, not fatal), then
    /// reload the live instance so the restored look takes effect without
    /// a relaunch.
    func applyBackupDefaults(_ values: [String: BackupDefaultsValue]) {
        let defaults = UserDefaults.standard
        for key in Self.backupDefaultsKeys {
            guard let value = values[key] else { continue }
            switch value.kind {
            case "data":
                if let b64 = value.data, let data = Data(base64Encoded: b64) {
                    defaults.set(data, forKey: key)
                }
            case "string":
                if let string = value.string { defaults.set(string, forKey: key) }
            case "strings":
                if let strings = value.strings { defaults.set(strings, forKey: key) }
            case "double":
                if let double = value.double { defaults.set(double, forKey: key) }
            default:
                break
            }
        }
        reloadAfterRestore()
    }

    /// Re-read every piece of appearance state from disk / defaults after
    /// a restore rewrote it underneath the live instance: colours, avatar,
    /// opacities, cleared-wallpaper list, custom icons (files), current
    /// theme pack, and the cached wallpapers.
    func reloadAfterRestore() {
        if let data = UserDefaults.standard.data(forKey: Keys.colors),
           let value = try? JSONDecoder().decode([String: String].self, from: data) {
            customColors = value
        } else {
            customColors = [:]
        }
        Self.colorSnapshot = customColors
        loadUserAvatar()
        surfaceOpacity = UserDefaults.standard.object(forKey: Keys.surfaceOpacity) as? Double ?? 0.88
        bubbleOpacity = UserDefaults.standard.object(forKey: Keys.bubbleOpacity) as? Double ?? 1.0
        wallpaperShade = UserDefaults.standard.object(forKey: Keys.wallpaperShade) as? Double ?? 0.08
        loadWallpaperCleared()
        customIcons = Self.loadCustomIconsFromDisk()
        themePackLock.lock()
        cachedThemePack = loadStoredPackUnlocked()
        themePackLoaded = true
        themePackLock.unlock()
        themePackRevision += 1
        wallpaperCache.removeAllObjects()
        bumpAllWallpaperRevisions()
        iconRevision += 1
        configureUIKitSurfaces()
    }
}

// MARK: - [B28 R10] 称呼自适应

/// App 里任何"要提到对话双方"的文案，都从这里取称呼，不写死具体名字。
/// - AI 侧：跟着当前会话绑的人设走（SOUL.md 的 name），人设改名即生效。
/// - 用户侧：她在外观工作室里自己填的称呼；没填就回落到中性词，
///   UI 用"你"，给模型的提示词用"用户"（对模型说"你"会指错人）。
@MainActor
enum ChatAddressing {
    /// 回答的人叫什么。
    static func assistant(sessionPersonaId: String? = nil) -> String {
        SoulStore.displayName(for: SoulStore.displayPersonaId(sessionPersonaId))
    }

    /// 说话的人叫什么（界面可见文案用）。
    /// [B28 R11] 优先级：通讯录「我自己」档案里的「怎么称呼」
    /// → 外观工作室填的称呼 → 中性词。哪来的就用哪来的，绝不写死名字。
    static func user() -> String {
        let fromProfile = SystemPromptBuilder.userProfileAddressingName()
        if !fromProfile.isEmpty { return fromProfile }
        let n = AppearanceStudio.shared.userDisplayName
        return n.isEmpty ? AppLocalized("你") : n
    }

    /// 说话的人叫什么（注入给模型的提示词用）。
    static func userForModel() -> String {
        let fromProfile = SystemPromptBuilder.userProfileAddressingName()
        if !fromProfile.isEmpty { return fromProfile }
        let n = AppearanceStudio.shared.userDisplayName
        return n.isEmpty ? AppLocalized("用户") : n
    }
}

private extension UIImage {
    /// [T-56] Rough decoded size, used as the wallpaper cache's cost.
    var cacheCost: Int {
        guard let cg = cgImage else { return 2 * 1024 * 1024 }
        return max(cg.bytesPerRow * cg.height, 64 * 1024)
    }
}
