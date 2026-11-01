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
// Numbers are stable and never reused (PEN-0001..0004), the
// same numbering rule as bubbles (BUB) and outfits (COM).
//
// The applied pendant lives in UserDefaults under one key,
// separate from the theme pack and from outfit rows, so a
// theme change or reset never clears it, and outfit rows are
// never touched by applying a pendant.

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

    var id: String { number }

    var color: Color { Color(hex: hex) }

    private enum CodingKeys: String, CodingKey {
        case number, title, category, imageFile, hex
    }

    init(number: String, title: String, category: String,
         imageFile: String? = nil, hex: String) {
        self.number = number
        self.title = title
        self.category = category
        self.imageFile = imageFile
        self.hex = hex
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        number = try c.decodeIfPresent(String.self, forKey: .number) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        category = try c.decodeIfPresent(String.self, forKey: .category) ?? ""
        imageFile = try c.decodeIfPresent(String.self, forKey: .imageFile)
        hex = try c.decodeIfPresent(String.self, forKey: .hex) ?? ""
    }
}

@MainActor
final class AvatarPendantStore: ObservableObject {
    static let shared = AvatarPendantStore()
    private static let appliedKey = "dressing.avatarPendantNumber"

    @Published private(set) var appliedNumber: String?

    /// Four pale glowing rings, one colour each.
    static let builtIns: [AvatarPendant] = [
        AvatarPendant(number: "PEN-0001", title: "浅黄圆环", category: "头像挂件", hex: "FFF6CC"),
        AvatarPendant(number: "PEN-0002", title: "浅白圆环", category: "头像挂件", hex: "FFFFFF"),
        AvatarPendant(number: "PEN-0003", title: "浅蓝圆环", category: "头像挂件", hex: "D6EBFF"),
        AvatarPendant(number: "PEN-0004", title: "浅粉圆环", category: "头像挂件", hex: "FFE3EE"),
    ]

    var pendants: [AvatarPendant] { Self.builtIns }

    var applied: AvatarPendant? {
        guard let number = appliedNumber else { return nil }
        return Self.builtIns.first { $0.number == number }
    }

    private init() {
        let stored = UserDefaults.standard.string(forKey: Self.appliedKey) ?? ""
        // Unknown or empty values fall back to no pendant — never
        // a crash, never a guessed pendant.
        appliedNumber = Self.builtIns.contains { $0.number == stored } ? stored : nil
    }

    func apply(_ pendant: AvatarPendant) {
        appliedNumber = pendant.number
        UserDefaults.standard.set(pendant.number, forKey: Self.appliedKey)
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
    /// Overlays the currently applied ring on an avatar of the
    /// given size, or nothing when no pendant is applied. The
    /// ring overlay is centred and 12pt wider than the avatar;
    /// callers must not clip the avatar's container tighter
    /// than the ring.
    func avatarPendantRing(size: CGFloat) -> some View {
        modifier(AvatarPendantRingModifier(size: size))
    }
}

private struct AvatarPendantRingModifier: ViewModifier {
    let size: CGFloat
    @ObservedObject private var store = AvatarPendantStore.shared

    func body(content: Content) -> some View {
        if let pendant = store.applied {
            content.overlay(AvatarRingView(size: size, color: pendant.color, imageFile: pendant.imageFile))
        } else {
            content
        }
    }
}
