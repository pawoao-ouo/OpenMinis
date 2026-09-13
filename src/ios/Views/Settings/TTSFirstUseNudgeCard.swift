import SwiftUI

// MARK: - [T-tts-first-use-nudge 09-13] First-use voice guidance card
//
// N2 (workorder 09-13): a user who never opened Settings → Voice Services
// enables read-aloud and hears the system voice — with zero signal that a
// whole service layer (OpenAI / Azure / MiniMax / ElevenLabs / Qwen ...,
// plus the on-device System voice roster of 100+ quality voices) exists.
// This card shows ONCE per install, at the moment of first enable, and
// offers the one-tap jump to the service list. Dismissing it marks it seen.

struct TTSFirstUseNudgeCard: View {
    let onOpenServices: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "speaker.wave.2.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(MinisTheme.accent)
            Text(AppLocalized("Give me a real voice", comment: "TTS first-use nudge title"))
                .font(.headline)
            Text(AppLocalized("Read-aloud just turned on. Right now I'm using the built-in Apple voice — you can give me a different one: pick a TTS service (OpenAI, Azure, MiniMax, ElevenLabs, Qwen and more) or tune the 100+ built-in system voices.",
                                  comment: "TTS first-use nudge body"))
                .font(.subheadline)
                .foregroundStyle(MinisTheme.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                VoiceOutputPreferences.markFirstUseNudgeShown()
                dismiss()
                onOpenServices()
            } label: {
                Text(AppLocalized("Choose a voice", comment: "TTS first-use nudge CTA"))
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            Button {
                VoiceOutputPreferences.markFirstUseNudgeShown()
                dismiss()
            } label: {
                Text(AppLocalized("Keep the default for now", comment: "TTS first-use nudge dismiss"))
                    .font(.subheadline)
                    .foregroundStyle(MinisTheme.secondaryText)
            }
            .buttonStyle(.plain)
        }
        .padding(24)
        .background(MinisTheme.canvas)
        .interactiveDismissDisabled(false)
    }
}
