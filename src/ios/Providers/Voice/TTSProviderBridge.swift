import Foundation

// MARK: - TTS service → provider bridge
//
// [T-tts-services 09-11] Turns a configured `TTSServiceOptions` (the kelivo-style
// independent layer) into something that can actually synthesize audio.
//
// This deliberately does NOT go through `VoiceProviderFactory.make(for:)`: that
// entry point keys off a `ProviderInstance`'s providerType + base-URL substrings,
// which is the right model when a service *is* a model provider, and the wrong
// one here — a TTS service already knows its vendor exactly. Mapping kind →
// subclass directly keeps the two paths independent, so neither can break the
// other (Decision A).
//
// Credentials are read from the Keychain on every call rather than cached: the
// user can rotate a key in the editor while a read-aloud session is running, and
// re-reading is a cheap Keychain hit compared to a network synthesis.

enum TTSProviderBridge {

    private static let logger = AppLogger(category: "TTSBridge")

    /// Build the provider for a service, or nil when the vendor cannot synthesize.
    /// `apiKey` overrides the stored credential (used by the editor's Test button
    /// so an unsaved key can be tried before it is persisted).
    static func provider(for service: TTSServiceOptions,
                         apiKey overrideKey: String? = nil) -> (any VoiceOutputCapable)? {
        let key = overrideKey ?? TTSServiceStore.shared.apiKey(for: service)
        let base = normalizedBase(service)
        let id = service.keychainInstanceId

        switch service.kind {

        case .openai, .qwen, .qwenAudio:
            // Qwen / Qwen-Audio ride the OpenAI-compatible speech endpoint.
            // Their vendor quirks (workspaceId, region, format) are carried in
            // `extras` and applied by the request builder below.
            return VoiceProvider(providerId: id, baseURL: base, apiKey: key)

        case .gemini:
            return GeminiVoiceProvider(providerId: id, baseURL: base, apiKey: key)

        case .azure:
            var azureBase = base
            if azureBase.hasSuffix("/cognitiveservices") {
                azureBase = String(azureBase.dropLast("/cognitiveservices".count))
            }
            return AzureTTSVoiceProvider(providerId: id, baseURL: azureBase, apiKey: key)

        case .minimax:
            return MiniMaxVoiceProvider(providerId: id, baseURL: base, apiKey: key)

        case .xai:
            return XAIVoiceProvider(providerId: id, baseURL: base, apiKey: key)

        case .elevenlabs:
            return ElevenLabsVoiceProvider(providerId: id, baseURL: base, apiKey: key)

        case .deepgram:
            return DeepgramVoiceProvider(providerId: id, baseURL: base, apiKey: key)

        case .openrouter:
            return OpenRouterVoiceProvider(providerId: id, baseURL: base, apiKey: key)

        case .doubao:
            // Volcano's v3 console issues a single API key; the credential field
            // is that key verbatim (no compound packing needed).
            return DoubaoVoiceProvider(providerId: id, apiKey: key)

        case .mimo:
            return MimoVoiceProvider(providerId: id, baseURL: base, apiKey: key)

        case .xunfei:
            // iFlytek needs three credentials; they live in the single Keychain
            // string as "appId;apiKey;apiSecret" (same convention as the
            // Add-Provider template documents).
            let parts = (key ?? "")
                .split(separator: ";", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard parts.count >= 3 else {
                logger.error("iFlytek service \(service.name) needs appId;apiKey;apiSecret")
                return nil
            }
            return XunfeiVoiceProvider(providerId: id,
                                       appId: parts[0], apiKey: parts[1], apiSecret: parts[2])

        case .groq:
            // Groq serves transcription only — there is no TTS endpoint.
            logger.error("Groq has no speech synthesis endpoint")
            return nil
        }
    }

    /// Build the synthesis request for a service: model + voice id + every
    /// tuning knob the user filled in. The speed knob is lifted out of `extras`
    /// into the typed field so vendors that special-case it (MiniMax, Azure)
    /// still see it through the normal channel.
    static func request(for service: TTSServiceOptions, text: String) -> VoiceOutputRequest {
        var extras = service.extras
        var speed: Float? = nil
        if let raw = extras["speed"], let v = Double(raw), v > 0 {
            speed = Float(v)
            extras.removeValue(forKey: "speed")
        }
        // Strip empties so an untouched field never becomes an empty string in
        // a request body (some vendors 400 on `emotion: ""`).
        extras = extras.filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }

        return VoiceOutputRequest(
            input: text,
            model: service.model,
            voice: service.voice,
            speed: speed,
            responseFormat: format(for: service),
            extras: extras
        )
    }

    /// Response container requested from the vendor. mp3 unless the service
    /// explicitly asks for something else in its knobs.
    private static func format(for service: TTSServiceOptions) -> VoiceOutputFormat {
        let raw = (service.extras["format"] ?? service.extras["outputFormat"] ?? "").lowercased()
        if raw.contains("wav") { return .wav }
        if raw.contains("opus") { return .opus }
        if raw.contains("aac") { return .aac }
        return .mp3
    }

    /// Trim trailing slashes; vendors append their own path segments.
    private static func normalizedBase(_ service: TTSServiceOptions) -> String {
        var base = service.baseURL.trimmingCharacters(in: .whitespaces)
        if base.isEmpty { base = service.kind.defaultBaseURL }
        while base.hasSuffix("/") { base.removeLast() }
        return base
    }
}
