import Foundation
import SwiftUI

/// One saved dressing outfit (a COM row). It is a RECORD, not a
/// live theme: it names the pieces it was saved from (bubble
/// number, and later theme/pendant/font numbers), so applying or
/// deleting it can never guess from a name. Numbers are stable
/// and never reused (nextSerial only moves forward).
///
/// Survival rule, stated plainly because it is the user's rule:
/// changing a theme or resetting a theme NEVER clears this
/// store — it lives in its own file, outside the theme pack.
/// Only deleting by number removes a row.
struct DressingOutfit: Identifiable, Equatable, Codable {
    var number: String
    var title: String
    var bubbleNumber: String?
    var pendantNumber: String?
    var themeNumber: String?
    var summary: String

    var id: String { number }

    private enum CodingKeys: String, CodingKey {
        case number, title, bubbleNumber, pendantNumber, themeNumber, summary
    }

    init(number: String, title: String, bubbleNumber: String? = nil,
         pendantNumber: String? = nil,
         themeNumber: String? = nil, summary: String) {
        self.number = number
        self.title = title
        self.bubbleNumber = bubbleNumber
        self.pendantNumber = pendantNumber
        self.themeNumber = themeNumber
        self.summary = summary
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        number = try c.decodeIfPresent(String.self, forKey: .number) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        bubbleNumber = try c.decodeIfPresent(String.self, forKey: .bubbleNumber)
        pendantNumber = try c.decodeIfPresent(String.self, forKey: .pendantNumber)
        themeNumber = try c.decodeIfPresent(String.self, forKey: .themeNumber)
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
    }
}

/// What one outfit apply actually did. A nil recorded number is
/// skipped, never failed; a recorded number that no longer
/// resolves (the pack / pendant / theme was deleted since the
/// save) is reported in `missing` and never aborts the rest.
struct DressingOutfitApplyOutcome {
    var appliedTheme = false
    var appliedBubble = false
    var appliedPendant = false
    /// "theme", "bubble", "pendant" — a recorded number that no
    /// longer resolves to anything.
    var missing: [String] = []
}

private struct DressingOutfitStoreData: Codable {
    var outfits: [DressingOutfit]
    var nextSerial: Int

    private enum CodingKeys: String, CodingKey {
        case outfits, nextSerial
    }

    init(outfits: [DressingOutfit], nextSerial: Int) {
        self.outfits = outfits
        self.nextSerial = nextSerial
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        outfits = try c.decodeIfPresent([DressingOutfit].self, forKey: .outfits) ?? []
        nextSerial = max(1, try c.decodeIfPresent(Int.self, forKey: .nextSerial) ?? 1)
    }
}

/// Saved outfits store. Single source of truth for COM rows:
/// the shop's outfit tab, the detail sheet's save button, and
/// any later theme-batch code all read and write through here.
@MainActor
final class DressingOutfitStore: ObservableObject {
    static let shared = DressingOutfitStore()

    @Published private(set) var outfits: [DressingOutfit] = []
    private var nextSerial = 1

    private var storeURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first!
        let dir = base.appendingPathComponent("AppearanceStudio", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("dressing_outfits.json")
    }

    private init() { load() }

    private func load() {
        if let data = try? Data(contentsOf: storeURL),
           let stored = try? JSONDecoder().decode(DressingOutfitStoreData.self, from: data),
           !stored.outfits.contains(where: { $0.number.isEmpty }) {
            outfits = stored.outfits
            nextSerial = max(1, stored.nextSerial)
        }
    }

    private func save() {
        let stored = DressingOutfitStoreData(outfits: outfits, nextSerial: nextSerial)
        guard let data = try? JSONEncoder().encode(stored) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }

    /// The saved-theme id of the theme currently applied, if any.
    /// Same key as AppearanceThemeLibrary's private lastAppliedKey
    /// ("appearanceStudio.lastAppliedLibraryID"): only
    /// applySavedTheme sets it. It only counts when it still
    /// resolves to a saved theme — a stale id (theme deleted
    /// since) reads as "no theme number", never an invented one.
    private var currentThemeNumber: String? {
        let key = "appearanceStudio.lastAppliedLibraryID"
        guard let id = UserDefaults.standard.string(forKey: key), !id.isEmpty,
              AppearanceStudio.shared.savedThemes().contains(where: { $0.id == id }) else { return nil }
        return id
    }

    /// Put a saved outfit back on, in the same order a saved
    /// theme set applies: theme first, then bubble pack, then
    /// pendant. Every step reuses the existing apply path — the
    /// user-initiated full-replace theme apply, the both-sides
    /// pack apply, the both-sides pendant apply — so an outfit
    /// apply can never do something those paths cannot.
    ///
    /// The outfit record carries no side, so the pack and the
    /// pendant go on BOTH sides (the whole-conversation meaning,
    /// same as a full-set apply with one number). A recorded
    /// number that no longer resolves is skipped and reported in
    /// the outcome's `missing`; it never aborts the pieces that
    /// do resolve.
    @discardableResult
    func apply(_ outfit: DressingOutfit) -> DressingOutfitApplyOutcome {
        var outcome = DressingOutfitApplyOutcome()
        if let themeNumber = outfit.themeNumber {
            if AppearanceStudio.shared.applySavedTheme(id: themeNumber) != nil {
                outcome.appliedTheme = true
            } else {
                outcome.missing.append("theme")
            }
        }
        if let bubbleNumber = outfit.bubbleNumber {
            if let pack = BubbleStylePackStore.shared.pack(number: bubbleNumber) {
                BubbleStylePackStore.shared.apply(pack)
                outcome.appliedBubble = true
            } else {
                outcome.missing.append("bubble")
            }
        }
        if let pendantNumber = outfit.pendantNumber {
            if let pendant = AvatarPendantStore.shared.pendants.first(where: { $0.number == pendantNumber }) {
                AvatarPendantStore.shared.apply(pendant)
                outcome.appliedPendant = true
            } else {
                outcome.missing.append("pendant")
            }
        }
        return outcome
    }

    /// Save a pendant as one outfit row, same rule as bubbles:
    /// the row names the piece by number, never by name guess.
    /// It also records the currently applied theme's number, so
    /// the outfit can put the whole look back on later.
    @discardableResult
    func save(pendant: AvatarPendant) -> DressingOutfit {
        let number = String(format: "COM-%04d", nextSerial)
        nextSerial += 1
        let outfit = DressingOutfit(
            number: number, title: pendant.title, pendantNumber: pendant.number,
            themeNumber: currentThemeNumber,
            summary: "\(pendant.title) · \(pendant.number)")
        outfits.append(outfit)
        save()
        return outfit
    }

    /// Save the currently applied pieces as one outfit row.
    /// The bubble piece comes from the pack record itself, so
    /// the row can never describe a different pack than the one
    /// the user just previewed. It also records the currently
    /// applied theme's number, so the outfit can put the whole
    /// look back on later.
    @discardableResult
    func save(bubblePack pack: BubbleStylePack) -> DressingOutfit {
        let number = String(format: "COM-%04d", nextSerial)
        nextSerial += 1
        let outfit = DressingOutfit(
            number: number, title: pack.title, bubbleNumber: pack.number,
            themeNumber: currentThemeNumber,
            summary: "\(pack.title) · \(pack.number)")
        outfits.append(outfit)
        save()
        return outfit
    }

    /// The ONLY removal path: by number. No theme change, no
    /// theme reset, and no pack apply ever calls this.
    func delete(number: String) {
        outfits.removeAll { $0.number == number }
        save()
    }
}
