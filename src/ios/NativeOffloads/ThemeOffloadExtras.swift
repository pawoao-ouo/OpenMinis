//
//  ThemeOffloadExtras.swift
//  MinisApp
//
//  `minis-theme` coverage for the parts of the appearance system the pack
//  JSON never carried: avatars, replaceable row icons, per-page wallpapers,
//  and single colour overrides.
//
//  The pack is a fixed 26-field document. Everything below lives outside it,
//  so before this file an AI could restyle bubbles, radii and the 16 category
//  tiles and nothing else — asking it to change a settings-row icon or the
//  chat page's wallpaper was impossible, not merely undocumented.
//
//  Every setter takes an image path or hex value, never raw bytes on the
//  command line: `--file` points at a guest path the shell already has.
//

import Foundation
import SwiftUI
import UIKit

@objc public class ThemeOffloadExtras: NSObject {

    // MARK: - Shared plumbing

    /// Runs `work` on the main actor and waits.
    ///
    /// [H-02 / H-06] The wait, the timeout and the cancellation token live
    /// in `ThemeBridgeCall` so every command shares one contract: once the
    /// CLI has timed out, a late main-actor task can no longer write.
    /// Reads keep the 5s ceiling; the callers that wait for a confirmation
    /// sheet pass a window wider than the gate's own timeout.
    private static func onMain(_ work: @escaping @MainActor (ThemeBridgeCallToken) -> [String: Any]) -> NSDictionary {
        ThemeBridgeCall.run { token in work(token) }
    }

    private static func onMainAwaited(_ work: @escaping @MainActor (ThemeBridgeCallToken) async -> [String: Any]) -> NSDictionary {
        ThemeBridgeCall.run(timeout: ThemeWriteConfirmation.waitWindow) { token in await work(token) }
    }

    private static func fail(_ code: String, _ message: String) -> [String: Any] {
        ["ok": false, "error": code, "message": message]
    }

    /// [T-52] The icon lock lives here as data so the ObjC command surface
    /// and any future Swift caller read ONE answer instead of two copies.
    /// Icons stay user-only; `minis-theme icon --list` is the AI's only
    /// permitted icon subcommand.
    @objc public static func aiAllowsIconSet() -> Bool { false }

    /// Reads an image from a path the caller already resolved.
    ///
    /// The ObjC handler maps guest paths with `noff_resolve_host_path` before
    /// calling in — the same function `minis-theme apply --file` uses — so
    /// one resolver serves both entry points.
    private static func loadImage(_ hostPath: String) -> UIImage? {
        guard !hostPath.isEmpty else { return nil }
        return UIImage(contentsOfFile: hostPath)
    }

    // MARK: - Avatars

    @objc public static func setAvatar(_ role: String, hostPath: String) -> NSDictionary {
        guard let image = loadImage(hostPath) else {
            return fail("no_image", "Cannot read an image at \(hostPath).") as NSDictionary
        }
        return onMainAwaited { token in
            // [T-02] 换头像会覆盖现有的那一张，之前一句话就能改掉。
            let decision = await ThemeWriteConfirmation.check(
                "avatar",
                what: role == "user" ? "把 AI 给的头像设成你的头像" : "更换 AI 自己的头像",
                detail: "会覆盖当前头像，旧图不留",
                verb: "set")
            if let refusal = decision.refusal { return refusal }
            guard token.beginWrite() else {
                return fail("timeout", "The call timed out before writing; no avatar was changed.")
            }
            switch role {
            case "user":
                // [B28 R16] 以前只写 studio.userAvatar，而界面读的是 Persona.avatar，
                // 所以命令回 ok、界面不动 —— 看着像空实现。现在写同一个源。
                return storeAvatar(image, personaID: PersonaStore.userProfilePersonaID,
                                   role: "user", fallback: PersonaStore.makeUserProfilePersona())
            case "assistant":
                let pid = PersonaStore.currentID()
                guard let existing = PersonaStore.shared.personas.first(where: { $0.id == pid })
                else { return fail("no_persona", "No persona \(pid).") }
                // 两边都写：SOUL.md 的 icon 是给旧读取路径的镜像，
                // Persona.avatar 是界面/聊天真正读的那一份。
                do {
                    try AppearanceStudio.shared.setAssistantAvatar(image)
                } catch {
                    return fail("save_failed", error.localizedDescription)
                }
                return storeAvatar(image, personaID: pid, role: "assistant", fallback: existing)
            default:
                return fail("bad_role", "role must be user or assistant.")
            }
        }
    }

    @objc public static func removeAvatar(_ role: String) -> NSDictionary {
        onMainAwaited { token in
            // [T-02] 清头像同样会丢东西，先问。
            let decision = await ThemeWriteConfirmation.check(
                "avatar",
                what: role == "user" ? "清掉你的头像" : "清掉 AI 的头像",
                detail: "头像会被移除，回到默认图形",
                verb: "remove")
            if let refusal = decision.refusal { return refusal }
            guard token.beginWrite() else {
                return fail("timeout", "The call timed out before writing; no avatar was changed.")
            }
            switch role {
            case "user":
                clearAvatar(personaID: PersonaStore.userProfilePersonaID)
                AppearanceStudio.shared.removeUserAvatar()
                return ["ok": true, "avatar": "user", "removed": true]
            case "assistant":
                let pid = PersonaStore.currentID()
                clearAvatar(personaID: pid)
                try? AppearanceStudio.shared.removeAssistantAvatar()
                return ["ok": true, "avatar": "assistant", "removed": true]
            default:
                return fail("bad_role", "role must be user or assistant.")
            }
        }
    }

    /// 把图落盘，再把路径写进 Persona.avatar —— 界面、聊天、通讯录读的都是它。
    @MainActor
    private static func storeAvatar(_ image: UIImage, personaID: String,
                                    role: String, fallback: Persona) -> [String: Any] {
        let name = SoulIconImage.storedName(prefix: "persona", id: personaID)
        guard case .success(let path) = SoulIconImage.store(image, named: name) else {
            return fail("save_failed", "Could not store the image.")
        }
        var target = PersonaStore.shared.personas.first(where: { $0.id == personaID }) ?? fallback
        target.avatar = path
        PersonaStore.shared.updatePersona(target)
        return ["ok": true, "avatar": role, "path": path]
    }

    @MainActor
    private static func clearAvatar(personaID: String) {
        guard var target = PersonaStore.shared.personas.first(where: { $0.id == personaID })
        else { return }
        target.avatar = nil
        PersonaStore.shared.updatePersona(target)
    }

    // MARK: - Replaceable row icons

    @objc public static func setIcon(_ slot: String, hostPath: String) -> NSDictionary {
        guard let image = loadImage(hostPath) else {
            return fail("no_image", "Cannot read an image at \(hostPath).") as NSDictionary
        }
        return onMain { _ in
            // [B28 R2-7] 编码或写盘失败以前也报 ok:true。
            guard AppearanceStudio.shared.setIcon(image, for: slot) else {
                return fail("icon_write_failed", "Could not store the icon for slot \u{22}" + slot + "\u{22}.")
            }
            return ["ok": true, "slot": slot]
        }
    }

    @objc public static func removeIcon(_ slot: String) -> NSDictionary {
        onMain { _ in
            // [B28 R2-7 / A-3] 删一个根本没有图标的 slot 以前也回
            // "removed": true —— AI 据此以为清理完成了。现在如实区分。
            let existed = AppearanceStudio.shared.removeIcon(for: slot)
            if existed { return ["ok": true, "slot": slot, "removed": true] }
            return fail("no_icon_for_slot", "Nothing was set for slot \u{22}" + slot + "\u{22}; nothing removed.")
        }
    }

    @objc public static func listIconSlots() -> NSDictionary {
        onMain { _ in
            let slots = QuietIconSlot.allCases.map { slot -> [String: Any] in
                [
                    "slot": slot.rawValue,
                    "title": slot.title,
                    "custom": AppearanceStudio.shared.customIcon(for: slot.rawValue) != nil,
                ]
            }
            return ["ok": true, "count": slots.count, "slots": slots]
        }
    }

    // MARK: - Per-page wallpapers

    @objc public static func setWallpaper(_ scope: String, hostPath: String) -> NSDictionary {
        guard let image = loadImage(hostPath) else {
            return fail("no_image", "Cannot read an image at \(hostPath).") as NSDictionary
        }
        guard let parsed = AppearanceScope(rawValue: scope) else {
            return fail("bad_scope", "scope must be one of: \(AppearanceScope.allCases.map(\.rawValue).joined(separator: ", ")).") as NSDictionary
        }
        return onMainAwaited { token in
            // [T-02] 换壁纸会盖掉用户原来的图；页级还会盖掉她单独给这一页
            // 挑的图（T-25 的页级覆盖），所以一并说清楚。
            let isPage = parsed != .global
            let decision = await ThemeWriteConfirmation.check(
                "wallpaper",
                what: isPage ? "换「\(parsed.rawValue)」页的壁纸" : "换全局壁纸",
                detail: isPage ? "会覆盖这一页单独设的图，其他页不动" : "会覆盖当前全局壁纸",
                verb: "set")
            if let refusal = decision.refusal { return refusal }
            guard token.beginWrite() else {
                return fail("timeout", "The call timed out before writing; no wallpaper was changed.")
            }
            // [T-29] 写不进去就如实失败，不再回一个 ok 让 AI 以为换上了。
            guard AppearanceStudio.shared.setWallpaper(image, for: parsed) else {
                return fail("wallpaper_write_failed",
                            "Could not store the wallpaper for scope \(parsed.rawValue); nothing was changed.")
            }
            return ["ok": true, "scope": parsed.rawValue]
        }
    }

    @objc public static func removeWallpaper(_ scope: String) -> NSDictionary {
        guard let parsed = AppearanceScope(rawValue: scope) else {
            return fail("bad_scope", "scope must be one of: \(AppearanceScope.allCases.map(\.rawValue).joined(separator: ", ")).") as NSDictionary
        }
        return onMainAwaited { token in
            // [T-02] 清壁纸会丢掉用户上传的图（进不了回收站），先问。
            let existed = AppearanceStudio.shared.hasOwnWallpaper(parsed)
            let decision = await ThemeWriteConfirmation.check(
                "wallpaper",
                what: "清掉「\(parsed.rawValue)」页的壁纸",
                detail: existed ? "这张图会被移除，不能撤回" : "这一页本来没有自己的图",
                verb: "remove")
            if let refusal = decision.refusal { return refusal }
            guard token.beginWrite() else {
                return fail("timeout", "The call timed out before writing; no wallpaper was changed.")
            }
            AppearanceStudio.shared.removeWallpaper(parsed)
            return ["ok": true, "scope": parsed.rawValue, "removed": true]
        }
    }

    // MARK: - Single colour override

    @objc public static func setColor(_ role: String, hex: String,
                                      scope: String, variant: String) -> NSDictionary {
        guard let parsedRole = AppearanceColorRole(rawValue: role) else {
            return fail("bad_role",
                        "role must be one of: \(AppearanceColorRole.allCases.map(\.rawValue).joined(separator: ", ")).") as NSDictionary
        }
        guard let parsedScope = AppearanceScope(rawValue: scope) else {
            return fail("bad_scope",
                        "scope must be one of: \(AppearanceScope.allCases.map(\.rawValue).joined(separator: ", ")).") as NSDictionary
        }
        guard let parsedVariant = AppearanceVariant(rawValue: variant) else {
            return fail("bad_variant", "variant must be light or dark.") as NSDictionary
        }
        // Reject junk before it reaches the store: an unparseable hex used to
        // land as pure black with no complaint.
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted).uppercased()
        guard (cleaned.count == 6 || cleaned.count == 8),
              cleaned.allSatisfy({ $0.isHexDigit }) else {
            return fail("bad_hex", "hex must be 6 or 8 hex digits, e.g. D4778B.") as NSDictionary
        }
        return onMainAwaited { token in
            // [T-22] 底部栏/终端只挂壁纸，不吃颜色。以前这里一路绿灯回
            // ok:true，界面纹丝不动，AI 转头就说「改好了」。现在明说。
            guard parsedScope.supportsColour else {
                return fail("scope_no_colour",
                            "scope \u{22}\(parsedScope.rawValue)\u{22} is wallpaper-only and carries no colours. Nothing was changed. Use a colour scope: \(AppearanceScope.allCases.filter(\.supportsColour).map(\.rawValue).joined(separator: ", ")).")
            }
            // [F1] Same contrast gate as AI apply, BEFORE setColor, on
            // this AI command path only: the settings UI calls
            // AppearanceStudio.setColor directly and is never gated here.
            // The proposed value is judged against the effective
            // canvas/surface for THIS scope+variant (scope override,
            // then global override, then built-in palette), with the
            // same thresholds (primaryText 4.5, accent 3.0). A failing
            // change returns contrast_failed and changes nothing.
            // --clear is not gated: clearing restores the default, which
            // is the way OUT of a bad override, not into one.
            let failures = AppearanceStudio.shared.contrastFailures(
                scope: parsedScope, variant: parsedVariant,
                proposed: [parsedRole: cleaned])
            if !failures.isEmpty {
                return [
                    "ok": false, "error": "contrast_failed",
                    "contrastFailures": failures,
                    "role": parsedRole.rawValue, "hex": cleaned,
                    "scope": parsedScope.rawValue, "variant": parsedVariant.rawValue,
                    "message": "Contrast check failed before changing the colour; nothing was changed: \(failures.joined(separator: "; ")). Adjust the colour and retry.",
                ]
            }
            // [T-25] 页级覆盖是用户在这一页亲手调过的值，锁表只保护了
            // apply，color --scope chat 以前能直接盖掉。页级写现在先过确认
            // 单，并把原来的值一起报回去。
            var previousValue: String?
            if parsedScope != .global {
                previousValue = AppearanceStudio.shared.hex(parsedRole, scope: parsedScope, variant: parsedVariant)
                let decision = await ThemeWriteConfirmation.check(
                    "color",
                    what: "改「\(parsedScope.rawValue)」页的「\(parsedRole.title)」",
                    detail: previousValue.map { "这一页单独的值，原来是 \($0)" } ?? "这一页原来没有单独设过",
                    verb: "set")
                if let refusal = decision.refusal { return refusal }
            }
            guard token.beginWrite() else {
                return fail("timeout", "The call timed out before writing; no colour was changed.")
            }
            guard AppearanceStudio.shared.setColor(Color(hex: cleaned), role: parsedRole,
                                                   scope: parsedScope, variant: parsedVariant) else {
                return fail("scope_no_colour", "scope \u{22}\(parsedScope.rawValue)\u{22} does not carry colours; nothing was changed.")
            }
            var out: [String: Any] = [
                "ok": true, "role": parsedRole.rawValue, "hex": cleaned,
                "scope": parsedScope.rawValue, "variant": parsedVariant.rawValue,
            ]
            if let previousValue {
                out["previousValue"] = previousValue
                out["pageScopeNote"] = "This wrote a page-level override for \(parsedScope.rawValue); the other pages are unchanged."
            }
            return out
        }
    }

    @objc public static func clearColor(_ role: String,
                                        scope: String, variant: String) -> NSDictionary {
        guard let parsedRole = AppearanceColorRole(rawValue: role),
              let parsedScope = AppearanceScope(rawValue: scope),
              let parsedVariant = AppearanceVariant(rawValue: variant) else {
            return fail("bad_args", "Unknown role, scope or variant.") as NSDictionary
        }
        return onMain { token in
            // [T-22] 清色同样只对能吃颜色的作用域有意义；否则「清成功」也
            // 是空话。
            guard parsedScope.supportsColour else {
                return fail("scope_no_colour",
                            "scope \u{22}\(parsedScope.rawValue)\u{22} is wallpaper-only and carries no colours; there is nothing to clear.")
            }
            guard token.beginWrite() else {
                return fail("timeout", "The call timed out before writing; no colour was changed.")
            }
            AppearanceStudio.shared.clearOverride(parsedRole, scope: parsedScope, variant: parsedVariant)
            return ["ok": true, "role": parsedRole.rawValue,
                    "scope": parsedScope.rawValue, "variant": parsedVariant.rawValue,
                    "cleared": true]
        }
    }

    /// [T-theme-color-read] 把每个语义角色现在的取值列出来。
    ///
    /// 在这之前 `minis-theme color` 只能写不能读：AI 想「把主文字调深一档」时
    /// 无从知道它现在是哪个值，只能先 `get` 整包再从 JSON 里翻，或者干脆猜一个
    /// 覆盖掉。`get` 回的是**主题包**（字段以返回体为准），和角色表不是
    /// 一回事，所以那条路也不通。
    ///
    /// 每个角色给三样东西：浅色值、深色值、以及有没有被用户手动覆盖过。
    /// 有覆盖才有资格 `--clear`，没覆盖说明它是内置默认值。
    /// 参数不带标签：ObjC 侧的选择器就是 `listColors:`，和同文件其它
    /// 命令（`setColor:hex:scope:variant:`）的写法一致。带标签会生成
    /// `listColorsWithScope:`，C 那边调不到。
    @objc public static func listColors(_ scope: String) -> NSDictionary {
        guard let parsedScope = AppearanceScope(rawValue: scope) else {
            return fail("bad_scope",
                        "scope must be one of: \(AppearanceScope.allCases.map(\.rawValue).joined(separator: ", ")).") as NSDictionary
        }
        return onMain { _ in
            let studio = AppearanceStudio.shared
            let roles = AppearanceColorRole.allCases.map { role -> [String: Any] in
                [
                    "role": role.rawValue,
                    "title": role.title,
                    "hint": role.hint,
                    "light": studio.hex(role, scope: parsedScope, variant: .light),
                    "dark": studio.hex(role, scope: parsedScope, variant: .dark),
                    "customLight": studio.hasOverride(role, scope: parsedScope, variant: .light),
                    "customDark": studio.hasOverride(role, scope: parsedScope, variant: .dark),
                ]
            }
            return ["ok": true, "scope": parsedScope.rawValue,
                    "count": roles.count, "roles": roles]
        }
    }
}
