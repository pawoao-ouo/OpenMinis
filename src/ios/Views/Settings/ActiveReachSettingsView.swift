import SwiftUI

struct ActiveReachSettingsView: View {
    @ObservedObject private var store = ActiveReachStore.shared
    @ObservedObject private var studio = AppearanceStudio.shared
    @State private var newDialogId = ""

    var body: some View {
        List {
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
            } header: {
                Text("小梦主动")
            } footer: {
                Text("默认关。关的时候不唤醒、不清你对话框，只是我不伸手。")
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
            } header: {
                Text("节奏")
            } footer: {
                Text("间隔是多久醒一次去想你。上限和破例分开算，破例更紧。")
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("API 模型")
                    TextField("模型 id 或显示名，空着先不调", text: Binding(
                        get: { store.snapshot.modelId },
                        set: { store.setModelId($0) }
                    ))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.body, design: .monospaced))
                }
            } header: {
                Text("模型")
            } footer: {
                Text("只存名字，不写死、不在这一页调接口。空着等于还没配。")
            }

            Section {
                if store.snapshot.dialogIds.isEmpty {
                    Text("还没指定。空着就不发。")
                        .foregroundStyle(studio.color(.secondaryText, scope: .settings))
                }
                ForEach(store.snapshot.dialogIds, id: \.self) { id in
                    HStack {
                        Text(id)
                            .font(.system(.caption, design: .monospaced))
                        Spacer()
                        Button("删") {
                            store.removeDialogId(id)
                        }
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
            } header: {
                Text("指定对话框")
            } footer: {
                Text("只往这里面发。一个都不填，等于不许发。")
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
                Text("自然日 0 点清零。本刀只记账，不真发。")
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
                        VStack(alignment: .leading, spacing: 4) {
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
                        }
                    }
                    Button("丢弃全部草稿", role: .destructive) {
                        store.discardAllDrafts()
                    }
                }
            } header: {
                Text("待发草稿")
            } footer: {
                Text("只存不发。cap 还没占。没有立即发送。")
            }
        }
        .appearancePage(.settings)
        .navigationTitle("小梦主动")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            store.resetCountsIfNeeded()
        }
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
                Text("\(value) \(suffix)")
                    .foregroundStyle(studio.color(.secondaryText, scope: .settings))
                    .monospacedDigit()
            }
        }
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
        default: return "拦住"
        }
    }

    private static func reasonLine(_ item: ActiveReachDecision) -> String {
        switch item.reason {
        case "masterOff": return "总闸关"
        case "noDialogs": return "没指定对话框"
        case "noModel": return "没配模型"
        case "noActiveDialog": return "对话框都不活跃"
        case "readFailed": return "读会话失败"
        case "parseFailed": return "模型结果读不懂"
        case "capExhausted": return "今天额度满了"
        case "belowThreshold": return "分不够"
        case "modelDeclined": return "模型说不发"
        case "wouldConsumeCap": return "会占一条额度"
        case "wouldBreak": return "会破例"
        case "emptyText": return "模型没写出话"
        case nil:
            if item.disposition == "drafted" { return "进草稿了" }
            return item.source.isEmpty ? "—" : item.source
        default: return item.reason ?? item.source
        }
    }
}
