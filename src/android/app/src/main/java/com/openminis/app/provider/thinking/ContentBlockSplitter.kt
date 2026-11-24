package com.openminis.app.provider.thinking

import org.json.JSONArray

/**
 * [thinking-blocks] Kotlin port of iOS `ContentBlockSplitter`.
 *
 * The OpenAI schema allows `content` to be EITHER a plain string OR an array of
 * content blocks. Reading it as a string silently drops every array-shaped
 * response — the Mistral/DeepSeek bug: thinking arrived in a block list and
 * neither the thinking nor the text reached the UI.
 *
 * Shape captured live from `api.mistral.ai` (deepseek-v4-1-flash-1017,
 * `reasoning_effort: "high"`, 2026-11-25). Non-streaming `message.content` and
 * streaming `delta.content` carry the SAME vocabulary:
 *
 * ```json
 * "content": [
 *   {"type": "thinking", "thinking": [{"type": "text", "text": "…"}], "closed": true},
 *   {"type": "text", "text": "…"}
 * ]
 * ```
 *
 * Two details no doc states: a thinking block's payload is a NESTED block
 * array under `thinking`, and one stream carries BOTH shapes (early deltas are
 * `"content": ""`). Unknown block types are ignored, never turned into body
 * text, so a future vendor's new block kind cannot corrupt the reply.
 */
object ContentBlockSplitter {

    data class Split(
        val thinking: String = "",
        val visible: String = "",
        /** Input was a recognisable content value (string or block array). */
        val recognised: Boolean = false
    )

    fun isThinkingType(raw: String?): Boolean {
        val t = (raw ?: "").lowercase()
        return t.contains("thinking") || t.contains("reasoning")
    }

    fun thinkingText(block: org.json.JSONObject): String {
        block.optJSONArray("thinking")?.let { nested ->
            val joined = buildString {
                for (i in 0 until nested.length()) {
                    append(nested.optJSONObject(i)?.optString("text", "") ?: "")
                }
            }
            if (joined.isNotEmpty()) return joined
        }
        block.optString("thinking", "").takeIf { it.isNotEmpty() }?.let { return it }
        block.optString("text", "").takeIf { it.isNotEmpty() }?.let { return it }
        block.optString("reasoning", "").takeIf { it.isNotEmpty() }?.let { return it }
        block.optJSONArray("reasoning")?.let { nested ->
            val joined = buildString {
                for (i in 0 until nested.length()) {
                    append(nested.optJSONObject(i)?.optString("text", "") ?: "")
                }
            }
            if (joined.isNotEmpty()) return joined
        }
        block.optJSONArray("content")?.let { nested ->
            val joined = buildString {
                for (i in 0 until nested.length()) {
                    append(nested.optJSONObject(i)?.optString("text", "") ?: "")
                }
            }
            if (joined.isNotEmpty()) return joined
        }
        return ""
    }

    fun visibleText(block: org.json.JSONObject): String {
        block.optString("text", "").takeIf { it.isNotEmpty() }?.let { return it }
        block.optJSONArray("content")?.let { nested ->
            val joined = buildString {
                for (i in 0 until nested.length()) {
                    append(nested.optJSONObject(i)?.optString("text", "") ?: "")
                }
            }
            if (joined.isNotEmpty()) return joined
        }
        return ""
    }

    /** Split a raw `content` value (String, JSONArray, or null). */
    fun split(raw: Any?): Split {
        when (raw) {
            is String -> return Split(visible = raw, recognised = true)
            is JSONArray -> {
                var thinking = ""
                var visible = ""
                for (i in 0 until raw.length()) {
                    val block = raw.optJSONObject(i) ?: continue
                    val type = block.optString("type", "")
                    when {
                        isThinkingType(type) -> thinking += thinkingText(block)
                        type == "text" || type.isEmpty() -> visible += visibleText(block)
                        // image_url / audio / tool_use … is not body text.
                    }
                }
                return Split(thinking = thinking, visible = visible, recognised = true)
            }
            else -> return Split()
        }
    }
}