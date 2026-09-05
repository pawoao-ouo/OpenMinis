// Standalone (`swift ActiveReachSendTests.swift`).
// Pins prepareSend / applyCount: masterOff, cap, break, failure does not count.

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
    var dailyCapCount: Int
    var dailyBreakCount: Int
    var countsDate: String
}

struct ActiveReachDraft {
    var id: String
    var text: String
    var wouldBreak: Bool
}

enum ActiveReachSendError: String, Error {
    case masterOff, capExhausted, emptyText
}

enum ActiveReachLogic {
    static func dayStamp(now: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: now)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
    static func resetCountsIfNeeded(
        _ snapshot: inout ActiveReachSnapshot, now: Date, calendar: Calendar = .current
    ) {
        let today = dayStamp(now: now, calendar: calendar)
        if snapshot.countsDate != today {
            snapshot.dailyCapCount = 0
            snapshot.dailyBreakCount = 0
            snapshot.countsDate = today
        }
    }
}

enum ActiveReachSend {
    static let idPrefix = "active-reach."

    static func prepareSend(
        draft: ActiveReachDraft,
        snapshot: inout ActiveReachSnapshot,
        now: Date,
        calendar: Calendar = .current
    ) -> Result<Bool, ActiveReachSendError> {
        guard snapshot.enabled else { return .failure(.masterOff) }
        ActiveReachLogic.resetCountsIfNeeded(&snapshot, now: now, calendar: calendar)
        let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .failure(.emptyText) }
        if draft.wouldBreak {
            guard snapshot.dailyBreakCount < snapshot.dailyBreakCap else {
                return .failure(.capExhausted)
            }
            return .success(true)
        }
        guard snapshot.dailyCapCount < snapshot.dailyCap else {
            return .failure(.capExhausted)
        }
        return .success(false)
    }

    static func applyCount(usedBreak: Bool, snapshot: inout ActiveReachSnapshot) {
        if usedBreak { snapshot.dailyBreakCount += 1 }
        else { snapshot.dailyCapCount += 1 }
    }

    static func notificationId(for draftId: String) -> String { idPrefix + draftId }
    static func isOurs(_ identifier: String) -> Bool { identifier.hasPrefix(idPrefix) }
}

func utcCalendar() -> Calendar {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(secondsFromGMT: 0)!
    return cal
}
func utcDate(_ y: Int, _ m: Int, _ d: Int) -> Date {
    var p = DateComponents(); p.year = y; p.month = m; p.day = d; p.hour = 12
    return utcCalendar().date(from: p)!
}

let now = utcDate(2026, 9, 6)
let cal = utcCalendar()
let draft = ActiveReachDraft(id: "d1", text: "想你", wouldBreak: false)
let brk = ActiveReachDraft(id: "d2", text: "破例一句", wouldBreak: true)

print("masterOff")
var off = ActiveReachSnapshot(
    enabled: false, dailyCap: 3, dailyBreakCap: 1,
    dailyCapCount: 0, dailyBreakCount: 0, countsDate: "2026-09-06")
switch ActiveReachSend.prepareSend(draft: draft, snapshot: &off, now: now, calendar: cal) {
case .failure(let e): checkEq("masterOff", e, .masterOff)
case .success: check("masterOff", false)
}
checkEq("off did not consume", off.dailyCapCount, 0)

print("\ncap success then apply")
var on = ActiveReachSnapshot(
    enabled: true, dailyCap: 3, dailyBreakCap: 1,
    dailyCapCount: 0, dailyBreakCount: 0, countsDate: "2026-09-06")
switch ActiveReachSend.prepareSend(draft: draft, snapshot: &on, now: now, calendar: cal) {
case .success(let usedBreak):
    check("cap path", usedBreak == false)
    ActiveReachSend.applyCount(usedBreak: usedBreak, snapshot: &on)
    checkEq("cap +1", on.dailyCapCount, 1)
    checkEq("break untouched", on.dailyBreakCount, 0)
case .failure: check("cap path", false)
}

print("\nprepare does not count until apply")
var held = ActiveReachSnapshot(
    enabled: true, dailyCap: 3, dailyBreakCap: 1,
    dailyCapCount: 2, dailyBreakCount: 0, countsDate: "2026-09-06")
_ = ActiveReachSend.prepareSend(draft: draft, snapshot: &held, now: now, calendar: cal)
checkEq("still 2 before apply (schedule fail case)", held.dailyCapCount, 2)

print("\ncap exhausted keeps counts")
var full = ActiveReachSnapshot(
    enabled: true, dailyCap: 3, dailyBreakCap: 1,
    dailyCapCount: 3, dailyBreakCount: 0, countsDate: "2026-09-06")
switch ActiveReachSend.prepareSend(draft: draft, snapshot: &full, now: now, calendar: cal) {
case .failure(let e): checkEq("capExhausted", e, .capExhausted)
case .success: check("capExhausted", false)
}
checkEq("exhausted no +", full.dailyCapCount, 3)

print("\nbreak path")
var br = ActiveReachSnapshot(
    enabled: true, dailyCap: 3, dailyBreakCap: 1,
    dailyCapCount: 3, dailyBreakCount: 0, countsDate: "2026-09-06")
switch ActiveReachSend.prepareSend(draft: brk, snapshot: &br, now: now, calendar: cal) {
case .success(let usedBreak):
    check("usedBreak", usedBreak)
    ActiveReachSend.applyCount(usedBreak: usedBreak, snapshot: &br)
    checkEq("break +1", br.dailyBreakCount, 1)
    checkEq("cap stays 3", br.dailyCapCount, 3)
case .failure: check("break path", false)
}
switch ActiveReachSend.prepareSend(draft: brk, snapshot: &br, now: now, calendar: cal) {
case .failure(let e): checkEq("break exhausted", e, .capExhausted)
case .success: check("break exhausted", false)
}

print("\nempty text")
var ok = on
let empty = ActiveReachDraft(id: "e", text: "  ", wouldBreak: false)
switch ActiveReachSend.prepareSend(draft: empty, snapshot: &ok, now: now, calendar: cal) {
case .failure(let e): checkEq("emptyText", e, .emptyText)
case .success: check("emptyText", false)
}

print("\ncross-day reset before send")
var stale = ActiveReachSnapshot(
    enabled: true, dailyCap: 3, dailyBreakCap: 1,
    dailyCapCount: 3, dailyBreakCount: 1, countsDate: "2026-09-05")
switch ActiveReachSend.prepareSend(draft: draft, snapshot: &stale, now: now, calendar: cal) {
case .success(let usedBreak):
    check("after reset can send cap", usedBreak == false)
    checkEq("cap reset", stale.dailyCapCount, 0)
case .failure: check("cross-day", false)
}

print("\nid prefix")
check("ours", ActiveReachSend.isOurs("active-reach.abc"))
check("not ours", ActiveReachSend.isOurs("SHORTCUT_TASK") == false)
checkEq("id", ActiveReachSend.notificationId(for: "d1"), "active-reach.d1")

print("\nshipping")
let here = URL(fileURLWithPath: #filePath)
let shipping = here.deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("Shared/ActiveReachSend.swift")
let source = (try? String(contentsOfFile: shipping.path, encoding: .utf8)) ?? ""
check("shipping exists", !source.isEmpty)
check("prefix", source.contains("active-reach."))
check("sessionId userInfo", source.contains("\"sessionId\""))
check("category OPEN", source.contains("打开"))
check("notAuthorized", source.contains("notAuthorized"))
check("cancelOurs", source.contains("func cancelOurs"))
check("no ShortcutsProvider", !source.contains("AppShortcutsProvider"))
check("uses UNUserNotificationCenter", source.contains("UNUserNotificationCenter"))

if failures == 0 {
    print("\nALL PASS")
    exit(0)
} else {
    print("\nFAILED \(failures)")
    exit(1)
}
