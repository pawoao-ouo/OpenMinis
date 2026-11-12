import SwiftUI

// [T-ambient-context 11-07] 设置 → Agent Runtime → 「她此刻的状态」。
//
// 每一行是一项，各自一个开关。她说「没开启就不喂给 ai」——所以这里不是
// 一个模糊的总开关，而是能逐项关掉：关掉那一项之后，拼装函数连标题都不
// 生成，prompt 里不存在这一行，不是「有值但被过滤」。
//
// 底部那段预览是用**真的拼装函数**算出来的（同一次调用，同一份规矩），
// 所以她在这一页看到什么，模型收到的就是什么——不会出现说明跟实现对不上。
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
        .navigationTitle(AppLocalized("她此刻的状态"))
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
        preview = AmbientContext.fragment(
            now: Date(),
            lastConversation: AmbientContextPreview.lastConversationDate(),
            isSubAgentChild: false
        ) ?? ""
    }
}

/// 预览用的「上一条消息在什么时候」。拿不到真会话（这个页面不属于任何会话）
/// 就给一个 11 分钟前的时刻——足够把间隔那一行演示出来，也说明它不是编的
/// 一个漂亮数字。
enum AmbientContextPreview {
    static func lastConversationDate() -> Date {
        Date().addingTimeInterval(-11 * 60)
    }
}