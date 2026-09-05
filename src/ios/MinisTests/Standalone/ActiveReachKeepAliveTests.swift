// Standalone (`swift ActiveReachKeepAliveTests.swift`).
// Pins keepalive threshold, debounce, and master-off.

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

enum ActiveReachKeepAlive {
    static let floorMinutes = 120
    static func thresholdMinutes(intervalMinutes: Int) -> Int {
        max(intervalMinutes, floorMinutes)
    }
    static func shouldKeepAlive(
        enabled: Bool,
        intervalMinutes: Int,
        lastAttemptAt: Date?,
        lastKeepAliveAt: Date?,
        now: Date
    ) -> Bool {
        guard enabled else { return false }
        let gap = TimeInterval(thresholdMinutes(intervalMinutes: intervalMinutes) * 60)
        if let last = lastAttemptAt, now.timeIntervalSince(last) < gap {
            return false
        }
        if let ka = lastKeepAliveAt, now.timeIntervalSince(ka) < 3600 {
            return false
        }
        return true
    }
}

func utcDate(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0) -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(secondsFromGMT: 0)!
    var p = DateComponents()
    p.year = y; p.month = m; p.day = d; p.hour = h; p.minute = min
    return cal.date(from: p)!
}

let now = utcDate(2026, 9, 6, 12, 0)

print("threshold")
checkEq("interval 60 floors to 120", ActiveReachKeepAlive.thresholdMinutes(intervalMinutes: 60), 120)
checkEq("interval 180 stays 180", ActiveReachKeepAlive.thresholdMinutes(intervalMinutes: 180), 180)

print("\nmaster off")
check("off never", ActiveReachKeepAlive.shouldKeepAlive(
    enabled: false, intervalMinutes: 60,
    lastAttemptAt: nil, lastKeepAliveAt: nil, now: now) == false)

print("\nno last attempt")
check("first keepalive when on", ActiveReachKeepAlive.shouldKeepAlive(
    enabled: true, intervalMinutes: 60,
    lastAttemptAt: nil, lastKeepAliveAt: nil, now: now))

print("\nwithin threshold")
let recent = now.addingTimeInterval(-30 * 60)
check("30 min ago skip", ActiveReachKeepAlive.shouldKeepAlive(
    enabled: true, intervalMinutes: 60,
    lastAttemptAt: recent, lastKeepAliveAt: nil, now: now) == false)

print("\npast threshold")
let stale = now.addingTimeInterval(-130 * 60)
check("130 min ago fire", ActiveReachKeepAlive.shouldKeepAlive(
    enabled: true, intervalMinutes: 60,
    lastAttemptAt: stale, lastKeepAliveAt: nil, now: now))

print("\ndebounce same hour")
let ka = now.addingTimeInterval(-10 * 60)
check("keepalive 10 min ago skip", ActiveReachKeepAlive.shouldKeepAlive(
    enabled: true, intervalMinutes: 60,
    lastAttemptAt: stale, lastKeepAliveAt: ka, now: now) == false)

let kaOld = now.addingTimeInterval(-61 * 60)
check("keepalive 61 min ago fire", ActiveReachKeepAlive.shouldKeepAlive(
    enabled: true, intervalMinutes: 60,
    lastAttemptAt: stale, lastKeepAliveAt: kaOld, now: now))

print("\nlarge interval")
check("interval 180 needs 180", ActiveReachKeepAlive.shouldKeepAlive(
    enabled: true, intervalMinutes: 180,
    lastAttemptAt: now.addingTimeInterval(-170 * 60),
    lastKeepAliveAt: nil, now: now) == false)
check("interval 180 at 181 fires", ActiveReachKeepAlive.shouldKeepAlive(
    enabled: true, intervalMinutes: 180,
    lastAttemptAt: now.addingTimeInterval(-181 * 60),
    lastKeepAliveAt: nil, now: now))

print("\nshipping")
let here = URL(fileURLWithPath: #filePath)
let shipping = here.deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("Shared/ActiveReachKeepAlive.swift")
let source = (try? String(contentsOfFile: shipping.path, encoding: .utf8)) ?? ""
check("shipping exists", !source.isEmpty)
check("floor 120", source.contains("floorMinutes = 120"))
check("shouldKeepAlive", source.contains("func shouldKeepAlive"))
check("no sendDraft", !source.contains("sendDraft"))
check("no UNUser", !source.contains("UNUserNotificationCenter"))

let intent = here.deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("Agent/Intents/ActiveReachWakeIntent.swift")
let intentSrc = (try? String(contentsOfFile: intent.path, encoding: .utf8)) ?? ""
check("intent shortcuts source", intentSrc.contains("source: \"shortcuts\""))
check("openAppWhenRun false", intentSrc.contains("openAppWhenRun = false"))
check("intent no sendDraft", !intentSrc.contains("sendDraft"))

let provider = here.deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("Agent/Intents/MinisShortcutsProvider.swift")
let provSrc = (try? String(contentsOfFile: provider.path, encoding: .utf8)) ?? ""
check("provider mounts intent", provSrc.contains("ActiveReachWakeIntent()"))

if failures == 0 {
    print("\nALL PASS")
    exit(0)
} else {
    print("\nFAILED \(failures)")
    exit(1)
}
