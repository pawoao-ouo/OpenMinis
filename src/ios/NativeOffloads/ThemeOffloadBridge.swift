//
//  ThemeOffloadBridge.swift
//  MinisApp
//
//  Swift bridge for `minis-theme`. ObjC handler parses argv / files;
//  this type applies packs on the main actor.
//

import Foundation
import UIKit

@objc public class ThemeOffloadBridge: NSObject {

    /// AI-facing packs contain ONLY editable fields. Anything the AI
    /// cannot change (radii, shapes, lineHeight, …) is stripped here, so
    /// `get`/`export` output can be fed straight back to `apply` without
    /// a guaranteed `locked_field` rejection. The stripped field names
    /// are reported, never silently hidden: the AI can see what it may
    /// not touch, and the settings UI remains the only place to change it.
    private static func aiEditable(_ obj: [String: Any]) -> (cleaned: [String: Any], stripped: [String]) {
        let stripped = AppearanceThemePack.aiApplyRejectedFields(in: obj)
        var cleaned = obj
        for key in stripped { cleaned.removeValue(forKey: key) }
        return (cleaned, stripped)
    }

    /// WCAG contrast helpers for the AI apply gate (item 3).
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
        let hi = max(la, lb), lo = min(la, lb)
        return (hi + 0.05) / (lo + 0.05)
    }

    @objc public static func currentPack() -> NSDictionary {
        let sem = DispatchSemaphore(value: 0)
        var result: [String: Any] = [:]
        Task { @MainActor in
            let pack = AppearanceStudio.shared.exportThemePack(includeWallpaper: false)
            var out = pack.asJSONObject()
            // [B28 A-1] 立绘整张 base64 不再吐给 AI：几百 KB 能把上下文吃满。
            // 想看有没有，读 `hasCharacterArt`。
            out.removeValue(forKey: "characterArtBase64")
            out["hasCharacterArt"] = AppearanceStudio.shared.hasCharacterArt
            let (cleaned, stripped) = aiEditable(out)
            out = cleaned
            out["aiEditableOnly"] = true
            out["strippedLockedFields"] = stripped
            out["ok"] = true
            result = out
            sem.signal()
        }
        if sem.wait(timeout: .now() + 5) == .timedOut {
            // 超时不能当成功返回：ObjC 侧把缺 ok 视为 true，会变成
            // 「命令成功但什么都没做」。这里明确给 ok:false。
            NSLog("[CLIBridge] semaphore wait timed out")
            return ["ok": false, "error": "timeout",
                    "message": "The app did not answer within the timeout."] as NSDictionary
        }
        return result as NSDictionary
    }

    @objc public static func applyJSON(_ json: String) -> NSDictionary {
        let sem = DispatchSemaphore(value: 0)
        var result: [String: Any] = [:]
        Task { @MainActor in
            guard let data = json.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                result = [
                    "ok": false,
                    "error": "invalid_pack",
                    "message": "JSON is not a theme pack.",
                ]
                sem.signal()
                return
            }
            // [T-theme-export-roundtrip] `export` writes the tool envelope
            // (`{ok,tool,action,data,timestamp}`, NativeOffloadUtils.m:135)
            // while `apply` only ever accepted a bare pack — so the two
            // subcommands of the same CLI disagreed about what a pack looks
            // like, and `export > a.json; apply --file a.json` failed with
            // "invalid_pack". Unwrap the envelope here so anything this tool
            // emits can be fed straight back into it. A bare pack still works:
            // it has no "data" key, so the unwrap is skipped.
            let obj: [String: Any]
            if let wrapped = parsed["data"] as? [String: Any],
               parsed["tool"] != nil || parsed["action"] != nil {
                obj = wrapped
            } else {
                obj = parsed
            }
            // [AI theme lock] Tool-layer allowlist: the AI may change ONLY
            // colours, wallpaper/surface images, font sizes, and avatar
            // shape (except rectangle, which resizes). A locked field is
            // rejected with its name and NOTHING is applied — never
            // silently dropped, never partially applied. This lock is
            // for the AI apply path only; the user can still change
            // radii, spacing, and shapes in the UI.
            let locked = AppearanceThemePack.aiApplyRejectedFields(in: obj)
            if !locked.isEmpty {
                result = [
                    "ok": false,
                    "error": "locked_field",
                    "lockedFields": locked,
                    "message": "AI theme apply is locked to colours, wallpaper/surface images, font sizes, and avatar shape (except rectangle). Locked field(s) rejected, nothing was applied: \(locked.joined(separator: ", ")). Remove those fields and retry.",
                ]
                sem.signal()
                return
            }
            // Merge onto the live pack: an AI call that only names colors must
            // not reset radii, fonts, images, or anything else it left out.
            let live = AppearanceStudio.shared.currentThemePack()
            guard let pack = try? AppearanceThemePack.decode(obj, merging: live) else {
                result = [
                    "ok": false,
                    "error": "invalid_pack",
                    "message": "JSON is not a theme pack.",
                ]
                sem.signal()
                return
            }
            // [AI contrast gate] Refuse BEFORE applying, never after.
            // Only variants the JSON actually recolours are checked, so
            // a non-colour apply is never blocked by a pre-existing bad
            // palette the user set in the UI. Thresholds: body text
            // (primaryText) 4.5:1, accent (large/UI) 3:1, against canvas
            // and surface. A full pre-apply visual preview is not feasible
            // in this CLI tool path (no view is rendered here), so the
            // contrast gate is the pre-apply check; the skill text says so.
            func mapKeys(_ v: Any?) -> Set<String> {
                if let m = v as? [String: String] { return Set(m.keys) }
                if let m = v as? [String: Any] { return Set(m.keys) }
                return []
            }
            let changedLight = mapKeys(obj["colorsLight"])
            let changedDark = mapKeys(obj["colorsDark"])
            var contrastFailures: [String] = []
            for (variant, changed) in [(AppearanceVariant.light, changedLight),
                                       (AppearanceVariant.dark, changedDark)] {
                guard !changed.intersection(["primaryText", "accent", "canvas", "surface"]).isEmpty else { continue }
                let studio = AppearanceStudio.shared
                var effective: [String: String] = [:]
                for role in ["canvas", "surface", "primaryText", "accent"] {
                    guard let r = AppearanceColorRole(rawValue: role) else { continue }
                    effective[role] = studio.hex(r, scope: .global, variant: variant)
                }
                // Override ONLY with keys the JSON actually named.
                // pack.colorsLight/Dark after decode already merged the
                // live pack, so using the whole map here would let stale
                // pack colours override the studio's live resolved values
                // (e.g. colours set via `minis-theme color`, which writes
                // custom overrides, not the pack).
                let packMap = variant == .light ? pack.colorsLight : pack.colorsDark
                for k in changed where packMap[k] != nil { effective[k] = packMap[k]! }
                let checks: [(String, String, Double)] = [
                    ("primaryText", "canvas", 4.5), ("primaryText", "surface", 4.5),
                    ("accent", "canvas", 3.0), ("accent", "surface", 3.0),
                ]
                for (fg, bg, threshold) in checks {
                    guard let f = effective[fg], let b = effective[bg],
                          let ratio = contrastRatio(f, b), ratio < threshold else { continue }
                    contrastFailures.append(
                        "\(variant.rawValue) \(fg)/\(bg) \(String(format: "%.2f", ratio)) < \(threshold)")
                }
            }
            if !contrastFailures.isEmpty {
                result = [
                    "ok": false,
                    "error": "contrast_failed",
                    "contrastFailures": contrastFailures,
                    "message": "Contrast check failed before applying; nothing was changed: \(contrastFailures.joined(separator: "; ")). Adjust the colours and retry.",
                ]
                sem.signal()
                return
            }
            // [AI merge leftovers] Capture BEFORE applying what this
            // partial apply will leave untouched, so the result can say
            // so honestly instead of implying a full switch.
            var untouchedImages: [String] = []
            if obj["wallpaperJPEGBase64"] == nil,
               AppearanceStudio.shared.wallpaper(for: .global) != nil { untouchedImages.append("wallpaper") }
            if obj["thinkingCardJPEGBase64"] == nil,
               AppearanceStudio.shared.thinkingCardImage() != nil { untouchedImages.append("thinkingCard") }
            if obj["inputBarJPEGBase64"] == nil,
               AppearanceStudio.shared.inputBarImage() != nil { untouchedImages.append("inputBar") }
            var untouchedColourRoles: [String] = []
            for role in AppearanceColorRole.allCases {
                for variant in [AppearanceVariant.light, AppearanceVariant.dark] {
                    guard AppearanceStudio.shared.hasOverride(role, scope: .global, variant: variant) else { continue }
                    let changed = variant == .light ? changedLight : changedDark
                    if !changed.contains(role.rawValue) {
                        untouchedColourRoles.append("\(role.rawValue) (\(variant.rawValue))")
                    }
                }
            }
            // [B28 R3-5 / F-2] 吃不下的字段不再被吞 —— warnings 明说哪些
            // 图没落住，AI 侧能自查重试，不会拿着 ok 当全好。
            // Partial-only: an AI `apply --file` call carries only the
            // fields it names, so it must NOT reset anything it left
            // out. Merge mode is kept for this path alone; a full theme
            // switch (library apply, clipboard import) uses replace.
            let warnings = AppearanceStudio.shared.applyThemePack(pack, mode: .merge)
            var out = AppearanceStudio.shared.currentThemePack().asJSONObject()
            out["ok"] = true
            out["applied"] = true
            if !warnings.isEmpty { out["warnings"] = warnings }
            out.removeValue(forKey: "wallpaperJPEGBase64")
            out.removeValue(forKey: "characterArtBase64")
            out["hasCharacterArt"] = AppearanceStudio.shared.hasCharacterArt
            if !untouchedImages.isEmpty { out["untouchedImages"] = untouchedImages }
            if !untouchedColourRoles.isEmpty { out["untouchedColourRoles"] = untouchedColourRoles }
            if !untouchedImages.isEmpty || !untouchedColourRoles.isEmpty {
                out["leftoverNote"] = "Partial apply: the images and custom colours listed in untouchedImages/untouchedColourRoles were left unchanged, not cleared."
            }
            // AI-facing result, like get/export, carries only editable
            // fields so it can be re-fed to apply without a locked_field
            // rejection. Untouched/leftover keys are not locked pack
            // fields, so they survive stripping.
            let (cleanedOut, strippedOut) = aiEditable(out)
            out = cleanedOut
            out["aiEditableOnly"] = true
            out["strippedLockedFields"] = strippedOut
            result = out
            sem.signal()
        }
        if sem.wait(timeout: .now() + 5) == .timedOut {
            // 超时不能当成功返回：ObjC 侧把缺 ok 视为 true，会变成
            // 「命令成功但什么都没做」。这里明确给 ok:false。
            NSLog("[CLIBridge] semaphore wait timed out")
            return ["ok": false, "error": "timeout",
                    "message": "The app did not answer within the timeout."] as NSDictionary
        }
        return result as NSDictionary
    }

    @objc public static func exportJSON(includeWallpaper: Bool) -> NSDictionary {
        let sem = DispatchSemaphore(value: 0)
        var result: [String: Any] = [:]
        Task { @MainActor in
            let pack = AppearanceStudio.shared.exportThemePack(includeWallpaper: includeWallpaper)
            var out = pack.asJSONObject()
            // [B28 A-1] 默认不吐立绘；只有 `--wallpaper` 明确要整包时才带。
            if !includeWallpaper {
                out.removeValue(forKey: "characterArtBase64")
                out["hasCharacterArt"] = AppearanceStudio.shared.hasCharacterArt
            }
            let (cleaned, stripped) = aiEditable(out)
            out = cleaned
            out["aiEditableOnly"] = true
            out["strippedLockedFields"] = stripped
            out["ok"] = true
            result = out
            sem.signal()
        }
        if sem.wait(timeout: .now() + 5) == .timedOut {
            // 超时不能当成功返回：ObjC 侧把缺 ok 视为 true，会变成
            // 「命令成功但什么都没做」。这里明确给 ok:false。
            NSLog("[CLIBridge] semaphore wait timed out")
            return ["ok": false, "error": "timeout",
                    "message": "The app did not answer within the timeout."] as NSDictionary
        }
        return result as NSDictionary
    }

    @objc public static func resetPack() -> NSDictionary {
        let sem = DispatchSemaphore(value: 0)
        var result: [String: Any] = [:]
        Task { @MainActor in
            AppearanceStudio.shared.resetThemePack()
            result = [
                "ok": true,
                "reset": true,
                "id": AppearanceThemePack.default.id,
                "name": AppearanceThemePack.default.name,
                "undoAvailable": AppearanceStudio.shared.canUndoThemeReset,
            ]
            sem.signal()
        }
        if sem.wait(timeout: .now() + 5) == .timedOut {
            // 超时不能当成功返回：ObjC 侧把缺 ok 视为 true，会变成
            // 「命令成功但什么都没做」。这里明确给 ok:false。
            NSLog("[CLIBridge] semaphore wait timed out")
            return ["ok": false, "error": "timeout",
                    "message": "The app did not answer within the timeout."] as NSDictionary
        }
        return result as NSDictionary
    }

    @objc public static func undoReset() -> NSDictionary {
        let sem = DispatchSemaphore(value: 0)
        var result: [String: Any] = [:]
        Task { @MainActor in
            let ok = AppearanceStudio.shared.undoThemeReset()
            result = ok
                ? ["ok": true, "restored": true]
                : ["ok": false, "error": "no_snapshot",
                   "message": "No theme reset to undo. The snapshot only covers the last reset."]
            sem.signal()
        }
        if sem.wait(timeout: .now() + 5) == .timedOut {
            // 超时不能当成功返回：ObjC 侧把缺 ok 视为 true，会变成
            // 「命令成功但什么都没做」。这里明确给 ok:false。
            NSLog("[CLIBridge] semaphore wait timed out")
            return ["ok": false, "error": "timeout",
                    "message": "The app did not answer within the timeout."] as NSDictionary
        }
        return result as NSDictionary
    }

    @objc public static func saveCurrent(name: String) -> NSDictionary {
        let sem = DispatchSemaphore(value: 0)
        var result: [String: Any] = [:]
        Task { @MainActor in
            // [B28 R2-3] 满 40 套时 saveCurrentTheme 现在返回 nil —— 如实
            // 报「库满，先删一套」，不再悄悄顶掉最旧的来腾地方。
            if let item = AppearanceStudio.shared.saveCurrentTheme(name: name) {
                result = [
                    "ok": true,
                    "saved": true,
                    "id": item.id,
                    "name": item.name,
                ]
            } else {
                result = [
                    "ok": false,
                    "error": "library full",
                    "message": "The theme library holds 40 themes. Delete one before saving another.",
                ]
            }
            sem.signal()
        }
        if sem.wait(timeout: .now() + 5) == .timedOut {
            // 超时不能当成功返回：ObjC 侧把缺 ok 视为 true，会变成
            // 「命令成功但什么都没做」。这里明确给 ok:false。
            NSLog("[CLIBridge] semaphore wait timed out")
            return ["ok": false, "error": "timeout",
                    "message": "The app did not answer within the timeout."] as NSDictionary
        }
        return result as NSDictionary
    }

    @objc public static func listSaved() -> NSDictionary {
        let sem = DispatchSemaphore(value: 0)
        var result: [String: Any] = [:]
        Task { @MainActor in
            let items = AppearanceStudio.shared.savedThemes().map { item -> [String: Any] in
                [
                    "id": item.id,
                    "name": item.name,
                    "savedAt": ISO8601DateFormatter().string(from: item.savedAt),
                ]
            }
            result = [
                "ok": true,
                "count": items.count,
                "themes": items,
            ]
            sem.signal()
        }
        if sem.wait(timeout: .now() + 5) == .timedOut {
            // 超时不能当成功返回：ObjC 侧把缺 ok 视为 true，会变成
            // 「命令成功但什么都没做」。这里明确给 ok:false。
            NSLog("[CLIBridge] semaphore wait timed out")
            return ["ok": false, "error": "timeout",
                    "message": "The app did not answer within the timeout."] as NSDictionary
        }
        return result as NSDictionary
    }

    /// AI-path `minis-theme use`. This bridge entry is AI-only: the
    /// settings UI calls `AppearanceStudio.applySavedTheme` directly and
    /// is untouched by this change. A saved pack always carries locked
    /// layout fields, so a full replace here would smuggle layout back
    /// through the AI path. Instead this applies ONLY colours, images,
    /// thinking-card font sizes, and non-rectangle avatar shape from the
    /// saved pack (see `applySavedThemeAI`), leaves layout exactly as
    /// the user left it, and says so in the result. It does not mark the
    /// saved theme as in use, because the result is not that theme.
    @objc public static func applySaved(id: String) -> NSDictionary {
        let sem = DispatchSemaphore(value: 0)
        var result: [String: Any] = [:]
        Task { @MainActor in
            if let applied = AppearanceStudio.shared.applySavedThemeAI(id: id) {
                var out: [String: Any] = [
                    "ok": true, "applied": true, "partial": true, "id": id,
                    "strippedLockedFields": applied.strippedLockedFields,
                    "message": "Partial AI apply: colours, wallpaper/surface images, thinking-card font sizes, and avatar shape from the saved theme were applied. Locked layout fields were stripped and layout is unchanged: \(applied.strippedLockedFields.joined(separator: ", ")). Images and colours the saved pack does not carry were left unchanged. For a full theme switch including layout, use the theme library in the settings UI. This result does not mark the saved theme as in use.",
                ]
                if !applied.warnings.isEmpty { out["warnings"] = applied.warnings }
                result = out
            } else {
                result = ["ok": false, "error": "not_found", "message": "No saved theme \(id)"]
            }
            sem.signal()
        }
        if sem.wait(timeout: .now() + 5) == .timedOut {
            // 超时不能当成功返回：ObjC 侧把缺 ok 视为 true，会变成
            // 「命令成功但什么都没做」。这里明确给 ok:false。
            NSLog("[CLIBridge] semaphore wait timed out")
            return ["ok": false, "error": "timeout",
                    "message": "The app did not answer within the timeout."] as NSDictionary
        }
        return result as NSDictionary
    }

    @objc public static func deleteSaved(id: String) -> NSDictionary {
        let sem = DispatchSemaphore(value: 0)
        var result: [String: Any] = [:]
        Task { @MainActor in
            let ok = AppearanceStudio.shared.deleteSavedTheme(id: id)
            result = ok
                ? ["ok": true, "deleted": true, "id": id]
                : ["ok": false, "error": "not_found", "message": "No saved theme \(id)"]
            sem.signal()
        }
        if sem.wait(timeout: .now() + 5) == .timedOut {
            // 超时不能当成功返回：ObjC 侧把缺 ok 视为 true，会变成
            // 「命令成功但什么都没做」。这里明确给 ok:false。
            NSLog("[CLIBridge] semaphore wait timed out")
            return ["ok": false, "error": "timeout",
                    "message": "The app did not answer within the timeout."] as NSDictionary
        }
        return result as NSDictionary
    }

    @objc public static func renameSaved(id: String, name: String) -> NSDictionary {
        let sem = DispatchSemaphore(value: 0)
        var result: [String: Any] = [:]
        Task { @MainActor in
            let ok = AppearanceStudio.shared.renameSavedTheme(id: id, name: name)
            result = ok
                ? ["ok": true, "renamed": true, "id": id, "name": name]
                : ["ok": false, "error": "not_found", "message": "Rename failed"]
            sem.signal()
        }
        if sem.wait(timeout: .now() + 5) == .timedOut {
            // 超时不能当成功返回：ObjC 侧把缺 ok 视为 true，会变成
            // 「命令成功但什么都没做」。这里明确给 ok:false。
            NSLog("[CLIBridge] semaphore wait timed out")
            return ["ok": false, "error": "timeout",
                    "message": "The app did not answer within the timeout."] as NSDictionary
        }
        return result as NSDictionary
    }
}
