# T-61 只读核查记录

**结论：一起听壁纸没有备份缺口——它在备份里，走的是 `sharedFiles` 分类，不是漏备。恢复是逐文件覆盖式合并，失败有整树回滚。**

核查时间：2026-11-04
分支 `fix/theme-audit-159`，基线 `ca39a77`

---

## 1. 一起听壁纸进不进备份

**进。**

- 一起听壁纸目录：`TogetherStore.rootURL` = `shared/together`，图片落在 `shared/together/images/`（`TogetherStore.swift:80-88`）。
- 备份分类 `BackupCategory.sharedFiles` 的导出实现（`BackupExporter.swift:718-727`）：

```swift
private func exportSharedFiles(trees: BackupFileTreeExporter) throws
    -> BackupManifest.CategoryStat {
    let r = try trees.export(root: AIChatViewModel.minisSharedPersistentDir,
                             logicalPrefix: "shared",
                             category: .sharedFiles)
```

导出的是 `shared/` **整棵树**，logicalPrefix `shared`，通过 `FileManager.enumerator` 递归（`BackupFileTreeExporter.swift:140-153`）。所以 `shared/together/images/xxx.jpg` 会以 `shared/together/images/xxx.jpg` 这个逻辑路径进包。

- 大小上限：`BackupBlobStore.maxFileBytes` 默认 `nil` = 无限（`BackupBlobStore.swift:28-29`，`BackupFormat.swift:289`："`maxFileBytes == nil` means unlimited, which is the DEFAULT"）。`BackupSnapshotService.swift:308` 传的也是 `nil`。所以壁纸不会被大小上限排除。
- 排除规则只有三条，都不命中壁纸：
  1. `isBackupArtifact` — 只挡 `shared/Backups/` 这类备份产物（`BackupFileTreeExporter.swift:165-169`）
  2. `.skipsHiddenFiles` — 只挡 dotfile
  3. `notDownloaded` — iCloud 未下载的占位文件

**准话：一起听壁纸在备份包内，分类是 `sharedFiles`。**

---

## 2. 恢复是覆盖还是合并

**合并（逐文件覆盖同名，包内没提到的文件保留）。不是整目录替换。**

- `importSharedFiles`（`BackupImporter+Categories.swift:389-406`）→ `restoreFileTree`。
- `restoreFileTree` 逐条遍历 `fileIndex` 里 `category == "shared_files"` 的条目（`:1179`），不做目录级删除。
- 每个文件先落到同目录的 `.restore-<UUID>.tmp` 再替换（`:1236-1245`，注释标 `[review I2]`），避免"先删后拷"期间崩溃丢文件。
- 包内没有的路径，代码里没有任何删除动作 → 保留。

---

## 3. 失败是否回滚

**有。`sharedFiles` 会整树拍快照，失败后回滚。**

- `BackupRollbackSnapshot.snapshotForRollback`（`BackupImporter+Categories.swift:62-63`）：

```swift
case .sharedFiles: liveDirs = [AIChatViewModel.minisSharedPersistentDir]
case .stickers:    liveDirs = [AIChatViewModel.minisStickersPersistentDir]
case .memory:      liveDirs = [AIChatViewModel.minisMemoryPersistentDir]
```

- 注释（`:76-81`）明确 `.chats` / `.skills` / `.voiceCorrections` / `.environmentVariables` **不拍快照**，`.sharedFiles` 在拍快照的那一侧。
- 回滚执行 `rollback(_ snapshot:...)`（`:127` 起），把 copy-aside 的目录拷回，日志 `"[Restore] rolled back \(snapshot.category.rawValue) (\(snapshot.directories.count) dir(s))"`（`:166`）。

---

## 4. 顺带查到的：两套壁纸在备份里分属两个分类

| 壁纸 | 存储位置 | 备份分类 |
|---|---|---|
| 主壁纸（聊天/各作用域） | `AppearanceStudio.appearanceAssetsDirectory` | `.appearance` |
| 一起听壁纸 | `shared/together/images/` | `.sharedFiles` |

两者**都在备份里**，但走的是不同分类、不同恢复路径。

这对 T-55「备份走同一套」的含义：备份层面没有缺口，不需要补；真正的缺口只在**缩放与校验的实现**（两份几乎相同的代码、两份 2200 常量），第 8 条按要求收掉。