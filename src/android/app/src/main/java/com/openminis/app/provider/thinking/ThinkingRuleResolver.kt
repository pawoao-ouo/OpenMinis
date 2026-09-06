package com.openminis.app.provider.thinking

import com.openminis.app.data.model.ThinkingLevel
import org.json.JSONObject

/**
 * Everything about the endpoint and the model that a rule may look at. Passed explicitly
 * rather than read off the provider so the resolver stays a pure function — which is what
 * makes it testable without a network stub.
 */
data class ThinkingResolveContext(
    val modelId: String,
    /**
     * [T-android-thinking-rules-phase2] Owning provider-instance id, or null. When
     * set, the resolver prepends this instance's user-authored custom rules (from
     * [ThinkingRuleResolver.customRulesFor]) ABOVE the built-in list. Null → built-ins
     * only, byte-identical to Phase 1.
     */
    val instanceId: String? = null,
    val supportsReasoning: Boolean?,
    val declaredEffortValues: List<String>?,
    /**
     * [OpenMinis#163] The catalog affirmatively declares this model has NO effort
     * tiers (it reasons, but takes no `reasoning_effort`). Distinct from
     * `declaredEffortValues == null`, which also means "the catalog never heard
     * of it" — only the affirmative case suppresses the field. Defaults false so
     * every existing construction site keeps its current behaviour.
     *
     * Only consulted together with [isXAI] — see the skip in the reasoningEffort
     * branch.
     */
    val declaresNoEffortTiers: Boolean = false,
    val level: ThinkingLevel,
    val maxTokens: Int,
    /**
     * Vendor predicates, resolved by the caller from the base URL. The resolver never
     * parses URLs itself — that keeps URL-sniffing in one place and lets Phase 2 replace
     * these with user-authored scopes without touching this file.
     */
    val isOpenRouter: Boolean,
    val usesUnifiedReasoningEffort: Boolean,
    val isMistral: Boolean,
    val isDashScope: Boolean,
    /**
     * [OpenMinis#163] Endpoint is xAI's own API (api.x.ai), not a relay that
     * merely serves grok-named models. Scopes the empty-tier skip to the vendor
     * where the 400 was actually observed. Defaults false so existing
     * construction sites are unchanged.
     */
    val isXAI: Boolean = false,
    /**
     * The vendor's documented off tier, or null to omit the field when thinking is off.
     * Already an ALLOWLIST decision made by the caller (iOS ff60c818).
     */
    val offEffort: String?,
)

/**
 * Why a particular wire shape was chosen. Design §8 / GH OpenMinis#100: the resolved
 * outcome must be inspectable, otherwise a user-editable rule layer just replaces one
 * hidden variable with a more complicated one.
 */
data class ThinkingResolveTrace(
    val matchedRuleLabel: String,
    val matchedRuleKind: ThinkingRule.Kind,
    val formatSource: String,
    val emittedKeys: List<String>,
    val clampedFrom: String? = null,
    val clampedTo: String? = null,
) {
    /** One-line form for `AppLogger("Thinking")`. */
    val logLine: String
        get() = buildList {
            add("rule=$matchedRuleLabel")
            add("kind=$matchedRuleKind")
            add("src=$formatSource")
            if (clampedFrom != null && clampedTo != null && clampedFrom != clampedTo) {
                add("clamp=$clampedFrom->$clampedTo")
            }
            add("keys=[${emittedKeys.sorted().joinToString(",")}]")
        }.joinToString(" ")
}

/**
 * Data-driven replacement for the thinking-parameter if-return chain.
 * Mirrors iOS `ThinkingRuleResolver.swift`.
 *
 * PHASE 1 SCOPE — read before extending:
 *  • Covers the OpenAI-compatible family only. Gemini and Anthropic keep their own
 *    emitters; their formats are declared in [ThinkingWireFormat] so the vocabulary is
 *    complete, but nothing resolves to them here. Wiring them in is Phase 2.
 *  • Built-in rules only. No persistence, no user rules, no UI. [ThinkingRule.Kind.CUSTOM]
 *    and [ThinkingWireFormat.CustomPath] exist so Phase 2 need not change these types.
 *  • Behaviour must stay byte-for-byte identical to the pre-refactor chain. That is not an
 *    aspiration — ThinkingWireGoldenSnapshotTest was generated against the old
 *    implementation and committed before this file existed (fdc28e2b).
 *
 * EVALUATION MODEL (design §4), two stages:
 *  Stage A — walk the rules top to bottom, first scope match wins, stop. Ordering is
 *            priority. The PROVIDER_TYPE_DEFAULT at the bottom has AllModels scope so a
 *            match is guaranteed and stage A can never fall through.
 *  Stage B — a matched rule that leaves wireFormat null defers to the fallback chain.
 *            Kept separate from stage A on purpose: cross-rule field merging would make
 *            "why did this value come from there" unanswerable in a trace.
 */
object ThinkingRuleResolver {

    /**
     * [T-android-thinking-rules-phase2] Process-wide cache of user-authored custom
     * rules, keyed by provider-instance id, each list in stored (priority) order.
     * Mirrors iOS `ThinkingRuleCache`: [apply] is a sync call reached from the
     * provider's request builder, but rules live in Room (async), so the repository
     * publishes them here on load and on every mutation. A cache miss yields an empty
     * list ⇒ built-in-only behaviour, never a wrong shape.
     */
    @Volatile
    private var customRulesCache: Map<String, List<ThinkingRule>> = emptyMap()

    /** Replace the whole cache (called once after the repository loads config). */
    @Synchronized
    fun setAllCustomRules(byInstance: Map<String, List<ThinkingRule>>) {
        customRulesCache = byInstance
    }

    /** Replace one instance's custom rules (called after an add/edit/delete/reorder). */
    @Synchronized
    fun setCustomRules(instanceId: String, rules: List<ThinkingRule>) {
        customRulesCache = customRulesCache.toMutableMap().apply {
            if (rules.isEmpty()) remove(instanceId) else put(instanceId, rules)
        }
    }

    /** This instance's custom rules in priority order, or empty. */
    fun customRulesFor(instanceId: String?): List<ThinkingRule> =
        instanceId?.let { customRulesCache[it] } ?: emptyList()

    // NOTE: truncated mid-upload - DO NOT KEEP THIS COMMIT
    fun builtInRules(ctx: ThinkingResolveContext): List<ThinkingRule> = emptyList()
}
