import SwiftUI

// [A-落地] 设置 → 「通用」：启动会话、语言、屏幕常亮。
// 三个控件都只绑已有的后端键，不新建键；默认值照代码里的默认值：
// 启动会话默认自动（注册表 appearance.launchScreen defaultIndex 0）、
// 语言默认跟随系统（appLanguage 默认 ""）、屏幕常亮默认关
// （注册表 chat.keepScreenAwake defaultValue false）。
struct GeneralSettingsView: View {
    @ObservedObject private var fontSettings = FontSettings.shared
    @AppStorage("launchScreen") private var launchScreen: Int = 0
    @AppStorage("appLanguage") private var appLanguage: String = ""
    @AppStorage("keepScreenAwakeDuringTasks") private var keepScreenAwakeDuringTasks: Bool = false

    /// 语言选项：仓库自带的 .lproj 仅此 9 种（de / en / es / fr / ja /
    /// ko / ru / zh-Hans / zh-Hant），不编别的。行文案写各语言自称，
    /// 不用本地化。空串 = 跟随系统。
    private static let languages: [(code: String, name: String)] = [
        ("en", "English"),
        ("zh-Hans", "简体中文"),
        ("zh-Hant", "繁體中文"),
        ("ja", "日本語"),
        ("ko", "한국어"),
        ("de", "Deutsch"),
        ("fr", "Français"),
        ("es", "Español"),
        ("ru", "Русский"),
    ]

    var body: some View {
        Form {
            Section {
                Picker(selection: $launchScreen) {
                    Text(AppLocalized("自动")).tag(0)
                    Text(AppLocalized("上次会话")).tag(1)
                    Text(AppLocalized("新会话")).tag(2)
                    Text(AppLocalized("首页")).tag(3)
                } label: {
                    rowTitle(AppLocalized("启动会话"), AppLocalized("启动会话说明"))
                }
                Picker(selection: Binding(
                    get: { appLanguage },
                    set: { newValue in
                        guard newValue != appLanguage else { return }
                        // 先写 reopen 标记再改 appLanguage：根
                        // `.id(appLanguage)` 重建会把整棵树拆掉重挂，
                        // ContentView 靠这个标记把设置页重新打开，
                        // SettingsSheet 再按标记推回本页。旧外观页的
                        // 语言选择器就是这个写法（随旧页清空一起没了）。
                        UserDefaults.standard.set("general", forKey: "pendingSettingsReopen")
                        appLanguage = newValue
                    }
                )) {
                    Text(AppLocalized("跟随系统")).tag("")
                    ForEach(Self.languages, id: \.code) { lang in
                        Text(lang.name).tag(lang.code)
                    }
                } label: {
                    rowTitle(AppLocalized("语言"), AppLocalized("语言说明"))
                }
                Toggle(isOn: $keepScreenAwakeDuringTasks) {
                    rowTitle(AppLocalized("屏幕常亮"), AppLocalized("屏幕常亮说明"))
                }
            } footer: {
                Text(AppLocalized("通用页说明"))
            }
        }
        .navigationTitle(AppLocalized("通用"))
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
