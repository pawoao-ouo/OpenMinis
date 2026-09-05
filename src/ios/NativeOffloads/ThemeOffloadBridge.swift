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

    @objc public static func currentPack() -> NSDictionary {
        let sem = DispatchSemaphore(value: 0)
        var result: [String: Any] = [:]
        Task { @MainActor in
            let pack = AppearanceStudio.shared.exportThemePack(includeWallpaper: false)
            var out = pack.asJSONObject()
            out["ok"] = true
            result = out
            sem.signal()
        }
        sem.wait()
        return result as NSDictionary
    }

    @objc public static func applyJSON(_ json: String) -> NSDictionary {
        let sem = DispatchSemaphore(value: 0)
        var result: [String: Any] = [:]
        Task { @MainActor in
            guard let data = json.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pack = try? AppearanceThemePack.decode(obj) else {
                result = [
                    "ok": false,
                    "error": "invalid_pack",
                    "message": "JSON is not a theme pack.",
                ]
                sem.signal()
                return
            }
            AppearanceStudio.shared.applyThemePack(pack)
            var out = AppearanceStudio.shared.currentThemePack().asJSONObject()
            out["ok"] = true
            out["applied"] = true
            out.removeValue(forKey: "wallpaperJPEGBase64")
            result = out
            sem.signal()
        }
        sem.wait()
        return result as NSDictionary
    }

    @objc public static func exportJSON(includeWallpaper: Bool) -> NSDictionary {
        let sem = DispatchSemaphore(value: 0)
        var result: [String: Any] = [:]
        Task { @MainActor in
            let pack = AppearanceStudio.shared.exportThemePack(includeWallpaper: includeWallpaper)
            var out = pack.asJSONObject()
            out["ok"] = true
            result = out
            sem.signal()
        }
        sem.wait()
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
            ]
            sem.signal()
        }
        sem.wait()
        return result as NSDictionary
    }
}
