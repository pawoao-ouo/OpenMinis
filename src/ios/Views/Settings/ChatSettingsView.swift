import SwiftUI

// [A-落地] 设置 → 「聊天」：聊天时的行为控件。入口在装扮中心，页内仍是这四项行为设置。
//
// 四个控件都只绑已有的后端键，不新建键；默认值照代码里的默认值：
// 自动分组默认开（MinisApp.swift 注册 true）、回车键默认换行
// （注册表 chat.returnKey defaultIndex 0）、回复后自动聚焦默认开
// （AIChatView.swift:1834 `?? true`）、工具预览默认开
// （ToolLiveSheet.swift:207 @AppStorage = true）。
struct ChatSettingsView: View {
    @ObservedObject private var fontSettings = FontSettings.shared
    @AppStorage("autoGroupingEnabled") private var autoGroupingEnabled: Bool = true
    @AppStorage("returnKeyBehavior") private var returnKeyBehavior: Int = 0
    @AppStorage("chat.autoFocusAfterReply") private var autoFocusAfterReply: Bool = true
    @AppStorage("toolPreviewEnabled") private var toolPreviewEnabled: Bool = true

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $autoGroupingEnabled) {
                    rowTitle(AppLocalized("自动分组"), AppLocalized("自动分组说明"))
                }
                Picker(selection: $returnKeyBehavior) {
                    Text(AppLocalized("换行")).tag(0)
                    Text(AppLocalized("发送")).tag(1)
                } label: {
                    rowTitle(AppLocalized("回车键"), AppLocalized("回车键说明"))
                }
                Toggle(isOn: $autoFocusAfterReply) {
                    rowTitle(AppLocalized("回复后自动聚焦"), AppLocalized("自动聚焦说明"))
                }
                Toggle(isOn: $toolPreviewEnabled) {
                    rowTitle(AppLocalized("工具预览"), AppLocalized("工具预览说明"))
                }
            } footer: {
                Text(AppLocalized("聊天页说明"))
            }
        }
        .navigationTitle(AppLocalized("聊天"))
        .navigationBarTitleDisplayMode(.inline)
        .settingsPage()
    }

    private func rowTitle(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(detail)
                .font(.system(size: fontSettings.scaledApp(12)))
                .foregroundStyle(.secondary)
        }
    }
}
