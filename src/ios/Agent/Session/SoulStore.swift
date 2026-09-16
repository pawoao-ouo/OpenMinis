import Foundation
import SwiftUI
import UIKit

/// [T-soul-custom-icon] Encode/decode for the Soul identity icon when the
/// user picks an image rather than an emoji.
///
/// Lives in this file rather than its own because `Agent/Session` is a plain
/// Xcode group, not a synchronized one — a new file there means editing
/// `project.pbxproj`, which several sessions contend over.
enum SoulIconImage {
    /// Rendered edge, in points, of the largest surface that shows the icon
    /// (the Soul Settings preview card; the chat header draws it at 18pt).
    static let renderPoints: CGFloat = 32
    /// Stored edge in pixels — the render size at @3x, so the icon is crisp
    /// on every current device and never larger than it needs to be.
    static let storedPixels: CGFloat = renderPoints * 3

    private static let prefix = "data:image/png;base64,"

    /// Cap on the stored data URI. Lives here (rather than on the removed
    /// `SoulIconSource`) because `encode` is the only thing that writes one.
    /// Mirrors Android's `SoulIcon.MAX_DATA_URI_CHARS` — the value syncs
    /// between platforms, so a value one side would refuse to load must not be
    /// storable on the other.
    static let maxStoredChars = 64 * 1024

    static func isDataURI(_ s: String) -> Bool { s.hasPrefix(prefix) }

    /// Why an image was refused.
    ///
    /// [T-soul-icon-opaque-rounded] `opaque` is gone. It used to reject any
    /// image without an alpha channel, on the reasoning that an unframed
    /// opaque rectangle reads as a broken tile. That reasoning was about
    /// PRESENTATION, and it is now handled where it belongs: `SoulIconView`
    /// clips every image to a rounded rectangle, so a JPEG or a flattened PNG
    /// renders as a normal small avatar. Keeping the refusal would have meant
    /// turning away the majority of images a user might pick, to solve a
    /// problem the renderer already solves.
    enum RejectionReason: Error {
        case unreadable
        /// Encoded data URI exceeds `Self.maxStoredChars`.
        /// Same gate Android's `SoulIcon.encode` applies via `TOO_LARGE` /
        /// `MAX_DATA_URI_CHARS`, so the Settings picker and the config path
        /// cannot diverge on what is storable. Associated value is the
        /// refused URI's character count (for config diagnostics).
        case tooLarge(Int)
    }

    /// Normalize a picked image into the stored form: square, downscaled,
    /// PNG, base64 data URI.
    ///
    /// Accepts opaque and transparent images alike — anything UIKit can
    /// decode. Re-encoding to PNG regardless keeps one stored format (so
    /// `isDataURI`'s single prefix stays valid) and preserves alpha when the
    /// source had it.
    static func encode(_ image: UIImage) -> Result<String, RejectionReason> {
        guard image.cgImage != nil else { return .failure(.unreadable) }

        let square = squareCropped(image)
        // Square and bounded: the chat header's row height is a hardcoded
        // layout estimate (28pt), so a non-square icon there would fight the
        // measured height. Cropping here means every consumer can assume 1:1.
        let side = min(storedPixels, max(square.size.width, square.size.height) * square.scale)
        let target = CGSize(width: side, height: side)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1              // size is already in pixels
        format.opaque = false         // preserve alpha
        let scaled = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            square.draw(in: CGRect(origin: .zero, size: target))
        }

        guard let png = scaled.pngData() else { return .failure(.unreadable) }
        let uri = prefix + png.base64EncodedString()
        // Cap lives HERE so every caller — Settings picker and SoulIconSource
        // alike — refuses the same oversized payload. Mirrors Android
        // `SoulIcon.encode` checking `MAX_DATA_URI_CHARS`.
        guard uri.count <= Self.maxStoredChars else {
            return .failure(.tooLarge(uri.count))
        }
        return .success(uri)
    }

    /// Decode a stored data URI back to an image. Returns nil for an emoji
    /// value or anything malformed, so callers can fall back to text.
    static func decode(_ value: String) -> UIImage? {
        guard isDataURI(value) else { return nil }
        let b64 = String(value.dropFirst(prefix.count))
        guard let data = Data(base64Encoded: b64) else { return nil }
        return UIImage(data: data)
    }

    /// [T-multi-assistant 09-14] Raw bytes of a stored data URI, for callers
    /// that need to write the image to a file (the persona migration moves an
    /// inline avatar out of SOUL.md and onto disk). Returns nil for a non-data
    /// URI or malformed base64 rather than throwing — migration treats an
    /// unreadable avatar as "no avatar" and keeps going.
    static func data(fromDataURI value: String) -> Data? {
        guard isDataURI(value) else { return nil }
        let b64 = String(value.dropFirst(prefix.count))
        return Data(base64Encoded: b64, options: [.ignoreUnknownCharacters])
    }

    /// Centre-crop to 1:1, keeping the shorter edge.
    private static func squareCropped(_ image: UIImage) -> UIImage {
        let w = image.size.width, h = image.size.height
        guard w != h, w > 0, h > 0 else { return image }
        let side = min(w, h)
        let origin = CGPoint(x: (w - side) / 2, y: (h - side) / 2)

        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.opaque = false
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side),
                                       format: format).image { _ in
            image.draw(at: CGPoint(x: -origin.x, y: -origin.y))
        }
    }
}

/// [T-soul-custom-icon] The Soul identity icon, rendered the same way
/// everywhere it appears.
///
/// Shared so every surface (Soul Settings preview at 32pt, the settings
/// picker sheet, chat turn header at 18pt) cannot drift apart: they differ
/// only in `size`. The image branch is drawn 1:1 — `encode` already
/// guaranteed a square, so this cannot distort.
///
/// [T-soul-icon-opaque-rounded] The image clip is a CONTINUOUS ROUNDED
/// RECTANGLE, and that is the single place the shape is decided. Since
/// opaque images are now accepted, the renderer is what stops a JPEG from
/// reading as a hard-edged tile — so the corner treatment has to live in the
/// shared component, not at each call site, or one surface would inevitably
/// miss it.
///
/// Rounded rather than a circle: at 18pt a circular mask eats the corners of
/// a small avatar (logos and faces lose noticeably more), and the request was
/// explicitly for a soft edge, not a crop to round. The radius scales with
/// `size` so the 18pt header and the 32pt card look like the same shape
/// rather than one looking markedly boxier than the other.
struct SoulIconView: View {
    let icon: String
    let size: CGFloat
    /// Gradient used for the default sparkle in the chat header. Nil renders
    /// the plain emoji glyph, which is what the settings card wants.
    var sparkleGradient: LinearGradient? = nil

    /// ~22% of the edge: iOS's own app-icon "squircle" proportion, which
    /// reads as rounded at 18pt without rounding away image content.
    static func cornerRadius(for size: CGFloat) -> CGFloat { size * 0.22 }

    var body: some View {
        if let image = SoulIconImage.decode(icon) {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius(for: size),
                                            style: .continuous))
        } else if icon.isEmpty, let gradient = sparkleGradient {
            // Default: keep the SF Symbol so the chat header's existing
            // gradient treatment is untouched for users who never set one.
            Image(systemName: "sparkles")
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(gradient)
        } else {
            // A user-chosen emoji, or the default sparkle where no gradient
            // was requested.
            Text(icon.isEmpty ? "✨" : icon)
                .font(.system(size: size))
        }
    }
}


/// [T-roles-identity-09-16] In-memory snapshot of the persona table, for
/// call sites that cannot `await` (`baseSystemPrompt` is a plain computed
/// property; `ChatStore` is an actor).
///
/// This used to be "SoulStore" and own a SOUL.md file — the single global
/// personality every conversation shared. There is no global personality any
/// more: a persona lives on its role, in the `assistants` table, and each
/// conversation reads ITS role. What remains here is the synchronous cache of
/// that table plus the currently-open session's role id, so identity surfaces
/// can resolve a name without an actor hop.
enum SoulStore {

    /// [T-identity-source 09-16] The role bound to the currently visible chat
    /// session. UI identity (title pill, placeholder, "X is thinking" bubble,
    /// Live Activity) reads this — so chatting with a role called "艾莉"
    /// surfaces "艾莉".
    ///
    /// Set by `AIChatView.refreshTitlePillSession` whenever a session loads.
    /// nil while no session is visible (e.g. sidebar / settings).
    @MainActor
    static var activeAssistantId: String? = nil

    /// The name to show for the currently visible session. Resolves the role
    /// by id; "Minis" only when there is no role to resolve (no session open,
    /// or the role was deleted on another device).
    @MainActor
    static func activeDisplayName() -> String {
        guard let id = activeAssistantId,
              let a = cachedAssistants[id] else { return "Minis" }
        let n = a.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? "Minis" : n
    }

    /// Set the active session's role and notify identity UI to refresh.
    /// Pass nil when leaving a session (sidebar / settings); the name then
    /// falls back to "Minis".
    @MainActor
    static func setActiveAssistant(_ id: String?) {
        guard activeAssistantId != id else { return }
        activeAssistantId = id
        NotificationCenter.default.post(name: .sessionAssistantChanged, object: nil)
    }

    /// [T-multi-assistant 09-14] Synchronous snapshot of every persona, for
    /// call sites that cannot `await` — `baseSystemPrompt` is a plain computed
    /// property, and `ChatStore` is an actor, so `getAssistant()` is not
    /// reachable from there.
    ///
    /// Refreshed by `refreshAssistantCache()` after any persona write and at
    /// launch.
    @MainActor
    static var cachedAssistants: [String: Assistant] = [:]

    /// Re-read every persona into `cachedAssistants` and notify observers.
    @MainActor
    static func refreshAssistantCache() async {
        let all = await ChatStore.shared.listAssistants()
        var map: [String: Assistant] = [:]
        for a in all { map[a.id] = a }
        cachedAssistants = map
        NotificationCenter.default.post(name: .assistantDidChange, object: nil)
    }

    /// Synchronous persona lookup for prompt building and UI rendering.
    /// Returns nil when the cache has not been populated yet (very first
    /// launch before `refreshAssistantCache` completes) or the role is gone.
    @MainActor
    static func cachedAssistant(_ id: String) -> Assistant? {
        cachedAssistants[id]
    }
}

extension Notification.Name {
    /// [T-identity-source 09-16] Posted when the active session's assistant
    /// changes, so identity UI (title pill, typing bubble, sidebar) refreshes
    /// without each component reaching into the view model.
    static let sessionAssistantChanged = Notification.Name("MinisSessionAssistantChanged")

    /// [T-multi-assistant 09-14] Posted after the persona cache is refreshed
    /// (create / rename / delete / prompt edit). Listeners that render a
    /// persona name or avatar refresh from `SoulStore.cachedAssistant(_:)`.
    static let assistantDidChange = Notification.Name("MinisAssistantDidChange")
}

// MARK: - System prompt composition

enum SystemPromptBuilder {

    private static let logger = AppLogger(category: "Soul")

    /// The identity sentence template. `{name}` is substituted from the
    /// role's `name`. This wording is owned by the app — users never see it
    /// in the persona editor, and it is stable so model-side expectations
    /// ("Minis, capable AI assistant, iSH Linux shell") stay intact
    /// regardless of what the user writes as a personality.
    ///
    /// IMPORTANT: keep this sentence in sync with the original literal that
    /// lived in `baseSystemPrompt`. Wording changes here affect every chat.
    private static let identityTemplate =
        "You are {name}, a capable AI assistant running on an iOS device with a fully functional iSH Linux shell (Alpine Linux, aarch64). "

    /// Render the identity sentence (template + name) and optionally
    /// append the user-authored persona prompt.
    ///
    /// [T-multi-assistant 09-14] The persona comes from the `assistants` row
    /// for `assistantId` — the role this conversation belongs to.
    ///
    /// Two things were deliberately dropped on the way:
    ///
    ///   • `style` — it used to be injected as its own "Response style … apply
    ///     to every reply" block. A model handed a handful of adjectives
    ///     latches onto those words and treats the box as ticked, which
    ///     flattens the performance instead of shaping it. The user's voice
    ///     text is not lost: the migration folded it into `systemPrompt`.
    ///   • `lang` — it only asked the user to pin a language the model already
    ///     infers from the user's own message.
    ///
    /// When no role can be resolved the prompt gets the identity sentence
    /// only, with no personality block. There is no fallback: the address book
    /// is the sole source of persona, and a built-in character is not a
    /// neutral default.
    @MainActor
    static func identitySection(assistantId: String? = nil) -> String {
        let resolvedId = assistantId ?? ChatStore.defaultAssistantId
        // Read the synchronous snapshot, NOT ChatStore: it is an actor and this
        // runs from a plain computed property (`baseSystemPrompt`).
        // Fully qualified: the cache lives on SoulStore, this method on
        // SystemPromptBuilder — different types in the same file.
        let assistant = SoulStore.cachedAssistant(resolvedId)

        let name: String
        let persona: String
        if let assistant {
            let n = assistant.name.trimmingCharacters(in: .whitespacesAndNewlines)
            name = n.isEmpty ? "Minis" : n
            persona = assistant.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            // No persona row — an empty address book, or a session whose
            // persona was deleted on another device. There is deliberately no
            // fallback to any built-in character: this app ships no
            // characters, so the identity sentence keeps the generic name and
            // whoever the user creates next supplies the personality.
            name = "Minis"
            persona = ""
        }

        let identity = identityTemplate.replacingOccurrences(of: "{name}", with: name)
        let identityTrimmed = identity.trimmingCharacters(in: .whitespaces)

        // [T-roles-identity-09-16] Fixed hint telling the model how the
        // persona can be changed. Always appended so the model never says
        // "I can't change my personality". System-owned text — not part of the
        // user's prompt.
        //
        // The old wording offered TWO paths and both were dead: `minis-config
        // set soul.*` wrote a SOUL.md file the identity layer no longer read,
        // and the "assistant settings" screen it pointed at had been removed.
        // A persona lives on its role, and the only way to change one is on
        // that role's own page — so that is what this says.
        let soulEditHint =
            "---\n" +
            "Your persona (name / avatar / prompt) belongs to the role you are speaking as. " +
            "It can be edited on that role's own page — ask the user to tap your name at the top of the conversation and edit it there. " +
            "Do not say you cannot change your personality."

        guard !persona.isEmpty else {
            return identityTrimmed + "\n\n" + soulEditHint + "\n\n"
        }

        let personality = scrubInjections(persona)

        // Strip the trailing space we'd otherwise leave hanging at the
        // end of the first paragraph when a personality block follows.
        return identityTrimmed
            + "\n\nPersonality (your character and voice; defer to the user's latest message when it conflicts with anything here):\n"
            + personality
            + "\n\n"
            + soulEditHint
            + "\n\n"
    }

    /// Drop lines that look like an attempt to subvert the system prompt.
    /// Conservative regex — matches "ignore previous instructions" and the
    /// usual variants ("disregard prior", "forget previous", etc.). Casts
    /// a wide net on purpose; SOUL.md is user-authored personality, not a
    /// place for instructions to the model anyway.
    private static func scrubInjections(_ s: String) -> String {
        let patterns: [String] = [
            #"(?i)ignore.{0,30}previous.{0,30}instructions?"#,
            #"(?i)disregard.{0,30}(previous|prior).{0,30}instructions?"#,
            #"(?i)forget.{0,30}(previous|prior).{0,30}instructions?"#,
        ]
        var lines = s.components(separatedBy: "\n")
        lines = lines.filter { line in
            for p in patterns {
                if line.range(of: p, options: .regularExpression) != nil {
                    return false
                }
            }
            return true
        }
        return lines.joined(separator: "\n")
    }
}

