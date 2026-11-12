import Foundation
import SwiftUI
import UIKit

/// Result of deleting one saved theme. [H-03]
///
/// `trashed` = the pack file really moved into the trash, so it can be
/// restored. `deleted` = the library list no longer carries it. A delete
/// never reports success while the pack is unrecoverable-but-unlisted.
struct ThemeDeletionOutcome {
    let deleted: Bool
    let trashed: Bool
}

/// Saved theme history. Current pack stays in AppearanceStudio;
/// this drawer only keeps names. Full packs live as JSON files so
/// wallpaper / category pictures never land in UserDefaults.
struct AppearanceSavedTheme: Equatable, Codable, Identifiable {
    var id: String
    var name: String
    var savedAt: Date
    var userStyle: String
    var assistantStyle: String
    /// Theme-set record (2026-11-02): the bubble-pack and pendant
    /// numbers each side was wearing when this set was saved.
    /// All four are optional with a nil default, so an old record
    /// (saved before this batch) decodes with all four nil — an
    /// old set simply has no numbers, never invented ones — and
    /// existing constructions without these arguments still compile.
    var userBubbleNumber: String? = nil
    var assistantBubbleNumber: String? = nil
    var userPendantNumber: String? = nil
    var assistantPendantNumber: String? = nil

    static let libraryKey = "appearanceStudio.themeLibrary.v1"
    static let limit = 40

    var userStyleTitle: String { AppearanceBubbleStyle.parse(userStyle).title }
    var assistantStyleTitle: String { AppearanceBubbleStyle.parse(assistantStyle).title }
}

extension AppearanceStudio {
    private static let libraryKey = AppearanceSavedTheme.libraryKey

    private struct LegacyLibraryMeta: Codable {
        var id: String
        var name: String
        var savedAt: Date
        var userStyle: String?
        var assistantStyle: String?
    }

    private func libraryDirectory() -> URL {
        let dir = appearanceDirectory.appendingPathComponent("library", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func libraryPackURL(_ id: String) -> URL {
        libraryDirectory().appendingPathComponent("\(id).json")
    }

    func savedThemes() -> [AppearanceSavedTheme] {
        guard let data = UserDefaults.standard.data(forKey: Self.libraryKey) else { return [] }
        if let list = try? JSONDecoder().decode([AppearanceSavedTheme].self, from: data) {
            return list.sorted { $0.savedAt > $1.savedAt }
        }
        return migrateLegacyLibrary(data)
    }

    /// v1 stuffed the whole pack (including JPEG) into UserDefaults.
    /// Pull pictures out into files and keep only names in the list.
    private func migrateLegacyLibrary(_ data: Data) -> [AppearanceSavedTheme] {
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        let decoder = JSONDecoder()
        var list: [AppearanceSavedTheme] = []
        for obj in raw {
            guard let itemData = try? JSONSerialization.data(withJSONObject: obj),
                  let meta = try? decoder.decode(LegacyLibraryMeta.self, from: itemData) else {
                continue
            }
            var userStyle = meta.userStyle ?? ""
            var assistantStyle = meta.assistantStyle ?? ""
            if let packObj = obj["pack"] as? [String: Any],
               let pack = try? AppearanceThemePack.decode(packObj) {
                writeLibraryPack(pack, id: meta.id)
                if userStyle.isEmpty { userStyle = pack.userStyle.rawValue }
                if assistantStyle.isEmpty { assistantStyle = pack.assistantStyle.rawValue }
            }
            list.append(AppearanceSavedTheme(
                id: meta.id,
                name: meta.name,
                savedAt: meta.savedAt,
                userStyle: userStyle,
                assistantStyle: assistantStyle
            ))
        }
        persistLibrary(list)
        return list.sorted { $0.savedAt > $1.savedAt }
    }

    /// [B28 R2-3] 满 40 套时以前**悄悄删掉你最旧的一套**再存 —— 用户没
    /// 点过任何删除，一套主题就这么消失了。现在满了直接拒绝并说原因：
    /// 「删一套再存」。宁可多一步操作，不替你扔东西。
    func saveCurrentTheme(name: String? = nil) -> AppearanceSavedTheme? {
        if savedThemes().count >= AppearanceSavedTheme.limit { return nil }
        var pack = exportThemePack(includeWallpaper: true)
        // [B28 R3-8/B-15] 空名字以前回落到 pack.name —— 那可能是上次导入的
        // ST 包名，存出来一套叫「XX主题 v2.1」，用户根本没起过这名字。
        let trimmed = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let label = trimmed.isEmpty ? "Untitled" : trimmed
        pack.name = label
        // Theme-set record: snapshot the numbers both sides are
        // actually wearing right now. A side wearing nothing
        // records nil for that piece — applying the set later
        // never guesses one for it (a nil bubble side follows
        // the saved pack's own style fields; a nil pendant side
        // is untouched).
        let item = AppearanceSavedTheme(
            id: UUID().uuidString.lowercased(),
            name: label,
            savedAt: Date(),
            userStyle: pack.userStyle.rawValue,
            assistantStyle: pack.assistantStyle.rawValue,
            userBubbleNumber: BubbleStylePackStore.shared.appliedNumber(for: .user),
            assistantBubbleNumber: BubbleStylePackStore.shared.appliedNumber(for: .assistant),
            userPendantNumber: AvatarPendantStore.shared.appliedNumber(for: .user),
            assistantPendantNumber: AvatarPendantStore.shared.appliedNumber(for: .assistant)
        )
        writeLibraryPack(pack, id: item.id)
        var list = savedThemes()
        list.insert(item, at: 0)
        persistLibrary(list)
        return item
    }

    /// AI-path saved-theme apply: NOT a full theme switch.
    ///
    /// The AI may change only colours, wallpaper/surface images, font
    /// sizes, and avatar shape. A saved pack always carries locked layout
    /// fields (radii, bubble shapes, lineHeight, …), so feeding it to
    /// `applySavedTheme` (replace) would re-apply layout through the AI
    /// path — exactly what the tool-layer lock forbids. This path therefore
    /// builds a partial pack from the live pack, overwrites ONLY the
    /// allowed fields from the saved pack, and applies it in merge mode.
    /// Layout, radii, shapes, spacing, and opacities stay exactly as the
    /// user left them. It deliberately does NOT set `lastAppliedKey`:
    /// the result is not the saved theme, and the UI must not claim it is.
    /// Returns nil when the id is unknown, else warnings plus the locked
    /// fields that were stripped, plus the all-scope leftovers (F3).
    /// [F2] Contrast failures the saved pack would produce, computed
    /// WITHOUT applying anything. nil = no such saved theme. A saved
    /// pack's colours are global roles, so the gate is the shared
    /// global-scope gate, over the roles the pack actually carries.
    func savedPackContrastFailures(id: String) -> [String]? {
        guard savedThemes().contains(where: { $0.id == id }),
              let saved = readLibraryPack(id: id) else { return nil }
        var failures: [String] = []
        for variant in AppearanceVariant.allCases {
            let map = variant == .light ? saved.colorsLight : saved.colorsDark
            var proposed: [AppearanceColorRole: String] = [:]
            for (raw, value) in map {
                if let role = AppearanceColorRole(rawValue: raw) { proposed[role] = value }
            }
            failures += contrastFailures(scope: .global, variant: variant, proposed: proposed)
        }
        return failures
    }

    func applySavedThemeAI(id: String) async -> (warnings: [String], strippedLockedFields: [String], untouchedImages: [String], untouchedColourRoles: [String])? {
        guard savedThemes().contains(where: { $0.id == id }),
              let saved = readLibraryPack(id: id) else { return nil }
        let stripped = AppearanceThemePack.aiApplyRejectedFields(in: saved.asJSONObject())
        // [F3] Capture leftovers BEFORE applying, against what the
        // saved pack actually carries (same shared helper as apply).
        let leftovers = aiApplyLeftovers(
            changedLightRoles: Set(saved.colorsLight.keys),
            changedDarkRoles: Set(saved.colorsDark.keys),
            carriesWallpaper: saved.wallpaperJPEGBase64 != nil
                || saved.wallpaperDarkJPEGBase64 != nil,
            carriesThinkingCard: saved.thinkingCardJPEGBase64 != nil,
            carriesInputBar: saved.inputBarJPEGBase64 != nil)
        var partial = currentThemePack()
        // Colours only (roles the pack carries; applyPackColors paints
        // exactly the roles present, so sparse packs stay partial).
        partial.colorsLight = saved.colorsLight
        partial.colorsDark = saved.colorsDark
        partial.thinkingFillHex = saved.thinkingFillHex
        partial.thinkingStrokeHex = saved.thinkingStrokeHex
        partial.thinkingAccentHex = saved.thinkingAccentHex
        partial.listRowFillHex = saved.listRowFillHex
        partial.rowBackgroundHex = saved.rowBackgroundHex
        partial.categoryColors = saved.categoryColors
        // Font sizes: thinking-card sizes only (see skill text — they do
        // not change message font size).
        partial.thinkingTitleSize = saved.thinkingTitleSize
        partial.thinkingBodySize = saved.thinkingBodySize
        // Avatar shape, except rectangle (which resizes the avatar).
        if saved.avatarShape != AppearanceAvatarShape.rectangle.rawValue {
            partial.avatarShape = saved.avatarShape
        }
        // Images only; a nil image means "leave the current file", which
        // the bridge result reports as an untouched leftover, not a clear.
        partial.wallpaperJPEGBase64 = saved.wallpaperJPEGBase64
        partial.wallpaperDarkJPEGBase64 = saved.wallpaperDarkJPEGBase64
        partial.thinkingCardJPEGBase64 = saved.thinkingCardJPEGBase64
        partial.inputBarJPEGBase64 = saved.inputBarJPEGBase64
        // [page-state] Page state is never an AI apply: the partial
        // starts from the live pack, whose page fields are the last
        // applied pack's record — not live page state — so carrying
        // them into a merge would revert page edits made since that
        // apply. Nil them outright; the saved pack's page keys, when
        // present, are already reported in `stripped` above via the
        // locked-fields list.
        partial.pageColorsLight = nil
        partial.pageColorsDark = nil
        partial.pageWallpapers = nil
        partial.pageDarkWallpapers = nil
        // Everything else stays live: radii, styles, lineHeight,
        // letterSpacing, opacities, shade, display modes, fontFamily,
        // category icons/images, character art.
        let warnings = await applyThemePack(partial, mode: .merge)
        return (warnings, stripped, leftovers.images, leftovers.colours)
    }

    /// [B28 R3-5] nil = 没应用成；返回数组 = 应用了但哪些图没落住（F-2）。
    /// Applying a saved theme is a full theme switch, not a merge:
    /// images and global colours the saved pack does not carry are
    /// cleared instead of leaving the previous theme's behind.
    /// This is the USER-initiated path (settings UI library); the AI
    /// path must use `applySavedThemeAI` above, never this one.
    @discardableResult
    func applySavedTheme(id: String) async -> [String]? {
        guard savedThemes().contains(where: { $0.id == id }),
              let pack = readLibraryPack(id: id) else { return nil }
        let warnings = await applyThemePack(pack, mode: .replace)
        // [B28 R2-10] 「现在用的是哪套」以前在模型里根本没有。记下这次
        // 应用的是谁，列表才能诚实回答：还是它 / 你后来改过。
        UserDefaults.standard.set(id, forKey: Self.lastAppliedKey)
        return warnings
    }

    /// Read-only accessor for the shop's theme-set preview, which
    /// must draw the saved pack's own colours and wallpaper, not
    /// the live theme's. It reads the same file applySavedTheme
    /// reads and changes nothing.
    func libraryPack(id: String) -> AppearanceThemePack? {
        readLibraryPack(id: id)
    }

    /// Shop full-set apply (2026-11-02 theme-set batch): the pack
    /// goes through the true-replace user path FIRST, then the
    /// recorded per-side bubble and pendant numbers, in that
    /// order. Nil = unknown id or unreadable pack (nothing
    /// applied). A recorded number whose pack/pendant is no
    /// longer in the catalogue is a failed piece, never a
    /// fallback to another pack: the caller must report it and
    /// must not claim the set applied cleanly. A nil recorded
    /// number is skipped, not failed — precisely: a nil bubble
    /// side gets no extra per-side pack apply, so its bubbles
    /// follow the saved pack's own style fields from the
    /// replace; a nil pendant side is truly untouched, because
    /// the pack replace never writes the pendant store.
    func applySavedThemeSet(id: String) async -> (packWarnings: [String], failedPieces: [String])? {
        guard let item = savedThemes().first(where: { $0.id == id }) else { return nil }
        guard let packWarnings = await applySavedTheme(id: id) else { return nil }
        var failed: [String] = []
        for (side, number) in [(DressingSide.user, item.userBubbleNumber),
                               (DressingSide.assistant, item.assistantBubbleNumber)] {
            guard let number else { continue }
            if let pack = BubbleStylePackStore.shared.pack(number: number) {
                BubbleStylePackStore.shared.apply(pack, for: side)
            } else {
                failed.append(side.isUser ? "userBubble" : "assistantBubble")
            }
        }
        for (side, number) in [(DressingSide.user, item.userPendantNumber),
                               (DressingSide.assistant, item.assistantPendantNumber)] {
            guard let number else { continue }
            if let pendant = AvatarPendantStore.shared.pendants.first(where: { $0.number == number }) {
                AvatarPendantStore.shared.apply(pendant, for: side)
            } else {
                failed.append(side.isUser ? "userPendant" : "assistantPendant")
            }
        }
        return (packWarnings, failed)
    }

    private static let lastAppliedKey = "appearanceStudio.lastAppliedLibraryID"

    /// 当前这套与某一库里的主题的关系。三态，全部由真实状态推导，
    /// 没有会过期的标记：
    ///   - notThisOne    当前不是从它应用的
    ///   - inUse         是从它应用的，且此后一个字段都没动过
    ///   - modifiedSince 是从它应用的，但你后来改过配色/滑杆/图
    ///
    /// 对比刻意不逐字节比图片：>2200px 的图 apply 时会缩放落盘，
    /// 字节必然和库里的原始包不同 —— 那是系统缩放，不是用户改过。
    /// 图片按「哪个槽位有图」参与对比，颜色/布局/透明度逐字段比。
    enum SavedThemeMatch { case notThisOne, inUse, modifiedSince }

    func savedThemeMatch(id: String) -> SavedThemeMatch {
        guard UserDefaults.standard.string(forKey: Self.lastAppliedKey) == id else { return .notThisOne }
        guard let saved = readLibraryPack(id: id) else { return .modifiedSince }
        return Self.packsMatchSemantically(exportThemePack(includeWallpaper: true), saved)
            ? .inUse : .modifiedSince
    }

    private static func packsMatchSemantically(_ a: AppearanceThemePack, _ b: AppearanceThemePack) -> Bool {
        func key(_ p: AppearanceThemePack) -> [String: Any] {
            var j = p.asJSONObject()
            for volatile in ["name", "id", "savedAt",
                             "wallpaperJPEGBase64", "wallpaperDarkJPEGBase64",
                             "thinkingCardJPEGBase64",
                             "inputBarJPEGBase64", "characterArtBase64"] {
                j[volatile] = nil
            }
            let imgs = (j["categoryImages"] as? [String: String]) ?? [:]
            j["categoryImages"] = imgs.keys.sorted()   // 只比哪些槽位有图
            // [page-state] Page colours compare by value (hex maps)
            // when both sides carry the table. Page wallpapers
            // compare by scope keys only, like category images:
            // re-exported bytes differ (downscale), which is a
            // system behaviour, not a user change — while a scope
            // gaining or losing an image (or a cleared "" entry)
            // is a real change and must drop the in-use tick.
            // Page colour tables are NOT normalised to [:] here:
            // a nil table means "says nothing about page colours",
            // and the cross-side drop below handles it.
            let pageWallKeys: [String]
            if let m = j["pageWallpapers"] as? [String: String] { pageWallKeys = Array(m.keys) }
            else if let m = j["pageWallpapers"] as? [String: Any] { pageWallKeys = Array(m.keys) }
            else { pageWallKeys = [] }
            j["pageWallpapers"] = pageWallKeys.sorted()
            // [T-54 r2] 暗档同样只比槽位，不比字节。
            let pageDarkWallKeys: [String]
            if let m = j["pageDarkWallpapers"] as? [String: String] { pageDarkWallKeys = Array(m.keys) }
            else if let m = j["pageDarkWallpapers"] as? [String: Any] { pageDarkWallKeys = Array(m.keys) }
            else { pageDarkWallKeys = [] }
            j["pageDarkWallpapers"] = pageDarkWallKeys.sorted()
            return j
        }
        var ka = key(a)
        var kb = key(b)
        // [page-state-fix] An apply that did not touch page colours
        // must not drop the tick: when either side's page colour
        // table is nil (an old pack, or a live state the apply
        // preserved under P0-4), that table is dropped from BOTH
        // sides' comparison, per table. When both sides carry a
        // table it is compared by value above. Page wallpaper keys
        // are untouched here: replace always clears page wallpapers,
        // so the keys already agree after an apply and the tick
        // cannot falsely drop on them.
        for colourKey in ["pageColorsLight", "pageColorsDark"] {
            if ka[colourKey] == nil || kb[colourKey] == nil {
                ka[colourKey] = nil
                kb[colourKey] = nil
            }
        }
        return (ka as NSDictionary).isEqual(kb as NSDictionary)
    }

    func renameSavedTheme(id: String, name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        var list = savedThemes()
        guard let idx = list.firstIndex(where: { $0.id == id }) else { return false }
        // [H-03] 写文件的结果以前不看就持久化新名字：文件写失败时列表已经
        // 改名，读回来还是旧名，两边对不上。现在写完读回验一次，验不过就
        // 把元数据恢复原样并如实失败。
        let previousName = list[idx].name
        var packWritten = true
        if var pack = readLibraryPack(id: id) {
            pack.name = trimmed
            writeLibraryPack(pack, id: id)
            packWritten = readLibraryPack(id: id)?.name == trimmed
        }
        guard packWritten else { return false }
        list[idx].name = trimmed
        persistLibrary(list)
        return savedThemes().first(where: { $0.id == id })?.name == trimmed
            || previousName == trimmed
    }

    /// [B28 B-2] 删掉一套。pack 文件不真删，挪进 `trash/` 留着撤销。
    ///
    /// 原来直接 `removeItem` —— 点错一下这套就没了，没有二次确认、没有
    /// 撤销、也没有提示。
    func deleteSavedTheme(id: String) -> Bool {
        deleteSavedThemeDetailed(id: id).deleted
    }

    /// [H-03] Delete with the trash result the caller needs to tell the truth.
    ///
    /// `trashed` is false when there was no pack file to keep — the theme is
    /// gone for good and the AI/user must not be told it can be restored.
    /// A move that fails leaves the metadata untouched: reporting success
    /// while dropping the metadata is what turned a failed move into a
    /// theme that was neither listed nor restorable.
    @discardableResult
    func deleteSavedThemeDetailed(id: String) -> ThemeDeletionOutcome {
        var list = savedThemes()
        let before = list.count
        list.removeAll { $0.id == id }
        guard list.count != before else { return ThemeDeletionOutcome(deleted: false, trashed: false) }
        let src = libraryPackURL(id)
        let dst = trashedPackURL(id)
        var trashed = false
        if FileManager.default.fileExists(atPath: src.path) {
            do {
                try FileManager.default.createDirectory(at: trashDirectory(),
                                                        withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: dst.path) {
                    try FileManager.default.removeItem(at: dst)
                }
                try FileManager.default.moveItem(at: src, to: dst)
                trashed = true
            } catch {
                return ThemeDeletionOutcome(deleted: false, trashed: false)
            }
        }
        pruneTrash()
        persistLibrary(list)
        return ThemeDeletionOutcome(deleted: true, trashed: trashed)
    }

    /// [B28 B-2] 撤销删除：文件搬回 library/，元数据插回列表最前面。
    func restoreSavedTheme(_ item: AppearanceSavedTheme) -> Bool {
        let src = trashedPackURL(item.id)
        guard FileManager.default.fileExists(atPath: src.path) else { return false }
        try? FileManager.default.removeItem(at: libraryPackURL(item.id))
        try? FileManager.default.moveItem(at: src, to: libraryPackURL(item.id))
        var list = savedThemes()
        guard !list.contains(where: { $0.id == item.id }) else { return true }
        // [B28 R2-3] 库满时撤销不进来，如实失败 —— 以前会静默把最后一套
        // 挤出列表，制造第二次「没删却消失」。
        guard list.count < AppearanceSavedTheme.limit else { return false }
        list.insert(item, at: 0)
        persistLibrary(list)
        return true
    }

    private func trashDirectory() -> URL {
        libraryDirectory().appendingPathComponent("trash", isDirectory: true)
    }

    private func trashedPackURL(_ id: String) -> URL {
        trashDirectory().appendingPathComponent("\(id).json")
    }

    /// 回收站只留最近 5 套，免得删过的主题永远堆在磁盘上。
    private func pruneTrash() {
        let dir = trashDirectory()
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return }
        let sorted = files.sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast
            return da > db
        }
        for extra in sorted.dropFirst(5) {
            try? FileManager.default.removeItem(at: extra)
        }
    }

    private func readLibraryPack(id: String) -> AppearanceThemePack? {
        guard let data = try? Data(contentsOf: libraryPackURL(id)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pack = try? AppearanceThemePack.decode(obj) else {
            return nil
        }
        return pack
    }

    private func writeLibraryPack(_ pack: AppearanceThemePack, id: String) {
        guard let data = try? JSONSerialization.data(
            withJSONObject: pack.asJSONObject(),
            options: [.sortedKeys]
        ) else { return }
        try? data.write(to: libraryPackURL(id), options: .atomic)
    }

    private func persistLibrary(_ list: [AppearanceSavedTheme]) {
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: Self.libraryKey)
        }
        themePackRevision += 1
        objectWillChange.send()
    }

    /// [P3-16] Delete saved-theme pack files in `library/` whose id is not
    /// in the theme-library list, returning how many were removed.
    ///
    /// Restore merges the appearance file tree (package files overwrite;
    /// unmentioned files are left alone), but the theme-library LIST in
    /// UserDefaults is replaced wholesale by the backup's. A pack created
    /// after the backup — or whose list entry was deleted while the file
    /// lingered — therefore survives a restore as an orphan: not in the
    /// list, but still on disk. The list is the registry the theme drawer
    /// reads, so a pack with no list entry can never be opened, applied,
    /// or deleted from the UI — unreachable clutter, and deleting it
    /// loses nothing the user could touch.
    ///
    /// Only `library/*.json` pack files are touched. Wallpapers, icons
    /// and category images have no registry to compare against, so they
    /// keep merge semantics: deleting an unreferenced wallpaper could
    /// destroy the live look.
    @discardableResult
    func removeOrphanedLibraryPacks() -> Int {
        let validIds = Set(savedThemes().map(\.id))
        let dir = libraryDirectory()
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return 0 }
        var removed = 0
        for url in files where url.pathExtension.lowercased() == "json" {
            let id = url.deletingPathExtension().lastPathComponent
            guard !validIds.contains(id) else { continue }
            do {
                try FileManager.default.removeItem(at: url)
                removed += 1
            } catch {
                // Leave it; the next restore or delete pass retries.
            }
        }
        return removed
    }
}
