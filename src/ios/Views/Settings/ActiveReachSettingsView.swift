import SwiftUI

struct ActiveReachSettingsView: View {
    @ObservedObject private var store = ActiveReachStore.shared
    @ObservedObject private var studio = AppearanceStudio.shared
    @ObservedObject private var presence = ActiveReachPresence.shared
    @ObservedObject private var providers = ProviderConfigStore.shared
    @State private var newDialogId = ""
    @State private var sessions: [ChatSession] = []
    @State private var showAdvancedId = false

    private var modelChoices: [ModelEntry] {
        providers.config.modelEntries.filter { !$0.isHidden }
    }

    var body: some View {
        List {
            Section {
                Text("总闸默认关。")
                Text("系统「快捷指令 → 自动化 → 定时」跑「小梦主动唤醒」。")
                Text("只入草稿，要在本页点发送才通知。")
                Text("你在前台时我不主动想。")
            } header: {
                Text("怎么用")
            }

            Section {
                Toggle(isOn: Binding(
                    get: { store.snapshot.enabled },
                    set: { store.setEnabled($0) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("总闸")
                        Text(store.snapshot.enabled ? "开着。关了立刻安静。" : "关着。不会主动找你。")
                            .font(.caption)
                            .foregroundStyle(studio.color(.secondaryText, scope: .settings))
                    }
                }
                HStack {
                    Text("上次唤醒")
                    Spacer()
                    Text(Self.lastWakeLine(store.lastWakeAttemptAt, store.lastWakeSource))
                        .font(.caption)
                        .foregroundStyle(studio.color(.secondaryText, scope: .settings))
                }
                HStack {
                    Text("在场")
                    Spacer()
                    Text(presence.isPresent ? "是" : "否")
                        .font(.caption)
                        .foregroundStyle(studio.color(.secondaryText, scope: .settings))
                }
                Button("立刻跑一轮（只打分入草稿）") {
                    Task { await store.runNow() }
                }
                Toggle("调试：在场也跑", isOn: $presence.debugRunWhilePresent)
            } header: {
                Text("小梦主动")
            }

            Section {
                stepperRow(
                    title: "唤醒间隔",
                    value: store.snapshot.intervalMinutes,
                    range: ActiveReachBounds.intervalMinutes,
                    suffix: "分钟"
                ) { store.setIntervalMinutes($0) }

                stepperRow(
                    title: "每日上限",
                    value: store.snapshot.dailyCap,
                    range: ActiveReachBounds.dailyCap,
                    suffix: "条"
                ) { store.setDailyCap($0) }

                stepperRow(
                    title: "破例上限",
                    value: store.snapshot.dailyBreakCap,
                    range: ActiveReachBounds.dailyBreakCap,
                    suffix: "条"
                ) { store.setDailyBreakCap($0) }

                stepperRow(
                    title: "想你的门槛",
                    value: store.snapshot.scoreThreshold,
                    range: ActiveReachBounds.scoreThreshold,
                    suffix: ""
                ) { store.setScoreThreshold($0) }
            } header: {
                Text("节奏")
            } footer: {
                Text("间隔是多久醒一次去想你。门槛是总分要过多少才入草稿。上限和破例分开算。")
            }

            Section {
                if modelChoices.isEmpty {
                    TextField("模型 id 或显示名，空着先不调", text: Binding(
                        get: { store.snapshot.modelId },
                        set: { store.setModelId($0) }
                    ))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.body, design: .monospaced))
                } else {
                    Picker("模型", selection: Binding(
                        get: { store.snapshot.modelId },
                        set: { store.setModelId($0) }
                    )) {
                        Text("还没选").tag("")
                        ForEach(modelChoices, id: \.id) { entry in
                            Text(Self.modelLabel(entry)).tag(entry.id)
                        }
                    }
                    if !store.snapshot.modelId.isEmpty,
                       !modelChoices.contains(where: { $0.id == store.snapshot.modelId }) {
                        Text("当前值不在列表里：\(store.snapshot.modelId)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(studio.color(.secondaryText, scope: .settings))
                    }
                    TextField("高级：手填 entry id / 显示名", text: Binding(
                        get: { store.snapshot.modelId },
                        set: { store.setModelId($0) }
                    ))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.caption, design: .monospaced))
                }
            } header: {
                Text("模型")
            } footer: {
                Text(modelChoices.isEmpty
                     ? "填 Minis 里模型的 entry id 或显示名。空着等于还没配。"
                     : "从已配置模型里选。仍可手填。")
            }

            Section {
                if sessions.isEmpty {
                    Text("还没有会话。空着就不发。")
                        .foregroundStyle(studio.color(.secondaryText, scope: .settings))
                }
                ForEach(sessions) { session in
                    Button {
                        let on = store.snapshot.dialogIds.contains(session.id)
                        store.setDialogSelected(session.id, selected: !on)
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: store.snapshot.dialogIds.contains(session.id)
                                  ? "checkmark.circle.fill" : "circle")
                            VStack(alignment: .leading, spacing: 2) {
                                Text(Self.sessionTitle(session))
                                Text(session.id)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(studio.color(.secondaryText, scope: .settings))
                                Text(Self.formatTime(session.updatedAt.timeIntervalSince1970))
                                    .font(.caption)
                                    .foregroundStyle(studio.color(.secondaryText, scope: .settings))
                            }
                            Spacer()
                        }
                    }
                    .foregroundStyle(studio.color(.primaryText, scope: .settings))
                }
                DisclosureGroup("高级：手动加 ID", isExpanded: $showAdvancedId) {
                    ForEach(orphanDialogIds, id: \.self) { id in
                        HStack {
                            Text(id)
                                .font(.system(.caption, design: .monospaced))
                            Spacer()
                            Button("删") { store.removeDialogId(id) }
                                .foregroundStyle(studio.color(.destructive, scope: .settings))
                        }
                    }
                    HStack {
                        TextField("会话 ID", text: $newDialogId)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.system(.body, design: .monospaced))
                        Button("加") {
                            store.addDialogId(newDialogId)
                            newDialogId = ""
                        }
                        .disabled(newDialogId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            } header: {
                Text("指定对话框")
            } footer: {
                Text("勾选才会往那儿想。一个都不勾，等于不许发。")
            }

            Section {
                stepperRow(
                    title: "超时别骚扰",
                    value: store.snapshot.quietTimeoutMinutes,
                    range: ActiveReachBounds.quietTimeoutMinutes,
                    suffix: "分钟"
                ) { store.setQuietTimeoutMinutes($0) }

                stepperRow(
                    title: "对话框活跃阈值",
                    value: store.snapshot.dialogActiveHours,
                    range: ActiveReachBounds.dialogActiveHours,
                    suffix: "小时"
                ) { store.setDialogActiveHours($0) }
            } header: {
                Text("边界")
            } footer: {
                Text("超时默认不打扰；对话框太久没动就不往那儿发。本页只存，不查活跃。")
            }

            Section {
                HStack {
                    Text("今日已发")
                    Spacer()
                    Text("\(store.snapshot.dailyCapCount)")
                        .foregroundStyle(studio.color(.secondaryText, scope: .settings))
                        .monospacedDigit()
                }
                HStack {
                    Text("今日破例")
                    Spacer()
                    Text("\(store.snapshot.dailyBreakCount)")
                        .foregroundStyle(studio.color(.secondaryText, scope: .settings))
                        .monospacedDigit()
                }
                HStack {
                    Text("计数日期")
                    Spacer()
                    Text(store.snapshot.countsDate.isEmpty ? "还没记过" : store.snapshot.countsDate)
                        .foregroundStyle(studio.color(.secondaryText, scope: .settings))
                        .font(.system(.caption, design: .monospaced))
                }
            } header: {
                Text("高级")
            } footer: {
                Text("自然日 0 点清零。")
            }

            Section {
                if store.decisions.isEmpty {
                    Text("还没有唤醒记录。")
                        .foregroundStyle(studio.color(.secondaryText, scope: .settings))
                } else {
                    ForEach(store.decisions) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(Self.formatTime(item.time))
                                    .font(.system(.caption, design: .monospaced))
                                Spacer()
                                Text(Self.dispositionLabel(item))
                                    .font(.caption.weight(.medium))
                            }
                            Text(Self.reasonLine(item))
                                .font(.caption)
                                .foregroundStyle(studio.color(.secondaryText, scope: .settings))
                        }
                    }
                }
            } header: {
                Text("最近决策")
            } footer: {
                Text("只读。每次唤醒信号都会记，不管过没过门。最多留 50 条。")
            }

            Section {
                if store.drafts.isEmpty {
                    Text("没有待发草稿。")
                        .foregroundStyle(studio.color(.secondaryText, scope: .settings))
                } else {
                    ForEach(store.drafts) { draft in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(draft.text)
                            HStack {
                                Text(Self.formatTime(draft.createdAt))
                                    .font(.system(.caption, design: .monospaced))
                                Spacer()
                                Text("情\(draft.emotion) 时\(draft.timeScore) 总\(draft.total)")
                                    .font(.caption)
                                    .foregroundStyle(studio.color(.secondaryText, scope: .settings))
                            }
                            Text(draft.wouldBreak ? "会破例 · \(draft.dialogId)" : draft.dialogId)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(studio.color(.secondaryText, scope: .settings))
                            Button("发送这条") {
                                Task { await store.sendDraft(id: draft.id) }
                            }
                        }
                    }
                    Button("发送全部待发") {
                        Task { await store.sendAllPending() }
                    }
                    Button("丢弃全部草稿", role: .destructive) {
                        store.discardAllDrafts()
                    }
                }
                if let err = store.lastSendError {
                    Text(Self.sendErrorLine(err))
                        .font(.caption)
                        .foregroundStyle(studio.color(.destructive, scope: .settings))
                }
            } header: {
                Text("待发草稿")
            } footer: {
                Text("打分只进草稿。点发送才出通知、才记账。关总闸会拆掉已排的。")
            }
        }
        .appearancePage(.settings)
        .navigationTitle("小梦主动")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            store.resetCountsIfNeeded()
        }
        .task {
            sessions = await ChatStore.shared.listSessions()
        }
    }

    private var orphanDialogIds: [String] {
        let known = Set(sessions.map(\.id))
        return store.snapshot.dialogIds.filter { !known.contains($0) }
    }

    private func stepperRow(
        title: String,
        value: Int,
        range: ClosedRange<Int>,
        suffix: String,
        onChange: @escaping (Int) -> Void
    ) -> some View {
        Stepper(value: Binding(
            get: { value },
            set: { onChange($0) }
        ), in: range) {
            HStack {
                Text(title)
                Spacer()
                Text(suffix.isEmpty ? "\(value)" : "\(value) \(suffix)")
                    .foregroundStyle(studio.color(.secondaryText, scope: .settings))
                    .monospacedDigit()
            }
        }
    }

    private static func sessionTitle(_ session: ChatSession) -> String {
        let t = session.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return t.isEmpty ? "未命名" : t
    }

    private static func modelLabel(_ entry: ModelEntry) -> String {
        let name = entry.model.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? entry.id : name
    }

    private static func formatTime(_ epoch: TimeInterval) -> String {
        let date = Date(timeIntervalSince1970: epoch)
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: date)
    }

    private static func dispositionLabel(_ item: ActiveReachDecision) -> String {
        switch item.disposition {
        case "allowed": return "过门"
        case "drafted": return "草稿"
        case "skipped": return "跳过"
        case "sent": return "已发"
        default: return "拦住"
        }
    }

    private static func lastWakeLine(_ date: Date?, _ source: String) -> String {
        guard let date else { return "还没有" }
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        let t = formatter.string(from: date)
        let src: String
        switch source {
        case "shortcuts": src = "快捷指令"
        case "keepalive": src = "保活兜底"
        case "manual": src = "手动"
        case "intent": src = "Intent"
        default: src = source.isEmpty ? "—" : source
        }
        return "\(t) · \(src)"
    }

    private static func sendErrorLine(_ err: String) -> String {
        switch err {
        case "masterOff": return "总闸关着，没发。"
        case "notAuthorized": return "系统通知没开，去设置里开。"
        case "capExhausted": return "今天额度满了，草稿还在。"
        case "scheduleFailed": return "通知没排上，没记账。"
        case "emptyText": return "这句话是空的。"
        case "missingDraft": return "这条草稿已经不在了。"
        default: return err
        }
    }

    private static func reasonLine(_ item: ActiveReachDecision) -> String {
        switch item.reason {
        case "masterOff": return "总闸关"
        case "sheIsHere": return "你在"
        case "noDialogs": return "没指定对话框"
        case "noModel": return "没配模型"
        case "noActiveDialog": return "对话框都不活跃"
        case "readFailed": return "读会话失败"
        case "modelFailed": return "模型没回上"
        case "parseFailed": return "模型结果读不懂"
        case "capExhausted": return "今天额度满了"
        case "belowThreshold": return "分不够"
        case "modelDeclined": return "模型说不发"
        case "wouldConsumeCap": return "会占一条额度"
        case "wouldBreak": return "会破例"
        case "emptyText": return "模型没写出话"
        case "notAuthorized": return "通知没开权限"
        case "scheduleFailed": return "通知没排上"
        case "cap": return "发出去了"
        case "break": return "破例发出去了"
        case "missingDraft": return "草稿没了"
        case nil:
            if item.disposition == "drafted" { return "进草稿了" }
            return item.source.isEmpty ? "—" : item.source
        default: return item.reason ?? item.source
        }
    }
}
