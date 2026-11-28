import SwiftUI

// [T-ambient-context 11-07] 设置 → Agent Runtime → 「她此刻的状态」。
//
// 每一行是一项，各自一个开关。她说「没开启就不喂给 ai」——所以这里不是
// 一个模糊的总开关，而是能逐项关掉：关掉那一项之后，拼装函数连标题都不
// 生成，prompt 里不存在这一行，不是「有值但被过滤」。
//
// 底部那段预览是用**真的拼装函数**算出来的（同一次调用，同一份规矩），
// 数值也全是真的：时间是现在，间隔取最近一条可见会话最后一次有消息
// 的时刻（ChatStore 里存着的），电量和网络都是实时读的。这一页没有正
// 在进行的轮次，所以间隔用的是最近会话的、不是某一轮的——但它绝不
// 是编出来的数字。
struct AmbientContextSettingsView: View {
    @ObservedObject private var fontSettings = FontSettings.shared
    @State private var revision = 0
    @State private var preview = ""
    @State private var customRule = ""

    var body: some View {
        Form {
            Section {
                ForEach(AmbientSignal.allCases) { signal in
                    row(signal)
                }
            } header: {
                Text(AppLocalized("每轮随消息一起发给模型"))
            } footer: {
                Text(AppLocalized("这些内容会随每条消息发给模型服务商。关掉的项连一行字都不会出现。它们不会出现在聊天记录里，模型也不会复述——同一条规矩写在它收到的指令里。"))
            }

            Section {
                TextEditor(text: $customRule)
                    .font(.system(size: fontSettings.scaledApp(12), design: .monospaced))
                    .frame(minHeight: 120)
                    .onChange(of: customRule) { _, newValue in
                        UserDefaults.standard.set(newValue, forKey: "ambient.usageRule")
                        AmbientSignal.bumpRevision()
                        revision += 1
                    }
            } header: {
                Text(AppLocalized("AI 如何感知这些信息"))
            } footer: {
                Text(AppLocalized("这里是写给模型的指令，解释该怎么用上面那些信息。你可以修改这段话，让它更符合你的期望。"))
            }

            Section {
                Text(preview.isEmpty
                     ? AppLocalized("现在没有任何可报的项，模型这一轮不会收到这一段。")
                     : preview)
                    .font(.system(size: fontSettings.scaledApp(12), design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } header: {
                Text(AppLocalized("这一轮实际会发的内容"))
            } footer: {
                Text(AppLocalized("照当前真实状态算的：歌没在放就不会有歌，间隔不到 3 分钟就不会有间隔。"))
            }
        }
        .navigationTitle(AppLocalized("当前状态"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            customRule = UserDefaults.standard.string(forKey: "ambient.usageRule") ?? AmbientContext.defaultUsageRule
            refreshPreview()
        }
        .onChange(of: revision) { _, _ in refreshPreview() }
        .settingsPage()
    }

    private func row(_ signal: AmbientSignal) -> some View {
        Toggle(isOn: Binding(
            get: { signal.isEnabled },
            set: { newValue in
                AmbientSignal.setEnabled(newValue, for: signal)
                // 缓存是每个 turn 的，改完开关这一轮就该按新设置走。
                AmbientSignal.bumpRevision()
                revision += 1
            }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text(signal.title)
                Text(signal.detail)
                    .font(.system(size: fontSettings.scaledApp(12)))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func refreshPreview() {
        // ChatStore 是 actor，读会话要 await；包在 Task 里，调用点不用动。
        Task { @MainActor in
            preview = AmbientContext.fragment(
                now: Date(),
                lastConversation: await AmbientContextPreview.lastConversationDate(),
                isSubAgentChild: false
            ) ?? ""
        }
    }
}

/// 预览用的「上一条消息在什么时候」：最近一条可见会话最后一次有消息
/// 的时刻。
///
/// 取 ChatSession.updatedAt——每次有消息落盘，ChatStore.appendMessages
/// 都会把它刷成现在（见 touchSession），所以它就是那条会话最后一条
/// 消息的时刻。子代理的隐藏会话不算（和会话列表同一条过滤）。
/// 没有会话时返回 nil，间隔那行直接不显示——绝不编一个时间顶上。
/// （updatedAt 也会被改名刷一下，极少数情况下间隔会是改名那一刻；
/// 它仍然是真实存着的时间，不是编出来的。）
enum AmbientContextPreview {
    static func lastConversationDate() async -> Date? {
        await ChatStore.shared.listSessions().filter { !$0.isChild }.first?.updatedAt
    }
}
