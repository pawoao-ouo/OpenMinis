import Foundation
import SwiftUI
import UIKit

// MARK: - Avatar pendants, simplest batch (enclosing ring only)
//
// Five pendants, all enclosing rings around the whole circular
// avatar — thin, pale, gentle, NOT hard border circles, and NOT
// a halo above the head (the halo style was cut by user decision
// before this batch shipped and is not in the catalogue at all):
// four soft glowing rings (pale yellow / white / blue / pink)
// plus one delicate white lace ring. No other decoration, no
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
// Numbers are stable and never reused (PEN-0001..0005), the
// same numbering rule as bubbles (BUB) and outfits (COM).
//
// User-uploaded frames (the planned self-upload pendant path,
// upload UI in a later batch): a pendant record may carry an
// imageFile instead of a code-drawn ring. When it does, the
// shared ring view draws that image over the avatar. The file
// MUST be a PNG with a transparent background and a centred
// circular empty centre: transparency is what lets the avatar
// show through the middle. A JPG, or a PNG with a black/white
// solid background, will cover the avatar with an opaque
// square — that is a bad file, not a rendering bug. Animated
// frames (APNG/GIF) are not in this batch; static PNG first.
// The applied pendant lives in UserDefaults under one key,
// separate from the theme pack and from outfit rows, so a
// theme change or reset never clears it, and outfit rows are
// never touched by applying a pendant.

enum AvatarPendantStyle: String, Codable, Equatable {
    case glow, lace
}

struct AvatarPendant: Identifiable, Equatable, Codable {
    var number: String
    var title: String
    var category: String
    var style: AvatarPendantStyle
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
        case number, title, category, style, imageFile, hex
    }

    init(number: String, title: String, category: String,
         style: AvatarPendantStyle = .glow, imageFile: String? = nil, hex: String) {
        self.number = number
        self.title = title
        self.category = category
        self.style = style
        self.imageFile = imageFile
        self.hex = hex
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        number = try c.decodeIfPresent(String.self, forKey: .number) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        category = try c.decodeIfPresent(String.self, forKey: .category) ?? ""
        style = try c.decodeIfPresent(AvatarPendantStyle.self, forKey: .style) ?? .glow
        imageFile = try c.decodeIfPresent(String.self, forKey: .imageFile)
        hex = try c.decodeIfPresent(String.self, forKey: .hex) ?? ""
    }
}

@MainActor
final class AvatarPendantStore: ObservableObject {
    static let shared = AvatarPendantStore()
    private static let appliedKey = "dressing.avatarPendantNumber"

    @Published private(set) var appliedNumber: String?

    /// Four pale glowing rings, one colour each, plus one
    /// delicate white lace ring — lace, not a dashed circle.
    static let builtIns: [AvatarPendant] = [
        AvatarPendant(number: "PEN-0001", title: "浅黄圆环", category: "头像挂件", style: .glow, hex: "FFF6CC"),
        AvatarPendant(number: "PEN-0002", title: "浅白圆环", category: "头像挂件", style: .glow, hex: "FFFFFF"),
        AvatarPendant(number: "PEN-0003", title: "浅蓝圆环", category: "头像挂件", style: .glow, hex: "D6EBFF"),
        AvatarPendant(number: "PEN-0004", title: "浅粉圆环", category: "头像挂件", style: .glow, hex: "FFE3EE"),
        AvatarPendant(number: "PEN-0005", title: "白色蕾丝圆环", category: "头像挂件", style: .lace, hex: "FFFFFF"),
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
    var style: AvatarPendantStyle = .glow
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
        } else if style == .lace {
            laceBody
        } else {
            glowBody
        }
    }

    /// Lace, layered and fine — not a dashed circle:
    ///  - a white band ring hugging the avatar;
    ///  - an outer scallop of 24 LARGE overlapping petal loops
    ///    (22pt, wider than their 17pt spacing, so they merge
    ///    into a continuous wavy scallop edge, not separate
    ///    dots), each petal given a faint taupe outline so the
    ///    white petal shape separates from a light background;
    ///  - a ring of 24 open eyelet loops (11pt stroked rings
    ///    with a transparent centre and a faint taupe outline,
    ///    so the hole reads against light backgrounds and the
    ///    avatar shows through) set half a step between
    ///    the petals;
    ///  - a second, smaller inner petal row for depth;
    ///  - a picot edge of tiny dots just outside the petals;
    ///  - one small bow accent at the top of the ring, in
    ///    pale pink (two loops + a knot, our own shape, not
    ///    a copied frame): the only colour accent on an
    ///    otherwise soft-white lace.
    /// Static and delicate: no breathing, so the fine edge
    /// never shimmers into a blur.
    private var laceBody: some View {
        let radius = (size + 12) / 2
        let petalCount = 24
        let outline = Color(red: 0.72, green: 0.66, blue: 0.58)
        return ZStack {
            Circle()
                .stroke(Color.white.opacity(0.85), lineWidth: 6)
                .frame(width: size + 10, height: size + 10)
            ForEach(0..<petalCount, id: \.self) { i in
                let angle = Double(i) / Double(petalCount) * 2 * Double.pi
                Circle()
                    .fill(Color.white.opacity(0.95))
                    .overlay(Circle().stroke(outline.opacity(0.9), lineWidth: 0.75))
                    .frame(width: 22, height: 22)
                    .offset(x: CGFloat(cos(angle)) * radius,
                            y: CGFloat(sin(angle)) * radius)
            }
            ForEach(0..<petalCount, id: \.self) { i in
                let angle = (Double(i) + 0.5) / Double(petalCount) * 2 * Double.pi
                Circle()
                    .stroke(outline.opacity(0.9), lineWidth: 1.25)
                    .frame(width: 11, height: 11)
                    .offset(x: CGFloat(cos(angle)) * radius,
                            y: CGFloat(sin(angle)) * radius)
            }
            ForEach(0..<petalCount, id: \.self) { i in
                let angle = Double(i) / Double(petalCount) * 2 * Double.pi
                Circle()
                    .fill(Color.white.opacity(0.85))
                    .frame(width: 9, height: 9)
                    .offset(x: CGFloat(cos(angle)) * (radius - 12),
                            y: CGFloat(sin(angle)) * (radius - 12))
            }
            ForEach(0..<petalCount, id: \.self) { i in
                let angle = Double(i) / Double(petalCount) * 2 * Double.pi
                Circle()
                    .fill(Color.white.opacity(0.90))
                    .frame(width: 4, height: 4)
                    .offset(x: CGFloat(cos(angle)) * (radius + 14),
                            y: CGFloat(sin(angle)) * (radius + 14))
            }
            // Small bow accent at the top: two pale-pink loops
            // tilted apart plus a knot, sitting on the ring.
            Group {
                Ellipse()
                    .fill(Color(hex: "FFE3EE").opacity(0.95))
                    .overlay(Ellipse().stroke(outline.opacity(0.9), lineWidth: 0.75))
                    .frame(width: 18, height: 11)
                    .rotationEffect(.degrees(-30))
                    .offset(x: -10, y: -radius)
                Ellipse()
                    .fill(Color(hex: "FFE3EE").opacity(0.95))
                    .overlay(Ellipse().stroke(outline.opacity(0.9), lineWidth: 0.75))
                    .frame(width: 18, height: 11)
                    .rotationEffect(.degrees(30))
                    .offset(x: 10, y: -radius)
                Circle()
                    .fill(Color(hex: "FFD1E3"))
                    .overlay(Circle().stroke(outline.opacity(0.9), lineWidth: 0.75))
                    .frame(width: 7, height: 7)
                    .offset(x: 0, y: -radius)
            }
        }
        .frame(width: size + 40, height: size + 40)
        .shadow(color: Color.white.opacity(0.45), radius: 6)
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
            content.overlay(AvatarRingView(size: size, color: pendant.color, style: pendant.style, imageFile: pendant.imageFile))
        } else {
            content
        }
    }
}
