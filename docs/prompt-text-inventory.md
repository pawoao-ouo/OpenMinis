# 模型可见文字 · 单一清单（批 0 建）

更新：2026-11-24
对应：整改包 §2.2
作用：**只给做事的人和以后的 AI 看，不进模型上下文，不做成系统提示。**

---

## 一、这些文字会进模型上下文

每一行的意思是「这里改了，模型看到的东西就变了」。改提示词之前先查这张表。

| # | 文字来源 | 位置 | 语言 | 谁负责 |
|---|---|---|---|---|
| 1 | 身份模板（含 `a capable AI assistant…`） | `Agent/Session/SoulStore.swift` · `identityTemplate` ≈1242 | 英 | SoulStore |
| 2 | SOUL 编辑说明 `soulEditHint` ≈3,590 字符 | `Agent/Session/SoulStore.swift` ≈1422 | 中 | SoulStore |
| 3 | SOUL 正文 + Personality 头 | 运行时文件 `memory/personas/<id>/SOUL.md` | 用户定 | 用户 |
| 4 | 用户档案段 `personas/me` | 运行时文件 | 用户定 | 用户 |
| 5 | 基础段：路由表 / 纪律 / 时间 / 目录 / 记忆 / 调度 / 默认 | `Agent/Chat/AIChatViewModel.swift` · `baseSystemPrompt` ≈1899–1996 | 英 | AIChatViewModel |
| 6 | 记忆状态段 `memoryStatusFragment` | 同上 ≈2010 | 英 | AIChatViewModel |
| 7 | 分段构建器 `buildTurnSystemPrompt` | 同上 ≈2031–2180 | 英 | AIChatViewModel |
| 7a | ├ capability 片段 | `Providers/LLMTypes.swift` ≈676 | 英 | LLMTypes |
| 7b | ├ behavior 片段 | `Providers/LLMTypes.swift` ≈710 | 英 | LLMTypes |
| 7c | ├ skills 目录（≤20 条） | `Agent/Session/SkillStore.swift` ≈1398 | 英 | SkillStore |
| 7d | ├ MCP 目录（≤20 条） | `Agent/Session/MCPStore.swift` ≈701 | 英 | MCPStore |
| 7e | ├ subagent 说明 + roster | `AIChatViewModel.swift` ≈2054 | 英 | AIChatViewModel |
| 7f | ├ TTS 常驻声明 / 纸条 | `Providers/Voice/TTSPaper.swift` ≈46 | 英 | TTSPaper |
| 7g | ├ 记忆注入 GLOBAL + 3×200 行 | `Agent/Chat/AIChatViewModel+MemoryTools.swift` ≈13–90 | 用户定 | MemoryTools |
| 7h | ├ 贴纸目录 | `StickerStore` | 中/英 | StickerStore |
| 7i | ├ 反馈规则 feedback-rules | `AIChatViewModel.swift` ≈2108 | 中 | AIChatViewModel |
| 7j | ├ 环境段 ambient | `Agent/Chat/AmbientContext.swift` ≈36 | 中 | AmbientContext |
| 7k | └ 进化段 evolution | `Agent/Evolution/EvolutionInjector.swift` ≈106 | 中 | EvolutionInjector |
| 8 | 工具定义（39 个 · 名称/描述/参数） | `Agent/Chat/AIChatViewModel+ToolDefinitions.swift` · `makeAgentTools()` | 英（少数中文） | ToolDefinitions |
| 9 | 工具返回里的报错与提示 | 各 handler | 中/英混 | 各 |
| 10 | user-role 的 system-reminder | `AIChatViewModel+Persistence.swift` ≈1737 等 | 英 | Persistence |
| 11 | 子代理委派前言（子会话第一层） | `AIChatViewModel+ProgrammaticPrompt.swift` | 英 | ProgrammaticPrompt |
| 12 | 非聊天路径：标题生成 / 压缩 / 块摘要 | `+TitleGeneration.swift` / `+Compaction.swift` / `+BlockSummary.swift` | 英 | 各 |
| 13 | 手册索引（正文按需读） | `Shared/UserManualMirror.swift` ≈45 / `Resources/user-manual.md` | 中 | UserManualMirror |
| 14 | 内置 steward 人设 | `Agent/Session/PersonaStore.swift:1234` | — | ⚠️ **偏离整合包**：包写「已定：保留」，实际已清成空 body 空名字（`ef2bdce`）。待醒醒定是否退回 |
| 15 | 图像生成 instructions | `Providers/OpenAI/OpenAIProvider.swift:1977` | 英 | ⚠️ **偏离整合包**：包写「报告位置，不动」，实际改成 `Use tools when available.`。待醒醒定 |

---

## 二、专项登记

### 2.1 Android

整改包 §7 已定：**跳过**。本清单只覆盖 iOS。不核位置，不补孪生。

### 2.2 语言归一

- 工具名 / 参数名 / 工具描述：一套英文。
- 中文工具描述现况：`add_mcp` 等少数几个，批 2 归一。
- 其余"说话"文字：同一类只用一种语言，默认跟人设语言。每项在第一节表里已标语言列。

### 2.3 界面文字不在范围内

本地化字符串、设置页、气泡角色名 —— 模型看不到，**不改**。

### 2.4 用户自己写的不动

SOUL 正文、用户档案，那是她的。

---

## 三、自动检查（批 0 建，§2.2）

**已进仓库，已接 CI。**

- 脚本：`scripts/prompt_audit.py`（跑法 `python3 scripts/prompt_audit.py`，退出码 0 通过）
- 基线：`scripts/prompt_imperative_baseline.json`（脚本首次运行时自动写，之后只许降不许升）
- CI：`.github/workflows/build-ios-ipa.yml` 的「Check standalone sources statically」步骤里，跟括号配平一起跑

它查五类事：

1. 路由表点名的工具，schema 里有没有
2. 提示词提到的 `/var/minis/` 路径存不存在（**只在真机上查**，CI 是 macOS runner 没有这些路径）
3. 手册索引能不能切出来
4. 目录总 token 数、有没有重复条目
5. **祈使句基线**：严格口径计数，比基线多就红，并指出是哪个文件多了几处

### 基线数字（2026-11-27，commit `ef2bdce`）

| 口径 | 数量 | 说明 |
|---|---|---|
| **严格祈使句（系统提示类）** | **73 处** | 验收基线，只许降不许升 |
| 技能手册正文 | 2 处 | **单独统计，不作验收**（见下） |

分布：

| 文件 | 处数 |
|---|---|
| `AIChatViewModel+ToolDefinitions.swift` | 17 |
| `AIChatViewModel.swift` | 16 |
| `AIChatViewModel+ProgrammaticPrompt.swift` | 10 |
| `HelperRunner.swift` | 8 |
| `AIChatViewModel+ManualTools.swift` | 6 |
| `AIChatViewModel+TitleGeneration.swift` | 4 |
| `SoulStore.swift` | 3 |
| `AIChatViewModel+Compaction.swift` | 3 |
| `AIChatViewModel+Persistence.swift` | 2 |
| `AIChatViewModel+MemoryTools.swift` | 1 |
| `PersonaStore.swift` | 1 |
| `AIChatView.swift` | 1 |
| `ScheduledJobRunner.swift` | 1 |

**这个 73 是存量，不是合格线。** 批 0 记的 19 是漏扫出来的——只认单行字符串，提示词正文的 `"""` 多行块全没扫到。

**技能手册为什么分开算**：`SkillStore.swift` 里那 12 处是 minis-theme 等技能的操作正文，只在技能被加载时进上下文，而且手册里写「不能改什么」「必须明说」是正当的。和系统提示混在一起计数，数字会误导。

严格口径的定义：

- 中文强祈使：必须 / 绝不 / 不许 / 务必 / 禁止
- 英文强祈使：MUST / Do NOT / Never / IMPORTANT
- 规章标记：核心原则 / 规则： / You are / You should
- **不算**：不要 / 不能 / 总是 / Always / 请你（这些在正常叙述里太常见）
- 排除：UI 标签（`Never Used`、`Never auto-lock`）、Swift 类型（`Task<Void, Never>`）、常量名（`...FromImageAlways`）
- `only`、`should` 这类英文正常文法用法不计

**每清掉一批就手动下调基线**，数字往下走才算真在改。新加任何一条撞红，就得先想清楚它该不该由代码闸门来管。

### 例外表

**口径**：登记进这张表的，是「祈使句基线里暂时不能撤」的条目。每项写清：位置、为什么不能撤、什么时候能撤。撤掉后把行删掉，基线数跟着降。

当前基线 **73 处**（2026-11-28，commit `36bf7db` 之后），另 2 处技能手册正文单独统计。

**扫描器重写过一次。** 之前按行猜字符串边界，漏掉一半以上：

- 块注释 `/* */` 里的 `"""` 会打乱状态
- 字符串拼接 `"你必须" + "先读文件"` 拆成两段后都太短
- 小写 `you must` / `do not` 不在词表
- 原始字符串 `#"..."#` 不认

现在改成字符级状态机（`extract_string_literals`），一次扫完整个文件，注释整体跳过。数字从 29 涨到 73——**涨的是漏检，不是新问题**。

口径：**强祈使词**（必须/绝不/务必/禁止/不许/MUST/Do NOT/Never/IMPORTANT/do not/you must/never ）和**规章标记**（核心原则/规则：/You are/You should）才计。「不要/不能」在参数说明里常是描述性的（"不传就用默认顺序"），不作判据。

| # | 位置 | 内容 | 为什么不能撤 | 预计撤掉的批次 |
|---|---|---|---|---|
| E1 | `AIChatViewModel.swift:1943` | `Never use grep/awk/sed/find` | **有事故背景**：曾因用 grep 扫大目录超时卡死。换成 `rg` 是硬要求，且没有代码闸门（无法在派发层拦住「用 grep」这个行为） | 不撤。永久保留 |
| E2 | `AIChatViewModel.swift:2027` | `Never record passwords, API keys, tokens, secrets` | **安全**：写进记忆文件后会被后续所有会话读到。没有代码闸门能拦住 memory_write 的内容语义 | 不撤。永久保留 |
| E3 | `AIChatViewModel.swift:1965` | `use ripgrep (rg) for EVERY scan of files` | 同 E1，是 E1 的正向表述。两句都在，因为一句讲「用什么」，一句讲「不用什么」 | 不撤。永久保留 |
| E4 | `AIChatViewModel+Persistence.swift:1739` | `You MUST continue`（空回复续写） | **协议**：这是模型协议层的重试指令，不是人设措辞。空回复时模型必须继续，否则这一轮就断了 | 不撤。这是 wire 协议的一部分 |
| E5 | `AIChatViewModel+TitleGeneration.swift:539` | `You MUST respond with a JSON object` | **协议**：标题生成走独立的非聊天链路，要求严格 JSON。不写 MUST 会返回带解释的文字，解析失败 | 不撤。非聊天链路 |
| E6 | `ToolDefinitions.swift:121` | `Do NOT use this tool for minis-clone:// ACTION urls` | **参数约束**：open_terminal 的 URL 必须是 minis-clone:// 而非 minis://，写错会静默失败。没有代码校验能拦住「模型传了错误 scheme」 | 不撤。等 add_mcp 之类有校验后再评估 |
| E7 | `ToolDefinitions.swift:265/419/431` | `Do NOT synthesize audio yourself with shell commands` | **有事故背景**：曾用 ffmpeg 手搓音频绕过 TTS，音质和格式都不对 | 不撤。永久保留 |
| E8 | `ToolDefinitions.swift:667` | `Never`（Tool call style 摘要示例里） | 误报：`Never guess` 是示例文本的一部分，不是给模型的指令 | 不用撤。口径误报，已登记 |
| E9 | `AIChatViewModel.swift:1938/1944/1951/2026` | 路由表里的 `Never` | 这些是「X 场景 → 用什么工具」的路由条目，`Never` 出现是因为它们和 E1/E2 在同一段字符串里被一起扫到 | 不用撤。口径连带，不是独立指令 |
| E10 | `SoulStore.swift:1242` | `You are {name}.` | 身份模板本体。批 1 定稿：只剩名字，这是唯一身份来源 | 不撤 |
| E11 | `SoulStore.swift:1393` | `「雷区」写了就必须照做` | 用户档案段的约束。这是**用户自己写的规矩**，不是代码给的 | 不撤。用户内容 |
| E12 | `SoulStore.swift:1388/1391` | `不要把它当自己的设定` / `规则：以「她明确写下的」为准` | 档案段的边界说明：告诉模型这是「对方」不是「自己」。这是防止身份串味的关键句 | 不撤。这是身份隔离的机制 |
| E15 | `+Compaction.swift:1231` | `You are a context compaction engine` | 压缩链路的**功能角色**，不是人设。这个调用只产出摘要，不继续对话，所以不污染人设 | 不撤 |
| E16 | `+Compaction.swift:1236` | `MUST PRESERVE (never omit or shorten)` | **数据保真**：摘要必须原样保留路径、命令、错误。撤掉会丢关键信息 | 不撤 |
| E17 | `+Compaction.swift:1256/1278` | `Do NOT translate code` / `Do NOT continue the conversation` | 前者防改坏代码，后者防模型把摘要写成续写。都是功能约束 | 不撤 |
| E18 | `HelperRunner.swift:1330` | `You are a helper sub-agent in Minis` | helper 子代理的身份段，跟 `subAgentIdentitySection` 平行。子代理有自己的第一层，不是人设污染 | 不撤 |
| E19 | `ScheduledJobRunner.swift:501` | `绝不像闹钟一样硬弹` | 自主心跳提示词里的行为约束。这条提示词是让模型**用自己的人设**主动说话，不是给它安身份 | 不撤 |
| E14 | `AIChatView.swift:8584` | 识图 JSON 提示词「请严格返回如下 JSON 格式，不要包含任何其他文字」 | 功能性约束：走视觉模型，不聊天；JSON 格式要求是硬性的 | 不撤。非聊天链路 |

**维护规矩**：
- 新增祈使句导致 CI 红 → 要么改写（改成陈述），要么登记进这张表并说明理由。
- 登记时基线文件同步更新（`scripts/prompt_imperative_baseline.json`），否则下次 CI 还是红。
- 每批做完，回头看一眼有没有能撤的。

---

## 四、待补

- [ ] 真机 dump（`main.txt` / `main-base.txt` / `main-ledger.md` / `subagent.txt`）——需要醒醒在手机上跑一次
- [ ] 11-20 那份 93 项改动点清单重新锚定（审计数出 82 项）
- [ ] 评测集（见整改包 §7）

### 复审补漏（2026-11-28 第三轮）

独立复审 + 自己复验，又抓出三个口子，全部已堵：

| 口子 | 后果 | 修法 |
|---|---|---|
| **净零置换** | 只比总数：删一处真问题、别处加一处，总数不变就骗过 | 逐文件严格对比，任何文件涨一处就 FAIL |
| **基线放松** | 基线数字改大，标准悄悄往后挪 | 基线比实际松时 NOTE 提醒；要下调必须重跑 `--init` |
| **CI 刷基线** | 在流水线里加 `--init` 就能把基线刷成当前值 | CI 环境下 `--init` 直接 FAIL（判 `CI` 环境变量） |

三种场景的退出码都验过：正常 0、CI+init 1、本地 init 0。
