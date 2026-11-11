import SwiftUI
import PhotosUI
import UIKit
import UniformTypeIdentifiers

// MARK: - 装扮中心 (DressingShopView)
// 统一接入 AppearanceStudio, BubbleStylePackStore, AvatarPendantStore,
// UploadedFontStore, FontSettings, AppearanceThemePackStore。
// 颜色走 CSSThemeVariables 全局变量，按钮做小做精致，iOS 26 胶囊与抽屉交互。

struct DressingShopView: View {
    @AppStorage(AppearanceMode.defaultsKey) private var appearanceModeRaw: Int = 0
    @StateObject private var studio = AppearanceStudio.shared
    @ObservedObject private var bubbleStore = BubbleStylePackStore.shared
    @ObservedObject private var pendantStore = AvatarPendantStore.shared
    @ObservedObject private var fontStore = UploadedFontStore.shared
    @ObservedObject private var fontSettings = FontSettings.shared

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
                    .padding(.horizontal, DressingTokens.Padding.page)
                    .padding(.top, DressingTokens.Padding.sectionTop)
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
                                .font(ChatFont.font(13, weight: .medium))
                        }
                        .padding(.horizontal, DressingTokens.Padding.pillHorizontal)
                        .padding(.vertical, DressingTokens.Padding.pillVertical)
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
                        .font(ChatFont.font(13, weight: .medium))
                        .foregroundStyle(CSSThemeVariables.card(scope: .settings))
                        .padding(.horizontal, DressingTokens.Padding.page)
                        .padding(.vertical, DressingTokens.Padding.cardVertical)
                        .background(CSSThemeVariables.textMain(scope: .settings))
                        .clipShape(Capsule())
                        .shadow(color: DressingTokens.Shadow.floatingColor, radius: DressingTokens.Shadow.floatingRadius, y: DressingTokens.Shadow.floatingY)
                        .padding(.bottom, DressingTokens.Padding.scrollBottom)
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
                .font(ChatFont.font(13, weight: .medium))
                .foregroundStyle(CSSThemeVariables.textDim(scope: .settings))

            Spacer()

            HStack(spacing: 4) {
                modePill(title: AppLocalized("自动"), mode: .system)
                modePill(title: AppLocalized("日间"), mode: .light)
                modePill(title: AppLocalized("夜间"), mode: .dark)
            }
            .padding(DressingTokens.Padding.segment)
            .background(CSSThemeVariables.surfaceFill(scope: .settings))
            .clipShape(Capsule())
        }
        .padding(.horizontal, DressingTokens.Padding.cardHorizontal)
        .padding(.vertical, DressingTokens.Padding.cardVertical)
        .background(CSSThemeVariables.card(scope: .settings).opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: DressingTokens.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DressingTokens.Radius.card, style: .continuous)
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
                .font(ChatFont.font(12, weight: isSelected ? .semibold : .regular))
                .padding(.horizontal, DressingTokens.Padding.pillHorizontal)
                .padding(.vertical, DressingTokens.Padding.pillVertical)
                .background(isSelected ? CSSThemeVariables.card(scope: .settings) : Color.clear)
                .foregroundStyle(isSelected ? CSSThemeVariables.textMain(scope: .settings) : CSSThemeVariables.textDim(scope: .settings))
                .clipShape(Capsule())
                .shadow(color: DressingTokens.Shadow.selectedColor(isSelected: isSelected), radius: DressingTokens.Shadow.selectedRadius, y: DressingTokens.Shadow.selectedY)
        }
    }

    // 2. 实时微缩预览卡片
    private var livePreviewDock: some View {
        VStack(spacing: 12) {
            HStack(alignment: .center, spacing: 8) {
                // 主题标题与状态小标签
                VStack(alignment: .leading, spacing: 3) {
                    Text(studio.currentThemePack().name)
                        .font(ChatFont.font(16, weight: .bold))
                        .foregroundStyle(CSSThemeVariables.textMain(scope: .settings))

                    HStack(spacing: 6) {
                        Circle()
                            .fill(CSSThemeVariables.accent(scope: .settings))
                            .frame(width: 7, height: 7)

                        Text(AppearanceFontFamily.parse(studio.currentThemePack().fontFamily).title + " · " + (bubbleStore.appliedPack(for: .user)?.title ?? AppLocalized("默认气泡")))
                            .font(ChatFont.font(11, weight: .medium))
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
                                .padding(DressingTokens.Padding.inner)
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
                            .font(ChatFont.font(12))
                            .foregroundStyle(CSSThemeVariables.textMain(scope: .chat))
                            .padding(.horizontal, DressingTokens.Padding.contentHorizontal)
                            .padding(.vertical, DressingTokens.Padding.contentVertical)
                            .background(CSSThemeVariables.card(scope: .chat))
                            .clipShape(RoundedRectangle(cornerRadius: CGFloat(studio.currentThemePack().assistantBubbleRadius), style: .continuous))
                    }
                    Spacer(minLength: 20)
                }

                // 用户侧模拟气泡
                HStack(alignment: .top, spacing: 8) {
                    Spacer(minLength: 20)
                    Text(AppLocalized("做简单、精致、iOS 26 质感～"))
                        .font(ChatFont.font(12))
                        .foregroundStyle(CSSThemeVariables.card(scope: .chat))
                        .padding(.horizontal, DressingTokens.Padding.contentHorizontal)
                        .padding(.vertical, DressingTokens.Padding.contentVertical)
                        .background(CSSThemeVariables.accent(scope: .chat))
                        .clipShape(RoundedRectangle(cornerRadius: CGFloat(studio.currentThemePack().userBubbleRadius), style: .continuous))
                    miniAvatar(isUser: true)
                }
            }
            .padding(DressingTokens.Padding.card)
            .background(CSSThemeVariables.bg(scope: .chat).opacity(0.85))
            .clipShape(RoundedRectangle(cornerRadius: DressingTokens.Radius.innerCard, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DressingTokens.Radius.innerCard, style: .continuous)
                    .stroke(CSSThemeVariables.divider(scope: .settings), lineWidth: 0.5)
            )
        }
        .padding(DressingTokens.Padding.section)
        .background(CSSThemeVariables.card(scope: .settings).opacity(0.92))
        .clipShape(RoundedRectangle(cornerRadius: DressingTokens.Radius.previewDock, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DressingTokens.Radius.previewDock, style: .continuous)
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
                        .font(ChatFont.font(13, weight: .semibold))
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
                        .font(ChatFont.font(11, weight: .medium))
                        .foregroundStyle(CSSThemeVariables.textDim(scope: .settings))
                        .padding(.horizontal, DressingTokens.Padding.rowHorizontal)
                        .padding(.vertical, DressingTokens.Padding.smallPillVertical)
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

                // [glass-switch] 全局玻璃感：跟三颗旋钮同一张卡，开关只管
                // 玻璃开不开，不管透多少——透多少还是上面三颗旋钮的事。
                HStack(spacing: 10) {
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(CSSThemeVariables.textDim(scope: .settings))
                        .frame(width: 16)

                    Text(AppLocalized("全局玻璃感"))
                        .font(ChatFont.font(12))
                        .foregroundStyle(CSSThemeVariables.textMain(scope: .settings))

                    Spacer()

                    Toggle(AppLocalized("全局玻璃感"), isOn: $studio.glassEnabled)
                        .labelsHidden()
                        .tint(CSSThemeVariables.accent(scope: .settings))
                }
            }
        }
        .padding(DressingTokens.Padding.section)
        .background(CSSThemeVariables.card(scope: .settings).opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: DressingTokens.Radius.largeCard, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DressingTokens.Radius.largeCard, style: .continuous)
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
                .font(ChatFont.font(12))
                .foregroundStyle(CSSThemeVariables.textMain(scope: .settings))

            Spacer()

            Slider(value: value, in: 0.0...1.0)
                .frame(width: 110)
                .tint(CSSThemeVariables.accent(scope: .settings))

            Text("\(Int(value.wrappedValue * 100))%")
                .font(ChatFont.font(11, weight: .semibold, design: .monospaced))
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
                        .font(ChatFont.font(14, weight: .bold))
                        .foregroundStyle(CSSThemeVariables.textMain(scope: .settings))

                    Text(sub)
                        .font(ChatFont.font(11))
                        .foregroundStyle(CSSThemeVariables.textDim(scope: .settings))
                        .lineLimit(1)
                }
            }
            .padding(DressingTokens.Padding.section)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(CSSThemeVariables.card(scope: .settings).opacity(0.85))
            .clipShape(RoundedRectangle(cornerRadius: DressingTokens.Radius.largeCard, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DressingTokens.Radius.largeCard, style: .continuous)
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
                        .font(ChatFont.font(13, weight: .medium))
                }
                .foregroundStyle(CSSThemeVariables.textDim(scope: .settings))
                .padding(.vertical, DressingTokens.Padding.contentVertical)
            }
        }
        .padding(.top, DressingTokens.Padding.sectionTop)
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
    @ObservedObject private var fontSettings = FontSettings.shared

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(ChatFont.font(17, weight: .bold))
                    .foregroundStyle(CSSThemeVariables.textMain(scope: .settings))

                if let sub = subtitle {
                    Text(sub)
                        .font(ChatFont.font(11))
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
        .padding(.horizontal, DressingTokens.Padding.page)
        .padding(.top, DressingTokens.Padding.sheetTop)
        .padding(.bottom, DressingTokens.Padding.sheetBottom)
    }
}


// MARK: - 1. 经典预设快速拾取 (DressingPresetsSheet)

@MainActor
struct DressingPresetsSheet: View {
    let onApply: (String) -> Void
    @ObservedObject private var studio = AppearanceStudio.shared
    @ObservedObject private var fontSettings = FontSettings.shared
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
                        composerIconCard()
                    }
                    .padding(DressingTokens.Padding.sheet)
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
                        .font(ChatFont.font(14, weight: .bold))
                        .foregroundStyle(CSSThemeVariables.textMain(scope: .settings))

                    Spacer()

                    // [P1-8] 正在用的那套才标：`isPresetActive` 是 live 算的，
                    // 任何一处改色、改壁纸都会让它立刻掉下去，不会过期。
                    if studio.isPresetActive(preset) {
                        Text(AppLocalized("正在用"))
                            .font(ChatFont.font(10, weight: .semibold))
                            .foregroundStyle(CSSThemeVariables.accent(scope: .settings))
                            .padding(.horizontal, DressingTokens.Padding.headerPillHorizontal)
                            .padding(.vertical, DressingTokens.Padding.smallPillVertical)
                            .background(CSSThemeVariables.accentSoft(scope: .settings))
                            .clipShape(Capsule())
                    }
                }

                Text(presetSubtitle(preset))
                    .font(ChatFont.font(11))
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
                        .font(ChatFont.font(10, weight: .medium))
                }
                .foregroundStyle(CSSThemeVariables.accent(scope: .settings))
                .padding(.horizontal, DressingTokens.Padding.rowHorizontal)
                .padding(.vertical, DressingTokens.Padding.rowVertical)
                .background(CSSThemeVariables.accentSoft(scope: .settings))
                .clipShape(Capsule())
            }
            .padding(DressingTokens.Padding.card)
            .background(CSSThemeVariables.card(scope: .settings).opacity(0.85))
            .clipShape(RoundedRectangle(cornerRadius: DressingTokens.Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DressingTokens.Radius.card, style: .continuous)
                    .stroke(CSSThemeVariables.divider(scope: .settings), lineWidth: 0.5)
            )
        }
        .buttonStyle(DressingPressStyle())
    }

    /// [composer-icons] 金色按键卡片：和预设卡同一张卡面、同一套“正在用”标记。
    /// 点一下换上四张图（只换四颗键的图片，不碰颜色、壁纸、气泡、字体）；
    /// 正在用时再点一下就取下，回到默认干净界面（系统符号）。
    private func composerIconCard() -> some View {
        let set = ComposerIconSet.gold
        let active = studio.isComposerIconSetActive(set)
        return Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            if active {
                studio.clearComposerIcons()
                onApply(AppLocalized("默认按键"))
            } else {
                studio.applyComposerIcons(set)
                onApply(set.title)
            }
            dismiss()
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(CSSThemeVariables.accent(scope: .settings))
                        .frame(width: 14, height: 14)

                    Text(set.title)
                        .font(ChatFont.font(14, weight: .bold))
                        .foregroundStyle(CSSThemeVariables.textMain(scope: .settings))

                    Spacer()

                    if active {
                        Text(AppLocalized("正在用"))
                            .font(ChatFont.font(10, weight: .semibold))
                            .foregroundStyle(CSSThemeVariables.accent(scope: .settings))
                            .padding(.horizontal, DressingTokens.Padding.headerPillHorizontal)
                            .padding(.vertical, DressingTokens.Padding.smallPillVertical)
                            .background(CSSThemeVariables.accentSoft(scope: .settings))
                            .clipShape(Capsule())
                    }
                }

                Text(AppLocalized("输入栏四颗键换成金色图片"))
                    .font(ChatFont.font(11))
                    .foregroundStyle(CSSThemeVariables.textDim(scope: .settings))
                    .lineLimit(2)
                    .frame(height: 28, alignment: .topLeading)

                HStack(spacing: 4) {
                    ForEach(set.previewImages, id: \.self) { name in
                        Image(name)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 24, height: 24)
                            .clipShape(Circle())
                    }
                    Spacer()
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 10))
                    Text(AppLocalized(active ? "取下" : "换上"))
                        .font(ChatFont.font(10, weight: .medium))
                }
                .foregroundStyle(CSSThemeVariables.accent(scope: .settings))
                .padding(.horizontal, DressingTokens.Padding.rowHorizontal)
                .padding(.vertical, DressingTokens.Padding.rowVertical)
                .background(CSSThemeVariables.accentSoft(scope: .settings))
                .clipShape(Capsule())
            }
            .padding(DressingTokens.Padding.card)
            .background(CSSThemeVariables.card(scope: .settings).opacity(0.85))
            .clipShape(RoundedRectangle(cornerRadius: DressingTokens.Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DressingTokens.Radius.card, style: .continuous)
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
    @ObservedObject private var fontSettings = FontSettings.shared
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
                                        .font(ChatFont.font(12, weight: .medium))
                                }
                                .foregroundStyle(CSSThemeVariables.textDim(scope: .settings))
                                .padding(.horizontal, DressingTokens.Padding.contentHorizontal)
                                .padding(.vertical, DressingTokens.Padding.contentVertical)
                                .background(CSSThemeVariables.surfaceFill(scope: .settings))
                                .clipShape(Capsule())
                            }
                            .disabled(!canClearPageOverrides)
                            .opacity(canClearPageOverrides ? 1.0 : 0.5)

                            Spacer()
                        }
                        .padding(.top, DressingTokens.Padding.sectionTop)
                    }
                    .padding(DressingTokens.Padding.sheet)
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
                                .font(ChatFont.font(12, weight: isSelected ? .semibold : .regular))
                                .padding(.horizontal, DressingTokens.Padding.pillHorizontal)
                                .padding(.vertical, DressingTokens.Padding.pillVertical)
                                .background(isSelected ? CSSThemeVariables.accent(scope: .settings) : CSSThemeVariables.surfaceFill(scope: .settings))
                                .foregroundStyle(isSelected ? CSSThemeVariables.card(scope: .settings) : CSSThemeVariables.textMain(scope: .settings))
                                .clipShape(Capsule())
                        }
                    }
                }
                .padding(.horizontal, DressingTokens.Padding.page)
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
                            .font(ChatFont.font(12, weight: isSelected ? .semibold : .regular))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, DressingTokens.Padding.widePillVertical)
                            .background(isSelected ? CSSThemeVariables.card(scope: .settings) : Color.clear)
                            .foregroundStyle(isSelected ? CSSThemeVariables.textMain(scope: .settings) : CSSThemeVariables.textDim(scope: .settings))
                            .clipShape(Capsule())
                    }
                }
            }
            .padding(DressingTokens.Padding.segment)
            .background(CSSThemeVariables.surfaceFill(scope: .settings))
            .clipShape(Capsule())
            .padding(.horizontal, DressingTokens.Padding.page)
        }
        .padding(.vertical, DressingTokens.Padding.widePillVertical)
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
                            .font(ChatFont.font(11, weight: isSelected ? .bold : .medium))
                            .padding(.horizontal, DressingTokens.Padding.pillHorizontal)
                            .padding(.vertical, DressingTokens.Padding.rowVertical)
                            .background(isSelected ? CSSThemeVariables.accentSoft(scope: .settings) : Color.clear)
                            .foregroundStyle(isSelected ? CSSThemeVariables.accent(scope: .settings) : CSSThemeVariables.textDim(scope: .settings))
                            .clipShape(Capsule())
                    }
                }
            }
            .padding(.horizontal, DressingTokens.Padding.page)
        }
        .padding(.vertical, DressingTokens.Padding.rowVertical)
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
                    .font(ChatFont.font(13, weight: .medium))
                    .foregroundStyle(CSSThemeVariables.textMain(scope: .settings))

                Text("#" + currentHex)
                    .font(ChatFont.font(11, design: .monospaced))
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
                    .padding(DressingTokens.Padding.tiny)
                    .background(CSSThemeVariables.surfaceFill(scope: .settings))
                    .clipShape(Circle())
            }
        }
        .padding(.horizontal, DressingTokens.Padding.contentHorizontal)
        .padding(.vertical, DressingTokens.Padding.tallRowVertical)
        .background(CSSThemeVariables.card(scope: .settings).opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: DressingTokens.Radius.innerCard, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DressingTokens.Radius.innerCard, style: .continuous)
                .stroke(CSSThemeVariables.divider(scope: .settings), lineWidth: 0.5)
        )
    }
}


// MARK: - 3. 壁纸与立绘抽屉 (DressingWallpaperArtSheet)

@MainActor
struct DressingWallpaperArtSheet: View {
    let onNotify: (String) -> Void
    @ObservedObject private var studio = AppearanceStudio.shared
    @ObservedObject private var fontSettings = FontSettings.shared
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
                    .padding(DressingTokens.Padding.sheet)
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
                .font(ChatFont.font(13, weight: .bold))
                .foregroundStyle(CSSThemeVariables.textMain(scope: .settings))

            // Scope 切换
            HStack(spacing: 6) {
                ForEach([AppearanceScope.global, .chat, .home, .settings, .browser, .terminal], id: \.self) { sc in
                    let isSelected = selectedScope == sc
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        selectedScope = sc
                    } label: {
                        Text(sc.title)
                            .font(ChatFont.font(11, weight: isSelected ? .semibold : .regular))
                            .padding(.horizontal, DressingTokens.Padding.pillHorizontal)
                            .padding(.vertical, DressingTokens.Padding.pillVertical)
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
                        .clipShape(RoundedRectangle(cornerRadius: DressingTokens.Radius.field, style: .continuous))
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: DressingTokens.Radius.field, style: .continuous)
                            .fill(CSSThemeVariables.surfaceFill(scope: .settings))
                            .frame(width: 64, height: 64)
                        Image(systemName: "photo")
                            .foregroundStyle(CSSThemeVariables.textDim(scope: .settings))
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(selectedScope == .global ? AppLocalized("全局通用壁纸") : AppLocalized("该页面独立壁纸"))
                        .font(ChatFont.font(13, weight: .medium))
                        .foregroundStyle(CSSThemeVariables.textMain(scope: .settings))

                    Text(studio.hasOwnWallpaper(selectedScope) ? AppLocalized("已自定义壁纸") : AppLocalized("未单独设置（遵循主题底色或全局壁纸）"))
                        .font(ChatFont.font(11))
                        .foregroundStyle(CSSThemeVariables.textDim(scope: .settings))

                    HStack(spacing: 8) {
                        PhotosPicker(selection: $pickedWallpaperItem, matching: .images) {
                            HStack(spacing: 4) {
                                Image(systemName: "photo.badge.plus")
                                    .font(.system(size: 10))
                                Text(AppLocalized("从相册选择"))
                                    .font(ChatFont.font(11, weight: .semibold))
                            }
                            .padding(.horizontal, DressingTokens.Padding.pillHorizontal)
                            .padding(.vertical, DressingTokens.Padding.pillVertical)
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
                                    .font(ChatFont.font(11, weight: .medium))
                                    .foregroundStyle(CSSThemeVariables.textDim(scope: .settings))
                                    .padding(.horizontal, DressingTokens.Padding.rowHorizontal)
                                    .padding(.vertical, DressingTokens.Padding.pillVertical)
                                    .background(CSSThemeVariables.surfaceFill(scope: .settings))
                                    .clipShape(Capsule())
                            }
                        }
                    }
                    .padding(.top, DressingTokens.Padding.labelTop)
                }
            }
            .padding(DressingTokens.Padding.card)
            .background(CSSThemeVariables.card(scope: .settings).opacity(0.85))
            .clipShape(RoundedRectangle(cornerRadius: DressingTokens.Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DressingTokens.Radius.card, style: .continuous)
                    .stroke(CSSThemeVariables.divider(scope: .settings), lineWidth: 0.5)
            )
        }
    }

    private var characterArtSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(AppLocalized("助手专属立绘 (Character Art)"))
                .font(ChatFont.font(13, weight: .bold))
                .foregroundStyle(CSSThemeVariables.textMain(scope: .settings))

            HStack(spacing: 12) {
                if let art = studio.characterArtImage() {
                    Image(uiImage: art)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 50, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: DressingTokens.Radius.chip, style: .continuous))
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: DressingTokens.Radius.chip, style: .continuous)
                            .fill(CSSThemeVariables.surfaceFill(scope: .settings))
                            .frame(width: 50, height: 64)
                        Image(systemName: "person.crop.artframe")
                            .foregroundStyle(CSSThemeVariables.textDim(scope: .settings))
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(studio.hasCharacterArt ? AppLocalized("立绘已就绪（将在特定模式下展示）") : AppLocalized("尚未设置立绘"))
                        .font(ChatFont.font(12))
                        .foregroundStyle(CSSThemeVariables.textDim(scope: .settings))

                    HStack(spacing: 8) {
                        PhotosPicker(selection: $pickedArtItem, matching: .images) {
                            Text(AppLocalized("上传立绘"))
                                .font(ChatFont.font(11, weight: .semibold))
                                .padding(.horizontal, DressingTokens.Padding.pillHorizontal)
                                .padding(.vertical, DressingTokens.Padding.pillVertical)
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
                                    .font(ChatFont.font(11))
                                    .foregroundStyle(CSSThemeVariables.textDim(scope: .settings))
                                    .padding(.horizontal, DressingTokens.Padding.rowHorizontal)
                                    .padding(.vertical, DressingTokens.Padding.pillVertical)
                                    .background(CSSThemeVariables.surfaceFill(scope: .settings))
                                    .clipShape(Capsule())
                            }
                        }
                    }
                }
            }
            .padding(DressingTokens.Padding.card)
            .background(CSSThemeVariables.card(scope: .settings).opacity(0.85))
            .clipShape(RoundedRectangle(cornerRadius: DressingTokens.Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DressingTokens.Radius.card, style: .continuous)
                    .stroke(CSSThemeVariables.divider(scope: .settings), lineWidth: 0.5)
            )
        }
    }

    private var componentDecorSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(AppLocalized("部件背景装饰图"))
                .font(ChatFont.font(13, weight: .bold))
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
                    .font(ChatFont.font(12, weight: .medium))
                    .foregroundStyle(CSSThemeVariables.textMain(scope: .settings))

                Spacer()

                PhotosPicker(selection: pickerItem, matching: .images) {
                    Text(hasImage ? AppLocalized("更换图片") : AppLocalized("添加图片"))
                        .font(ChatFont.font(11, weight: .semibold))
                        .padding(.horizontal, DressingTokens.Padding.rowHorizontal)
                        .padding(.vertical, DressingTokens.Padding.rowVertical)
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
                        .font(ChatFont.font(10))
                        .foregroundStyle(CSSThemeVariables.textDim(scope: .settings))

                    Slider(value: opacity, in: 0.05...1.0)
                        .tint(CSSThemeVariables.accent(scope: .settings))

                    Text("\(Int(opacity.wrappedValue * 100))%")
                        .font(ChatFont.font(10, design: .monospaced))
                        .foregroundStyle(CSSThemeVariables.textDim(scope: .settings))
                }
            }
        }
        .padding(DressingTokens.Padding.card)
        .background(CSSThemeVariables.card(scope: .settings).opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: DressingTokens.Radius.innerCard, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DressingTokens.Radius.innerCard, style: .continuous)
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
    @ObservedObject private var fontSettings = FontSettings.shared

    @State private var selectedTab: Int = 0 // 0: 气泡款式, 1: 头像与挂件
    @State private var editingSide: DressingSide = .user
    @State private var pickedBubbleImageItem: PhotosPickerItem? = nil
    @State private var pendingBubbleSide: DressingSide? = nil
    @State private var bubblePickerPresented = false
    // 装饰选图器：和底图选图器共用一颗抽屉根，但各走各的 binding。
    // pendingDecorationIndex 为 nil = 新增装饰，数字 = 给第几个换图。
    @State private var pickedDecorationItem: PhotosPickerItem? = nil
    @State private var pendingDecorationSide: DressingSide? = nil
    @State private var pendingDecorationIndex: Int? = nil
    @State private var decorationPickerPresented = false

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
                .padding(DressingTokens.Padding.segment)
                .background(CSSThemeVariables.surfaceFill(scope: .settings))
                .clipShape(Capsule())
                .padding(.horizontal, DressingTokens.Padding.page)
                .padding(.vertical, DressingTokens.Padding.widePillVertical)

                ScrollView(.vertical, showsIndicators: false) {
                    if selectedTab == 0 {
                        bubbleSection
                    } else {
                        pendantAndAvatarSection
                    }
                }
                .padding(DressingTokens.Padding.sheet)
            }
            .background(AppearanceBackdrop(scope: .settings).ignoresSafeArea())
            // 单个选图器由下面气泡底图行的 Button 统一打开：Button 的
            // action 在 VoiceOver / 切换控制激活下也会触发（图标格那次
            // 的教训：TapGesture 只认真实触摸），所以点哪侧先记哪侧，
            // 再打开选图器；onChange 读到的永远是这次点的侧。
            .photosPicker(isPresented: $bubblePickerPresented, selection: $pickedBubbleImageItem, matching: .images)
            .onChange(of: pickedBubbleImageItem) { item in
                guard let item, let side = pendingBubbleSide else { return }
                pickedBubbleImageItem = nil
                Task {
                    guard let data = try? await item.loadTransferable(type: Data.self),
                          let uiImage = UIImage(data: data) else {
                        await MainActor.run {
                            onNotify(AppLocalized("气泡底图设置失败，请换一张图试试"))
                        }
                        return
                    }
                    await MainActor.run {
                        if let name = BubblePackImageStore.storeCustomImage(uiImage, user: side.isUser) {
                            setEditingBackgroundImageFile(name, user: side.isUser)
                            onNotify(AppLocalized("已设置气泡底图"))
                        } else {
                            onNotify(AppLocalized("气泡底图设置失败，请换一张图试试"))
                        }
                    }
                }
            }
            // 装饰选图器：和底图那套同款写法——Button 里先把侧和第几
            // 个记下来再开，onChange 里只认这次点的；取消（item 为 nil）
            // 或无侧直接 return，同一张图再选也照样触发。
            .photosPicker(isPresented: $decorationPickerPresented, selection: $pickedDecorationItem, matching: .images)
            .onChange(of: pickedDecorationItem) { item in
                guard let item, let side = pendingDecorationSide else { return }
                pickedDecorationItem = nil
                let index = pendingDecorationIndex
                Task {
                    guard let data = try? await item.loadTransferable(type: Data.self),
                          let uiImage = UIImage(data: data) else {
                        await MainActor.run {
                            onNotify(AppLocalized("装饰设置失败，请换一张图试试"))
                        }
                        return
                    }
                    await MainActor.run {
                        if let name = BubblePackImageStore.storeDecorationImage(uiImage) {
                            if let index {
                                replaceEditingDecorationImage(at: index, fileName: name, user: side.isUser)
                                onNotify(AppLocalized("已更换装饰图片"))
                            } else {
                                addEditingDecoration(imageFile: name, user: side.isUser)
                                onNotify(AppLocalized("已添加装饰"))
                            }
                        } else {
                            onNotify(AppLocalized("装饰设置失败，请换一张图试试"))
                        }
                    }
                }
            }
        }
    }

    private func tabPill(title: String, index: Int) -> some View {
        let isSelected = selectedTab == index
        return Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            selectedTab = index
        } label: {
            Text(title)
                .font(ChatFont.font(12, weight: isSelected ? .semibold : .regular))
                .frame(maxWidth: .infinity)
                .padding(.vertical, DressingTokens.Padding.widePillVertical)
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
                    .font(ChatFont.font(12, weight: .medium))
                    .foregroundStyle(CSSThemeVariables.textDim(scope: .settings))

                ForEach(DressingSide.allCases, id: \.self) { side in
                    let isSelected = editingSide == side
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        editingSide = side
                    } label: {
                        Text(side.displayName)
                            .font(ChatFont.font(12, weight: isSelected ? .bold : .medium))
                            .padding(.horizontal, DressingTokens.Padding.contentHorizontal)
                            .padding(.vertical, DressingTokens.Padding.pillVertical)
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
                    .font(ChatFont.font(13, weight: .bold))
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
                                .font(ChatFont.font(11, weight: isSelected ? .bold : .regular))
                                .padding(.horizontal, DressingTokens.Padding.rowHorizontal)
                                .padding(.vertical, DressingTokens.Padding.rowVertical)
                                .background(isSelected ? CSSThemeVariables.accentSoft(scope: .settings) : CSSThemeVariables.surfaceFill(scope: .settings))
                                .foregroundStyle(isSelected ? CSSThemeVariables.accent(scope: .settings) : CSSThemeVariables.textDim(scope: .settings))
                                .clipShape(Capsule())
                        }
                    }
                }

                // 圆角滑块
                HStack(spacing: 8) {
                    Text(AppLocalized("圆角半径"))
                        .font(ChatFont.font(11))
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
                        .font(ChatFont.font(11, design: .monospaced))
                        .foregroundStyle(CSSThemeVariables.textDim(scope: .settings))
                        .frame(width: 36, alignment: .trailing)
                }
            }
            .padding(DressingTokens.Padding.card)
            .background(CSSThemeVariables.card(scope: .settings).opacity(0.85))
            .clipShape(RoundedRectangle(cornerRadius: DressingTokens.Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DressingTokens.Radius.card, style: .continuous)
                    .stroke(CSSThemeVariables.divider(scope: .settings), lineWidth: 0.5)
            )

            // 气泡底纹与文字色：只写分侧字段，不碰共享字段
            // （见 AppearanceThemePack 的 per-side 注释：单侧改写共享
            // 字段会把另一侧的气泡也带走）。
            VStack(alignment: .leading, spacing: 10) {
                Text(AppLocalized("气泡底纹与文字色"))
                    .font(ChatFont.font(13, weight: .bold))
                    .foregroundStyle(CSSThemeVariables.textMain(scope: .settings))

                // 实时样例气泡：和 live 聊天同一条渲染链
                // （BubblePackSurfaceBackground + MinisThemeShape 分侧字段），
                // 改了图案 / 不透明度 / 文字色 / 底图当场就能看见。
                BubblePackSurfaceBackground(
                    shape: editingSide.isUser ? MinisThemeShape.userBubble : MinisThemeShape.assistantBubble,
                    colour: editingSide.isUser ? ChatColors.userBubble : ChatColors.assistantBubble,
                    imageFile: MinisThemeShape.packBackgroundImageFile(user: editingSide.isUser),
                    pattern: editingPattern,
                    patternOpacity: editingPatternOpacity,
                    textColour: editingTextColor
                )
                .overlay(alignment: .leading) {
                    Text(AppLocalized("这是一条示例消息"))
                        .font(ChatFont.font(13))
                        .foregroundStyle(editingTextColor)
                        .padding(.horizontal, DressingTokens.Padding.contentHorizontal)
                        .padding(.vertical, DressingTokens.Padding.cardVertical)
                }
                // 装饰就盖在气泡上（和 live 聊天同一层：BubblePackDecorationsView
                // 盖在气泡容器外，角标能探出气泡轮廓），改了当场就能看见。
                .overlay {
                    BubblePackDecorationsView(decorations: MinisThemeShape.packDecorations(user: editingSide.isUser))
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // 图案选择
                HStack(spacing: 6) {
                    Text(AppLocalized("图案"))
                        .font(ChatFont.font(11))
                        .foregroundStyle(CSSThemeVariables.textDim(scope: .settings))
                        .frame(width: 72, alignment: .leading)

                    ForEach(BubblePattern.allCases, id: \.self) { pattern in
                        let isSelected = editingPattern == pattern
                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            setEditingPattern(pattern)
                        } label: {
                            Text(pattern.title)
                                .font(ChatFont.font(11, weight: isSelected ? .bold : .regular))
                                .padding(.horizontal, DressingTokens.Padding.rowHorizontal)
                                .padding(.vertical, DressingTokens.Padding.rowVertical)
                                .background(isSelected ? CSSThemeVariables.accentSoft(scope: .settings) : CSSThemeVariables.surfaceFill(scope: .settings))
                                .foregroundStyle(isSelected ? CSSThemeVariables.accent(scope: .settings) : CSSThemeVariables.textDim(scope: .settings))
                                .clipShape(Capsule())
                        }
                    }
                }

                // 图案不透明度（0...0.6，和 BubbleStyleRecord 的夹值一致；
                // 没选图案时滑不动，值留着等选了图案再起效）
                HStack(spacing: 8) {
                    Text(AppLocalized("图案不透明度"))
                        .font(ChatFont.font(11))
                        .foregroundStyle(CSSThemeVariables.textDim(scope: .settings))
                        .frame(width: 72, alignment: .leading)

                    Slider(
                        value: Binding(
                            get: { editingPatternOpacity },
                            set: { setEditingPatternOpacity($0) }
                        ),
                        in: 0...0.6
                    )
                    .tint(CSSThemeVariables.accent(scope: .settings))

                    Text("\(Int(editingPatternOpacity * 100))%")
                        .font(ChatFont.font(11, design: .monospaced))
                        .foregroundStyle(CSSThemeVariables.textDim(scope: .settings))
                        .frame(width: 36, alignment: .trailing)
                }
                .disabled(editingPattern == .none)
                .opacity(editingPattern == .none ? 0.5 : 1)

                // 气泡文字色（nil = 跟随主题色）
                HStack(spacing: 8) {
                    Text(AppLocalized("气泡文字色"))
                        .font(ChatFont.font(11))
                        .foregroundStyle(CSSThemeVariables.textDim(scope: .settings))
                        .frame(width: 72, alignment: .leading)

                    Text(editingTextHex.map { "#" + $0 } ?? AppLocalized("跟随主题"))
                        .font(ChatFont.font(11, design: .monospaced))
                        .foregroundStyle(CSSThemeVariables.textDim(scope: .settings))

                    Spacer()

                    ColorPicker("", selection: Binding(
                        get: { editingTextColor },
                        set: { newColor in
                            let pickedHex = BubbleStyleRecord.normalizedPackHex(UIColor(newColor).hexRGB)
                            // 点的就是主题槽自己的色：别把它写回成自定义，
                            // 否则行里会从「跟随主题」变成一串相同的 hex。
                            // 主题色走的正是 ColorPicker 显示的同一条回退
                            // （ChatColors.bubbleText / assistantBubbleText
                            // 里 studio.color 那半），所以比的和看到的
                            // 是同一个值，不会跑偏。
                            let themeHex = BubbleStyleRecord.normalizedPackHex(UIColor(editingSide.isUser
                                ? studio.color(.bubbleText, scope: ThemeColorLayer.chat)
                                : studio.color(.assistantBubbleText, scope: ThemeColorLayer.chat)).hexRGB)
                            setEditingTextHex(pickedHex == themeHex ? nil : pickedHex)
                        }
                    ))
                    .labelsHidden()
                    .scaleEffect(0.9)

                    if editingTextHex != nil {
                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            setEditingTextHex(nil)
                            onNotify(AppLocalized("已恢复默认文字色"))
                        } label: {
                            Image(systemName: "arrow.uturn.backward")
                                .font(.system(size: 11))
                                .foregroundStyle(CSSThemeVariables.textDim(scope: .settings))
                                .padding(DressingTokens.Padding.tiny)
                                .background(CSSThemeVariables.surfaceFill(scope: .settings))
                                .clipShape(Circle())
                        }
                        .accessibilityLabel(AppLocalized("重置"))
                    }
                }

                // 气泡底图（分侧自定义图：只写分侧字段。nil = 没有底图。
                // 和款式库的图不一样：款式库的图是 pack 记录里带来的，
                // 这里存的是这侧自己挑的图，文件名固定为一侧一个。）
                HStack(spacing: 8) {
                    Text(AppLocalized("气泡底图"))
                        .font(ChatFont.font(11))
                        .foregroundStyle(CSSThemeVariables.textDim(scope: .settings))
                        .frame(width: 72, alignment: .leading)

                    Text(editingBackgroundImageFile == nil ? AppLocalized("未设置") : AppLocalized("已设置"))
                        .font(ChatFont.font(11))
                        .foregroundStyle(CSSThemeVariables.textDim(scope: .settings))

                    Spacer()

                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        pendingBubbleSide = editingSide
                        bubblePickerPresented = true
                    } label: {
                        Text(AppLocalized("选择图片"))
                            .font(ChatFont.font(11, weight: .medium))
                            .padding(.horizontal, DressingTokens.Padding.rowHorizontal)
                            .padding(.vertical, DressingTokens.Padding.rowVertical)
                            .background(CSSThemeVariables.surfaceFill(scope: .settings))
                            .foregroundStyle(CSSThemeVariables.textMain(scope: .settings))
                            .clipShape(Capsule())
                    }
                    .accessibilityLabel(AppLocalized("选择图片"))

                    if editingBackgroundImageFile != nil {
                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            removeEditingBackgroundImage()
                            onNotify(AppLocalized("已移除气泡底图"))
                        } label: {
                            Image(systemName: "arrow.uturn.backward")
                                .font(.system(size: 11))
                                .foregroundStyle(CSSThemeVariables.textDim(scope: .settings))
                                .padding(DressingTokens.Padding.tiny)
                                .background(CSSThemeVariables.surfaceFill(scope: .settings))
                                .clipShape(Circle())
                        }
                        .accessibilityLabel(AppLocalized("重置"))
                    }
                }

                // 气泡装饰（分侧列表：每条一个角标图 + 锚点 + 大小 + 偏移。
                // 只写分侧 JSON 字段；图文件走 BubblePackImageStore 的
                // decoration- 唯一名，移除时只删编辑器自己存的图。）
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text(AppLocalized("气泡装饰"))
                            .font(ChatFont.font(11))
                            .foregroundStyle(CSSThemeVariables.textDim(scope: .settings))
                            .frame(width: 72, alignment: .leading)

                        Spacer()

                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            pendingDecorationSide = editingSide
                            pendingDecorationIndex = nil
                            decorationPickerPresented = true
                        } label: {
                            Text(AppLocalized("添加装饰"))
                                .font(ChatFont.font(11, weight: .medium))
                                .padding(.horizontal, DressingTokens.Padding.rowHorizontal)
                                .padding(.vertical, DressingTokens.Padding.rowVertical)
                                .background(CSSThemeVariables.surfaceFill(scope: .settings))
                                .foregroundStyle(CSSThemeVariables.textMain(scope: .settings))
                                .clipShape(Capsule())
                        }
                        .accessibilityLabel(AppLocalized("添加装饰"))
                    }

                    if editingDecorations.isEmpty {
                        Text(AppLocalized("暂无装饰"))
                            .font(ChatFont.font(11))
                            .foregroundStyle(CSSThemeVariables.textDim(scope: .settings))
                    }

                    ForEach(Array(editingDecorations.enumerated()), id: \.offset) { index, decoration in
                        VStack(alignment: .leading, spacing: 8) {
                            // 标题行：缩略图 + 装饰 N + 换图 + 移除
                            HStack(spacing: 8) {
                                if let thumb = BubblePackImageStore.image(fileName: decoration.imageFile) {
                                    Image(uiImage: thumb)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 28, height: 28)
                                        .clipShape(RoundedRectangle(cornerRadius: DressingTokens.Radius.thumbnail, style: .continuous))
                                } else {
                                    RoundedRectangle(cornerRadius: DressingTokens.Radius.thumbnail, style: .continuous)
                                        .fill(CSSThemeVariables.surfaceFill(scope: .settings))
                                        .frame(width: 28, height: 28)
                                }

                                Text(AppLocalized("装饰") + " \(index + 1)")
                                    .font(ChatFont.font(11, weight: .medium))
                                    .foregroundStyle(CSSThemeVariables.textMain(scope: .settings))

                                Spacer()

                                Button {
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                    pendingDecorationSide = editingSide
                                    pendingDecorationIndex = index
                                    decorationPickerPresented = true
                                } label: {
                                    Text(AppLocalized("换图"))
                                        .font(ChatFont.font(11, weight: .medium))
                                        .padding(.horizontal, DressingTokens.Padding.rowHorizontal)
                                        .padding(.vertical, DressingTokens.Padding.rowVertical)
                                        .background(CSSThemeVariables.surfaceFill(scope: .settings))
                                        .foregroundStyle(CSSThemeVariables.textMain(scope: .settings))
                                        .clipShape(Capsule())
                                }
                                .accessibilityLabel(AppLocalized("换图"))

                                Button {
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                    removeEditingDecoration(at: index, user: editingSide.isUser)
                                    onNotify(AppLocalized("已移除装饰"))
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.system(size: 11))
                                        .foregroundStyle(CSSThemeVariables.textDim(scope: .settings))
                                        .padding(DressingTokens.Padding.tiny)
                                        .background(CSSThemeVariables.surfaceFill(scope: .settings))
                                        .clipShape(Circle())
                                }
                                .accessibilityLabel(AppLocalized("移除"))
                            }

                            // 锚点（四个角）
                            HStack(spacing: 6) {
                                Text(AppLocalized("位置"))
                                    .font(ChatFont.font(11))
                                    .foregroundStyle(CSSThemeVariables.textDim(scope: .settings))
                                    .frame(width: 72, alignment: .leading)

                                ForEach(BubbleDecorationAnchor.allCases, id: \.self) { anchor in
                                    let isSelected = decoration.anchor == anchor
                                    Button {
                                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                        updateEditingDecoration(at: index, user: editingSide.isUser) { $0.anchor = anchor }
                                    } label: {
                                        Text(anchor.title)
                                            .font(ChatFont.font(11, weight: isSelected ? .bold : .regular))
                                            .padding(.horizontal, DressingTokens.Padding.rowHorizontal)
                                            .padding(.vertical, DressingTokens.Padding.rowVertical)
                                            .background(isSelected ? CSSThemeVariables.accentSoft(scope: .settings) : CSSThemeVariables.surfaceFill(scope: .settings))
                                            .foregroundStyle(isSelected ? CSSThemeVariables.accent(scope: .settings) : CSSThemeVariables.textDim(scope: .settings))
                                            .clipShape(Capsule())
                                    }
                                }
                            }

                            // 大小（12...64，和 BubbleDecoration 的夹值一致）
                            HStack(spacing: 8) {
                                Text(AppLocalized("大小"))
                                    .font(ChatFont.font(11))
                                    .foregroundStyle(CSSThemeVariables.textDim(scope: .settings))
                                    .frame(width: 72, alignment: .leading)

                                Slider(
                                    value: Binding(
                                        get: { decoration.size },
                                        set: { newValue in
                                            updateEditingDecoration(at: index, user: editingSide.isUser) { $0.size = newValue }
                                        }
                                    ),
                                    in: 12...64
                                )
                                .tint(CSSThemeVariables.accent(scope: .settings))

                                Text("\(Int(decoration.size))")
                                    .font(ChatFont.font(11, design: .monospaced))
                                    .foregroundStyle(CSSThemeVariables.textDim(scope: .settings))
                                    .frame(width: 24, alignment: .trailing)
                            }

                            // 横向偏移（-40...40，和 BubbleDecoration 的夹值一致）
                            HStack(spacing: 8) {
                                Text(AppLocalized("横向偏移"))
                                    .font(ChatFont.font(11))
                                    .foregroundStyle(CSSThemeVariables.textDim(scope: .settings))
                                    .frame(width: 72, alignment: .leading)

                                Slider(
                                    value: Binding(
                                        get: { decoration.offsetX },
                                        set: { newValue in
                                            updateEditingDecoration(at: index, user: editingSide.isUser) { $0.offsetX = newValue }
                                        }
                                    ),
                                    in: -40...40
                                )
                                .tint(CSSThemeVariables.accent(scope: .settings))

                                Text("\(Int(decoration.offsetX))")
                                    .font(ChatFont.font(11, design: .monospaced))
                                    .foregroundStyle(CSSThemeVariables.textDim(scope: .settings))
                                    .frame(width: 28, alignment: .trailing)
                            }

                            // 纵向偏移（-40...40）
                            HStack(spacing: 8) {
                                Text(AppLocalized("纵向偏移"))
                                    .font(ChatFont.font(11))
                                    .foregroundStyle(CSSThemeVariables.textDim(scope: .settings))
                                    .frame(width: 72, alignment: .leading)

                                Slider(
                                    value: Binding(
                                        get: { decoration.offsetY },
                                        set: { newValue in
                                            updateEditingDecoration(at: index, user: editingSide.isUser) { $0.offsetY = newValue }
                                        }
                                    ),
                                    in: -40...40
                                )
                                .tint(CSSThemeVariables.accent(scope: .settings))

                                Text("\(Int(decoration.offsetY))")
                                    .font(ChatFont.font(11, design: .monospaced))
                                    .foregroundStyle(CSSThemeVariables.textDim(scope: .settings))
                                    .frame(width: 28, alignment: .trailing)
                            }
                        }
                        .padding(DressingTokens.Padding.inner)
                        .background(CSSThemeVariables.surfaceFill(scope: .settings).opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: DressingTokens.Radius.chip, style: .continuous))
                    }
                }
            }
            .padding(DressingTokens.Padding.card)
            .background(CSSThemeVariables.card(scope: .settings).opacity(0.85))
            .clipShape(RoundedRectangle(cornerRadius: DressingTokens.Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DressingTokens.Radius.card, style: .continuous)
                    .stroke(CSSThemeVariables.divider(scope: .settings), lineWidth: 0.5)
            )

            // 预设款式列表
            VStack(alignment: .leading, spacing: 8) {
                Text(AppLocalized("预设气泡款式库"))
                    .font(ChatFont.font(13, weight: .bold))
                    .foregroundStyle(CSSThemeVariables.textMain(scope: .settings))

                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(bubbleStore.packs) { pack in
                        bubblePackCard(pack)
                    }
                }
            }
        }
    }

    // MARK: - 气泡底纹与文字色（分侧字段读写，绝不碰共享字段）

    /// 当前调节侧的图案：只读分侧字段 userBubblePattern /
    /// assistantBubblePattern，绝不读共享 bubblePattern
    /// （live 读的也是分侧字段，见 MinisThemeShape.packPattern）。
    private var editingPattern: BubblePattern {
        BubblePattern.parse(editingSide.isUser
            ? studio.currentThemePack().userBubblePattern
            : studio.currentThemePack().assistantBubblePattern)
    }

    private func setEditingPattern(_ pattern: BubblePattern) {
        var pack = studio.currentThemePack()
        if editingSide.isUser {
            pack.userBubblePattern = pattern.rawValue
        } else {
            pack.assistantBubblePattern = pattern.rawValue
        }
        studio.persistPack(pack)
    }

    private var editingPatternOpacity: Double {
        editingSide.isUser
            ? studio.currentThemePack().userBubblePatternOpacity
            : studio.currentThemePack().assistantBubblePatternOpacity
    }

    private func setEditingPatternOpacity(_ value: Double) {
        var pack = studio.currentThemePack()
        let clamped = min(0.6, max(0, value))
        if editingSide.isUser {
            pack.userBubblePatternOpacity = clamped
        } else {
            pack.assistantBubblePatternOpacity = clamped
        }
        studio.persistPack(pack)
    }

    /// 当前调节侧的文字色 hex：nil = 跟随主题色。
    private var editingTextHex: String? {
        editingSide.isUser
            ? studio.currentThemePack().userBubblePackTextHex
            : studio.currentThemePack().assistantBubblePackTextHex
    }

    private func setEditingTextHex(_ hex: String?) {
        var pack = studio.currentThemePack()
        if editingSide.isUser {
            pack.userBubblePackTextHex = hex
        } else {
            pack.assistantBubblePackTextHex = hex
        }
        studio.persistPack(pack)
    }

    /// 当前调节侧的底图文件名：nil = 没有底图。
    private var editingBackgroundImageFile: String? {
        editingSide.isUser
            ? studio.currentThemePack().userBubbleBackgroundImageFile
            : studio.currentThemePack().assistantBubbleBackgroundImageFile
    }

    private func setEditingBackgroundImageFile(_ fileName: String?, user: Bool) {
        var pack = studio.currentThemePack()
        if user {
            pack.userBubbleBackgroundImageFile = fileName
        } else {
            pack.assistantBubbleBackgroundImageFile = fileName
        }
        studio.persistPack(pack)
    }

    /// 移除当前侧的底图：只有这侧自己挑的自定义图才删文件，
    /// 款式库带进来的图可能多处共用，只清字段、不删文件。
    private func removeEditingBackgroundImage() {
        if BubblePackImageStore.isCustomFileName(editingBackgroundImageFile, user: editingSide.isUser) {
            BubblePackImageStore.removeCustomImage(user: editingSide.isUser)
        }
        setEditingBackgroundImageFile(nil, user: editingSide.isUser)
    }

    /// 当前调节侧的装饰列表（分侧 JSON 字段解码），空 = []。
    private var editingDecorations: [BubbleDecoration] {
        decorations(for: editingSide.isUser)
    }

    /// 读一侧的装饰列表（分侧 JSON 字段解码），空 = []。
    private func decorations(for user: Bool) -> [BubbleDecoration] {
        BubbleStyleRecord.decodeDecorations(user
            ? studio.currentThemePack().userBubbleDecorationsJSON
            : studio.currentThemePack().assistantBubbleDecorationsJSON)
    }

    /// 写回一侧的装饰列表（JSON 编码后进分侧字段，再 persistPack，
    /// 样例气泡和 live 聊天都读同一字段，当场刷新）。
    private func setEditingDecorations(_ decorations: [BubbleDecoration], user: Bool) {
        var pack = studio.currentThemePack()
        let json = BubbleStyleRecord.encodeDecorations(decorations)
        if user {
            pack.userBubbleDecorationsJSON = json
        } else {
            pack.assistantBubbleDecorationsJSON = json
        }
        studio.persistPack(pack)
    }

    /// 新增一个装饰：图刚存好，锚点默认右上、大小 28、偏移 0
    ///（BubbleDecoration 的默认值）。
    private func addEditingDecoration(imageFile: String, user: Bool) {
        var decorations = decorations(for: user)
        decorations.append(BubbleDecoration(imageFile: imageFile))
        setEditingDecorations(decorations, user: user)
    }

    /// 给第几个装饰换图：旧图是编辑器自己存的才删文件
    /// （款式库带进来的图可能多处共用，绝不删），再写新文件名。
    private func replaceEditingDecorationImage(at index: Int, fileName: String, user: Bool) {
        var decorations = decorations(for: user)
        guard decorations.indices.contains(index) else { return }
        BubblePackImageStore.removeDecorationImage(fileName: decorations[index].imageFile)
        decorations[index].imageFile = fileName
        setEditingDecorations(decorations, user: user)
    }

    /// 移除第几个装饰：列表里删掉，图文件是编辑器自己存的才删。
    private func removeEditingDecoration(at index: Int, user: Bool) {
        var decorations = decorations(for: user)
        guard decorations.indices.contains(index) else { return }
        BubblePackImageStore.removeDecorationImage(fileName: decorations[index].imageFile)
        decorations.remove(at: index)
        setEditingDecorations(decorations, user: user)
    }

    /// 改第几个装饰的锚点 / 大小 / 偏移：改完用 init 重建一次，
    /// 让大小 12...64、偏移 -40...40 的夹值真正跑起来
    ///（原地赋值不经过 init，不重建就夹不到）。
    private func updateEditingDecoration(at index: Int, user: Bool, _ change: (inout BubbleDecoration) -> Void) {
        var decorations = decorations(for: user)
        guard decorations.indices.contains(index) else { return }
        change(&decorations[index])
        let changed = decorations[index]
        decorations[index] = BubbleDecoration(imageFile: changed.imageFile, anchor: changed.anchor, size: changed.size, offsetX: changed.offsetX, offsetY: changed.offsetY)
        setEditingDecorations(decorations, user: user)
    }

    /// 当前调节侧实际生效的文字色（包里有就用包的，没有就跟主题），
    /// 和 live 聊天的 ChatColors.bubbleText / assistantBubbleText 同款。
    private var editingTextColor: Color {
        editingSide.isUser ? ChatColors.bubbleText : ChatColors.assistantBubbleText
    }

    private func bubblePackCard(_ pack: BubbleStylePack) -> some View {
        let isApplied = bubbleStore.appliedNumber(for: editingSide) == pack.number

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(pack.title)
                    .font(ChatFont.font(13, weight: .bold))
                    .foregroundStyle(CSSThemeVariables.textMain(scope: .settings))

                Spacer()

                if isApplied {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(CSSThemeVariables.accent(scope: .settings))
                }
            }

            Text(pack.number)
                .font(ChatFont.font(10, design: .monospaced))
                .foregroundStyle(CSSThemeVariables.textDim(scope: .settings))

            HStack(spacing: 6) {
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    bubbleStore.apply(pack, for: editingSide)
                    onNotify(AppLocalized("已给 \(editingSide.displayName) 换上 \(pack.title)"))
                } label: {
                    Text(AppLocalized("换上"))
                        .font(ChatFont.font(10, weight: .semibold))
                        .padding(.horizontal, DressingTokens.Padding.rowHorizontal)
                        .padding(.vertical, DressingTokens.Padding.rowVertical)
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
                        .font(ChatFont.font(10))
                        .foregroundStyle(CSSThemeVariables.textDim(scope: .settings))
                }
            }
        }
        .padding(DressingTokens.Padding.card)
        .background(CSSThemeVariables.card(scope: .settings).opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: DressingTokens.Radius.innerCard, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DressingTokens.Radius.innerCard, style: .continuous)
                .stroke(isApplied ? CSSThemeVariables.accent(scope: .settings) : CSSThemeVariables.divider(scope: .settings), lineWidth: isApplied ? 1 : 0.5)
        )
    }

    // 头像与挂件部分
    private var pendantAndAvatarSection: some View {
        VStack(spacing: 16) {
            // 头像轮廓与大小
            VStack(alignment: .leading, spacing: 10) {
                Text(AppLocalized("头像形状与尺寸"))
                    .font(ChatFont.font(13, weight: .bold))
                    .foregroundStyle(CSSThemeVariables.textMain(scope: .settings))

                HStack(spacing: 6) {
                    ForEach(AppearanceAvatarShape.allCases) { shape in
                        let isSelected = studio.currentThemePack().avatarShape == shape.rawValue
                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            studio.setAvatarShape(shape)
                        } label: {
                            Text(shape.title)
                                .font(ChatFont.font(12, weight: isSelected ? .bold : .regular))
                                .padding(.horizontal, DressingTokens.Padding.pillHorizontal)
                                .padding(.vertical, DressingTokens.Padding.pillVertical)
                                .background(isSelected ? CSSThemeVariables.accent(scope: .settings) : CSSThemeVariables.surfaceFill(scope: .settings))
                                .foregroundStyle(isSelected ? CSSThemeVariables.card(scope: .settings) : CSSThemeVariables.textMain(scope: .settings))
                                .clipShape(Capsule())
                        }
                    }
                }

                HStack(spacing: 8) {
                    Text(AppLocalized("头像大小"))
                        .font(ChatFont.font(11))
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
                        .font(ChatFont.font(11, design: .monospaced))
                        .foregroundStyle(CSSThemeVariables.textDim(scope: .settings))
                        .frame(width: 36, alignment: .trailing)
                }
            }
            .padding(DressingTokens.Padding.card)
            .background(CSSThemeVariables.card(scope: .settings).opacity(0.85))
            .clipShape(RoundedRectangle(cornerRadius: DressingTokens.Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DressingTokens.Radius.card, style: .continuous)
                    .stroke(CSSThemeVariables.divider(scope: .settings), lineWidth: 0.5)
            )

            // 头像发光圆环挂件
            VStack(alignment: .leading, spacing: 8) {
                Text(AppLocalized("发光柔光圆环挂件"))
                    .font(ChatFont.font(13, weight: .bold))
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
                        .font(ChatFont.font(12, weight: .bold))
                        .foregroundStyle(CSSThemeVariables.textMain(scope: .settings))

                    Text(pendant.number)
                        .font(ChatFont.font(10, design: .monospaced))
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
                        .font(ChatFont.font(10, weight: .medium))
                        .padding(.horizontal, DressingTokens.Padding.itemPillHorizontal)
                        .padding(.vertical, DressingTokens.Padding.smallPillVertical)
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
                        .font(ChatFont.font(10, weight: .medium))
                        .padding(.horizontal, DressingTokens.Padding.itemPillHorizontal)
                        .padding(.vertical, DressingTokens.Padding.smallPillVertical)
                        .background(isAIWearing ? CSSThemeVariables.accent(scope: .settings) : CSSThemeVariables.surfaceFill(scope: .settings))
                        .foregroundStyle(isAIWearing ? CSSThemeVariables.card(scope: .settings) : CSSThemeVariables.textDim(scope: .settings))
                        .clipShape(Capsule())
                }
            }
        }
        .padding(DressingTokens.Padding.innerCard)
        .background(CSSThemeVariables.card(scope: .settings).opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: DressingTokens.Radius.innerCard, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DressingTokens.Radius.innerCard, style: .continuous)
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
    @ObservedObject private var fontSettings = FontSettings.shared
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
                    .padding(DressingTokens.Padding.sheet)
                }
            }
            .background(AppearanceBackdrop(scope: .settings).ignoresSafeArea())
            .sheet(isPresented: $showFontPicker) {
                FontFilePicker(
                    onPick: { url in
                        showFontPicker = false
                        switch fontStore.importFont(from: url) {
                        case .success(let font):
                            onNotify(AppLocalized("成功导入字体：") + font.title)
                        case .failure(let error):
                            onNotify(error.userMessage)
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
                .font(ChatFont.font(13, weight: .bold))
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
                            .font(ChatFont.font(12, weight: isSelected ? .bold : .medium, design: family.design))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, DressingTokens.Padding.capsuleButtonVertical)
                            .background(isSelected ? CSSThemeVariables.accent(scope: .settings) : CSSThemeVariables.surfaceFill(scope: .settings))
                            .foregroundStyle(isSelected ? CSSThemeVariables.card(scope: .settings) : CSSThemeVariables.textMain(scope: .settings))
                            .clipShape(Capsule())
                    }
                }
            }
        }
        .padding(DressingTokens.Padding.card)
        .background(CSSThemeVariables.card(scope: .settings).opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: DressingTokens.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DressingTokens.Radius.card, style: .continuous)
                .stroke(CSSThemeVariables.divider(scope: .settings), lineWidth: 0.5)
        )
    }

    private var customFontSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(AppLocalized("自定义导入字体 (.ttf / .otf)"))
                    .font(ChatFont.font(13, weight: .bold))
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
                            .font(ChatFont.font(11, weight: .semibold))
                    }
                    .padding(.horizontal, DressingTokens.Padding.rowHorizontal)
                    .padding(.vertical, DressingTokens.Padding.rowVertical)
                    .background(CSSThemeVariables.accentSoft(scope: .settings))
                    .foregroundStyle(CSSThemeVariables.accent(scope: .settings))
                    .clipShape(Capsule())
                }
            }

            if fontStore.fonts.isEmpty {
                Text(AppLocalized("暂无已导入的自定义字体"))
                    .font(ChatFont.font(11))
                    .foregroundStyle(CSSThemeVariables.textDim(scope: .settings))
                    .padding(.vertical, DressingTokens.Padding.rowVertical)
            } else {
                VStack(spacing: 6) {
                    ForEach(fontStore.fonts) { font in
                        let isApplied = MinisThemeShape.globalCustomFontName == font.postScriptName
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(font.title)
                                    .font(ChatFont.font(12, weight: .medium))
                                    .foregroundStyle(CSSThemeVariables.textMain(scope: .settings))
                                Text(font.postScriptName)
                                    .font(ChatFont.font(10, design: .monospaced))
                                    .foregroundStyle(CSSThemeVariables.textDim(scope: .settings))
                            }

                            Spacer()

                            Button {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                studio.setGlobalCustomFont(isApplied ? nil : font.postScriptName)
                                onNotify(isApplied ? AppLocalized("已停用自定义字体") : AppLocalized("已应用自定义字体"))
                            } label: {
                                Text(isApplied ? AppLocalized("使用中") : AppLocalized("应用"))
                                    .font(ChatFont.font(10, weight: .semibold))
                                    .padding(.horizontal, DressingTokens.Padding.rowHorizontal)
                                    .padding(.vertical, DressingTokens.Padding.rowVertical)
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
                                    .padding(DressingTokens.Padding.tapTarget)
                            }
                        }
                        .padding(DressingTokens.Padding.inner)
                        .background(CSSThemeVariables.surfaceFill(scope: .settings).opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: DressingTokens.Radius.chip, style: .continuous))
                    }
                }
            }
        }
        .padding(DressingTokens.Padding.card)
        .background(CSSThemeVariables.card(scope: .settings).opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: DressingTokens.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DressingTokens.Radius.card, style: .continuous)
                .stroke(CSSThemeVariables.divider(scope: .settings), lineWidth: 0.5)
        )
    }

    private var typographySlidersSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(AppLocalized("字体大小与留白"))
                .font(ChatFont.font(13, weight: .bold))
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
        .padding(DressingTokens.Padding.card)
        .background(CSSThemeVariables.card(scope: .settings).opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: DressingTokens.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DressingTokens.Radius.card, style: .continuous)
                .stroke(CSSThemeVariables.divider(scope: .settings), lineWidth: 0.5)
        )
    }

    private func sliderRow(title: String, value: Binding<Double>, range: ClosedRange<Double>, unit: String, isDecimal: Bool = false) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(ChatFont.font(11))
                .foregroundStyle(CSSThemeVariables.textDim(scope: .settings))
                .frame(width: 95, alignment: .leading)

            Slider(value: value, in: range)
                .tint(CSSThemeVariables.accent(scope: .settings))

            Text(isDecimal ? String(format: "%.2f %@", value.wrappedValue, unit) : "\(Int(value.wrappedValue)) \(unit)")
                .font(ChatFont.font(11, design: .monospaced))
                .foregroundStyle(CSSThemeVariables.textDim(scope: .settings))
                .frame(width: 55, alignment: .trailing)
        }
    }

    private var readingModesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(AppLocalized("沉浸阅读与消息形态"))
                .font(ChatFont.font(13, weight: .bold))
                .foregroundStyle(CSSThemeVariables.textMain(scope: .settings))

            VStack(alignment: .leading, spacing: 4) {
                Text(AppLocalized("视觉小说模式"))
                    .font(ChatFont.font(11))
                    .foregroundStyle(CSSThemeVariables.textDim(scope: .settings))

                HStack(spacing: 6) {
                    ForEach(AppearanceNovelMode.allCases) { mode in
                        let isSelected = studio.currentThemePack().novelMode == mode.rawValue
                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            studio.setNovelMode(mode)
                        } label: {
                            Text(mode.title)
                                .font(ChatFont.font(11, weight: isSelected ? .bold : .medium))
                                .padding(.horizontal, DressingTokens.Padding.pillHorizontal)
                                .padding(.vertical, DressingTokens.Padding.pillVertical)
                                .background(isSelected ? CSSThemeVariables.accent(scope: .settings) : CSSThemeVariables.surfaceFill(scope: .settings))
                                .foregroundStyle(isSelected ? CSSThemeVariables.card(scope: .settings) : CSSThemeVariables.textMain(scope: .settings))
                                .clipShape(Capsule())
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(AppLocalized("消息气泡排布"))
                    .font(ChatFont.font(11))
                    .foregroundStyle(CSSThemeVariables.textDim(scope: .settings))

                HStack(spacing: 6) {
                    ForEach(AppearanceChatDisplay.allCases) { disp in
                        let isSelected = studio.currentThemePack().chatDisplay == disp.rawValue
                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            studio.setChatDisplay(disp)
                        } label: {
                            Text(disp.title)
                                .font(ChatFont.font(11, weight: isSelected ? .bold : .medium))
                                .padding(.horizontal, DressingTokens.Padding.pillHorizontal)
                                .padding(.vertical, DressingTokens.Padding.pillVertical)
                                .background(isSelected ? CSSThemeVariables.accent(scope: .settings) : CSSThemeVariables.surfaceFill(scope: .settings))
                                .foregroundStyle(isSelected ? CSSThemeVariables.card(scope: .settings) : CSSThemeVariables.textMain(scope: .settings))
                                .clipShape(Capsule())
                        }
                    }
                }
            }
        }
        .padding(DressingTokens.Padding.card)
        .background(CSSThemeVariables.card(scope: .settings).opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: DressingTokens.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DressingTokens.Radius.card, style: .continuous)
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
    @ObservedObject private var fontSettings = FontSettings.shared
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
                                .font(ChatFont.font(12, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, DressingTokens.Padding.contentVertical)
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
                                .font(ChatFont.font(12, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, DressingTokens.Padding.contentVertical)
                        .background(CSSThemeVariables.surfaceFill(scope: .settings))
                        .foregroundStyle(CSSThemeVariables.textMain(scope: .settings))
                        .clipShape(Capsule())
                    }
                }
                .padding(.horizontal, DressingTokens.Padding.page)
                .padding(.vertical, DressingTokens.Padding.contentVertical)

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(AppLocalized("我的已存主题 (\(studio.savedThemes().count))"))
                            .font(ChatFont.font(13, weight: .bold))
                            .foregroundStyle(CSSThemeVariables.textMain(scope: .settings))

                        if studio.savedThemes().isEmpty {
                            Text(AppLocalized("还没有保存任何主题，点击上方“保存当前主题”即可存入"))
                                .font(ChatFont.font(11))
                                .foregroundStyle(CSSThemeVariables.textDim(scope: .settings))
                                .padding(.vertical, DressingTokens.Padding.sectionVertical)
                        } else {
                            ForEach(studio.savedThemes()) { theme in
                                savedThemeCard(theme)
                            }
                        }
                    }
                    .padding(DressingTokens.Padding.sheet)
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
                    .font(ChatFont.font(14, weight: .bold))
                    .foregroundStyle(CSSThemeVariables.textMain(scope: .settings))

                Text(theme.savedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(ChatFont.font(10))
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
                    .font(ChatFont.font(11, weight: .semibold))
                    .padding(.horizontal, DressingTokens.Padding.pillHorizontal)
                    .padding(.vertical, DressingTokens.Padding.pillVertical)
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
                    .padding(DressingTokens.Padding.tiny)
            }
        }
        .padding(DressingTokens.Padding.card)
        .background(CSSThemeVariables.card(scope: .settings).opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: DressingTokens.Radius.innerCard, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DressingTokens.Radius.innerCard, style: .continuous)
                .stroke(CSSThemeVariables.divider(scope: .settings), lineWidth: 0.5)
        )
    }
}

// MARK: - 7. 细节与图标抽屉 (DressingDetailsIconsSheet)

@MainActor
struct DressingDetailsIconsSheet: View {
    let onNotify: (String) -> Void
    @ObservedObject private var studio = AppearanceStudio.shared
    @ObservedObject private var fontSettings = FontSettings.shared
    @State private var expandedCategoryKey: String?
    @State private var pickedIconItem: PhotosPickerItem? = nil
    @State private var pendingIconSlotId: String? = nil
    @State private var iconPickerPresented = false

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

                        // 标签符号
                        categorySymbolsSection
                    }
                    .padding(DressingTokens.Padding.sheet)
                }
            }
            .background(AppearanceBackdrop(scope: .settings).ignoresSafeArea())
            // 单个选图器由下面各格的 Button 统一打开：Button 的 action 在
            // VoiceOver / 切换控制激活下也会触发（TapGesture 只认真实触摸，
            // 以前那路 VoiceOver 选图会丢格、甚至贴错格），所以点哪格先记哪格，
            // 再打开选图器；onChange 读到的永远是这次点的格。
            .photosPicker(isPresented: $iconPickerPresented, selection: $pickedIconItem, matching: .images)
            .onChange(of: pickedIconItem) { item in
                guard let item, let slotId = pendingIconSlotId else { return }
                pickedIconItem = nil
                Task {
                    guard let data = try? await item.loadTransferable(type: Data.self),
                          let uiImage = UIImage(data: data) else {
                        await MainActor.run {
                            onNotify(AppLocalized("图标设置失败，请换一张图试试"))
                        }
                        return
                    }
                    await MainActor.run {
                        if studio.setIcon(uiImage, for: slotId) {
                            onNotify(AppLocalized("已设置图标"))
                        } else {
                            onNotify(AppLocalized("图标设置失败，请换一张图试试"))
                        }
                    }
                }
            }
        }
    }

    private var codeBlockSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(AppLocalized("代码块折叠设置"))
                .font(ChatFont.font(13, weight: .bold))
                .foregroundStyle(CSSThemeVariables.textMain(scope: .settings))

            HStack(spacing: 8) {
                Text(AppLocalized("自动折叠行数"))
                    .font(ChatFont.font(11))
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
                    .font(ChatFont.font(11, design: .monospaced))
                    .foregroundStyle(CSSThemeVariables.textDim(scope: .settings))
                    .frame(width: 45, alignment: .trailing)
            }
        }
        .padding(DressingTokens.Padding.card)
        .background(CSSThemeVariables.card(scope: .settings).opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: DressingTokens.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DressingTokens.Radius.card, style: .continuous)
                .stroke(CSSThemeVariables.divider(scope: .settings), lineWidth: 0.5)
        )
    }

    private var iconSlotsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(AppLocalized("常用界面图标"))
                .font(ChatFont.font(13, weight: .bold))
                .foregroundStyle(CSSThemeVariables.textMain(scope: .settings))

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach([QuietIconSlot.decorate, .skills, .memory, .terminal, .browser, .storage], id: \.self) { slot in
                    iconSlotCard(slot)
                }
            }
        }
        .padding(DressingTokens.Padding.card)
        .background(CSSThemeVariables.card(scope: .settings).opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: DressingTokens.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DressingTokens.Radius.card, style: .continuous)
                .stroke(CSSThemeVariables.divider(scope: .settings), lineWidth: 0.5)
        )
    }

    private func iconSlotCard(_ slot: QuietIconSlot) -> some View {
        HStack(spacing: 8) {
            // 点图标换图：和 AIChatView / PersonaSettingsView 同一款写法——
            // Button action 里先记格、再打开选图器，选完图的 onChange 读到的
            // 就是这次点的格。不能用 TapGesture 记格：它只认真实触摸，
            // VoiceOver 激活走 Button action，不经过手势系统。
            Button {
                pendingIconSlotId = slot.id
                iconPickerPresented = true
            } label: {
                QuietAppIcon(id: slot.id, systemName: slot.systemName, size: 24)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(slot.title)

            VStack(alignment: .leading, spacing: 2) {
                Text(slot.title)
                    .font(ChatFont.font(11, weight: .medium))
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
                        .font(ChatFont.font(10, weight: .medium))
                        .foregroundStyle(CSSThemeVariables.textDim(scope: .settings))
                        .padding(.horizontal, DressingTokens.Padding.itemPillHorizontal)
                        .padding(.vertical, DressingTokens.Padding.smallPillVertical)
                        .background(CSSThemeVariables.surfaceFill(scope: .settings))
                        .clipShape(Capsule())
                }
            }
        }
        .padding(DressingTokens.Padding.inner)
        .background(CSSThemeVariables.surfaceFill(scope: .settings).opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: DressingTokens.Radius.chip, style: .continuous))
    }

    // MARK: - 标签符号：每个分类挑一个 SF Symbol，后端是 pack.categoryIcons

    /// 候选符号：16 个内置默认符号，取自 sessionCategoryIconBuiltin 的
    /// 单一事实来源 —— 每个都在生产环境的会话行里真实渲染过
    /// (Image(systemName:))，所以选出来的每一个都一定能画出来；
    /// 不给自由输入，写错名字会在会话行上留一个空白图标。
    private var candidateSymbols: [String] {
        AppearanceThemePack.categoryKeys.map { sessionCategoryIconBuiltin(for: $0).systemName }
    }

    private func categorySymbolTitle(_ key: String) -> String {
        switch key {
        case "code": return AppLocalized("代码")
        case "writing": return AppLocalized("写作")
        case "research": return AppLocalized("研究")
        case "analysis": return AppLocalized("分析")
        case "creative": return AppLocalized("创意")
        case "chat": return AppLocalized("聊天")
        case "math": return AppLocalized("数学")
        case "translation": return AppLocalized("翻译")
        case "health": return AppLocalized("健康")
        case "finance": return AppLocalized("金融")
        case "travel": return AppLocalized("旅行")
        case "education": return AppLocalized("教育")
        case "design": return AppLocalized("设计")
        case "productivity": return AppLocalized("生产力")
        case "support": return AppLocalized("支持")
        default: return AppLocalized("其他")
        }
    }

    /// 当前生效的符号：改过用改的，没改过用内置默认。
    private func currentSymbolName(for key: String) -> String {
        studio.currentThemePack().categoryIcons[key] ?? sessionCategoryIconBuiltin(for: key).systemName
    }

    private var categorySymbolsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(AppLocalized("标签符号"))
                .font(ChatFont.font(13, weight: .bold))
                .foregroundStyle(CSSThemeVariables.textMain(scope: .settings))

            ForEach(AppearanceThemePack.categoryKeys, id: \.self) { key in
                categorySymbolRow(key)
            }
        }
        .padding(DressingTokens.Padding.card)
        .background(CSSThemeVariables.card(scope: .settings).opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: DressingTokens.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DressingTokens.Radius.card, style: .continuous)
                .stroke(CSSThemeVariables.divider(scope: .settings), lineWidth: 0.5)
        )
    }

    private func categorySymbolRow(_ key: String) -> some View {
        let isCustomized = studio.currentThemePack().categoryIcons[key] != nil
        let isExpanded = expandedCategoryKey == key
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    expandedCategoryKey = isExpanded ? nil : key
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: currentSymbolName(for: key))
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(CSSThemeVariables.accent(scope: .settings))
                            .frame(width: 28, height: 28)

                        Text(categorySymbolTitle(key))
                            .font(ChatFont.font(11, weight: .medium))
                            .foregroundStyle(CSSThemeVariables.textMain(scope: .settings))
                            .lineLimit(1)

                        Spacer()

                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(CSSThemeVariables.textDim(scope: .settings))
                    }
                }
                .buttonStyle(.plain)

                if isCustomized {
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        studio.setCategorySymbol("", for: key)
                        onNotify(AppLocalized("已恢复默认符号"))
                    } label: {
                        Text(AppLocalized("重置"))
                            .font(ChatFont.font(10, weight: .medium))
                            .foregroundStyle(CSSThemeVariables.textDim(scope: .settings))
                            .padding(.horizontal, DressingTokens.Padding.itemPillHorizontal)
                            .padding(.vertical, DressingTokens.Padding.smallPillVertical)
                            .background(CSSThemeVariables.surfaceFill(scope: .settings))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }

            if isExpanded {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                    ForEach(candidateSymbols, id: \.self) { name in
                        let isCurrent = currentSymbolName(for: key) == name
                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            if name == sessionCategoryIconBuiltin(for: key).systemName {
                                studio.setCategorySymbol("", for: key)
                            } else {
                                studio.setCategorySymbol(name, for: key)
                            }
                            expandedCategoryKey = nil
                        } label: {
                            Image(systemName: name)
                                .font(.system(size: 20, weight: .medium))
                                .foregroundStyle(isCurrent ? CSSThemeVariables.accent(scope: .settings) : CSSThemeVariables.textMain(scope: .settings))
                                .frame(width: 44, height: 44)
                                .background(isCurrent ? CSSThemeVariables.accent(scope: .settings).opacity(0.18) : CSSThemeVariables.surfaceFill(scope: .settings).opacity(0.4))
                                .clipShape(RoundedRectangle(cornerRadius: DressingTokens.Radius.chip, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(DressingTokens.Padding.inner)
        .background(CSSThemeVariables.surfaceFill(scope: .settings).opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: DressingTokens.Radius.chip, style: .continuous))
    }
}

// MARK: - 8. 保存主题弹窗 (DressingSaveThemeSheet)

@MainActor
struct DressingSaveThemeSheet: View {
    let onSaved: (String) -> Void
    let onNotify: (String) -> Void
    @ObservedObject private var studio = AppearanceStudio.shared
    @ObservedObject private var fontSettings = FontSettings.shared
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
                        .font(ChatFont.font(12, weight: .bold))
                        .foregroundStyle(CSSThemeVariables.textDim(scope: .settings))

                    TextField(AppLocalized("给这款主题起个名字..."), text: $themeName)
                        .padding(DressingTokens.Padding.card)
                        .background(CSSThemeVariables.surfaceFill(scope: .settings))
                        .clipShape(RoundedRectangle(cornerRadius: DressingTokens.Radius.field, style: .continuous))
                        .foregroundStyle(CSSThemeVariables.textMain(scope: .settings))
                }
                .padding(.horizontal, DressingTokens.Padding.page)

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
                        .font(ChatFont.font(14, weight: .bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, DressingTokens.Padding.sectionVertical)
                        .background(themeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? CSSThemeVariables.surfaceFill(scope: .settings) : CSSThemeVariables.accent(scope: .settings))
                        .foregroundStyle(themeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? CSSThemeVariables.textDim(scope: .settings) : CSSThemeVariables.card(scope: .settings))
                        .clipShape(Capsule())
                }
                .disabled(themeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .padding(.horizontal, DressingTokens.Padding.page)

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
    @ObservedObject private var fontSettings = FontSettings.shared
    @State private var importText: String = ""
    @State private var showSTPicker = false
    @State private var pendingST: SillyTavernTheme.Imported? = nil
    @State private var showSTConfirm = false
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
                                .font(ChatFont.font(13, weight: .bold))
                                .foregroundStyle(CSSThemeVariables.textMain(scope: .settings))

                            Text(AppLocalized("将当前主题生成为 JSON 字符串并写入系统剪贴板。"))
                                .font(ChatFont.font(11))
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
                                        .font(ChatFont.font(12, weight: .semibold))
                                }
                                .padding(.horizontal, DressingTokens.Padding.contentHorizontal)
                                .padding(.vertical, DressingTokens.Padding.contentVertical)
                                .background(CSSThemeVariables.accent(scope: .settings))
                                .foregroundStyle(CSSThemeVariables.card(scope: .settings))
                                .clipShape(Capsule())
                            }
                        }
                        .padding(DressingTokens.Padding.section)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(CSSThemeVariables.card(scope: .settings).opacity(0.85))
                        .clipShape(RoundedRectangle(cornerRadius: DressingTokens.Radius.card, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: DressingTokens.Radius.card, style: .continuous)
                                .stroke(CSSThemeVariables.divider(scope: .settings), lineWidth: 0.5)
                        )

                        // 导入卡片
                        VStack(alignment: .leading, spacing: 10) {
                            Text(AppLocalized("从剪贴板或文本导入"))
                                .font(ChatFont.font(13, weight: .bold))
                                .foregroundStyle(CSSThemeVariables.textMain(scope: .settings))

                            TextEditor(text: $importText)
                                .frame(height: 120)
                                .padding(DressingTokens.Padding.inner)
                                .background(CSSThemeVariables.surfaceFill(scope: .settings))
                                .clipShape(RoundedRectangle(cornerRadius: DressingTokens.Radius.chip, style: .continuous))
                                .font(ChatFont.font(11, design: .monospaced))

                            HStack(spacing: 8) {
                                Button {
                                    if let clip = UIPasteboard.general.string {
                                        importText = clip
                                        onNotify(AppLocalized("已粘贴剪贴板内容"))
                                    }
                                } label: {
                                    Text(AppLocalized("粘贴"))
                                        .font(ChatFont.font(11, weight: .medium))
                                        .padding(.horizontal, DressingTokens.Padding.pillHorizontal)
                                        .padding(.vertical, DressingTokens.Padding.widePillVertical)
                                        .background(CSSThemeVariables.surfaceFill(scope: .settings))
                                        .foregroundStyle(CSSThemeVariables.textMain(scope: .settings))
                                        .clipShape(Capsule())
                                }

                                Spacer()

                                Button {
                                    applyImportedPack()
                                } label: {
                                    Text(AppLocalized("解析并换上"))
                                        .font(ChatFont.font(12, weight: .bold))
                                        .padding(.horizontal, DressingTokens.Padding.cardHorizontal)
                                        .padding(.vertical, DressingTokens.Padding.widePillVertical)
                                        .background(importText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? CSSThemeVariables.surfaceFill(scope: .settings) : CSSThemeVariables.accent(scope: .settings))
                                        .foregroundStyle(importText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? CSSThemeVariables.textDim(scope: .settings) : CSSThemeVariables.card(scope: .settings))
                                        .clipShape(Capsule())
                                }
                                .disabled(importText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                        }
                        .padding(DressingTokens.Padding.section)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(CSSThemeVariables.card(scope: .settings).opacity(0.85))
                        .clipShape(RoundedRectangle(cornerRadius: DressingTokens.Radius.card, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: DressingTokens.Radius.card, style: .continuous)
                                .stroke(CSSThemeVariables.divider(scope: .settings), lineWidth: 0.5)
                        )

                        // 小酒馆主题卡片：上传 ST 主题 JSON 文件（不是粘贴文本）。
                        // 解析走 SillyTavernTheme.parse，换上前先过确认页。
                        VStack(alignment: .leading, spacing: 10) {
                            Text(AppLocalized("导入小酒馆主题"))
                                .font(ChatFont.font(13, weight: .bold))
                                .foregroundStyle(CSSThemeVariables.textMain(scope: .settings))

                            Text(AppLocalized("上传小酒馆主题 JSON 文件，颜色、圆角、行高与字号都会跟着变，换上前先让你确认。"))
                                .font(ChatFont.font(11))
                                .foregroundStyle(CSSThemeVariables.textDim(scope: .settings))

                            Button {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                showSTPicker = true
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "square.and.arrow.up")
                                        .font(.system(size: 11))
                                    Text(AppLocalized("选择 JSON 文件"))
                                        .font(ChatFont.font(12, weight: .semibold))
                                }
                                .padding(.horizontal, DressingTokens.Padding.contentHorizontal)
                                .padding(.vertical, DressingTokens.Padding.contentVertical)
                                .background(CSSThemeVariables.accent(scope: .settings))
                                .foregroundStyle(CSSThemeVariables.card(scope: .settings))
                                .clipShape(Capsule())
                            }
                        }
                        .padding(DressingTokens.Padding.section)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(CSSThemeVariables.card(scope: .settings).opacity(0.85))
                        .clipShape(RoundedRectangle(cornerRadius: DressingTokens.Radius.card, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: DressingTokens.Radius.card, style: .continuous)
                                .stroke(CSSThemeVariables.divider(scope: .settings), lineWidth: 0.5)
                        )
                    }
                    .padding(DressingTokens.Padding.sheet)
                }
            }
            .background(AppearanceBackdrop(scope: .settings).ignoresSafeArea())
            .sheet(isPresented: $showSTPicker, onDismiss: {
                // 选完图的回调先于 onDone 跑：解析成功时 pendingST 已经
                // 在了，选图器关掉后才弹确认页；取消或解析失败时
                // pendingST 是 nil，什么都不弹。
                if pendingST != nil { showSTConfirm = true }
            }) {
                DocumentCopyPicker(
                    contentTypes: [UTType.json],
                    allowsMultipleSelection: false,
                    onPick: { urls in handleSTFile(urls) },
                    onDone: { showSTPicker = false }
                )
            }
            .sheet(isPresented: $showSTConfirm, onDismiss: { pendingST = nil }) {
                if let imported = pendingST {
                    STImportConfirmSheet(
                        imported: imported,
                        onApply: { applySTImport(imported) },
                        onCancel: { showSTConfirm = false }
                    )
                }
            }
        }
    }

    /// 读用户选的 ST 主题 JSON 文件并解析。选图器是 asCopy 模式
    /// （DocumentCopyPicker），文件拷进 tmp 后的普通地址，
    /// Data(contentsOf:) 直接就能读，不用安全域授权 —— 自签包上
    /// 就地打开模式点按会静默死亡（字体上传那次的教训），这里
    /// 绝不能回到 open-in-place。
    private func handleSTFile(_ urls: [URL]) {
        guard let url = urls.first else { return }
        guard let data = try? Data(contentsOf: url) else {
            onNotify(AppLocalized("读取文件失败"))
            return
        }
        do {
            pendingST = try SillyTavernTheme.parse(data)
        } catch {
            onNotify(AppLocalized("主题解析失败：") + error.localizedDescription)
        }
    }

    /// 先抓撤销快照再换上：和 resetPaletteWithUndo 同一套撤销机制，
    /// 换上后顶栏的撤销箭头能把旧主题救回来。快照抓不到时导入照常
    /// 换上，只是不留撤销（快照函数内部已清掉旧快照，箭头不会
    /// 承诺一次做不到的撤销）。
    private func applySTImport(_ imported: SillyTavernTheme.Imported) {
        _ = studio.captureUndoSnapshotBeforeImport()
        studio.applySillyTavern(imported)
        showSTConfirm = false
        pendingST = nil
        onNotify(AppLocalized("已成功换上：") + imported.name)
        dismiss()
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

// MARK: - 10. 小酒馆主题导入确认 (STImportConfirmSheet)
//
// 只做确认，不做换算：颜色是 SillyTavernTheme.parse 已经映射好的
// 两张表（浅色版 + 深色版，解析器在原包是浅色时按反相推导、是
// 深色时直接复用同一套）；确认页按当前深浅读其中一张，正文与
// 强调色在这里再过一遍和 applySillyTavern 一模一样的对比度
// enforcement，所以确认页上看到的颜色就是换上后实际生效的颜色，
// 不是一张“看起来像”的图。
// 仿聊天小视窗复用不了：它是读当前主题画的，改它去画一个还没
// 换上的 Imported 要新加一套参数化管线；这里直接用解析出来的
// 六个色画两句示例气泡，够确认，不发明新机械。

@MainActor
struct STImportConfirmSheet: View {
    let imported: SillyTavernTheme.Imported
    let onApply: () -> Void
    let onCancel: () -> Void

    @ObservedObject private var fontSettings = FontSettings.shared
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                DressingSheetHeader(
                    title: imported.name,
                    subtitle: AppLocalized("小酒馆主题")
                )

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 16) {
                        // 六个主色
                        VStack(alignment: .leading, spacing: 10) {
                            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                                swatchCell(label: AppLocalized("底色"), hex: hex(.canvas))
                                swatchCell(label: AppLocalized("卡片"), hex: hex(.surface))
                                swatchCell(label: AppLocalized("强调"), hex: effectiveAccentHex)
                                swatchCell(label: AppLocalized("正文"), hex: effectiveTextHex)
                                swatchCell(label: AppLocalized("我的气泡"), hex: hex(.userBubble))
                                swatchCell(label: AppLocalized("AI 气泡"), hex: hex(.assistantBubble))
                            }
                        }
                        .padding(DressingTokens.Padding.section)
                        .background(CSSThemeVariables.card(scope: .settings).opacity(0.85))
                        .clipShape(RoundedRectangle(cornerRadius: DressingTokens.Radius.card, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: DressingTokens.Radius.card, style: .continuous)
                                .stroke(CSSThemeVariables.divider(scope: .settings), lineWidth: 0.5)
                        )

                        // 两句示例气泡：和装扮中心顶栏预览同一句文案
                        VStack(spacing: 10) {
                            HStack(alignment: .top, spacing: 8) {
                                Text(AppLocalized("你好，醒醒。今天想怎么打扮我？"))
                                    .font(ChatFont.font(12))
                                    .foregroundStyle(Color(hex: effectiveTextHex))
                                    .padding(.horizontal, DressingTokens.Padding.contentHorizontal)
                                    .padding(.vertical, DressingTokens.Padding.contentVertical)
                                    .background(Color(hex: hex(.assistantBubble)))
                                    .clipShape(RoundedRectangle(cornerRadius: previewBubbleRadius(user: false), style: .continuous))
                                Spacer(minLength: 20)
                            }

                            HStack(alignment: .top, spacing: 8) {
                                Spacer(minLength: 20)
                                Text(AppLocalized("做简单、精致、iOS 26 质感～"))
                                    .font(ChatFont.font(12))
                                    .foregroundStyle(Color(hex: effectiveTextHex))
                                    .padding(.horizontal, DressingTokens.Padding.contentHorizontal)
                                    .padding(.vertical, DressingTokens.Padding.contentVertical)
                                    .background(Color(hex: hex(.userBubble)))
                                    .clipShape(RoundedRectangle(cornerRadius: previewBubbleRadius(user: true), style: .continuous))
                            }
                        }
                        .padding(DressingTokens.Padding.card)
                        .background(Color(hex: hex(.canvas)).opacity(0.85))
                        .clipShape(RoundedRectangle(cornerRadius: DressingTokens.Radius.innerCard, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: DressingTokens.Radius.innerCard, style: .continuous)
                                .stroke(CSSThemeVariables.divider(scope: .settings), lineWidth: 0.5)
                        )

                        // 头像 / 消息 / 字号
                        VStack(alignment: .leading, spacing: 8) {
                            summaryRow(label: AppLocalized("头像"), value: imported.avatarShape.title)
                            summaryRow(label: AppLocalized("消息"), value: imported.chatDisplay.title)
                            if let scale = imported.fontScale {
                                summaryRow(label: AppLocalized("字号"), value: "\(Int(min(15, max(10, (13 * scale).rounded()))))pt")
                            }
                        }
                        .padding(DressingTokens.Padding.section)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(CSSThemeVariables.card(scope: .settings).opacity(0.85))
                        .clipShape(RoundedRectangle(cornerRadius: DressingTokens.Radius.card, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: DressingTokens.Radius.card, style: .continuous)
                                .stroke(CSSThemeVariables.divider(scope: .settings), lineWidth: 0.5)
                        )

                        // 解析时留下的提醒
                        if !imported.warnings.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(imported.warnings, id: \.self) { warning in
                                    Text(warning)
                                        .font(ChatFont.font(11))
                                        .foregroundStyle(CSSThemeVariables.textDim(scope: .settings))
                                }
                            }
                            .padding(DressingTokens.Padding.section)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(CSSThemeVariables.card(scope: .settings).opacity(0.85))
                            .clipShape(RoundedRectangle(cornerRadius: DressingTokens.Radius.card, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: DressingTokens.Radius.card, style: .continuous)
                                    .stroke(CSSThemeVariables.divider(scope: .settings), lineWidth: 0.5)
                            )
                        }

                        // 换上 / 取消
                        HStack(spacing: 12) {
                            Button {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                onCancel()
                            } label: {
                                Text(AppLocalized("取消"))
                                    .font(ChatFont.font(12, weight: .semibold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, DressingTokens.Padding.cardVertical)
                                    .background(CSSThemeVariables.surfaceFill(scope: .settings))
                                    .foregroundStyle(CSSThemeVariables.textMain(scope: .settings))
                                    .clipShape(Capsule())
                            }

                            Button {
                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                onApply()
                            } label: {
                                Text(AppLocalized("换上"))
                                    .font(ChatFont.font(12, weight: .bold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, DressingTokens.Padding.cardVertical)
                                    .background(CSSThemeVariables.accent(scope: .settings))
                                    .foregroundStyle(CSSThemeVariables.card(scope: .settings))
                                    .clipShape(Capsule())
                            }
                        }
                    }
                    .padding(DressingTokens.Padding.sheet)
                }
            }
            .background(AppearanceBackdrop(scope: .settings).ignoresSafeArea())
        }
    }

    /// 确认页按当前深浅画哪张表：浅色下读 light、深色下读 dark。
    /// applySillyTavern 两档都写，暗色下确认浅色预览、换上却是
    /// 反相推导的深色套，是谎言。enforcement 逻辑不变，只换
    /// 读哪张表 —— 六个色格和两句示例气泡都走 hex()，一次改
    /// 全改对。
    private var previewTable: [AppearanceColorRole: String] {
        colorScheme == .dark ? imported.dark : imported.light
    }

    private func hex(_ role: AppearanceColorRole) -> String {
        previewTable[role] ?? "FFFFFF"
    }

    /// 和 applySillyTavern 里同一段 enforcement：先底色、再卡片面，
    /// 正文用 body 档（4.5），强调色用 ui 档（3.0），只动明度不动色相。
    private var effectiveTextHex: String {
        var fg = AppearanceContrast.enforce(hex(.primaryText), on: hex(.canvas), level: .body)
        fg = AppearanceContrast.enforce(fg, on: hex(.surface), level: .body)
        return fg
    }

    private var effectiveAccentHex: String {
        var accent = AppearanceContrast.enforce(hex(.accent), on: hex(.canvas), level: .ui)
        accent = AppearanceContrast.enforce(accent, on: hex(.surface), level: .ui)
        return accent
    }

    /// 示例气泡的圆角：和 applySillyTavern 里同一段 clamp（0–32）。
    /// 包里没写圆角时换上不动现有圆角，所以预览也画现有圆角 ——
    /// 不能硬编一个 14pt，否则预览和换上后对不上。用户气泡与 AI
    /// 气泡各画各的现有圆角。
    private func previewBubbleRadius(user: Bool) -> CGFloat {
        if let r = imported.bubbleRadius {
            return CGFloat(min(32, max(0, r)))
        }
        let pack = AppearanceStudio.shared.currentThemePack()
        return CGFloat(user ? pack.userBubbleRadius : pack.assistantBubbleRadius)
    }

    private func swatchCell(label: String, hex: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            RoundedRectangle(cornerRadius: DressingTokens.Radius.swatch, style: .continuous)
                .fill(Color(hex: hex))
                .frame(height: 44)
                .overlay(
                    RoundedRectangle(cornerRadius: DressingTokens.Radius.swatch, style: .continuous)
                        .stroke(CSSThemeVariables.divider(scope: .settings), lineWidth: 0.5)
                )
            Text(label)
                .font(ChatFont.font(10, weight: .medium))
                .foregroundStyle(CSSThemeVariables.textMain(scope: .settings))
            Text("#" + hex)
                .font(ChatFont.micro(9, design: .monospaced))
                .foregroundStyle(CSSThemeVariables.textDim(scope: .settings))
        }
    }

    private func summaryRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(ChatFont.font(11))
                .foregroundStyle(CSSThemeVariables.textDim(scope: .settings))
            Spacer()
            Text(value)
                .font(ChatFont.font(11, weight: .medium))
                .foregroundStyle(CSSThemeVariables.textMain(scope: .settings))
        }
    }
}
