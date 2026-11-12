import Foundation
import SwiftUI
import UIKit

// MARK: - Bubble style packs, step 1 (record + catalogue + grid + tap-apply)
//
// A pack is STRUCTURE only. It never carries a colour, a wallpaper, a
// remote image, or CSS — colours and wallpapers stay in the theme pack,
// so a pack composes with any theme and can never overwrite a user's
// colours when applied. Border "colour" is deliberately NOT a pack
// field: the pack sets border width/presence only, and the border
// colour keeps coming from the theme's `.border` role.
//
// Live chat wiring (fixer, step 1 review): apply() writes the FULL
// structural record to the live theme pack — display, both bubble
// styles, both radii, both surfaces, both border widths, both
// paddings, avatar size/border, message spacing, meta and name
// placement, corner preset, input-bar style and radius — and the
// chat rows read those fields (see MinisThemeShape). It never
// touches colours, opacity, text slots, wallpapers, avatar shape,
// or the theme library. Two honest exceptions, both visible in the
// samples too: assistant avatar placement stays inline (the AI
// header is a separate list cell and cannot overlap a bubble cell),
// and assistant name above/inline both render as the header name
// (the name cannot move into a bubble row in the split-cell list).
// Assistant meta below renders under the last text block; a
// tool-only turn has no text block, so it shows no meta line.

/// Bubble border chrome, shared by user and assistant bubbles.
/// Width 0 = no-op, so the default (no border) rendering is
/// identical to before: no clip, no stroke added. When the shape
/// carries a pack kind, the chrome draws that kind's border:
/// letter = double frame (outer + inset stroke), stitch = dashed
/// stroke. Stitch is the dashed border in shop samples, detail
/// previews, and live chat alike — there is no ribbon tab in any
/// of the three, so a sample never promises what live chat omits.
struct BubbleBorderChrome: ViewModifier {
    let shape: MinisBubbleShape
    let width: CGFloat

    func body(content: Content) -> some View {
        if width > 0 {
            content
                .clipShape(shape)
                .overlay(borderOverlay)
        } else {
            content
        }
    }

    @ViewBuilder
    private var borderOverlay: some View {
        let colour = AppearanceStudio.shared.color(.border, scope: .chat)
        if shape.packKind == .letter {
            shape.stroke(colour, lineWidth: width)
            shape.stroke(colour, lineWidth: max(0.5, width * 0.75))
                .padding(4)
        } else if shape.packKind == .stitch {
            shape.stroke(colour, style: StrokeStyle(lineWidth: width, dash: [4, 3]))
        } else {
            shape.stroke(colour, lineWidth: width)
        }
    }
}

/// The pack's whole visual shape — the thing that makes one pack
/// instantly distinguishable from another at a glance. This is
/// NOT a radius/tail tweak: each kind draws a different outline.
/// Colours still come from the theme, never from the pack.
enum BubblePackKind: String, CaseIterable, Codable {
    case porcelain, cloud, letter, wave, cut, stitch
    var title: String {
        switch self {
        case .porcelain: return AppLocalized("瓷白圆润")
        case .cloud: return AppLocalized("云朵")
        case .letter: return AppLocalized("信纸")
        case .wave: return AppLocalized("波浪")
        case .cut: return AppLocalized("方章")
        case .stitch: return AppLocalized("丝带针脚")
        }
    }
    static func parse(_ raw: String?) -> BubblePackKind {
        guard let raw, let value = BubblePackKind(rawValue: raw) else { return .porcelain }
        return value
    }
}

/// Outline for one pack kind, shared by shop samples, detail
/// previews, and live chat (via MinisBubbleShape.packKind), so
/// sample and live can never drift apart into two truths.
struct BubblePackOutlineShape: Shape {
    var kind: BubblePackKind
    var radius: CGFloat

    func path(in rect: CGRect) -> Path {
        switch kind {
        case .porcelain:
            // Fixed radius from the pack's radius field, not
            // min(height, width) / 2: a long message must stay a
            // rounded rectangle and only grow downward, never
            // balloon into an ellipse that clips its own text.
            return Path(RoundedRectangle(cornerRadius: min(max(radius, 4), 32),
                                         style: .continuous).path(in: rect).cgPath)
        case .cloud:
            // Same cloud at any length: the middle stretches
            // straight, the bumps do not multiply. Bump centres are
            // anchored a fixed distance from the ends (plus the
            // centre one), never spaced by a fraction of the width
            // — fraction spacing is what stretched the short
            // cloud's bumps apart into a caterpillar on a long
            // bubble. Count is unchanged: three bumps on the top
            // edge, three on the bottom, at every length.
            //
            // But a fixed 12pt bump does NOT survive stretching:
            // on a ~380pt long bubble it is a tiny nub on a long
            // flat slab and the shape reads as a plain rounded
            // rectangle. So the bump grows with width past the
            // short-bubble threshold, and only there: at or below
            // 220pt wide the geometry is exactly the old one
            // (bump 12, protrusion 0.45), so the short cloud is
            // pixel-identical to before. Past 220pt the bump
            // radius grows (12 + excess/12, capped at 30), the
            // bump widens (up to 1.5x) and protrudes further
            // (up to 0.80 of its radius), so the three lobes stay
            // legible humps on a long bubble instead of nubs.
            // Long example (380pt wide): bump 25.3, half-width
            // 38, protrusion 20.2 — three wide lobes top and
            // bottom, flat middle between them, no fourth bump.
            var path = Path(RoundedRectangle(cornerRadius: 18, style: .continuous).path(in: rect).cgPath)
            let shortWidth: CGFloat = 220
            let excess = max(0, rect.width - shortWidth)
            let bump = min(12 + excess / 12, 30)
            let baseBump = min(12, rect.height / 3)
            let effectiveBump = rect.width <= shortWidth ? baseBump : bump
            let halfWidth = effectiveBump * (1 + min(0.5, excess / 320))
            let protrude = effectiveBump * (0.45 + min(0.35, excess / 460))
            let midX = rect.midX
            var centres = [rect.minX + max(effectiveBump * 2, halfWidth + 6), midX,
                           rect.maxX - max(effectiveBump * 2, halfWidth + 6)]
            centres[0] = min(centres[0], midX - halfWidth)
            centres[2] = max(centres[2], midX + halfWidth)
            for cx in centres {
                path.addEllipse(in: CGRect(x: cx - halfWidth, y: rect.minY - protrude,
                                           width: halfWidth * 2, height: effectiveBump * 2))
                path.addEllipse(in: CGRect(x: cx - halfWidth,
                                           y: rect.maxY - effectiveBump * 2 + protrude,
                                           width: halfWidth * 2, height: effectiveBump * 2))
            }
            return path
        case .letter:
            return Path(RoundedRectangle(cornerRadius: 4, style: .circular).path(in: rect).cgPath)
        case .wave:
            var path = Path()
            let r = min(8, radius)
            path.move(to: CGPoint(x: rect.minX, y: rect.minY + r))
            path.addQuadCurve(to: CGPoint(x: rect.minX + r, y: rect.minY),
                              control: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
            path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + r),
                              control: CGPoint(x: rect.maxX, y: rect.minY))
            // Wave bottom, deep enough to read as a wave at any
            // height: joints sit 18pt above the bottom, troughs
            // touch the bottom. Exactly 3 waves at every width —
            // a long bubble stretches the waves horizontally, it
            // never gains a fourth one.
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - 18))
            let waves = 3
            let step = rect.width / CGFloat(waves)
            for i in 0..<waves {
                let x0 = rect.maxX - step * CGFloat(i)
                let x1 = x0 - step / 2
                let x2 = x0 - step
                path.addCurve(to: CGPoint(x: x1, y: rect.maxY),
                              control1: CGPoint(x: x0 - step * 0.25, y: rect.maxY - 18),
                              control2: CGPoint(x: x1 - step * 0.25, y: rect.maxY))
                path.addCurve(to: CGPoint(x: x2, y: rect.maxY - 18),
                              control1: CGPoint(x: x1 + step * 0.25, y: rect.maxY),
                              control2: CGPoint(x: x2 + step * 0.25, y: rect.maxY - 18))
            }
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - 18))
            path.closeSubpath()
            return path
        case .cut:
            var path = Path()
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.22, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.22))
            path.closeSubpath()
            return path
        case .stitch:
            return Path(RoundedRectangle(cornerRadius: 12, style: .continuous).path(in: rect).cgPath)
        }
    }
}

/// MARK: - Bubble foundation for future complex image packs
///
/// The six built-in packs are shape-only, but the record must already
/// be able to carry what a complex pack needs, so a later complex
/// pack is data, not a rewrite: an image background, a procedural
/// pattern, decorative image elements, and a per-role text colour
/// that stays readable on that pack's own background. Nothing here
/// designs a complex pack — there is no built-in that sets any of
/// these fields, and no upload UI yet (that is the pendant/upload
/// batch's job). The fields are only the storage + the one shared
/// renderer every surface uses, so a future pack can never be
/// promised by the shop and missing in live chat.
///
/// Image storage: pack image files live under
/// ApplicationSupport/AppearanceStudio/bubble_pack_images/, next to
/// the pack catalogue, named by file name only. A file name that
/// contains a path separator or ".." is treated as absent — a pack
/// record must never reach outside its own directory. A missing
/// image is never a blank box: the solid theme colour underneath
/// always shows, and a missing decoration is simply skipped.

enum BubblePattern: String, CaseIterable, Codable {
    case none, dots, stripes
    var title: String {
        switch self {
        case .none: return AppLocalized("无图案")
        case .dots: return AppLocalized("圆点")
        case .stripes: return AppLocalized("斜纹")
        }
    }
    static func parse(_ raw: String?) -> BubblePattern {
        guard let raw, let value = BubblePattern(rawValue: raw) else { return .none }
        return value
    }
}

enum BubbleDecorationAnchor: String, CaseIterable, Codable {
    case topLeading, topTrailing, bottomLeading, bottomTrailing
    var alignment: Alignment {
        switch self {
        case .topLeading: return .topLeading
        case .topTrailing: return .topTrailing
        case .bottomLeading: return .bottomLeading
        case .bottomTrailing: return .bottomTrailing
        }
    }
    static func parse(_ raw: String?) -> BubbleDecorationAnchor {
        guard let raw, let value = BubbleDecorationAnchor(rawValue: raw) else { return .topTrailing }
        return value
    }
    var title: String {
        switch self {
        case .topLeading: return AppLocalized("左上")
        case .topTrailing: return AppLocalized("右上")
        case .bottomLeading: return AppLocalized("左下")
        case .bottomTrailing: return AppLocalized("右下")
        }
    }
}

/// One decorative image element on a pack: a file in the pack
/// image directory, anchored to a bubble corner, with a size and an
/// offset that may let it peek outside the bubble outline. Tolerant
/// decode: a bad file name, anchor, or size degrades to a skipped
/// decoration, never to a broken pack.
struct BubbleDecoration: Equatable, Codable {
    var imageFile: String
    var anchor: BubbleDecorationAnchor
    var size: Double
    var offsetX: Double
    var offsetY: Double

    init(imageFile: String = "", anchor: BubbleDecorationAnchor = .topTrailing,
         size: Double = 28, offsetX: Double = 0, offsetY: Double = 0) {
        self.imageFile = imageFile
        self.anchor = anchor
        self.size = min(64, max(12, size))
        self.offsetX = min(40, max(-40, offsetX))
        self.offsetY = min(40, max(-40, offsetY))
    }

    private enum CodingKeys: String, CodingKey {
        case imageFile, anchor, size, offsetX, offsetY
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        imageFile = try c.decodeIfPresent(String.self, forKey: .imageFile) ?? ""
        anchor = BubbleDecorationAnchor.parse(try c.decodeIfPresent(String.self, forKey: .anchor))
        size = min(64, max(12, try c.decodeIfPresent(Double.self, forKey: .size) ?? 28))
        offsetX = min(40, max(-40, try c.decodeIfPresent(Double.self, forKey: .offsetX) ?? 0))
        offsetY = min(40, max(-40, try c.decodeIfPresent(Double.self, forKey: .offsetY) ?? 0))
    }
}

enum BubblePackImageStore {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first!
        let dir = base.appendingPathComponent("AppearanceStudio", isDirectory: true)
            .appendingPathComponent("bubble_pack_images", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A file name is safe only as a bare name: no separators, no
    /// "..", non-empty. Anything else is absent, not an error.
    static func url(fileName: String?) -> URL? {
        guard let fileName, !fileName.isEmpty,
              !fileName.contains("/"), !fileName.contains("\\"),
              !fileName.contains("..") else { return nil }
        return directory.appendingPathComponent(fileName)
    }

    static func image(fileName: String?) -> UIImage? {
        guard let url = url(fileName: fileName) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }

    /// Custom background image file names: one fixed name per side.
    /// Replacing overwrites the same path, so a replace can never
    /// leave an orphan behind — the same fixed-name convention as
    /// the input-bar ("input-bar.jpg") and wallpaper
    /// ("wallpaper-<scope>.jpg") images. The name also tells a
    /// caller whether the field points at a user-picked image or a
    /// pack record's image: only the two names below are customs.
    static func customFileName(user: Bool) -> String {
        user ? "bubble-user.jpg" : "bubble-assistant.jpg"
    }

    /// Whether this file name is one of the per-side custom images
    /// rather than a pack record's image.
    static func isCustomFileName(_ fileName: String?, user: Bool) -> Bool {
        fileName == customFileName(user: user)
    }

    /// Stores an image as this side's custom background image:
    /// downscales to maxEdge 1400 and JPEG-encodes at 0.82 — the
    /// same numbers as the input-bar / thinking-card paths — and
    /// writes atomically, so a failed store leaves the previous
    /// image untouched. Returns the file name on success, nil on
    /// failure (callers report that honestly, never as success).
    /// Takes raw bytes, not a UIImage: the decode + downscale +
    /// encode + write all run in a background task, so a 12MP pick
    /// no longer blocks the main thread ~100–300ms. Only Data and
    /// URL (both Sendable) cross into the detached task.
    @discardableResult
    static func storeCustomImage(_ data: Data, user: Bool) async -> String? {
        let name = customFileName(user: user)
        guard let url = url(fileName: name) else { return nil }
        let ok = await Task.detached(priority: .utility) {
            guard let image = UIImage(data: data) else { return false }
            return writeDownscaledJPEG(image, to: url, maxEdge: 1400, quality: 0.82)
        }.value
        return ok ? name : nil
    }

    /// Deletes a file by bare name; silently does nothing when the
    /// name is unsafe or the file is already gone.
    static func remove(fileName: String?) {
        guard let url = url(fileName: fileName) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Deletes this side's custom image file, if there is one.
    static func removeCustomImage(user: Bool) {
        remove(fileName: customFileName(user: user))
    }

    /// Decoration image file names: one unique name per decoration.
    /// Unlike the background image (one fixed name per side), a side
    /// can hold several decorations, so each stored image gets its
    /// own "decoration-<uuid>.jpg". The prefix is also the ownership
    /// mark: only names with this prefix were created by the
    /// decoration editor, so only those are ever deleted by it —
    /// a pack record's image never carries the prefix.
    static func decorationFileName() -> String {
        "decoration-\(UUID().uuidString).jpg"
    }

    /// Whether this file name is one of the decoration editor's own
    /// images rather than a pack record's image.
    static func isDecorationFileName(_ fileName: String?) -> Bool {
        guard let fileName else { return false }
        return fileName.hasPrefix("decoration-") && fileName.hasSuffix(".jpg")
    }

    /// Stores an image as a new decoration image: same downscale
    /// (maxEdge 1400), JPEG (0.82) and atomic write as the custom
    /// background path. Returns the unique file name on success,
    /// nil on failure (callers report that honestly, never as success).
    /// Takes raw bytes, not a UIImage — same background-task reason
    /// as storeCustomImage: decode + downscale + encode + write
    /// run off the main thread; only Data and URL cross over.
    @discardableResult
    static func storeDecorationImage(_ data: Data) async -> String? {
        let name = decorationFileName()
        guard let url = url(fileName: name) else { return nil }
        let ok = await Task.detached(priority: .utility) {
            guard let image = UIImage(data: data) else { return false }
            return writeDownscaledJPEG(image, to: url, maxEdge: 1400, quality: 0.82)
        }.value
        return ok ? name : nil
    }

    /// Deletes a decoration image file, but only one this editor
    /// created. Pack images are never touched.
    static func removeDecorationImage(fileName: String?) {
        guard isDecorationFileName(fileName) else { return }
        remove(fileName: fileName)
    }

    /// Downscale + JPEG + atomic write, mirroring the wallpaper
    /// path (AppearanceThemePack.writeDownscaledJPEG): the store
    /// cannot call that private method, so the same lines live
    /// here. A failed encode or write returns false and the old
    /// file stays exactly as it was (atomic write).
    /// Only ever called from a background task now: both store
    /// entry points hop off MainActor first, because the draw +
    /// encode of a 12MP photo on the main thread used to block
    /// ~100–300ms per pick — never call this from the main thread.
    private static func writeDownscaledJPEG(_ image: UIImage, to url: URL,
                                            maxEdge: CGFloat, quality: CGFloat) -> Bool {
        let size = image.size
        let scale = min(1, maxEdge / max(size.width, size.height, 1))
        let target = CGSize(width: max(1, size.width * scale), height: max(1, size.height * scale))
        let format = UIGraphicsImageRendererFormat()
        format.opaque = true
        format.scale = 1
        let rendered = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        guard let data = rendered.jpegData(compressionQuality: quality) else { return false }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            return false
        }
        return true
    }
}

/// The one bubble surface every surface uses: solid colour first
/// (never blank), then the pack's image background scaled to fill
/// and clipped to the bubble shape, then its pattern at low
/// opacity in the pack's text colour. Shop cards, detail previews,
/// and live chat all call this with their own shape/colour and
/// the same record fields, so they cannot drift apart.
struct BubblePackSurfaceBackground: View {
    let shape: MinisBubbleShape
    let colour: Color
    let imageFile: String?
    let pattern: BubblePattern
    let patternOpacity: Double
    let textColour: Color
    var dim: Double = 1

    var body: some View {
        ZStack {
            colour
            if let uiImage = BubblePackImageStore.image(fileName: imageFile) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
            }
            if pattern != .none {
                BubblePatternView(pattern: pattern, colour: textColour,
                                  opacity: patternOpacity)
            }
        }
        .clipShape(shape)
        .opacity(dim)
    }
}

/// Decorations drawn OVER the bubble (after clip + border chrome),
/// so a corner element may peek outside the outline. Missing image
/// files are skipped, never drawn as empty frames.
struct BubblePackDecorationsView: View {
    let decorations: [BubbleDecoration]

    var body: some View {
        ZStack {
            ForEach(Array(decorations.enumerated()), id: \.offset) { _, decoration in
                if let uiImage = BubblePackImageStore.image(fileName: decoration.imageFile) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: CGFloat(decoration.size), height: CGFloat(decoration.size))
                        .offset(x: CGFloat(decoration.offsetX), y: CGFloat(decoration.offsetY))
                        .frame(maxWidth: .infinity, maxHeight: .infinity,
                               alignment: decoration.anchor.alignment)
                }
            }
        }
    }
}

private struct BubblePatternView: View {
    let pattern: BubblePattern
    let colour: Color
    let opacity: Double

    var body: some View {
        Canvas { context, size in
            switch pattern {
            case .none:
                break
            case .dots:
                let step: CGFloat = 18
                var y: CGFloat = 9
                while y < size.height {
                    var x: CGFloat = 9
                    while x < size.width {
                        let rect = CGRect(x: x - 1.5, y: y - 1.5, width: 3, height: 3)
                        context.fill(Path(ellipseIn: rect), with: .color(colour.opacity(opacity)))
                        x += step
                    }
                    y += step
                }
            case .stripes:
                let step: CGFloat = 16
                var offset: CGFloat = -size.height
                while offset < size.width {
                    var path = Path()
                    path.move(to: CGPoint(x: offset, y: 0))
                    path.addLine(to: CGPoint(x: offset + size.height, y: size.height))
                    context.stroke(path, with: .color(colour.opacity(opacity)), lineWidth: 1.5)
                    offset += step
                }
            }
        }
    }
}

/// Row-bubble = the bubble spans the message row; text-bubble = the
/// bubble hugs the text only.
enum BubbleSurface: String, CaseIterable, Codable {
    case row, text
    var title: String {
        switch self {
        case .row: return AppLocalized("整行气泡")
        case .text: return AppLocalized("文字气泡")
        }
    }
    static func parse(_ raw: String?) -> BubbleSurface {
        guard let raw, let value = BubbleSurface(rawValue: raw) else { return .row }
        return value
    }
}

/// Corner treatment. `asymmetric` = one outer corner near-sharp, the
/// rest rounded — the QQ/ST "tail direction" read, without a tail.
enum BubbleCornerPreset: String, CaseIterable, Codable {
    case even, asymmetric, pill, sharp
    var title: String {
        switch self {
        case .even: return AppLocalized("均匀圆角")
        case .asymmetric: return AppLocalized("不对称圆角")
        case .pill: return AppLocalized("胶囊")
        case .sharp: return AppLocalized("方一点")
        }
    }
    static func parse(_ raw: String?) -> BubbleCornerPreset {
        guard let raw, let value = BubbleCornerPreset(rawValue: raw) else { return .even }
        return value
    }
}

/// Where the avatar sits relative to the bubble.
enum BubbleAvatarPlacement: String, CaseIterable, Codable {
    case inline, overlapping
    var title: String {
        switch self {
        case .inline: return AppLocalized("行内头像")
        case .overlapping: return AppLocalized("压在气泡上")
        }
    }
    static func parse(_ raw: String?) -> BubbleAvatarPlacement {
        guard let raw, let value = BubbleAvatarPlacement(rawValue: raw) else { return .inline }
        return value
    }
}

/// Time/meta line placement for one role.
enum BubbleMetaPosition: String, CaseIterable, Codable {
    case hidden, above, below
    var title: String {
        switch self {
        case .hidden: return AppLocalized("不显示时间")
        case .above: return AppLocalized("时间在上")
        case .below: return AppLocalized("时间在下")
        }
    }
    static func parse(_ raw: String?) -> BubbleMetaPosition {
        guard let raw, let value = BubbleMetaPosition(rawValue: raw) else { return .below }
        return value
    }
}

/// Name row placement for one role.
enum BubbleNamePlacement: String, CaseIterable, Codable {
    case hidden, above, inline
    var title: String {
        switch self {
        case .hidden: return AppLocalized("不显示名字")
        case .above: return AppLocalized("名字在上")
        case .inline: return AppLocalized("名字在行内")
        }
    }
    static func parse(_ raw: String?) -> BubbleNamePlacement {
        guard let raw, let value = BubbleNamePlacement(rawValue: raw) else { return .above }
        return value
    }
}

/// Input-bar form. `flat` = minimal radius, no pill rounding.
enum BubbleInputBarForm: String, CaseIterable, Codable {
    case pill, rounded, flat
    var title: String {
        switch self {
        case .pill: return AppLocalized("胶囊输入栏")
        case .rounded: return AppLocalized("圆角输入栏")
        case .flat: return AppLocalized("平直输入栏")
        }
    }
    static func parse(_ raw: String?) -> BubbleInputBarForm {
        guard let raw, let value = BubbleInputBarForm(rawValue: raw) else { return .rounded }
        return value
    }
}

/// Structural style record. Tolerant decode: any unknown or missing
/// field falls back to the default value instead of discarding the
/// whole pack, mirroring the sticker catalogue pattern.
struct BubbleStyleRecord: Equatable, Codable {
    var display: AppearanceChatDisplay
    var userSurface: BubbleSurface
    var assistantSurface: BubbleSurface
    var tailOn: Bool
    var packShape: BubblePackKind
    var cornerPreset: BubbleCornerPreset
    var userRadius: Double
    var assistantRadius: Double
    var avatarPlacement: BubbleAvatarPlacement
    var avatarSize: Double
    var avatarBorderWidth: Double
    var userBorderWidth: Double
    var assistantBorderWidth: Double
    var userPadding: Double
    var assistantPadding: Double
    var messageSpacing: Double
    var userMeta: BubbleMetaPosition
    var assistantMeta: BubbleMetaPosition
    var userName: BubbleNamePlacement
    var assistantName: BubbleNamePlacement
    var inputBarForm: BubbleInputBarForm
    var inputBarRadius: Double
    // Foundation for future complex packs (all unset on the six
    // built-ins, so they render exactly as before): an image
    // background file, a procedural pattern, decorative image
    // elements, and a per-role text colour that follows the pack's
    // own background instead of the theme's bubble text slot.
    var backgroundImageFile: String?
    var pattern: BubblePattern
    var patternOpacity: Double
    var decorations: [BubbleDecoration]
    var userTextHex: String?
    var assistantTextHex: String?

    // Width fix (user device report): every pack hugs its text.
    // The old default was .row, which stretches a bubble to the
    // full row width even for short text ("宝宝" / "贴贴") — the
    // opposite of the original behaviour, where bubble width
    // follows text length. No pack uses .row anymore.
    static let `default` = BubbleStyleRecord(
        display: .bubbles,
        userSurface: .text, assistantSurface: .text,
        tailOn: false, packShape: .porcelain, cornerPreset: .even,
        userRadius: 18, assistantRadius: 16,
        avatarPlacement: .inline, avatarSize: 40, avatarBorderWidth: 0,
        userBorderWidth: 0, assistantBorderWidth: 0,
        userPadding: 14, assistantPadding: 14,
        messageSpacing: 10,
        userMeta: .below, assistantMeta: .below,
        userName: .hidden, assistantName: .above,
        inputBarForm: .rounded, inputBarRadius: 20
    )

    init(display: AppearanceChatDisplay = .bubbles,
         userSurface: BubbleSurface = .text, assistantSurface: BubbleSurface = .text,
         tailOn: Bool = false, packShape: BubblePackKind = .porcelain,
         cornerPreset: BubbleCornerPreset = .even,
         userRadius: Double = 18, assistantRadius: Double = 16,
         avatarPlacement: BubbleAvatarPlacement = .inline,
         avatarSize: Double = 40, avatarBorderWidth: Double = 0,
         userBorderWidth: Double = 0, assistantBorderWidth: Double = 0,
         userPadding: Double = 14, assistantPadding: Double = 14,
         messageSpacing: Double = 10,
         userMeta: BubbleMetaPosition = .below, assistantMeta: BubbleMetaPosition = .below,
         userName: BubbleNamePlacement = .hidden, assistantName: BubbleNamePlacement = .above,
         inputBarForm: BubbleInputBarForm = .rounded, inputBarRadius: Double = 20,
         backgroundImageFile: String? = nil, pattern: BubblePattern = .none,
         patternOpacity: Double = 0.15, decorations: [BubbleDecoration] = [],
         userTextHex: String? = nil, assistantTextHex: String? = nil) {
        self.display = display
        self.userSurface = userSurface
        self.assistantSurface = assistantSurface
        self.tailOn = tailOn
        self.packShape = packShape
        self.cornerPreset = cornerPreset
        self.userRadius = BubbleStyleRecord.clampRadius(userRadius)
        self.assistantRadius = BubbleStyleRecord.clampRadius(assistantRadius)
        self.avatarPlacement = avatarPlacement
        self.avatarSize = min(64, max(28, avatarSize))
        self.avatarBorderWidth = min(3, max(0, avatarBorderWidth))
        self.userBorderWidth = min(2, max(0, userBorderWidth))
        self.assistantBorderWidth = min(2, max(0, assistantBorderWidth))
        self.userPadding = min(20, max(8, userPadding))
        self.assistantPadding = min(20, max(8, assistantPadding))
        self.messageSpacing = min(24, max(4, messageSpacing))
        self.userMeta = userMeta
        self.assistantMeta = assistantMeta
        self.userName = userName
        self.assistantName = assistantName
        self.inputBarForm = inputBarForm
        self.inputBarRadius = BubbleStyleRecord.clampRadius(inputBarRadius)
        self.backgroundImageFile = (backgroundImageFile?.isEmpty == true) ? nil : backgroundImageFile
        self.pattern = pattern
        self.patternOpacity = min(0.6, max(0, patternOpacity))
        self.decorations = decorations
        self.userTextHex = BubbleStyleRecord.normalizedPackHex(userTextHex)
        self.assistantTextHex = BubbleStyleRecord.normalizedPackHex(assistantTextHex)
    }

    /// Pack text hex: a bare 6/8-digit hex, or nil when unset or
    /// invalid — an invalid value falls back to the theme slot,
    /// never to black. (The theme pack's own normalizer lives in
    /// AppearanceThemePack.swift and is fileprivate there, so this
    /// record normalizes with the same rule, not a second rule.)
    static func normalizedPackHex(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: CharacterSet.alphanumerics.inverted).uppercased()
        guard (trimmed.count == 6 || trimmed.count == 8),
              trimmed.allSatisfy({ $0.isHexDigit }) else { return nil }
        return trimmed
    }

    /// Pack text colour for one role, or nil when the pack carries
    /// none — the caller falls back to the theme's bubble text slot.
    func textColor(isUser: Bool) -> Color? {
        let hex = isUser ? userTextHex : assistantTextHex
        guard let hex else { return nil }
        return Color(hex: hex)
    }

    static func clampRadius(_ value: Double) -> Double { min(32, max(4, value)) }

    /// Decorations as a JSON string for the theme pack (which is a
    /// flat JSON dictionary, not a Codable struct). Empty means
    /// "no decorations" on decode, same as nil.
    static func encodeDecorations(_ decorations: [BubbleDecoration]) -> String? {
        guard !decorations.isEmpty,
              let data = try? JSONEncoder().encode(decorations),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return json
    }

    static func decodeDecorations(_ json: String?) -> [BubbleDecoration] {
        guard let json, let data = json.data(using: .utf8),
              let value = try? JSONDecoder().decode([BubbleDecoration].self, from: data) else { return [] }
        return value
    }

    private enum CodingKeys: String, CodingKey {
        case display, userSurface, assistantSurface, tailOn, packShape, cornerPreset
        case userRadius, assistantRadius, avatarPlacement, avatarSize, avatarBorderWidth
        case userBorderWidth, assistantBorderWidth, userPadding, assistantPadding
        case messageSpacing, userMeta, assistantMeta, userName, assistantName
        case inputBarForm, inputBarRadius
        case backgroundImageFile, pattern, patternOpacity, decorations
        case userTextHex, assistantTextHex
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = BubbleStyleRecord.default
        if let raw = try c.decodeIfPresent(String.self, forKey: .display),
           let parsed = AppearanceChatDisplay(rawValue: raw) {
            display = parsed
        } else {
            display = d.display
        }
        userSurface = BubbleSurface.parse(try c.decodeIfPresent(String.self, forKey: .userSurface))
        assistantSurface = BubbleSurface.parse(try c.decodeIfPresent(String.self, forKey: .assistantSurface))
        tailOn = try c.decodeIfPresent(Bool.self, forKey: .tailOn) ?? d.tailOn
        packShape = BubblePackKind.parse(try c.decodeIfPresent(String.self, forKey: .packShape))
        cornerPreset = BubbleCornerPreset.parse(try c.decodeIfPresent(String.self, forKey: .cornerPreset))
        userRadius = BubbleStyleRecord.clampRadius(try c.decodeIfPresent(Double.self, forKey: .userRadius) ?? d.userRadius)
        assistantRadius = BubbleStyleRecord.clampRadius(try c.decodeIfPresent(Double.self, forKey: .assistantRadius) ?? d.assistantRadius)
        avatarPlacement = BubbleAvatarPlacement.parse(try c.decodeIfPresent(String.self, forKey: .avatarPlacement))
        avatarSize = min(64, max(28, try c.decodeIfPresent(Double.self, forKey: .avatarSize) ?? d.avatarSize))
        avatarBorderWidth = min(3, max(0, try c.decodeIfPresent(Double.self, forKey: .avatarBorderWidth) ?? d.avatarBorderWidth))
        userBorderWidth = min(2, max(0, try c.decodeIfPresent(Double.self, forKey: .userBorderWidth) ?? d.userBorderWidth))
        assistantBorderWidth = min(2, max(0, try c.decodeIfPresent(Double.self, forKey: .assistantBorderWidth) ?? d.assistantBorderWidth))
        userPadding = min(20, max(8, try c.decodeIfPresent(Double.self, forKey: .userPadding) ?? d.userPadding))
        assistantPadding = min(20, max(8, try c.decodeIfPresent(Double.self, forKey: .assistantPadding) ?? d.assistantPadding))
        messageSpacing = min(24, max(4, try c.decodeIfPresent(Double.self, forKey: .messageSpacing) ?? d.messageSpacing))
        userMeta = BubbleMetaPosition.parse(try c.decodeIfPresent(String.self, forKey: .userMeta))
        assistantMeta = BubbleMetaPosition.parse(try c.decodeIfPresent(String.self, forKey: .assistantMeta))
        userName = BubbleNamePlacement.parse(try c.decodeIfPresent(String.self, forKey: .userName))
        assistantName = BubbleNamePlacement.parse(try c.decodeIfPresent(String.self, forKey: .assistantName))
        inputBarForm = BubbleInputBarForm.parse(try c.decodeIfPresent(String.self, forKey: .inputBarForm))
        inputBarRadius = BubbleStyleRecord.clampRadius(try c.decodeIfPresent(Double.self, forKey: .inputBarRadius) ?? d.inputBarRadius)
        let rawImageFile = try c.decodeIfPresent(String.self, forKey: .backgroundImageFile)
        backgroundImageFile = (rawImageFile?.isEmpty == true) ? nil : rawImageFile
        pattern = BubblePattern.parse(try c.decodeIfPresent(String.self, forKey: .pattern))
        patternOpacity = min(0.6, max(0, try c.decodeIfPresent(Double.self, forKey: .patternOpacity) ?? d.patternOpacity))
        if let decoded = try? c.decodeIfPresent([BubbleDecoration].self, forKey: .decorations) {
            decorations = decoded
        } else {
            decorations = []
        }
        userTextHex = BubbleStyleRecord.normalizedPackHex(try c.decodeIfPresent(String.self, forKey: .userTextHex))
        assistantTextHex = BubbleStyleRecord.normalizedPackHex(try c.decodeIfPresent(String.self, forKey: .assistantTextHex))
    }

    /// Bubble style the live theme pack understands, for one role.
    /// Asymmetric corners map to rounded live; the asymmetry itself
    /// now travels in the theme pack's bubbleCornerPreset and is
    /// drawn by MinisBubbleShape's per-corner radii (see
    /// MinisThemeShape.cornerRadii), so sample and live agree.
    func liveStyle() -> AppearanceBubbleStyle {
        if tailOn { return .tail }
        switch packShape {
        case .porcelain: return .pill
        case .letter: return .sharp
        case .cloud, .wave, .cut, .stitch: return .rounded
        }
    }

    func liveInputBarStyle() -> AppearanceBubbleStyle {
        switch inputBarForm {
        case .pill: return .pill
        case .rounded: return .rounded
        case .flat: return .sharp
        }
    }
}

/// One catalogue entry. `number` is the stable, never-reused
/// identifier (BUB-0001 style) shown next to the name in UI and used
/// by the AI instead of guessing from a name.
struct BubbleStylePack: Identifiable, Equatable, Codable {
    var number: String
    var title: String
    var category: String
    /// Shop tag rail value for bubble packs: 柔和 / 简约, matching
    /// the dressing-shop draft (kept packs: BUB-0001/0003 柔和,
    /// BUB-0006 简约). Persisted on the pack so the shop, the detail sheet,
    /// and any AI lookup read the same record — no second source
    /// of truth. The shared rail also carries 清新 / 淡雅, which
    /// match theme / pendant records in the draft, not bubbles.
    var tag: String
    var useCount: Int
    var style: BubbleStyleRecord

    var id: String { number }

    /// What this pack is made of, derived from this same record
    /// (shape + display + surfaces), so the detail sheet can
    /// never describe a different pack than the shop applied.
    var composition: [String] {
        var parts = [style.packShape.title, style.display.title,
                     style.userSurface.title, style.assistantSurface.title]
        if style.backgroundImageFile != nil { parts.append(AppLocalized("图片底")) }
        if style.pattern != .none { parts.append(style.pattern.title) }
        if !style.decorations.isEmpty { parts.append(AppLocalized("装饰件")) }
        return parts
    }

    private enum CodingKeys: String, CodingKey {
        case number, title, category, tag, useCount, style
    }

    init(number: String, title: String, category: String, tag: String = "",
         useCount: Int = 0, style: BubbleStyleRecord) {
        self.number = number
        self.title = title
        self.category = category
        self.tag = tag
        self.useCount = max(0, useCount)
        self.style = style
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        number = try c.decodeIfPresent(String.self, forKey: .number) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        category = try c.decodeIfPresent(String.self, forKey: .category) ?? ""
        tag = try c.decodeIfPresent(String.self, forKey: .tag) ?? ""
        useCount = max(0, try c.decodeIfPresent(Int.self, forKey: .useCount) ?? 0)
        style = try c.decodeIfPresent(BubbleStyleRecord.self, forKey: .style) ?? .default
    }
}

private struct BubblePackCatalogData: Codable {
    var packs: [BubbleStylePack]
    /// Legacy single applied number (pre-per-side catalogues).
    /// Read for migration only; this version never writes it.
    var appliedNumber: String?
    /// Applied pack number, per side. A side with no number has
    /// no pack applied (live chat shows the theme's own shape
    /// for that side until one is picked).
    var appliedUserNumber: String?
    var appliedAssistantNumber: String?
    var nextSerial: Int

    private enum CodingKeys: String, CodingKey {
        case packs, appliedNumber, appliedUserNumber, appliedAssistantNumber, nextSerial
    }

    init(packs: [BubbleStylePack], appliedNumber: String? = nil,
         appliedUserNumber: String? = nil, appliedAssistantNumber: String? = nil,
         nextSerial: Int) {
        self.packs = packs
        self.appliedNumber = appliedNumber
        self.appliedUserNumber = appliedUserNumber
        self.appliedAssistantNumber = appliedAssistantNumber
        self.nextSerial = nextSerial
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        packs = try c.decodeIfPresent([BubbleStylePack].self, forKey: .packs) ?? []
        appliedNumber = try c.decodeIfPresent(String.self, forKey: .appliedNumber)
        appliedUserNumber = try c.decodeIfPresent(String.self, forKey: .appliedUserNumber)
        appliedAssistantNumber = try c.decodeIfPresent(String.self, forKey: .appliedAssistantNumber)
        nextSerial = max(1, try c.decodeIfPresent(Int.self, forKey: .nextSerial) ?? 1)
    }
}

/// Catalogue store, mirroring the sticker catalogue pattern:
/// tolerant decode, built-ins on first run, numbers never reused
/// (nextSerial only moves forward; step 1 has no delete, so no
/// tombstones are needed yet).
@MainActor
final class BubbleStylePackStore: ObservableObject {
    static let shared = BubbleStylePackStore()

    @Published private(set) var packs: [BubbleStylePack] = []
    /// Applied pack number, per side — the two sides may wear
    /// different packs, and changing one side never moves the
    /// other. Records store only pack numbers, never a persona
    /// or user name (see DressingSide).
    @Published private(set) var appliedUserNumber: String?
    @Published private(set) var appliedAssistantNumber: String?

    func appliedNumber(for side: DressingSide) -> String? {
        side.isUser ? appliedUserNumber : appliedAssistantNumber
    }

    /// Pack worn by one side, or nil.
    func appliedPack(for side: DressingSide) -> BubbleStylePack? {
        guard let number = appliedNumber(for: side) else { return nil }
        return pack(number: number)
    }

    /// Numbers applied on either side (the studio grid, which
    /// has no side picker, marks a pack "in use" if any side
    /// wears it).
    var appliedNumbers: [String] {
        [appliedUserNumber, appliedAssistantNumber].compactMap { $0 }
    }

    private var nextSerial = 7

    /// Three packs, kept by the user on device (2026-11-01):
    /// porcelain, letter, stitch. Cloud, wave, and cut were
    /// removed from the catalogue in the same batch — their
    /// numbers (BUB-0002/0004/0005) are never reused, so a
    /// stored record naming one can only be a stale record.
    /// Titles and numbers match the dressing-shop draft, so
    /// shop, detail, and live chat all name the same pack.
    static let builtIns: [BubbleStylePack] = [
        BubbleStylePack(
            number: "BUB-0001", title: "瓷白圆润", category: "气泡", tag: "柔和",
            style: .default),
        BubbleStylePack(
            number: "BUB-0003", title: "信纸", category: "气泡", tag: "柔和",
            style: BubbleStyleRecord(
                userSurface: .text, assistantSurface: .text,
                tailOn: false, packShape: .letter, cornerPreset: .even,
                userRadius: 8, assistantRadius: 8,
                avatarPlacement: .inline, avatarSize: 40, avatarBorderWidth: 1,
                userBorderWidth: 1, assistantBorderWidth: 1,
                userPadding: 16, assistantPadding: 16,
                messageSpacing: 14,
                userName: .above, assistantName: .above,
                inputBarForm: .rounded, inputBarRadius: 16)),
        BubbleStylePack(
            number: "BUB-0006", title: "丝带针脚", category: "气泡", tag: "简约",
            style: BubbleStyleRecord(
                userSurface: .text, assistantSurface: .text,
                tailOn: false, packShape: .stitch, cornerPreset: .even,
                userRadius: 14, assistantRadius: 14,
                avatarPlacement: .inline, avatarSize: 40, avatarBorderWidth: 1,
                userBorderWidth: 1, assistantBorderWidth: 1,
                userPadding: 16, assistantPadding: 16,
                messageSpacing: 12,
                userName: .hidden, assistantName: .above,
                inputBarForm: .rounded, inputBarRadius: 20)),
    ]

    private var catalogURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first!
        let dir = base.appendingPathComponent("AppearanceStudio", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("bubble_packs_catalog.json")
    }

    private init() { load() }

    private func load() {
        if let data = try? Data(contentsOf: catalogURL),
           let catalog = try? JSONDecoder().decode(BubblePackCatalogData.self, from: data),
           !catalog.packs.isEmpty,
           !catalog.packs.contains(where: { $0.number.isEmpty }) {
            // Migration to the three-pack catalogue: no user-created
            // packs exist (there is no create API), so a stored
            // catalogue can only hold old built-ins. Keep each
            // pack's useCount, but take the shape/tag/title from
            // the current built-ins, so a stored record for a
            // removed pack can never survive as a stale record.
            // The applied number is kept ONLY if the
            // stored applied pack's style still equals its built-in
            // style — otherwise the live theme does not actually
            // show that pack, and keeping the claim would make the
            // shop lie about what is in use. A cleared claim is
            // restored honestly the next time the user taps a pack,
            // when apply() writes the full shape to the live theme.
            // Tag/title-only changes do not clear the claim: the
            // live shape is unchanged by metadata.
            var useCounts: [String: Int] = [:]
            for stored in catalog.packs {
                useCounts[stored.number] = stored.useCount
            }
            packs = Self.builtIns.map { builtIn in
                var pack = builtIn
                pack.useCount = useCounts[builtIn.number] ?? 0
                return pack
            }
            // Per-side resolution of the applied numbers. Each
            // side's number is kept ONLY if the stored pack's
            // style still equals its built-in style — otherwise
            // the live theme does not actually show that pack,
            // and keeping the claim would make the shop lie about
            // what is in use. A cleared claim is restored honestly
            // the next time the user taps a pack for that side,
            // when apply() writes that side's fields to the live
            // theme. Tag/title-only changes do not clear the claim:
            // the live shape is unchanged by metadata.
            // Migration: a pre-per-side catalogue has only the
            // legacy appliedNumber, which becomes BOTH sides'
            // number (first launch looks exactly as before). A
            // catalogue written by this version has no legacy
            // number, so a nil per-side number stays nil — it is
            // never refilled from a stale legacy value, because
            // this version never writes one.
            func resolve(_ sideNumber: String?) -> String? {
                guard let number = sideNumber ?? catalog.appliedNumber,
                      let builtIn = Self.builtIns.first(where: { $0.number == number }),
                      let stored = catalog.packs.first(where: { $0.number == number }) else { return nil }
                // Width-fix tolerance: the bubble-width fix changed
                // only the surface fields (.row -> .text) on the
                // formerly-row packs. A stored pack that differs
                // from its built-in ONLY in surface is still the
                // same pack in use, so its claim survives; any
                // other difference (shape, radius, padding, …)
                // still clears the claim, as before.
                var adjusted = stored
                adjusted.style.userSurface = builtIn.style.userSurface
                adjusted.style.assistantSurface = builtIn.style.assistantSurface
                guard adjusted.style == builtIn.style else { return nil }
                return number
            }
            appliedUserNumber = resolve(catalog.appliedUserNumber)
            appliedAssistantNumber = resolve(catalog.appliedAssistantNumber)
            nextSerial = max(7, catalog.nextSerial)
            // Subtraction fallback, per side: if a side's stored
            // applied pack is one of the removed numbers, it is no
            // longer in builtIns, so that side's number above is
            // nil while live chat would still show the removed
            // shape for that side. Apply the kept porcelain pack
            // to THAT side only, so live chat, shop, and the
            // now-wearing strip agree again; the other side's
            // pack is untouched. Outfit rows are a separate store
            // and are never touched here.
            for side in DressingSide.allCases {
                let candidate = (side.isUser ? catalog.appliedUserNumber : catalog.appliedAssistantNumber)
                    ?? catalog.appliedNumber
                if candidate != nil,
                   !Self.builtIns.contains(where: { $0.number == candidate }),
                   appliedNumber(for: side) == nil,
                   let fallback = Self.builtIns.first(where: { $0.number == "BUB-0001" }) {
                    apply(fallback, for: side)
                }
            }
            return
        }
        // First run, or an unreadable catalogue: built-ins in memory.
        // A corrupt file is left alone until the next save, so a bad
        // write never silently destroys a catalogue the user could
        // still recover by hand.
        packs = Self.builtIns
        appliedUserNumber = nil
        appliedAssistantNumber = nil
        nextSerial = 7
    }

    private func save() {
        let catalog = BubblePackCatalogData(
            packs: packs, appliedUserNumber: appliedUserNumber,
            appliedAssistantNumber: appliedAssistantNumber, nextSerial: nextSerial)
        guard let data = try? JSONEncoder().encode(catalog) else { return }
        try? data.write(to: catalogURL, options: .atomic)
    }

    func pack(number: String) -> BubbleStylePack? {
        packs.first { $0.number == number }
    }

    /// Tap-apply to ONE side. Writes only that side's fields
    /// to the live theme pack: that side's bubble style, radius,
    /// surface, border width, padding, meta and name placement,
    /// pack text colour, and that side's pack shape / image /
    /// pattern / decorations (the per-side theme fields, which
    /// live chat reads per side). The other side's fields are
    /// not touched, so its bubbles keep their own pack. Colours,
    /// opacity, wallpapers, avatar shape, and the theme library
    /// are untouched on either path.
    ///
    /// Deliberately NOT written on a one-side apply: the shared
    /// layout fields (display, corner preset, avatar size /
    /// border / placement, message spacing, input-bar style /
    /// radius). The pack record carries only one value for each,
    /// shared by both sides, so writing it for one side would
    /// move the other side's layout too — exactly the "changing
    /// one thing forces everything the same" fault this split
    /// removes. Those fields still change on the both-sides
    /// apply below, where the user means the whole conversation.
    /// The style is written straight into the theme struct, not
    /// via setBubbleStyle(), because that setter clears the
    /// shared corner preset — a one-side apply must not clear
    /// (or rewrite) shared layout at all.
    func apply(_ pack: BubbleStylePack, for side: DressingSide) {
        apply(pack, forSides: [side])
    }

    /// Tap-apply to BOTH sides (the old single-apply behaviour,
    /// kept for the studio grid, which has no side picker, and
    /// for any caller that means "the whole conversation, same
    /// pack"). In addition to both sides' fields, it writes the
    /// shared layout fields from the pack (display, avatar
    /// size/border/placement, message spacing, corner preset,
    /// input-bar style/radius, and the legacy shared shape /
    /// foundation fields) exactly as the old apply did. It still
    /// writes TWO per-side records, not one global record, so a
    /// later one-side change leaves the other side alone.
    func apply(_ pack: BubbleStylePack) {
        apply(pack, forSides: DressingSide.allCases)
    }

    private func apply(_ pack: BubbleStylePack, forSides sides: [DressingSide]) {
        let studio = AppearanceStudio.shared
        var theme = studio.currentThemePack()
        let s = pack.style
        let style = s.liveStyle()
        for side in sides {
            if side.isUser {
                // A pack replacing this side's image must not orphan
                // a user-picked custom file left behind under its
                // fixed name: delete it before the pack's name (or
                // nil) takes the field. Pack records' own images
                // are shared and never touched.
                if BubblePackImageStore.isCustomFileName(theme.userBubbleBackgroundImageFile, user: true),
                   s.backgroundImageFile != theme.userBubbleBackgroundImageFile {
                    BubblePackImageStore.removeCustomImage(user: true)
                }
                theme.userBubbleStyle = style.rawValue
                theme.userBubbleRadius = s.userRadius
                theme.userBubbleSurface = s.userSurface.rawValue
                theme.userBubbleBorderWidth = s.userBorderWidth
                theme.userBubblePadding = s.userPadding
                theme.userMetaPosition = s.userMeta.rawValue
                theme.userNamePlacement = s.userName.rawValue
                theme.userBubblePackTextHex = s.userTextHex
                theme.userBubblePackShape = s.packShape.rawValue
                theme.userBubbleBackgroundImageFile = s.backgroundImageFile
                theme.userBubblePattern = s.pattern.rawValue
                theme.userBubblePatternOpacity = s.patternOpacity
                theme.userBubbleDecorationsJSON = BubbleStyleRecord.encodeDecorations(s.decorations)
                appliedUserNumber = pack.number
            } else {
                if BubblePackImageStore.isCustomFileName(theme.assistantBubbleBackgroundImageFile, user: false),
                   s.backgroundImageFile != theme.assistantBubbleBackgroundImageFile {
                    BubblePackImageStore.removeCustomImage(user: false)
                }
                theme.assistantBubbleStyle = style.rawValue
                theme.assistantBubbleRadius = s.assistantRadius
                theme.assistantBubbleSurface = s.assistantSurface.rawValue
                theme.assistantBubbleBorderWidth = s.assistantBorderWidth
                theme.assistantBubblePadding = s.assistantPadding
                theme.assistantMetaPosition = s.assistantMeta.rawValue
                theme.assistantNamePlacement = s.assistantName.rawValue
                theme.assistantBubblePackTextHex = s.assistantTextHex
                theme.assistantBubblePackShape = s.packShape.rawValue
                theme.assistantBubbleBackgroundImageFile = s.backgroundImageFile
                theme.assistantBubblePattern = s.pattern.rawValue
                theme.assistantBubblePatternOpacity = s.patternOpacity
                theme.assistantBubbleDecorationsJSON = BubbleStyleRecord.encodeDecorations(s.decorations)
                appliedAssistantNumber = pack.number
            }
        }
        if sides.count == DressingSide.allCases.count {
            studio.setChatDisplay(s.display)
            // setChatDisplay persists its own pack; re-read so
            // the side fields above (written on the pre-display
            // snapshot) are not lost by that intermediate write.
            theme = studio.currentThemePack()
            theme.userBubbleStyle = style.rawValue
            theme.assistantBubbleStyle = style.rawValue
            theme.userBubbleRadius = s.userRadius
            theme.assistantBubbleRadius = s.assistantRadius
            theme.userBubbleSurface = s.userSurface.rawValue
            theme.assistantBubbleSurface = s.assistantSurface.rawValue
            theme.userBubbleBorderWidth = s.userBorderWidth
            theme.assistantBubbleBorderWidth = s.assistantBorderWidth
            theme.userBubblePadding = s.userPadding
            theme.assistantBubblePadding = s.assistantPadding
            theme.userBubblePackShape = s.packShape.rawValue
            theme.assistantBubblePackShape = s.packShape.rawValue
            theme.userBubbleBackgroundImageFile = s.backgroundImageFile
            theme.assistantBubbleBackgroundImageFile = s.backgroundImageFile
            theme.userBubblePattern = s.pattern.rawValue
            theme.assistantBubblePattern = s.pattern.rawValue
            theme.userBubblePatternOpacity = s.patternOpacity
            theme.assistantBubblePatternOpacity = s.patternOpacity
            theme.userBubbleDecorationsJSON = BubbleStyleRecord.encodeDecorations(s.decorations)
            theme.assistantBubbleDecorationsJSON = BubbleStyleRecord.encodeDecorations(s.decorations)
            theme.userBubblePackTextHex = s.userTextHex
            theme.assistantBubblePackTextHex = s.assistantTextHex
            theme.avatarSize = s.avatarSize
            theme.avatarBorderWidth = s.avatarBorderWidth
            theme.avatarPlacement = s.avatarPlacement.rawValue
            theme.userMetaPosition = s.userMeta.rawValue
            theme.assistantMetaPosition = s.assistantMeta.rawValue
            theme.userNamePlacement = s.userName.rawValue
            theme.assistantNamePlacement = s.assistantName.rawValue
            theme.messageSpacing = s.messageSpacing
            theme.bubbleCornerPreset = s.cornerPreset.rawValue
            theme.bubblePackShape = s.packShape.rawValue
            // Legacy shared foundation fields, kept in step so
            // any reader still on the shared fields sees the
            // same pack the per-side fields describe.
            theme.bubbleBackgroundImageFile = s.backgroundImageFile
            theme.bubblePattern = s.pattern.rawValue
            theme.bubblePatternOpacity = s.patternOpacity
            theme.bubbleDecorationsJSON = BubbleStyleRecord.encodeDecorations(s.decorations)
            theme.inputBarRadius = s.inputBarRadius
            theme.inputBarStyle = s.liveInputBarStyle().rawValue
        }
        studio.persistPack(theme)
        if let index = packs.firstIndex(where: { $0.number == pack.number }) {
            packs[index].useCount += 1
        }
        save()
    }
}
