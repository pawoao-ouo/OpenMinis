import SwiftUI

// MARK: - [s2-askuser] 提问小抽屉 (CSS全局变量驱动、素行选项与紧凑贴底设计)
//
// 视觉特性（对齐视频里的提问卡片）：
// 1. 弹窗高度跟着内容走，绝无大片空白区域；超长时自适应平滑滚动。
// 2. 卡片紧贴屏幕物理底部，不悬空，安全区自然延展。
// 3. 素行选项：每行纯文字 + 细分隔线，选中行右端打勾；自填行同样一条素行。
// 4. 右下角胶囊"提交"，旁边一颗文字"跳过"；提交后对话里留一条"问：… 答：…"气泡。
// 5. 全局 CSS 变量系统驱动色彩与样式，零硬编码色。

// MARK: - CSS 全局色彩变量定义
//
// [T-dynamic-color] 这套变量的每个成员都是**动态色**：同一份 `Color` 同时
// 携带浅色和深色的值，由 UIKit 在解析时按当前 trait collection 选。
//
// 所以这里不再收 `isDark: Bool`。以前每个函数都要调用方传
// `colorScheme == .dark`，而 `AppearanceStudio` 内部又用 `appearanceMode`
// 自己判一次 —— 两个判定源。用户在设置里强制浅色、系统是深色时，两者给出
// 相反答案，同一屏的卡片和文字就分成两套配色。现在只有 trait collection
// 一个源，`preferredColorScheme` 改的也正是它，不可能再打架。
//
// 顺带：切系统外观不用重建视图，UIKit 自己重解析；也不再需要
// `@ObservedObject var appearanceStudio` 才能刷新颜色（改色仍然需要它，
// 因为那是换值不是换明暗）。

@MainActor
/// Colours as CSS-style variables.
///
/// `internal`, not `public`: these take `AppearanceScope` as a default
/// argument, and a public signature cannot carry an internal type's case
/// there. Nothing outside the module used them anyway.
enum CSSThemeVariables {
    private static var studio: AppearanceStudio { .shared }

    /// 一起听图标的字重与尺寸放大系数：画法统一在这一层定。
    static let togetherIconWeight: Font.Weight = .semibold
    static let togetherIconScale: CGFloat = 1.12

    /// --color-card / var(--dudu-card)
    /// [4-1 醒醒] 背景卡接入全局 surface 角色，支持壁纸透明度
    /// 取色和透明度必须一起走:只配一个,页面会一半深一半浅。
    /// 透光只一套算法:无条件乘 surfaceOpacity,有壁纸没壁纸都一样,
    /// 旋钮就是这一个值。
    static func card(scope: AppearanceScope = ThemeColorLayer.sheet) -> Color {
        studio.color(.surface, scope: scope).opacity(studio.surfaceOpacity)
    }

    /// 不透明 surface 色：给字色/图标当前景色用，不跟透光旋钮走。
    /// 字不是卡片面，旋钮拉到 0 时字不能跟着消失。
    static func surface(scope: AppearanceScope = ThemeColorLayer.sheet) -> Color {
        studio.color(.surface, scope: scope)
    }

    /// --color-bg / var(--dudu-cream)
    /// [4-1 醒醒] 背景底衬接入全局 canvas 角色
    /// 同 card:跟主题角色一起走。
    static func bg(scope: AppearanceScope = ThemeColorLayer.sheet) -> Color {
        studio.color(.canvas, scope: scope)
    }

    /// --color-text-main / var(--dudu-brown)
    /// [4-1 醒醒] 主文字接入全局 primaryText 角色
    static func textMain(scope: AppearanceScope = ThemeColorLayer.sheet) -> Color {
        studio.color(.primaryText, scope: scope)
    }

    /// --color-text-dim / var(--dudu-text-dim)
    /// [4-1 醒醒] 次文字接入全局 secondaryText 角色
    static func textDim(scope: AppearanceScope = ThemeColorLayer.sheet) -> Color {
        studio.color(.secondaryText, scope: scope)
    }

    /// [T-03] 最淡的一档字（脚注、时间、次要说明）接全局 tertiaryText。
    /// 以前一起听自己写死 #8E8E93，主文字换了它不跟。
    static func textTertiary(scope: AppearanceScope = ThemeColorLayer.sheet) -> Color {
        studio.color(.tertiaryText, scope: scope)
    }

    /// [T-03] 玻璃面用的底色。就是 card 本身,无条件带 surfaceOpacity,
    /// 有壁纸没壁纸都一样 —— 这样瓷白玻璃在浅色/深色、有图/没图下都还站得住。
    static func surfaceFill(scope: AppearanceScope = ThemeColorLayer.sheet) -> Color {
        card(scope: scope)
    }

    /// --color-divider / var(--dudu-divider)
    /// [4-1 醒醒] 分隔线接入全局 border 角色
    /// 同 card:跟主题角色一起走。
    static func divider(scope: AppearanceScope = ThemeColorLayer.sheet) -> Color {
        studio.color(.border, scope: scope)
    }

    /// --color-accent-soft / var(--dudu-pink-soft)
    /// [4-1 醒醒] 柔和强调色由 accent 角色动态派生
    static func accentSoft(scope: AppearanceScope = ThemeColorLayer.sheet) -> Color {
        studio.color(.accent, scope: scope).opacity(0.18)
    }

    /// --color-accent / var(--dudu-pink)
    /// [4-1 醒醒] 强调色接入全局 accent 角色
    static func accent(scope: AppearanceScope = ThemeColorLayer.sheet) -> Color {
        studio.color(.accent, scope: scope)
    }

    /// --color-accent-fg / 强调色上的前景字（按钮标题、图标）
    ///
    /// [T-dynamic-color] 原来硬写 `Color.white`。强调色是用户自己挑的，
    /// 挑成浅黄、浅粉、米白时白字直接看不见。现在按 WCAG 对比度在黑白之间
    /// 选更好的那个，逐明暗各算一遍。
    static func accentFg(scope: AppearanceScope = ThemeColorLayer.sheet) -> Color {
        Color(uiColor: accentFgUIColor(scope: scope))
    }

    /// `accentFg` 的 UIKit 形式。动态色闭包里算对比度，所以不用调用方告诉
    /// 它现在是深还是浅。
    static func accentFgUIColor(scope: AppearanceScope = ThemeColorLayer.sheet) -> UIColor {
        UIColor { trait in
            let variant: AppearanceVariant = trait.userInterfaceStyle == .dark ? .dark : .light
            let accentHex = AppearanceStudio.snapshotHex(.accent, scope: scope, variant: variant)
            return UIColor(hex: Self.bestForegroundHex(on: accentHex))
        }
    }

    /// 强调色上的前景字。
    ///
    /// [T-dynamic-color] 原来硬写 `Color.white`。强调色是用户自己挑的，挑成
    /// 浅黄、浅米白时白字直接看不见，所以要有兜底。
    ///
    /// 但**不是简单比黑白哪个对比度高**：内置的粉色强调色上，黑字对比度
    /// 6.8 比白字 3.1 高，纯比大小会把整个 App 的按钮文字从白翻成黑——
    /// 那是视觉大改，没人要求。
    ///
    /// 门槛取 2.0，刻意低于 WCAG 的 3.0：内置两套配色的白字对比度是
    /// 3.08 / 2.41，用 3.0 会让深色模式也跟着翻黑。这里的目的是「白字
    /// 真的看不见时兜底」，不是「把现有配色校正到达标」——后者会改动
    /// 所有既有观感。用户挑浅黄（1.5）这类极端色时才换黑。
    nonisolated static func bestForegroundHex(on backgroundHex: String) -> String {
        let white = "FFFFFF"
        let black = "000000"
        let onWhite = AppearanceContrast.ratio(white, on: backgroundHex)
        guard onWhite < 2.0 else { return white }
        // 白字真的看不见了，看黑字能不能救；黑字也不行就取对比度高的那个。
        let onBlack = AppearanceContrast.ratio(black, on: backgroundHex)
        return onBlack >= onWhite ? black : white
    }

    /// --color-option-bg (输入框/未选中胶囊底色)
    /// [10-15 1-3 醒醒] 输入框与选项底色接入全局 input 角色（同族统一，不再硬编码 hex）
    /// 同 card:跟主题角色一起走。
    static func optionBg(scope: AppearanceScope = ThemeColorLayer.sheet) -> Color {
        studio.color(.field, scope: scope)
    }

    /// --color-option-border (输入框/未选中胶囊边框)
    /// [10-15 1-3 醒醒] 输入框与选项边线接入全局 border 角色
    /// 同 divider:跟主题角色一起走。
    static func optionBorder(scope: AppearanceScope = ThemeColorLayer.sheet) -> Color {
        studio.color(.border, scope: scope)
    }

    /// --color-scrim / 遮罩层
    ///
    /// 不是主题角色（遮罩永远是暗的，不跟用户配色），但明暗两套值不同，
    /// 所以同样做成动态色。
    static func scrim() -> Color {
        Color(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor.black.withAlphaComponent(0.65)
                : UIColor(hex: "2A2A2E").withAlphaComponent(0.28)
        })
    }

    /// --color-sheet-shadow / 弹窗投影
    static func sheetShadow() -> Color {
        Color(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor.black.withAlphaComponent(0.45)
                : UIColor(hex: "8B736C").withAlphaComponent(0.16)
        })
    }

    /// --color-danger
    /// [4-1 醒醒] 危险操作接入全局 destructive 角色
    static func danger(scope: AppearanceScope = ThemeColorLayer.sheet) -> Color {
        studio.color(.destructive, scope: scope)
    }

    /// --color-danger-soft
    static func dangerSoft(scope: AppearanceScope = ThemeColorLayer.sheet) -> Color {
        studio.color(.destructive, scope: scope).opacity(0.18)
    }

    /// --color-success
    ///
    /// [AUD-18] Delegates to the theme role instead of another pair of hex
    /// literals: `AppearanceStudio.color(_:)` already resolves per
    /// appearance, so this variable follows the user's theme and its dark
    /// variant for free.
    static func success(scope: AppearanceScope = ThemeColorLayer.sheet) -> Color {
        studio.color(.success, scope: scope)
    }

    /// --color-warning
    static func warning(scope: AppearanceScope = ThemeColorLayer.sheet) -> Color {
        studio.color(.warning, scope: scope)
    }
}

// MARK: - 顶角圆角 Shape 工具

private struct AskRoundedCorner: Shape {
    var radius: CGFloat = 24.0
    var corners: UIRectCorner = [.topLeft, .topRight]

    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(
            roundedRect: rect,
            byRoundingCorners: corners,
            cornerRadii: CGSize(width: radius, height: radius)
        )
        return Path(path.cgPath)
    }
}

// MARK: - 素行按压反馈样式（只压暗，不缩放——素行没有卡片可缩）

private struct AskRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.55 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - 问询挂载修饰器

struct AskUserDialogModifier: ViewModifier {
    @ObservedObject private var suspension = ToolSuspensionService.shared
    @ObservedObject var vm: AIChatViewModel

    private var currentRequest: SuspendedRequest? {
        suspension.askRequestForSession(vm.sessionId)
    }

    func body(content: Content) -> some View {
        ZStack {
            content

            if let request = currentRequest {
                AskUserDrawerOverlay(request: request, vm: vm)
                    .zIndex(9999)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.28), value: currentRequest != nil)
    }
}

// MARK: - 提问小抽屉 Overlay

private struct AskUserDrawerOverlay: View {
    /// [T-dynamic-color] 观察主题，改色立刻重绘（明暗由动态色自己跟 trait）。
    @ObservedObject private var appearanceStudio = AppearanceStudio.shared
    let request: SuspendedRequest
    @ObservedObject var vm: AIChatViewModel

    @State private var states: [QuestionAnswerState] = []
    @State private var activeQuestionIndex: Int = 0

    private var payload: AskPayload? {
        if case .askUser(let p) = request.kind { return p }
        return nil
    }

    private var isRestored: Bool { request.tag == "ask-user-restored" }
    private var isSessionReady: Bool { !vm.isLoadingSession }

    private var questions: [AskQuestion] {
        payload?.questions ?? []
    }

    private var currentQuestion: AskQuestion? {
        guard !questions.isEmpty, activeQuestionIndex < questions.count else { return nil }
        return questions[activeQuestionIndex]
    }

    private var displayTitle: String {
        if let current = currentQuestion {
            return current.question
        }
        return payload?.title ?? "AI 想问你几个问题"
    }

    private var canSubmit: Bool {
        guard !states.isEmpty else { return false }
        for st in states {
            if !st.selected.isEmpty || !st.otherText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return true
            }
        }
        return false
    }

    var body: some View {
        GeometryReader { proxy in
            let bottomInset = proxy.safeAreaInsets.bottom

            ZStack(alignment: .bottom) {
                // 背景半透明遮罩 (Scrim)
                CSSThemeVariables.scrim()
                    .ignoresSafeArea()
                    .onTapGesture {
                        dismiss()
                    }

                // 抽屉卡片主体 (贴底不悬空，高度随内容紧凑自适应)
                VStack(spacing: 0) {
                    // 抽屉头部：左对齐粗标题 + 右上 X（视频里的样式，没有抓手条）
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(displayTitle)
                                .font(ChatFont.font(17, weight: .semibold))
                                .foregroundColor(CSSThemeVariables.textMain())
                                .multilineTextAlignment(.leading)
                                .lineLimit(3)
                                .fixedSize(horizontal: false, vertical: true)

                            if questions.count > 1 {
                                Text("问题 \(activeQuestionIndex + 1) / \(questions.count)")
                                    .font(ChatFont.font(11))
                                    .foregroundColor(CSSThemeVariables.textDim())
                            } else if isRestored {
                                Text("之前未答完的问题，答完后继续")
                                    .font(ChatFont.font(11))
                                    .foregroundColor(CSSThemeVariables.textDim())
                            }
                        }

                        // 右上角圆形关闭按钮 (Close Button)，和"跳过"同一个动作
                        Button(action: dismiss) {
                            Image(systemName: "xmark")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(CSSThemeVariables.textMain())
                                .frame(width: 40, height: 40)
                                .background(CSSThemeVariables.accentSoft())
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 18)
                    .padding(.bottom, 6)

                    // 抽屉主体：素行选项 (紧跟内容高度，底部绝无留白)
                    if let q = currentQuestion, activeQuestionIndex < states.count {
                        let isMulti = q.type == "multi"
                        let currentState = states[activeQuestionIndex]

                        if q.isConfirm {
                            // [T-manual-phase2-3a] confirm 不是"挑一个"，是
                            // "批不批"。题面下面写清会失去什么，然后两颗键。
                            confirmBody(q: q, currentState: currentState)
                                .padding(.horizontal, 20)
                                .padding(.top, 8)
                                .padding(.bottom, 8)
                        } else if q.options.count <= 4 {
                            // 选项少时紧贴内容高度渲染，高度由内容自然撑开
                            optionsList(q: q, currentState: currentState, isMulti: isMulti)
                                .padding(.top, 4)
                                .padding(.bottom, 4)
                        } else {
                            // 选项很多时才限制最大高度并支持滚动
                            ScrollView(.vertical, showsIndicators: true) {
                                optionsList(q: q, currentState: currentState, isMulti: isMulti)
                                    .padding(.top, 4)
                                    .padding(.bottom, 4)
                            }
                            .frame(maxHeight: UIScreen.main.bounds.height * 0.46)
                        }
                    }

                    // 抽屉底部操作栏 (Foot)：上一题/下一题 + 跳过 + 提交
                    HStack(spacing: 14) {
                        if questions.count > 1 {
                            // 多题目时的上一题 / 下一题切换
                            if activeQuestionIndex > 0 {
                                Button("上一题") {
                                    withAnimation(.spring(response: 0.28, dampingFraction: 0.72)) {
                                        activeQuestionIndex -= 1
                                    }
                                }
                                .font(ChatFont.font(13, weight: .medium))
                                .foregroundColor(CSSThemeVariables.textDim())
                            }

                            if activeQuestionIndex < questions.count - 1 {
                                Button("下一题") {
                                    withAnimation(.spring(response: 0.28, dampingFraction: 0.72)) {
                                        activeQuestionIndex += 1
                                    }
                                }
                                .font(ChatFont.font(13, weight: .medium))
                                .foregroundColor(CSSThemeVariables.accent())
                            }
                        }

                        Spacer()

                        // 文字"跳过"：和右上 X 同一个动作（decision .skipped），
                        // 卡片上终于有一颗看得见的跳过。
                        Button("跳过", action: dismiss)
                            .font(ChatFont.font(15, weight: .medium))
                            .foregroundColor(CSSThemeVariables.textDim())
                            .buttonStyle(.plain)

                        // 右下角胶囊提交按钮 (Submit Button)。
                        // 颜色走主题 accent，不是视频里那个写死的黑。
                        Button(action: submit) {
                            Text("提交")
                                .font(ChatFont.font(16, weight: .semibold))
                                .foregroundColor(CSSThemeVariables.accentFg())
                                .frame(minWidth: 110, minHeight: 44)
                                .background(CSSThemeVariables.accent())
                                .clipShape(Capsule())
                        }
                        .disabled(!canSubmit || !isSessionReady)
                        .opacity((canSubmit && isSessionReady) ? 1.0 : 0.45)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 10)
                    .padding(.bottom, 8)
                }
                .padding(.bottom, max(bottomInset, 16))
                .background(
                    CSSThemeVariables.card()
                        .clipShape(AskRoundedCorner(radius: 24, corners: [.topLeft, .topRight]))
                )
                .shadow(color: CSSThemeVariables.sheetShadow(), radius: 24, x: 0, y: -8)
                .transition(.move(edge: .bottom))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .ignoresSafeArea()
        }
        .onAppear {
            if let payload, states.count != payload.questions.count {
                states = Array(repeating: QuestionAnswerState(), count: payload.questions.count)
            }
        }
    }

    // MARK: - 素行选项与自填行

    /// [T-manual-phase2-3a] confirm 类型的题面：impact 写在下面，
    /// 然后是批准/拒绝两颗键。颜色只用 ChatColors / CSSThemeVariables，
    /// 字号走 ChatFont，和卡片其余部分同一套。
    @ViewBuilder
    private func confirmBody(q: AskQuestion, currentState: QuestionAnswerState) -> some View {
        let isHighRisk = (q.risk ?? "").lowercased() == "high"
        VStack(alignment: .leading, spacing: 10) {
            if let impact = q.impact, !impact.isEmpty {
                Text(impact)
                    .font(ChatFont.font(13))
                    .foregroundColor(isHighRisk ? CSSThemeVariables.warning() : CSSThemeVariables.textDim())
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                confirmKey(title: "批准", approved: true, selected: currentState.selected.contains(0),
                           isHighRisk: isHighRisk)
                confirmKey(title: "拒绝", approved: false, selected: currentState.selected.contains(1),
                           isHighRisk: isHighRisk)
            }
        }
    }

    @ViewBuilder
    private func confirmKey(title: String, approved: Bool, selected: Bool, isHighRisk: Bool) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: approved ? .medium : .light).impactOccurred()
            withAnimation(.spring(response: 0.28, dampingFraction: 0.72)) {
                // 单选语义：点哪颗就只选哪颗。
                states[activeQuestionIndex].selected = [approved ? 0 : 1]
            }
        } label: {
            Text(title)
                .font(ChatFont.font(15, weight: .semibold))
                .foregroundColor(selected ? CSSThemeVariables.accentFg() : CSSThemeVariables.textMain())
                .frame(maxWidth: .infinity, minHeight: 46)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(selected
                              ? (approved ? CSSThemeVariables.accent()
                                          : (isHighRisk ? CSSThemeVariables.warning() : CSSThemeVariables.optionBorder()))
                              : CSSThemeVariables.optionBg())
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(selected ? Color.clear : CSSThemeVariables.optionBorder(), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func optionsList(q: AskQuestion, currentState: QuestionAnswerState, isMulti: Bool) -> some View {
        VStack(spacing: 0) {
            // 素行选项：纯文字 + 细分隔线，选中行右端打勾（视频里的样式）
            ForEach(Array(q.options.enumerated()), id: \.offset) { optIdx, option in
                let isSelected = currentState.selected.contains(optIdx)
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.72)) {
                        toggleOption(questionIndex: activeQuestionIndex, optionIndex: optIdx, isMulti: isMulti)
                    }
                } label: {
                    HStack(spacing: 12) {
                        Text(option)
                            .font(ChatFont.font(16, weight: isSelected ? .semibold : .regular))
                            .foregroundColor(CSSThemeVariables.textMain())
                            .multilineTextAlignment(.leading)
                            .lineLimit(3)

                        Spacer(minLength: 8)

                        if isSelected {
                            Image(systemName: "checkmark")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(CSSThemeVariables.accent())
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                    .padding(.horizontal, 20)
                    .frame(minHeight: 52)
                    .contentShape(Rectangle())
                }
                .buttonStyle(AskRowButtonStyle())

                if optIdx < q.options.count - 1 {
                    hairline()
                }
            }

            // 自填行：同样一条素行，前面不再有铅笔图标；有字时右端打勾
            hairline()
            HStack(spacing: 10) {
                TextField("输入您的回答...", text: Binding(
                    get: {
                        activeQuestionIndex < states.count ? states[activeQuestionIndex].otherText : ""
                    },
                    set: { val in
                        if activeQuestionIndex < states.count {
                            states[activeQuestionIndex].otherText = val
                            if !val.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                if !isMulti {
                                    states[activeQuestionIndex].selected.removeAll()
                                }
                                states[activeQuestionIndex].otherSelected = true
                            }
                        }
                    }
                ))
                .font(ChatFont.font(15))
                .foregroundColor(CSSThemeVariables.textMain())
                .submitLabel(.send)
                .onSubmit {
                    if canSubmit && isSessionReady {
                        submit()
                    }
                }

                if !currentState.otherText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Image(systemName: "checkmark")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(CSSThemeVariables.accent())
                }
            }
            .padding(.horizontal, 20)
            .frame(minHeight: 52)
        }
    }

    /// 一条 1px 的主题分隔线（行与行之间，左端和文字对齐）。
    private func hairline() -> some View {
        Rectangle()
            .fill(CSSThemeVariables.divider())
            .frame(height: 1 / UIScreen.main.scale)
            .padding(.leading, 20)
    }

    private func toggleOption(questionIndex: Int, optionIndex: Int, isMulti: Bool) {
        guard questionIndex < states.count else { return }
        if isMulti {
            if states[questionIndex].selected.contains(optionIndex) {
                states[questionIndex].selected.remove(optionIndex)
            } else {
                states[questionIndex].selected.insert(optionIndex)
            }
        } else {
            states[questionIndex].selected = [optionIndex]
            states[questionIndex].otherSelected = false
            states[questionIndex].otherText = ""
        }
    }

    private func dismiss() {
        ToolSuspensionService.shared.respond(id: request.id, decision: .skipped)
    }

    private func submit() {
        guard let payload else { return }
        var answers: [String: Any] = [:]
        // 问答气泡用的展示文案，和 JSON 答案同一份逻辑算出来。
        var qaBubbles: [String] = []
        for (idx, q) in payload.questions.enumerated() {
            let st = idx < states.count ? states[idx] : QuestionAnswerState()
            let isMulti = q.type == "multi"
            if st.skipped {
                answers[q.id] = NSNull()
                qaBubbles.append("问：\(q.question)\n答：跳过")
                continue
            }
            let otherText = st.otherText.trimmingCharacters(in: .whitespacesAndNewlines)
            // [T-manual-phase2-3a] confirm 回 "approved"/"denied"/null，
            // 不是选项文字。模型那边只有 approved 才算授权。
            if q.isConfirm {
                if let first = st.selected.sorted().first {
                    let approved = first == 0
                    answers[q.id] = approved ? "approved" : "denied"
                    qaBubbles.append("问：\(q.question)\n答：\(approved ? "批准" : "拒绝")")
                } else {
                    answers[q.id] = NSNull()
                    qaBubbles.append("问：\(q.question)\n答：跳过")
                }
                continue
            }
            if isMulti {
                var picked = st.selected.sorted().compactMap { i in
                    i < q.options.count ? q.options[i] : nil
                }
                if !otherText.isEmpty { picked.append(otherText) }
                if picked.isEmpty {
                    answers[q.id] = NSNull()
                    qaBubbles.append("问：\(q.question)\n答：跳过")
                } else {
                    answers[q.id] = picked
                    qaBubbles.append("问：\(q.question)\n答：\(picked.joined(separator: "、"))")
                }
            } else {
                if !otherText.isEmpty {
                    answers[q.id] = otherText
                    qaBubbles.append("问：\(q.question)\n答：\(otherText)")
                } else if let first = st.selected.sorted().first, first < q.options.count {
                    answers[q.id] = q.options[first]
                    qaBubbles.append("问：\(q.question)\n答：\(q.options[first])")
                } else {
                    answers[q.id] = NSNull()
                    qaBubbles.append("问：\(q.question)\n答：跳过")
                }
            }
        }
        let json = (try? JSONSerialization.data(withJSONObject: answers, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        ToolSuspensionService.shared.respond(id: request.id, decision: .answered(json))
        // 问答气泡：提交后在对话里留一条"问：… 答：…"记录（视频里的样式）。
        // 先 respond 再挂气泡：恢复问询那条路里 respond 会同步调 resume()，
        // resume 按 messages.last 判继续方式，气泡不能抢在它前面。
        // 注意：气泡只进 UI，不进 agentHistory 也不落盘——答案本身已经
        // 以 tool_result 进了模型上下文和 DB；重进会话后气泡消失，
        // 工具块里的摘要还在。
        for bubble in qaBubbles {
            vm.messages.append(ChatMessage(role: .user, content: bubble, isQABubble: true))
        }
    }
}

/// 单题的作答状态
private struct QuestionAnswerState {
    var selected: Set<Int> = []
    var otherSelected = false
    var otherText = ""
    var skipped = false
}

extension View {
    func askUserDialog(vm: AIChatViewModel) -> some View {
        modifier(AskUserDialogModifier(vm: vm))
    }
}
