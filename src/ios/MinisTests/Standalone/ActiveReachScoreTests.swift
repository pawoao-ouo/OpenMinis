// Standalone (`swift ActiveReachScoreTests.swift`).
// Pins timeScore, pickDialog, parseModelJSON, capDecision, windowTurns.

import Foundation

var failures = 0
func check(_ label: String, _ actual: Bool, _ expected: Bool = true) {
    if actual == expected { print("  OK \(label)") }
    else { print("  FAIL \(label) — expected \(expected), got \(actual)"); failures += 1 }
}
func checkEq<T: Equatable>(_ label: String, _ actual: T, _ expected: T) {
    if actual == expected { print("  OK \(label)") }
    else { print("  FAIL \(label) — expected \(expected), got \(actual)"); failures += 1 }
}

struct ActiveReachSnapshot {
    var enabled: Bool
    var dailyCap: Int
    var dailyBreakCap: Int
    var modelId: String
    var dialogIds: [String]
    var quietTimeoutMinutes: Int
    var dialogActiveHours: Int
    var scoreThreshold: Int = 60
    var dailyCapCount: Int
    var dailyBreakCount: Int
}

struct ActiveReachTurn {
    var role: String
    var text: String
    var date: Date
}

struct TimeScoreResult: Equatable {
    var score: Int
    var timedOut: Bool
    var noPeerTimestamp: Bool
    var minutes: Int?
}

struct DialogPick {
    var id: String
    var note: String?
}

struct ModelScorePayload {
    var emotionScore: Int
    var wantSend: Bool
    var text: String
    var reason: String
}

struct CapDecision {
    var shouldDraft: Bool
    var wouldConsumeCap: Bool
    var wouldBreak: Bool
    var reason: String?
}

enum ActiveReachScore {
    static let peerQuietFloorMinutes = 30
    static let timeScoreCap = 120
    static let scoreThreshold = 60
    static let maxTurns = 10
    static let sinceHours = 24
    static let maxChars = 6000
    static let draftLimit = 20

    static func timeScore(
        lastPeerMessageAt: Date?,
        now: Date,
        quietTimeoutMinutes: Int
    ) -> TimeScoreResult {
        guard let last = lastPeerMessageAt else {
            return TimeScoreResult(
                score: timeScoreCap, timedOut: true, noPeerTimestamp: true, minutes: nil)
        }
        let minutes = max(0, Int(now.timeIntervalSince(last) / 60.0))
        let high = max(quietTimeoutMinutes, peerQuietFloorMinutes)
        if minutes < peerQuietFloorMinutes {
            return TimeScoreResult(
                score: 0, timedOut: false, noPeerTimestamp: false, minutes: minutes)
        }
        if minutes > high {
            return TimeScoreResult(
                score: timeScoreCap, timedOut: true, noPeerTimestamp: false, minutes: minutes)
        }
        if high == peerQuietFloorMinutes {
            return TimeScoreResult(
                score: timeScoreCap, timedOut: false, noPeerTimestamp: false, minutes: minutes)
        }
        let t = Double(minutes - peerQuietFloorMinutes) / Double(high - peerQuietFloorMinutes)
        let mapped = 30.0 + t * Double(timeScoreCap - 30)
        return TimeScoreResult(
            score: Int(mapped.rounded()),
            timedOut: false,
            noPeerTimestamp: false,
            minutes: minutes
        )
    }

    static func pickDialog(
        ids: [String],
        lastActive: [String: Date],
        now: Date,
        activeHours: Int
    ) -> Result<DialogPick, String> {
        let window = TimeInterval(max(activeHours, 1) * 3600)
        var fresh: [(String, Date)] = []
        var noMeta: [String] = []
        for id in ids {
            if let at = lastActive[id] {
                if now.timeIntervalSince(at) <= window {
                    fresh.append((id, at))
                }
            } else {
                noMeta.append(id)
            }
        }
        if let best = fresh.max(by: { $0.1 < $1.1 }) {
            return .success(DialogPick(id: best.0, note: nil))
        }
        if let first = noMeta.first {
            return .success(DialogPick(id: first, note: "pickFallbackFirst"))
        }
        return .failure("noActiveDialog")
    }

    static func parseModelJSON(_ raw: String) -> ModelScorePayload? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") {
            if let nl = s.firstIndex(of: "\n") {
                s = String(s[s.index(after: nl)...])
            }
            if let fence = s.range(of: "```") {
                s = String(s[..<fence.lowerBound])
            }
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let data = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        guard let emotion = intValue(obj["emotionScore"] ?? obj["emotion_score"]),
              (0...100).contains(emotion)
        else { return nil }
        guard let want = boolValue(obj["wantSend"] ?? obj["want_send"]) else { return nil }
        let text = stringValue(obj["text"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let reason = stringValue(obj["reason"]) ?? ""
        return ModelScorePayload(emotionScore: emotion, wantSend: want, text: text, reason: reason)
    }

    static func capDecision(
        snapshot: ActiveReachSnapshot,
        timedOut: Bool,
        emotionScore: Int,
        wantSend: Bool,
        total: Int,
        threshold: Int? = nil
    ) -> CapDecision {
        let threshold = threshold ?? snapshot.scoreThreshold
        if !wantSend {
            return CapDecision(
                shouldDraft: false, wouldConsumeCap: false, wouldBreak: false,
                reason: "modelDeclined")
        }
        if total < threshold {
            return CapDecision(
                shouldDraft: false, wouldConsumeCap: false, wouldBreak: false,
                reason: "belowThreshold")
        }
        if snapshot.dailyCapCount < snapshot.dailyCap {
            return CapDecision(
                shouldDraft: true, wouldConsumeCap: true, wouldBreak: false, reason: nil)
        }
        let strong = timedOut || emotionScore >= 80
        if strong && snapshot.dailyBreakCount < snapshot.dailyBreakCap {
            return CapDecision(
                shouldDraft: true, wouldConsumeCap: false, wouldBreak: true, reason: nil)
        }
        return CapDecision(
            shouldDraft: false, wouldConsumeCap: false, wouldBreak: false,
            reason: "capExhausted")
    }

    static func windowTurns(
        _ turns: [ActiveReachTurn],
        now: Date,
        maxCount: Int = maxTurns,
        hours: Int = sinceHours,
        maxChars: Int = maxChars
    ) -> [ActiveReachTurn] {
        let since = now.addingTimeInterval(TimeInterval(-hours * 3600))
        let inWindow = turns.filter { $0.date >= since }
        let clipped = Array(inWindow.suffix(maxCount))
        var kept: [ActiveReachTurn] = []
        var count = 0
        for turn in clipped.reversed() {
            let n = turn.text.count
            if count + n > maxChars && !kept.isEmpty { break }
            if n > maxChars && kept.isEmpty {
                let trimmed = String(turn.text.suffix(maxChars))
                kept.append(ActiveReachTurn(role: turn.role, text: trimmed, date: turn.date))
                break
            }
            kept.append(turn)
            count += n
        }
        return kept.reversed()
    }

    private static func intValue(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let d = any as? Double { return Int(d.rounded()) }
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String { return Int(s) }
        return nil
    }

    private static func boolValue(_ any: Any?) -> Bool? {
        if let b = any as? Bool { return b }
        if let n = any as? NSNumber { return n.boolValue }
        if let s = any as? String {
            let t = s.lowercased()
            if t == "true" || t == "1" { return true }
            if t == "false" || t == "0" { return false }
        }
        return nil
    }

    private static func stringValue(_ any: Any?) -> String? { any as? String }
}

func utcDate(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0) -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(secondsFromGMT: 0)!
    var parts = DateComponents()
    parts.year = y; parts.month = m; parts.day = d; parts.hour = h; parts.minute = min
    return cal.date(from: parts)!
}

let now = utcDate(2026, 9, 5, 12, 0)

print("timeScore")
let t0 = ActiveReachScore.timeScore(
    lastPeerMessageAt: now.addingTimeInterval(-10 * 60), now: now, quietTimeoutMinutes: 120)
checkEq("under 30 is 0", t0.score, 0)
check("not timedOut", t0.timedOut == false)

let mid = ActiveReachScore.timeScore(
    lastPeerMessageAt: now.addingTimeInterval(-75 * 60), now: now, quietTimeoutMinutes: 120)
checkEq("75 min maps to 75", mid.score, 75)
check("mid not timedOut", mid.timedOut == false)

let cap = ActiveReachScore.timeScore(
    lastPeerMessageAt: now.addingTimeInterval(-200 * 60), now: now, quietTimeoutMinutes: 120)
checkEq("over 120 caps", cap.score, 120)
check("timedOut", cap.timedOut)

let nilTs = ActiveReachScore.timeScore(
    lastPeerMessageAt: nil, now: now, quietTimeoutMinutes: 120)
checkEq("nil timestamp caps", nilTs.score, 120)
check("noPeerTimestamp", nilTs.noPeerTimestamp)
check("nil timedOut", nilTs.timedOut)

print("\npickDialog")
switch ActiveReachScore.pickDialog(
    ids: ["A", "B"],
    lastActive: ["A": now.addingTimeInterval(-48 * 3600), "B": now.addingTimeInterval(-49 * 3600)],
    now: now, activeHours: 24
) {
case .failure(let r): checkEq("all stale", r, "noActiveDialog")
case .success: check("all stale", false)
}
switch ActiveReachScore.pickDialog(
    ids: ["A", "B"], lastActive: [:], now: now, activeHours: 24
) {
case .success(let p):
    checkEq("fallback first", p.id, "A")
    checkEq("fallback note", p.note, "pickFallbackFirst")
case .failure: check("fallback", false)
}
switch ActiveReachScore.pickDialog(
    ids: ["A", "B"],
    lastActive: ["A": now.addingTimeInterval(-2 * 3600), "B": now.addingTimeInterval(-10 * 60)],
    now: now, activeHours: 24
) {
case .success(let p): checkEq("newest active", p.id, "B")
case .failure: check("newest active", false)
}

print("\nparseModelJSON")
check("garbage is parseFailed", ActiveReachScore.parseModelJSON("not json") == nil)
check("missing fields fail", ActiveReachScore.parseModelJSON("{\"foo\":1}") == nil)
let ok = ActiveReachScore.parseModelJSON(
    "{\"emotionScore\":40,\"wantSend\":true,\"text\":\"想你\",\"reason\":\"miss\"}")
checkEq("emotion", ok?.emotionScore, 40)
checkEq("text", ok?.text, "想你")
let fenced = ActiveReachScore.parseModelJSON(
    "```json\n{\"emotionScore\":10,\"wantSend\":false,\"text\":\"x\",\"reason\":\"n\"}\n```")
checkEq("fence", fenced?.wantSend, false)

print("\ncapDecision")
var snap = ActiveReachSnapshot(
    enabled: true, dailyCap: 3, dailyBreakCap: 1, modelId: "m",
    dialogIds: ["A"], quietTimeoutMinutes: 120, dialogActiveHours: 24,
    dailyCapCount: 0, dailyBreakCount: 0)
var capD = ActiveReachScore.capDecision(
    snapshot: snap, timedOut: false, emotionScore: 40, wantSend: true, total: 115)
check("draft consumes cap", capD.shouldDraft && capD.wouldConsumeCap && !capD.wouldBreak)
capD = ActiveReachScore.capDecision(
    snapshot: snap, timedOut: false, emotionScore: 10, wantSend: false, total: 130)
checkEq("modelDeclined", capD.reason, "modelDeclined")
capD = ActiveReachScore.capDecision(
    snapshot: snap, timedOut: false, emotionScore: 10, wantSend: true, total: 20)
checkEq("belowThreshold", capD.reason, "belowThreshold")
snap.dailyCapCount = 3
capD = ActiveReachScore.capDecision(
    snapshot: snap, timedOut: true, emotionScore: 50, wantSend: true, total: 170)
check("wouldBreak on timeout", capD.shouldDraft && capD.wouldBreak)
snap.dailyBreakCount = 1
capD = ActiveReachScore.capDecision(
    snapshot: snap, timedOut: true, emotionScore: 90, wantSend: true, total: 210)
checkEq("capExhausted", capD.reason, "capExhausted")

print("\nnoModel / noActiveDialog / modelFailed / parseFailed")
func gate(modelId: String, dialogs: [String], lastActive: [String: Date], callFailed: Bool, raw: String?) -> String {
    if modelId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "noModel" }
    switch ActiveReachScore.pickDialog(ids: dialogs, lastActive: lastActive, now: now, activeHours: 24) {
    case .failure(let r): return r
    case .success:
        if callFailed { return "modelFailed" }
        if let raw, ActiveReachScore.parseModelJSON(raw) == nil { return "parseFailed" }
        return "ok"
    }
}
checkEq("noModel", gate(modelId: "", dialogs: ["A"], lastActive: [:], callFailed: false, raw: nil), "noModel")
checkEq("noActiveDialog", gate(
    modelId: "m", dialogs: ["A"],
    lastActive: ["A": now.addingTimeInterval(-100 * 3600)], callFailed: false, raw: nil), "noActiveDialog")
checkEq("modelFailed", gate(
    modelId: "m", dialogs: ["A"], lastActive: [:], callFailed: true, raw: nil), "modelFailed")
checkEq("parseFailed", gate(
    modelId: "m", dialogs: ["A"], lastActive: [:], callFailed: false, raw: "nope"), "parseFailed")

print("\ncapDecision uses snapshot threshold")
var threshSnap = ActiveReachSnapshot(
    enabled: true, dailyCap: 3, dailyBreakCap: 1, modelId: "m",
    dialogIds: ["A"], quietTimeoutMinutes: 120, dialogActiveHours: 24,
    scoreThreshold: 200, dailyCapCount: 0, dailyBreakCount: 0)
var threshCap = ActiveReachScore.capDecision(
    snapshot: threshSnap, timedOut: false, emotionScore: 40, wantSend: true, total: 115)
checkEq("custom 200 blocks 115", threshCap.reason, "belowThreshold")
threshSnap.scoreThreshold = 60
threshCap = ActiveReachScore.capDecision(
    snapshot: threshSnap, timedOut: false, emotionScore: 40, wantSend: true, total: 115)
check("custom 60 allows 115", threshCap.shouldDraft)

print("\nshipping")
let here = URL(fileURLWithPath: #filePath)
let shipping = here.deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("Shared/ActiveReachScore.swift")
let source = (try? String(contentsOfFile: shipping.path, encoding: .utf8)) ?? ""
check("shipping exists", !source.isEmpty)
check("timeScore", source.contains("func timeScore"))
check("pickDialog", source.contains("func pickDialog"))
check("noModel", source.contains("noModel"))
check("noActiveDialog", source.contains("noActiveDialog"))
check("parseFailed", source.contains("parseFailed"))
check("modelFailed", source.contains("modelFailed"))
check("draftLimit 20", source.contains("draftLimit = 20"))
check("reads snapshot threshold", source.contains("threshold: snapshot.scoreThreshold"))
check("ModelUseOffloadBridge", source.contains("ModelUseOffloadBridge.runModel"))
check("ChatStore.loadMessages", source.contains("loadMessages(sessionId"))
check("no notify", !source.contains("UNUserNotificationCenter") && !source.contains("apple-notification"))
check("no BGTask", !source.contains("BGTaskScheduler"))
check("no hardcoded URL key", !source.contains("sk-") && !source.contains("https://api.openai.com"))

if failures == 0 {
    print("\nALL PASS")
    exit(0)
} else {
    print("\nFAILED \(failures)")
    exit(1)
}
