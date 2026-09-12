import Foundation

// MARK: - AI voice-message composer
//
// [T-ai-voice-messages 09-12] 醒醒 2：「我想要里面的ai自己也能发语音，发出来就是
// 自动播放的。有气泡UI像wx那样会动的，有动态效果。」
//
// Flow (triggered from StreamEnd when per-session "AI Voice Replies" is ON):
//   1. Sanitize the assistant text (strip markdown, keep plain text).
//   2. Synthesize via the read-aloud candidate chain (service → group → System).
//   3. Write the WAV bytes to the session's attachments dir.
//   4. Return a minis-clone:// URL + duration for the caller to embed into a
//      markdown audio link. The link renders as a WX-style voice bubble via
//      AudioAttachment (detects `voice_bubble=1` query param).

@MainActor
enum AIVoiceMessageComposer {

    private static let logger = AppLogger(category: "AIVoiceComposer")

    /// Result: (minis-clone URL String, duration in seconds).
    struct Result {
        let url: String
        let duration: Double
    }

    private static func prefKey(_ sid: String) -> String { "ai.voiceReplies.\(sid)" }

    static func voiceRepliesEnabled(sessionId: String) -> Bool {
        UserDefaults.standard.bool(forKey: prefKey(sessionId))
    }

    static func setVoiceReplies(enabled: Bool, sessionId: String) {
        UserDefaults.standard.set(enabled, forKey: prefKey(sessionId))
    }

    /// Synthesize the assistant reply text and persist the audio in the session's
    /// attachments dir. Returns a minis-clone:// URL ready for embedding into a
    /// `![voice](...)` markdown link. All errors (empty text, every candidate
    /// failed) are logged and return nil — the caller just skips the voice bubble.
    static func compose(for text: String, sessionId: String) async -> Result? {
        let sanitized = VoiceTextSanitizer.sanitize(text, mode: .fullText)
        guard !sanitized.isEmpty else { return nil }

        let data: Data
        let dur: Double
        do {
            (data, dur) = try await synthesizeFull(sanitized)
        } catch {
            logger.warning("voice message synthesis failed: \(error.localizedDescription)")
            return nil
        }
        guard !data.isEmpty else { return nil }

        let ext = dur > 0 ? "wav" : "mp3"   // wav duration reads 0 for mp3
        let fname = "tts-\(UUID().uuidString.prefix(8)).\(ext)"
        let hostDir = AIChatViewModel.minisAttachmentsPersistentDir(for: sessionId)
        try? FileManager.default.createDirectory(at: hostDir, withIntermediateDirectories: true)
        let dest = hostDir.appendingPathComponent(fname)
        do {
            try data.write(to: dest, options: .atomic)
        } catch {
            logger.warning("voice message write failed: \(error.localizedDescription)")
            return nil
        }
        let linuxPath = "/var/minis/attachments/\(fname)"
        let minisURL = "minis-clone://attachments/\(fname.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? fname)"
        logger.info("voice message composed: \(linuxPath) dur=\(String(format: "%.1f", dur))s size=\(data.count)")
        return Result(url: minisURL, duration: dur)
    }

    /// Walk the candidate chain exactly like read-aloud: selected service →
    /// model group → System.
    private static func synthesizeFull(_ text: String) async throws -> (Data, Double) {
        if let (data, _) = try? await synthesizeWithServiceOrGroup(text) {
            return (data, VoiceOutputPlayer.wavDurationOf(data))
        }
        let sys = SystemVoiceProvider()
        let data = try await sys.synthesize(VoiceOutputRequest(input: text, responseFormat: .wav))
        return (data, VoiceOutputPlayer.wavDurationOf(data))
    }

    /// linuxPathFor(url:) — turn the minis-clone URL back into the /var/minis
    /// path (used by the auto-play trigger's resolvePathForDirectRead).
    nonisolated static func linuxPathFor(url: String) -> String {
        guard let comps = URLComponents(string: url), let host = comps.host else { return "" }
        let sub = comps.percentEncodedPath.isEmpty ? "" : "/" + (comps.percentEncodedPath.dropFirst().removingPercentEncoding ?? String(comps.percentEncodedPath.dropFirst()))
        return "/var/minis/\(host)\(sub)"
    }

    /// Selected TTS service (kelivo layer) first, then the model group.
    private static func synthesizeWithServiceOrGroup(_ text: String) async throws -> (Data, String?) {
        if let service = TTSServiceStore.shared.selectedService(),
           service.enabled,
           TTSServiceStore.shared.hasAPIKey(for: service),
           let provider = TTSProviderBridge.provider(for: service) {
            let request = TTSProviderBridge.request(for: service, text: text)
            if let data = try? await provider.synthesize(request), !data.isEmpty {
                return (data, service.kind == .azure ? "mp3" : "wav")
            }
        }
        for entry in VoiceProviderResolver.resolvedOutputCandidates() {
            guard let provider = VoiceProviderResolver.outputProvider(for: entry) else { continue }
            if let data = try? await provider.synthesize(
                VoiceOutputRequest(input: text, model: entry.model.id)), !data.isEmpty {
                return (data, VoiceProviderResolver.isSystemEntry(entry.providerInstanceId) ? "wav" : "mp3")
            }
        }
        throw VoiceProviderError.parseError("all voice candidates failed")
    }
}
