//
//  ThemeOffloadBridge.swift
//  MinisApp
//
//  Swift bridge for `minis-theme`. ObjC handler parses argv / files;
//  this type applies packs on the main actor.
//
//  [H-02 / H-06] Every entry point goes through `ThemeBridgeCall.run`,
//  which owns the semaphore, the timeout and the cancellation token.
//  Reads keep the original 5s ceiling; a destructive command waits for the
//  confirmation sheet instead, and a timed-out call can no longer write
//  after the CLI has already reported failure.
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

    @objc public static func currentPack() -> NSDictionary {
        ThemeBridgeCall.run { _ in
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
            return out
        }
    }

    @objc public static func applyJSON(_ json: String) -> NSDictionary {
        ThemeBridgeCall.run { token in
            guard let data = json.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return [
                    "ok": false,
                    "error": "invalid_pack",
                    "message": "JSON is not a theme pack.",
                ]
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
                return [
                    "ok": false,
                    "error": "locked_field",
                    "lockedFields": locked,
                    "message": "AI theme apply is locked to colours, wallpaper/surface images, font sizes, and avatar shape (except rectangle). Locked field(s) rejected, nothing was applied: \(locked.joined(separator: ", ")). Remove those fields and retry.",
                ]
            }
            // Merge onto the live pack: an AI call that only names colors must
            // not reset radii, fonts, images, or anything else it left out.
            let live = AppearanceStudio.shared.currentThemePack()
            guard let pack = try? AppearanceThemePack.decode(obj, merging: live) else {
                return [
                    "ok": false,
                    "error": "invalid_pack",
                    "message": "JSON is not a theme pack.",
                ]
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
            // Shared gate (AppearanceStudio.contrastFailures): same
            // thresholds and pairs as the colour/use gates. Override ONLY
            // with keys the JSON actually named: pack.colorsLight/Dark
            // after decode already merged the live pack, so using the
            // whole map here would let stale pack colours override the
            // studio's live resolved values (e.g. colours set via
            // `minis-theme color`, which writes custom overrides, not
            // the pack).
            var contrastFailures: [String] = []
            for (variant, changed) in [(AppearanceVariant.light, changedLight),
                                       (AppearanceVariant.dark, changedDark)] {
                let packMap = variant == .light ? pack.colorsLight : pack.colorsDark
                var proposed: [AppearanceColorRole: String] = [:]
                for k in changed where packMap[k] != nil {
                    if let role = AppearanceColorRole(rawValue: k) { proposed[role] = packMap[k]! }
                }
                contrastFailures += AppearanceStudio.shared.contrastFailures(
                    scope: .global, variant: variant, proposed: proposed)
            }
            if !contrastFailures.isEmpty {
                return [
                    "ok": false,
                    "error": "contrast_failed",
                    "contrastFailures": contrastFailures,
                    "message": "Contrast check failed before applying; nothing was changed: \(contrastFailures.joined(separator: "; ")). Adjust the colours and retry.",
                ]
            }
            // [AI merge leftovers] Capture BEFORE applying what this
            // partial apply will leave untouched, so the result can say
            // so honestly instead of implying a full switch.
            // [F3] Leftovers for ALL scopes, via the shared helper:
            // global entries keep the bare format; non-global entries
            // are scope-labelled (`chat.primaryText (light)`,
            // `wallpaper:chat`). Per-scope wallpapers are untouched by
            // an AI merge apply (page fields are stripped before
            // apply, and merge never clears); user replace applies
            // do carry and write page wallpapers, so the old
            // "a pack never carries page wallpapers" claim no
            // longer holds for them. They are listed whenever an
            // own file exists, even when the pack carries a global
            // wallpaper.
            let leftovers = AppearanceStudio.shared.aiApplyLeftovers(
                changedLightRoles: changedLight, changedDarkRoles: changedDark,
                carriesWallpaper: obj["wallpaperJPEGBase64"] != nil
                    || obj["wallpaperDarkJPEGBase64"] != nil,
                carriesThinkingCard: obj["thinkingCardJPEGBase64"] != nil,
                carriesInputBar: obj["inputBarJPEGBase64"] != nil)
            let untouchedImages = leftovers.images
            let untouchedColourRoles = leftovers.colours
            // [B28 R3-5 / F-2] 吃不下的字段不再被吞 —— warnings 明说哪些
            // 图没落住，AI 侧能自查重试，不会拿着 ok 当全好。
            // Partial-only: an AI `apply --file` call carries only the
            // fields it names, so it must NOT reset anything it left
            // out. Merge mode is kept for this path alone; a full theme
            // switch (library apply, clipboard import) uses replace.
            guard token.beginWrite() else { return ["ok": false, "error": "timeout"] }
            let warnings = await AppearanceStudio.shared.applyThemePack(pack, mode: .merge)
            var out = AppearanceStudio.shared.currentThemePack().asJSONObject()
            out["ok"] = true
            out["applied"] = true
            if !warnings.isEmpty { out["warnings"] = warnings }
            out.removeValue(forKey: "wallpaperJPEGBase64")
            // [T-54 r2] 第二档也是图字节，一样不能出现在回给 AI 的包里。
            out.removeValue(forKey: "wallpaperDarkJPEGBase64")
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
            // [T-02] apply has no undo snapshot; say how to back out instead
            // of letting the AI imply it is free to re-run.
            out["revertNote"] = "No automatic undo for apply. Read the current values with `minis-theme get` before applying if you may need to revert; a single colour can be reverted with `color --role <r> --clear`."
            return out
        }
    }

    @objc public static func exportJSON(includeWallpaper: Bool) -> NSDictionary {
        ThemeBridgeCall.run { _ in
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
            return out
        }
    }/// [Safe-mode recovery] The chat reset path. The result must state
    /// plainly what was reset, because the user reads it in chat after a
    /// broken theme — a bare `reset: true` lets the AI invent the scope.
    /// `undoAvailable` means THIS reset captured a snapshot, not merely
    /// that some older snapshot file exists on disk: a reset with no
    /// pack JSON captures nothing, and promising undo for it would
    /// restore that older snapshot instead of this reset.
    ///
    /// [T-02] `--force` is a flag the AI writes itself, so it never was a
    /// user confirmation. The reset now stops at the confirm sheet first.
    @objc public static func resetPack() -> NSDictionary {
        ThemeBridgeCall.run(timeout: ThemeWriteConfirmation.waitWindow) { token in
            let decision = await ThemeWriteConfirmation.check(
                "reset",
                what: "重置整套主题",
                detail: "清掉所有页级配色、各页壁纸和上传的图（思考卡、输入栏、立绘、分类图）")
            if let refusal = decision.refusal { return refusal }
            guard token.beginWrite() else { return ["ok": false, "error": "timeout"] }
            let snapshotCaptured = AppearanceStudio.shared.resetThemePack()
            let name = AppearanceThemePack.default.name
            let resetScope = [
                "theme pack colours",
                "all page colour overrides",
                "all scope wallpapers",
                "uploaded theme images (thinking-card, input-bar, character art, category images)",
                "opacity/shade defaults (surface opacity 0.88, bubble opacity 1.0, wallpaper shade 0.08)",
            ]
            let message: String
            if snapshotCaptured {
                message = "Theme reset to the default \"\(name)\" pack: \(resetScope.joined(separator: "; ")). Chats, backups, and saved library themes were not touched. Undo is available: `minis-theme undo` restores the theme removed by this reset."
            } else {
                message = "Theme reset to the default \"\(name)\" pack: \(resetScope.joined(separator: "; ")). Chats, backups, and saved library themes were not touched. No undo snapshot was captured for this reset, so `minis-theme undo` cannot restore the theme this reset removed."
            }
            return [
                "ok": true,
                "reset": true,
                "id": AppearanceThemePack.default.id,
                "name": name,
                "resetScope": resetScope,
                "undoAvailable": snapshotCaptured,
                "message": message,
            ]
        }
    }

    @objc public static func undoReset() -> NSDictionary {
        ThemeBridgeCall.run { token in
            guard token.beginWrite() else { return ["ok": false, "error": "timeout"] }
            let ok = AppearanceStudio.shared.undoThemeReset()
            return ok
                ? ["ok": true, "restored": true]
                : ["ok": false, "error": "no_snapshot",
                   "message": "No theme reset to undo. The snapshot only covers the last reset."]
        }
    }

    @objc public static func saveCurrent(name: String) -> NSDictionary {
        ThemeBridgeCall.run { _ in
            // [B28 R2-3] 满 40 套时 saveCurrentTheme 现在返回 nil —— 如实
            // 报「库满，先删一套」，不再悄悄顶掉最旧的来腾地方。
            if let item = AppearanceStudio.shared.saveCurrentTheme(name: name) {
                return [
                    "ok": true,
                    "saved": true,
                    "id": item.id,
                    "name": item.name,
                ]
            }
            return [
                "ok": false,
                "error": "library full",
                "message": "The theme library holds 40 themes. Delete one before saving another.",
            ]
        }
    }

    @objc public static func listSaved() -> NSDictionary {
        ThemeBridgeCall.run { _ in
            let items = AppearanceStudio.shared.savedThemes().map { item -> [String: Any] in
                [
                    "id": item.id,
                    "name": item.name,
                    "savedAt": ISO8601DateFormatter().string(from: item.savedAt),
                ]
            }
            return [
                "ok": true,
                "count": items.count,
                "themes": items,
            ]
        }
    }

    /// AI-path `minis-theme use`. This bridge entry is AI-only: the
    /// settings UI goes through `AppearanceStudio.applySavedThemeSet`
    /// (not `applySavedTheme` directly), and is untouched by this change.
    /// A saved pack always carries locked layout fields, so a full replace
    /// here would smuggle layout back through the AI path. Instead this
    /// applies ONLY colours, images, thinking-card font sizes, and
    /// non-rectangle avatar shape from the saved pack (see
    /// `applySavedThemeAI`), leaves layout exactly as the user left it,
    /// and says so in the result. It does not mark the saved theme as in
    /// use, because the result is not that theme.
    @objc public static func applySaved(id: String) -> NSDictionary {
        ThemeBridgeCall.run { token in
            // [F2] Same contrast gate as apply, BEFORE anything is
            // applied: a saved pack that would fail contrast is refused
            // with nothing changed. nil = no such saved theme.
            if let failures = AppearanceStudio.shared.savedPackContrastFailures(id: id),
               !failures.isEmpty {
                return [
                    "ok": false, "error": "contrast_failed",
                    "contrastFailures": failures,
                    "message": "Contrast check failed before applying the saved theme; nothing was changed: \(failures.joined(separator: "; ")). Adjust the colours and retry.",
                ]
            }
            guard token.beginWrite() else { return ["ok": false, "error": "timeout"] }
            if let applied = await AppearanceStudio.shared.applySavedThemeAI(id: id) {
                var out: [String: Any] = [
                    "ok": true, "applied": true, "partial": true, "id": id,
                    "strippedLockedFields": applied.strippedLockedFields,
                    "message": "Partial AI apply: colours, wallpaper/surface images, thinking-card font sizes, and avatar shape from the saved theme were applied. Locked layout fields were stripped and layout is unchanged: \(applied.strippedLockedFields.joined(separator: ", ")). Images and colours the saved pack does not carry were left unchanged. For a full theme switch including layout, use the theme library in the settings UI. This result does not mark the saved theme as in use.",
                ]
                if !applied.warnings.isEmpty { out["warnings"] = applied.warnings }
                if !applied.untouchedImages.isEmpty { out["untouchedImages"] = applied.untouchedImages }
                if !applied.untouchedColourRoles.isEmpty { out["untouchedColourRoles"] = applied.untouchedColourRoles }
                if !applied.untouchedImages.isEmpty || !applied.untouchedColourRoles.isEmpty {
                    out["leftoverNote"] = "Partial apply: the images and custom colours listed in untouchedImages/untouchedColourRoles were left unchanged, not cleared."
                }
                return out
            }
            return ["ok": false, "error": "not_found", "message": "No saved theme \(id)"]
        }
    }

    /// [T-02] Deleting a saved theme used to be one AI keystroke away from a
    /// permanent loss: the trash keeps 5 packs, the 6th prunes the oldest.
    /// The delete now asks first, and the result states whether the pack is
    /// restorable instead of reporting a bare `deleted: true`.
    @objc public static func deleteSaved(id: String) -> NSDictionary {
        ThemeBridgeCall.run(timeout: ThemeWriteConfirmation.waitWindow) { token in
            guard let item = AppearanceStudio.shared.savedThemes().first(where: { $0.id == id }) else {
                return ["ok": false, "error": "not_found", "message": "No saved theme \(id)"]
            }
            let decision = await ThemeWriteConfirmation.check(
                "delete",
                what: "删除主题套「\(item.name)」",
                detail: "移进回收站（最多留 5 套，更早的会被永久清掉）")
            if let refusal = decision.refusal { return refusal }
            guard token.beginWrite() else { return ["ok": false, "error": "timeout"] }
            let outcome = AppearanceStudio.shared.deleteSavedThemeDetailed(id: id)
            // [H-03] A failed move used to be swallowed and the metadata was
            // dropped anyway, leaving a pack that could no longer be restored.
            if !outcome.deleted {
                return [
                    "ok": false,
                    "error": "trash_failed",
                    "message": "「\(item.name)」没删成：把它移进回收站失败，主题套原样保留。",
                    "restorable": true,
                ]
            }
            return [
                "ok": true,
                "deleted": true,
                "id": id,
                "name": item.name,
                "restorable": outcome.trashed,
                "message": outcome.trashed
                    ? "Deleted「\(item.name)」. It is in the trash and can be restored from the theme shop."
                    : "Deleted「\(item.name)」. No pack file was found, so there is nothing to restore from the trash.",
            ]
        }
    }

    /// [T-02] Renaming is reversible but it rewrites what the user sees in
    /// their own library, so it goes through the same confirmation. [H-03]
    /// The metadata write is verified against the pack write instead of
    /// reporting success unconditionally.
    @objc public static func renameSaved(id: String, name: String) -> NSDictionary {
        ThemeBridgeCall.run(timeout: ThemeWriteConfirmation.waitWindow) { token in
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return ["ok": false, "error": "invalid_name", "message": "Name cannot be empty."]
            }
            guard let item = AppearanceStudio.shared.savedThemes().first(where: { $0.id == id }) else {
                return ["ok": false, "error": "not_found", "message": "No saved theme \(id)"]
            }
            let decision = await ThemeWriteConfirmation.check(
                "rename",
                what: "把主题套「\(item.name)」改名成「\(trimmed)」",
                detail: "只改名字，配色和壁纸不动")
            if let refusal = decision.refusal { return refusal }
            guard token.beginWrite() else { return ["ok": false, "error": "timeout"] }
            guard AppearanceStudio.shared.renameSavedTheme(id: id, name: trimmed) else {
                return ["ok": false, "error": "rename_failed", "message": "Rename failed; the theme name was left unchanged."]
            }
            return ["ok": true, "renamed": true, "id": id, "name": trimmed]
        }
    }
}