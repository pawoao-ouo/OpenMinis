import Foundation
import SwiftUI
import UIKit

// MARK: - Avatar pendants (four glowing rings only)
//
// Four pendants, one style only: a soft glowing ring enclosing
// the whole circular avatar — thin, pale, gentle glow, NOT a
// hard border circle. No lace, no bows, no cat ears, no halo
// above the head: those variants were cut by final user
// decision before this batch shipped and are not in the
// catalogue or the code at all. No other decoration, no
// payment, no membership. Colours are pale pastels only, one
// per pendant, and the colour is the pendant's identity, so it
// is stored on the record itself (not a theme variable).
//
// Animation: only the glow breathes — a slow soft pulse
// (~2.8s ease in/out, glow opacity 0.7..1.0), never fast,
// never flashing. Colour, thickness, and shape are static and
// never change with the pulse, so a still frame of the ring is
// exactly the approved look.
//
// Numbers are stable and never reused (built-ins PEN-0001..0004,
// AI-created pendants from PEN-0005 up), the same numbering
// rule as bubbles (BUB) and outfits (COM).
//
// The applied pendant lives in UserDefaults, one record PER
// SIDE (user side vs assistant side — see DressingSide), never
// one global record: the two sides may wear different rings,
// and changing one side never moves the other. The records
// store only pendant numbers, never a persona or user name, so
// a persona change or a user-profile rename cannot leave a
// stale name behind — labels and avatars resolve dynamically
// at render time (DressingSide.displayName, PersonAvatarView).
// Separate from the theme pack and from outfit rows, so a
// theme change or reset never clears it, and outfit rows are
// never touched by applying a pendant.
//
// Migration: an install that only has the old single key gets
// that pendant on BOTH sides (first launch looks exactly as
// before); the split is then persisted to the per-side keys,
// and afterwards each side is written separately.

/// Which side of the conversation a dressing choice belongs
/// to. Shared by pendants and bubbles: both stores key their
/// applied records by side, the shop edits one side at a time,
/// and live chat renders each side from its own record.
/// A side is a ROLE, not a person: it carries no name and no
/// avatar of its own. The name shown for a side is resolved
/// fresh at render time — AI side from the current persona
/// (ChatAddressing.assistant, which follows the session /
/// current persona's SOUL.md name), user side from the current
/// user profile (ChatAddressing.user, which follows the
/// profile's addressing name, then the studio display name,
/// then a neutral word). Rename a persona or the user profile
/// and every side label in the shop follows, with no stored
/// name to go stale. Avatars work the same way: PersonAvatarView
/// resolves the image from the current / session persona for
/// the AI side and from the user-profile persona for the user
/// side, so a side's pendant simply wraps whichever avatar is
/// current — it is never pinned to one persona's picture.
@MainActor
enum DressingSide: String, CaseIterable {
    case assistant
    case user

    var isUser: Bool { self == .user }

    /// Display name for this side, resolved NOW from the live
    /// persona / profile — never a stored or hardcoded name.
    /// Empty can only happen if both dynamic sources are blank;
    /// the fallbacks are generic role words, not a person's name.
    var displayName: String {
        if isUser {
            let name = ChatAddressing.user()
            return name.isEmpty ? AppLocalized("你") : name
        }
        let name = ChatAddressing.assistant()
        return name.isEmpty ? AppLocalized("AI") : name
    }
}

struct AvatarPendant: Identifiable, Equatable, Codable {
    var number: String
    var title: String
    var category: String
    /// Optional uploaded frame image file name (no path), under
    /// AppearanceStudio/pendant_images/. Nil for all built-ins.
    /// A name containing a path separator is treated as absent,
    /// same rule as bubble background images.
    var imageFile: String?
    /// Pale colour hex, no "#". The ring reads this colour.
    var hex: String
    /// What this pendant looks like, in words — the description
    /// an AI reads when the user asks for a pendant by number
    /// or describes one it should create. Built-ins carry one;
    /// an AI-created pendant must carry one too, so it is
    /// never applied by name-guessing.
    var detail: String

    var id: String { number }

    var color: Color { Color(hex: hex) }

    private enum CodingKeys: String, CodingKey {
        case number, title, category, imageFile, hex, detail
    }

    init(number: String, title: String, category: String,
         imageFile: String? = nil, hex: String, detail: String = "") {
        self.number = number
        self.title = title
        self.category = category
        self.imageFile = imageFile
        self.hex = hex
        self.detail = detail
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        number = try c.decodeIfPresent(String.self, forKey: .number) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        category = try c.decodeIfPresent(String.self, forKey: .category) ?? ""
        imageFile = try c.decodeIfPresent(String.self, forKey: .imageFile)
        hex = try c.decodeIfPresent(String.self, forKey: .hex) ?? ""
        detail = try c.decodeIfPresent(String.self, forKey: .detail) ?? ""
    }
}

@MainActor
final class AvatarPendantStore: ObservableObject {
    static let shared = AvatarPendantStore()
    /// Legacy single key (pre-per-side installs only). Read once
    /// for migration, never written by this version.
    private static let appliedKey = "dressing.avatarPendantNumber"
    private static let appliedUserKey = "dressing.avatarPendantNumber.user"
    private static let appliedAssistantKey = "dressing.avatarPendantNumber.assistant"
    private static let customsKey = "dressing.avatarPendantCustoms"

    /// Applied pendant number, per side. Nil = no pendant on
    /// that side (live avatars simply show no ring).
    @Published private(set) var appliedUserNumber: String?
    @Published private(set) var appliedAssistantNumber: String?

    func appliedNumber(for side: DressingSide) -> String? {
        side.isUser ? appliedUserNumber : appliedAssistantNumber
    }
    /// Pendants created later by the in-app AI (never by this
    /// batch). They live in UserDefaults as JSON, separate from
    /// the theme pack, so a theme change or reset never clears
    /// them. Numbers start at PEN-0005 and only move forward.
    @Published private(set) var customPendants: [AvatarPendant] = []
    private var nextSerial = 5

    /// Four pale glowing rings, one colour each.
    static let builtIns: [AvatarPendant] = [
        AvatarPendant(number: "PEN-0001", title: "浅黄圆环", category: "头像挂件", hex: "FFF6CC", detail: "浅黄柔光圆环，包住整个圆形头像，细线，柔和发光"),
        AvatarPendant(number: "PEN-0002", title: "浅白圆环", category: "头像挂件", hex: "FFFFFF", detail: "浅白柔光圆环，包住整个圆形头像，细线，柔和发光"),
        AvatarPendant(number: "PEN-0003", title: "浅蓝圆环", category: "头像挂件", hex: "D6EBFF", detail: "浅蓝柔光圆环，包住整个圆形头像，细线，柔和发光"),
        AvatarPendant(number: "PEN-0004", title: "浅粉圆环", category: "头像挂件", hex: "FFE3EE", detail: "浅粉柔光圆环，包住整个圆形头像，细线，柔和发光"),
    ]

    /// Everything the shop shows: the four built-in rings
    /// first, then AI-created pendants in number order. The
    /// shop, detail sheet, and live avatar all read this one
    /// list, so a future AI pendant appears everywhere a
    /// built-in does, with no second path.
    var pendants: [AvatarPendant] { Self.builtIns + customPendants }

    /// The pendant worn by one side, or nil. Live chat and the
    /// shop both read through here, keyed by side — never through
    /// a single global applied pendant.
    func applied(for side: DressingSide) -> AvatarPendant? {
        guard let number = appliedNumber(for: side) else { return nil }
        return pendants.first { $0.number == number }
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.customsKey),
           let decoded = try? JSONDecoder().decode([AvatarPendant].self, from: data) {
            // Only well-formed, non-built-in numbers survive;
            // a corrupt or colliding row is dropped, never
            // allowed to shadow a built-in.
            var seen: Set<String> = []
            customPendants = decoded.filter { p in
                guard !p.number.isEmpty,
                      !Self.builtIns.contains(where: { $0.number == p.number }),
                      seen.insert(p.number).inserted else { return false }
                return true
            }
            let maxSerial = customPendants.compactMap { p in
                Int(p.number.dropFirst(4))
            }.max() ?? 4
            nextSerial = max(5, maxSerial + 1)
        }
        // Per-side records first; a pre-per-side install has only
        // the legacy key, which migrates to BOTH sides so first
        // launch after upgrade looks exactly as before. Unknown
        // or empty values fall back to no pendant on that side —
        // never a crash, never a guessed pendant.
        let legacy = UserDefaults.standard.string(forKey: Self.appliedKey) ?? ""
        let legacyValid = pendants.contains { $0.number == legacy } ? legacy : nil
        func valid(_ raw: String?) -> String? {
            guard let raw, !raw.isEmpty,
                  pendants.contains(where: { $0.number == raw }) else { return nil }
            return raw
        }
        let storedUser = UserDefaults.standard.string(forKey: Self.appliedUserKey)
        let storedAssistant = UserDefaults.standard.string(forKey: Self.appliedAssistantKey)
        let hasPerSide = storedUser != nil || storedAssistant != nil
        appliedUserNumber = hasPerSide ? valid(storedUser) : legacyValid
        appliedAssistantNumber = hasPerSide ? valid(storedAssistant) : legacyValid
        // Persist the migrated split so later launches read the
        // per-side keys (the legacy key is left alone, unread).
        if !hasPerSide, legacyValid != nil { saveApplied() }
    }

    private func saveApplied() {
        if let number = appliedUserNumber {
            UserDefaults.standard.set(number, forKey: Self.appliedUserKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.appliedUserKey)
        }
        if let number = appliedAssistantNumber {
            UserDefaults.standard.set(number, forKey: Self.appliedAssistantKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.appliedAssistantKey)
        }
    }

    private func saveCustoms() {
        guard let data = try? JSONEncoder().encode(customPendants) else { return }
        UserDefaults.standard.set(data, forKey: Self.customsKey)
    }

    /// Create a future AI pendant: the store assigns the next
    /// stable number (never reused, never guessed from a name),
    /// stores the record with its description, and returns it.
    /// Applying it afterwards goes through the same apply()
    /// and the same ring view as a built-in — an AI pendant is
    /// a pendant record, not a special case. A code-drawn ring
    /// uses hex; an image frame uses imageFile; either way the
    /// record must carry a detail description.
    @discardableResult
    func create(title: String, hex: String, detail: String,
                imageFile: String? = nil) -> AvatarPendant {
        let pendant = AvatarPendant(
            number: String(format: "PEN-%04d", nextSerial),
            title: title, category: "头像挂件",
            imageFile: imageFile, hex: hex, detail: detail)
        nextSerial += 1
        customPendants.append(pendant)
        saveCustoms()
        return pendant
    }

    /// The only removal path for AI-created pendants, by
    /// number. Built-ins can never be deleted. If the deleted
    /// pendant was applied, the applied mark clears (live
    /// avatars simply show no pendant) rather than pointing
    /// at a missing record.
    func deleteCustom(number: String) {
        guard !Self.builtIns.contains(where: { $0.number == number }) else { return }
        customPendants.removeAll { $0.number == number }
        // Only the side(s) wearing it clear; the other side's
        // ring is untouched by a deletion on this side.
        if appliedUserNumber == number { appliedUserNumber = nil }
        if appliedAssistantNumber == number { appliedAssistantNumber = nil }
        saveApplied()
        saveCustoms()
    }

    /// Apply to ONE side only. The other side keeps its own ring.
    func apply(_ pendant: AvatarPendant, for side: DressingSide) {
        guard pendants.contains(where: { $0.number == pendant.number }) else { return }
        if side.isUser { appliedUserNumber = pendant.number }
        else { appliedAssistantNumber = pendant.number }
        saveApplied()
    }

    /// Apply to BOTH sides (the old single-apply behaviour, kept
    /// for callers that mean "both sides, same ring" — e.g. a
    /// full-set apply. It writes two per-side records, not one
    /// global record, so changing one side afterwards still
    /// leaves the other alone).
    func apply(_ pendant: AvatarPendant) {
        guard pendants.contains(where: { $0.number == pendant.number }) else { return }
        appliedUserNumber = pendant.number
        appliedAssistantNumber = pendant.number
        saveApplied()
    }
}

// MARK: - Ring rendering (one shared view, every surface)
//
// The ring is drawn the same way in the shop card, the detail
// preview, live chat, and the profile — one view, no second
// version that could promise a different ring. Softness comes
// from a wide blurred outer glow plus a thin bright ring, with
// the ring floating just outside the avatar edge (diameter =
// avatar + 12pt) instead of sitting on it like a border. A
// white pendant still reads because its glow and bright ring
// sit on a shadow, not on a bare white background. Only the
// glow breathes (slow pulse, see header); the ring stroke
// itself is static.

struct AvatarRingView: View {
    let size: CGFloat
    let color: Color
    var imageFile: String? = nil
    @State private var breathing = false

    /// Uploaded transparent frame, if any. Path separators are
    /// rejected and a missing file falls back to the code-drawn
    /// ring — a bad record never leaves an empty hole.
    private var frameImage: UIImage? {
        guard let file = imageFile, !file.isEmpty, !file.contains("/") else { return nil }
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first else { return nil }
        let url = base.appendingPathComponent("AppearanceStudio/pendant_images/\(file)")
        return UIImage(contentsOfFile: url.path)
    }

    var body: some View {
        if let img = frameImage {
            // Transparent frame over the avatar: the image's own
            // transparent centre is the hole, so the frame must
            // be square with a centred circular empty centre.
            // Sized slightly larger than the avatar so the frame
            // edge wraps it instead of sitting on top of it.
            Image(uiImage: img)
                .resizable()
                .scaledToFit()
                .frame(width: size + 16, height: size + 16)
        } else {
            glowBody
        }
    }

    private var glowBody: some View {
        ZStack {
            // Outer glow: wide, blurred, low opacity — the airy
            // part, and the only layer that breathes.
            Circle()
                .stroke(color.opacity(0.22), lineWidth: 7)
                .blur(radius: 5)
                .opacity(breathing ? 1.0 : 0.7)
            // Main ring: soft, static, not hard.
            Circle()
                .stroke(color.opacity(0.70), lineWidth: 2)
            // Inner bright thread, so the ring reads even in white.
            Circle()
                .stroke(Color.white.opacity(0.60), lineWidth: 0.75)
        }
        .frame(width: size + 12, height: size + 12)
        .shadow(color: color.opacity(0.35), radius: 7)
        .onAppear {
            withAnimation(.easeInOut(duration: 2.8).repeatForever(autoreverses: true)) {
                breathing = true
            }
        }
    }
}


extension View {
    /// Overlays THAT SIDE's applied ring on an avatar of the
    /// given size, or nothing when that side wears no pendant.
    /// The side is mandatory: a caller that does not say which
    /// side this avatar belongs to cannot get a ring, so no
    /// avatar can silently borrow the other side's ring. Pass
    /// nil only to deliberately suppress the ring (a preview
    /// that overlays a not-yet-applied pendant itself). The
    /// ring overlay is centred and 12pt wider than the avatar;
    /// callers must not clip the avatar's container tighter
    /// than the ring.
    func avatarPendantRing(size: CGFloat, side: DressingSide?) -> some View {
        modifier(AvatarPendantRingModifier(size: size, side: side))
    }
}

private struct AvatarPendantRingModifier: ViewModifier {
    let size: CGFloat
    let side: DressingSide?
    @ObservedObject private var store = AvatarPendantStore.shared

    func body(content: Content) -> some View {
        if let side, let pendant = store.applied(for: side) {
            content.overlay(AvatarRingView(size: size, color: pendant.color, imageFile: pendant.imageFile))
        } else {
            content
        }
    }
}
