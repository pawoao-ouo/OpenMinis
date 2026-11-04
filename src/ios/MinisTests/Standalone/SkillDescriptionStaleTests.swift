// Regression test for GH#215 + T-skill-description-stuck-forever —
// SkillStore.loadSkills() stale-description rule.
//
// Mirrors the exact predicate from SkillStore.swift (the `descStale` line in
// loadSkills) and the parse-failure sentinel from rescanFromDisk
// (`parseFailed`). Standalone because the MinisTests target has a pre-existing
// compile break (ToolPreflightTests / AgentToolDefinition), so `xcodebuild
// test` cannot run today.

import Foundation

let defaultSkillName = "Untitled Skill"

/// The predicate under test — copied verbatim from the fix.
///
/// A DB description is stale whenever the file says something different.
/// `parsedOK` is the a720585db guard: a failed parse yields exactly
/// name == defaultSkillName && description == "", and must never overwrite
/// stored metadata.
func descStale(dbDescription: String, parsedDescription: String,
               parsedName: String = "Real Skill") -> Bool {
    let parsedOK = !(parsedName == defaultSkillName && parsedDescription.isEmpty)
    let fileDesc = parsedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
    return parsedOK && !fileDesc.isEmpty
        && fileDesc != dbDescription.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// The parse-failure sentinel a720585db relies on.
func parseFailed(parsedName: String, parsedDescription: String) -> Bool {
    parsedName == defaultSkillName && parsedDescription.isEmpty
}

var failures = 0
func check(_ label: String, _ actual: Bool, _ expected: Bool) {
    if actual == expected {
        print("  ✅ \(label)")
    } else {
        print("  ❌ \(label) — expected \(expected), got \(actual)")
        failures += 1
    }
}

print("GH#215 — empty DB description must be treated as stale")
// The reported bug: shell-created skill registered before `description:` existed.
check("empty DB + real file desc → REFRESH", descStale(dbDescription: "", parsedDescription: "Fetch a web page"), true)

print("\nT-skill-description-stuck-forever — a rotted non-empty description must refresh too")
// The reported bug: SKILL.md edited on disk after import; DB kept the old
// sentence forever, and that old sentence is what got injected into
// <available_skills>.
check("old DB desc + different file desc → REFRESH",
      descStale(dbDescription: "小手机全仓库审计方法论", parsedDescription: "通用项目审计方法论"), true)
check("same desc on both sides → KEEP (no churn)",
      descStale(dbDescription: "Same text", parsedDescription: "Same text"), false)

print("\nPre-existing behaviour must be preserved (block-scalar indicators)")
check("\"|\" + real file desc → REFRESH", descStale(dbDescription: "|", parsedDescription: "Real"), true)
check("\">\" + real file desc → REFRESH", descStale(dbDescription: ">", parsedDescription: "Real"), true)

print("\nSafety: a mid-edit / malformed SKILL.md must NEVER wipe good metadata (a720585db)")
// A failed parse yields name=="Untitled Skill" && description=="".
check("good DB + parse failure → KEEP", descStale(dbDescription: "Fetch a web page", parsedDescription: ""), false)
check("empty DB + parse failure → KEEP (nothing to write)", descStale(dbDescription: "", parsedDescription: ""), false)
check("\"|\" DB + parse failure → KEEP", descStale(dbDescription: "|", parsedDescription: ""), false)
// Cross-check the sentinel itself so the guarantee is explicit.
check("parse failure sentinel holds", parseFailed(parsedName: defaultSkillName, parsedDescription: ""), true)
// The sentinel must require BOTH halves: the default name alone is not a
// failed parse (a real skill may legitimately be called that), and an empty
// description alone is already covered by the non-empty guard.
check("default name alone is not a parse failure",
      parseFailed(parsedName: defaultSkillName, parsedDescription: "Real"), false)
check("empty description alone is not a parse failure",
      parseFailed(parsedName: "Real Skill", parsedDescription: ""), false)

print("\nScope: the description column has no independent editor, so the file wins")
// No free-text description editor exists in the UI (the detail screen renders
// the body read-only); every writer is the SKILL.md parse. A DB/file
// disagreement is therefore stale data, not an override. This case flipped
// from KEEP to REFRESH on purpose in T-skill-description-stuck-forever — the
// old expectation is exactly what kept six skills frozen on stale text.
check("user desc + different file desc → REFRESH (file wins)",
      descStale(dbDescription: "My own wording", parsedDescription: "Upstream wording"), true)
check("user desc + same file desc → KEEP", descStale(dbDescription: "Same", parsedDescription: "Same"), false)

print("\nEdge cases")
check("whitespace-only DB desc + real file desc → REFRESH",
      descStale(dbDescription: " ", parsedDescription: "Real"), true)
check("empty DB + whitespace-only file desc → KEEP (nothing useful to adopt)",
      descStale(dbDescription: "", parsedDescription: " "), false)
check("empty DB + empty file desc → KEEP", descStale(dbDescription: "", parsedDescription: ""), false)

print("")
if failures == 0 {
    print("ALL PASS")
    exit(0)
} else {
    print("\(failures) FAILURE(S)")
    exit(1)
}
