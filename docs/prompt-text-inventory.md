# 批 0：模型可见文字清单

本文原计划对应整改包 §2.1 / §2.2，是供维护者复核的清单，不注入任何模型请求；本轮不改产品文案。本仓库未找到所引 §2.2 原文，因此下列归属按代码中的实际数据流说明，不声称是对 §2.2 条款的逐项解释。

**基线代码：** `641a2b546239fdd244a36d6324b8c6c1c7cfc873`（`prompt/rectify-batch0`）。下列调用链按此提交核对。扫描器枚举当前登记范围内的静态 Swift 字符串，并扫描固定 Markdown 手册正文全文；当前数字只代表已登记扫描范围，不构成全仓来源完整的结论。动态内容和运行时条件另行标注。扫描器报告中的词句数是复核候选，不是已确认的越权或缺陷。

## 1. 主对话与同一轮的上下文

| 模型收到的来源 | 当前代码锚点 | 进入上下文的方式与条件 |
|---|---|---|
| 主系统提示及分段拼装 | `src/ios/Agent/Chat/AIChatViewModel.swift`：`baseSystemPrompt`、`memoryStatusFragment`、`buildTurnSystemPrompt`、`ambientContextFragment` | 构成主对话系统提示；部分片段依会话、人设、工具可用性、配置和本轮消息而变。自动重试 `streamWithAutoRetry` 复用本次已组装的系统提示；群组 fallback 切换到下一模型时会再次调用 `buildTurnSystemPrompt(base:model:)`，按新模型能力重建；缓存保活复放已组装提示与历史，不是另一份提示来源。 |
| Anthropic Claude Code OAuth 前缀 | `src/ios/Providers/Anthropic/AnthropicProvider.swift`：`claudeCodeSystemPrompt`、`resolveSystemPrompt`；请求序列化在 `src/ios/Providers/Anthropic/AnthropicAgentProvider.swift` | Claude Code OAuth 请求会把构建时生成的 `ProviderCustomizationGenerated.anthropicOAuthIdentifierPrompt` 作为第一段 Anthropic system block，再把主对话 `systemPrompt` 作为第二段；Anthropic API-key 路径不加此前缀。该值来自私有 build setting，未作为字面量存在于公开 Swift 源码；扫描器登记其属性锚点，但无法枚举该构建期文本，因此不增加静态候选计数。 |
| 身份、人设和用户档案 | `src/ios/Agent/Session/SoulStore.swift`：`identityTemplate`、`identitySection`、`userProfileSection`；`src/ios/Agent/Session/PersonaStore.swift`：`stewardSoulContent` | 活跃人设的 SOUL 正文、身份/语言/编辑提示，以及独立的第三人称用户档案段会按选择与开关进入系统提示。`stewardSoulContent` 是内置 MCP 小助手的初始 SOUL；运行时 SOUL 文件可能已被用户改写，因此脚本的静态种子不等于每台设备的当前正文。 |
| 记忆、工具能力与会话状态 | `AIChatViewModel.swift`；`src/ios/Providers/LLMTypes.swift`：`capabilityPromptFragment`、`agentBehaviorPromptFragment`；`src/ios/Agent/Session/MCPStore.swift`：`systemPromptSnippet`；`src/ios/Agent/Session/SkillStore.swift`：`skillPromptFragment` | 包括能力/行为片段、技能与 MCP 目录、记忆状态，以及按功能开关注入的记忆、工具路由、调度、环境等上下文。具体内容和条目为运行时数据。技能目录是发现信息；技能 `SKILL.md` 正文在模型按需读取时才作为工具结果进入历史，不等同于每轮常驻系统提示。 |
| 其他主提示片段 | `src/ios/Views/Chat/AIChatView.swift`：`promptCatalogSummary`、`systemPromptFragment`；`src/ios/Agent/Evolution/EvolutionInjector.swift`：`turnFragment`；`src/ios/Providers/Voice/TTSPaper.swift`：`standingCapability`、`paperIfRelevant` | 包括贴纸目录、进化片段，以及 AI 语音能力声明/按话题展开的语音说明；均受运行时条件或配置影响。贴纸完整抽屉目录由 `promptDrawerContent` 在 `browse_stickers` 工具结果或 `[翻:抽屉名]` 后续 reminder 中按需返回，不是常驻提示。 |
| 环境状态片段 | `src/ios/Agent/Chat/AmbientContext.swift`：`fragment`、`timeFactsLine`、`gapLine`、`listeningLine`、`deviceLine`、`clock`、`timeOfDayWord`、`defaultUsageRule`、`switch path.status`；调用入口为 `AIChatViewModel.swift::ambientContextFragment` | `AmbientContext.fragment` 在主提示构造路径中生成有条件的环境状态段；标题、说明和状态行只在对应条件满足时出现。用法规矩来自用户设置或 `defaultUsageRule`，默认值在状态段有内容时会一并附上。动态时间、歌曲、设备与网络值不是静态候选。`AmbientSignal.title/detail` 由 `AmbientContextSettingsView::row` 用于 UI 设置项，不进入模型上下文，因此未纳入扫描。 |
| 用户手册索引与按需正文 | `src/ios/MinisApp.swift`：`init`；`src/ios/Shared/UserManualMirror.swift`：`indexFragment`、`syncFromBundle`；`src/ios/Resources/user-manual.md`；`AIChatViewModel+ToolDefinitions.swift`：`makeAgentTools`；`AIChatViewModel+FileTools.swift`：`executeFileRead`；`AIChatViewModel+ConcurrentTools.swift`：活动 `file_read` 分支和 `tool_result` 构造 | `MinisApp.init` 启动时调用 `syncFromBundle`，把 bundle 手册同步到 `/var/minis/shared/user-manual.md`；模型可调用 `file_read` 读该路径，正文作为 `tool_result` 返回给模型。索引字面量和完整 Markdown 正文分别按两个来源扫描；正文可按需分段读取。 |
| 工具定义与目录 | `src/ios/Agent/Chat/AIChatViewModel+ToolDefinitions.swift`：`makeAgentTools`、`defaultCatalogItems`、`renderCatalogFragment`、`appleCompactSection`、`subAgentRosterSection`；`src/ios/Agent/Bridge/MCPManagementTools.swift`：`dialogDefinitions` | `buildTurnSystemPrompt` 在 `AIChatViewModel.swift` 中调用 `renderCatalogFragment`；目录由 `defaultCatalogItems` 提供并按本轮 `makeAgentTools` 的可用 schema 过滤，Apple 原生紧凑目录由 `appleCompactSection` 追加，子代理 roster 由 `subAgentRosterSection` 独立加入。没有发现该工具定义文件中其他活动目录生产函数。工具名、描述、参数 schema、可用目录和 MCP 管理工具定义均依能力、开关和配置变化。 |
| 工具执行结果、错误与提醒 | `src/ios/Agent/Chat/AIChatViewModel+ConcurrentTools.swift`、`+FileTools.swift`、`+MemoryTools.swift`、`+Persistence.swift`、`+ProgrammaticPrompt.swift`、`+ManualTools.swift`、`src/ios/Agent/BrowserUse/BrowserUseManager.swift::execute/navigate/timedOutNavigationResult`、`BrowserTabPool.swift::execute`、`BrowserUseActions.swift::BrowserActionResult.error(_:)`、`src/ios/Agent/Bridge/MCPAggregator.swift`、`MCPManagementTools.swift` 及扫描器登记的其他本地结果生产函数 | 本地工具返回值会作为工具结果进入本地模型历史；包括取消、截断等条件性结果。`ConcurrentTools` 的活动 `browser_use` 分支调用 `browserTabPool.execute`，把 `BrowserActionResult.text/success` 交给 `toolOutput/toolSuccess`，最后构造 `AgentContentPart.toolResult`；因此 BrowserUseManager 的缺参、路由、URL 校验错误，以及 BrowserTabPool 的视口、tab 回收/超时等静态失败文字在命中相应分支时会成为模型工具结果。`BrowserActionResult.error(_:)` 会把固定前缀 `Error: ` 与传入的错误消息拼成结果文本；该前缀在所有经此工厂返回的错误中都进入上述工具结果，动态消息不由本扫描器枚举。导航 deadline 只标记超时；需等 WebKit 终止回调后 `navigate` 才返回失败结果，若 Pool 的 300 秒 dead-timeout 先触发，则由 Pool 的新 tab 失败结果取代。`ManualTools` 的静态成功/错误输出只有在相应本地工具可用、被调用且主循环继续时才会在后续请求中返回。动态值、路径、服务回执等通常无法静态枚举。扫描器按结果构造函数做较宽字面量范围，因此附近候选仍需人工确认。 |
| 图片裁剪占位文字（本地构造） | `src/ios/Agent/Chat/AIChatViewModel+Offloading.swift::imagePlaceholderText`、`trimOldImagesFromHistory` | 当历史图片数超过保留数并裁剪较旧图片时，本地生成占位文字并写回有效对话历史：工具图片仍在工具结果块中，用户附件则转为普通文本部分。若没有触发裁剪，占位文字不会生成；它不是图片来源工具原始返回，也不是独立模型请求。 |
| 静默反馈 directive / notice | `src/ios/Views/Chat/MessageActionBar.swift::ChatFeedbackSheet.onSendFeedback` → `MessageActionBar.onFeedback` → `src/ios/Agent/MessageList/CollectionViewMessageListV3.swift::bridge.onFeedback` → `AIChatViewModel.swift::addFeedbackDirective` / `pendingFeedbackDirectives`；`send()` 于 3228–3237 行消费并追加 | 用户触发点赞、踩、快捷标签或自定义指令时，反馈字符串先进入待处理队列；下一次真实发送继续执行时才被消费，并作为独立 `.user` 消息包在 `<system-reminder>` 中追加并持久化到模型历史。扫描器只选择含 `<system_runtime_feedback` 的 XML 字面量（包括 290–294 行的 5 个快捷标签），不把按钮标签、说明文字或 toast 误作模型输入；自定义评论内容是动态值。 |
| 请求级图片预算占位文字 | `src/ios/Agent/Chat/AIChatViewModel+RequestBudget.swift::elidedImagePlaceholder`、`applyRequestImageBudget`；主发送/重试/fallback 调用在 `src/ios/Agent/Chat/AIChatViewModel.swift` 6834、7018、7090、7117、7169 行，keep-alive 快照在 7342 行 | 超出请求图片字节预算时，普通用户图片部分会被替换成 `.text` 占位；工具结果中的图片会在 `toolResult.content` 追加同类占位并移除图像 payload。预算后的历史用于主请求及自动重试、群组 fallback；未超限时不生成占位。扫描器只锚定 `elidedImagePlaceholder` 的两个静态输出，不扫描 `applyRequestImageBudget` 内的 UI toast/log 文案；路径等插值值保持动态。 |
| 追加到本地消息历史的提醒 | `AIChatViewModel.swift`、`+Persistence.swift`、`+Attachments.swift`、`+ConcurrentTools.swift`、`+CodeBlockEditing.swift`、`+AskUser.swift`、`src/ios/Agent/Chat/AIChatViewModel+ISHCommand.swift` / `src/ios/Agent/Shell/BashismReminder.swift`、`src/ios/Shared/EnvVarRedactor.swift` | 包括图片批次提醒、超问题数提醒、工具取消/截断、空工具结果重试、长上下文用户档案提醒、Bashism shell 结果提醒和脱敏输出提醒。代码块编辑在 `+CodeBlockEditing.swift::notifyAIAboutCodeEdit` 中通过 `submitProgrammaticPrompt` 提交 system-reminder 与编辑前后代码。扫描器既按 `<system-reminder>` 标记选取实际提醒，也显式扫描 Persistence 等生成函数；`ChatStore` / `ChatModels` 中对标记的解析、过滤或显示逻辑不是生成源。 |
| 排队消息与时间锚点 | `src/ios/Agent/Chat/AIChatViewModel.swift`：`queuedTimingNote`、`appendQueuedPromptsAsOwnTurns`；`src/ios/Agent/Chat/ChatStore.swift`：`queuedFollowUpBridgeText` | 活动队列 drain 路径把时间锚点写入每条用户历史消息，并在连续用户消息之间插入桥接文本。`queuedFollowUpBridgeText` 是活动生成来源；`internalBridgeText` 只用于旧桥接文本识别/过滤，不作为活动生成源。时间、消息正文和附件路径均为动态值。 |
| 恢复答案与浏览器接管 | `src/ios/Agent/Chat/AIChatViewModel+SuspensionResume.swift::continueAfterRestoredAsk`；`src/ios/Agent/Chat/AIChatViewModel+BackgroundTask.swift::waitIfBrowserTakeover` | 恢复提问答案在可配对时作为 tool result 进入历史；原 tool_use 已不在历史时改成普通 user 文本。浏览器接管结束并成功取得截图后，静态说明和截图作为 user 消息追加进历史。答案、工具 ID、截图字节和路径为动态值。 |
| 附件与会话恢复 | `src/ios/Agent/Chat/AIChatViewModel+Attachments.swift::processAttachments`；`src/ios/Agent/Chat/ChatStore.swift::RawMessage.toAgentMessage`（由 `+Persistence.swift` 的会话加载调用） | 正常/排队附件处理把路径说明和文件元数据写入 AgentMessage；恢复历史时读取持久化图片并经 `ImagePayloadPrep.preparedForContext` 处理。图片无法加载或无法准备时，固定回退说明与动态路径进入历史。 |
| 图片能力降级与 Provider 序列化 | `src/ios/Shared/ImagePayloadPrep.swift::replacingImagesWithPlaceholders`、`gatedForVisionCapability`；`src/ios/Providers/VisionGroupResolver.swift::attachmentPlaceholder`；`src/ios/Providers/Anthropic/AnthropicAgentProvider.swift::convertMessages`、`src/ios/Providers/Gemini/GeminiAgentProvider.swift::convertMessages`、`src/ios/Providers/Antigravity/AntigravityAgentProvider.swift::convertMessages`、`src/ios/Providers/OpenAI/OpenAIAgentProvider.swift::convertMessagesChatCompletions/convertMessagesResponsesAPI` | 图片被当前模型拒绝时，群组 fallback 的一次自愈重试把图片改成文本占位；不支持视觉输入时，Provider 序列化调用 `attachmentPlaceholder`；不支持/不可读格式的特定 Provider 还会写入固定回退文本。只在对应模型能力、图片格式和错误分支触发，图片内容/路径为动态值。 |
| 工具图片 gate 拒绝结果 | `src/ios/Shared/ImagePayloadPrep.swift::gatedToolImage`、`ToolImageRejection.reason`；调用方 `src/ios/Agent/Chat/AIChatViewModel+FileTools.swift::executeFileRead`（活动 `read_image` 分支） | gate 拒绝时，固定原因属性和动态尺寸/格式细节被拼入失败 `toolOutput` 并作为工具结果返回模型；成功时图片内容仍按 gate 处理。扫描器同时登记 gate 的静态原因及调用方结果构造，运行时文件路径、格式、尺寸等不作为静态候选。 |
| 子代理/委派 | `src/ios/Agent/Chat/AIChatViewModel+ProgrammaticPrompt.swift`：`subAgentIdentitySection`、`delegationPrompt`、`executeDelegateTask`、状态/恢复提示 | 子会话身份、任务前言、状态/恢复或结果提示会随委派路径送入相应模型上下文。 |
| 定时任务与自主脉搏 | `src/ios/Agent/Jobs/ScheduledJobRunner.swift`：`scheduledEnvelope`、`buildPulsePrompt` | 定时任务的封装和脉搏触发说明确实作为新一轮输入提交；任务正文、时间、轮次等为动态值。非脉搏任务不会收到脉搏说明。 |

## 2. 独立模型请求（不是主聊天系统提示）

| 请求类型 | 当前代码锚点 | 实际送入的内容 |
|---|---|---|
| 标题/文件夹建议、子模型标题 | `src/ios/Agent/Chat/AIChatViewModel+TitleGeneration.swift`：`suggestFolder`、`callSubModelForTitle` | 独立请求的任务说明和待归纳内容。 |
| 轮次摘要与上下文压缩 | `src/ios/Agent/Chat/AIChatViewModel+BlockSummary.swift`：`summarizeTurnBlocks`；`+Compaction.swift`：`generateCompactSummary`、`compactSummaryWrappedText` | 分别对轮次块或历史生成摘要；包装文字与输入历史一起发送。 |
| Provider 连通性探测 | `src/ios/Providers/ProviderConfigStore.swift`：`pingModel` | 独立用户消息 `Reply with exactly: OK`；`systemPrompt` 为 `nil`。 |
| 语音识别纠错 | `src/ios/Providers/Voice/CorrectionStrategy.swift`：`systemPrompt`、`buildPrompt` | 独立纠错请求；转写文本、候选词和上下文为动态输入。TTS 合成的语音正文属于合成请求内容，不是另一个聊天系统提示。 |
| chat-based ASR 转写 | `src/ios/Providers/Voice/VoiceProvider.swift::transcribeChatBased`；活动入口在 `VoiceInputPanel`，由 `VoiceProvider.transcribe` / `usesChatBasedASR` 路由 | 独立 `/v1/chat/completions` 请求，静态 system 指令要求逐字转录；仅模型 id 含 `omni`，或同时含 `audio` 与 `gpt`/`qwen` 时进入此分支。音频和语言提示是动态输入；普通系统语音、其他模型或覆盖 `transcribe` 的 Provider 不必经过此请求。转写结果返回语音输入 UI，不是主聊天工具结果。 |
| 图片描述/视觉请求 | `src/ios/Providers/VisionGroupResolver.swift`：`describePrompt`、`systemPrompt`、`describe`、`describeOnce`；`src/ios/Providers/ImageOCRTier.swift`：`textForImage`、`frameOCR` | 描述提示与图片作为独立视觉请求发送；ImageOCRTier 会把动态 `customPrompt`/question 传给 VisionGroupResolver，并把结果框成图像文本上下文。模型选择、图片、问题和失败原因依运行时而定。 |
| 贴纸识别视觉请求 | `src/ios/Views/Chat/AIChatView.swift`：`recognizeSticker` | 导入贴纸时，将图片和静态 JSON 提取指令作为独立视觉请求发送；结果再解析为贴纸元数据。 |
| 对话气泡翻译 | `src/ios/Views/Chat/TurnDetailSheet.swift`：`startAITranslation` | 独立翻译请求，包含所选文本及翻译方向。 |
| `minis-model-use` judge | `src/ios/NativeOffloads/ModelUseOffloadBridge.swift`：`runJudgePrompt` | judge 工具的提示由调用方提供，属动态输入；扫描器能登记请求构造位置，不能枚举所有调用者文本。 |
| 图像生成 | `src/ios/Providers/OpenAI/OpenAIProvider.swift`：`generateImage`、`generateImageViaCodexResponses` | 图像生成提示由调用方提供。Codex Responses 路径还发送静态 instructions `You are a helpful assistant. Use tools when available.` 与 `Use the image generation tool to create: …` 用户文本。 |
| Provider 快速测试 | `src/ios/Views/Providers/ModelQuickTestSheet.swift`：`performTest` | 按测试类型构造独立请求；可能涉及文本、图像、语音或转录。测试输入和所选 Provider/模型依运行时而定。 |

## 3. Bridge 对外 MCP 协议（与本地聊天请求分开）

`src/ios/BridgeCore/Sources/BridgeCore/Kernel/BridgeMetaTools.swift` 的 `makeServer` 对外只发布 MCP「搜」「命令」两个元工具及其说明/schema；并非把注册表内工具逐个列为 MCP `tools/list` 项。设备工具由 `DeviceTools.registerAll` 注册；`BridgeKernelAssembly.registerToolsWithRetry` 也会注册 `ReportIssueTool` 和 `WebSearchBridgeTool`。这些工具的 `ToolDescriptor` 在各自 `register` 中提供静态 `summary`、`detail`、keywords 和 `parameterSchemaJSON`。实际传给外部 MCP 的路径是：`ToolRegistry.search` 从 schema 生成 `hit.parameterBrief` 并带上 `hit.summary`，`BridgeMetaTools.handleSearch` 将命中项的名字、`hit.summary` 与 `hit.parameterBrief` 写入「搜」的工具结果；`detail` 用于搜索匹配，不在该结果行中原样回传。于是 ReportIssueTool/WebSearchBridgeTool 的简介摘要和参数简述可在搜索命中时被外部 AI 看见；完整 schema 不会因此整份下发。`ToolPapers.swift` 的纸条也会按命中工具附加到搜索结果，或特定参数错误的命令结果。「命令」执行结果另作为外部 MCP 工具结果返回。外部 MCP 客户端启用 Bridge 后，外部 AI 可见这些响应；客户端如何进一步放入自身模型上下文由客户端决定。它们**不是**本地 ChatAgent 的系统提示或本地聊天工具定义；Bridge 默认关闭，只有设置页用户动作才启动。扫描器把这些静态描述/参数源码与本地工具结果分开计入清单，仍属独立协议来源，不计作本地聊天上下文。

## 4. 静态扫描基线

从仓库根目录运行：

```sh
python3 scripts/scan_prompt_text.py
python3 scripts/scan_prompt_text.py --json
python3 scripts/scan_prompt_text.py --exact-baseline
```

默认模式（含 `--json`）用于后续批次：当前登记范围的指令候选不得超过 **413**，角色主语候选不得超过 **89**；按此范围基线只降不升。超限退出码为 `1`，未解析锚点或新来源未登记退出码为 `2`。HEAD 与批 0 不同只作信息展示，不会单独让后续提交失败。`--exact-baseline` 专用于复现本轮扫描范围：要求 HEAD 精确等于 `641a2b546239fdd244a36d6324b8c6c1c7cfc873`、五项计数精确为 `62/3457/1/413/89`，且 `src/ios` 工作树干净；不用于后续批次。

**隐私输出：** 默认文本与 JSON 都省略候选原文，只报告路径、行号和命中类别；错误路径也不回显候选句。只有显式传入 `--include-candidate-text` 才输出源句；原文可能敏感，分享前必须审核。CI 不启用此选项。

新增独立工作流 `.github/workflows/prompt-text-validation.yml`：只针对 `main` 目标分支及 `prompt/rectify-batch0` 源分支上的相关路径运行 Python 语法检查、扫描器回归测试和默认候选上限扫描；权限仅 `contents: read`，不构建 iOS、不输出候选原文。默认浅检出后从扫描器读取冻结基线 SHA，只 fetch 该 commit（depth 1）供历史对比，不下载完整仓库历史。该工作流文件已添加但本轮没有触发 CI。

本轮扫描结果（只代表已登记范围，不宣称全仓来源完整）：

- **62 个登记路径 = (62−1) 个 Swift 文件 + 1 份 Markdown 文档**；共 **3,457 条静态 Swift 字符串字面量**，另有 **1 份 Markdown 正文**。
- **413 条“指令关键词或句首祈使”候选句**；按源出现计数，不去重，其中手册正文贡献 2 条。
- **89 条以明确角色主语开头的候选句**；按源出现计数，不去重，其中手册正文贡献 1 条。
- 所有已登记源路径和锚点均解析成功；当前默认候选上限检查通过。干净的 `src/ios` 工作树在冻结 HEAD=`641a2b546239fdd244a36d6324b8c6c1c7cfc873` 时曾通过 `--exact-baseline`。协调者随后有意撤回越界 App exporter 代码，当前 `src/ios` 与冻结 HEAD 存在差异，因此当前 `--exact-baseline` 退出码为 `1`；不要将它描述为当前仍通过。以上结果不证明不存在其他未登记生成点。
- 相对上一份记录 **52/2983/1/397/75**，当前计数差异为 **+10 个登记路径、+474 条静态 Swift 字符串、+16 条指令候选及 +14 条角色主语候选**。该比较同时包含新增扫描来源与插值解析能力改进，不是纯粹的来源扩张增量。

| 登记路径 | Swift 字符串字面量 | Markdown 文档 | 指令候选 | 角色主语候选 |
|---|---:|---:|---:|---:|
| `src/ios/Agent/Bridge/BluetoothDeviceTool.swift` | 61 | 0 | 7 | 0 |
| `src/ios/Agent/Bridge/ClipboardDeviceTool.swift` | 33 | 0 | 3 | 0 |
| `src/ios/Agent/Bridge/LocationDeviceTool.swift` | 37 | 0 | 3 | 0 |
| `src/ios/Agent/Bridge/MCPAggregator.swift` | 23 | 0 | 1 | 0 |
| `src/ios/Agent/Bridge/MCPManagementTools.swift` | 104 | 0 | 20 | 0 |
| `src/ios/Agent/Bridge/NotificationDeviceTool.swift` | 54 | 0 | 5 | 0 |
| `src/ios/Agent/Bridge/PhotosDeviceTool.swift` | 118 | 0 | 4 | 0 |
| `src/ios/Agent/Bridge/ReportIssueTool.swift` | 49 | 0 | 11 | 0 |
| `src/ios/Agent/Bridge/WebSearchBridgeTool.swift` | 16 | 0 | 1 | 0 |
| `src/ios/Agent/BrowserUse/BrowserTabPool.swift` | 46 | 0 | 9 | 1 |
| `src/ios/Agent/BrowserUse/BrowserUseActions.swift` | 1 | 0 | 0 | 0 |
| `src/ios/Agent/BrowserUse/BrowserUseManager.swift` | 250 | 0 | 13 | 1 |
| `src/ios/Agent/Chat/AIChatViewModel+AskUser.swift` | 1 | 0 | 2 | 0 |
| `src/ios/Agent/Chat/AIChatViewModel+Attachments.swift` | 18 | 0 | 1 | 0 |
| `src/ios/Agent/Chat/AIChatViewModel+BackgroundTask.swift` | 10 | 0 | 0 | 0 |
| `src/ios/Agent/Chat/AIChatViewModel+BlockSummary.swift` | 8 | 0 | 3 | 1 |
| `src/ios/Agent/Chat/AIChatViewModel+CodeBlockEditing.swift` | 1 | 0 | 1 | 0 |
| `src/ios/Agent/Chat/AIChatViewModel+Compaction.swift` | 10 | 0 | 9 | 4 |
| `src/ios/Agent/Chat/AIChatViewModel+ConcurrentTools.swift` | 451 | 0 | 18 | 2 |
| `src/ios/Agent/Chat/AIChatViewModel+FileTools.swift` | 80 | 0 | 4 | 0 |
| `src/ios/Agent/Chat/AIChatViewModel+ManualTools.swift` | 55 | 0 | 16 | 1 |
| `src/ios/Agent/Chat/AIChatViewModel+MemoryTools.swift` | 61 | 0 | 3 | 0 |
| `src/ios/Agent/Chat/AIChatViewModel+Offloading.swift` | 5 | 0 | 0 | 0 |
| `src/ios/Agent/Chat/AIChatViewModel+Persistence.swift` | 4 | 0 | 4 | 0 |
| `src/ios/Agent/Chat/AIChatViewModel+ProgrammaticPrompt.swift` | 336 | 0 | 21 | 14 |
| `src/ios/Agent/Chat/AIChatViewModel+RequestBudget.swift` | 2 | 0 | 1 | 0 |
| `src/ios/Agent/Chat/AIChatViewModel+SuspensionResume.swift` | 3 | 0 | 1 | 1 |
| `src/ios/Agent/Chat/AIChatViewModel+TitleGeneration.swift` | 89 | 0 | 6 | 7 |
| `src/ios/Agent/Chat/AIChatViewModel+ToolDefinitions.swift` | 707 | 0 | 137 | 10 |
| `src/ios/Agent/Chat/AIChatViewModel.swift` | 130 | 0 | 36 | 3 |
| `src/ios/Agent/Chat/AmbientContext.swift` | 40 | 0 | 3 | 0 |
| `src/ios/Agent/Chat/ChatStore.swift` | 3 | 0 | 0 | 1 |
| `src/ios/Agent/Evolution/EvolutionInjector.swift` | 3 | 0 | 0 | 0 |
| `src/ios/Agent/Jobs/ScheduledJobRunner.swift` | 2 | 0 | 1 | 0 |
| `src/ios/Agent/Session/MCPStore.swift` | 6 | 0 | 0 | 0 |
| `src/ios/Agent/Session/PersonaStore.swift` | 6 | 0 | 2 | 3 |
| `src/ios/Agent/Session/SkillStore.swift` | 18 | 0 | 0 | 0 |
| `src/ios/Agent/Session/SoulStore.swift` | 88 | 0 | 17 | 2 |
| `src/ios/Agent/Shell/BashismReminder.swift` | 1 | 0 | 0 | 0 |
| `src/ios/BridgeCore/Sources/BridgeCore/Kernel/BridgeMetaTools.swift` | 67 | 0 | 3 | 2 |
| `src/ios/BridgeCore/Sources/BridgeCore/Kernel/ToolPapers.swift` | 10 | 0 | 11 | 2 |
| `src/ios/NativeOffloads/ModelUseOffloadBridge.swift` | 13 | 0 | 1 | 0 |
| `src/ios/Providers/Anthropic/AnthropicAgentProvider.swift` | 8 | 0 | 0 | 0 |
| `src/ios/Providers/Antigravity/AntigravityAgentProvider.swift` | 33 | 0 | 0 | 2 |
| `src/ios/Providers/Gemini/GeminiAgentProvider.swift` | 25 | 0 | 0 | 2 |
| `src/ios/Providers/ImageOCRTier.swift` | 11 | 0 | 2 | 0 |
| `src/ios/Providers/LLMTypes.swift` | 22 | 0 | 7 | 3 |
| `src/ios/Providers/OpenAI/OpenAIAgentProvider.swift` | 83 | 0 | 0 | 7 |
| `src/ios/Providers/OpenAI/OpenAIProvider.swift` | 63 | 0 | 3 | 6 |
| `src/ios/Providers/ProviderConfigStore.swift` | 3 | 0 | 1 | 0 |
| `src/ios/Providers/VisionGroupResolver.swift` | 55 | 0 | 5 | 3 |
| `src/ios/Providers/Voice/CorrectionStrategy.swift` | 29 | 0 | 7 | 1 |
| `src/ios/Providers/Voice/TTSPaper.swift` | 21 | 0 | 0 | 2 |
| `src/ios/Providers/Voice/VoiceProvider.swift` | 24 | 0 | 1 | 3 |
| `src/ios/Resources/user-manual.md` | 0 | 1 | 2 | 1 |
| `src/ios/Shared/EnvVarRedactor.swift` | 1 | 0 | 1 | 0 |
| `src/ios/Shared/ImagePayloadPrep.swift` | 7 | 0 | 0 | 0 |
| `src/ios/Shared/UserManualMirror.swift` | 4 | 0 | 0 | 2 |
| `src/ios/Views/Chat/AIChatView.swift` | 21 | 0 | 2 | 1 |
| `src/ios/Views/Chat/MessageActionBar.swift` | 8 | 0 | 1 | 0 |
| `src/ios/Views/Chat/TurnDetailSheet.swift` | 5 | 0 | 3 | 1 |
| `src/ios/Views/Providers/ModelQuickTestSheet.swift` | 14 | 0 | 0 | 0 |

这些数量不是“实际提示条数”、问题数或整改验收线；它们是登记路径上的静态字面量与启发式候选，包含本地来源及下节另行标记的外部 MCP 协议源，不等于本地 ChatAgent 上下文计数。Swift 插值外层仍以 `⟪dynamic⟫` 代替动态值，但插值表达式内的静态 Swift 字符串会另行计入；逐源表分别报告 Swift 字面量和 Markdown 文档数。完整 JSON 默认省略候选原文，路径/行号/类别与此表计数一致。

## 5. 扫描边界与排除项

**输出安全警告：** 默认文本与 JSON 不包含候选源句；显式 opt-in 参数 `--include-candidate-text` 才会输出原文，原文可能敏感，未经审核不得复制到共享日志或共享产物。CI 不得启用该参数。

`scan_prompt_text.py` 是标准库 Python 静态候选扫描器：先跳过注释并识别 Swift 字符串，再扫描代码中登记的符号锚点、模型输入 marker、工具结果生产函数，以及 `src/ios/Resources/user-manual.md` 正文。扫描锚点覆盖主提示构造、工具目录、排队消息和时间锚点、恢复答案、浏览器接管截图说明、附件构造与会话恢复、图片拒绝后的自愈重试、请求图片预算占位函数和各 Provider 的视觉能力回退；`MessageActionBar.swift` 仅按 `<system_runtime_feedback` XML marker 选取模型反馈，不扫描同文件的 UI 标签或 toast。工具结果扫描现在包括 `BrowserUseActions.swift::BrowserActionResult.error(_:)` 的固定 `Error: ` 前缀、`BrowserUseManager` 与 `BrowserTabPool` 的结果构造及 `return .error(...)` 结果工厂，以及 `ReportIssueTool`、`WebSearchBridgeTool` 注册函数中的 `ToolOutput` sink；后两者的描述和 schema 静态值因此能被纳入候选范围。错误 sink 特意要求 `return`，避免把 `logger.error(...)` 当成模型可见结果。插值表达式内的静态字符串会单独枚举，外层动态插值值仍以占位符表示。缺少目录/文件/符号锚点会报告未解析项并以非零状态退出。工具结果函数按结果构造位置做较宽扫描，可能包含附近但没有送入模型的字面量；这是为了人工复核，不代表每条都在每次请求中出现。Markdown 文档作为一个独立来源计数，不混入 Swift 字符串字面量总数。

**新增来源不能静默漏过：** 扫描器把批 0 提交中的 `src/ios` 文件路径作为发现基线，每次运行都会检查其下新增的 UTF-8 文本文件（也包括未跟踪文件，不限扩展名；二进制资源不算文本来源）。新增模型文字来源必须被符号范围、提醒标记、Markdown 来源表登记，或确实被工具结果扫描选中；确认与模型文字无关的新增文本文件，才加入扫描器的 `NEW_SOURCE_EXCLUSIONS` 明确排除。两边都没有登记会以退出码 `2` 失败；排除项过期或同时被扫描也会失败。发现范围是整个 `src/ios`，因此普通文本源码和资源也必须先登记为来源或经复核后排除。

**变更候选检查：** 每次运行还会把相对同一批 0 提交新增/修改的 UTF-8 文本重新抽取启发式候选；若出现的候选句不在已登记扫描结果中，且没有在 `CHANGED_CANDIDATE_EXCLUSIONS` 精确列出 `(路径, 句子)`，则以退出码 `2` 失败。已登记范围内的新句会进入候选计数；默认只显示路径、行号和类别，不显示原文，并受默认 **413/89、只降不升** 上限约束。该差异检查不能发现批 0 时已存在、但当时未登记的老来源（本轮补入的来源正属于这类），也不能发现不符合候选正则的模型文字、运行时/动态拼接内容、非 UTF-8 或二进制文本；因此它是针对新增文件和部分变更的闸门，不是自动覆盖全仓模型文字的证明。已有文件中其他未登记的生成点仍需人工追查并加入锚点。候选上限只约束已选中的扫描范围，不代替对请求构造处的来源复核。

以下内容不可能由该静态基线完整列举：运行时 SOUL/用户档案/记忆文件，用户输入与附件，按需读取的技能正文，外部 MCP 服务动态提供的 schema/描述，Provider 配置、动态图像/转写/提示、模型输出，以及工具运行时返回的变量值。它们是清单确认的动态来源，不应拿静态计数推算。

`src/ios/Agent/Jobs/HelperRunner.swift` 中存在旧提示/实现文本，但该文件未编译、没有活动调用；活跃子代理路径在 `AIChatViewModel+ProgrammaticPrompt.swift`，故不把 HelperRunner 的死字符串计入清单或扫描。`ChatStore` / `ChatModels` 中识别、过滤或展示提醒标记的代码也不是生成源。UI-only 文案、未调用的旧实现及 Android 不在本批范围。

正则候选不是语义分析：关键词可能出现在普通叙述、错误说明或引用中；句首祈使启发式也会误收描述句；显式主语匹配不判断权限、对象、否定、引述或上下文。外层 Swift 字符串中的插值值仍以 `⟪dynamic⟫` 占位；插值表达式里的静态字符串作为独立字面量扫描，动态变量不展开或计入。词法器也不是完整 Swift 编译器。因此只有逐条人工复核才能判定某句是否真正构成越权、是否在活跃分支发送，以及是否应登记为例外。

## 6. 人工复核与例外登记

| 复核对象 | 当前状态 | 判定/理由 | 例外批次或处置 |
|---|---|---|---|
| 413 条指令关键词/句首祈使候选（当前扫描输出及来源） | 待逐条语义复核 | 扫描器只给线索，不作定性；此前记录的 397 条未覆盖后来补入的来源 | 尚未登记例外 |
| 89 条明确角色句首候选（当前扫描输出及来源） | 待逐条语义复核 | “以角色为主语”不自动等于越权；此前记录的 75 条未覆盖后来补入的来源 | 尚未登记例外 |
| 工具结果函数中的静态候选 | 逐项结合返回路径复核 | 函数范围较宽，候选不保证返回给模型 | 不以关键词单独判例外 |

本批不预先裁定任何候选是越权，也不凭扫描结果改动产品文字。后续人工确认确需保留的例外，应在此登记精确位置、保留原因和计划复核/撤除批次。
