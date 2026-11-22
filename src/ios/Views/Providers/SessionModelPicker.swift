import SwiftUI

private let pickerLog = AppLogger(category: "ModelPicker")

/// In-session model picker — thin wrapper around `UnifiedModelPicker` that adds
/// session binding logic and the non-text-output confirmation alert.
struct SessionModelPicker: View {
    let sessionId: String?
    var ensureSessionId: (() async -> String)?
    /// [input-bar-liquid-glass] 思考强度走 vm 那条读写(和加号抽屉里的
    /// 思考强度 sheet 同源):草稿态的 pending 档位、按模型夹取、
    /// 组默认档位都在 vm 里,store 直读会丢这些。三个都传才挂思考分区。
    let thinkingCurrent: (@MainActor () -> ThinkingLevel)?
    let thinkingAvailable: (@MainActor () -> [ThinkingLevel])?
    let onSetThinkingLevel: (@MainActor (ThinkingLevel) -> Void)?
    @ObservedObject private var store = ProviderConfigStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var pendingNonTextOutput: PendingSelection?
    /// [picker-model-tuning] 快速模式 / 增强缓存搬到这里：只有当前模型真支持
    /// 才出现那一行，不再是加号面板里点了只弹「不支持」的磁贴。
    @AppStorage(OpenAIProvider.fastModeDefaultsKey) private var codexFastModeEnabled: Bool = false
    @AppStorage(AIChatViewModel.enhancedCacheDefaultsKey) private var enhancedCacheEnabled: Bool = false
    @State private var showEnhancedCacheAlert = false
    /// 刚点过的那条模型。列表点完不会立刻关页，开关区要跟着手上这条走。
    @State private var tuningProbe: ModelEntry?
    /// [input-bar-liquid-glass] 上次开着的档位:深度思考开关关掉再开时
    /// 回到它,而不是每次都落到 Medium。
    @State private var lastEnabledThinkingLevel: ThinkingLevel?

    private struct PendingSelection: Identifiable {
        let id = UUID()
        let entry: ModelEntry
        let group: ModelGroup?
        let modalityLabel: String
        let isGroupBind: Bool
    }

    init(
        sessionId: String?,
        ensureSessionId: (() async -> String)? = nil,
        thinkingCurrent: (@MainActor () -> ThinkingLevel)? = nil,
        thinkingAvailable: (@MainActor () -> [ThinkingLevel])? = nil,
        onSetThinkingLevel: (@MainActor (ThinkingLevel) -> Void)? = nil
    ) {
        self.sessionId = sessionId
        self.ensureSessionId = ensureSessionId
        self.thinkingCurrent = thinkingCurrent
        self.thinkingAvailable = thinkingAvailable
        self.onSetThinkingLevel = onSetThinkingLevel
    }

    private var currentEntryId: String? {
        guard let sid = sessionId,
              let binding = store.binding(for: sid) else { return nil }
        switch binding.primarySource {
        case .directEntry(let entryId, _): return entryId
        case .group(_, let resolvedEntryId): return resolvedEntryId
        }
    }

    private var currentGroupId: String? {
        guard let sid = sessionId else { return store.defaultPrimaryGroupId }
        guard let binding = store.binding(for: sid) else {
            return store.defaultPrimaryGroupId
        }
        if case .group(let groupId, _) = binding.primarySource {
            return groupId
        }
        return nil
    }

    var body: some View {
        UnifiedModelPicker(config: .init(
            title: "Choose Model",
            mode: .single,
            groupScope: .all,
            dismissOnSelect: false,
            currentEntryId: { [self] in currentEntryId },
            currentGroupId: { [self] in currentGroupId },
            onSelect: { entry in handleEntryTap(entry) },
            onSelectGroup: { group in handleGroupTap(group) },
            onSelectInGroup: { entry, group in handleEntryTap(entry, inGroup: group) },
            extraSection: { AnyView(modelTuningSection) },
            thinkingSection: { AnyView(thinkingSectionView) },
            channelsSection: { AnyView(channelsSectionView) }
        ))
        .alert(
            "Enhanced Cache",
            isPresented: $showEnhancedCacheAlert
        ) {
            Button(AppLocalized("Enable")) {
                UserDefaults.standard.set(true, forKey: "enhancedCacheConfirmed")
                enhancedCacheEnabled = true
            }
            Button(AppLocalized("Cancel"), role: .cancel) {}
        } message: {
            Text("Enhanced cache extends the cache TTL from 5 minutes to 1 hour. Cache writes cost more (2x vs 1.25x base price), but cache reads remain cheap (0.1x). Recommended for long coding sessions where request gaps may exceed 5 minutes.")
        }
        .alert(
            AppLocalized("This model may not work as an Agent"),
            isPresented: Binding(
                get: { pendingNonTextOutput != nil },
                set: { if !$0 { pendingNonTextOutput = nil } }
            ),
            presenting: pendingNonTextOutput
        ) { selection in
            Button(AppLocalized("Choose another model"), role: .cancel) {
                pendingNonTextOutput = nil
            }
            Button(AppLocalized("Use anyway")) {
                let entry = selection.entry
                let group = selection.group
                let isGroupBind = selection.isGroupBind
                pendingNonTextOutput = nil
                if isGroupBind, let group {
                    bindToGroup(group)
                } else {
                    bindToEntry(entry, inGroup: group)
                }
            }
        } message: { selection in
            Text(AppLocalized("\(selection.entry.model.displayName) outputs \(selection.modalityLabel) and usually can't drive an Agent task. Pick a text-output model for the session, or add this model to Available Models in Agent Loop so the agent can call it via minis-model-use when it needs to generate \(selection.modalityLabel)."))
        }
    }

    // MARK: - Model tuning (fast mode / enhanced cache)

    private var activeInstanceAndModel: (instance: ProviderInstance, modelId: String)? {
        // 刚在列表里点过的那条优先：点完不一定马上关页（dismissOnSelect=false），
        // 开关区得跟着手上选的模型走，而不是还盯着旧绑定。
        if let probe = tuningProbe,
           let instance = store.instance(for: probe.providerInstanceId) {
            return (instance, probe.model.id)
        }
        return SessionModelDisplay(store: store).resolvedInstanceAndModel(for: sessionId)
    }

    /// 快速模式 = 给请求加 `service_tier: priority`。只对 gpt 系 + Responses
    /// 接口（或 OAuth 直连 OpenAI）有效，别的模型发了也是白花。
    private var supportsFastMode: Bool {
        guard let (instance, modelId) = activeInstanceAndModel else { return false }
        guard modelId.lowercased().contains("gpt") else { return false }
        if instance.providerType == .openAIResponses { return true }
        return instance.providerType == .openAI
            && instance.credentialType == .oauth
            && (instance.customBaseURL?.isEmpty ?? true)
    }

    /// 增强缓存 = 提示词缓存 TTL 从 5 分钟延到 1 小时。只对 Anthropic 官方
    /// 直连有效，自建中转不走这套协议。
    private var supportsEnhancedCache: Bool {
        guard let (instance, _) = activeInstanceAndModel else { return false }
        guard instance.providerType == .anthropic else { return false }
        if let url = instance.customBaseURL, !url.isEmpty { return false }
        return true
    }

    /// 只在当前模型支持时出现对应行；两个都不支持就整块不显示，
    /// 不留一个点不动的空壳。
    @ViewBuilder
    private var modelTuningSection: some View {
        if supportsFastMode || supportsEnhancedCache {
            Section {
                if supportsFastMode {
                    Toggle(isOn: $codexFastModeEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Label(AppLocalized("Fast Mode"), systemImage: "bolt.fill")
                            Text("Sends service_tier: priority so this model answers sooner. Costs more per request.")
                                .font(.caption)
                                .foregroundStyle(MinisTheme.secondaryText)
                        }
                    }
                }
                if supportsEnhancedCache {
                    Toggle(isOn: Binding(
                        get: { enhancedCacheEnabled },
                        set: { on in
                            if on && !UserDefaults.standard.bool(forKey: "enhancedCacheConfirmed") {
                                showEnhancedCacheAlert = true
                            } else {
                                enhancedCacheEnabled = on
                            }
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Label(AppLocalized("Enhanced Cache"), systemImage: "clock.badge.checkmark.fill")
                            Text("Keeps the prompt cache alive for 1 hour instead of 5 minutes. Cache writes cost more, reads stay cheap.")
                                .font(.caption)
                                .foregroundStyle(MinisTheme.secondaryText)
                        }
                    }
                }
            } header: {
                Text("Model Options")
            }
        }
    }

    // MARK: - Thinking + channels (unified sheet)

    /// [input-bar-liquid-glass] 思考强度分区:深度思考开关 + 档位行,
    /// 照 HTML modelSheet 的 effort 子页(档位行 + 深度思考链开关)。
    /// 只在当前模型有档位可选时出现;点档位行就是开着选那个档,
    /// 不照 HTML 那样先把档位行置灰——和加号抽屉里的思考强度 sheet
    /// 同一个行为,点一下就能开。
    @ViewBuilder
    private var thinkingSectionView: some View {
        if let current = thinkingCurrent,
           let available = thinkingAvailable,
           let onSet = onSetThinkingLevel,
           !available.isEmpty {
            Section {
                Toggle(isOn: Binding(
                    get: { current().isEnabled },
                    set: { on in
                        if on {
                            let restore = lastEnabledThinkingLevel
                                ?? (available.contains(.medium) ? .medium : available[0])
                            lastEnabledThinkingLevel = restore
                            onSet(restore)
                        } else {
                            let cur = current()
                            if cur.isEnabled { lastEnabledThinkingLevel = cur }
                            onSet(.off)
                        }
                    }
                )) {
                    Label(AppLocalized("Deep Thinking"), systemImage: "brain")
                }
                ForEach(available, id: \.self) { level in
                    Button { onSet(level) } label: {
                        HStack {
                            Image("ThinkingIcon")
                                .resizable()
                                .frame(width: 16, height: 16)
                            Text(level.displayName)
                                .foregroundStyle(.primary)
                            Spacer()
                            if current() == level {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(ChatColors.accent)
                                    .fontWeight(.semibold)
                            }
                        }
                    }
                }
            } header: {
                Text("Thinking Intensity")
            } footer: {
                Text("Thinking is passed to models that support it as a reasoning parameter.")
            }
        }
    }

    /// 有模型的服务商,按模型列表同一个 type-major 顺序排(见
    /// UnifiedModelPicker.entriesByInstance);没模型的实例不列,
    /// 开关它对列表没影响。
    private var channelInstances: [ProviderInstance] {
        var result: [ProviderInstance] = []
        var seen = Set<String>()
        for type in ProviderType.allCases {
            for instance in store.instances where instance.providerType == type {
                guard !seen.contains(instance.id) else { continue }
                seen.insert(instance.id)
                guard store.modelEntries.contains(where: { $0.providerInstanceId == instance.id && !$0.isHidden }) else { continue }
                result.append(instance)
            }
        }
        return result
    }

    private var enabledChannelCount: Int {
        channelInstances.filter { store.instance(for: $0.id)?.isEnabled == true }.count
    }

    /// [input-bar-liquid-glass] 渠道开关分区:每个服务商一行开关,
    /// 照 HTML modelSheet 的 channels 子页。关掉的渠道名下模型立刻
    /// 从上面的列表里藏起来,随时可重新开启。至少留一个开着——
    /// 全关了会话就没模型可用,和 HTML 的「请至少保留一个可用渠道」一样。
    @ViewBuilder
    private var channelsSectionView: some View {
        let channels = channelInstances
        if !channels.isEmpty {
            Section {
                ForEach(channels) { instance in
                    Toggle(isOn: Binding(
                        get: { store.instance(for: instance.id)?.isEnabled ?? false },
                        set: { on in setChannelEnabled(instance, on) }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(instance.label)
                            if let url = instance.customBaseURL, !url.isEmpty {
                                Text(url)
                                    .font(.caption)
                                    .foregroundStyle(MinisTheme.secondaryText)
                            }
                        }
                    }
                }
            } header: {
                Text("Channels")
            } footer: {
                Text(AppLocalized("Enabled \(enabledChannelCount) of \(channels.count) channels"))
            }
        }
    }

    private func setChannelEnabled(_ instance: ProviderInstance, _ enabled: Bool) {
        if !enabled && enabledChannelCount <= 1 {
            MinisToast.show(AppLocalized("Keep at least one channel enabled"))
            return
        }
        var updated = instance
        updated.isEnabled = enabled
        store.updateInstance(updated)
    }

    // MARK: - Non-text output guard

    private func nonTextOutputLabel(for model: LLMModel) -> String? {
        guard let modality = model.modalityOverride else { return nil }
        if modality.contains(.imageOutput) { return AppLocalized("image") }
        if modality.contains(.audioOutput) { return AppLocalized("audio") }
        if modality.contains(.videoOutput) { return AppLocalized("video") }
        return nil
    }

    private func handleEntryTap(_ entry: ModelEntry, inGroup group: ModelGroup? = nil) {
        tuningProbe = entry
        if let label = nonTextOutputLabel(for: entry.model) {
            pendingNonTextOutput = PendingSelection(entry: entry, group: group, modalityLabel: label, isGroupBind: false)
            return
        }
        bindToEntry(entry, inGroup: group)
    }

    private func handleGroupTap(_ group: ModelGroup) {
        guard let sid = sessionId,
              let resolvedEntryId = ModelGroupRouter.resolve(group: group, sessionId: sid, store: store),
              let resolvedEntry = store.entry(for: resolvedEntryId) else {
            bindToGroup(group)
            return
        }
        tuningProbe = resolvedEntry
        if let label = nonTextOutputLabel(for: resolvedEntry.model) {
            pendingNonTextOutput = PendingSelection(entry: resolvedEntry, group: group, modalityLabel: label, isGroupBind: true)
            return
        }
        bindToGroup(group)
    }

    // MARK: - Session Binding

    private func resolveSessionId() async -> String? {
        if let sid = sessionId { return sid }
        return await ensureSessionId?()
    }

    private func bindToGroup(_ group: ModelGroup) {
        Task {
            guard let sid = await resolveSessionId() else { return }
            let resolvedEntryId = ModelGroupRouter.resolve(group: group, sessionId: sid, store: store) ?? ""
            let source = SessionModelSource.group(groupId: group.id, resolvedEntryId: resolvedEntryId)
            let existing = store.binding(for: sid)
            let binding = SessionModelBinding(
                sessionId: sid,
                primarySource: source,
                subModelSource: existing?.subModelSource
            )
            store.setBinding(binding, for: sid)
            if let thinkLevel = group.defaultThinkingLevel {
                var cfg = store.inferenceConfig(for: sid) ?? SessionInferenceConfig()
                cfg.thinkingLevel = thinkLevel
                store.setInferenceConfig(cfg, for: sid)
            }
            if let entry = store.entry(for: resolvedEntryId) {
                await ChatStore.shared.updateSessionModelId(sid, modelId: entry.model.id)
            }
            dismiss()
        }
    }

    private func bindToEntry(_ entry: ModelEntry, inGroup group: ModelGroup? = nil) {
        Task {
            guard let sid = await resolveSessionId() else { return }
            let source: SessionModelSource
            if let group {
                source = .group(groupId: group.id, resolvedEntryId: entry.id)
            } else {
                source = .directEntry(modelEntryId: entry.id)
            }
            let existing = store.binding(for: sid)
            let binding = SessionModelBinding(
                sessionId: sid,
                primarySource: source,
                subModelSource: existing?.subModelSource
            )
            store.setBinding(binding, for: sid)
            if let group, let thinkLevel = group.defaultThinkingLevel {
                var cfg = store.inferenceConfig(for: sid) ?? SessionInferenceConfig()
                cfg.thinkingLevel = thinkLevel
                store.setInferenceConfig(cfg, for: sid)
            }
            await ChatStore.shared.updateSessionModelId(sid, modelId: entry.model.id)
            dismiss()
        }
    }
}

// MARK: - Compact Display Helper

@MainActor
struct SessionModelDisplay {
    let store: ProviderConfigStore
    var draftGroupId: String? = nil

    func displayName(for sessionId: String?) -> String {
        if sessionId == nil, let gid = draftGroupId,
           let group = store.group(for: gid) {
            return group.name
        }
        guard let sid = sessionId,
              let binding = store.binding(for: sid) else {
            return defaultDisplayName()
        }

        switch binding.primarySource {
        case .directEntry(let entryId, _):
            if let entry = store.entry(for: entryId) {
                return entry.model.displayName
            }
            return entryId
        case .group(let groupId, _):
            return store.group(for: groupId)?.name ?? "Group"
        }
    }

    func resolvedDetail(for sessionId: String?) -> (providerLabel: String, modelName: String)? {
        if sessionId == nil, let gid = draftGroupId {
            return resolvedDetail(forGroupId: gid)
        }
        guard let sid = sessionId,
              let binding = store.binding(for: sid) else {
            return defaultResolvedDetail()
        }

        let entryId: String
        switch binding.primarySource {
        case .directEntry(let eid, _): entryId = eid
        case .group(_, let eid): entryId = eid
        }

        guard let entry = store.entry(for: entryId),
              let instance = store.instance(for: entry.providerInstanceId) else { return nil }
        return (instance.label, entry.model.displayName)
    }

    private func defaultResolvedDetail() -> (providerLabel: String, modelName: String)? {
        guard let groupId = store.defaultPrimaryGroupId else { return nil }
        return resolvedDetail(forGroupId: groupId)
    }

    /// [T-codex-fast-mode] Resolve the ProviderInstance AND model id behind
    /// the session's active model — same resolution order as resolvedDetail
    /// (draft group → binding → default group). Callers inspect
    /// credentialType/providerType/model (e.g. the "..." menu's Fast Mode
    /// gate: Responses-API providers with a gpt-family model).
    func resolvedInstanceAndModel(for sessionId: String?) -> (instance: ProviderInstance, modelId: String)? {
        if sessionId == nil, let gid = draftGroupId {
            return resolvedInstanceAndModel(forGroupId: gid)
        }
        guard let sid = sessionId,
              let binding = store.binding(for: sid) else {
            guard let groupId = store.defaultPrimaryGroupId else { return nil }
            return resolvedInstanceAndModel(forGroupId: groupId)
        }
        let entryId: String
        switch binding.primarySource {
        case .directEntry(let eid, _): entryId = eid
        case .group(_, let eid): entryId = eid
        }
        guard let entry = store.entry(for: entryId),
              let instance = store.instance(for: entry.providerInstanceId) else { return nil }
        return (instance, entry.model.id)
    }

    private func resolvedInstanceAndModel(forGroupId groupId: String) -> (instance: ProviderInstance, modelId: String)? {
        guard let group = store.group(for: groupId) else { return nil }
        let resolved = group.memberEntryIds.lazy.compactMap { eid -> (ProviderInstance, String)? in
            guard let entry = store.entry(for: eid), !entry.isHidden,
                  let instance = store.instance(for: entry.providerInstanceId),
                  instance.isEnabled, instance.hasAnyCredential else { return nil }
            return (instance, entry.model.id)
        }.first
        if let resolved { return resolved }
        guard let firstEntryId = group.memberEntryIds.first,
              let entry = store.entry(for: firstEntryId),
              let instance = store.instance(for: entry.providerInstanceId) else { return nil }
        return (instance, entry.model.id)
    }

    private func resolvedDetail(forGroupId groupId: String) -> (providerLabel: String, modelName: String)? {
        guard let group = store.group(for: groupId) else { return nil }
        let resolved = group.memberEntryIds.lazy.compactMap { eid -> (ProviderInstance, ModelEntry)? in
            guard let entry = store.entry(for: eid), !entry.isHidden,
                  let instance = store.instance(for: entry.providerInstanceId),
                  instance.isEnabled, instance.hasAnyCredential else { return nil }
            return (instance, entry)
        }.first
        if let (instance, entry) = resolved {
            return (instance.label, entry.model.displayName)
        }
        guard let firstEntryId = group.memberEntryIds.first,
              let entry = store.entry(for: firstEntryId),
              let instance = store.instance(for: entry.providerInstanceId) else { return nil }
        return (instance.label, entry.model.displayName)
    }

    func isGroupBound(for sessionId: String?) -> Bool {
        if sessionId == nil, let gid = draftGroupId,
           store.group(for: gid) != nil {
            return true
        }
        guard let sid = sessionId,
              let binding = store.binding(for: sid) else { return false }
        if case .group = binding.primarySource { return true }
        return false
    }

    private func defaultDisplayName() -> String {
        if let groupId = store.defaultPrimaryGroupId,
           let group = store.group(for: groupId) {
            return group.name
        }
        return AppLocalized("No model selected")
    }
}
