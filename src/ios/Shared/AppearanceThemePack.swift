import Foundation
import SwiftUI
import UIKit

/// Shape + thinking chrome that a theme pack can swap.
/// Colors stay in AppearanceStudio; this file owns everything the palette
/// could not reach: radii, thinking card, pack identity.
struct AppearanceThemePack: Equatable, Codable, Identifiable {
    var id: String
    var name: String
    var userBubbleRadius: Double
    var assistantBubbleRadius: Double
    var thinkingRadius: Double
    var thinkingFillHex: String
    var thinkingStrokeHex: String
    var thinkingAccentHex: String
    var wallpaperShade: Double?
    var surfaceOpacity: Double?
    var colorsLight: [String: String]
    var colorsDark: [String: String]
    var wallpaperJPEGBase64: String?

    static let currentKey = "appearanceStudio.themePack.v1"
    static let schemaVersion = 1

    static let `default` = AppearanceThemePack(
        id: "warm-paper",
        name: "暖纸",
        userBubbleRadius: 18,
        assistantBubbleRadius: 16,
        thinkingRadius: 12,
        thinkingFillHex: "1E88E5",
        thinkingStrokeHex: "1E88E5",
        thinkingAccentHex: "1E88E5",
        wallpaperShade: 0.08,
        surfaceOpacity: 0.88,
        colorsLight: [:],
        colorsDark: [:],
        wallpaperJPEGBase64: nil
    )

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
            "colorsLight": colorsLight,
            "colorsDark": colorsDark,
        ]
        if let wallpaperShade { obj["wallpaperShade"] = wallpaperShade }
        if let surfaceOpacity { obj["surfaceOpacity"] = surfaceOpacity }
        if let wallpaperJPEGBase64 { obj["wallpaperJPEGBase64"] = wallpaperJPEGBase64 }
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
        return pack
    }

    func resetThemePack() {
        UserDefaults.standard.removeObject(forKey: Self.packKey)
        themePackLock.lock()
        cachedThemePack = .default
        themePackLoaded = true
        themePackLock.unlock()
        themePackRevision += 1
        resetColors()
        objectWillChange.send()
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
}
