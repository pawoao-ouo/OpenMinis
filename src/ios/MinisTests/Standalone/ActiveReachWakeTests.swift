// Standalone (`swift ActiveReachWakeTests.swift`).
// Pins handleWake intercept order: masterOff, noDialogs, allowed.
// Also pins ring log limit and canSend / canProceedToScore.

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

struct ActiveReachSnapshot: Equatable, Codable {
    var enabled: Bool
    var intervalMinutes: Int
    var dailyCap: Int
    var dailyBreakCap: Int
    var modelId: String
    var dialogIds: [String]
    var quietTimeoutMinutes: Int
    var dialogActiveHours: Int
    var dailyCapCount: Int
    var dailyBreakCount: Int
    var countsDate: String

    static let `default` = ActiveReachSnapshot(
        enabled: false, intervalMinutes: 60, dailyCap: 3, dailyBreakCap: 1,
        modelId: "", dialogIds: [], quietTimeoutMinutes: 120, dialogActiveHours: 24,
        dailyCapCount: 0, dailyBreakCount: 0, countsDate: ""
    )
}

enum ActiveReachLogic {
    static func dayStamp(now: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: now)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func resetCountsIfNeeded(
        _ snapshot: inout ActiveReachSnapshot,
        now: Date,
        calendar: Calendar = .current
    ) {
        let today = dayStamp(now: now, calendar: calendar)
        if snapshot.countsDate != today {
            snapshot.dailyCapCount = 0
            snapshot.dailyBreakCount = 0
            snapshot.countsDate = today
        }
    }

    static func shouldAllowWake(_ snapshot: ActiveReachSnapshot) -> Bool {
        snapshot.enabled
    }
}

enum WakeBlockReason: String, Equatable, Codable {
    case masterOff
    case noDialogs
}

struct WakeContext: Equatable {
    var snapshot: ActiveReachSnapshot
    var source: String
    var now: Date
}

enum WakeDisposition: Equatable {
    case blocked(reason: WakeBlockReason)
    case allowed(context: WakeContext)
}

struct ActiveReachDecision: Equatable, Codable, Identifiable {
    var id: String
    var time: TimeInterval
    var source: String
    var disposition: String
    var reason: String?
    var enabled: Bool
    var dialogCount: Int
    var capCount: Int
    var breakCount: Int
}

enum ActiveReachWake {
    static let decisionLogKey = "activeReach.decisions.v1"
    static let decisionLogLimit = 50

    static func shouldAllowWake(_ snapshot: ActiveReachSnapshot) -> Bool {
        ActiveReachLogic.shouldAllowWake(snapshot)
    }

    static func canProceedToScore(_ snapshot: ActiveReachSnapshot) -> Bool {
        canSend(snapshot)
    }

    static func canSend(_ snapshot: ActiveReachSnapshot) -> Bool {
        snapshot.enabled && !snapshot.dialogIds.isEmpty
    }

    static func evaluate(
        snapshot: ActiveReachSnapshot,
        source: String,
        now: Date
    ) -> WakeDisposition {
        if !shouldAllowWake(snapshot) {
            return .blocked(reason: .masterOff)
        }
        if snapshot.dialogIds.isEmpty {
            return .blocked(reason: .noDialogs)
        }
        return .allowed(context: WakeContext(snapshot: snapshot, source: source, now: now))
    }

    static func handleWake(
        snapshot: inout ActiveReachSnapshot,
        log: inout [ActiveReachDecision],
        source: String,
        now: Date,
        calendar: Calendar = .current
    ) -> WakeDisposition {
        ActiveReachLogic.resetCountsIfNeeded(&snapshot, now: now, calendar: calendar)
        let disposition = evaluate(snapshot: snapshot, source: source, now: now)
        if case .blocked = disposition {
            let entry = ActiveReachDecision.make(
                disposition: disposition, snapshot: snapshot, source: source, now: now)
            log = prepend(entry, onto: log)
        }
        return disposition
    }

    static func prepend(
        _ entry: ActiveReachDecision,
        onto log: [ActiveReachDecision],
        limit: Int = decisionLogLimit
    ) -> [ActiveReachDecision] {
        Array(([entry] + log).prefix(limit))
    }
}

extension ActiveReachDecision {
    static func make(
        disposition: WakeDisposition,
        snapshot: ActiveReachSnapshot,
        source: String,
        now: Date
    ) -> ActiveReachDecision {
        let kind: String
        let reason: String?
        switch disposition {
        case .blocked(let block):
            kind = "blocked"; reason = block.rawValue
        case .allowed:
            kind = "allowed"; reason = nil
        }
        return ActiveReachDecision(
            id: UUID().uuidString, time: now.timeIntervalSince1970, source: source,
            disposition: kind, reason: reason, enabled: snapshot.enabled,
            dialogCount: snapshot.dialogIds.count,
            capCount: snapshot.dailyCapCount, breakCount: snapshot.dailyBreakCount
        )
    }
}

func utcCalendar() -> Calendar {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(secondsFromGMT: 0)!
    return cal
}

func utcDate(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
    var parts = DateComponents()
    parts.year = y; parts.month = m; parts.day = d; parts.hour = h
    return utcCalendar().date(from: parts)!
}

let cal = utcCalendar()
let now = utcDate(2026, 9, 5)

print("masterOff")
var off = ActiveReachSnapshot.default
var log: [ActiveReachDecision] = []
var d = ActiveReachWake.handleWake(snapshot: &off, log: &log, source: "test", now: now, calendar: cal)
check("blocked masterOff", {
    if case .blocked(.masterOff) = d { return true }
    return false
}())
check("logged blocked", log.count == 1 && log[0].disposition == "blocked" && log[0].reason == "masterOff")
check("canSend false when off", ActiveReachWake.canSend(off) == false)
check("canProceed false when off", ActiveReachWake.canProceedToScore(off) == false)

print("\nnoDialogs")
var gated = ActiveReachSnapshot.default
gated.enabled = true
log = []
d = ActiveReachWake.handleWake(snapshot: &gated, log: &log, source: "test", now: now, calendar: cal)
check("blocked noDialogs", {
    if case .blocked(.noDialogs) = d { return true }
    return false
}())
check("logged noDialogs", log[0].reason == "noDialogs")
check("canSend false empty dialogs", ActiveReachWake.canSend(gated) == false)

print("\nmasterOff beats empty dialogs")
var both = ActiveReachSnapshot.default
both.enabled = false
both.dialogIds = []
log = []
d = ActiveReachWake.handleWake(snapshot: &both, log: &log, source: "test", now: now, calendar: cal)
check("off wins over empty", {
    if case .blocked(.masterOff) = d { return true }
    return false
}())

print("\nallowed")
var on = ActiveReachSnapshot.default
on.enabled = true
on.dialogIds = ["SID-1"]
on.dailyCapCount = 2
on.countsDate = "2026-09-05"
log = []
d = ActiveReachWake.handleWake(snapshot: &on, log: &log, source: "intent", now: now, calendar: cal)
check("allowed", {
    if case .allowed(let ctx) = d {
        return ctx.source == "intent" && ctx.snapshot.dialogIds == ["SID-1"]
    }
    return false
}())
check("allowed does not log yet", log.isEmpty)
check("canSend true", ActiveReachWake.canSend(on))
check("canProceed true", ActiveReachWake.canProceedToScore(on))

print("\ncross-day reset before gate")
var stale = ActiveReachSnapshot.default
stale.enabled = true
stale.dialogIds = ["SID-1"]
stale.dailyCapCount = 3
stale.dailyBreakCount = 1
stale.countsDate = "2026-09-04"
log = []
_ = ActiveReachWake.handleWake(snapshot: &stale, log: &log, source: "test", now: now, calendar: cal)
checkEq("cap reset before allow", stale.dailyCapCount, 0)
checkEq("break reset", stale.dailyBreakCount, 0)
check("allowed still no log", log.isEmpty)

print("\nring limit")
var ringSnap = ActiveReachSnapshot.default
var ring: [ActiveReachDecision] = []
for i in 0..<55 {
    _ = ActiveReachWake.handleWake(
        snapshot: &ringSnap, log: &ring, source: "s\(i)", now: now, calendar: cal)
}
checkEq("limit 50", ring.count, 50)
checkEq("newest first", ring[0].source, "s54")
checkEq("oldest kept is s5", ring[49].source, "s5")

print("\nshipping agreement")
let here = URL(fileURLWithPath: #filePath)
let shipping = here.deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("Shared/ActiveReachWake.swift")
let source = (try? String(contentsOfFile: shipping.path, encoding: .utf8)) ?? ""
check("shipping exists", !source.isEmpty)
check("handleWake", source.contains("func handleWake"))
check("canSend", source.contains("func canSend"))
check("canProceedToScore", source.contains("func canProceedToScore"))
check("masterOff", source.contains("masterOff"))
check("noDialogs", source.contains("noDialogs"))
check("limit 50", source.contains("decisionLogLimit = 50"))
check("no LLM", !source.contains("URLSession") && !source.contains("chat/completions"))
check("no notify", !source.contains("UNUserNotificationCenter") && !source.contains("apple-notification"))
check("no BGTask", !source.contains("BGTaskScheduler"))

if failures == 0 {
    print("\nALL PASS")
    exit(0)
} else {
    print("\nFAILED \(failures)")
    exit(1)
}
