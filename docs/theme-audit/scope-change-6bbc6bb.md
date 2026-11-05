# 范围变更：`6bbc6bb`

## 它是什么

```
6bbc6bb  SkillStore: refresh stored description when file differs (fix stuck skills)
```

三个文件：

- `src/ios/Agent/Session/SkillStore.swift`——技能描述过期判断的行为改动
- `src/ios/MinisTests/Standalone/SkillDescriptionStaleTests.swift`——新增
- `.github/workflows/build-ios-ipa.yml`——第 10 步多跑一条 `SkillDescriptionStaleTests.swift`

## 为什么它在这里

它不在主题审计的 16 项里，也不是我提的。分支上的提交作者都是同一个账号，从 git 上分不出谁写的，所以这里只记事实，不记归因。（不写笔数：笔数每推一笔就变，写进文档当天就过期。）

它挂在 `446aebc` 之后，从那以后每次构建都会跑到它，包括最后绿的那一轮。

## 影响

- 功能上：它修的是“技能描述改了文件还一直卡着”的独立缺陷，和主题系统无交叉。
- 流程上：本轮动过 CI 工作流的是三笔之一——`6bbc6bb`、`a155af9`（把调色板套件接进第 11 步）、`f7ef801`（把静态检查接进第 10 步）。后两笔是范围修复本身要接的线，只有它把**范围外的**断言塞进了验收步骤。
- 摘除代价：它之后没有任何提交动过这三个文件，顶上 `git revert 6bbc6bb` 是干净的。

## 当前处置

**留着，并正式记成范围变更**，没有擅自 revert 别人的修法。

要摘的话，一句话就能摘：`git revert 6bbc6bb`，重跑一轮绿。

## 相关

- 复审报告 P2-3
- 分支 `fix/theme-audit-159`，基线 `ca39a77`
