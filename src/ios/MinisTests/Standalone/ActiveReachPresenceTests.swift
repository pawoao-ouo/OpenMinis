// Standalone (`swift ActiveReachPresenceTests.swift`).
// Pins sheIsHere after masterOff, keepalive skip when present.

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
    var dialogIds: [String]
}

enum WakeBlockReason: String {
    case masterOff, sheIsHere, noDialogs
}

enum WakeDisposition {
    case blocked(WakeBlockReason)
    case allowed
}

enum ActiveReachWake {
    static func evaluate(
        snapshot: ActiveReachSnapshot,
        sheIsHere: Bool
    ) -> WakeDisposition {
        if !snapshot.enabled { return .blocked(.masterOff) }
        if sheIsHere { return .blocked(.sheIsHere) }
        if snapshot.dialogIds.isEmpty { return .blocked(.noDialogs) }
        return .allowed
    }
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
        now: Date,
        isPresent: Bool = false
    ) -> Bool {
        guard enabled else { return false }
        guard !isPresent else { return false }
        let gap = TimeInterval(thresholdMinutes(intervalMinutes: intervalMinutes) * 60)
        if let last = lastAttemptAt, now.timeIntervalSince(last) < gap { return false }
        if let ka = lastKeepAliveAt, now.timeIntervalSince(ka) < 3600 { return false }
        return true
    }
}

func kind(_ d: WakeDisposition) -> String {
    switch d {
    case .blocked(let r): return r.rawValue
    case .allowed: return "allowed"
    }
}

print("order")
var off = ActiveReachSnapshot(enabled: false, dialogIds: ["A"])
checkEq("off beats present", kind(ActiveReachWake.evaluate(snapshot: off, sheIsHere: true)), "masterOff")

var on = ActiveReachSnapshot(enabled: true, dialogIds: ["A"])
checkEq("present blocks", kind(ActiveReachWake.evaluate(snapshot: on, sheIsHere: true)), "sheIsHere")
checkEq("absent allows", kind(ActiveReachWake.evaluate(snapshot: on, sheIsHere: false)), "allowed")

var empty = ActiveReachSnapshot(enabled: true, dialogIds: [])
checkEq("present beats empty dialogs", kind(ActiveReachWake.evaluate(snapshot: empty, sheIsHere: true)), "sheIsHere")
checkEq("absent empty still noDialogs", kind(ActiveReachWake.evaluate(snapshot: empty, sheIsHere: false)), "noDialogs")

print("\nkeepalive")
let now = Date()
check("present skips keepalive", ActiveReachKeepAlive.shouldKeepAlive(
    enabled: true, intervalMinutes: 60,
    lastAttemptAt: nil, lastKeepAliveAt: nil, now: now, isPresent: true) == false)
check("absent can keepalive", ActiveReachKeepAlive.shouldKeepAlive(
    enabled: true, intervalMinutes: 60,
    lastAttemptAt: nil, lastKeepAliveAt: nil, now: now, isPresent: false))

print("\nshipping")
let here = URL(fileURLWithPath: #filePath)
let root = here.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let wake = (try? String(contentsOfFile: root.appendingPathComponent("Shared/ActiveReachWake.swift").path, encoding: .utf8)) ?? ""
let ka = (try? String(contentsOfFile: root.appendingPathComponent("Shared/ActiveReachKeepAlive.swift").path, encoding: .utf8)) ?? ""
let presence = (try? String(contentsOfFile: root.appendingPathComponent("Shared/ActiveReachPresence.swift").path, encoding: .utf8)) ?? ""
let app = (try? String(contentsOfFile: root.appendingPathComponent("MinisApp.swift").path, encoding: .utf8)) ?? ""
check("sheIsHere in wake", wake.contains("case sheIsHere"))
check("evaluate after masterOff", wake.contains("if sheIsHere"))
check("keepalive isPresent", ka.contains("guard !isPresent"))
check("presence type", presence.contains("final class ActiveReachPresence"))
check("debug default off key", presence.contains("debugRunWhilePresent"))
check("app active hook", app.contains("ActiveReachPresence.shared.setPresent(true)"))
check("app background hook", app.contains("ActiveReachPresence.shared.setPresent(false)"))

if failures == 0 {
    print("\nALL PASS")
    exit(0)
} else {
    print("\nFAILED \(failures)")
    exit(1)
}
