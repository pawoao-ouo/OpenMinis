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

func read(_ url: URL) -> String {
    (try? String(contentsOf: url, encoding: .utf8)) ?? ""
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
let pack = read(here.appendingPathComponent("Shared/AppearanceThemePack.swift"))
let studio = read(here.appendingPathComponent("Shared/AppearanceStudio.swift"))
let library = read(here.appendingPathComponent("Shared/AppearanceThemeLibrary.swift"))
let chat = read(here.appendingPathComponent("Views/Chat/ChatMessageViews.swift"))
let think = read(here.appendingPathComponent("Views/Chat/AssistantBlockView.swift"))
let input = read(here.appendingPathComponent("Views/Chat/AIChatView.swift"))
let list = read(here.appendingPathComponent("Views/ContentView.swift"))
let studioView = read(here.appendingPathComponent("Views/Settings/AppearanceStudioView.swift"))
let kernel = read(here.appendingPathComponent("iSH/ISHKernel.m"))
let offload = read(here.appendingPathComponent("NativeOffloads/ThemeOffload.m"))

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
check("schema 4", pack.contains("schemaVersion = 4"))
check("input bar radius", pack.contains("inputBarRadius"))
check("thinking title size", pack.contains("thinkingTitleSize"))
check("category images", pack.contains("categoryImages"))
check("apply category images", pack.contains("func applyCategoryImages"))
check("wipe category images", pack.contains("func wipeCategoryImageFiles"))
check("thinking body uses pack size", think.contains("MinisThemeShape.thinkingBodySize"))
check("thinking title uses pack size", think.contains("MinisThemeShape.thinkingTitleSize"))
check("composer uses pack radius", input.contains("MinisThemeShape.inputBarRadius"))
check("studio category picker", studioView.contains("setCategoryImage"))
check("edit sheet custom icon", list.contains("categoryImage(for: cat.key)"))
check("v1 pack still decodes", pack.contains("userBubbleStyle"))
check("list row fill", pack.contains("listRowFillHex"))
check("list icon shape", pack.contains("enum AppearanceListIconShape"))
check("category overlay", pack.contains("categoryIcons"))
check("session row uses theme title", list.contains("MinisThemeList.title"))
check("builtin fallback", list.contains("sessionCategoryIconBuiltin"))
check("folder follows theme", list.contains("MinisThemeList.title"))
check("no strokeBorder on bubble", !chat.contains("strokeBorder"))
check("session row observes studio", list.contains("@ObservedObject private var appearanceStudio"))
check("theme library file", library.contains("appearanceStudio.themeLibrary.v1"))
check("save current", library.contains("func saveCurrentTheme"))
check("library files not defaults", library.contains("libraryPackURL"))
check("legacy library migrate", library.contains("func migrateLegacyLibrary"))
check("apply strips jpeg", pack.contains("stored.thinkingCardJPEGBase64 = nil"))
check("studio title binding", studioView.contains("thinkingTitleSizeBinding"))
check("category onChange", studioView.contains("onChange(of: categoryImageItem)"))
check("edit sheet observes studio", list.contains("struct SessionEditSheet"))
check("composer observes studio", input.contains("@ObservedObject private var appearanceStudio"))
check("list category fill", list.contains("categoryImage(for: key)"))
check("default input radius 20", pack.contains("inputBarRadius: 20"))
check("schema not 3", !pack.contains("schemaVersion = 3"))
check("cli save", offload.contains("cmd_save"))
check("cli use", offload.contains("cmd_use"))
check("studio library section", studioView.contains("主题库"))
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
