//
//  SessionMemoryView.swift
//  MinisApp
//
//  Shows all memory used in the current session: auto-injected + tool-recalled.
//

import SwiftUI

struct SessionMemoryView: View {
    @ObservedObject var vm: AIChatViewModel
    @Environment(\.dismiss) private var dismiss

    // [batch6-ui 11-27 醒醒] 上游这份是原生 List + Section，配色走
    // ChatColors.accent / MinisTheme.secondaryText；而加号抽屉是
    // CSSThemeVariables 卡片风。点「查看」从卡片抽屉跳进一个原生列表，
    // 像换了个 App，而且不跟用户装扮的主题走。
    // 现在改成卡片风：ScrollView + CSSThemeVariables.card，
    // 背景 bg(scope: .sheet)，行样式对齐 ComposerActionSheet.navRow。

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if !vm.memoryEnabled {
                        disabledNotice
                    }
                    summaryBar
                    section(
                        title: AppLocalized("每轮自动注入"),
                        footer: AppLocalized("这些内容在每个 agent turn 开始时被拼进 system prompt。"),
                        items: autoInjected.map { item in
                            row(name: item.name, detail: item.detail, icon: item.icon) {
                                AnyView(MemoryContentView(
                                    title: item.name,
                                    content: item.content,
                                    fileURL: item.fileURL))
                            }
                        })
                    if !toolMemories.isEmpty {
                        section(
                            title: AppLocalized("本次会话的工具读写"),
                            footer: AppLocalized("agent 在这次会话里读过或写过的记忆。"),
                            items: toolMemories.map { item in
                                row(name: item.title, detail: item.detail,
                                    icon: item.isWrite ? "square.and.pencil" : "magnifyingglass") {
                                    AnyView(
                                        Group {
                                            if item.isWrite {
                                                MemoryWriteDetailView(item: item, personaID: vm.sessionPersonaId)
                                            } else {
                                                MemoryGetDetailView(item: item)
                                            }
                                        })
                                }
                            })
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            .background(CSSThemeVariables.bg(scope: ThemeColorLayer.sheet))
            .navigationTitle(AppLocalized("会话记忆"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(AppLocalized("完成")) { dismiss() }
                        .foregroundStyle(CSSThemeVariables.textMain(scope: ThemeColorLayer.sheet))
                }
            }
        }
    }

    /// 记忆关着的时候，顶部说清后果——用户关之前要知道自己关掉了什么。
    private var disabledNotice: some View {
        HStack(spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(ChatFont.font(13))
            Text(AppLocalized("记忆已关闭，本轮没有注入任何内容"))
                .font(ChatFont.font(13))
            Spacer(minLength: 0)
        }
        .foregroundStyle(CSSThemeVariables.textDim(scope: ThemeColorLayer.sheet))
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(CSSThemeVariables.card(scope: ThemeColorLayer.sheet))
        )
    }

    /// 一行看完规模：不用逐个点开就知道这轮模型吃进去多少。
    private var summaryBar: some View {
        HStack(spacing: 0) {
            statCell(value: "\(autoInjectedLineCount())", label: AppLocalized("行已注入"))
            dividerCell
            statCell(value: "\(autoInjected.count)", label: AppLocalized("个来源"))
            if !toolMemories.isEmpty {
                dividerCell
                statCell(value: "\(toolMemories.count)", label: AppLocalized("次工具读写"))
            }
        }
        .padding(.vertical, 13)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(CSSThemeVariables.card(scope: ThemeColorLayer.sheet))
        )
    }

    private var dividerCell: some View {
        Rectangle()
            .fill(CSSThemeVariables.textDim(scope: ThemeColorLayer.sheet).opacity(0.18))
            .frame(width: 1, height: 22)
    }

    private func statCell(value: String, label: String) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(ChatFont.font(17, weight: .semibold))
                .foregroundStyle(CSSThemeVariables.textMain(scope: ThemeColorLayer.sheet))
            Text(label)
                .font(ChatFont.font(11))
                .foregroundStyle(CSSThemeVariables.textDim(scope: ThemeColorLayer.sheet))
        }
        .frame(maxWidth: .infinity)
    }

    private func autoInjectedLineCount() -> Int {
        guard vm.memoryEnabled else { return 0 }
        return autoInjected.reduce(0) { $0 + $1.injectedLines }
    }

    /// 卡片分组：标题 + 卡片 + 脚注。
    private func section<Item: View>(title: String, footer: String,
                                     items: [Item]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(ChatFont.font(12, weight: .medium))
                .foregroundStyle(CSSThemeVariables.textDim(scope: ThemeColorLayer.sheet))
                .padding(.leading, 4)
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                    if idx > 0 {
                        Rectangle()
                            .fill(CSSThemeVariables.textDim(scope: ThemeColorLayer.sheet).opacity(0.12))
                            .frame(height: 1)
                            .padding(.leading, 46)
                    }
                    item
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(CSSThemeVariables.card(scope: ThemeColorLayer.sheet))
            )
            Text(footer)
                .font(ChatFont.font(11))
                .foregroundStyle(CSSThemeVariables.textDim(scope: ThemeColorLayer.sheet))
                .padding(.horizontal, 4)
                .padding(.top, 1)
        }
    }

    // MARK: - Row

    private func row(name: String, detail: String, icon: String,
                     destination: @escaping () -> AnyView) -> some View {
        NavigationLink {
            destination()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(ChatFont.font(15))
                    .foregroundStyle(CSSThemeVariables.textMain(scope: ThemeColorLayer.sheet))
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(ChatFont.font(15))
                        .foregroundStyle(CSSThemeVariables.textMain(scope: ThemeColorLayer.sheet))
                    if !detail.isEmpty {
                        Text(detail)
                            .font(ChatFont.font(12))
                            .foregroundStyle(CSSThemeVariables.textDim(scope: ThemeColorLayer.sheet))
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        // 不用 .plain：那会把 NavigationLink 自带的 disclosure 箭头一起抹掉，
        // 看起来像不可点。用 borderless 保留系统箭头，同时不叠按钮底色。
        .buttonStyle(.borderless)
    }

    // MARK: - Auto-injected

    private struct AutoItem {
        let name: String
        let detail: String
        let icon: String
        let content: String
        let fileURL: URL?
        /// 这一项实际被注入 system prompt 的行数（daily 只取前 200 行；
        /// SOUL/GLOBAL 全量）。summaryBar 用它说话。
        var injectedLines: Int = 0
    }

    private var autoInjected: [AutoItem] {
        var items: [AutoItem] = []
        let fm = FileManager.default
        // ［persona］人设未知且不是草稿（fail closed）：loadSession 查不到
        // 人设时绝不回落到当前人设的目录——那会把另一个人设的 SOUL/GLOBAL
        // 摆出来让人改（MemoryContentView 是可编辑的）。草稿（sessionId
        // == nil）按 S26 跟随当前人设，下面的回落只对草稿生效。
        guard vm.sessionPersonaId != nil || vm.sessionId == nil else { return [] }
        // ［persona］按本会话人设读记忆目录（草稿回落到当前人设）。
        let memDir = PersonaStore.memoryDir(for: vm.sessionPersonaId ?? PersonaStore.currentID())

        // SOUL.md — listed first because it's the identity/personality
        // layer that SystemPromptBuilder.identitySection() injects at
        // the very top of every turn's system prompt. The Memory Sheet
        // previously only surfaced GLOBAL.md + daily logs, so users had
        // no way to confirm SOUL.md was reaching the model.
        let soulURL = memDir.appendingPathComponent("SOUL.md")
        if fm.fileExists(atPath: soulURL.path),
           let content = try? String(contentsOf: soulURL, encoding: .utf8),
           !content.isEmpty {
            let lineCount = content.components(separatedBy: "\n").count
            items.append(AutoItem(
                name: "SOUL.md",
                detail: AppLocalized("\(lineCount) 行，全量注入"),
                icon: "person.fill",
                content: content,
                fileURL: soulURL,
                injectedLines: lineCount
            ))
        } else {
            items.append(AutoItem(name: "SOUL.md", detail: AppLocalized("空"),
                                  icon: "person", content: "(empty)", fileURL: soulURL))
        }

        // GLOBAL.md
        let globalURL = memDir.appendingPathComponent("GLOBAL.md")
        if fm.fileExists(atPath: globalURL.path),
           let content = try? String(contentsOf: globalURL, encoding: .utf8),
           !content.isEmpty {
            let lineCount = content.components(separatedBy: "\n").count
            items.append(AutoItem(
                name: "GLOBAL.md",
                detail: AppLocalized("\(lineCount) 行，全量注入"),
                icon: "star.fill",
                content: content,
                fileURL: globalURL,
                injectedLines: lineCount
            ))
        } else {
            items.append(AutoItem(name: "GLOBAL.md", detail: AppLocalized("空"),
                                  icon: "star.fill", content: "(empty)", fileURL: globalURL))
        }

        // Most recent 3 daily logs with content (matches system prompt injection logic)
        // [audit-E7] Calendar-day stepping via shared MemoryLogDates (matches
        // AIChatViewModel+MemoryTools injection logic; -86400s caused DST drift).
        var found = 0
        let dates = MemoryLogDates.recentDays(count: 30)

        for (dayOffset, dateStr) in dates.enumerated() where found < 3 {
            let fileName = "\(dateStr).md"
            let fileURL = memDir.appendingPathComponent(fileName)
            if fm.fileExists(atPath: fileURL.path),
               let content = try? String(contentsOf: fileURL, encoding: .utf8),
               !content.isEmpty {
                let lineCount = content.components(separatedBy: "\n").count
                let injected = min(lineCount, 200)
                let detail = lineCount > 200
                    ? AppLocalized("注入前 \(injected) 行，共 \(lineCount) 行")
                    : AppLocalized("\(lineCount) 行，全量注入")
                let label: String
                switch dayOffset {
                case 0: label = AppLocalized("今天")
                case 1: label = AppLocalized("昨天")
                default: label = dateStr
                }
                items.append(AutoItem(
                    name: "\(label) · \(fileName)",
                    detail: detail,
                    icon: "calendar",
                    content: content,
                    fileURL: fileURL,
                    injectedLines: injected
                ))
                found += 1
            }
        }

        return items
    }

    // MARK: - Tool memories

    struct ToolMemoryItem: Identifiable {
        // Identity comes from the source AssistantBlock, whose id is
        // stable for the block's lifetime. A fresh UUID() here would
        // change on every recompute of `toolMemories` (it is a computed
        // property rebuilt on each body evaluation), so any background
        // message change would swap every row's identity and tear down
        // a pushed detail view along with its editing state.
        let id: UUID
        let title: String
        let detail: String
        /// The tool result output (what the tool returned to the agent).
        let content: String
        let isWrite: Bool
        /// The original content written by memory_write, parsed from toolInputArgs.
        let writtenContent: String?
        /// Keywords used for memory_get search.
        let keywords: String?
    }

    private var toolMemories: [ToolMemoryItem] {
        var items: [ToolMemoryItem] = []
        for message in vm.messages {
            for block in message.blocks {
                guard case .memoryTool(let action) = block.kind else { continue }
                let isWrite = action == "memory_write"
                let summary = block.toolSummary ?? action

                var writtenContent: String?
                var keywords: String?

                if let argsJson = block.toolInputArgs,
                   let data = argsJson.data(using: .utf8),
                   let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if isWrite {
                        writtenContent = dict["content"] as? String
                    } else {
                        keywords = dict["keywords"] as? String
                    }
                }

                // Build a meaningful detail preview
                let detail: String
                if isWrite, let written = writtenContent {
                    // Show what was written
                    let firstLine = written.components(separatedBy: "\n").first(where: { !$0.isEmpty }) ?? ""
                    detail = String(firstLine.prefix(100))
                } else if !isWrite {
                    // Show keywords + result summary
                    let resultLines = block.content.components(separatedBy: "\n").filter { !$0.isEmpty }
                    if let kw = keywords, !kw.isEmpty {
                        let matchCount = resultLines.filter { $0.hasPrefix("---") || $0.hasPrefix("## ") }.count
                        detail = "Search: \(kw)" + (matchCount > 0 ? " (\(matchCount) files)" : "")
                    } else {
                        detail = String((resultLines.first ?? "").prefix(100))
                    }
                } else {
                    detail = String(block.content.prefix(100))
                }

                items.append(ToolMemoryItem(
                    id: block.id,
                    title: summary,
                    detail: detail,
                    content: block.content,
                    isWrite: isWrite,
                    writtenContent: writtenContent,
                    keywords: keywords
                ))
            }
        }
        return items
    }
}

// MARK: - Content Detail

private struct MemoryContentView: View {
    let title: String
    let fileURL: URL?

    /// Live copy of the file's content. The `content` init parameter is
    /// only the opening snapshot: save() writes to disk, and unless the
    /// local copy advances too, the view keeps displaying — and
    /// re-seeding the editor from — the pre-edit text, so a second save
    /// silently overwrites the first edit with a draft based on the
    /// old content.
    @State private var currentContent: String
    @State private var editedContent: String = ""
    @State private var isEditing = false
    @State private var saved = false
    @ObservedObject private var studio = AppearanceStudio.shared

    /// [glass-switch] 浮条底：玻璃开 = 材质，关 = 浮层实底面色。
    private var toastFill: AnyShapeStyle {
        studio.glassEnabled
            ? AnyShapeStyle(.ultraThinMaterial)
            : AnyShapeStyle(CSSThemeVariables.surface())
    }

    init(title: String, content: String, fileURL: URL?) {
        self.title = title
        self.fileURL = fileURL
        _currentContent = State(initialValue: content)
    }

    var body: some View {
        Group {
            if isEditing {
                TextEditor(text: $editedContent)
                    .font(.system(.caption, design: .monospaced))
                    .padding(.horizontal, 8)
            } else {
                ScrollView {
                    Text(currentContent)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .textSelection(.enabled)
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .background(CSSThemeVariables.bg(scope: ThemeColorLayer.sheet))
        .toolbar {
            if fileURL != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    if isEditing {
                        Button("Save") {
                            save()
                        }
                    } else {
                        Button {
                            editedContent = currentContent
                            isEditing = true
                        } label: {
                            Image(systemName: "pencil")
                        }
                    }
                }
            }
        }
        .overlay(alignment: .bottom) {
            if saved {
                Text(AppLocalized("已保存"))
                    .font(.caption)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(toastFill, in: Capsule())
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    private func save() {
        guard let url = fileURL else { return }
        do {
            try editedContent.write(to: url, atomically: true, encoding: .utf8)
            currentContent = editedContent
            // SOUL.md needs the same side effect SoulStore.save() does:
            // refresh the in-memory metadata cache (so the chat header /
            // SystemPromptBuilder pick up the new identity). Without this,
            // edits in this sheet would land on disk but the running app
            // would keep using the stale identity until next launch.
            if url.lastPathComponent == "SOUL.md" {
                SoulStore.refreshCache()
            }
            isEditing = false
            withAnimation { saved = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                withAnimation { saved = false }
            }
        } catch {
            // Stay in editing mode so the user's text is not lost — but say
            // why, otherwise the Save button just looks dead.
            MinisToast.show(
                String(format: AppLocalized("Save failed: %@"), error.localizedDescription),
                systemImage: "exclamationmark.triangle.fill"
            )
        }
    }
}

// MARK: - Memory Write Detail (with revoke)

private struct MemoryWriteDetailView: View {
    let item: SessionMemoryView.ToolMemoryItem
    /// ［persona］本会话人设 id，编辑回写定位该人设的记忆目录。
    /// nil = 人设未知：编辑/撤销一律拒绝（fail closed），绝不回退全局当前人设。
    let personaID: String?
    @Environment(\.dismiss) private var dismiss
    /// Live copy of the entry's written content. `item` is a snapshot
    /// taken when the list was built; saveEdit replaces the log body by
    /// matching the OLD written content, so after one successful edit
    /// this copy must advance to the new content — otherwise the next
    /// edit searches the log for text that no longer exists there,
    /// finds nothing, and silently does nothing. Revoke reads it for
    /// the same reason.
    @State private var currentWrittenContent: String?
    @State private var isEditing = false
    @State private var editedContent: String = ""
    @State private var showRevokeAlert = false
    @State private var revokeResult: String?
    @State private var showResultAlert = false
    @State private var saved = false
    @ObservedObject private var studio = AppearanceStudio.shared

    /// [glass-switch] 浮条底：玻璃开 = 材质，关 = 浮层实底面色。
    private var toastFill: AnyShapeStyle {
        studio.glassEnabled
            ? AnyShapeStyle(.ultraThinMaterial)
            : AnyShapeStyle(CSSThemeVariables.surface())
    }

    init(item: SessionMemoryView.ToolMemoryItem, personaID: String?) {
        self.item = item
        self.personaID = personaID
        _currentWrittenContent = State(initialValue: item.writtenContent)
    }

    var body: some View {
        Group {
            if isEditing {
                TextEditor(text: $editedContent)
                    .font(.system(.caption, design: .monospaced))
                    .padding(.horizontal, 8)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if let written = currentWrittenContent {
                            SectionHeader(title: "Written Content")
                            Text(written)
                                .font(.system(.caption, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal)
                                .textSelection(.enabled)
                        }

                        SectionHeader(title: "Tool Result")
                        Text(item.content)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(CSSThemeVariables.textDim(scope: ThemeColorLayer.sheet))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 8)
                }
            }
        }
        .navigationTitle(item.title)
        .navigationBarTitleDisplayMode(.inline)
        .background(CSSThemeVariables.bg(scope: ThemeColorLayer.sheet))
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if isEditing {
                    Button("Save") { saveEdit() }
                } else {
                    if currentWrittenContent != nil {
                        Button {
                            editedContent = currentWrittenContent ?? ""
                            isEditing = true
                        } label: {
                            Image(systemName: "pencil")
                        }
                    }
                    Button {
                        showRevokeAlert = true
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .disabled(currentWrittenContent == nil)
                }
            }
        }
        .overlay(alignment: .bottom) {
            if saved {
                Text(AppLocalized("已保存"))
                    .font(.caption)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(toastFill, in: Capsule())
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .alert("Revoke Memory", isPresented: $showRevokeAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Revoke", role: .destructive) {
                revokeResult = revokeEntry()
                showResultAlert = true
            }
        } message: {
            Text(AppLocalized("从 daily 里删掉这条记忆？删了找不回来。"))
        }
        .alert(revokeResult ?? "", isPresented: $showResultAlert) {
            Button("OK") {
                if revokeResult?.hasPrefix("Removed") == true {
                    dismiss()
                }
            }
        }
    }

    private func saveEdit() {
        guard let written = currentWrittenContent else { return }
        let result = replaceEntryInLog(oldContent: written, newContent: editedContent)
        if result != nil {
            currentWrittenContent = editedContent
            isEditing = false
            withAnimation { saved = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                withAnimation { saved = false }
            }
        } else {
            // `replaceEntryInLog` returns nil when the entry could not be
            // located in the last two days' logs, or when the write failed.
            // Staying in edit mode without a word looks like a dead button.
            MinisToast.show(
                AppLocalized("Could not save: this memory entry was not found in the daily log."),
                systemImage: "exclamationmark.triangle.fill"
            )
        }
    }

    /// Find entry matching `oldContent` in daily logs and replace its body with `newContent`.
    /// Returns the filename on success, nil on failure.
    private func replaceEntryInLog(oldContent: String, newContent: String) -> String? {
        // ［persona］人设未知（fail closed）：不知道条目属于谁就不改，
        // 绝不回退全局当前人设的目录——那会改掉另一个人设的日报。
        guard let personaID else { return nil }
        let fm = FileManager.default
        // ［persona］按本会话人设回写记忆目录。
        let memDir = PersonaStore.memoryDir(for: personaID)
        // [audit-E7] Calendar days via shared MemoryLogDates.
        let candidates = MemoryLogDates.recentDays(count: 2)

        for dateStr in candidates {
            let fileURL = memDir.appendingPathComponent("\(dateStr).md")
            guard fm.fileExists(atPath: fileURL.path),
                  let fileContent = try? String(contentsOf: fileURL, encoding: .utf8) else {
                continue
            }

            let pattern = "<!-- \\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2}:\\d{2} -->\n"
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }

            let nsContent = fileContent as NSString
            let matches = regex.matches(in: fileContent, range: NSRange(location: 0, length: nsContent.length))

            for (i, match) in matches.enumerated() {
                let contentStart = match.range.location + match.range.length
                let entryEnd: Int
                if i + 1 < matches.count {
                    entryEnd = matches[i + 1].range.location
                } else {
                    entryEnd = nsContent.length
                }

                let bodyRange = NSRange(location: contentStart, length: entryEnd - contentStart)
                let body = nsContent.substring(with: bodyRange)
                let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
                let trimmedOld = oldContent.trimmingCharacters(in: .whitespacesAndNewlines)

                if trimmedBody == trimmedOld {
                    let replacement = newContent.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n"
                    let newFileContent = nsContent.replacingCharacters(in: bodyRange, with: replacement)
                    if let _ = try? newFileContent.write(to: fileURL, atomically: true, encoding: .utf8) {
                        return dateStr
                    }
                }
            }
        }
        return nil
    }

    /// [T-ios-memory-write-revoke] Delegates to the shared revoker, which the
    /// tool capsule's long-press menu uses too — the entry-deletion logic must
    /// not drift between the two entry points.
    private func revokeEntry() -> String {
        guard let written = currentWrittenContent else {
            return AppLocalized("No written content to revoke.")
        }
        // [audit-E6] The detail view carries the persona the entry was
        // written under — revoke must look THERE, not at "whoever is current".
        return MemoryWriteRevoker.revoke(writtenContent: written, personaID: personaID)
    }
}

// MARK: - Memory Get Detail

private struct MemoryGetDetailView: View {
    let item: SessionMemoryView.ToolMemoryItem

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let kw = item.keywords, !kw.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(CSSThemeVariables.textDim(scope: ThemeColorLayer.sheet))
                        Text(kw)
                            .font(.subheadline.bold())
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)
                }

                Text(item.content)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .textSelection(.enabled)
            }
            .padding(.bottom)
        }
        .navigationTitle(item.title)
        .navigationBarTitleDisplayMode(.inline)
        .background(CSSThemeVariables.bg(scope: ThemeColorLayer.sheet))
    }
}

// MARK: - Section Header

private struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.caption.bold())
            .foregroundStyle(CSSThemeVariables.textDim(scope: ThemeColorLayer.sheet))
            .textCase(.uppercase)
            .padding(.horizontal)
    }
}
