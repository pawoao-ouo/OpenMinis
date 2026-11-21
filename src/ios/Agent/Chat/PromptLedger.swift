import Foundation

/// [Phase 0 — token observability] The prompt ledger.
///
/// The plan (ch. 8) requires prompt assembly to converge on a single builder
/// with a per-section ledger, so the usage page can show where the tokens go
/// and the 8.5K gap can be attributed instead of guessed.
///
/// The builder (`buildTurnSystemPrompt`) computes each fragment as before and
/// hands the ordered sections to `PromptAssembler`; the assembler is the only
/// place that joins them. Section order is part of the contract — it is pinned
/// by `PromptAssemblerSnapshotTests`.
///
/// A section's `separator` is the exact joiner placed BEFORE its text
/// (`"\n\n"` for almost every fragment, `""` for fragments that already start
/// with their own newline, e.g. `memoryStatusFragment`, and for fragments
/// appended raw, e.g. the evolution injector). Callers must never append an
/// empty fragment: an empty text with a `"\n\n"` separator would inject a
/// stray blank line the old builder never produced.

/// The seven ledger sections the usage page shows (plan ch. 2 / ch. 8).
/// `kind` is the sheet aggregation; `name` keeps the finer attribution
/// (e.g. "mcp-servers" inside `.system`) so detail is never lost.
enum PromptSectionKind: String, CaseIterable, Sendable {
    case system
    case tools
    case skills
    case memory
    case history
    case thinking
    case protocolEnvironment

    /// The row label on the usage sheet.
    var sheetLabel: String {
        switch self {
        case .system: return "System"
        case .tools: return "Tools"
        case .skills: return "Skills"
        case .memory: return "Memory"
        case .history: return "History"
        case .thinking: return "Thinking"
        case .protocolEnvironment: return "Protocol & Environment"
        }
    }
}

/// One builder segment: which sheet row it belongs to, its fine-grained name,
/// the exact separator before it, and its text.
struct PromptSection: Sendable {
    let kind: PromptSectionKind
    let name: String
    let separator: String
    let text: String
}

/// The counted form of a section, as stored on the VM for the usage sheet.
struct PromptSectionTokens: Sendable {
    let kind: PromptSectionKind
    let name: String
    let tokens: Int
}

/// One request's token ledger (Phase 0, plan ch. 2 / ch. 8).
///
/// Sections are BPE counts of what was actually sent; `interfacePromptTokens`
/// is the provider's own count for the same request, attached when the usage
/// event lands. The difference between the two is the protocol remainder —
/// the number the plan's 8.5K hunt is after — and it is shown as
/// `unattributedTokens`, never hidden.
///
/// BPE here is cl100k_base (`BPETokenizer`); the interface uses its own
/// tokenizer, so a small remainder from tokenizer drift is expected. A
/// remainder in the thousands on a fresh persona is not drift — it is a
/// section nobody accounted for, and this ledger is how it gets found.
struct RequestLedger: Sendable {
    /// BPE tokens per builder section kind (from `lastBuiltPromptSections`).
    var sectionTokens: [PromptSectionKind: Int] = [:]
    /// BPE tokens of the tool definitions as sent.
    var toolsTokens: Int = 0
    /// BPE tokens of the history messages as sent.
    var historyTokens: Int = 0
    /// Reasoning/thinking tokens reported for this request (output-side).
    var thinkingTokens: Int = 0
    /// The provider's prompt_tokens for this request, once the usage event lands.
    var interfacePromptTokens: Int? = nil

    var systemTokens: Int { sectionTokens[.system] ?? 0 }
    var skillsTokens: Int { sectionTokens[.skills] ?? 0 }
    var memoryTokens: Int { sectionTokens[.memory] ?? 0 }
    var ambientTokens: Int { sectionTokens[.protocolEnvironment] ?? 0 }

    /// Tokens accounted for on the input side (everything except thinking,
    /// which is output-side and excluded from the input closure math).
    var accountedInputTokens: Int {
        systemTokens + toolsTokens + skillsTokens + memoryTokens + historyTokens + ambientTokens
    }

    /// Interface total minus accounted input: message framing, role markers,
    /// tool-call wrappers, and tokenizer drift. Positive = the interface
    /// counted more than our BPE recipe; negative = our BPE over-counted.
    /// nil until the usage event lands.
    var unattributedTokens: Int? {
        interfacePromptTokens.map { $0 - accountedInputTokens }
    }

    /// Protocol & Environment row = ambient block + unattributed remainder,
    /// so the breakdown rows sum to the interface total once it is known.
    /// nil until the usage event lands (the sheet falls back to ambient alone).
    var protocolTokens: Int? {
        unattributedTokens.map { ambientTokens + $0 }
    }
}

/// The single place that joins a prompt. Pure and deterministic: the same
/// (base, sections) always yields the same string, which is what the snapshot
/// test pins. It deliberately knows nothing about models, sessions, or stores
/// — everything dynamic is computed by the builder before this call.
///
/// NOTE: full-builder byte-stability is impossible to pin, because the ambient
/// fragment embeds wall-clock time. This assembler is the pinned seam.
enum PromptAssembler {
    static func assemble(base: String, sections: [PromptSection]) -> String {
        var out = base
        out.reserveCapacity(base.count + sections.reduce(0) { $0 + $1.separator.count + $1.text.count })
        for section in sections {
            out += section.separator
            out += section.text
        }
        return out
    }
}
