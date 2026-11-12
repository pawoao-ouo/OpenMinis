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
check("theme apply/export backend remains", pack.contains("func applyThemePack") && pack.contains("func exportThemePack"))
check("wallpaper and theme store remains", studio.contains("final class AppearanceStudio") && studio.contains("func setWallpaperEncoded"))
let lib = read(here.appendingPathComponent("Shared/AppearanceThemeLibrary.swift"))
let library = read(here.appendingPathComponent("Shared/AppearanceThemeLibrary.swift"))
let chat = read(here.appendingPathComponent("Views/Chat/ChatMessageViews.swift"))
let think = read(here.appendingPathComponent("Views/Chat/AssistantBlockView.swift"))
let input = read(here.appendingPathComponent("Views/Chat/AIChatView.swift"))
let list = read(here.appendingPathComponent("Views/ContentView.swift"))
let kernel = read(here.appendingPathComponent("iSH/ISHKernel.m"))
let offload = read(here.appendingPathComponent("NativeOffloads/ThemeOffload.m"))
let offloadBridge = read(here.appendingPathComponent("NativeOffloads/ThemeOffloadBridge.swift"))
let extras = read(here.appendingPathComponent("NativeOffloads/ThemeOffloadExtras.swift"))
let extrasCommands = read(here.appendingPathComponent("NativeOffloads/ThemeOffloadExtras+Commands.m"))
let skillStore = read(here.appendingPathComponent("Agent/Session/SkillStore.swift"))
let markdown = read(here.appendingPathComponent("Views/Chat/SelectableMarkdownView.swift"))
let toolLive = read(here.appendingPathComponent("Views/Chat/ToolLiveSheet.swift"))
let transport = read(here.appendingPathComponent("Agent/Sync/V2/ICloudSharedZoneTransport.swift"))
let engine = read(here.appendingPathComponent("Agent/Sync/CloudSyncEngine.swift"))
let migration = read(here.appendingPathComponent("Agent/Sync/V2/MigrationEngine.swift"))
let bootstrap = read(here.appendingPathComponent("Agent/Sync/V2/SyncV2Bootstrap.swift"))
let entitlements = read(here.appendingPathComponent("Minis.entitlements"))

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
// [04b-2 §7] Both of these asserted a spelling the code no longer uses, so
// they had been red since before b5595fc and made "run the tests" meaningless.
// The BEHAVIOUR is there in both cases — the assertion was just pinned to an
// older shape.
//   • `case tail` is declared inside a combined case list
//     (`case rounded, squircle, pill, tail, sharp`), so match the switch arm
//     that proves the style is handled.
//   • markdown links colour now comes from `uiColorSnapshot(.accent)`; the
//     scoped `uiColor(.accent, scope: .chat)` form was the older accessor.
check("tail style", pack.contains("case .tail:"))
check("schema 5", pack.contains("schemaVersion = 5"))
check("font family", pack.contains("enum AppearanceFontFamily"))
check("input bar style", pack.contains("inputBarStyle"))
check("input bar image", pack.contains("func setInputBarImage"))
check("composer uses pack shape", input.contains("MinisThemeShape.inputBar"))
// [04b-2] Message sites moved from `MinisThemeShape.fontFamily` to the
// per-part `MinisThemeShape.messageFont(size:)`, which honours the
// message-part family and uploaded fonts — same behaviour, new accessor.
check("bubbles use theme font", chat.contains("MinisThemeShape.messageFont"))
check("input bar radius", pack.contains("inputBarRadius"))
check("thinking title size", pack.contains("thinkingTitleSize"))
check("category images", pack.contains("categoryImages"))
check("apply category images", pack.contains("func applyCategoryImages"))
check("wipe category images", pack.contains("func wipeCategoryImageFiles"))
check("thinking body uses pack size", think.contains("MinisThemeShape.thinkingBodySize"))
check("thinking title uses pack size", think.contains("MinisThemeShape.thinkingTitleSize"))
check("composer observes studio", input.contains("@ObservedObject private var appearanceStudio"))
check("category symbol setter", pack.contains("func setCategorySymbol"))
check("category color setter", pack.contains("func setCategoryColor"))
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
// [K-4] The eight per-row `PhotosPicker`s collapsed into one page-level picker
// driven by `pickedPhoto` + `pickerTarget`. The old assertion pinned the now
// deleted `categoryImageItem`; pin the replacement wiring instead — a single
// `.photosPicker(isPresented:selection:)` plus the dispatch that routes the
// picked item to the row that asked for it.
check("edit sheet observes studio", list.contains("struct SessionEditSheet"))
check("list category fill", list.contains("categoryImage(for: key)"))
check("default input radius 20", pack.contains("inputBarRadius: 20"))
check("schema not 3", !pack.contains("schemaVersion = 3"))
check("notAThemePack", pack.contains("notAThemePack"))
check("no unsupportedSchema", !pack.contains("unsupportedSchema"))
check("looksLikeThemePack gate", pack.contains("looksLikeThemePack"))
check("migrate fill missing", pack.contains("fill missing") || pack.contains("Missing fields are filled") || pack.contains("looksLikeThemePack"))
check("schema 5 asJSONObject write", pack.contains("\"schema\": Self.schemaVersion"))
check("upgrade rewrite UserDefaults", pack.contains("storedSchema != AppearanceThemePack.schemaVersion"))
check("cli save", offload.contains("cmd_save"))
check("cli use", offload.contains("cmd_use"))
check("no hardcoded thinking blue fill", !think.contains("Color.blue.opacity(0.06)"))
check("kernel registers theme", kernel.contains("theme_offload_register()"))
check("offload stub", offload.contains("noff_ensure_guest_stub(\"/usr/local/bin/minis-theme\")"))
check("offload apply", offload.contains("cmd_apply"))
check("thinking accent follows chat accent", pack.contains("AppearanceStudio.shared.color(.accent, scope: .chat)"))
// [B28 B-3] 默认包不再写死一个 hex —— 空串就是「跟 accent 走」。
// 原来这两条锁的是 D4778B 这个具体色值，B-3 之后那个值本身就不该存在了。
check("default thinking not material blue", !pack.contains("thinkingAccentHex: \"1E88E5\""))
check("default thinking defers to accent", pack.contains("thinkingAccentHex: \"\""))
check("thinking fill falls back to accent", pack.contains("return AppearanceStudio.shared.color(.accent, scope: .chat).opacity(0.06)"))
check("thinking accent falls back to accent", pack.contains("return AppearanceStudio.shared.color(.accent, scope: .chat)"))
check("tool capsules use ChatColors.accent", think.contains("accentColor: ChatColors.accent"))
check("no green tool capsule", !think.contains("accentColor: .green"))
check("tool success uses theme", think.contains("case .success: return ChatColors.success"))
check("slash thinking uses accent", input.contains("thinkingLevel.isEnabled ? ChatColors.accent"))
check("bundled minis-theme skill", skillStore.contains("name: minis-theme"))
check("bundled skill not PPT", skillStore.contains("不是 PPT"))
check("cli documents accent", offload.contains("THEME PACK:"))
check("warning color role", studio.contains("case success, warning, destructive"))
// [B28 E-1] 枚举标题改成 AppLocalized 了，断言跟着改形态。
check("warning title", studio.contains("case .warning: return AppLocalized(\"警告\")"))
check("ChatColors.warning", input.contains("static var warning: Color"))
check("errors use destructive", input.contains("ChatColors.destructive"))
check("interrupt uses warning", chat.contains("ChatColors.warning"))
check("markdown links use accent", markdown.contains("uiColorSnapshot(.accent)"))
check("no chat capsule green leftover", !think.contains("accentColor: .green"))
check("no tool live purple leftover", !toolLive.contains("return .purple"))
check("clone icloud container", transport.contains("iCloud.com.openminis.clone"))
check("no default CKContainer call", !transport.contains("CKContainer.default().privateCloudDatabase"))
check("probeAccount exists", bootstrap.contains("probeAccount()"))
check("disable sync when icloud missing", bootstrap.contains("disabling sync so launch can continue"))
check("v1 delete uses clone container", transport.contains("let db = container.privateCloudDatabase"))
check("entitlement gate exists", transport.contains("hasCloneICloudEntitlement"))
check("probe gated on entitlement", transport.contains("guard hasCloneICloudEntitlement() else"))
check("v1 gated on entitlement", engine.contains("guard ICloudSharedZoneTransport.hasCloneICloudEntitlement() else"))
check("migration shim gated ×4", migration.components(separatedBy: "hasCloneICloudEntitlement()").count > 4)
check("entitlements clone icloud", entitlements.contains("iCloud.com.openminis.clone"))
check("entitlements not official icloud", !entitlements.contains("iCloud.com.openminis.app"))

// --- Partial packs must not destroy user images (2026-10-18) ---
// A missing categoryImages key used to mean "delete that file". Any AI call
// carrying colors only wiped all 16 uploaded category images.
check("decode merges onto a base", pack.contains("merging base: AppearanceThemePack = .default"))
check("category map falls back", pack.contains("fallback: base.categoryImages"))
check("missing key keeps file", pack.contains("guard let value = map[key] else { continue }"))
check("empty string is the delete signal", pack.contains("if value.isEmpty {"))
check("apply keeps unmentioned markers", pack.contains("let mentioned = Set(pack.categoryImages.keys)"))
check("encoded bytes skip re-encode", pack.contains("func writeEncodedImage"))
check("wallpaper takes raw bytes", studio.contains("func setWallpaperEncoded"))
check("thinking card takes raw bytes", pack.contains("func setThinkingCardImageEncoded"))
check("input bar takes raw bytes", pack.contains("func setInputBarImageEncoded"))
check("ai apply merges live pack", offloadBridge.contains("merging: live"))
check("reset snapshots first", pack.contains("func captureThemeUndoSnapshot"))
check("reset is undoable", pack.contains("func undoThemeReset"))
check("reset needs force", offload.contains("--force"))
check("undo command wired", offload.contains("cmd_undo"))
check("undo bridge exists", offloadBridge.contains("func undoReset"))

// --- Extended AI surface (2026-10-18) ---
// Avatars, row icons, per-page wallpapers and single colour overrides used to
// live outside the pack JSON, so an AI could not touch them at all.
check("extras bridge file", extras.contains("class ThemeOffloadExtras"))
check("avatar command", extras.contains("func setAvatar"))
check("assistant avatar", extras.contains("setAssistantAvatar"))
check("icon command", extras.contains("func setIcon"))
check("icon slot listing", extras.contains("listIconSlots"))
check("per-page wallpaper", extras.contains("func setWallpaper"))
check("single colour", extras.contains("func setColor"))
check("colour cleared by name", extras.contains("clearOverride"))
check("extras commands registered", offload.contains("theme_extra_avatar"))
check("wallpaper scope parsed", extras.contains("AppearanceScope(rawValue: scope)"))
check("hex rejected before store", extras.contains("allSatisfy({ $0.isHexDigit })"))
check("extras emit maps ok", extrasCommands.contains("theme_extra_emit"))
check("host path resolved in objc", extrasCommands.contains("noff_resolve_host_path"))

// [T-55] 壁纸只认一处上限。主壁纸和一起听各写一份 2200、各写一份压色，
// 是这条审计的原始问题；收敛之后只许 `WallpaperPipeline.maxEdge` 一处出现。
let together = read(here.appendingPathComponent("Agent/Together/TogetherStore.swift"))
check("wallpaper maxEdge lives in one place",
      studio.contains("static let maxEdge: CGFloat = 2200"))
check("together has no second 2200 literal", !together.contains("= 2200"))
check("together encodes through the pipeline",
      together.contains("WallpaperPipeline.jpeg(image, matte: .white)"))
check("together sniffs through the pipeline",
      together.contains("WallpaperPipeline.fileExtension(for: image, source: source)"))
check("main wallpaper encodes through the pipeline",
      studio.contains("return WallpaperPipeline.jpeg(image, matte: matte)"))
check("together downscale implementation is gone", !together.contains("func downscaledJPEG"))
check("pipeline owns the only quality constant", studio.contains("static let jpegQuality: CGFloat = 0.86"))

// [T-25] 页级写保护：apply 的锁表管不到子命令，所以每条能改到页级的
// 命令都得自己过确认单、自己报原值。这里是源码级钉住，防止以后被顺手删掉。
// `extras` 在文件前面已经读过一次，这里直接复用，不重复声明。
check("page colour write asks first",
      extras.contains("previousValue = hadOwnOverride"))
check("page colour reports whether it replaced an override",
      extras.contains("out[\"hadOwnOverride\"] = hadOwnOverride"))
check("page wallpaper reports the file it replaced",
      extras.contains("out[\"previousWallpaper\"] = previousFile"))
check("page wallpaper clear reports the file it removed",
      extras.contains("out[\"removedWallpaper\"] = removedFile"))
check("page colour clear is awaited and gated",
      extras.contains("return onMainAwaited { token in")
      && extras.contains("what: \"清掉「\\(parsedScope.rawValue)」页的「\\(parsedRole.title)」\""))
check("wallpaper filenames come from one accessor",
      studio.contains("func ownWallpaperFileName(_ scope: AppearanceScope) -> String?"))

// [T-06] 四个取色入口的默认作用域必须来自 ThemeColorLayer，不再各写字面量。
// 只钉默认值：主题包 apply 那类"写入"仍显式写 .global 是对的，不能一刀切。
let askDialog = read(here.appendingPathComponent("Views/Chat/AskUserDialog.swift"))
check("layer contract exists", studio.contains("enum ThemeColorLayer"))
check("chat layer is chat", studio.contains("static let chat: AppearanceScope = .chat"))
check("sheet layer follows chat", studio.contains("static let sheet: AppearanceScope = .chat"))
check("settings layer is global", studio.contains("static let settings: AppearanceScope = .global"))
check("home layer is home", studio.contains("static let home: AppearanceScope = .home"))
check("MinisTheme defaults through the contract",
      studio.contains("scope: AppearanceScope = ThemeColorLayer.fallback"))
check("ChatColors has no bare .chat scope", !input.contains("scope: .chat"))
check("sheet defaults through the contract",
      askDialog.contains("scope: AppearanceScope = ThemeColorLayer.sheet")
      && !askDialog.contains("scope: AppearanceScope = .chat"))
check("home list defaults through the contract", pack.contains("scope: ThemeColorLayer.home"))

// [T-07] 明暗模式只许一处映射。任何文件里再出现 `== 1 ? .light` 这类
// 三目就是又长出一份副本，直接判失败。
let modeFiles = ["MinisApp.swift", "Views/ContentView.swift",
                 "Views/Chat/MinisMediaViews.swift", "Views/Chat/WebPreviewSheet.swift",
                 "Debug/DebugRPCProviderChat.swift"]
check("appearance mode enum exists", studio.contains("enum AppearanceMode: Int, CaseIterable"))
check("appearance mode owns the key",
      studio.contains("static let defaultsKey = \"appearanceMode\""))
check("appearance mode parses to a legal case",
      studio.contains("static func parse(_ raw: Int) -> AppearanceMode"))
check("appearance mode rejects illegal values",
      studio.contains("static func isLegal(_ raw: Int) -> Bool"))
check("appearance mode maps to a colour scheme",
      studio.contains("var colorScheme: ColorScheme?"))
check("appearance mode maps to a ui style",
      studio.contains("var interfaceStyle: UIUserInterfaceStyle"))
for name in modeFiles {
    let body = read(here.appendingPathComponent(name))
    check("\(name) has no hand-rolled mode ternary",
          !body.contains("appearanceMode == 1 ? .light")
          && !body.contains("appearanceMode == 2 ? .dark"))
    check("\(name) has no bare mode key", !body.contains("\"appearanceMode\""))
}
check("keys table holds the mode key",
      studio.contains("static let appearanceMode = AppearanceMode.defaultsKey"))

// [T-33] 助手块整块只许跟主题，不许再掺系统语义色和自写动态闭包。
let helperBlock = read(here.appendingPathComponent("Views/Chat/HelperBlockView.swift"))
check("helper block has no system semantic label colours",
      !helperBlock.contains("UIColor.label")
      && !helperBlock.contains("UIColor.secondaryLabel")
      && !helperBlock.contains("UIColor.tertiaryLabel"))
check("helper block card surfaces read theme roles",
      helperBlock.contains("private static var cardBg: Color {")
      && helperBlock.contains("uiColorSnapshot(.surface, scope: ThemeColorLayer.chat)")
      && helperBlock.contains("uiColorSnapshot(.border, scope: ThemeColorLayer.chat)"))
check("helper accent follows the theme when tuned",
      helperBlock.contains("Self.accentWasTuned ? Self.themeAccent : Self.violet")
      && helperBlock.contains("Color(AppearanceStudio.uiColorSnapshot(.accent, scope: ThemeColorLayer.chat))"))
check("helper accent keeps the violet as the untuned default",
      helperBlock.contains("static let violet = Color(UIColor { tc in"))
check("helper badge text follows the theme when tuned",
      helperBlock.contains("Self.accentWasTuned ? Self.themeAccent : Self.badgeViolet"))
check("helper accent reads the snapshot, not the isolated studio",
      helperBlock.contains("AppearanceStudio.colorSnapshot")
      && !helperBlock.contains("AppearanceStudio.shared.hasOverride"))

// [T-43] 内置默认表里，卡片 / 浮层 / 输入框必须是三个不同的值——原来浅色
// 三个都是 FFFFFF、深色 field 与 surface 同值，白底上根本看不出层次。
check("light surfaces are three distinct steps",
      studio.contains(".surface: \"FFFFFF\", .raised: \"FBFBFD\"")
      && studio.contains(".field: \"F4F4F7\""))
check("dark surfaces are three distinct steps",
      studio.contains(".surface: \"1C1C1E\", .raised: \"2C2C2E\"")
      && studio.contains(".field: \"262628\""))
check("dark muted block sits between surface and raised",
      studio.contains(".mutedSurface: \"242426\""))

// [T-44] 角色分组只许一份源，且必须覆盖每一个角色。
check("role groups flatten to every case",
      studio.contains("static var allRoles: [AppearanceColorRole] { allCases.flatMap(\\.roles) }"))
check("text group carries the shell text",
      studio.contains("case .text: return [.primaryText, .secondaryText, .tertiaryText, .shellText]"))
check("chat group carries both bubble texts",
      studio.contains("case .chat: return [.userBubble, .assistantBubble, .bubbleText, .assistantBubbleText]"))
check("controls group carries disabled",
      studio.contains("case .controls: return [.iconTile, .chip, .field, .border, .disabled]"))
// The dress-up UI is intentionally empty during redesign; backend roles are checked above.
// [T-47] 调色板是字典，缺项只在运行时变 808080 灰。断言把"每个角色都有
// 值"钉死，并说明两个气泡文字角色是故意缺席的。
check("palette declares its intentional gaps",
      studio.contains("static let rolesWithoutOwnEntry: Set<AppearanceColorRole> = [.bubbleText, .assistantBubbleText]"))
check("palette reports missing roles",
      studio.contains("static var missingRoles: [AppearanceColorRole] {"))
check("palette完整性在启动时断言",
      studio.contains("assert(AppearancePaletteBook.missingRoles.isEmpty"))

// [六定-6] 选中胶囊换了填充，里面的字必须跟着反色。聊天的两处选中行
// （斜杠菜单、文件提及菜单）底都是 accent，字却原来还是 primaryText ——
// 默认配色下两者同为 #111113，选中即黑底黑字。
let fontSettings = read(here.appendingPathComponent("Shared/FontSettings.swift"))
check("contrast foreground linearises sRGB",
      fontSettings.contains("static func relativeLuminance(hex: String) -> Double")
      && fontSettings.contains("pow((c + 0.055) / 1.055, 2.4)"))
check("contrast foreground uses the linearised luminance",
      fontSettings.contains("relativeLuminance(hex: hex) > 0.179 ? Color.black : Color.white"))
check("slash menu inverts its text on the accent fill",
      input.contains("isSelected ? onSelectedFill : ChatColors.primaryText"))
check("mention menu inverts its text on the accent fill",
      input.contains("isSelected ? onSelectedFill : ChatColors.secondaryText"))
check("chat selection fill is still the accent role",
      input.contains("(isSelected || configuration.isPressed) ? ChatColors.accent : Color.clear"))

// Backend image APIs remain present while the UI is redesigned.
check("backend retains user avatar setter", studio.contains("func setUserAvatar"))
check("backend retains character-art API", pack.contains("func setCharacterArtImage"))
check("backend retains icon setter", studio.contains("func setIcon"))
check("backend retains input-bar image setter", pack.contains("func setInputBarImage"))
check("backend retains thinking-card image setter", pack.contains("func setThinkingCardImage"))
check("backend retains category image setter", pack.contains("func setCategoryImage"))

// [T-73a] AI 桥不能在主线程上阻塞信号量。断言写死这条前提，并给主线程
// 调用留一条不阻塞的退路。
let bridgeCall = read(here.appendingPathComponent("Shared/ThemeBridgeCall.swift"))
check("theme bridge asserts it is off the main thread",
      bridgeCall.contains("assert(!Thread.isMainThread,"))
check("theme bridge has a non-blocking path for main-thread callers",
      bridgeCall.contains("private static func runOffMainThread("))
check("main-thread path reports itself as deferred",
      bridgeCall.contains("\"deferred\": true"))
check("deferred path never claims to have written",
      !bridgeCall.contains("\"ok\": true, \"written\": true"))

// [T-54] 透明 PNG 的烘焙底色。审计的原症状：透明 PNG 在深色档被压到画布
// 浅色上，暗内容周围留一圈惨白（PIC-8）。核对项固定成四条，逐条给结果：
//
//   用例：一张带透明区域的 PNG 当主壁纸
//   期望：垫的是当前档位的画布色（浅 F5F5F7 / 深 000000），不是写死的白
//   做法：opaque=true，且先填 matte 再画图（顺序反了等于没垫）
//   结果：下面四条断言，代码层全部成立；渲染观感仍待真机
check("T-54 case: transparent PNG mattes with the scheme canvas",
      studio.contains("let matte = UIColor(hex: book[.canvas] ?? (dark ? \"000000\" : \"F5F5F7\"))"))
check("T-54 case: the pipeline renders opaque, so alpha cannot survive",
      studio.contains("format.opaque = true"))
if let fillAt = studio.range(of: "matte.setFill()")?.lowerBound,
   let drawAt = studio.range(of: "image.draw(in: CGRect(origin: .zero, size: canvas))")?.lowerBound {
    check("T-54 case: matte is filled BEFORE the image is drawn", fillAt < drawAt)
} else {
    check("T-54 case: matte is filled BEFORE the image is drawn", false)
}
check("T-54 case: the matte actually reaches the pipeline",
      studio.contains("return WallpaperPipeline.jpeg(image, matte: matte)"))
check("T-54 case: dark and light produce different mattes",
      studio.contains("\"000000\"") && studio.contains("\"F5F5F7\""))

// [T-54] 真正的修法：带透明的图按档位各存一份，切档不再沿用旧配色的白边。
// 原来只在拾取那一刻垫一次底，切档后文件里还是旧档的画布色 —— 这才是审计
// 要修的那个场景，光有上面那几条"拾取时垫对了"是不够的。
check("T-54 fix: a per-variant wallpaper path exists",
      studio.contains("wallpaper-\\(scope.rawValue)-\\(variant.rawValue).jpg"))
check("T-54 fix: transparency is actually detected",
      studio.contains("case .none, .noneSkipFirst, .noneSkipLast: return false"))
check("T-54 fix: a transparent image is written once per variant",
      studio.contains("writeWallpaperData(light, for: scope, variant: .light)")
      && studio.contains("writeWallpaperData(darkData, for: scope, variant: .dark)"))
check("T-54 fix: the legacy single file is removed for transparent sources",
      studio.contains("try? FileManager.default.removeItem(at: wallpaperURL(scope))\n            return true"))
check("T-54 fix: reading prefers the current variant",
      studio.contains("let ownVariant = wallpaperURL(scope, variant: activeVariant)"))
check("T-54 fix: the cache is keyed by variant too",
      studio.contains("\"\\(scope.rawValue).\\(activeVariant.rawValue)\" as NSString"))
check("T-54 fix: clear removes all three files",
      studio.contains("for url in wallpaperURLs(scope) { try? FileManager.default.removeItem(at: url) }"))
check("T-54 fix: snapshots capture all three files",
      studio.contains("for src in wallpaperURLs(scope) where FileManager.default.fileExists(atPath: src.path)"))
check("T-54 fix: pack export reads the light variant, falling back to the legacy name",
      pack.contains("private func wallpaperLightFileData(_ scope: AppearanceScope) -> Data?")
      && pack.contains("originalImageData(fileName: \"wallpaper-\\(scope.rawValue)-light.jpg\")"))

// [T-54 r2] 只带一份的话，浅色档导出、别人导入、切深色档，读到的还是浅色
// 垫的那张——原症状换了个入口。包必须两档都带，导入必须两档都落盘。
check("T-54 r2: the pack carries a second variant for the global wallpaper",
      pack.contains("pack.wallpaperDarkJPEGBase64 = wallpaperDarkFileData(.global)?.base64EncodedString()"))
check("T-54 r2: the pack carries a second variant per page scope",
      pack.contains("pageDarkWallpapers[scope.rawValue] = dark.base64EncodedString()"))
check("T-54 r2: the second variant is a real field, not a comment",
      pack.contains("var wallpaperDarkJPEGBase64: String? = nil")
      && pack.contains("var pageDarkWallpapers: [String: String]? = nil"))
check("T-54 r2: the second variant survives decode and re-encode",
      pack.contains("wallpaperDarkJPEGBase64: raw[\"wallpaperDarkJPEGBase64\"] as? String")
      && pack.contains("if let wallpaperDarkJPEGBase64 { obj[\"wallpaperDarkJPEGBase64\"] = wallpaperDarkJPEGBase64 }"))
check("T-54 r2: image bytes never land in UserDefaults",
      pack.contains("stored.wallpaperDarkJPEGBase64 = nil")
      && pack.contains("stored.pageDarkWallpapers = nil"))
check("T-54 r2: import writes both variants and drops the legacy file",
      studio.contains("func setWallpaperEncoded(_ data: Data, for scope: AppearanceScope,\n                             darkData: Data? = nil) async -> Bool")
      && studio.contains("writeWallpaperData(darkJPEG, for: scope, variant: .dark)"))
check("T-54 r2: apply feeds both variants in",
      pack.contains("setWallpaperEncoded(data, for: .global, darkData: darkData)")
      && pack.contains("darkData: pack.pageDarkWallpapers?[scopeRaw]"))
check("T-54 r2: a single-file write clears stale variant files",
      studio.contains("for stale in [wallpaperURL(scope, variant: .light),"))
check("T-54 r2: the AI cannot use the new key to reach a page wallpaper",
      pack.contains("\"pageWallpapers\", \"pageDarkWallpapers\",\n    ]"))
check("T-54 r2: a saved theme keeps the second variant",
      lib.contains("partial.wallpaperDarkJPEGBase64 = saved.wallpaperDarkJPEGBase64"))
check("T-54 r2: the in-use check ignores variant bytes but not variant slots",
      lib.contains("\"wallpaperJPEGBase64\", \"wallpaperDarkJPEGBase64\"")
      && lib.contains("j[\"pageDarkWallpapers\"] = pageDarkWallKeys.sorted()"))

// [T-54 r2] 带透明的壁纸只存分档文件，旧单文件被删了。只看旧名字，AI
// 报原值时会说"这一页没有自己的图"，可它明明有。
check("T-54 r2: reporting the previous wallpaper looks at the variant files",
      studio.contains("for variant in [activeVariant, .light, .dark] {"))

// [P2-2] Executable corpus tests for the EXIF gate. The walkers below
// are transliterations of `WallpaperPipeline.stripJPEGMetadata` /
// `stripPNGMetadata` / `stripWebPMetadata` in AppearanceStudio.swift,
// run here on real Pillow-made files (base64 below) so the byte logic is
// exercised, not just asserted by string. Decode-ability of the stripped
// output is verified by the Python mirror (/tmp/exif_gate_mirror.py,
// Pillow: stripped output decodes pixel-identical to the original);
// this script has no UIImage, so it asserts structure instead: exact
// golden lengths, segment/chunk inventories, and byte-identical image
// payloads. The UIImage-dependent gate branches (decode, orientation,
// re-encode) are covered by the routing table + string pins below.
func exifStripJPEG(_ bytes: [UInt8]) -> [UInt8] {
    var out: [UInt8] = []
    out.reserveCapacity(bytes.count)
    guard bytes.count >= 4 else { return bytes }
    out.append(contentsOf: bytes[0..<2])
    var i = 2
    while i < bytes.count {
        guard bytes[i] == 0xFF, i + 1 < bytes.count else { return bytes }
        let marker = bytes[i + 1]
        if marker == 0xFF { i += 1; continue }
        if marker == 0xD9 {
            out.append(contentsOf: bytes[i..<(i + 2)])
            return out
        }
        if marker == 0xDA {
            guard bytes.count - i >= 4 else { return bytes }
            let segLen = (Int(bytes[i + 2]) << 8) | Int(bytes[i + 3])
            guard segLen >= 2, bytes.count - i >= 2 + segLen else { return bytes }
            var j = i + 2 + segLen
            var scanEnded = false
            while j < bytes.count {
                guard bytes[j] == 0xFF else { j += 1; continue }
                guard j + 1 < bytes.count else { return bytes }
                let next = bytes[j + 1]
                if next == 0xFF { j += 1; continue }
                if next == 0x00 { j += 2; continue }
                if next >= 0xD0 && next <= 0xD7 { j += 2; continue }
                if next == 0xD9 {
                    out.append(contentsOf: bytes[i...(j + 1)])
                    return out
                }
                out.append(contentsOf: bytes[i..<j])
                i = j
                scanEnded = true
                break
            }
            guard scanEnded else { return bytes }
            continue
        }
        guard bytes.count - i >= 4 else { return bytes }
        let len = (Int(bytes[i + 2]) << 8) | Int(bytes[i + 3])
        guard len >= 2, bytes.count - i >= 2 + len else { return bytes }
        if marker != 0xE1 && marker != 0xED && marker != 0xFE {
            out.append(contentsOf: bytes[i..<(i + 2 + len)])
        }
        i += 2 + len
    }
    return out
}

func exifStripPNG(_ bytes: [UInt8]) -> [UInt8] {
    var out: [UInt8] = []
    out.reserveCapacity(bytes.count)
    guard bytes.count >= 8 else { return bytes }
    var i = 8
    out.append(contentsOf: bytes[0..<8])
    var sawIDAT = false
    while i < bytes.count {
        guard bytes.count - i >= 8 else { return out }
        let len = (Int(bytes[i]) << 24) | (Int(bytes[i + 1]) << 16) | (Int(bytes[i + 2]) << 8) | Int(bytes[i + 3])
        let type = String(decoding: bytes[(i + 4)..<(i + 8)], as: UTF8.self)
        guard len >= 0, bytes.count - i >= 12 + len else {
            return (sawIDAT && type != "IDAT") ? out : bytes
        }
        if type != "eXIf" && type != "tEXt" && type != "iTXt" && type != "zTXt" && type != "tIME" {
            out.append(contentsOf: bytes[i..<(i + 12 + len)])
        }
        if type == "IDAT" { sawIDAT = true }
        if type == "IEND" { return out }
        i += 12 + len
    }
    return out
}

func exifStripWebP(_ bytes: [UInt8]) -> [UInt8] {
    var out: [UInt8] = []
    out.reserveCapacity(bytes.count)
    guard bytes.count >= 12 else { return bytes }
    var i = 12
    out.append(contentsOf: bytes[0..<12])
    var vp8xFlagOffset: Int? = nil
    var droppedEXIF = false
    var droppedXMP = false
    var sawChunk = false
    var sawImage = false
    while i < bytes.count {
        guard bytes.count - i >= 8 else { break }
        let type = String(decoding: bytes[i..<(i + 4)], as: UTF8.self)
        let len = Int(bytes[i + 4]) | (Int(bytes[i + 5]) << 8) | (Int(bytes[i + 6]) << 16) | (Int(bytes[i + 7]) << 24)
        guard len >= 0, bytes.count - i >= 8 + len else {
            if !sawImage { return bytes }
            if type == "EXIF" { droppedEXIF = true } else if type == "XMP " { droppedXMP = true }
            break
        }
        let chunkLen = 8 + len + (len % 2)
        if bytes.count - i < chunkLen {
            if type == "VP8 " || type == "VP8L" { return bytes }
            if type == "EXIF" { droppedEXIF = true } else if type == "XMP " { droppedXMP = true }
            sawChunk = true
            break
        }
        sawChunk = true
        if type == "VP8X", len == 10 { vp8xFlagOffset = out.count + 8 }
        if type == "VP8 " || type == "VP8L" { sawImage = true }
        if type != "EXIF" && type != "XMP " {
            out.append(contentsOf: bytes[i..<(i + chunkLen)])
        } else if type == "EXIF" {
            droppedEXIF = true
        } else {
            droppedXMP = true
        }
        i += chunkLen
    }
    guard sawChunk else { return bytes }
    if let flagOffset = vp8xFlagOffset {
        var flags = out[flagOffset]
        if droppedEXIF { flags &= ~0x08 }
        if droppedXMP { flags &= ~0x04 }
        out[flagOffset] = flags
    }
    let newSize = UInt32(out.count - 8)
    out[4] = UInt8(newSize & 0xFF)
    out[5] = UInt8((newSize >> 8) & 0xFF)
    out[6] = UInt8((newSize >> 16) & 0xFF)
    out[7] = UInt8((newSize >> 24) & 0xFF)
    return out
}

func exifJPEGMarkers(_ bytes: [UInt8]) -> [UInt8] {
    var markers: [UInt8] = []
    var i = 2
    while i + 1 < bytes.count {
        if bytes[i] != 0xFF { break }
        let marker = bytes[i + 1]
        if marker == 0xFF { i += 1; continue }
        markers.append(marker)
        if marker == 0xD9 { break }
        if marker == 0xDA { break }
        if bytes.count - i < 4 { break }
        let len = (Int(bytes[i + 2]) << 8) | Int(bytes[i + 3])
        if len < 2 || bytes.count - i < 2 + len { break }
        i += 2 + len
    }
    return markers
}

func exifPNGTypes(_ bytes: [UInt8]) -> [String] {
    var types: [String] = []
    var i = 8
    while i + 8 <= bytes.count {
        let len = (Int(bytes[i]) << 24) | (Int(bytes[i + 1]) << 16) | (Int(bytes[i + 2]) << 8) | Int(bytes[i + 3])
        let type = String(decoding: bytes[(i + 4)..<(i + 8)], as: UTF8.self)
        types.append(type)
        if len < 0 || bytes.count - i < 12 + len { break }
        if type == "IEND" { break }
        i += 12 + len
    }
    return types
}

func exifWebPTypes(_ bytes: [UInt8]) -> [String] {
    var types: [String] = []
    var i = 12
    while i + 8 <= bytes.count {
        let type = String(decoding: bytes[i..<(i + 4)], as: UTF8.self)
        let len = Int(bytes[i + 4]) | (Int(bytes[i + 5]) << 8) | (Int(bytes[i + 6]) << 16) | (Int(bytes[i + 7]) << 24)
        types.append(type)
        if len < 0 || bytes.count - i < 8 + len { break }
        i += 8 + len + (len % 2)
    }
    return types
}

func exifPNGChunkPayload(_ bytes: [UInt8], _ want: String) -> [UInt8] {
    var i = 8
    while i + 8 <= bytes.count {
        let len = (Int(bytes[i]) << 24) | (Int(bytes[i + 1]) << 16) | (Int(bytes[i + 2]) << 8) | Int(bytes[i + 3])
        let type = String(decoding: bytes[(i + 4)..<(i + 8)], as: UTF8.self)
        if len < 0 || bytes.count - i < 12 + len { return [] }
        if type == want { return Array(bytes[(i + 8)..<(i + 8 + len)]) }
        if type == "IEND" { return [] }
        i += 12 + len
    }
    return []
}

func exifWebPChunkPayload(_ bytes: [UInt8], _ want: String) -> [UInt8] {
    var i = 12
    while i + 8 <= bytes.count {
        let type = String(decoding: bytes[i..<(i + 4)], as: UTF8.self)
        let len = Int(bytes[i + 4]) | (Int(bytes[i + 5]) << 8) | (Int(bytes[i + 6]) << 16) | (Int(bytes[i + 7]) << 24)
        if len < 0 || bytes.count - i < 8 + len { return [] }
        if type == want { return Array(bytes[(i + 8)..<(i + 8 + len)]) }
        i += 8 + len + (len % 2)
    }
    return []
}

func exifContains(_ bytes: [UInt8], _ needle: [UInt8]) -> Bool {
    if needle.count == 0 || bytes.count < needle.count { return false }
    var i = 0
    while i + needle.count <= bytes.count {
        var match = true
        var k = 0
        while k < needle.count {
            if bytes[i + k] != needle[k] { match = false; break }
            k += 1
        }
        if match { return true }
        i += 1
    }
    return false
}

func exifJPEGScan(_ bytes: [UInt8]) -> [UInt8] {
    var i = 2
    while i + 1 < bytes.count {
        if bytes[i] != 0xFF { return [] }
        let marker = bytes[i + 1]
        if marker == 0xD9 { return [] }
        if marker == 0xDA {
            let len = (Int(bytes[i + 2]) << 8) | Int(bytes[i + 3])
            let start = i + 2 + len
            var j = start
            while j + 1 < bytes.count {
                if bytes[j] == 0xFF && bytes[j + 1] == 0xD9 { return Array(bytes[start..<j]) }
                j += 1
            }
            return []
        }
        let len = (Int(bytes[i + 2]) << 8) | Int(bytes[i + 3])
        i += 2 + len
    }
    return []
}

// [P2-1] Gate routing table, mirroring `exportableImageData`'s branches:
// undecodable -> nil, strippable + orientation up -> byte strip,
// anything else -> re-encode. The UIImage decode / render itself is
// not executable here; the string pins below tie the table to the
// real function.
func exifGateRoute(strippable: Bool, orientationUp: Bool, decodable: Bool) -> String {
    if !decodable { return "nil" }
    if strippable && orientationUp { return "strip" }
    return "reencode"
}

// [P3-2] Migration re-read guard, mirroring the decision in
// `migrateThemeImageMetadata` / `migrateLibraryPackMetadata`: write
// only when the file on disk is still the bytes that were read, and
// only when cleaning actually changed something. No reachable case
// for the residual microsecond TOCTOU window was proven, so no code
// change rides with this test — it pins the guard that bounds it.
func exifMigrationShouldWrite(original: [UInt8], current: [UInt8], clean: [UInt8]) -> Bool {
    if clean == original { return false }
    return current == original
}

// Corpora: Pillow-made 24x16 images (see /tmp/exif_gate_mirror.py).
// JPEG carries a GPS EXIF APP1 + COM + APP13 and trailing garbage after
// EOI (including a fake EOI + fake APP1 inside the garbage). PNG carries
// eXIf + tEXt + tIME and trailing garbage after IEND. WebP carries EXIF
// + XMP chunks and trailing garbage.
let jpegTrailB64 = "/9j/7QAaUGhvdG9zaG9wIDMuMAA4QklNBAQAAAAA//4ACGhlbGxvIf/hAIhFeGlmAABJSSoACAAAAAEAJYgEAAEAAAAaAAAAAAAAAAQAAQACAAIAAABOAAAAAgAFAAMAAABQAAAAAwACAAIAAABFAAAABAAFAAMAAABoAAAAAAAAACUAAAABAAAALgAAAAEAAAAeAAAAAQAAAHoAAAABAAAACgAAAAEAAAAAAAAAAQAAAP/gABBKRklGAAEBAAABAAEAAP/bAEMABgQFBgUEBgYFBgcHBggKEAoKCQkKFA4PDBAXFBgYFxQWFhodJR8aGyMcFhYgLCAjJicpKikZHy0wLSgwJSgpKP/bAEMBBwcHCggKEwoKEygaFhooKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKP/AABEIABAAGAMBIgACEQEDEQH/xAAfAAABBQEBAQEBAQAAAAAAAAAAAQIDBAUGBwgJCgv/xAC1EAACAQMDAgQDBQUEBAAAAX0BAgMABBEFEiExQQYTUWEHInEUMoGRoQgjQrHBFVLR8CQzYnKCCQoWFxgZGiUmJygpKjQ1Njc4OTpDREVGR0hJSlNUVVZXWFlaY2RlZmdoaWpzdHV2d3h5eoOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4eLj5OXm5+jp6vHy8/T19vf4+fr/xAAfAQADAQEBAQEBAQEBAAAAAAAAAQIDBAUGBwgJCgv/xAC1EQACAQIEBAMEBwUEBAABAncAAQIDEQQFITEGEkFRB2FxEyIygQgUQpGhscEJIzNS8BVictEKFiQ04SXxFxgZGiYnKCkqNTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqCg4SFhoeIiYqSk5SVlpeYmZqio6Slpqeoqaqys7S1tre4ubrCw8TFxsfIycrS09TV1tfY2dri4+Tl5ufo6ery8/T19vf4+fr/2gAMAwEAAhEDEQA/APGtM8MdP3f6V1emeGOnyfpXpGmeGOnyfpXV6Z4Y6fu/0rPDYs8fJeKNvePONM8MdPk/SivcbDw2sab3UBR1JFFd9TOsLhbRr1Yxb7yS/Nn6hguJpSpKzP/Z3q2+70V4aWYAAEZBS0VHUFP/2f/hAIhFeGlmAABJSSoACAAAAAEAJYgEAAEAAAAaAAAAAAAAAAQAAQACAAIAAABOAAAAAgAFAAMAAABQAAAAAwACAAIAAABFAAAABAAFAAMAAABoAAAAAAAAACUAAAABAAAALgAAAAEAAAAeAAAAAQAAAHoAAAABAAAACgAAAAEAAAAAAAAAAQAAAA=="
let pngTrailB64 = "iVBORw0KGgoAAAANSUhEUgAAABgAAAAQCAIAAACDRijCAAAAB3RJTUUH6gsMFwAAX2SpGAAAAA10RVh0Q29tbWVudABoZWxsb+b/riQAAAAkZVhJZk1NACoAAAAIAAEBDwACAAAACQAAABoAAAAAVGVzdE1ha2UAAJV/N/MAAAAiSURBVHicY2RgYOBmYKccsTAIsjMwUAGNGjRq0KhBI9UgAP7gDLMpXKBlAAAAAElFTkSuQmCCR0FSQkFHRWVYSWZGQUtF"
let webpTrailB64 = "UklGRkQBAABXRUJQVlA4WAoAAAAMAAAAFwAADwAAVlA4IIAAAABQBACdASoYABAAPm0qkUWkIqGYBABABsS2AE6ZQjgb0B8AAKAcQt8Aqf7AAP7/oaztw4nG5MpE9oH2VqpvuHen7YWO82lGJzi95IMe8xzWncLzD+YlxUP1figBg4Zh5pDR6ynJhDd6/yfr9jAO3a6D9I/xgW/4L4kltpB11R8AAEVYSUYkAAAATU0AKgAAAAgAAQEPAAIAAAAJAAAAGgAAAABUZXN0TWFrZQAAWE1QIHIAAAA8eDp4bXBtZXRhIHhtbG5zOng9ImFkb2JlOm5zOm1ldGEvIj48cmRmOlJERiB4bWxuczpyZGY9Imh0dHA6Ly93d3cudzMub3JnLzE5OTkvMDIvMjItcmRmLXN5bnRheC1ucyMiLz48L3g6eG1wbWV0YT4BAgNFWElGRkFLRQ=="

let jpegTrail = [UInt8](Data(base64Encoded: jpegTrailB64) ?? Data())
let pngTrail = [UInt8](Data(base64Encoded: pngTrailB64) ?? Data())
let webpTrail = [UInt8](Data(base64Encoded: webpTrailB64) ?? Data())

let jpegStripped = exifStripJPEG(jpegTrail)
check("P2-1: JPEG strip drops APP1/COM/APP13 and trailing garbage (golden length 712)", jpegStripped.count == 712)
check("P2-1: JPEG stripped ends exactly at EOI", jpegStripped.count >= 2 && jpegStripped[jpegStripped.count - 2] == 0xFF && jpegStripped[jpegStripped.count - 1] == 0xD9)
check("P2-1: JPEG stripped has no APP1/COM/APP13 segment left", !exifJPEGMarkers(jpegStripped).contains(0xE1) && !exifJPEGMarkers(jpegStripped).contains(0xED) && !exifJPEGMarkers(jpegStripped).contains(0xFE))
check("P2-1: JPEG corpus did carry APP1/COM/APP13 to drop", exifJPEGMarkers(jpegTrail).contains(0xE1) && exifJPEGMarkers(jpegTrail).contains(0xED) && exifJPEGMarkers(jpegTrail).contains(0xFE))
check("P2-1: JPEG scan data is byte-identical after strip", exifJPEGScan(jpegStripped) == exifJPEGScan(jpegTrail))
check("P2-1: JPEG stripped has no trailing garbage bytes", !exifContains(jpegStripped, [0xDE, 0xAD, 0xBE, 0xEF]))
check("P2-1: JPEG clean input passes through unchanged", exifStripJPEG(Array(jpegStripped)) == jpegStripped)
check("P2-1: JPEG truncated scan returns original bytes", exifStripJPEG(Array(jpegStripped.dropLast(5))) == Array(jpegStripped.dropLast(5)))

let pngStripped = exifStripPNG(pngTrail)
check("P3-5: PNG strip drops eXIf/tEXt/tIME (golden length 91)", pngStripped.count == 91)
check("P3-5: PNG stripped keeps IDAT and ends at IEND", exifPNGTypes(pngStripped).contains("IDAT") && exifPNGTypes(pngStripped).last == "IEND")
check("P3-5: PNG stripped has no eXIf/tEXt/tIME left", !exifPNGTypes(pngStripped).contains("eXIf") && !exifPNGTypes(pngStripped).contains("tEXt") && !exifPNGTypes(pngStripped).contains("tIME"))
check("P3-5: PNG corpus did carry eXIf/tEXt/tIME to drop", exifPNGTypes(pngTrail).contains("eXIf") && exifPNGTypes(pngTrail).contains("tEXt") && exifPNGTypes(pngTrail).contains("tIME"))
check("P3-5: PNG IDAT payload is byte-identical after strip", exifPNGChunkPayload(pngStripped, "IDAT") == exifPNGChunkPayload(pngTrail, "IDAT"))

let webpStripped = exifStripWebP(webpTrail)
check("P2-1: WebP strip drops EXIF/XMP and trailing garbage (golden length 166)", webpStripped.count == 166)
check("P2-1: WebP stripped has no EXIF/XMP chunk left", !exifWebPTypes(webpStripped).contains("EXIF") && !exifWebPTypes(webpStripped).contains("XMP "))
check("P2-1: WebP corpus did carry EXIF/XMP to drop", exifWebPTypes(webpTrail).contains("EXIF") && exifWebPTypes(webpTrail).contains("XMP "))
check("P2-1: WebP RIFF size matches stripped length", webpStripped.count >= 8 && Int(webpStripped[4]) | (Int(webpStripped[5]) << 8) | (Int(webpStripped[6]) << 16) | (Int(webpStripped[7]) << 24) == webpStripped.count - 8)
check("P2-1: WebP VP8 payload is byte-identical after strip", exifWebPChunkPayload(webpStripped, "VP8 ") == exifWebPChunkPayload(webpTrail, "VP8 "))

// Walker fallback invariants: a truncated chunk before any image data
// returns the original bytes — and the gate (routing table below) turns
// those undecodable bytes into nil, so they never land.
let pngSig: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
let pngIHDR: [UInt8] = [0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52, 0, 0, 0, 24, 0, 0, 0, 16, 8, 2, 0, 0, 0, 0, 0, 0, 0]
let pngTruncExif: [UInt8] = pngSig + pngIHDR + [0, 0, 1, 244, 0x65, 0x58, 0x49, 0x66] + [UInt8](repeating: 0, count: 10)
check("P2-2: truncated eXIf before IDAT returns original bytes", exifStripPNG(pngTruncExif) == pngTruncExif)
let pngTruncIDAT: [UInt8] = pngSig + pngIHDR + [0, 0, 0, 4, 0x49, 0x44, 0x41, 0x54, 1, 2, 3, 4, 0, 0, 0, 0] + [0, 1, 0x86, 0xA0, 0x49, 0x44, 0x41, 0x54] + [UInt8](repeating: 0, count: 20)
check("P2-2: truncated 2nd IDAT returns original bytes", exifStripPNG(pngTruncIDAT) == pngTruncIDAT)
let webpNoPad: [UInt8] = [0x52, 0x49, 0x46, 0x46, 30, 0, 0, 0, 0x57, 0x45, 0x42, 0x50, 0x56, 0x50, 0x38, 0x58, 10, 0, 0, 0, 0x18, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x56, 0x50, 0x38, 0x20, 5, 0, 0, 0, 1, 2, 3, 4, 5]
check("P2-2: VP8 chunk missing its pad byte returns original bytes", exifStripWebP(webpNoPad) == webpNoPad)

check("P2-2: gate routes orientation-up strippable to strip", exifGateRoute(strippable: true, orientationUp: true, decodable: true) == "strip")
check("P2-2: gate routes orientation!=up to re-encode", exifGateRoute(strippable: true, orientationUp: false, decodable: true) == "reencode")
check("P2-2: gate routes HEIC/GIF to re-encode", exifGateRoute(strippable: false, orientationUp: true, decodable: true) == "reencode")
check("P2-2: gate returns nil for undecodable bytes", exifGateRoute(strippable: true, orientationUp: true, decodable: false) == "nil")
check("P2-2: gate returns nil for undecodable strippable bytes (no strip fallback)", exifGateRoute(strippable: true, orientationUp: false, decodable: false) == "nil")
check("P3-2: migration writes when disk still holds the read bytes and cleaning changed something", exifMigrationShouldWrite(original: [1, 2, 3], current: [1, 2, 3], clean: [1, 2, 9]))
check("P3-2: migration skips when a picker swapped the file mid-flight", !exifMigrationShouldWrite(original: [1, 2, 3], current: [4, 5, 6], clean: [1, 2, 9]))
check("P3-2: migration skips when cleaning changed nothing", !exifMigrationShouldWrite(original: [1, 2, 3], current: [1, 2, 3], clean: [1, 2, 3]))

// String pins: the table above only means something if the real
// functions have the same shape.
check("P2-2: exportableImageData returns nil for undecodable bytes",
      studio.contains("guard let image = UIImage(data: data),")
      && studio.contains("image.size.width > 0, image.size.height > 0 else { return nil }"))
check("P2-1: JPEG walker scans to EOI instead of copying to end of file",
      studio.contains("if next == 0xD9 { // EOI: copy through it, drop the rest"))
check("P3-5: PNG walker drops tIME alongside the text chunks",
      studio.contains("typeString != \"tIME\""))
check("P3-2: migration re-reads before writing (TOCTOU guard)",
      studio.contains("guard let current = try? Data(contentsOf: url), current == data else { continue }"))
check("P1-1: pack-JSON cleaner enumerates the image base64 fields",
      pack.contains("cleanField(\"wallpaperJPEGBase64\", dark: false)")
      && pack.contains("cleanField(\"wallpaperDarkJPEGBase64\", dark: true)")
      && pack.contains("cleanMap(\"categoryImages\", dark: false)")
      && pack.contains("cleanMap(\"pageWallpapers\", dark: false)"))
check("P1-1: launch migration also covers library packs",
      studio.contains("func migrateLibraryPackMetadata(lightCanvasHex: String, darkCanvasHex: String)"))
check("P3-4: failed category-image write clears the marker instead of leaving raw base64",
      pack.contains("pack.categoryImages[key] = \"\""))
check("P3-4: image-less export omits category images",
      pack.contains("pack.categoryImages = [:]"))
check("P3-8: IfDecodable decodes once and hands the image to the overload",
      pack.contains("writeEncodedImage(decoded: image, data, to: url, maxEdge: maxEdge, quality: quality, matte: matte)"))
check("P3-6: stale icon task drops its result before writing",
      studio.contains("guard generation == Self.currentIconGeneration(for: id) else { return nil }"))

// [T-39] Backend APIs remain; UI wiring is intentionally pending a user-approved redesign.
check("backend retains user avatar setter", studio.contains("func setUserAvatar"))
check("backend retains character-art API", pack.contains("func setCharacterArtImage"))
check("backend retains icon setter", studio.contains("func setIcon"))
check("backend retains icon removal", studio.contains("func removeIcon"))

if failures == 0 {
    print("\nALL PASS")
    exit(0)
} else {
    print("\nFAILED \(failures)")
    exit(1)
}
