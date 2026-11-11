// Standalone (`swift AppearancePaletteIntegrityTests.swift`).
//
// [T-47] The built-in palette is a dictionary, so a role added to
// `AppearanceColorRole` but forgotten in the books does not fail to
// compile — it renders 808080 grey at runtime and nobody notices until a
// screenshot looks wrong. This suite is the standalone half of the guard;
// the other half is the startup assert inside AppearanceStudio.init.
//
// It parses the source instead of importing the app graph, same as the
// theme-pack suite, because this script runs without a simulator.

import Foundation

var failures = 0
func check(_ label: String, _ actual: Bool, _ expected: Bool = true) {
    if actual == expected { print("  OK \(label)") }
    else { print("  FAIL \(label) — expected \(expected), got \(actual)"); failures += 1 }
}

func read(_ url: URL) -> String {
    (try? String(contentsOf: url, encoding: .utf8)) ?? ""
}

print("AppearancePaletteIntegrity standalone")

let here = URL(fileURLWithPath: #file)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
let studio = read(here.appendingPathComponent("Shared/AppearanceStudio.swift"))

// 1. Every role declared by the enum.
let roleSection: String = {
    guard let start = studio.range(of: "enum AppearanceColorRole: String, CaseIterable"),
          let end = studio.range(of: "var title", range: start.upperBound..<studio.endIndex) else {
        return ""
    }
    return String(studio[start.upperBound..<end.lowerBound])
}()

var declaredRoles: [String] = []
for line in roleSection.split(separator: "\n") {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard trimmed.hasPrefix("case ") else { continue }
    let body = trimmed.dropFirst("case ".count)
    let head = body.split(separator: ":").first.map(String.init) ?? String(body)
    for piece in head.split(separator: ",") {
        let name = piece.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty, name.first?.isLetter == true { declaredRoles.append(name) }
    }
}
check("the role enum parses", declaredRoles.count >= 20)
check("roles are unique", Set(declaredRoles).count == declaredRoles.count)

// 2. The two documented exceptions.
let exceptions: Set<String> = ["bubbleText", "assistantBubbleText"]
check("the exception list is declared in source",
      studio.contains("static let rolesWithoutOwnEntry: Set<AppearanceColorRole> = [.bubbleText, .assistantBubbleText]"))

// 3. Both books carry every non-exempt role.
func book(enumeratedBy marker: String) -> Set<String> {
    guard let start = studio.range(of: marker) else { return [] }
    let tail = studio[start.upperBound...]
    guard let end = tail.range(of: "\n    ]") else { return [] }
    let body = String(tail[..<end.lowerBound])
    var found: Set<String> = []
    for chunk in body.split(separator: ",") {
        let piece = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
        guard piece.hasPrefix(".") else { continue }
        guard let colon = piece.firstIndex(of: ":") else { continue }
        let name = piece[piece.index(after: piece.startIndex)..<colon]
            .trimmingCharacters(in: .whitespaces)
        if !name.isEmpty, name.allSatisfy({ $0.isLetter }) { found.insert(name) }
    }
    return found
}

let lightBook = book(enumeratedBy: "static let light: [AppearanceColorRole: String] = [")
let darkBook = book(enumeratedBy: "static let dark: [AppearanceColorRole: String] = [")
check("the light book parses", lightBook.count >= 18)
check("the dark book parses", darkBook.count >= 18)

let expected = Set(declaredRoles).subtracting(exceptions)
let lightMissing = expected.subtracting(lightBook)
let darkMissing = expected.subtracting(darkBook)
check("light book covers every role", lightMissing.isEmpty)
check("dark book covers every role", darkMissing.isEmpty)
if !lightMissing.isEmpty { print("      light missing: \(lightMissing.sorted())") }
if !darkMissing.isEmpty { print("      dark missing: \(darkMissing.sorted())") }

// 4. Nothing extra sneaks in that is not a role.
let unknownLight = lightBook.subtracting(Set(declaredRoles))
check("light book has no unknown roles", unknownLight.isEmpty)

// 5. The startup guard exists so a missed role fails loudly on launch.
check("startup asserts palette completeness",
      studio.contains("assert(AppearancePaletteBook.missingRoles.isEmpty"))
check("missingRoles is computed from the enum, not a hand-kept list",
      studio.contains("let expected = AppearanceColorRole.allCases.filter { !rolesWithoutOwnEntry.contains($0) }"))

// 6. The 808080 fallback still exists — this suite is the thing that must
//    make it unreachable, so record that it is still the runtime fallback.
check("the silent grey fallback is still visible in source",
      studio.contains("?? DressingTokens.fallbackHex"))
check("the grey fallback value is still 808080",
      studio.contains("static let fallbackHex = \"808080\""))

if failures == 0 {
    print("\nALL PASS")
    exit(0)
} else {
    print("\nFAILED \(failures)")
    exit(1)
}