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
