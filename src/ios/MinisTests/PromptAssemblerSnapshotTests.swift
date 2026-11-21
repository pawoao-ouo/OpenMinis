import XCTest
@testable import Minis

/// GOLDEN SNAPSHOT of `PromptAssembler.assemble` (Phase 0, token plan ch. 8).
///
/// WHY THIS EXISTS: the plan requires prompt assembly to converge on a single
/// builder with a per-section ledger. `buildTurnSystemPrompt` computes each
/// fragment as before and hands the ordered sections to this assembler — the
/// assembler is the ONLY place that joins them. These tests pin the join
/// contract (order + separators), so a future refactor cannot silently change
/// what the model sees or what the ledger counts.
///
/// WHAT IT DOES NOT PIN: the full builder output. The ambient fragment embeds
/// wall-clock time, so two calls to `buildTurnSystemPrompt` are never
/// byte-identical by design. The pinned seam is the assembler; the builder's
/// gates (which fragments are appended, in which order) are verified by
/// reading `buildTurnSystemPrompt`, not by this file.
///
/// HOW TO USE: if a change here goes red, it is a behaviour change — either
/// an unintended regression in join order/separators, or an intended change
/// that must be called out explicitly in the commit message and updated
/// deliberately. Do NOT regenerate the golden string to make a red test
/// green without first explaining, in words, why the prompt legitimately
/// changed.
final class PromptAssemblerSnapshotTests: XCTestCase {

    // MARK: - Fixture

    /// Mirrors the builder's real shapes: "\n\n"-separated fragments, one
    /// fragment that carries its own leading newline (memoryStatusFragment),
    /// and one raw empty fragment (evolution injector when off).
    private var fixtureSections: [PromptSection] {
        [
            PromptSection(kind: .system, name: "capability", separator: "\n\n", text: "CAP"),
            PromptSection(kind: .skills, name: "skills", separator: "\n\n", text: "SKILL-A\nSKILL-B"),
            PromptSection(kind: .memory, name: "memory-global", separator: "\n\n", text: "MEM"),
            PromptSection(kind: .system, name: "memory-status", separator: "", text: "\n\nSTATUS"),
            PromptSection(kind: .system, name: "evolution", separator: "", text: ""),
        ]
    }

    /// Hand-computed join of the fixture above. If you change the fixture,
    /// recompute this by hand — never copy it from a failing run.
    private let golden = "BASE\n\nCAP\n\nSKILL-A\nSKILL-B\n\nMEM\n\nSTATUS"

    // MARK: - Assembly

    func testGoldenAssembly() {
        XCTAssertEqual(
            PromptAssembler.assemble(base: "BASE", sections: fixtureSections),
            golden
        )
    }

    func testDeterminism() {
        let first = PromptAssembler.assemble(base: "BASE", sections: fixtureSections)
        let second = PromptAssembler.assemble(base: "BASE", sections: fixtureSections)
        XCTAssertEqual(first, second)
    }

    func testOrderMatters() {
        let swapped = Array(fixtureSections.reversed())
        XCTAssertNotEqual(
            PromptAssembler.assemble(base: "BASE", sections: swapped),
            golden
        )
    }

    func testEmptySections() {
        // No sections at all: the prompt is exactly the base.
        XCTAssertEqual(PromptAssembler.assemble(base: "BASE", sections: []), "BASE")
        // An empty fragment appended raw contributes nothing (the evolution
        // case); an empty fragment with a "\n\n" separator would inject a
        // stray blank line — callers must never append one, and this
        // assertion documents that contract.
        let rawEmpty = PromptAssembler.assemble(base: "BASE", sections: [
            PromptSection(kind: .system, name: "evolution", separator: "", text: "")
        ])
        XCTAssertEqual(rawEmpty, "BASE")
    }

    // MARK: - Section kinds

    func testSectionKindsAreExactlyTheSheetSections() {
        // The usage sheet has exactly these seven rows (plan ch. 2 / ch. 8).
        // A new kind without a sheet row would silently vanish from the
        // breakdown; a removed kind would leave a dead row.
        XCTAssertEqual(
            Set(PromptSectionKind.allCases.map(\.rawValue)),
            ["system", "tools", "skills", "memory", "history", "thinking", "protocolEnvironment"]
        )
    }

    func testSheetLabelsAreUnique() {
        let labels = PromptSectionKind.allCases.map(\.sheetLabel)
        XCTAssertEqual(Set(labels).count, labels.count)
    }
}
