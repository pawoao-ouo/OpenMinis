import Foundation
import SwiftUI
import UIKit

/// Shape + thinking chrome that a theme pack can swap.
/// Colors stay in AppearanceStudio; this file owns radii, bubble style,
/// thinking card image, pack identity.
struct AppearanceThemePack: Equatable, Codable, Identifiable {
    var id: String
    var name: String
    var userBubbleRadius: Double
    var assistantBubbleRadius: Double
    var thinkingRadius: Double
    var thinkingFillHex: String
    var thinkingStrokeHex: String
    var thinkingAccentHex: String
    var userBubbleStyle: String
    var assistantBubbleStyle: String
    var thinkingCardJPEGBase64: String?
    var thinkingCardImageOpacity: Double
    var listRowFillHex: String?
    var listIconShape: String
    var categoryIcons: [String: String]
    var categoryColors: [String: String]
    var wallpaperShade: Double?
    var surfaceOpacity: Double?
    var colorsLight: [String: String]
    var colorsDark: [String: String]
    var wallpaperJPEGBase64: String?

    static let currentKey = "appearanceStudio.themePack.v1"
    static let schemaVersion = 3
    static let categoryKeys = [
        "code", "writing", "research", "analysis", "creative", "chat", "math",
        "translation", "health", "finance", "travel", "education", "design",
        "productivity", "support", "other",
    ]

    static let `default` = AppearanceThemePack(
        id: "warm-paper",
        name: "暖纸",
        userBubbleRadius: 18,
        assistantBubbleRadius: 16,
        thinkingRadius: 12,
        thinkingFillHex: "1E88E5",
        thinkingStrokeHex: "1E88E5",
        thinkingAccentHex: "1E88E5",
        userBubbleStyle: AppearanceBubbleStyle.rounded.rawValue,
        assistantBubbleStyle: AppearanceBubbleStyle.rounded.rawValue,
        thinkingCardJPEGBase64: nil,
        thinkingCardImageOpacity: 0.28,
        listRowFillHex: nil,
        listIconShape: AppearanceListIconShape.circle.rawValue,
        categoryIcons: [:],
        categoryColors: [:],
        wallpaperShade: 0.08,
        surfaceOpacity: 0.88,
        colorsLight: [:],
        colorsDark: [:],
        wallpaperJPEGBase64: nil
    )

    var userStyle: AppearanceBubbleStyle { AppearanceBubbleStyle.parse(userBubbleStyle) }
    var assistantStyle: AppearanceBubbleStyle { AppearanceBubbleStyle.parse(assistantBubbleStyle) }

    func radius(_ kind: AppearanceShapeKind) -> CGFloat {
        switch kind {
        case .userBubble: return CGFloat(clampRadius(userBubbleRadius))
        case .assistantBubble: return CGFloat(clampRadius(assistantBubbleRadius))
        case .thinking: return CGFloat(clampRadius(thinkingRadius))
        }
    }

    func thinkingFill(opacity: Double) -> Color {
        Color(hex: thinkingFillHex).opacity(opacity)
    }

    var thinkingStroke: Color { Color(hex: thinkingStrokeHex).opacity(0.15) }
    var thinkingAccent: Color { Color(hex: thinkingAccentHex) }

    func asJSONObject() -> [String: Any] {
        var obj: [String: Any] = [
            "schema": Self.schemaVersion,
            "id": id,
            "name": name,
            "userBubbleRadius": userBubbleRadius,
            "assistantBubbleRadius": assistantBubbleRadius,
            "thinkingRadius": thinkingRadius,
            "thinkingFillHex": thinkingFillHex,
            "thinkingStrokeHex": thinkingStrokeHex,
            "thinkingAccentHex": thinkingAccentHex,
            "userBubbleStyle": userStyle.rawValue,
            "assistantBubbleStyle": assistantStyle.rawValue,
            "thinkingCardImageOpacity": thinkingCardImageOpacity,
            "listIconShape": AppearanceListIconShape.parse(listIconShape).rawValue,
            "categoryIcons": categoryIcons,
            "categoryColors": categoryColors,
            "colorsLight": colorsLight,
            "colorsDark": colorsDark,
        ]
        if let listRowFillHex { obj["listRowFillHex"] = listRowFillHex }
        if let wallpaperShade { obj["wallpaperShade"] = wallpaperShade }
        if let surfaceOpacity { obj["surfaceOpacity"] = surfaceOpacity }
        if let wallpaperJPEGBase64 { obj["wallpaperJPEGBase64"] = wallpaperJPEGBase64 }
        if let thinkingCardJPEGBase64 { obj["thinkingCardJPEGBase64"] = thinkingCardJPEGBase64 }
        return obj
    }

    static func decode(_ raw: [String: Any]) throws -> AppearanceThemePack {
        func str(_ k: String, fallback: String) -> String {
            (raw[k] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? (raw[k] as! String) : fallback
        }
        func num(_ k: String, fallback: Double) -> Double {
            if let d = raw[k] as? Double { return d }
            if let i = raw[k] as? Int { return Double(i) }
            if let s = raw[k] as? String, let d = Double(s) { return d }
            return fallback
        }
        func map(_ k: String) -> [String: String] {
            if let typed = raw[k] as? [String: String] { return typed }
            guard let anyMap = raw[k] as? [String: Any] else { return [:] }
            var out: [String: String] = [:]
            for (key, val) in anyMap {
                if let s = val as? String { out[key] = s }
            }
            return out
        }
        let base = AppearanceThemePack.default
        var pack = AppearanceThemePack(
            id: str("id", fallback: base.id),
            name: str("name", fallback: base.name),
            userBubbleRadius: clampRadius(num("userBubbleRadius", fallback: base.userBubbleRadius)),
            assistantBubbleRadius: clampRadius(num("assistantBubbleRadius", fallback: base.assistantBubbleRadius)),
            thinkingRadius: clampRadius(num("thinkingRadius", fallback: base.thinkingRadius)),
            thinkingFillHex: normalizeHex(str("thinkingFillHex", fallback: base.thinkingFillHex)),
            thinkingStrokeHex: normalizeHex(str("thinkingStrokeHex", fallback: base.thinkingStrokeHex)),
            thinkingAccentHex: normalizeHex(str("thinkingAccentHex", fallback: base.thinkingAccentHex)),
            userBubbleStyle: AppearanceBubbleStyle.parse(str("userBubbleStyle", fallback: base.userBubbleStyle)).rawValue,
            assistantBubbleStyle: AppearanceBubbleStyle.parse(str("assistantBubbleStyle", fallback: base.assistantBubbleStyle)).rawValue,
            thinkingCardJPEGBase64: raw["thinkingCardJPEGBase64"] as? String,
            thinkingCardImageOpacity: min(1, max(0.05, num("thinkingCardImageOpacity", fallback: base.thinkingCardImageOpacity))),
            listRowFillHex: (raw["listRowFillHex"] as? String).map(normalizeHex),
            listIconShape: AppearanceListIconShape.parse(str("listIconShape", fallback: base.listIconShape)).rawValue,
            categoryIcons: filterCategoryMap(map("categoryIcons"), symbols: true),
            categoryColors: filterCategoryMap(map("categoryColors"), symbols: false),
            wallpaperShade: raw["wallpaperShade"] == nil ? nil : min(0.65, max(0, num("wallpaperShade", fallback: 0.08))),
            surfaceOpacity: raw["surfaceOpacity"] == nil ? nil : min(1, max(0.35, num("surfaceOpacity", fallback: 0.88))),
            colorsLight: normalizeHexMap(map("colorsLight")),
            colorsDark: normalizeHexMap(map("colorsDark")),
            wallpaperJPEGBase64: raw["wallpaperJPEGBase64"] as? String
        )
        if pack.id.isEmpty { pack.id = base.id }
        if pack.name.isEmpty { pack.name = pack.id }
        return pack
    }
}

enum AppearanceShapeKind {
    case userBubble, assistantBubble, thinking
}

enum AppearanceListIconShape: String, CaseIterable, Identifiable {
    case circle, squircle, rounded
    var id: String { rawValue }
    var title: String {
        switch self {
        case .circle: return "圆"
        case .squircle: return "方圆"
        case .rounded: return "圆角方"
        }
    }
    static func parse(_ raw: String) -> AppearanceListIconShape {
        AppearanceListIconShape(rawValue: raw) ?? .circle
    }
}

fileprivate func filterCategoryMap(_ map: [String: String], symbols: Bool) -> [String: String] {
    let allowed = Set(AppearanceThemePack.categoryKeys)
    var out: [String: String] = [:]
    for (k, v) in map {
        guard allowed.contains(k) else { continue }
        let trimmed = v.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { continue }
        out[k] = symbols ? trimmed : normalizeHex(trimmed)
    }
    return out
}

enum AppearanceBubbleStyle: String, CaseIterable, Identifiable {
    case rounded, squircle, pill, tail, sharp
    var id: String { rawValue }
    var title: String {
        switch self {
        case .rounded: return "圆角"
        case .squircle: return "连续圆角"
        case .pill: return "胶囊"
        case .tail: return "小尾巴"
        case .sharp: return "方一点"
        }
    }
    static func parse(_ raw: String) -> AppearanceBubbleStyle {
        AppearanceBubbleStyle(rawValue: raw) ?? .rounded
    }
}

fileprivate func clampRadius(_ value: Double) -> Double {
    min(32, max(4, value))
}

fileprivate func normalizeHex(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: CharacterSet.alphanumerics.inverted).uppercased()
    if trimmed.count == 6 || trimmed.count == 8 { return trimmed }
    return "808080"
}

fileprivate func normalizeHexMap(_ map: [String: String]) -> [String: String] {
    var out: [String: String] = [:]
    let allowed = Set(AppearanceColorRole.allCases.map(\.rawValue))
    for (k, v) in map {
        guard allowed.contains(k) else { continue }
        out[k] = normalizeHex(v)
    }
    return out
}

/// Chat bubble / thinking card clip. Tail sits on the outer side
/// (user = trailing, assistant = leading).
struct MinisBubbleShape: Shape {
    var style: AppearanceBubbleStyle
    var radius: CGFloat
    var tailOnTrailing: Bool

    func path(in rect: CGRect) -> Path {
        let r = min(max(radius, 4), min(rect.width, rect.height) / 2)
        switch style {
        case .rounded:
            return rounded(rect, r, continuous: false)
        case .squircle:
            return rounded(rect, r, continuous: true)
        case .pill:
            return rounded(rect, min(rect.height, rect.width) / 2, continuous: true)
        case .sharp:
            return rounded(rect, min(6, r * 0.35), continuous: false)
        case .tail:
            return tailedPath(in: rect, corner: r)
        }
    }

    private func rounded(_ rect: CGRect, _ r: CGFloat, continuous: Bool) -> Path {
        Path(RoundedRectangle(cornerRadius: r, style: continuous ? .continuous : .circular).path(in: rect).cgPath)
    }

    private func tailedPath(in rect: CGRect, corner: CGFloat) -> Path {
        let tail: CGFloat = 7
        let body = tailOnTrailing
            ? CGRect(x: rect.minX, y: rect.minY, width: max(1, rect.width - tail), height: rect.height)
            : CGRect(x: rect.minX + tail, y: rect.minY, width: max(1, rect.width - tail), height: rect.height)
        var path = rounded(body, corner, continuous: true)
        let baseY = body.maxY - max(10, corner)
        if tailOnTrailing {
            path.move(to: CGPoint(x: body.maxX - 1, y: baseY - 7))
            path.addLine(to: CGPoint(x: rect.maxX, y: baseY))
            path.addLine(to: CGPoint(x: body.maxX - 1, y: baseY + 5))
            path.closeSubpath()
        } else {
            path.move(to: CGPoint(x: body.minX + 1, y: baseY - 7))
            path.addLine(to: CGPoint(x: rect.minX, y: baseY))
            path.addLine(to: CGPoint(x: body.minX + 1, y: baseY + 5))
            path.closeSubpath()
        }
        return path
    }
}

extension AppearanceStudio {
    private static let packKey = AppearanceThemePack.currentKey

    func loadStoredPack() -> AppearanceThemePack {
        currentThemePack()
    }

    func currentThemePack() -> AppearanceThemePack {
        themePackLock.lock()
        defer { themePackLock.unlock() }
        if !themePackLoaded {
            cachedThemePack = loadStoredPackUnlocked()
            themePackLoaded = true
        }
        return cachedThemePack
    }

    func loadStoredPackUnlocked() -> AppearanceThemePack {
        guard let data = UserDefaults.standard.data(forKey: Self.packKey),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pack = try? AppearanceThemePack.decode(obj) else {
            return .default
        }
        return pack
    }

    func persistPack(_ pack: AppearanceThemePack) {
        guard let data = try? JSONSerialization.data(withJSONObject: pack.asJSONObject()) else { return }
        UserDefaults.standard.set(data, forKey: Self.packKey)
        themePackLock.lock()
        cachedThemePack = pack
        themePackLoaded = true
        themePackLock.unlock()
        themePackRevision += 1
        objectWillChange.send()
    }

    func applyThemePack(_ pack: AppearanceThemePack, wallpaper: UIImage? = nil) {
        persistPack(pack)
        if !pack.colorsLight.isEmpty || !pack.colorsDark.isEmpty {
            applyPackColors(light: pack.colorsLight, dark: pack.colorsDark)
        }
        if let opacity = pack.surfaceOpacity { surfaceOpacity = opacity }
        if let shade = pack.wallpaperShade { wallpaperShade = shade }
        if let wallpaper {
            setWallpaper(wallpaper, for: .global)
        } else if let b64 = pack.wallpaperJPEGBase64,
                  let data = Data(base64Encoded: b64),
                  let image = UIImage(data: data) {
            setWallpaper(image, for: .global)
        }
        if let b64 = pack.thinkingCardJPEGBase64,
           let data = Data(base64Encoded: b64),
           let image = UIImage(data: data) {
            setThinkingCardImage(image)
        }
        configureUIKitSurfaces()
    }

    func exportThemePack(includeWallpaper: Bool) -> AppearanceThemePack {
        var pack = loadStoredPack()
        pack.colorsLight = exportColors(variant: .light)
        pack.colorsDark = exportColors(variant: .dark)
        pack.surfaceOpacity = surfaceOpacity
        pack.wallpaperShade = wallpaperShade
        if includeWallpaper, let image = wallpaper(for: .global),
           let data = image.jpegData(compressionQuality: 0.82) {
            pack.wallpaperJPEGBase64 = data.base64EncodedString()
        } else {
            pack.wallpaperJPEGBase64 = nil
        }
        if includeWallpaper, let image = thinkingCardImage(),
           let data = image.jpegData(compressionQuality: 0.82) {
            pack.thinkingCardJPEGBase64 = data.base64EncodedString()
        }
        return pack
    }

    func resetThemePack() {
        UserDefaults.standard.removeObject(forKey: Self.packKey)
        removeThinkingCardImage()
        themePackLock.lock()
        cachedThemePack = .default
        themePackLoaded = true
        themePackLock.unlock()
        themePackRevision += 1
        resetColors()
        objectWillChange.send()
    }

    func setBubbleStyle(_ style: AppearanceBubbleStyle, user: Bool) {
        var pack = currentThemePack()
        if user { pack.userBubbleStyle = style.rawValue }
        else { pack.assistantBubbleStyle = style.rawValue }
        persistPack(pack)
    }

    private func thinkingCardURL() -> URL {
        appearanceDirectory.appendingPathComponent("thinking-card.jpg")
    }

    func thinkingCardImage() -> UIImage? {
        UIImage(contentsOfFile: thinkingCardURL().path)
    }

    func hasThinkingCardImage() -> Bool {
        FileManager.default.fileExists(atPath: thinkingCardURL().path)
    }

    func setThinkingCardImage(_ image: UIImage) {
        let maxEdge: CGFloat = 1400
        let size = image.size
        let scale = min(1, maxEdge / max(size.width, size.height, 1))
        let target = CGSize(width: max(1, size.width * scale), height: max(1, size.height * scale))
        let format = UIGraphicsImageRendererFormat()
        format.opaque = true
        format.scale = 1
        let rendered = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        if let data = rendered.jpegData(compressionQuality: 0.82) {
            try? data.write(to: thinkingCardURL(), options: .atomic)
        }
        var pack = currentThemePack()
        pack.thinkingCardJPEGBase64 = nil
        persistPack(pack)
    }

    func removeThinkingCardImage() {
        try? FileManager.default.removeItem(at: thinkingCardURL())
        var pack = currentThemePack()
        pack.thinkingCardJPEGBase64 = nil
        persistPack(pack)
    }

    func setThinkingCardImageOpacity(_ value: Double) {
        var pack = currentThemePack()
        pack.thinkingCardImageOpacity = min(1, max(0.05, value))
        persistPack(pack)
    }

    fileprivate func applyPackColors(light: [String: String], dark: [String: String]) {
        func paint(_ map: [String: String], variant: AppearanceVariant) {
            for (raw, hex) in map {
                guard let role = AppearanceColorRole(rawValue: raw) else { continue }
                setColor(Color(hex: hex), role: role, scope: .global, variant: variant)
            }
        }
        paint(light, variant: .light)
        paint(dark, variant: .dark)
    }

    fileprivate func exportColors(variant: AppearanceVariant) -> [String: String] {
        var out: [String: String] = [:]
        for role in AppearanceColorRole.allCases {
            out[role.rawValue] = hex(role, scope: .global, variant: variant)
        }
        return out
    }
}

@MainActor
enum MinisThemeShape {
    static var pack: AppearanceThemePack { AppearanceStudio.shared.loadStoredPack() }
    static var userBubbleRadius: CGFloat { pack.radius(.userBubble) }
    static var assistantBubbleRadius: CGFloat { pack.radius(.assistantBubble) }
    static var thinkingRadius: CGFloat { pack.radius(.thinking) }
    static var thinkingFill: Color { pack.thinkingFill(opacity: 0.06) }
    static var thinkingStroke: Color { pack.thinkingStroke }
    static var thinkingAccent: Color { pack.thinkingAccent }
    static var userStyle: AppearanceBubbleStyle { pack.userStyle }
    static var assistantStyle: AppearanceBubbleStyle { pack.assistantStyle }
    static var thinkingCardOpacity: Double { pack.thinkingCardImageOpacity }

    static var userBubble: MinisBubbleShape {
        MinisBubbleShape(style: userStyle, radius: userBubbleRadius, tailOnTrailing: true)
    }
    static var assistantBubble: MinisBubbleShape {
        MinisBubbleShape(style: assistantStyle, radius: assistantBubbleRadius, tailOnTrailing: false)
    }
    static var thinkingCard: MinisBubbleShape {
        MinisBubbleShape(style: .squircle, radius: thinkingRadius, tailOnTrailing: false)
    }
}

@MainActor
enum MinisThemeList {
    static var pack: AppearanceThemePack { AppearanceStudio.shared.loadStoredPack() }

    static var title: Color { AppearanceStudio.shared.color(.primaryText, scope: .home) }
    static var subtitle: Color { AppearanceStudio.shared.color(.secondaryText, scope: .home) }
    static var meta: Color { AppearanceStudio.shared.color(.secondaryText, scope: .home).opacity(0.72) }
    static var accent: Color { AppearanceStudio.shared.color(.accent, scope: .home) }
    static var rowFill: Color {
        if let hex = pack.listRowFillHex {
            return Color(hex: hex).opacity(AppearanceStudio.shared.surfaceOpacity)
        }
        return AppearanceStudio.shared.color(.surface, scope: .home)
            .opacity(AppearanceStudio.shared.surfaceOpacity)
    }
    static var iconShape: AppearanceListIconShape {
        AppearanceListIconShape.parse(pack.listIconShape)
    }

    static func categoryIcon(for category: String?) -> (systemName: String, color: Color) {
        let fallback = sessionCategoryIconBuiltin(for: category)
        let key = category ?? "other"
        let name = pack.categoryIcons[key] ?? fallback.systemName
        if let hex = pack.categoryColors[key] {
            return (name, Color(hex: hex))
        }
        return (name, fallback.color)
    }
}
