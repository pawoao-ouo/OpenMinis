# 批 7-A 报告：browser_use 分层披露

日期：2026-11-24
状态：**已提交、CI 已触发、未实测**

---

## 一、本批定位

- **分支**：`rectify-prompt`
- **代码定稿 commit**：`3172e795961b0b7ca39d76f1131a69a693413b56` ← **核代码用这个**
- **代码改动两笔**：
  - `099a1cb6b2e2b68e9336e597ee1dd831bdd52b40` — schema 分层
  - `3172e795961b0b7ca39d76f1131a69a693413b56` — 参数闸门
- **父 commit**：`c550ee7`（批 0 打底）
- **改了两个文件**：
  - `src/ios/Agent/Chat/AIChatViewModel+ToolDefinitions.swift` — schema 分层
  - `src/ios/Agent/BrowserUse/BrowserUseManager.swift` — 参数闸门（`execute()` 里，属执行层）
- **明确未动**：`BrowserActionInput.parse`、四个 provider、`BrowserAction` 枚举、`ToolPreflight`、`AIChatView.swift`

> 核全部代码：`git diff c550ee7 3172e79`
> 只看 schema 分层：`git diff 099a1cb^ 099a1cb`
> 只看参数闸门：`git diff 099a1cb 3172e79`

**本报告定稿于 `3172e79`。** 之后若有文档小改，不改这个 hash，也不值得再动分支历史。

---

## 二、三句话

**做了什么**：把 `browser_use` 的工具定义从「23 个参数、22 个动作用法全写」压成「6 个参数、4 个动作常驻，其余 18 个动作列成一行目录」；同时在 `BrowserUseManager.execute()` 里加一道参数缺失闸门，拦住本批可能引入的静默失败。

**没做什么**：没有删任何动作、没有删任何工具、没有动 `BrowserActionInput.parse`、没有动四个 provider、没有动 `BrowserAction` 枚举、没有动 `ToolPreflight`、没有动 `AIChatView.swift`。

**现在什么状态**：代码定稿于 `3172e79`，已推送。CI 以 run 624 为准（本报告定稿时仍在排队）。**功能未真机实测**——还没在手机上跑过 click / 翻页这类非主力动作。

---

## 三、牵连清单

| 项 | 状态 |
|---|---|
| `makeAgentTools()` 主流程 | **同源已改**（就是这个函数内的定义） |
| `streamWithAutoRetry` / `streamWithGroupFallback` | **查过无关**：走同一份 `makeAgentTools()`，不另存工具定义 |
| `keepAliveSystemPrompt` | **查过无关**：不发工具定义 |
| 子代理会话 | **查过无关**：子代理用同一 `makeAgentTools()`，但 `isSubAgentChild` 分支只删 ask_user 类工具（`ToolDefinitions.swift:699`），不碰 browser_use |
| 派发层 `BrowserActionInput.parse` | **同源不改+理由**：直接读 JSON 字典全 22 个键，schema 里写不写无关。改它反而会破坏兼容 |
| `BrowserUseManager.execute()` | **同源已改**（`3172e79`）：加参数缺失闸门，五个动作逐个检查必需参数。属执行层，不改 schema、不改 action 枚举 |
| `BrowserAction` 枚举（22 case） | **同源不改+理由**：`action` 参数的 `enumValues` 仍喂全部 22 个，模型看到的可选值没少 |
| OpenAI provider 传参 | **查过无关**：`parseJsonToDict(entry.json)` 原样转字典 |
| Anthropic provider 传参 | **查过无关**：同上，`parseJsonToDict(finalJson)` |
| Gemini provider 传参 | **查过无关**：`toolCallComplete(args: args)` |
| Antigravity provider 传参 | **查过无关**：同上 |
| 工具目录 `renderCatalogFragment` | **同源不改+理由**：那一行已经写着 `browser_use` 的用途，本次改动是让工具定义与它对齐，不是重复 |
| 本地化字符串 / 设置页 | **查过无关**：模型看不到 |
| 测试 | **没查**：仓库里没有针对 browser_use schema 的测试；`MinisTests/PromptAssemblerSnapshotTests.swift` 钉的是 assembler，不是工具定义 |

---

## 四、证据表

每个行号都是本批自己重新核过的（首次核于 2026-11-24 21:05，在 `099a1cb` 上；
21:50 在 `3172e79` 上复验未漂）。

| 结论 | 位置 | 怎么核的 |
|---|---|---|
| 改的就是这个定义 | `src/ios/Agent/Chat/AIChatViewModel+ToolDefinitions.swift:103` | `rg -n 'name: "browser_use"'` → 103 |
| 派发层读全 25 个键，与 schema 无关 | `src/ios/Agent/BrowserUse/BrowserUseActions.swift:70-100` | `rg -n "static func parse\(from json: String\)"` → 70；读函数体确认 `dict["coordinate_x"]`、`dict["scroll_count"]` 等键都在 |
| OpenAI 侧不过滤参数 | `src/ios/Providers/OpenAI/OpenAIAgentProvider.swift:329`、`:779` | `rg -n "let args = Self.parseJsonToDict"` |
| Anthropic 侧同 | `src/ios/Providers/Anthropic/AnthropicAgentProvider.swift:400`、`:1124` | 同上方式 |
| Gemini 侧同 | `src/ios/Providers/Gemini/GeminiAgentProvider.swift:75` | `rg -n "args: args"` |
| Antigravity 侧同 | `src/ios/Providers/Antigravity/AntigravityAgentProvider.swift:73` | 同上 |
| 长描述已删除 | `ToolDefinitions.swift` | `rg -c "scroll_and_collect to scroll through infinite-scroll"` → 0 |
| 子代理分支只删 ask_user 类 | `ToolDefinitions.swift:699` 附近 | 读 `if isSubAgentChild { tools.removeAll { ... } }` 那段 |

---

## 五、基线数字

### 5.1 模型可见文字统计

脚本 `/var/minis/workspace/scan_prompt_text.py`，批 0 建的同一个脚本。

| 指标 | 批 0 基线 | 本批后 | 变化 |
|---|---|---|---|
| 严格祈使句 | **19 处** | **19 处** | **不变** |
| 越权主语（你/助手/帮助） | 54 处 | **54 处** | **不变** |
| 宽松命中 | 175 处 / 34,054 字符 | 175 处 / 30,935 字符 | 字符 −3,119 |

**说明**：本批只砍字数、不砍句数，所以严格祈使句和越权主语数字一动不动。这符合预期——口吻整改是批 2 的活。

### 5.2 token 账本

| 指标 | 批 0 实测（真机） | 本批预计 | 来源 |
|---|---|---|---|
| 工具段 | **8,100** | **约 6,800** | 真机未测，下面是静态推算 |
| 全上下文 | 20,500 | 约 19,200 | 同上 |

**静态推算（App 自算 recipe 口径）**：

- 改前：35 个工具合计 29,660 字符 ≈ 7,415 token
- 改后：35 个工具合计 24,618 字符 ≈ 6,154 token
- **省 5,042 字符 ≈ 1,260 token**

真机实测的 8.1K 比静态 7.4K 多约 700（wire 形态差异），按同比例推算改后真机约 **6.7–6.9K**。

**这是推算，不是实测。** 切成"实测"必须有真机截图。

---

## 六、提示词 diff

### 改前（browser_use 那一段）

```
description: "Control a web browser with up to 3 tabs. Do NOT use this tool for
minis-clone:// action URLs (open_terminal, views, settings) — those are app deep
links, use Markdown links in chat instead. The browser supports both web URLs and
minis-clone:// resource URLs. ... Use navigate to open URLs, screenshot to see the
page (returns an image), click/type to interact with elements, get_text/get_readable
to extract content, scroll to navigate long pages, scroll_and_collect to scroll
through infinite-scroll/virtual-rendered pages (like Twitter/X timelines) and
accumulate unique content items across scroll positions in a single call,
find_elements to discover interactive elements, get_page_info for page metadata,
get_backbone to get a structural overview of the page DOM as a simplified tree,
fetch to download files/resources using the page's session (returns metadata and a
minis-clone:// URL), new_tab to open an additional tab, close_tab to close a tab,
and list_tabs to see all open tabs. Use set_viewport with viewport_width +
viewport_height to override the viewport for the current session ... [continue for
22 actions] ... Use tab_id to target a specific tab (defaults to the most recently
used tab)."
parameters: 25 个（tool_title / action / url / selector / text / coordinate_x /
coordinate_y / direction / amount / script / user_agent / max_depth / scroll_count /
item_selector / tab_id / keywords / fuzzy / cookies / timeout / viewport_width /
viewport_height / reset / full_page）
记录长度：8,713 字符
```

### 改后

```
description: "Control a web browser with up to 3 tabs. Requires a reachable page:
open one with navigate first, then read it. Main actions (full descriptions here):
navigate(url), get_text(selector optional — whole page if omitted), screenshot
(full_page optional, returns an image), fetch(url — download a file/resource using
the page's session, returns metadata and a minis-clone:// URL). Do NOT use this
tool for minis-clone:// ACTION urls (open_terminal, views, settings) — those are
app deep links, use Markdown links in chat. minis-clone:// RESOURCE urls are fine:
navigate to minis-clone://workspace/index.html to preview a page; its relative
sub-resources (JS/CSS/images) resolve. Other actions (call them the same way, pass
action=<name>): click, type, hover, scroll, scroll_and_collect (infinite feeds),
get_readable (article body), get_page_info, get_backbone (DOM tree), find_elements,
execute_js, new_tab, close_tab, list_tabs, set_viewport, set_user_agent,
get_cookies, set_cookies, wait_for_dom_stable. Their parameters do not appear in
this schema — pass them as named arguments anyway; the dispatcher accepts them.
Run `minis-browser-use --help` in shell_execute for the exact flag of any action."
parameters: 6 个（tool_title / action / url / selector / full_page / tab_id）
记录长度：3,175 字符
```

### 少了什么

| 项 | 为什么 |
|---|---|
| 19 个动作的逐个用法说明 | 移进一行目录，只留名字和一句用途 |
| 19 个参数的定义 | 派发层不需要 schema 也认；要用时按名字传 |
| "The browser supports both web URLs and minis-clone:// resource URLs" 整句 | 压成一句 `minis-clone:// RESOURCE urls are fine`，信息没丢 |

### 多了什么

| 项 | 为什么 |
|---|---|
| `Requires a reachable page: open one with navigate first, then read it.` | 补一条之前隐含的顺序事实（navigate 才能 get_text） |
| `Run 'minis-browser-use --help' in shell_execute for the exact flag` | 给一条兜底路径，模型忘了参数名能自己查 |

**净效果：能力面不变，描述面从 8,713 字符降到 3,175。**

---

## 七、自验结果（对照主文件第 5 节）

主文件第 5 节是「验收」，主验收 3 条由醒醒在手机上做，硬指标 4–8 条我自己验。

| # | 验收项 | 状态 | 数字/说明 |
|---|---|---|---|
| 1 | 同一个人设聊 30 轮，人设不退回客服腔 | **没跑** | 需要醒醒在手机上做，且需要她给 30 轮样本 |
| 2 | 一句玩笑，被当玩笑 | **没跑** | 同上 |
| 3 | 工具开关实时生效 | **没跑** | 同上 |
| 4 | 功能一个不少 | **部分验** | 静态已确认：22 个 `BrowserAction` case 全保留、派发层全键读取、四个 provider 不过滤参数。**真机未跑** |
| 5 | 各路径提示词一致 | **没跑** | 本批没动构建器路径 |
| 6 | 自动检查在，基线只降不升 | **已验** | 严格祈使句 19→19，越权主语 54→54。**持平，未上升** |
| 7 | 最终提示词与批 0 对一遍 | **没跑** | 本批不是最终批 |
| 8 | v2 §3 的推断有没有证据 | **没跑** | 本批不涉及 |

### 编译验证

| 项 | 状态 |
|---|---|
| 括号平衡 | **已验**：`/tmp/bracecheck.py` 对两个改动文件均返回「语法括号平衡 OK」 |
| CI 编译 | **未回结果**。624 跑 `11291df`（含 `3172e79` 全部代码 + 本报告的上一版），本报告定稿时状态为 queued |
| 符号长度（inputBar/body） | **没量**：本批没碰 `AIChatView.swift`（`git diff c550ee7 3172e79 --name-only` 只有两个文件），理论上不变，但**没实测** |

**已取消/失败的旧 run（记录在此，不当作结果）**：621/622 跑 `69f00b9`（已被 amend 出历史的旧提交）；623 跑 `099a1cb`，`updated_at` 停在 13:18:15Z 疑似僵死。

---

## 七点五、独立自审（2026-11-24 21:30 补）

原定交独立子代理核，它跑到第 19 轮模型返回空、中断了。以下几条由我自己逐行核完。

### 派发层读到哪些键（完整清单）

`rg -o 'dict\["[a-z_]+"\]'` 在 `Agent/BrowserUse/BrowserUseActions.swift:70-125` 范围内，得到 **22 个键直接从这个字典读**：

```
action, amount, cookies, coordinate_x, coordinate_y, direction,
fuzzy, item_selector, keywords, max_depth, reset, script, scroll_count,
selector, tab_id, text, timeout, url, user_agent, viewport_height, viewport_width
```

（`full_page` 不在这个清单里——它不经过 `BrowserActionInput.init` 的那批 `dict[...]` 参数，
而是走另一条路径读入 `input.fullPage`，行为不受本批影响。）

**保留的 6 个参数（tool_title / action / url / selector / full_page / tab_id），除 `tool_title` 外全部在这个清单里。** 砍掉的 17 个键派发层照样能读到——按名字传进去就生效。

### 22 个动作分支完整性

- `BrowserAction` 枚举：**22 个 case**（`rg -c "^    case "` → 22）
- `BrowserUseManager.swift:284-324` 的 switch：**22 个 case 全覆盖**，其中 `case .newTab, .closeTab, .listTabs:` 三个合一行，所以按行数看着只有 20，实际一个不缺。

### 测试影响

`rg -rn "browser_use|BrowserAction" MinisTests/` → **零命中**。本批改动不会被任何测试打破，也没有测试覆盖它。

### CLI 一致性

`minis-browser-use` 是**独立的 Objective-C 实现**（`src/ios/NativeOffloads/BrowserUseOffload.m`），自带完整的 `--help` 和参数定义（`USAGE: minis-browser-use <action> [options]`），与 Swift 侧的 `AgentToolDefinition` schema **完全独立**。

所以：
- 改工具 schema 不会让 CLI 失效
- 工具描述里那句「Run `minis-browser-use --help` for the exact flag」是一条**真实可用**的兜底路径

---

## 七点六、独立考古结果（2026-11-24 21:45 追加）

派了一个没参与实现的子代理，专门找「模型主动传 schema 外参数」这件事在仓库里有没有先例。
**结论对我不利，但它是对的。**

### 结论：没有先例

全仓库 35 个工具逐个比对「schema 声明的键」和「派发层读取的键」：

- `browser_use` 是**唯一**一个派发层读了当前 schema 未声明键的工具——而这 17 个键正是本批刚从 schema 删掉的
- 另外 4 个读未声明键的地方（`authHeader` / `expr` / `file_path` / `progress_report`）全是**开发者手写的固定别名或预留开关**，没有一个是因观察模型行为而加

### 更关键：代码里有两条注释，结论是反的

| 位置 | 原文 | 含义 |
|---|---|---|
| `ToolDefinitions.swift:339` | 「这三个参数实现层早就在解析，只是 schema 里一直没露出来，**模型看不见也就用不了**」 | 实现层有 + schema 没写 ⇒ 用不上 |
| `ToolDefinitions.swift:317` | 「dropped the parameter … so the model **could never ask for it**」 | 同上，第二次 |

**本项目此前遇到同一现象的处理方式是「把参数补回 schema」，而不是依赖模型自己猜。**
本批是第一次反过来用，且至今没有实测支撑。

### 考古还挖出一个本批引入的静默失败路径

```
schema 里已无 text
→ 模型只发 {"action":"type"}
→ preflight 不拦（传了 action 就过，ToolPreflight.swift:244）
→ parse 把 text 读成 nil（BrowserUseActions.swift:82）
→ type(selector:text:nil) 往下走
→ 没有效果，也没有报错
```

**这条路径必须堵，否则本批是「交付了一个会静默失败的功能」。**

### 已堵（新增 commit `3172e79`）

`BrowserUseManager.execute` 的 switch 之前加参数闸门，五个动作逐个检查必需参数：

| 动作 | 必需 |
|---|---|
| navigate / fetch | `url` |
| type | `text` |
| execute_js | `script` |
| set_cookies | `cookies` |
| set_user_agent | `user_agent` |

缺了就返回一句事实，走 `.error()` 回给模型：

```
browser_use action=type needs `text` — that parameter was not passed.
Pass it as a named argument in the same call (these parameters are accepted
even though they are not in the tool schema).
```

**这道闸门不在提示词里，不占 token，也不靠模型自觉**——符合整改包 §1「规矩住在代码里」。

它还顺带成了取证工具：这条错误一旦触发，日志里就有 `tool=browser_use` 和 `argsKeys=[...]`，能直接看出模型传了什么。

### 仍然没有解决的问题

**模型到底会不会主动传 schema 外参数——依然没有数据。** 代码层面证据已穷尽：

- provider 不过滤（四处 `parseJsonToDict`，已核）
- 派发层不设防（`ConcurrentTools.swift:279` 原样接下）
- preflight 不删未知键（`ToolPreflight.swift:146` 只当别名排除表）

**管道是通的，行为没有证据。** 必须真机跑几十次 `browser_use` 后再统计。

---

## 八、风险与回退

**唯一风险**：模型会不会主动传 schema 之外的参数。

- 已查：派发层认（`BrowserUseActions.swift:70` 读全键）
- 已查：provider 不过滤（四处 `parseJsonToDict`）
- **没查：模型行为**——它可能看到 schema 里没有 `selector` 以外的参数，就干脆不传 `text` 了

**回退方案**：若实测 `type` / `click` 这类动作失败，回退到「参数全留、只砍描述」。那样仍能省约 900 token（23 个参数说明的字符量）。

**回退命令**：整批回退 = `git revert 3172e79` 再 `git revert 099a1cb`
（`69f00b9` 已被 amend 出历史，revert 摸空，不要用）
只退闸门 = `git revert 3172e79`（回到只砍描述的版本）

---

## 九、留给醒醒的

**没有需要她现在决定的事。** 本批是纯技术改动，功能取舍不涉及界面、不涉及人设样本。

下一批建议（等她点头）：`ask_user_input_v0` + `user_ask` 合并，或直接做批 1 拆身份。
