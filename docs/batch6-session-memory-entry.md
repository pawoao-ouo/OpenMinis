# 批 6 计划：把「会话记忆」入口搬进加号抽屉

## 问题

模型每轮会拿到近三天的 daily 记忆（这是对的，不能砍）。但**用户看不见这三天记了什么**。

`memoryEnabled` 开关在加号抽屉里（`ComposerActionSheet.swift:131-133`），旁边没有任何查看入口。用户关记忆前不知道自己要关掉什么。

## 上游怎么做的

上游把 `SessionMemoryView` 挂在右上角 `…` 菜单里，菜单项文案 `Memories in Session`：

- `AIChatView+TrailingMenu.swift:74` → `onMemories: { showSessionMemory = true }`
- `ChatToolbarHost.swift:376-380` → `if memoryEnabled { Button { onMemories() } label: { Label("Memories in Session", systemImage: "brain.head.profile") } }`
- `AIChatView.swift:1146` → `.sheet(isPresented: $showSessionMemory) { SessionMemoryView(vm: cached.vm) }`

注意上游把它**放在记忆开关同级的菜单里**，且用 `if memoryEnabled` 门控——只有开着才显示。

## 我们现状

- `Views/Chat/SessionMemoryView.swift` **文件存在**（和上游是同一份，内容基本一致）
- `AIChatView.swift:1235` 已经有 `.sheet(isPresented: $showSessionMemory) { SessionMemoryView(vm: cached.vm) }`
- 但**没有任何地方把 `showSessionMemory` 设成 true** —— 入口断了
- 结论：视图和 sheet 都在，只缺一个打开它的按钮

## 要做的

把入口放进 `ComposerActionSheet` 的**记忆开关那一行旁边**，正是醒醒要的位置。

### 方案 A（推荐）：记忆开关行右侧加一个「查看」箭头

现在是：
```
记忆                    [开关]
这一句起，X会不会把这次对话记下来
```

改成：
```
记忆                     查看 ›  [开关]
这一句起，X会不会把这次对话记下来
```

- 「查看」常驻可点（关着也能看上次记了什么，这恰恰是她要的：关之前先看清）
- 点开 → 关闭抽屉 → 打开 `SessionMemoryView`
- 不改 `if memoryEnabled` 门控，关着也能看

### 方案 B：加一整行「会话记忆」

```
记忆                    [开关]
这一句起，X会不会把这次对话记下来
会话记忆              查看最近三天记了什么 ›
```

两行更啰嗦，但读起来更明确。

## 牵连清单

1. `ComposerActionSheet.swift`
   - 新增 `let onOpenSessionMemory: (() -> Void)?`
   - 记忆行加查看入口
   - 需要 `@Environment(\.dismiss)` 先关自己再调回调（注意：dismiss 后立刻 present 另一个 sheet 在 SwiftUI 上会打架，要 delay 一帧或用外层状态）
2. `AIChatView.swift`
   - `ComposerActionSheet(...)` 调用处传 `onOpenSessionMemory`
   - 确认 `showAttachmentMenu` 关闭后再设 `showSessionMemory = true`
3. `SessionMemoryView.swift`
   - **不改**。已有内容：自动注入（SOUL.md / GLOBAL.md / 近三天 daily，带「N/M lines injected」标注）+ 本次会话的工具读写记录
   - 需核实一件事：它的 `minisMemoryPersistentDir` 是否按人设分目录（我们是多人设，上游是单人设）

## 必须先核实的两件事

1. **`SessionMemoryView` 的路径是否对得上多人设**：它读 `AIChatViewModel.minisMemoryPersistentDir`，而我们的 daily 在 `PersonaStore.memoryDir(for: personaID)`。如果两者不一致，面板会显示错的人设记忆，甚至空白——**这是这个功能能不能用的前提**。
2. **sheet 切换冲突**：从加号抽屉点「查看」，要先关抽屉再开记忆面板。SwiftUI 同一时刻只允许一个 sheet，直接连开会吃掉第二个。需要 `dismiss()` 后延迟一帧再置位。

## 验收

1. 加号抽屉 → 记忆行右侧有「查看」
2. 点开 → 看到 SOUL.md / GLOBAL.md / 近三天 daily，每天标注实际注入行数
3. 关掉记忆开关后，同一入口仍然能打开，看到关掉状态下模型没拿到任何记忆
4. 切到别的人设，面板显示的是那个人设的记忆

## 不做

- 不改记忆注入逻辑（近三天 daily 保留）
- 不改 `SessionMemoryView` 的展示结构（除非路径不匹配必须改）
- 不加新开关
