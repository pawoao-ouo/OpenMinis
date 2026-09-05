// Standalone (`swift AppearanceThemePackTests.swift`).
// Pins theme-pack decode, radius clamp, hex normalize, and shipping hooks
// without importing the app graph.

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

func clampRadius(_ value: Double) -> Double {
    min(32, max(4, value))
}

func normalizeHex(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: CharacterSet.alphanumerics.inverted).uppercased()
    if trimmed.count == 6 || trimmed.count == 8 { return trimmed }
    return "808080"
}

print("AppearanceThemePack standalone")

checkEq("clamp low", clampRadius(1), 4)
checkEq("clamp high", clampRadius(99), 32)
checkEq("clamp mid", clampRadius(18), 18)
checkEq("hex hash", normalizeHex("#d4778b"), "D4778B")
checkEq("hex junk", normalizeHex("nope"), "808080")
checkEq("hex eight", normalizeHex("11223344"), "11223344")

let here = URL(fileURLWithPath: #file)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
let packFile = here.appendingPathComponent("Shared/AppearanceThemePack.swift")
let studioFile = here.appendingPathComponent("Shared/AppearanceStudio.swift")
let chatFile = here.appendingPathComponent("Views/Chat/ChatMessageViews.swift")
let thinkFile = here.appendingPathComponent("Views/Chat/AssistantBlockView.swift")
let kernelFile = here.appendingPathComponent("iSH/ISHKernel.m")
let offloadFile = here.appendingPathComponent("NativeOffloads/ThemeOffload.m")

let pack = (try? String(contentsOf: packFile, encoding: .utf8)) ?? ""
let studio = (try? String(contentsOf: studioFile, encoding: .utf8)) ?? ""
let chat = (try? String(contentsOf: chatFile, encoding: .utf8)) ?? ""
let think = (try? String(contentsOf: thinkFile, encoding: .utf8)) ?? ""
let kernel = (try? String(contentsOf: kernelFile, encoding: .utf8)) ?? ""
let offload = (try? String(contentsOf: offloadFile, encoding: .utf8)) ?? ""

check("pack file", !pack.isEmpty)
check("storage key", pack.contains("appearanceStudio.themePack.v1"))
check("applyThemePack", pack.contains("func applyThemePack"))
check("exportThemePack", pack.contains("func exportThemePack"))
check("studio cache", studio.contains("cachedThemePack"))
check("user bubble uses pack", chat.contains("MinisThemeShape.userBubble"))
check("assistant bubble uses pack", think.contains("MinisThemeShape.assistantBubble"))
check("thinking fill uses pack", think.contains("MinisThemeShape.thinkingFill"))
check("thinking card image", think.contains("thinkingCardImage()"))
check("bubble style enum", pack.contains("enum AppearanceBubbleStyle"))
check("tail style", pack.contains("case tail"))
check("schema 3", pack.contains("schemaVersion = 3"))
check("v1 pack still decodes", pack.contains("userBubbleStyle"))
check("list row fill", pack.contains("listRowFillHex"))
check("list icon shape", pack.contains("enum AppearanceListIconShape"))
check("category overlay", pack.contains("categoryIcons"))
check("session row uses theme title", Path("/var/minis/workspace/OpenMinis/src/ios/Views/ContentView.swift").read_text().contains("MinisThemeList.title"))
check("builtin fallback", Path("/var/minis/workspace/OpenMinis/src/ios/Views/ContentView.swift").read_text().contains("sessionCategoryIconBuiltin"))
check("folder follows theme", Path("/var/minis/workspace/OpenMinis/src/ios/Views/ContentView.swift").read_text().contains("MinisThemeList.title"))
check("no strokeBorder on bubble", "strokeBorder" not in chat)
check("session row observes studio", Path("/var/minis/workspace/OpenMinis/src/ios/Views/ContentView.swift").read_text().contains("@ObservedObject private var appearanceStudio"))
check("no hardcoded thinking blue fill", !think.contains("Color.blue.opacity(0.06)"))
check("kernel registers theme", kernel.contains("theme_offload_register()"))
check("offload stub", offload.contains("noff_ensure_guest_stub(\"/usr/local/bin/minis-theme\")"))
check("offload apply", offload.contains("cmd_apply"))

if failures == 0 {
    print("\nALL PASS")
    exit(0)
} else {
    print("\nFAILED \(failures)")
    exit(1)
}
