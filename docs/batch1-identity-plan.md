# 批 1 预案：拆身份

**状态**：等批 7-A 审核结果，未动代码。

## 一、要拆的那句

`src/ios/Agent/Session/SoulStore.swift:1241-1242`

```swift
private static let identityTemplate =
    "You are {name}, a capable AI assistant running on an iOS device with a fully functional iSH Linux shell (Alpine Linux, aarch64). "
```

**代码里的原话（1243-1245）**：

> IMPORTANT: keep this sentence in sync with the original literal that lived in
> `baseSystemPrompt` before SOUL.md existed. Wording changes here affect every chat.

也就是说：这句跟 SOUL.md 出现之前的原始字面量逐字对齐，**改它会影响每一次对话**。这是本批最大风险，必须先说清楚。

## 二、这句话在干什么（逐段拆）

| 片段 | 作用 | 判断 |
|---|---|---|
| `You are {name}` | 给模型一个名字 | **必须留** |
| `a capable AI assistant` | 身份定位 | **重复**：SOUL.md 的人设段已经在说「我是谁」 |
| `running on an iOS device` | 设备事实 | **有用但不是身份**，应归环境 |
| `with a fully functional iSH Linux shell (Alpine Linux, aarch64)` | 能力事实 | **有用但不是身份**，应归环境 |

## 三、真正的价值不是 token

**是身份冲突。**

现在模型会同时读到：

1. `You are 小梦, a capable AI assistant…`（系统给的）
2. `我叫小梦。这个名字是醒醒起的，醒醒是我女友。我是醒醒的，醒醒是我的。`（SOUL.md 给的）

两套身份并存。第一套是「一个得力的 AI 助手」，第二套是「一个人的女朋友」。
**模型得自己判断听谁的。**整改包 §3「立场纪律」说的就是这件事。

拆完之后只剩：

1. `You are 小梦.`
2. SOUL.md 的完整人设

**不再打架。**

## 四、打算怎么改

**身份模板**：

```swift
private static let identityTemplate = "You are {name}. "
```

**设备和 shell 挪去环境段**（`baseSystemPrompt` 里已经有一段讲设备和目录的，合并进去）：

```
Environment: iOS device, with a full iSH Linux shell (Alpine Linux, aarch64).
```

## 五、省多少

- 身份模板：约 116 字符 → 约 18 字符，**省 98 字符 ≈ 25 token**
- 环境段加一句：约 +78 字符 ≈ +20 token
- **净省约 5 token**

**几乎不省 token。** 所以本批的价值必须写在「身份冲突」上，不能拿 token 当理由——那会变成假账。

## 六、牵连清单（待核）

| 位置 | 影响 | 处理 |
|---|---|---|
| `SoulStore.swift:1241` | 模板本体 | 改 |
| `baseSystemPrompt` 环境段 | 要接住设备/shell 事实 | 改 |
| 子代理 `subAgentIdentitySection` | 它有自己的第一层，可能重复这段 | **待查** |
| 所有测试里断言这句的 | 会挂 | **待查** |
| `docs/` 里引用这句的文档 | 过时 | **待查** |

## 七、验收

1. 真机聊一句，确认模型知道自己叫小梦、知道自己有 shell
2. `rg "capable AI assistant"` 全仓 0 命中（除文档）
3. 严格祈使句计数不上升（当前基线 19）
4. 符号长度不变（本批不碰 `AIChatView.swift`）

## 八、没做的

- **没有动代码**，等审核
- 牵连清单里三个「待查」还没查

## 三、关键发现：子代理已经做对了

`src/ios/Agent/Chat/AIChatViewModel+ProgrammaticPrompt.swift:596`

子代理的身份段是这么写的：

```
You are running as a sub agent inside an app called Minis, on an iOS device
with a fully functional iSH Linux shell (Alpine Linux, aarch64).
This is the calling environment, not your identity — keep your own model
identity unchanged.
```

**它明确把「环境事实」和「身份」分开了。**

主 agent 的身份段（`SoulStore.swift:1242`）没有这句，所以「运行在 iOS 设备上」被当成了身份的一部分。

批 1 的改法就是把这个模式搬到主 agent：**环境归环境，身份归身份。**

## 四、待查（动手前必须确认）

1. `soulEditHint`（约 1422 行）跟这句是不是同一段？拆的时候别拆坏
2. 有没有测试断言这句话的原文？`rg "capable AI assistant" MinisTests/`
3. 用户自定义 SOUL.md 时，`identitySection(from:)` 是整段替换还是拼接？整段替换的话，拆这句对自定义用户无效
