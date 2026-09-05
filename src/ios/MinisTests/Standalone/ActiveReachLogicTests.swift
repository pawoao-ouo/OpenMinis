// Standalone (`swift ActiveReachLogicTests.swift`).
// Pins ActiveReachLogic defaults, clamp, resetCountsIfNeeded, and the
// master-switch contract without importing the app graph.

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
        enabled: false,
        intervalMinutes: 60,
        dailyCap: 3,
        dailyBreakCap: 1,
        modelId: "",
        dialogIds: [],
        quietTimeoutMinutes: 120,
        dialogActiveHours: 24,
        dailyCapCount: 0,
        dailyBreakCount: 0,
        countsDate: ""
    )
}

enum ActiveReachBounds {
    static let intervalMinutes = 15...240
    static let dailyCap = 0...20
    static let dailyBreakCap = 0...5
    static let quietTimeoutMinutes = 30...720
    static let dialogActiveHours = 1...168
}

enum ActiveReachLogic {
    static let storageKey = "activeReach.config.v1"

    static func dayStamp(now: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: now)
        let year = parts.year ?? 0
        let month = parts.month ?? 0
        let day = parts.day ?? 0
        return String(format: "%04d-%02d-%02d", year, month, day)
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

    static func clamp(_ snapshot: inout ActiveReachSnapshot) {
        snapshot.intervalMinutes = clampInt(
            snapshot.intervalMinutes, to: ActiveReachBounds.intervalMinutes)
        snapshot.dailyCap = clampInt(snapshot.dailyCap, to: ActiveReachBounds.dailyCap)
        snapshot.dailyBreakCap = clampInt(
            snapshot.dailyBreakCap, to: ActiveReachBounds.dailyBreakCap)
        snapshot.quietTimeoutMinutes = clampInt(
            snapshot.quietTimeoutMinutes, to: ActiveReachBounds.quietTimeoutMinutes)
        snapshot.dialogActiveHours = clampInt(
            snapshot.dialogActiveHours, to: ActiveReachBounds.dialogActiveHours)
        snapshot.dailyCapCount = max(0, snapshot.dailyCapCount)
        snapshot.dailyBreakCount = max(0, snapshot.dailyBreakCount)
        snapshot.modelId = snapshot.modelId.trimmingCharacters(in: .whitespacesAndNewlines)
        snapshot.dialogIds = sanitizeDialogIds(snapshot.dialogIds)
    }

    static func sanitizeDialogIds(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in ids {
            let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, !seen.contains(id) else { continue }
            seen.insert(id)
            result.append(id)
        }
        return result
    }

    static func isEnabled(_ snapshot: ActiveReachSnapshot) -> Bool {
        snapshot.enabled
    }

    static func shouldAllowWake(_ snapshot: ActiveReachSnapshot) -> Bool {
        snapshot.enabled
    }

    private static func clampInt(_ value: Int, to range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

func utcCalendar() -> Calendar {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(secondsFromGMT: 0)!
    return cal
}

func utcDate(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0) -> Date {
    var parts = DateComponents()
    parts.year = y; parts.month = m; parts.day = d; parts.hour = h; parts.minute = min
    return utcCalendar().date(from: parts)!
}

print("defaults")
let def = ActiveReachSnapshot.default
check("master off", def.enabled == false)
checkEq("interval 60", def.intervalMinutes, 60)
checkEq("cap 3", def.dailyCap, 3)
checkEq("break 1", def.dailyBreakCap, 1)
checkEq("timeout 120", def.quietTimeoutMinutes, 120)
check("dialogs empty", def.dialogIds.isEmpty)
check("model empty", def.modelId.isEmpty)
checkEq("active hours 24", def.dialogActiveHours, 24)
checkEq("storage key", ActiveReachLogic.storageKey, "activeReach.config.v1")

print("\nmaster switch")
var off = ActiveReachSnapshot.default
check("isEnabled false", ActiveReachLogic.isEnabled(off) == false)
check("shouldAllowWake false", ActiveReachLogic.shouldAllowWake(off) == false)
var on = off
on.enabled = true
check("isEnabled true", ActiveReachLogic.isEnabled(on))
check("shouldAllowWake true", ActiveReachLogic.shouldAllowWake(on))

print("\nresetCountsIfNeeded")
var snap = ActiveReachSnapshot.default
snap.dailyCapCount = 2
snap.dailyBreakCount = 1
snap.countsDate = "2026-09-04"
let cal = utcCalendar()
ActiveReachLogic.resetCountsIfNeeded(&snap, now: utcDate(2026, 9, 5, 0, 1), calendar: cal)
checkEq("crossed day cap zero", snap.dailyCapCount, 0)
checkEq("crossed day break zero", snap.dailyBreakCount, 0)
checkEq("stamp today", snap.countsDate, "2026-09-05")

snap.dailyCapCount = 2
snap.dailyBreakCount = 1
ActiveReachLogic.resetCountsIfNeeded(&snap, now: utcDate(2026, 9, 5, 23, 59), calendar: cal)
checkEq("same day keeps cap", snap.dailyCapCount, 2)
checkEq("same day keeps break", snap.dailyBreakCount, 1)

snap.countsDate = ""
snap.dailyCapCount = 9
ActiveReachLogic.resetCountsIfNeeded(&snap, now: utcDate(2026, 9, 5), calendar: cal)
checkEq("empty stamp treated as new day", snap.dailyCapCount, 0)
checkEq("empty stamp filled", snap.countsDate, "2026-09-05")

print("\nclamp")
var wild = ActiveReachSnapshot.default
wild.intervalMinutes = 1
wild.dailyCap = 99
wild.dailyBreakCap = -3
wild.quietTimeoutMinutes = 10
wild.dialogActiveHours = 0
wild.modelId = "  grok-4.3  "
wild.dialogIds = ["  ", "aaa", "aaa", " bbb "]
ActiveReachLogic.clamp(&wild)
checkEq("interval floor 15", wild.intervalMinutes, 15)
checkEq("cap ceiling 20", wild.dailyCap, 20)
checkEq("break floor 0", wild.dailyBreakCap, 0)
checkEq("timeout floor 30", wild.quietTimeoutMinutes, 30)
checkEq("active hours floor 1", wild.dialogActiveHours, 1)
checkEq("model trimmed", wild.modelId, "grok-4.3")
checkEq("dialog unique keep order", wild.dialogIds, ["aaa", "bbb"])

print("\nround trip UserDefaults")
let suite = "activeReach.logic.tests.\(UUID().uuidString)"
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }
var stored = ActiveReachSnapshot.default
stored.enabled = true
stored.intervalMinutes = 90
stored.dialogIds = ["SID-1"]
stored.modelId = "entry-abc"
let data = try! JSONEncoder().encode(stored)
defaults.set(data, forKey: ActiveReachLogic.storageKey)
let backData = defaults.data(forKey: ActiveReachLogic.storageKey)!
let loaded = try! JSONDecoder().decode(ActiveReachSnapshot.self, from: backData)
checkEq("round-trip enabled", loaded.enabled, true)
checkEq("round-trip interval", loaded.intervalMinutes, 90)
checkEq("round-trip dialogs", loaded.dialogIds, ["SID-1"])
checkEq("round-trip model", loaded.modelId, "entry-abc")

print("\nshipping file agreement")
let here = URL(fileURLWithPath: #filePath)
let shipping = here.deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("Shared/ActiveReachConfig.swift")
let source = (try? String(contentsOfFile: shipping.path, encoding: .utf8)) ?? ""
check("shipping file exists", !source.isEmpty)
check("storage key in shipping", source.contains("activeReach.config.v1"))
check("enabled default false", source.contains("enabled: false"))
check("cancelPending hook", source.contains("func cancelPending()"))
check("shouldAllowWake", source.contains("func shouldAllowWake"))
check("resetCountsIfNeeded", source.contains("func resetCountsIfNeeded"))
check("no notification call", !source.contains("apple-notification"))
check("no UNUserNotification", !source.contains("UNUserNotificationCenter"))
check("no BGTask", !source.contains("BGTaskScheduler"))

if failures == 0 {
    print("\nALL PASS")
    exit(0)
} else {
    print("\nFAILED \(failures)")
    exit(1)
}
