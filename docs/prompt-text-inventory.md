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
| 14 | 内置 steward 人设「MCP小助手」 | `Agent/Session/PersonaStore.swift` ≈1230、1256 | 中 | **已定：保留** |
| 15 | 图像生成 "You are a helpful assistant" | `Providers/OpenAIProvider.swift` ≈1975 | 英 | **不在聊天链路，只登记不改** |

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

## 三、自动检查（批 0 建）

脚本：`/var/minis/workspace/scan_prompt_text.py`
输出：`/var/minis/workspace/prompt-baseline/scan-baseline.json`

### 基线数字（2026-11-24，commit 7833a57）

| 口径 | 数量 | 说明 |
|---|---|---|
| 宽松命中（含 only/should 等普通用法） | 175 处 / 34,054 字符 | 用来找线索，不作验收 |
| **严格祈使句** | **19 处** | 验收基线，只许降不许升 |
| 越权主语（你/助手/帮助…） | 54 处 | 批 2 主战场 |

严格口径命中分布：

| 文件 | 处数 |
|---|---|
| `AIChatViewModel.swift`（路由/纪律段） | 9 |
| `AIChatViewModel+ToolDefinitions.swift`（工具描述） | 6 |
| `SoulStore.swift` | 2 |
| `+TitleGeneration.swift` | 1 |
| `+Persistence.swift` | 1 |

### 严格口径的定义

中文祈使：必须 / 总是 / 绝不 / 不许 / 务必 / 禁止 / 请你 / 你来
英文祈使：MUST / Do NOT / Never / Always / IMPORTANT / You must / You should / You can / You are

`only`、`should`、单独一个 `never` 的小写形在宽松口径里，不计入验收基线——英文里正常文法的用法太多，计进来数字就废了。

### 例外表

还没建。批 2 开始填，每项写：位置、为什么暂时不能撤、预计撤掉的批次。

---

## 四、待补

- [ ] 真机 dump（`main.txt` / `main-base.txt` / `main-ledger.md` / `subagent.txt`）——需要醒醒在手机上跑一次
- [ ] 11-20 那份 93 项改动点清单重新锚定（审计数出 82 项）
- [ ] 评测集（见整改包 §7）
