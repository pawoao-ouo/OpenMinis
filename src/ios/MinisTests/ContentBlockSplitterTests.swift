import XCTest
@testable import Minis

/// [thinking-blocks] Regression net for the "model thinks but the app shows nothing" bug.
///
/// Every payload below is copied from a LIVE `api.mistral.ai` capture
/// (deepseek-v4-1-flash-1017, `reasoning_effort: "high"`, 2026-11-25) — not
/// written from the docs, because the shape is not what the docs imply:
/// a thinking block's payload is a NESTED block array under `thinking`, and a
/// single stream carries both string and array `content`.
final class ContentBlockSplitterTests: XCTestCase {

    // MARK: - The real shapes

    /// Non-streaming `message.content`, verbatim from the capture.
    func testMistralNonStreamingBlocks() {
        let content: [[String: Any]] = [
            ["type": "thinking",
             "thinking": [["type": "text", "text": "We need answer one sentence."]],
             "closed": true],
            ["type": "text", "text": "一个都不用，他们会先训练一个模型来预测灯泡该怎么换。"],
        ]
        let split = ContentBlockSplitter.split(content)
        XCTAssertEqual(split.thinking, "We need answer one sentence.")
        XCTAssertEqual(split.visible, "一个都不用，他们会先训练一个模型来预测灯泡该怎么换。")
    }

    /// Streaming `delta.content`, verbatim: first deltas are an empty STRING,
    /// then the shape switches to a block array.
    func testMistralStreamingBothShapesOnOneStream() {
        XCTAssertEqual(ContentBlockSplitter.split(""), ContentBlockSplitter.Split(recognised: true))

        let thinkingDelta: [[String: Any]] = [
            ["type": "thinking",
             "thinking": [["type": "text", "text": "We"]],
             "closed": false],
        ]
        let s1 = ContentBlockSplitter.split(thinkingDelta)
        XCTAssertEqual(s1.thinking, "We")
        XCTAssertEqual(s1.visible, "")

        let textDelta: [[String: Any]] = [["type": "text", "text": "电费。"]]
        let s2 = ContentBlockSplitter.split(textDelta)
        XCTAssertEqual(s2.thinking, "")
        XCTAssertEqual(s2.visible, "电费。")
    }

    /// Streaming thinking fragments must CONCATENATE across deltas — the
    /// fragment boundaries fall mid-word ("We" / " need answer one").
    func testStreamingFragmentsConcatenate() {
        var acc = ""
        for fragment in ["We", " need answer one", " sentence."] {
            let delta: [[String: Any]] = [
                ["type": "thinking",
                 "thinking": [["type": "text", "text": fragment]],
                 "closed": false],
            ]
            acc += ContentBlockSplitter.split(delta).thinking
        }
        XCTAssertEqual(acc, "We need answer one sentence.")
    }

    // MARK: - Compatibility: the shapes that already worked must not change

    func testPlainStringStillVisible() {
        let split = ContentBlockSplitter.split("hello")
        XCTAssertEqual(split.visible, "hello")
        XCTAssertEqual(split.thinking, "")
        XCTAssertTrue(split.recognised)
    }

    func testFlatThinkingSpellingsAccepted() {
        let reasoning: [[String: Any]] = [["type": "reasoning", "text": "think"]]
        XCTAssertEqual(ContentBlockSplitter.split(reasoning).thinking, "think")

        let flat: [[String: Any]] = [["type": "thinking", "text": "flat"]]
        XCTAssertEqual(ContentBlockSplitter.split(flat).thinking, "flat")
    }

    func testUnknownBlockNeverBecomesBodyText() {
        // A future vendor adding a block kind must not corrupt the reply.
        let blocks: [[String: Any]] = [
            ["type": "image_url", "image_url": ["url": "data:image/png;base64,AAAA"]],
            ["type": "text", "text": "ok"],
        ]
        let split = ContentBlockSplitter.split(blocks)
        XCTAssertEqual(split.visible, "ok")
        XCTAssertEqual(split.thinking, "")
    }

    func testGarbageInputIsNotRecognised() {
        XCTAssertFalse(ContentBlockSplitter.split(nil).recognised)
        XCTAssertFalse(ContentBlockSplitter.split(42).recognised)
    }

    // MARK: - The capability flag must beat the vendor prohibition

    private func ctx(level: ThinkingLevel, cap: Bool, mistral: Bool) -> ThinkingResolveContext {
        ThinkingResolveContext(
            modelId: "deepseek-v4-1-flash-1017", supportsReasoning: true,
            declaredEffortValues: nil,
            level: level, maxTokens: 8192,
            isOpenRouter: false, usesUnifiedReasoningEffort: false,
            isMistral: mistral, offEffort: nil, userRules: [],
            acceptsRootReasoningEffort: cap
        )
    }

    private func body(_ ctx: ThinkingResolveContext) -> [String: Any] {
        var b: [String: Any] = [:]
        _ = ThinkingRuleResolver.apply(to: &b, ctx: ctx)
        return b
    }

    /// The bug: Mistral's `omitEverything` rule silenced the endpoint.
    func testFlagSendsReasoningEffortDespiteMistralRule() {
        XCTAssertNil(body(ctx(level: .high, cap: false, mistral: true))["reasoning_effort"])
        XCTAssertEqual(body(ctx(level: .high, cap: true, mistral: true))["reasoning_effort"] as? String, "high")
    }

    /// Off must send NOTHING, never an invented off tier.
    func testFlagOffSendsNothing() {
        XCTAssertNil(body(ctx(level: .off, cap: true, mistral: true))["reasoning_effort"])
    }

    /// The three tiers the path is allowed to use.
    func testCapabilityEffortMapping() {
        XCTAssertNil(ThinkingRuleResolver.capabilityEffort(for: .off, declared: nil))
        XCTAssertEqual(ThinkingRuleResolver.capabilityEffort(for: .low, declared: nil), "low")
        XCTAssertEqual(ThinkingRuleResolver.capabilityEffort(for: .medium, declared: nil), "low")
        XCTAssertEqual(ThinkingRuleResolver.capabilityEffort(for: .high, declared: nil), "high")
        XCTAssertEqual(ThinkingRuleResolver.capabilityEffort(for: .max, declared: nil), "max")
        // Declared sets win; an undeclared max must not be invented.
        XCTAssertEqual(ThinkingRuleResolver.capabilityEffort(for: .max, declared: ["low", "high"]), "high")
        XCTAssertNil(ThinkingRuleResolver.capabilityEffort(for: .xhigh, declared: ["low", "medium"]))
    }
}