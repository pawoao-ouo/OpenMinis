import PhotosUI
import SwiftUI
import UIKit

struct AppearanceStudioView: View {
    @ObservedObject private var studio = AppearanceStudio.shared
    @State private var variant: AppearanceVariant = .light
    @State private var wallpaperScope: AppearanceScope = .global
    @State private var wallpaperItem: PhotosPickerItem?
    @State private var userAvatarItem: PhotosPickerItem?
    @State private var assistantAvatarItem: PhotosPickerItem?
    @State private var iconPickSlot: QuietIconSlot?
    @State private var iconItem: PhotosPickerItem?
    @State private var errorText: String?

    var body: some View {
        List {
            Section {
                themePreview
            } header: {
                Text("你的房间")
            } footer: {
                Text("默认是安静的暖纸色。下面每一项都可以换，布局不会跟着乱。")
            }

            Section {
                Picker("色盘", selection: $variant) {
                    ForEach(AppearanceVariant.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)

                ForEach(AppearanceColorRole.allCases) { role in
                    HStack(spacing: 12) {
                        ColorPicker(role.title,
                                    selection: studio.colorBinding(role,
                                                                   scope: .global,
                                                                   variant: variant),
                                    supportsOpacity: false)
                        Text("#\(studio.hex(role, scope: .global, variant: variant))")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(studio.color(.secondaryText, scope: .global,
                                                          variant: variant))
                    }
                }
            } header: {
                Text("色盘")
            } footer: {
                Text("这些颜色会流过每一页、卡片、文字、气泡和输入框。浅色和深色会跟着系统外观切换。")
            }

            Section {
                HStack(spacing: 10) {
                    ForEach(AppearancePreset.allCases) { preset in
                        Button(preset.title) { studio.applyPreset(preset) }
                            .buttonStyle(.bordered)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button("恢复默认色盘", role: .destructive) {
                    studio.resetColors()
                }
            } header: {
                Text("预设")
            }

            Section {
                let pack = studio.currentThemePack()
                VStack(alignment: .leading, spacing: 6) {
                    Text(pack.name)
                        .font(.headline)
                    Text("气泡 \(Int(pack.userBubbleRadius))/\(Int(pack.assistantBubbleRadius)) · thinking \(Int(pack.thinkingRadius))")
                        .font(.caption)
                        .foregroundStyle(studio.color(.secondaryText))
                }
                .id(studio.themePackRevision)

                Button("导出当前主题包到剪贴板") {
                    exportPackToClipboard()
                }
                Button("从剪贴板贴上主题包") {
                    importPackFromClipboard()
                }
                Button("恢复默认主题包", role: .destructive) {
                    studio.resetThemePack()
                }
            } header: {
                Text("AI 主题包")
            } footer: {
                Text("一整套：色、气泡圆角、thinking 卡片、壁纸。小梦也可以用 minis-theme 直接贴上来。")
            }

            Section {
                Picker("壁纸用于", selection: $wallpaperScope) {
                    ForEach(AppearanceScope.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }

                ZStack(alignment: .bottomTrailing) {
                    AppearanceBackdrop(scope: wallpaperScope)
                    Text(studio.hasWallpaper(wallpaperScope) ? "壁纸预览" : "纯色背景")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(studio.color(.primaryText, scope: wallpaperScope))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(studio.color(.raised, scope: wallpaperScope).opacity(0.88),
                                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .padding(10)
                }
                .frame(height: 150)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(studio.color(.border, scope: wallpaperScope), lineWidth: 0.8)
                )

                PhotosPicker(selection: $wallpaperItem, matching: .images) {
                    Label(studio.hasOwnWallpaper(wallpaperScope) ? "更换这张壁纸" : "选择壁纸",
                          systemImage: "photo")
                }

                if studio.hasOwnWallpaper(wallpaperScope) {
                    Button("改用继承的背景", role: .destructive) {
                        studio.removeWallpaper(wallpaperScope)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("壁纸压色")
                        Spacer()
                        Text("\(Int(studio.wallpaperShade * 100))%")
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $studio.wallpaperShade, in: 0...0.65, step: 0.01)
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("卡片透明度")
                        Spacer()
                        Text("\(Int(studio.surfaceOpacity * 100))%")
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $studio.surfaceOpacity, in: 0.35...1, step: 0.01)
                }
            } header: {
                Text("页面背景")
            } footer: {
                Text("可以先给全部页面设一张图，再只换你想单独打扮的那一页。压色保护文字对比；卡片透明度决定图透出来多少。")
            }

            Section {
                pairedAvatarPreview

                PhotosPicker(selection: $userAvatarItem, matching: .images) {
                    Label("选我的头像", systemImage: "person.crop.square")
                }
                if !studio.userAvatar.isEmpty {
                    Button("去掉我的头像", role: .destructive) {
                        studio.removeUserAvatar()
                    }
                }

                PhotosPicker(selection: $assistantAvatarItem, matching: .images) {
                    Label("选小梦的头像", systemImage: "sparkles.rectangle.stack")
                }
                if !SoulStore.cachedMetadata.icon.isEmpty {
                    Button("去掉小梦的头像", role: .destructive) {
                        do { try studio.removeAssistantAvatar() }
                        catch { errorText = error.localizedDescription }
                    }
                }
            } header: {
                Text("情头")
            } footer: {
                Text("两张图都会裁成方的，存在这台手机上。小梦的头像同时就是 Soul 图标，身份不会各处长不一样。")
            }

            Section {
                ForEach(QuietIconSlot.allCases) { slot in
                    HStack(spacing: 12) {
                        QuietAppIcon(id: slot.id, systemName: slot.systemName, size: 28)
                        Text(slot.title)
                        Spacer()
                        PhotosPicker(selection: Binding(
                            get: { iconPickSlot == slot ? iconItem : nil },
                            set: { newValue in
                                iconPickSlot = slot
                                iconItem = newValue
                            }
                        ), matching: .images) {
                            Text(studio.customIcon(for: slot.id) == nil ? "上传" : "更换")
                        }
                        if studio.customIcon(for: slot.id) != nil {
                            Button("还原") {
                                studio.removeIcon(for: slot.id)
                            }
                            .foregroundStyle(studio.color(.destructive))
                        }
                    }
                }
            } header: {
                Text("图标")
            } footer: {
                Text("默认图标跟着色盘走，不再用彩虹圆底。不喜欢系统图标，就在这里换成你自己的图。")
            }
        }
        .appearancePage(.settings)
        .navigationTitle("装扮")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: wallpaperItem) { item in
            guard let item else { return }
            Task { await importImage(item) { studio.setWallpaper($0, for: wallpaperScope) } }
        }
        .onChange(of: userAvatarItem) { item in
            guard let item else { return }
            Task { await importImage(item) { studio.setUserAvatar($0) } }
        }
        .onChange(of: assistantAvatarItem) { item in
            guard let item else { return }
            Task {
                await importImage(item) { image in
                    do { try studio.setAssistantAvatar(image) }
                    catch { errorText = error.localizedDescription }
                }
            }
        }
        .onChange(of: iconItem) { item in
            guard let item, let slot = iconPickSlot else { return }
            Task {
                await importImage(item) { image in
                    studio.setIcon(image, for: slot.id)
                }
                iconItem = nil
                iconPickSlot = nil
            }
        }
        .alert("这张图用不了", isPresented: Binding(
            get: { errorText != nil },
            set: { if !$0 { errorText = nil } }
        )) {
            Button("好", role: .cancel) { errorText = nil }
        } message: {
            Text(errorText ?? "")
        }
    }

    private var themePreview: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("一间可以慢慢变成你的房间")
                        .font(.headline)
                    Text("默认安静。想打扮时再动手。")
                        .font(.caption)
                        .foregroundStyle(studio.color(.secondaryText, variant: variant))
                }
                Spacer()
                Circle()
                    .fill(studio.color(.accent, variant: variant))
                    .frame(width: 18, height: 18)
            }
            HStack(spacing: 8) {
                previewSwatch(.surface)
                previewSwatch(.mutedSurface)
                previewSwatch(.userBubble)
                previewSwatch(.assistantBubble)
                previewSwatch(.input)
            }
        }
        .padding(18)
        .foregroundStyle(studio.color(.primaryText, variant: variant))
        .background(studio.color(.surface, variant: variant),
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(studio.color(.border, variant: variant), lineWidth: 0.8)
        )
        .listRowBackground(Color.clear)
    }

    private func previewSwatch(_ role: AppearanceColorRole) -> some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(studio.color(role, variant: variant))
            .frame(height: 28)
    }

    private var pairedAvatarPreview: some View {
        HStack(spacing: 12) {
            Spacer()
            VStack(spacing: 6) {
                PersonAvatarView(kind: .assistant, size: 54)
                Text(SoulStore.cachedMetadata.name.isEmpty ? "小梦" : SoulStore.cachedMetadata.name)
                    .font(.caption)
            }
            Image(systemName: "link")
                .foregroundStyle(studio.color(.accent))
            VStack(spacing: 6) {
                PersonAvatarView(kind: .user, size: 54)
                Text("醒醒").font(.caption)
            }
            Spacer()
        }
        .padding(.vertical, 8)
    }

    @MainActor
    private func importImage(_ item: PhotosPickerItem,
                             apply: @escaping @MainActor (UIImage) -> Void) async {
        defer {
            wallpaperItem = nil
            userAvatarItem = nil
            assistantAvatarItem = nil
        }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else {
            errorText = "选中的图读不出来。"
            return
        }
        apply(image)
    }

    private func exportPackToClipboard() {
        let pack = studio.exportThemePack(includeWallpaper: true)
        guard let data = try? JSONSerialization.data(withJSONObject: pack.asJSONObject(), options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            errorText = "主题包写不出来。"
            return
        }
        UIPasteboard.general.string = text
    }

    private func importPackFromClipboard() {
        guard let text = UIPasteboard.general.string,
              let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pack = try? AppearanceThemePack.decode(obj) else {
            errorText = "剪贴板里没有能用的主题包。"
            return
        }
        studio.applyThemePack(pack)
    }
}
