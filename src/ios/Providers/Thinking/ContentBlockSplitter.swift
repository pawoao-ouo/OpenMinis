import Foundation

/// Split an OpenAI-compatible `content` value into (thinking, visible) text.
///
/// The OpenAI schema allows `content` to be EITHER a plain string OR an array of
/// content blocks. Reading it as `as? String` silently drops every array-shaped
/// response — which is exactly the Mistral/DeepSeek bug: thinking arrived in a
/// block list and neither the turn's thinking nor its text ever reached the UI.
///
/// Shape captured live from `api.mistral.ai` (deepseek-v4-1-flash-1017,
/// `reasoning_effort: "high"`, 2026-11-25). Non-streaming `message.content` and
/// streaming `delta.content` carry the SAME block vocabulary:
///
/// ```json
/// "content": [
///   {"type": "thinking",
///    "thinking": [{"type": "text", "text": "…"}],
///    "closed": true},
///   {"type": "text", "text": "…"}
/// ]
/// ```
///
/// Two details that are not guessable from the docs:
///   1. a thinking block's payload is a NESTED block array under `thinking`,
///      not a plain string;
///   2. a single stream carries BOTH shapes — the first few deltas are
///      `"content": ""` (a string) and only later ones switch to an array.
///
/// The parser therefore accepts strings and arrays, and tolerates the flat
/// spellings (`{type:thinking, text:…}`, `{type:reasoning, reasoning:…}`) that
/// other gateways use for the same concept. It never guesses a block type it
/// does not recognise: unknown blocks are ignored rather than turned into body
/// text, so a future vendor adding a block kind cannot corrupt the reply.
enum ContentBlockSplitter {

    struct Split: Equatable {
        var thinking: String = ""
        var visible: String = ""
        /// True when the input was a recognisable content value at all
        /// (string or block array). Lets callers tell "no content" from
        /// "content in a shape we don't understand".
        var recognised = false
    }

    /// Block types that mean "this is the model thinking". Matched
    /// case-insensitively, and by substring so `reasoning_content` /
    /// `thinking_delta` are covered without a hardcoded list of every vendor's
    /// spelling.
    static func isThinkingType(_ raw: String) -> Bool {
        let t = raw.lowercased()
        return t.contains("thinking") || t.contains("reasoning")
    }

    /// Text carried by one thinking block. Accepts the nested-block shape first
    /// (the live one), then the flat string spellings.
    static func thinkingText(from block: [String: Any]) -> String {
        if let nested = block["thinking"] as? [[String: Any]] {
            let joined = nested.compactMap { $0["text"] as? String }.joined()
            if !joined.isEmpty { return joined }
        }
        if let s = block["thinking"] as? String { return s }
        if let s = block["text"] as? String { return s }
        if let s = block["reasoning"] as? String { return s }
        if let nested = block["reasoning"] as? [[String: Any]] {
            return nested.compactMap { $0["text"] as? String }.joined()
        }
        if let nested = block["content"] as? [[String: Any]] {
            return nested.compactMap { $0["text"] as? String }.joined()
        }
        return ""
    }

    /// Text carried by one visible block.
    static func visibleText(from block: [String: Any]) -> String {
        if let s = block["text"] as? String { return s }
        if let nested = block["content"] as? [[String: Any]] {
            return nested.compactMap { $0["text"] as? String }.joined()
        }
        return ""
    }

    static func split(_ raw: Any?) -> Split {
        var out = Split()
        guard let raw else { return out }

        if let s = raw as? String {
            out.recognised = true
            out.visible = s
            return out
        }

        guard let blocks = raw as? [[String: Any]] else { return out }
        out.recognised = true
        for block in blocks {
            let type = block["type"] as? String ?? ""
            if isThinkingType(type) {
                out.thinking += thinkingText(from: block)
            } else if type == "text" || type.isEmpty {
                out.visible += visibleText(from: block)
            }
            // Everything else (image_url, audio, tool_use …) is not body text.
            // Media has its own attachment path; ignoring here keeps the reply
            // clean instead of dumping a base64 blob into the transcript.
        }
        return out
    }
}