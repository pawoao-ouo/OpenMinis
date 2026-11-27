# 牵连清单（整改包 §2.1）

改任何一处模型可见文字或逻辑之前，先照这张表查一遍同源的地方。
汇报时附上：每项写「同源、已改 / 同源、不改，理由 / 查过、无关」。空着的格子不算做完。

**只给做事的人看，不进模型上下文。**

---

## 一、系统提示的构建路径

| # | 路径 | 位置 | 什么时候走 | 状态 |
|---|---|---|---|---|
| P1 | 主流程 | `AIChatViewModel.swift` `buildTurnSystemPrompt()` ≈2073 | 每轮开头 | 每轮重建，改提示词即时生效 |
| P2 | 换模型自动重试（倒计时） | `+Fallback.swift` `streamWithAutoRetry()` ≈58，调用方 `:527` | 可重试错误，倒计时重试 | **待核**：调用方传 `currentSystemPrompt`，倒计时内换模型只换 provider，不重建提示词 |
| P3 | 兜底重试（换模型） | `+Fallback.swift` ≈441 / 517 / 602 / 739 | 重试耗尽，换组内下一个模型 | 已改：四处都走 `buildTurnSystemPrompt` |
| P4 | 保活重放 | `AIChatViewModel.swift:7442` `keepAliveSystemPrompt` → `CacheKeepAliveManager.swift:143` | 后台缓存预热 | 存的是当轮拼好的提示词，不重建 |
| P5 | 子代理子会话 | `+ProgrammaticPrompt.swift:593` `subAgentIdentitySection` | 委派任务 | 已改：`You are a sub agent in Minis. A parent agent handed you one task.` |
| P6 | 摘要 / 压缩 | `+Compaction.swift:1230` `systemPrompt` | 上下文超限、手动压缩 | **核过**：独立的功能引擎提示词（`You are a context compaction engine`），不是人设。**但里面用 `The agent will read your summary` / `the agent needs` 称呼模型**，是第二来源，待改 |
| P7 | 块摘要 | 同 P6 文件 | 长工具输出 | **核过**：走同一套 compaction 提示词 |

## 二、不走聊天构建器的另一批文字

| # | 位置 | 状态 |
|---|---|---|
| N1 | 标题生成 `+TitleGeneration.swift:539` | 独立链路，`You MUST respond with a JSON object`（协议要求，见例外表 E5） |
| N2 | 图像生成 `Providers/OpenAI/OpenAIProvider.swift:1977` | 已改：`Use tools when available.`（原 `You are a helpful assistant`） |
| N3 | 语音转写 `Providers/Voice/VoiceProvider.swift:257` | 独立链路，`You are a speech-to-text transcription engine`（功能型，非人设） |
| N4 | ProviderConfigStore | **核过**：`Shared/Config/` 下没有独立拼提示词的地方，配置只提供值，不产文字。无关 |

## 三、用户角色的 system-reminder

| # | 位置 | 内容 | 状态 |
|---|---|---|---|
| R1 | `SoulStore.swift:1393` `userProfilePromptSection` | 档案提醒（>40 条时追加） | 中文，敲醒体，保留 |
| R2 | `+Persistence.swift:1739` | `<system-reminder>The previous response was empty... You MUST continue` | 协议，见例外表 E4 |
| R3 | 贴纸 | `AIChatView.swift` `StickerStore.systemPromptFragment()` | **核过，有问题**：中文，带「核心原则」「规则：1. 2. 3.」规章腔，批 2 漏改。待改成陈述 |
| R4 | `AIChatViewModel.swift:2186` | 自审段（批 5） | 中文，敲醒体 |

## 四、其他

| # | 项 | 状态 |
|---|---|---|
| O1 | 本地化字符串（`AppLocalized`） | 界面文字，模型看不到，不改 |
| O2 | 用户手册 `Resources/user-manual.md` + `UserManualMirror` | 索引进提示词，正文按需读 |
| O3 | `docs/` | 不进模型，但改了要同步 |
| O4 | 测试 | `MinisTests` 里没有断言身份句的（批 1 已核） |
| O5 | 技能正文 `SkillStore.swift` | 内置技能硬编码在代码里，改内容要**同时提版本号**，否则 `installBundledSkills` 判 `existing.version < version` 会跳过 |

---

## 批 1 三个「待查」的结论（2026-11-27 核）

| 项 | 结论 |
|---|---|
| 子代理 `subAgentIdentitySection` | **已改**。现在是 `You are a sub agent in Minis. A parent agent handed you one task.`，不再带 `capable AI assistant` |
| 测试里断言那句的 | **没有**。`rg 'capable AI assistant' src/ios --glob '*Test*'` 零命中 |
| `docs/` 引用那句的 | 只有 `docs/batch1-identity-plan.md` 自己引用（作为改前记录），不需要改 |

---

## 维护

- 新加一条进模型上下文的文字路径 → 补进这张表
- 每批汇报时对照这张表逐项写状态，别留空
