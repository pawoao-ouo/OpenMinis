import SwiftUI
import PhotosUI
import UIKit

// MARK: - 装扮中心 (DressingShopView)
// 统一接入 AppearanceStudio, BubbleStylePackStore, AvatarPendantStore,
// UploadedFontStore, FontSettings, AppearanceThemePackStore。
// 按钮做小做精致，iOS 26 胶囊与抽屉交互。

struct DressingShopView: View {
    @AppStorage(AppearanceMode.defaultsKey) private var appearanceModeRaw: Int = 0
    @StateObject private var studio = AppearanceStudio.shared
    @ObservedObject private var bubbleStore = BubbleStylePackStore.shared
    @ObservedObject private var pendantStore = AvatarPendantStore.shared
    @ObservedObject private var fontStore = UploadedFontStore.shared

    @State private var activeSheet: DressingSheetDestination? = nil
    @State private var toastMessage: String? = nil
    @State private var toastTask: Task<Void, Never>? = nil

    var body: some View {
        NavigationStack {
            ZStack {
                // 背景：统一壁纸与主题底板
                AppearanceBackdrop(scope: .settings)
                    .ignoresSafeArea()

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 16) {
                        // 1. 顶栏模式切换与状态胶囊
                        topModeBar

                        // 2. 实时微缩预览卡 (Live Preview Dock)
                        livePreviewDock

                        // 3. 全局透光与遮罩三旋钮卡片
                        globalDialsCard

                        // 4. 六大核心入口网格 (Bento Grid)
                        bentoGrid

                        // 5. 底部便捷重置与快速动作
                        footerQuickActions

                        Spacer(minLength: 40)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                }
            }
            .navigationTitle(AppLocalized("装扮中心"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        haptic()
                        activeSheet = .presets
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 12, weight: .semibold))
                            Text(AppLocalized("预设"))
                                .font(.system(size: 13, weight: .medium))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(CSSThemeVariables.accentSoft(scope: .settings))
                        .foregroundStyle(CSSThemeVariables.accent(scope: .settings))
                        .clipShape(Capsule())
                    }
                }
            }
            .sheet(item: $activeSheet) { dest in
                sheetView(for: dest)
                    .presentationDragIndicator(.visible)
                    .presentationDetents([.fraction(0.72), .large])
            }
            .overlay(alignment: .bottom) {
                if let msg = toastMessage {
                    Text(msg)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(CSSThemeVariables.card(scope: .settings))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(CSSThemeVariables.textMain(scope: .settings))
                        .clipShape(Capsule())
                        .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
                        .padding(.bottom, 24)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
    }

    private func showToast(_ text: String) {
        toastTask?.cancel()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            toastMessage = text
        }
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if !Task.isCancelled {
                withAnimation(.easeOut(duration: 0.25)) {
                    toastMessage = nil
                }
            }
        }
    }

    private func haptic() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}


// MARK: - 主页面子组件扩展

extension DressingShopView {

    // 1. 顶栏模式切换胶囊
    private var topModeBar: some View {
        HStack(spacing: 8) {
            Text(AppLocalized("色彩模式"))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(CSSThemeVariables.textDim(scope: .settings))

            Spacer()

            HStack(spacing: 4) {
                modePill(title: AppLocalized("自动"), mode: .system)
                modePill(title: AppLocalized("日间"), mode: .light)
                modePill(title: AppLocalized("夜间"), mode: .dark)
            }
            .padding(3)
            .background(CSSThemeVariables.surfaceFill(scope: .settings))
            .clipShape(Capsule())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(CSSThemeVariables.card(scope: .settings).opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(CSSThemeVariables.divider(scope: .settings), lineWidth: 0.5)
        )
    }

    private func modePill(title: String, mode: AppearanceMode) -> some View {
        let isSelected = appearanceModeRaw == mode.rawValue
        return Button {
            haptic()
            withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                appearanceModeRaw = mode.rawValue
            }
        } label: {
            Text(title)
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(isSelected ? CSSThemeVariables.card(scope: .settings) : Color.clear)
                .foregroundStyle(isSelected ? CSSThemeVariables.textMain(scope: .settings) : CSSThemeVariables.textDim(scope: .settings))
                .clipShape(Capsule())
                .shadow(color: isSelected ? .black.opacity(0.06) : .clear, radius: 3, y: 1)
        }
    }

    // 2. 实时微缩预览卡片
    private var livePreviewDock: some View {
        VStack(spacing: 12) {
            HStack(alignment: .center, spacing: 8) {
                // 主题标题与状态小标签
                VStack(alignment: .leading, spacing: 3) {
                    Text(studio.currentThemePack().name)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(CSSThemeVariables.textMain(scope: .settings))

                    HStack(spacing: 6) {
                        Circle()
                            .fill(CSSThemeVariables.accent(scope: .settings))
                            .frame(width: 7, height: 7)

                        Text(AppearanceFontFamily.parse(studio.currentThemePack().fontFamily).title + " · " + (bubbleStore.appliedPack(for: .user)?.title ?? AppLocalized("默认气泡")))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(CSSThemeVariables.textDim(scope: .settings))
                    }
                }

                Spacer()

                // 撤销胶囊
                HStack(spacing: 6) {
                    if studio.canUndoThemeReset {
                        Button {
                            haptic()
                            if studio.undoThemeReset() {
                                showToast(AppLocalized("已撤销上一次重置"))
                            }
                        } label: {
                            Image(systemName: "arrow.uturn.backward")
                                .font(.system(size: 11, weight: .bold))
                                .padding(8)
                                .background(CSSThemeVariables.surfaceFill(scope: .settings))
                                .foregroundStyle(CSSThemeVariables.textMain(scope: .settings))
                                .clipShape(Circle())
                        }
                    }
                }
            }

            // 仿聊天小视窗预览
            VStack(spacing: 10) {
                // 助手侧模拟气泡
                HStack(alignment: .top, spacing: 8) {
                    miniAvatar(isUser: false)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(AppLocalized("你好，醒醒。今天想怎么打扮我？"))
                            .font(.system(size: 12))
                            .foregroundStyle(CSSThemeVariables.textMain(scope: .chat))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(CSSThemeVariables.card(scope: .chat))
                            .clipShape(RoundedRectangle(cornerRadius: CGFloat(studio.currentThemePack().assistantBubbleRadius), style: .continuous))
                    }
                    Spacer(minLength: 20)
                }

                // 用户侧模拟气泡
                HStack(alignment: .top, spacing: 8) {
                    Spacer(minLength: 20)
                    Text(AppLocalized("做简单、精致、iOS 26 质感～"))
                        .font(.system(size: 12))
                        .foregroundStyle(CSSThemeVariables.card(scope: .chat))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(CSSThemeVariables.accent(scope: .chat))
                        .clipShape(RoundedRectangle(cornerRadius: CGFloat(studio.currentThemePack().userBubbleRadius), style: .continuous))
                    miniAvatar(isUser: true)
                }
            }
            .padding(12)
            .background(CSSThemeVariables.bg(scope: .chat).opacity(0.85))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(CSSThemeVariables.divider(scope: .settings), lineWidth: 0.5)
            )
        }
        .padding(14)
        .background(CSSThemeVariables.card(scope: .settings).opacity(0.92))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(CSSThemeVariables.divider(scope: .settings), lineWidth: 0.5)
        )
    }

    private func miniAvatar(isUser: Bool) -> some View {
        let side: DressingSide = isUser ? .user : .assistant
        let pendant = pendantStore.applied(for: side)
        let ringColor = pendant?.color ?? Color.clear

        return ZStack {
            Circle()
                .fill(CSSThemeVariables.surfaceFill(scope: .settings))
                .frame(width: 28, height: 28)
                .overlay {
                    Image(systemName: isUser ? "person.fill" : "sparkle")
                        .font(.system(size: 12))
                        .foregroundStyle(CSSThemeVariables.textDim(scope: .settings))
                }

            if pendant != nil {
                AvatarRingView(size: 28, color: ringColor, imageFile: pendant?.imageFile)
            }
        }
    }

    // 3. 全局透光度与遮罩三旋钮
    private var globalDialsCard: some View {
        VStack(spacing: 12) {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(CSSThemeVariables.accent(scope: .settings))
                    Text(AppLocalized("全局透光与材质"))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(CSSThemeVariables.textMain(scope: .settings))
                }
                Spacer()

                Button {
                    haptic()
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        studio.resetOpacityDials()
                    }
                    showToast(AppLocalized("旋钮已复位"))
                } label: {
                    Text(AppLocalized("复位"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(CSSThemeVariables.textDim(scope: .settings))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(CSSThemeVariables.surfaceFill(scope: .settings))
                        .clipShape(Capsule())
                }
            }

            VStack(spacing: 8) {
                dialRow(title: AppLocalized("卡片表面透光"), icon: "square.2.layers.3d.top.filled", value: Binding(
                    get: { studio.surfaceOpacity },
                    set: { studio.surfaceOpacity = $0 }
                ))

                dialRow(title: AppLocalized("气泡表面透光"), icon: "bubble.left.and.bubble.right.fill", value: Binding(
                    get: { studio.bubbleOpacity },
                    set: { studio.bubbleOpacity = $0 }
                ))

                dialRow(title: AppLocalized("壁纸遮罩浓度"), icon: "circle.lefthalf.striped.horizontal", value: Binding(
                    get: { studio.wallpaperShade },
                    set: { studio.wallpaperShade = $0 }
                ))
            }
        }
        .padding(14)
        .background(CSSThemeVariables.card(scope: .settings).opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(CSSThemeVariables.divider(scope: .settings), lineWidth: 0.5)
        )
    }

    private func dialRow(title: String, icon: String, value: Binding<Double>) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(CSSThemeVariables.textDim(scope: .settings))
                .frame(width: 16)

            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(CSSThemeVariables.textMain(scope: .settings))

            Spacer()

            Slider(value: value, in: 0.0...1.0)
                .frame(width: 110)
                .tint(CSSThemeVariables.accent(scope: .settings))

            Text("\(Int(value.wrappedValue * 100))%")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(CSSThemeVariables.textDim(scope: .settings))
                .frame(width: 38, alignment: .trailing)
        }
    }

    // 4. 六大核心入口网格 (Bento Grid)
    private var bentoGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            bentoCard(title: AppLocalized("色彩调控"), sub: AppLocalized("21色分页面分深浅"), icon: "paintpalette.fill", dest: .colorStudio)
            bentoCard(title: AppLocalized("壁纸与立绘"), sub: AppLocalized("全局与独立壁纸立绘"), icon: "photo.on.rectangle.angled", dest: .wallpaperArt)
            bentoCard(title: AppLocalized("气泡与挂件"), sub: AppLocalized("款式、圆角与头像圈"), icon: "bubble.left.circle.fill", dest: .bubblesPendants)
            bentoCard(title: AppLocalized("字体与排版"), sub: AppLocalized("字号、行距与小说模式"), icon: "textformat", dest: .typography)
            bentoCard(title: AppLocalized("主题存档库"), sub: AppLocalized("保存、分享与导入导出"), icon: "archivebox.fill", dest: .themeLibrary)
            bentoCard(title: AppLocalized("细节与图标"), sub: AppLocalized("静音图标与标签符号"), icon: "sparkle.magnifyingglass", dest: .detailsIcons)
        }
    }

    private func bentoCard(title: String, sub: String, icon: String, dest: DressingSheetDestination) -> some View {
        Button {
            haptic()
            activeSheet = dest
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    ZStack {
                        Circle()
                            .fill(CSSThemeVariables.accentSoft(scope: .settings))
                            .frame(width: 32, height: 32)

                        Image(systemName: icon)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(CSSThemeVariables.accent(scope: .settings))
                    }

                    Spacer()

                    Image(systemName: "arrow.up.forward")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(CSSThemeVariables.textDim(scope: .settings).opacity(0.6))
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(CSSThemeVariables.textMain(scope: .settings))

                    Text(sub)
                        .font(.system(size: 11))
                        .foregroundStyle(CSSThemeVariables.textDim(scope: .settings))
                        .lineLimit(1)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(CSSThemeVariables.card(scope: .settings).opacity(0.85))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(CSSThemeVariables.divider(scope: .settings), lineWidth: 0.5)
            )
        }
        .buttonStyle(DressingPressStyle())
    }

    // 5. 底部便捷重置
    private var footerQuickActions: some View {
        VStack(spacing: 8) {
            Button {
                haptic()
                var undoAvailable = false
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    undoAvailable = studio.resetGlobalColorsWithUndo()
                }
                if undoAvailable {
                    showToast(AppLocalized("调色板已重置为默认值（可撤销）"))
                } else {
                    showToast(AppLocalized("调色板已重置为默认值"))
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 12))
                    Text(AppLocalized("恢复默认调色板"))
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundStyle(CSSThemeVariables.textDim(scope: .settings))
                .padding(.vertical, 8)
            }
        }
        .padding(.top, 8)
    }
}


// MARK: - 抽屉目标枚举与路由

enum DressingSheetDestination: String, Identifiable {
    case presets
    case colorStudio
    case wallpaperArt
    case bubblesPendants
    case typography
    case themeLibrary
    case detailsIcons
    case saveTheme
    case importExport

    var id: String { rawValue }
}

extension DressingShopView {
    @ViewBuilder
    private func sheetView(for dest: DressingSheetDestination) -> some View {
        switch dest {
        case .presets:
            DressingPresetsSheet(onApply: { name in
                showToast(AppLocalized("已应用预设：") + name)
                activeSheet = nil
            })
        case .colorStudio:
            DressingColorStudioSheet(onNotify: { showToast($0) })
        case .wallpaperArt:
            DressingWallpaperArtSheet(onNotify: { showToast($0) })
        case .bubblesPendants:
            DressingBubblesPendantsSheet(onNotify: { showToast($0) })
        case .typography:
            DressingTypographySheet(onNotify: { showToast($0) })
        case .themeLibrary:
            DressingThemeLibrarySheet(
                onOpenSave: { activeSheet = .saveTheme },
                onOpenImportExport: { activeSheet = .importExport },
                onNotify: { showToast($0) }
            )
        case .detailsIcons:
            DressingDetailsIconsSheet(onNotify: { showToast($0) })
        case .saveTheme:
            DressingSaveThemeSheet(onSaved: { name in
                showToast(AppLocalized("已保存主题：") + name)
                activeSheet = .themeLibrary
            }, onNotify: { showToast($0) })
        case .importExport:
            DressingImportExportSheet(onNotify: { showToast($0) })
        }
    }
}

// MARK: - 精致按钮按压效果
struct DressingPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.spring(response: 0.22, dampingFraction: 0.75), value: configuration.isPressed)
    }
}

// MARK: - 抽屉统一页眉
struct DressingSheetHeader: View {
    let title: String
    let subtitle: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(CSSThemeVariables.textMain(scope: .settings))

                if let sub = subtitle {
                    Text(sub)
                        .font(.system(size: 11))
                        .foregroundStyle(CSSThemeVariables.textDim(scope: .settings))
                }
            }

            Spacer()

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(CSSThemeVariables.textDim(scope: .settings).opacity(0.6))
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 8)
    }
}


// MARK: - 1. 经典预设快速拾取 (DressingPresetsSheet)

@MainActor
struct DressingPresetsSheet: View {
    let onApply: (String) -> Void
    @ObservedObject private var studio = AppearanceStudio.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                DressingSheetHeader(
                    title: AppLocalized("经典预设库"),
                    subtitle: AppLocalized("一键切换整体色调与氛围")
                )

                ScrollView(.vertical, showsIndicators: false) {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                        ForEach(AppearancePreset.allCases) { preset in
                            presetCard(preset)
                        }
                    }
                    .padding(16)
                }
            }
            .background(AppearanceBackdrop(scope: .settings).ignoresSafeArea())
        }
    }

    private func presetCard(_ preset: AppearancePreset) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            studio.applyPreset(preset)
            onApply(preset.title)
            dismiss()
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(presetAccentColor(preset))
                        .frame(width: 14, height: 14)

                    Text(preset.title)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(CSSThemeVariables.textMain(scope: .settings))

                    Spacer()
                }

                Text(presetSubtitle(preset))
                    .font(.system(size: 11))
                    .foregroundStyle(CSSThemeVariables.textDim(scope: .settings))
                    .lineLimit(2)
                    .frame(height: 28, alignment: .topLeading)

                HStack(spacing: 4) {
                    ForEach(presetSwatchColors(preset), id: \.self) { hex in
                        Circle()
                            .fill(Color(hex: hex))
                            .frame(width: 8, height: 8)
                    }
                    Spacer()
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 10))
                    Text(AppLocalized("换上"))
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundStyle(CSSThemeVariables.accent(scope: .settings))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(CSSThemeVariables.accentSoft(scope: .settings))
                .clipShape(Capsule())
            }
            .padding(12)
            .background(CSSThemeVariables.card(scope: .settings).opacity(0.85))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(CSSThemeVariables.divider(scope: .settings), lineWidth: 0.5)
            )
        }
        .buttonStyle(DressingPressStyle())
    }

    private func presetSubtitle(_ preset: AppearancePreset) -> String {
        switch preset {
        case .warmPaper: return AppLocalized("晨光白底与温暖卡片，舒适阅读")
        case .cleanAir: return AppLocalized("清冷透亮，科技与空气感")
        case .nightCocoa: return AppLocalized("柔和大地与夜色可可，深邃护眼")
        }
    }

    private func presetAccentColor(_ preset: AppearancePreset) -> Color {
        let hex = preset.colors.light[.accent] ?? "007AFF"
        return Color(hex: hex)
    }

    private func presetSwatchColors(_ preset: AppearancePreset) -> [String] {
        let map = preset.colors.light
        return [AppearanceColorRole.canvas, .surface, .accent, .primaryText].compactMap { map[$0] }
    }
}

// MARK: - 2. 色彩调控抽屉 (DressingColorStudioSheet)

@MainActor
struct DressingColorStudioSheet: View {
    let onNotify: (String) -> Void
    @ObservedObject private var studio = AppearanceStudio.shared
    @State private var selectedScope: AppearanceScope = .global
    @State private var selectedVariant: AppearanceVariant = .light
    @State private var selectedGroup: AppearanceColorRoleGroup = .text

    /// 清除按钮只在真有东西可清时才给点：默认页没有“本页覆盖”可清，
    /// 覆盖数为 0 时点它也是空操作。覆盖数跟着 customColors 走，
    /// studio 是 @ObservedObject，清完会自动变灰。
    private var canClearPageOverrides: Bool {
        selectedScope != .global && studio.overrideCount(scope: selectedScope, variant: selectedVariant) > 0
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                DressingSheetHeader(
                    title: AppLocalized("色彩调控台"),
                    subtitle: AppLocalized("分页面 · 分日夜模式 · 21角色精细上色")
                )

                // 页面与深浅模式胶囊切换行
                scopeAndVariantPills

                // 颜色角色大类选择器
                roleGroupPicker

                // 颜色调节卡片列表
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 10) {
                        ForEach(selectedGroup.roles) { role in
                            colorRoleRow(role)
                        }

                        // 页面重置操作行
                        HStack(spacing: 12) {
                            Button {
                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                if studio.clearOverridesWithUndo(scope: selectedScope, variant: selectedVariant) {
                                    onNotify(AppLocalized("已清除当前页面的自定义覆盖"))
                                } else {
                                    onNotify(AppLocalized("清除失败，请重试"))
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.counterclockwise")
                                        .font(.system(size: 11))
                                    Text(AppLocalized("清除本页覆盖"))
                                        .font(.system(size: 12, weight: .medium))
                                }
                                .foregroundStyle(CSSThemeVariables.textDim(scope: .settings))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(CSSThemeVariables.surfaceFill(scope: .settings))
                                .clipShape(Capsule())
                            }
                            .disabled(!canClearPageOverrides)
                            .opacity(canClearPageOverrides ? 1.0 : 0.5)

                            Spacer()
                        }
                        .padding(.top, 8)
                    }
                    .padding(16)
                }
            }
            .background(AppearanceBackdrop(scope: .settings).ignoresSafeArea())
        }
    }

    private var scopeAndVariantPills: some View {
        VStack(spacing: 8) {
            // Scope 选择
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach([AppearanceScope.global, .chat, .home, .settings, .browser, .terminal], id: \.self) { scope in
                        let isSelected = selectedScope == scope
                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            selectedScope = scope
                        } label: {
                            Text(scope.title)
                                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(isSelected ? CSSThemeVariables.accent(scope: .settings) : CSSThemeVariables.surfaceFill(scope: .settings))
                                .foregroundStyle(isSelected ? CSSThemeVariables.card(scope: .settings) : CSSThemeVariables.textMain(scope: .settings))
                                .clipShape(Capsule())
                        }
                    }
                }
                .padding(.horizontal, 16)
            }

            // Variant (浅色/深色)
            HStack(spacing: 6) {
                ForEach(AppearanceVariant.allCases) { variant in
                    let isSelected = selectedVariant == variant
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        selectedVariant = variant
                    } label: {
                        Text(variant.title)
                            .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(isSelected ? CSSThemeVariables.card(scope: .settings) : Color.clear)
                            .foregroundStyle(isSelected ? CSSThemeVariables.textMain(scope: .settings) : CSSThemeVariables.textDim(scope: .settings))
                            .clipShape(Capsule())
                    }
                }
            }
            .padding(3)
            .background(CSSThemeVariables.surfaceFill(scope: .settings))
            .clipShape(Capsule())
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 6)
    }

    private var roleGroupPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(AppearanceColorRoleGroup.allCases) { grp in
                    let isSelected = selectedGroup == grp
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        selectedGroup = grp
                    } label: {
                        Text(grp.title)
                            .font(.system(size: 11, weight: isSelected ? .bold : .medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(isSelected ? CSSThemeVariables.accentSoft(scope: .settings) : Color.clear)
                            .foregroundStyle(isSelected ? CSSThemeVariables.accent(scope: .settings) : CSSThemeVariables.textDim(scope: .settings))
                            .clipShape(Capsule())
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 4)
    }

    private func colorRoleRow(_ role: AppearanceColorRole) -> some View {
        let currentHex = studio.hex(role, scope: selectedScope, variant: selectedVariant)
        let binding = Binding<Color>(
            get: { Color(hex: currentHex) },
            set: { newColor in
                studio.setColor(newColor, role: role, scope: selectedScope, variant: selectedVariant)
            }
        )

        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(role.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(CSSThemeVariables.textMain(scope: .settings))

                Text("#" + currentHex)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(CSSThemeVariables.textDim(scope: .settings))
            }

            Spacer()

            // 原生 ColorPicker
            ColorPicker("", selection: binding)
                .labelsHidden()
                .scaleEffect(0.9)

            // 清除单项覆盖小按钮
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                studio.clearOverride(role, scope: selectedScope, variant: selectedVariant)
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 11))
                    .foregroundStyle(CSSThemeVariables.textDim(scope: .settings))
                    .padding(6)
                    .background(CSSThemeVariables.surfaceFill(scope: .settings))
                    .clipShape(Circle())
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(CSSThemeVariables.card(scope: .settings).opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(CSSThemeVariables.divider(scope: .settings), lineWidth: 0.5)
        )
    }
}


// MARK: - 3. 壁纸与立绘抽屉 (DressingWallpaperArtSheet)

@MainActor
struct DressingWallpaperArtSheet: View {
    let onNotify: (String) -> Void
    @ObservedObject private var studio = AppearanceStudio.shared
    @State private var selectedScope: AppearanceScope = .global

    // 相册拾取项
    @State private var pickedWallpaperItem: PhotosPickerItem? = nil
    @State private var pickedArtItem: PhotosPickerItem? = nil
    @State private var pickedThinkingItem: PhotosPickerItem? = nil
    @State private var pickedInputBarItem: PhotosPickerItem? = nil

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                DressingSheetHeader(
                    title: AppLocalized("壁纸与特色装饰"),
                    subtitle: AppLocalized("页面专属壁纸 · 助手立绘 · 思考与输入栏贴图")
                )

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 16) {
                        // 1. 壁纸模块
                        wallpaperSection

                        // 2. 助手专属立绘 (Character Art)
                        characterArtSection

                        // 3. 思考卡与输入栏装饰图
                        componentDecorSection
                    }
                    .padding(16)
                }
            }
            .background(AppearanceBackdrop(scope: .settings).ignoresSafeArea())
            .onChange(of: pickedWallpaperItem) { item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        await MainActor.run {
                            if studio.setWallpaperEncoded(data, for: selectedScope) {
                                onNotify(AppLocalized("壁纸已更新"))
                            } else {
                                onNotify(AppLocalized("壁纸格式不支持或已损坏"))
                            }
                        }
                    }
                }
            }
            .onChange(of: pickedArtItem) { item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let uiImage = UIImage(data: data) {
                        await MainActor.run {
                            studio.setCharacterArtImage(uiImage)
                            onNotify(AppLocalized("助手立绘已设置"))
                        }
                    }
                }
            }
            .onChange(of: pickedThinkingItem) { item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let uiImage = UIImage(data: data) {
                        await MainActor.run {
                            _ = studio.setThinkingCardImage(uiImage)
                            onNotify(AppLocalized("思考卡背景已更新"))
                        }
                    }
                }
            }
            .onChange(of: pickedInputBarItem) { item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let uiImage = UIImage(data: data) {
                        await MainActor.run {
                            _ = studio.setInputBarImage(uiImage)
                            onNotify(AppLocalized("输入栏背景已更新"))
                        }
                    }
                }
            }
        }
    }

    private var wallpaperSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(AppLocalized("分页面壁纸设置"))
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(CSSThemeVariables.textMain(scope: .settings))

            // Scope 切换
            HStack(spacing: 6) {
                ForEach([AppearanceScope.global, .chat, .home, .settings], id: \.self) { sc in
                    let isSelected = selectedScope == sc
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        selectedScope = sc
                    } label: {
                        Text(sc.title)
                            .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(isSelected ? CSSThemeVariables.accent(scope: .settings) : CSSThemeVariables.surfaceFill(scope: .settings))
                            .foregroundStyle(isSelected ? CSSThemeVariables.card(scope: .settings) : CSSThemeVariables.textMain(scope: .settings))
                            .clipShape(Capsule())
                    }
                }
            }

            // 当前壁纸卡片
            HStack(spacing: 12) {
                if let wp = studio.wallpaper(for: selectedScope) {
                    Image(uiImage: wp)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(CSSThemeVariables.surfaceFill(scope: .settings))
                            .frame(width: 64, height: 64)
                        Image(systemName: "photo")
                            .foregroundStyle(CSSThemeVariables.textDim(scope: .settings))
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(selectedScope == .global ? AppLocalized("全局通用壁纸") : AppLocalized("该页面独立壁纸"))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(CSSThemeVariables.textMain(scope: .settings))

                    Text(studio.hasOwnWallpaper(selectedScope) ? AppLocalized("已自定义壁纸") : AppLocalized("未单独设置（遵循主题底色或全局壁纸）"))
                        .font(.system(size: 11))
                        .foregroundStyle(CSSThemeVariables.textDim(scope: .settings))

                    HStack(spacing: 8) {
                        PhotosPicker(selection: $pickedWallpaperItem, matching: .images) {
                            HStack(spacing: 4) {
                                Image(systemName: "photo.badge.plus")
                                    .font(.system(size: 10))
                                Text(AppLocalized("从相册选择"))
                                    .font(.system(size: 11, weight: .semibold))
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(CSSThemeVariables.accent(scope: .settings))
                            .foregroundStyle(CSSThemeVariables.card(scope: .settings))
                            .clipShape(Capsule())
                        }

                        if studio.hasOwnWallpaper(selectedScope) {
                            Button {
                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                studio.removeWallpaper(selectedScope)
                                onNotify(AppLocalized("已清除该页面壁纸并恢复默认"))
                            } label: {
                                Text(AppLocalized("清除壁纸"))
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(CSSThemeVariables.textDim(scope: .settings))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 5)
                                    .background(CSSThemeVariables.surfaceFill(scope: .settings))
                                    .clipShape(Capsule())
                            }
                        }
                    }
                    .padding(.top, 2)
                }
            }
            .padding(12)
            .background(CSSThemeVariables.card(scope: .settings).opacity(0.85))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(CSSThemeVariables.divider(scope: .settings), lineWidth: 0.5)
            )
        }
    }

    private var characterArtSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(AppLocalized("助手专属立绘 (Character Art)"))
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(CSSThemeVariables.textMain(scope: .settings))

            HStack(spacing: 12) {
                if let art = studio.characterArtImage() {
                    Image(uiImage: art)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 50, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(CSSThemeVariables.surfaceFill(scope: .settings))
                            .frame(width: 50, height: 64)
                        Image(systemName: "person.crop.artframe")
                            .foregroundStyle(CSSThemeVariables.textDim(scope: .settings))
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(studio.hasCharacterArt ? AppLocalized("立绘已就绪（将在特定模式下展示）") : AppLocalized("尚未设置立绘"))
                        .font(.system(size: 12))
                        .foregroundStyle(CSSThemeVariables.textDim(scope: .settings))

                    HStack(spacing: 8) {
                        PhotosPicker(selection: $pickedArtItem, matching: .images) {
                            Text(AppLocalized("上传立绘"))
                                .font(.system(size: 11, weight: .semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(CSSThemeVariables.accentSoft(scope: .settings))
                                .foregroundStyle(CSSThemeVariables.accent(scope: .settings))
                                .clipShape(Capsule())
                        }

                        if studio.hasCharacterArt {
                            Button {
                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                studio.removeCharacterArt()
                                onNotify(AppLocalized("已清除立绘"))
                            } label: {
                                Text(AppLocalized("移除"))
                                    .font(.system(size: 11))
                                    .foregroundStyle(CSSThemeVariables.textDim(scope: .settings))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 5)
                                    .background(CSSThemeVariables.surfaceFill(scope: .settings))
                                    .clipShape(Capsule())
                            }
                        }
                    }
                }
            }
            .padding(12)
            .background(CSSThemeVariables.card(scope: .settings).opacity(0.85))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(CSSThemeVariables.divider(scope: .settings), lineWidth: 0.5)
            )
        }
    }

    private var componentDecorSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(AppLocalized("部件背景装饰图"))
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(CSSThemeVariables.textMain(scope: .settings))

            // 思考卡装饰
            decorItemRow(
                title: AppLocalized("思考过程卡片背景"),
                hasImage: studio.hasThinkingCardImage(),
                pickerItem: $pickedThinkingItem,
                onRemove: {
                    studio.removeThinkingCardImage()
                    onNotify(AppLocalized("已移除思考卡装饰图"))
                },
                opacity: Binding(
                    get: { studio.currentThemePack().thinkingCardImageOpacity },
                    set: { studio.setThinkingCardImageOpacity($0) }
                )
            )

            // 输入栏装饰
            decorItemRow(
                title: AppLocalized("聊天输入栏背景"),
                hasImage: studio.hasInputBarImage(),
                pickerItem: $pickedInputBarItem,
                onRemove: {
                    studio.removeInputBarImage()
                    onNotify(AppLocalized("已移除输入栏装饰图"))
                },
                opacity: Binding(
                    get: { studio.currentThemePack().inputBarImageOpacity },
                    set: { studio.setInputBarImageOpacity($0) }
                )
            )
        }
    }

    private func decorItemRow(title: String, hasImage: Bool, pickerItem: Binding<PhotosPickerItem?>, onRemove: @escaping () -> Void, opacity: Binding<Double>) -> some View {
        VStack(spacing: 8) {
            HStack {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(CSSThemeVariables.textMain(scope: .settings))

                Spacer()

                PhotosPicker(selection: pickerItem, matching: .images) {
                    Text(hasImage ? AppLocalized("更换图片") : AppLocalized("添加图片"))
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(CSSThemeVariables.accentSoft(scope: .settings))
                        .foregroundStyle(CSSThemeVariables.accent(scope: .settings))
                        .clipShape(Capsule())
                }

                if hasImage {
                    Button(action: onRemove) {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundStyle(CSSThemeVariables.textDim(scope: .settings))
                    }
                }
            }

            if hasImage {
                HStack(spacing: 8) {
                    Text(AppLocalized("透明度"))
                        .font(.system(size: 10))
                        .foregroundStyle(CSSThemeVariables.textDim(scope: .settings))

                    Slider(value: opacity, in: 0.05...1.0)
                        .tint(CSSThemeVariables.accent(scope: .settings))

                    Text("\(Int(opacity.wrappedValue * 100))%")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(CSSThemeVariables.textDim(scope: .settings))
                }
            }
        }
        .padding(12)
        .background(CSSThemeVariables.card(scope: .settings).opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(CSSThemeVariables.divider(scope: .settings), lineWidth: 0.5)
        )
    }
}

// MARK: - 4. 气泡与挂件抽屉 (DressingBubblesPendantsSheet)

@MainActor
struct DressingBubblesPendantsSheet: View {
    let onNotify: (String) -> Void
    @ObservedObject private var studio = AppearanceStudio.shared
    @ObservedObject private var bubbleStore = BubbleStylePackStore.shared
    @ObservedObject private var pendantStore = AvatarPendantStore.shared

    @State private var selectedTab: Int = 0 // 0: 气泡款式, 1: 头像与挂件
    @State private var editingSide: DressingSide = .user

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                DressingSheetHeader(
                    title: AppLocalized("气泡与头像挂件"),
                    subtitle: AppLocalized("气泡形状款式 · 头像轮廓 · 柔光发光圈")
                )

                // 顶部切页胶囊
                HStack(spacing: 6) {
                    tabPill(title: AppLocalized("气泡款式与圆角"), index: 0)
                    tabPill(title: AppLocalized("头像挂件与形状"), index: 1)
                }
                .padding(3)
                .background(CSSThemeVariables.surfaceFill(scope: .settings))
                .clipShape(Capsule())
                .padding(.horizontal, 16)
                .padding(.vertical, 6)

                ScrollView(.vertical, showsIndicators: false) {
                    if selectedTab == 0 {
                        bubbleSection
                    } else {
                        pendantAndAvatarSection
                    }
                }
                .padding(16)
            }
            .background(AppearanceBackdrop(scope: .settings).ignoresSafeArea())
        }
    }

    private func tabPill(title: String, index: Int) -> some View {
        let isSelected = selectedTab == index
        return Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            selectedTab = index
        } label: {
            Text(title)
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(isSelected ? CSSThemeVariables.card(scope: .settings) : Color.clear)
                .foregroundStyle(isSelected ? CSSThemeVariables.textMain(scope: .settings) : CSSThemeVariables.textDim(scope: .settings))
                .clipShape(Capsule())
        }
    }

    // 气泡部分
    private var bubbleSection: some View {
        VStack(spacing: 16) {
            // 侧别切换 (你 / AI)
            HStack(spacing: 8) {
                Text(AppLocalized("正在调节："))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(CSSThemeVariables.textDim(scope: .settings))

                ForEach(DressingSide.allCases, id: \.self) { side in
                    let isSelected = editingSide == side
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        editingSide = side
                    } label: {
                        Text(side.displayName)
                            .font(.system(size: 12, weight: isSelected ? .bold : .medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(isSelected ? CSSThemeVariables.accent(scope: .settings) : CSSThemeVariables.surfaceFill(scope: .settings))
                            .foregroundStyle(isSelected ? CSSThemeVariables.card(scope: .settings) : CSSThemeVariables.textMain(scope: .settings))
                            .clipShape(Capsule())
                    }
                }

                Spacer()
            }

            // 气泡圆角滑块与基本风格切换
            VStack(alignment: .leading, spacing: 10) {
                Text(AppLocalized("气泡形状微调"))
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(CSSThemeVariables.textMain(scope: .settings))

                // 风格选择
                HStack(spacing: 6) {
                    ForEach(AppearanceBubbleStyle.allCases) { style in
                        let isSelected = (editingSide == .user ? studio.currentThemePack().userBubbleStyle : studio.currentThemePack().assistantBubbleStyle) == style.rawValue
                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            studio.setBubbleStyle(style, user: editingSide.isUser)
                        } label: {
                            Text(style.title)
                                .font(.system(size: 11, weight: isSelected ? .bold : .regular))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(isSelected ? CSSThemeVariables.accentSoft(scope: .settings) : CSSThemeVariables.surfaceFill(scope: .settings))
                                .foregroundStyle(isSelected ? CSSThemeVariables.accent(scope: .settings) : CSSThemeVariables.textDim(scope: .settings))
                                .clipShape(Capsule())
                        }
                    }
                }

                // 圆角滑块
                HStack(spacing: 8) {
                    Text(AppLocalized("圆角半径"))
                        .font(.system(size: 11))
                        .foregroundStyle(CSSThemeVariables.textDim(scope: .settings))

                    Slider(
                        value: Binding(
                            get: { editingSide.isUser ? studio.currentThemePack().userBubbleRadius : studio.currentThemePack().assistantBubbleRadius },
                            set: { val in
                                var pack = studio.currentThemePack()
                                if editingSide.isUser {
                                    pack.userBubbleRadius = min(32, max(4, val))
                                } else {
                                    pack.assistantBubbleRadius = min(32, max(4, val))
                                }
                                studio.persistPack(pack)
                            }
                        ),
                        in: 4...32
                    )
                    .tint(CSSThemeVariables.accent(scope: .settings))

                    Text("\(Int(editingSide.isUser ? studio.currentThemePack().userBubbleRadius : studio.currentThemePack().assistantBubbleRadius)) pt")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(CSSThemeVariables.textDim(scope: .settings))
                        .frame(width: 36, alignment: .trailing)
                }
            }
            .padding(12)
            .background(CSSThemeVariables.card(scope: .settings).opacity(0.85))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(CSSThemeVariables.divider(scope: .settings), lineWidth: 0.5)
            )

            // 预设款式列表
            VStack(alignment: .leading, spacing: 8) {
                Text(AppLocalized("预设气泡款式库"))
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(CSSThemeVariables.textMain(scope: .settings))

                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(bubbleStore.packs) { pack in
                        bubblePackCard(pack)
                    }
                }
            }
        }
    }

    private func bubblePackCard(_ pack: BubbleStylePack) -> some View {
        let isApplied = bubbleStore.appliedNumber(for: editingSide) == pack.number

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(pack.title)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(CSSThemeVariables.textMain(scope: .settings))

                Spacer()

                if isApplied {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(CSSThemeVariables.accent(scope: .settings))
                }
            }

            Text(pack.number)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(CSSThemeVariables.textDim(scope: .settings))

            HStack(spacing: 6) {
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    bubbleStore.apply(pack, for: editingSide)
                    onNotify(AppLocalized("已给 \(editingSide.displayName) 换上 \(pack.title)"))
                } label: {
                    Text(AppLocalized("换上"))
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(isApplied ? CSSThemeVariables.accent(scope: .settings) : CSSThemeVariables.surfaceFill(scope: .settings))
                        .foregroundStyle(isApplied ? CSSThemeVariables.card(scope: .settings) : CSSThemeVariables.textMain(scope: .settings))
                        .clipShape(Capsule())
                }

                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    bubbleStore.apply(pack)
                    onNotify(AppLocalized("已全部应用 \(pack.title)"))
                } label: {
                    Text(AppLocalized("双方都用"))
                        .font(.system(size: 10))
                        .foregroundStyle(CSSThemeVariables.textDim(scope: .settings))
                }
            }
        }
        .padding(12)
        .background(CSSThemeVariables.card(scope: .settings).opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(isApplied ? CSSThemeVariables.accent(scope: .settings) : CSSThemeVariables.divider(scope: .settings), lineWidth: isApplied ? 1 : 0.5)
        )
    }

    // 头像与挂件部分
    private var pendantAndAvatarSection: some View {
        VStack(spacing: 16) {
            // 头像轮廓与大小
            VStack(alignment: .leading, spacing: 10) {
                Text(AppLocalized("头像形状与尺寸"))
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(CSSThemeVariables.textMain(scope: .settings))

                HStack(spacing: 6) {
                    ForEach(AppearanceAvatarShape.allCases) { shape in
                        let isSelected = studio.currentThemePack().avatarShape == shape.rawValue
                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            studio.setAvatarShape(shape)
                        } label: {
                            Text(shape.title)
                                .font(.system(size: 12, weight: isSelected ? .bold : .regular))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(isSelected ? CSSThemeVariables.accent(scope: .settings) : CSSThemeVariables.surfaceFill(scope: .settings))
                                .foregroundStyle(isSelected ? CSSThemeVariables.card(scope: .settings) : CSSThemeVariables.textMain(scope: .settings))
                                .clipShape(Capsule())
                        }
                    }
                }

                HStack(spacing: 8) {
                    Text(AppLocalized("头像大小"))
                        .font(.system(size: 11))
                        .foregroundStyle(CSSThemeVariables.textDim(scope: .settings))

                    Slider(
                        value: Binding(
                            get: { studio.currentThemePack().avatarSize },
                            set: { val in
                                var pack = studio.currentThemePack()
                                pack.avatarSize = min(64, max(28, val))
                                studio.persistPack(pack)
                            }
                        ),
                        in: 28...64
                    )
                    .tint(CSSThemeVariables.accent(scope: .settings))

                    Text("\(Int(studio.currentThemePack().avatarSize)) pt")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(CSSThemeVariables.textDim(scope: .settings))
                        .frame(width: 36, alignment: .trailing)
                }
            }
            .padding(12)
            .background(CSSThemeVariables.card(scope: .settings).opacity(0.85))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(CSSThemeVariables.divider(scope: .settings), lineWidth: 0.5)
            )

            // 头像发光圆环挂件
            VStack(alignment: .leading, spacing: 8) {
                Text(AppLocalized("发光柔光圆环挂件"))
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(CSSThemeVariables.textMain(scope: .settings))

                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(pendantStore.pendants) { pendant in
                        pendantCard(pendant)
                    }
                }
            }
        }
    }

    private func pendantCard(_ pendant: AvatarPendant) -> some View {
        let isUserWearing = pendantStore.appliedNumber(for: .user) == pendant.number
        let isAIWearing = pendantStore.appliedNumber(for: .assistant) == pendant.number

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(CSSThemeVariables.surfaceFill(scope: .settings))
                        .frame(width: 34, height: 34)

                    AvatarRingView(size: 34, color: pendant.color, imageFile: pendant.imageFile)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(pendant.title)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(CSSThemeVariables.textMain(scope: .settings))

                    Text(pendant.number)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(CSSThemeVariables.textDim(scope: .settings))
                }
            }

            HStack(spacing: 6) {
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    if isUserWearing {
                        pendantStore.clear(for: .user)
                        onNotify(AppLocalized("已卸下我的挂件"))
                    } else {
                        pendantStore.apply(pendant, for: .user)
                        onNotify(AppLocalized("已佩戴在我的头像上"))
                    }
                } label: {
                    Text(isUserWearing ? AppLocalized("你已佩戴") : AppLocalized("戴在我头上"))
                        .font(.system(size: 9, weight: .medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(isUserWearing ? CSSThemeVariables.accent(scope: .settings) : CSSThemeVariables.surfaceFill(scope: .settings))
                        .foregroundStyle(isUserWearing ? CSSThemeVariables.card(scope: .settings) : CSSThemeVariables.textDim(scope: .settings))
                        .clipShape(Capsule())
                }

                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    if isAIWearing {
                        pendantStore.clear(for: .assistant)
                        onNotify(AppLocalized("已卸下AI的挂件"))
                    } else {
                        pendantStore.apply(pendant, for: .assistant)
                        onNotify(AppLocalized("已佩戴在AI头像上"))
                    }
                } label: {
                    Text(isAIWearing ? AppLocalized("AI已佩戴") : AppLocalized("戴在AI上"))
                        .font(.system(size: 9, weight: .medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(isAIWearing ? CSSThemeVariables.accent(scope: .settings) : CSSThemeVariables.surfaceFill(scope: .settings))
                        .foregroundStyle(isAIWearing ? CSSThemeVariables.card(scope: .settings) : CSSThemeVariables.textDim(scope: .settings))
                        .clipShape(Capsule())
                }
            }
        }
        .padding(10)
        .background(CSSThemeVariables.card(scope: .settings).opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke((isUserWearing || isAIWearing) ? CSSThemeVariables.accent(scope: .settings) : CSSThemeVariables.divider(scope: .settings), lineWidth: 0.5)
        )
    }
}


// MARK: - 5. 字体与排版抽屉 (DressingTypographySheet)

@MainActor
struct DressingTypographySheet: View {
    let onNotify: (String) -> Void
    @ObservedObject private var studio = AppearanceStudio.shared
    @ObservedObject private var fontStore = UploadedFontStore.shared
    @State private var showFontPicker = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                DressingSheetHeader(
                    title: AppLocalized("字体与版面排版"),
                    subtitle: AppLocalized("字体族 · 自定义字体 · 字号行距 · 小说模式")
                )

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 16) {
                        // 1. 系统内置字体族
                        systemFontSection

                        // 2. 自定义导入字体
                        customFontSection

                        // 3. 详细排版滑块群
                        typographySlidersSection

                        // 4. 阅读模式与布局形态
                        readingModesSection
                    }
                    .padding(16)
                }
            }
            .background(AppearanceBackdrop(scope: .settings).ignoresSafeArea())
            .sheet(isPresented: $showFontPicker) {
                FontFilePicker(
                    onPick: { url in
                        showFontPicker = false
                        if let font = fontStore.importFont(from: url) {
                            onNotify(AppLocalized("成功导入字体：") + font.title)
                        } else {
                            onNotify(AppLocalized("字体导入失败，请确保格式正确"))
                        }
                    },
                    onCancel: { showFontPicker = false }
                )
            }
        }
    }

    private var systemFontSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(AppLocalized("内置字体风格"))
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(CSSThemeVariables.textMain(scope: .settings))

            HStack(spacing: 6) {
                ForEach(AppearanceFontFamily.allCases) { family in
                    let isSelected = MinisThemeShape.globalCustomFontName == nil && MinisThemeShape.globalFontFamily == family
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        studio.setFontFamily(family)
                        studio.setGlobalCustomFont(nil)
                        onNotify(AppLocalized("已切换字体：") + family.title)
                    } label: {
                        Text(family.title)
                            .font(.system(size: 12, weight: isSelected ? .bold : .medium, design: family.design))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .background(isSelected ? CSSThemeVariables.accent(scope: .settings) : CSSThemeVariables.surfaceFill(scope: .settings))
                            .foregroundStyle(isSelected ? CSSThemeVariables.card(scope: .settings) : CSSThemeVariables.textMain(scope: .settings))
                            .clipShape(Capsule())
                    }
                }
            }
        }
        .padding(12)
        .background(CSSThemeVariables.card(scope: .settings).opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(CSSThemeVariables.divider(scope: .settings), lineWidth: 0.5)
        )
    }

    private var customFontSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(AppLocalized("自定义导入字体 (.ttf / .otf)"))
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(CSSThemeVariables.textMain(scope: .settings))

                Spacer()

                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    showFontPicker = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 11))
                        Text(AppLocalized("导入字体"))
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(CSSThemeVariables.accentSoft(scope: .settings))
                    .foregroundStyle(CSSThemeVariables.accent(scope: .settings))
                    .clipShape(Capsule())
                }
            }

            if fontStore.fonts.isEmpty {
                Text(AppLocalized("暂无已导入的自定义字体"))
                    .font(.system(size: 11))
                    .foregroundStyle(CSSThemeVariables.textDim(scope: .settings))
                    .padding(.vertical, 4)
            } else {
                VStack(spacing: 6) {
                    ForEach(fontStore.fonts) { font in
                        let isApplied = MinisThemeShape.globalCustomFontName == font.postScriptName
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(font.title)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(CSSThemeVariables.textMain(scope: .settings))
                                Text(font.postScriptName)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(CSSThemeVariables.textDim(scope: .settings))
                            }

                            Spacer()

                            Button {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                studio.setGlobalCustomFont(isApplied ? nil : font.postScriptName)
                                onNotify(isApplied ? AppLocalized("已停用自定义字体") : AppLocalized("已应用自定义字体"))
                            } label: {
                                Text(isApplied ? AppLocalized("使用中") : AppLocalized("应用"))
                                    .font(.system(size: 10, weight: .semibold))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(isApplied ? CSSThemeVariables.accent(scope: .settings) : CSSThemeVariables.surfaceFill(scope: .settings))
                                    .foregroundStyle(isApplied ? CSSThemeVariables.card(scope: .settings) : CSSThemeVariables.textMain(scope: .settings))
                                    .clipShape(Capsule())
                            }

                            Button {
                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                fontStore.delete(font)
                                onNotify(AppLocalized("已删除字体"))
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 11))
                                    .foregroundStyle(CSSThemeVariables.textDim(scope: .settings))
                                    .padding(4)
                            }
                        }
                        .padding(8)
                        .background(CSSThemeVariables.surfaceFill(scope: .settings).opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }
            }
        }
        .padding(12)
        .background(CSSThemeVariables.card(scope: .settings).opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(CSSThemeVariables.divider(scope: .settings), lineWidth: 0.5)
        )
    }

    private var typographySlidersSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(AppLocalized("字体大小与留白"))
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(CSSThemeVariables.textMain(scope: .settings))

            // 字号
            sliderRow(
                title: AppLocalized("消息字号"),
                value: Binding(
                    get: { Double(FontSettings.shared.messagePointSize) },
                    set: { FontSettings.shared.messagePointSize = CGFloat($0) }
                ),
                range: 10...15,
                unit: "pt"
            )

            // 行高
            sliderRow(
                title: AppLocalized("正文行高倍率"),
                value: Binding(
                    get: { studio.currentThemePack().lineHeight },
                    set: { studio.setLineHeight($0) }
                ),
                range: 1.0...2.0,
                unit: "x",
                isDecimal: true
            )

            // 字间距
            sliderRow(
                title: AppLocalized("文字间距 (字距)"),
                value: Binding(
                    get: { studio.currentThemePack().letterSpacing },
                    set: { studio.setLetterSpacing($0) }
                ),
                range: -0.5...3.0,
                unit: "pt",
                isDecimal: true
            )
        }
        .padding(12)
        .background(CSSThemeVariables.card(scope: .settings).opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(CSSThemeVariables.divider(scope: .settings), lineWidth: 0.5)
        )
    }

    private func sliderRow(title: String, value: Binding<Double>, range: ClosedRange<Double>, unit: String, isDecimal: Bool = false) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(CSSThemeVariables.textDim(scope: .settings))
                .frame(width: 95, alignment: .leading)

            Slider(value: value, in: range)
                .tint(CSSThemeVariables.accent(scope: .settings))

            Text(isDecimal ? String(format: "%.2f %@", value.wrappedValue, unit) : "\(Int(value.wrappedValue)) \(unit)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(CSSThemeVariables.textDim(scope: .settings))
                .frame(width: 55, alignment: .trailing)
        }
    }

    private var readingModesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(AppLocalized("沉浸阅读与消息形态"))
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(CSSThemeVariables.textMain(scope: .settings))

            VStack(alignment: .leading, spacing: 4) {
                Text(AppLocalized("视觉小说模式"))
                    .font(.system(size: 11))
                    .foregroundStyle(CSSThemeVariables.textDim(scope: .settings))

                HStack(spacing: 6) {
                    ForEach(AppearanceNovelMode.allCases) { mode in
                        let isSelected = studio.currentThemePack().novelMode == mode.rawValue
                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            studio.setNovelMode(mode)
                        } label: {
                            Text(mode.title)
                                .font(.system(size: 11, weight: isSelected ? .bold : .medium))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(isSelected ? CSSThemeVariables.accent(scope: .settings) : CSSThemeVariables.surfaceFill(scope: .settings))
                                .foregroundStyle(isSelected ? CSSThemeVariables.card(scope: .settings) : CSSThemeVariables.textMain(scope: .settings))
                                .clipShape(Capsule())
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(AppLocalized("消息气泡排布"))
                    .font(.system(size: 11))
                    .foregroundStyle(CSSThemeVariables.textDim(scope: .settings))

                HStack(spacing: 6) {
                    ForEach(AppearanceChatDisplay.allCases) { disp in
                        let isSelected = studio.currentThemePack().chatDisplay == disp.rawValue
                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            studio.setChatDisplay(disp)
                        } label: {
                            Text(disp.title)
                                .font(.system(size: 11, weight: isSelected ? .bold : .medium))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(isSelected ? CSSThemeVariables.accent(scope: .settings) : CSSThemeVariables.surfaceFill(scope: .settings))
                                .foregroundStyle(isSelected ? CSSThemeVariables.card(scope: .settings) : CSSThemeVariables.textMain(scope: .settings))
                                .clipShape(Capsule())
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(CSSThemeVariables.card(scope: .settings).opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(CSSThemeVariables.divider(scope: .settings), lineWidth: 0.5)
        )
    }
}

// MARK: - 6. 主题存档库抽屉 (DressingThemeLibrarySheet)

@MainActor
struct DressingThemeLibrarySheet: View {
    let onOpenSave: () -> Void
    let onOpenImportExport: () -> Void
    let onNotify: (String) -> Void
    @ObservedObject private var studio = AppearanceStudio.shared
    @State private var deleteConfirmTheme: AppearanceSavedTheme? = nil

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                DressingSheetHeader(
                    title: AppLocalized("主题档案库"),
                    subtitle: AppLocalized("保存搭配 · 历史存档 · 导入与导出")
                )

                // 快捷操作胶囊
                HStack(spacing: 8) {
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        onOpenSave()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "square.and.arrow.down.fill")
                                .font(.system(size: 11))
                            Text(AppLocalized("保存当前主题"))
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(CSSThemeVariables.accent(scope: .settings))
                        .foregroundStyle(CSSThemeVariables.card(scope: .settings))
                        .clipShape(Capsule())
                    }

                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        onOpenImportExport()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up.arrow.down")
                                .font(.system(size: 11))
                            Text(AppLocalized("导入 / 导出"))
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(CSSThemeVariables.surfaceFill(scope: .settings))
                        .foregroundStyle(CSSThemeVariables.textMain(scope: .settings))
                        .clipShape(Capsule())
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(AppLocalized("我的已存主题 (\(studio.savedThemes().count))"))
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(CSSThemeVariables.textMain(scope: .settings))

                        if studio.savedThemes().isEmpty {
                            Text(AppLocalized("还没有保存任何主题，点击上方“保存当前主题”即可存入"))
                                .font(.system(size: 11))
                                .foregroundStyle(CSSThemeVariables.textDim(scope: .settings))
                                .padding(.vertical, 12)
                        } else {
                            ForEach(studio.savedThemes()) { theme in
                                savedThemeCard(theme)
                            }
                        }
                    }
                    .padding(16)
                }
            }
            .background(AppearanceBackdrop(scope: .settings).ignoresSafeArea())
            .confirmationDialog(
                AppLocalized("确认删除此主题存档？"),
                isPresented: Binding(
                    get: { deleteConfirmTheme != nil },
                    set: { if !$0 { deleteConfirmTheme = nil } }
                ),
                titleVisibility: .visible
            ) {
                if let t = deleteConfirmTheme {
                    Button(AppLocalized("确认删除"), role: .destructive) {
                        _ = studio.deleteSavedThemeDetailed(id: t.id)
                        deleteConfirmTheme = nil
                        onNotify(AppLocalized("已删除主题：") + t.name)
                    }
                }
                Button(AppLocalized("取消"), role: .cancel) {
                    deleteConfirmTheme = nil
                }
            }
        }
    }

    /// applyThemePack 警告里只有这三个是良性的。带 Kept 的三个
    /// （surfaceOpacityKept / wallpaperShadeKept / bubbleOpacityKept）
    /// 是 T-46 定好的常规保留——包里没写旋钮就留着她的值，不是失败。
    /// 除此之外的警告一律算失败：分页面壁纸失败是 "wallpaper:<scope>"、
    /// 分类图解不出来是分类键本身（code / writing / …），还有以后新增的
    /// 未知警告码——默认判失败比默认放行更诚实。
    private static let applyBenignWarningCodes: Set<String> = [
        "surfaceOpacityKept", "wallpaperShadeKept", "bubbleOpacityKept"
    ]

    private func failedPieceLabel(_ code: String) -> String {
        switch code {
        case "userBubble": return AppLocalized("我的气泡")
        case "assistantBubble": return AppLocalized("AI 气泡")
        case "userPendant": return AppLocalized("我的挂件")
        case "assistantPendant": return AppLocalized("AI 挂件")
        default: return code
        }
    }

    private func savedThemeCard(_ theme: AppearanceSavedTheme) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(theme.name)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(CSSThemeVariables.textMain(scope: .settings))

                Text(theme.savedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 10))
                    .foregroundStyle(CSSThemeVariables.textDim(scope: .settings))
            }

            Spacer()

            Button {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                if let result = studio.applySavedThemeSet(id: theme.id) {
                    // 只有 Kept 三码是良性保留，其余警告一律算失败。
                    let failureWarnings = result.packWarnings.filter {
                        !Self.applyBenignWarningCodes.contains($0)
                    }
                    if result.packWarnings.contains("pack") {
                        // 包没落盘就提前返回了，什么都没换上，算彻底失败。
                        onNotify(AppLocalized("主题应用失败"))
                    } else if result.failedPieces.isEmpty, failureWarnings.isEmpty {
                        onNotify(AppLocalized("已成功换上：") + theme.name)
                    } else if !result.failedPieces.isEmpty {
                        var message = AppLocalized("已换上，但没换上：") + result.failedPieces.map({ failedPieceLabel($0) }).joined(separator: "、")
                        if !failureWarnings.isEmpty {
                            message += "、" + AppLocalized("还有部分内容没换过来")
                        }
                        onNotify(message)
                    } else {
                        onNotify(AppLocalized("已换上，但部分内容没换过来"))
                    }
                } else {
                    onNotify(AppLocalized("主题应用失败"))
                }
            } label: {
                Text(AppLocalized("换上"))
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(CSSThemeVariables.accentSoft(scope: .settings))
                    .foregroundStyle(CSSThemeVariables.accent(scope: .settings))
                    .clipShape(Capsule())
            }

            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                deleteConfirmTheme = theme
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundStyle(CSSThemeVariables.textDim(scope: .settings))
                    .padding(6)
            }
        }
        .padding(12)
        .background(CSSThemeVariables.card(scope: .settings).opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(CSSThemeVariables.divider(scope: .settings), lineWidth: 0.5)
        )
    }
}

// MARK: - 7. 细节与图标抽屉 (DressingDetailsIconsSheet)

@MainActor
struct DressingDetailsIconsSheet: View {
    let onNotify: (String) -> Void
    @ObservedObject private var studio = AppearanceStudio.shared

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                DressingSheetHeader(
                    title: AppLocalized("细节与图标"),
                    subtitle: AppLocalized("界面图标自定义 · 代码块折叠 · 渲染细项")
                )

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 16) {
                        // 代码折叠
                        codeBlockSection

                        // 界面静音图标 Slots
                        iconSlotsSection
                    }
                    .padding(16)
                }
            }
            .background(AppearanceBackdrop(scope: .settings).ignoresSafeArea())
        }
    }

    private var codeBlockSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(AppLocalized("代码块折叠设置"))
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(CSSThemeVariables.textMain(scope: .settings))

            HStack(spacing: 8) {
                Text(AppLocalized("自动折叠行数"))
                    .font(.system(size: 11))
                    .foregroundStyle(CSSThemeVariables.textDim(scope: .settings))

                Slider(
                    value: Binding(
                        get: { Double(studio.currentThemePack().codeBlockCollapseLines) },
                        set: { studio.setCodeBlockCollapseLines(Int($0)) }
                    ),
                    in: 4...40,
                    step: 4
                )
                .tint(CSSThemeVariables.accent(scope: .settings))

                let lines = studio.currentThemePack().codeBlockCollapseLines
                Text("\(lines) 行")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(CSSThemeVariables.textDim(scope: .settings))
                    .frame(width: 45, alignment: .trailing)
            }
        }
        .padding(12)
        .background(CSSThemeVariables.card(scope: .settings).opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(CSSThemeVariables.divider(scope: .settings), lineWidth: 0.5)
        )
    }

    private var iconSlotsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(AppLocalized("常用界面图标"))
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(CSSThemeVariables.textMain(scope: .settings))

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach([QuietIconSlot.decorate, .skills, .memory, .terminal, .browser, .storage], id: \.self) { slot in
                    iconSlotCard(slot)
                }
            }
        }
        .padding(12)
        .background(CSSThemeVariables.card(scope: .settings).opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(CSSThemeVariables.divider(scope: .settings), lineWidth: 0.5)
        )
    }

    private func iconSlotCard(_ slot: QuietIconSlot) -> some View {
        HStack(spacing: 8) {
            QuietAppIcon(id: slot.id, systemName: slot.systemName, size: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(slot.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(CSSThemeVariables.textMain(scope: .settings))
                    .lineLimit(1)
            }

            Spacer()

            if studio.customIcon(for: slot.id) != nil {
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    _ = studio.removeIcon(for: slot.id)
                    onNotify(AppLocalized("已恢复默认图标"))
                } label: {
                    Text(AppLocalized("重置"))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(CSSThemeVariables.textDim(scope: .settings))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(CSSThemeVariables.surfaceFill(scope: .settings))
                        .clipShape(Capsule())
                }
            }
        }
        .padding(8)
        .background(CSSThemeVariables.surfaceFill(scope: .settings).opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - 8. 保存主题弹窗 (DressingSaveThemeSheet)

@MainActor
struct DressingSaveThemeSheet: View {
    let onSaved: (String) -> Void
    let onNotify: (String) -> Void
    @ObservedObject private var studio = AppearanceStudio.shared
    @State private var themeName: String = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                DressingSheetHeader(
                    title: AppLocalized("保存为新主题"),
                    subtitle: AppLocalized("记录当前调色、气泡、壁纸与字体")
                )

                VStack(alignment: .leading, spacing: 8) {
                    Text(AppLocalized("主题名称"))
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(CSSThemeVariables.textDim(scope: .settings))

                    TextField(AppLocalized("给这款主题起个名字..."), text: $themeName)
                        .padding(12)
                        .background(CSSThemeVariables.surfaceFill(scope: .settings))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .foregroundStyle(CSSThemeVariables.textMain(scope: .settings))
                }
                .padding(.horizontal, 16)

                Button {
                    let trimmed = themeName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    if studio.saveCurrentTheme(name: trimmed) != nil {
                        onSaved(trimmed)
                        dismiss()
                    } else {
                        // 存档库满 40 套时 saveCurrentTheme 返回 nil：如实报，不关弹窗。
                        onNotify(AppLocalized("存档库已满（40 套），删一套再存"))
                    }
                } label: {
                    Text(AppLocalized("立即保存"))
                        .font(.system(size: 14, weight: .bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(themeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? CSSThemeVariables.surfaceFill(scope: .settings) : CSSThemeVariables.accent(scope: .settings))
                        .foregroundStyle(themeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? CSSThemeVariables.textDim(scope: .settings) : CSSThemeVariables.card(scope: .settings))
                        .clipShape(Capsule())
                }
                .disabled(themeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .padding(.horizontal, 16)

                Spacer()
            }
            .background(AppearanceBackdrop(scope: .settings).ignoresSafeArea())
        }
    }
}

// MARK: - 9. 导入导出弹窗 (DressingImportExportSheet)

@MainActor
struct DressingImportExportSheet: View {
    let onNotify: (String) -> Void
    @ObservedObject private var studio = AppearanceStudio.shared
    @State private var importText: String = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                DressingSheetHeader(
                    title: AppLocalized("主题导入与导出"),
                    subtitle: AppLocalized("支持标准 JSON 主题包")
                )

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 16) {
                        // 导出卡片
                        VStack(alignment: .leading, spacing: 10) {
                            Text(AppLocalized("导出当前主题"))
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(CSSThemeVariables.textMain(scope: .settings))

                            Text(AppLocalized("将当前主题生成为 JSON 字符串并写入系统剪贴板。"))
                                .font(.system(size: 11))
                                .foregroundStyle(CSSThemeVariables.textDim(scope: .settings))

                            Button {
                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                let pack = studio.exportThemePack(includeWallpaper: true)
                                if let data = try? JSONSerialization.data(withJSONObject: pack.asJSONObject(), options: [.prettyPrinted, .sortedKeys]),
                                   let str = String(data: data, encoding: .utf8) {
                                    UIPasteboard.general.string = str
                                    onNotify(AppLocalized("已复制主题包 JSON 到剪贴板"))
                                    dismiss()
                                } else {
                                    onNotify(AppLocalized("导出主题失败"))
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "doc.on.doc")
                                        .font(.system(size: 11))
                                    Text(AppLocalized("复制主题 JSON"))
                                        .font(.system(size: 12, weight: .semibold))
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(CSSThemeVariables.accent(scope: .settings))
                                .foregroundStyle(CSSThemeVariables.card(scope: .settings))
                                .clipShape(Capsule())
                            }
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(CSSThemeVariables.card(scope: .settings).opacity(0.85))
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(CSSThemeVariables.divider(scope: .settings), lineWidth: 0.5)
                        )

                        // 导入卡片
                        VStack(alignment: .leading, spacing: 10) {
                            Text(AppLocalized("从剪贴板或文本导入"))
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(CSSThemeVariables.textMain(scope: .settings))

                            TextEditor(text: $importText)
                                .frame(height: 120)
                                .padding(8)
                                .background(CSSThemeVariables.surfaceFill(scope: .settings))
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .font(.system(size: 11, design: .monospaced))

                            HStack(spacing: 8) {
                                Button {
                                    if let clip = UIPasteboard.general.string {
                                        importText = clip
                                        onNotify(AppLocalized("已粘贴剪贴板内容"))
                                    }
                                } label: {
                                    Text(AppLocalized("粘贴"))
                                        .font(.system(size: 11, weight: .medium))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(CSSThemeVariables.surfaceFill(scope: .settings))
                                        .foregroundStyle(CSSThemeVariables.textMain(scope: .settings))
                                        .clipShape(Capsule())
                                }

                                Spacer()

                                Button {
                                    applyImportedPack()
                                } label: {
                                    Text(AppLocalized("解析并换上"))
                                        .font(.system(size: 12, weight: .bold))
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 6)
                                        .background(importText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? CSSThemeVariables.surfaceFill(scope: .settings) : CSSThemeVariables.accent(scope: .settings))
                                        .foregroundStyle(importText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? CSSThemeVariables.textDim(scope: .settings) : CSSThemeVariables.card(scope: .settings))
                                        .clipShape(Capsule())
                                }
                                .disabled(importText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(CSSThemeVariables.card(scope: .settings).opacity(0.85))
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(CSSThemeVariables.divider(scope: .settings), lineWidth: 0.5)
                        )
                    }
                    .padding(16)
                }
            }
            .background(AppearanceBackdrop(scope: .settings).ignoresSafeArea())
        }
    }

    private func applyImportedPack() {
        guard let data = importText.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            onNotify(AppLocalized("输入的 JSON 格式无效"))
            return
        }

        do {
            let pack = try AppearanceThemePack.decode(obj)
            studio.applyThemePack(pack, mode: .replace)
            onNotify(AppLocalized("已成功导入并换上主题：") + pack.name)
            dismiss()
        } catch {
            onNotify(AppLocalized("主题解析失败：") + error.localizedDescription)
        }
    }
}
