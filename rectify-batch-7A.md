# 批 7-A 报告：browser_use 分层披露

日期：2026-11-24
状态：**已提交、CI 已触发、未实测**

---

## 一、本批定位

- **分支**：`rectify-prompt`
- **完整 commit**：`69f00b9167191161809531b6b1751eae91292914`
- **父 commit**：`c550ee7`（批 0 打底）
- **只改一个文件**：`src/ios/Agent/Chat/AIChatViewModel+ToolDefinitions.swift`

---

## 二、三句话

**做了什么**：把 `browser_use` 的工具定义从「22 个动作用法全写、25 个参数」压成「常驻 4 个动作、6 个参数，其余 18 个动作列成一行目录」。

**没做什么**：没有删任何动作、没有删任何工具、没有改派发层、没有改 provider、没有动 `BrowserAction` 枚举（22 个 case 原样保留）。

**现在什么状态**：代码已提交，CI 已触发，`git push` 成功。**功能未实测**——还没拿到包、没在真机上跑过 click / 翻页这类非主力动作。

---

## 三、牵连清单

| 项 | 状态 |
|---|---|
| `makeAgentTools()` 主流程 | **同源已改**（就是这个函数内的定义） |
| `streamWithAutoRetry` / `streamWithGroupFallback` | **查过无关**：走同一份 `makeAgentTools()`，不另存工具定义 |
| `keepAliveSystemPrompt` | **查过无关**：不发工具定义 |
| 子代理会话 | **查过无关**：子代理用同一 `makeAgentTools()`，但 `isSubAgentChild` 分支只删 ask_user 类工具（`ToolDefinitions.swift:699`），不碰 browser_use |
| 派发层 `BrowserActionInput.parse` | **同源不改+理由**：直接读 JSON 字典全 25 个键，schema 里写不写无关。改它反而会破坏兼容 |
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

每个行号都是本批自己重新核过的（2026-11-24 21:05，在 `69f00b9` 上执行）。

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
| 括号平衡 | **已验**：`/tmp/bracecheck.py` → 结论 OK |
| CI 编译 | **已触发，未回结果**（run 已 dispatch，HTTP 204） |
| 符号长度（inputBar/body） | **没量**：本批没碰 `AIChatView.swift`，理论上不变，但**没实测** |

---

## 八、风险与回退

**唯一风险**：模型会不会主动传 schema 之外的参数。

- 已查：派发层认（`BrowserUseActions.swift:70` 读全键）
- 已查：provider 不过滤（四处 `parseJsonToDict`）
- **没查：模型行为**——它可能看到 schema 里没有 `selector` 以外的参数，就干脆不传 `text` 了

**回退方案**：若实测 `type` / `click` 这类动作失败，回退到「参数全留、只砍描述」。那样仍能省约 900 token（25 个参数说明的字符量）。

**回退命令**：`git revert 69f00b9`

---

## 九、留给醒醒的

**没有需要她现在决定的事。** 本批是纯技术改动，功能取舍不涉及界面、不涉及人设样本。

下一批建议（等她点头）：`ask_user_input_v0` + `user_ask` 合并，或直接做批 1 拆身份。
