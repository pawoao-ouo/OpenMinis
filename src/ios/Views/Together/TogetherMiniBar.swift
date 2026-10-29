//
//  TogetherMiniBar.swift
//  MinisApp
//
//  Together capsule system: porcelain pill, deck card, and lyric curtain.
//
//  One capsule, three unified presentations:
//    pill    --tap pill content/vinyl--> deck
//    deck    --collapse--> pill | --lyric button/box--> curtain
//    deck    --open-panel button--> full Together panel
//    curtain --close button / swipe down--> deck (sheet dismiss)
//
//  Completely self-contained in TogetherMiniBar without touching AIChatView,
//  preventing SwiftUI type demangling depth issues and runtime stack overflows.
//

import SwiftUI

private func togetherMMSS(_ s: Double) -> String {
    let total = max(0, Int(s.rounded()))
    return String(format: "%02d:%02d", total / 60, total % 60)
}

// MARK: - Main Mini Bar (Pill / Deck Container)

enum TogetherCapsuleDockSide: String, Equatable {
    case left
    case right
}

struct TogetherMiniBar: View {

    /// The full stack height (48pt capsule + 2pt gap to the input bar).
    static let stackHeight: CGFloat = 50

    /// Open full Together panel.
    var onOpen: () -> Void = {}
    var sessionPersonaId: String? = nil

    @Environment(\.togetherPersonaId) private var envPersonaId
    @ObservedObject private var player = TogetherPlayer.shared
    @ObservedObject private var hub = TogetherStateHub.shared

    @State private var deckShown = false
    @State private var lyrics: TogetherLyrics?
    @State private var dockSide: TogetherCapsuleDockSide? = nil
    @State private var dockYOffset: CGFloat = 0
    @State private var dockDragX: CGFloat = 0
    @State private var dockDragY: CGFloat = 0
    @State private var pillDragX: CGFloat = 0
    @State private var isDraggingCapsule = false

    private let capsuleWidth: CGFloat = 242
    private let capsuleHeight: CGFloat = 48

    var body: some View {
        GeometryReader { geo in
            let totalW = geo.size.width
            let isDocked = dockSide != nil
            let leftEdgeOffset = -(totalW / 2 - 29)
            let rightEdgeOffset = (totalW / 2 - 29)

            let curOffsetX: CGFloat = {
                if let side = dockSide {
                    return (side == .left ? leftEdgeOffset : rightEdgeOffset) + dockDragX
                } else {
                    return pillDragX
                }
            }()
            let curOffsetY: CGFloat = isDocked ? (dockYOffset + dockDragY) : 0

            let currentWidth: CGFloat = isDocked ? 58 : capsuleWidth
            let currentHeight: CGFloat = isDocked ? 40 : capsuleHeight

            ZStack {
                ghostPreview(totalWidth: totalW)
                morphingCapsule(width: currentWidth, height: currentHeight, isDocked: isDocked)
                    .offset(x: curOffsetX, y: curOffsetY)
                    .gesture(activeGesture(totalWidth: totalW))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .frame(height: 50)
        .padding(.bottom, 2)
        .fullScreenCover(isPresented: $deckShown) {
            TogetherDeckOverlay(
                sessionPersonaId: sessionPersonaId ?? envPersonaId,
                onOpenPanel: onOpen
            ) {
                deckShown = false
            }
            .presentationBackground(.clear)
        }
        .onAppear { loadLyrics() }
        .onChange(of: player.track?.id) { _ in loadLyrics() }
    }

    private func morphingCapsule(width: CGFloat, height: CGFloat, isDocked: Bool) -> some View {
        ZStack {
            // Pill 完整内容：展开时居中，收进侧边时平滑渐隐且不换行变形
            // Crossfade 时序照 HTML：淡出 180ms，新内容延迟 70ms 淡入并由 0.94
            // 轻微放大回 1。尺寸 morph 仍走 withAnimation 里的 springPhysics。
            pillContent
                .opacity(isDocked ? 0 : 1)
                .scaleEffect(isDocked ? 0.94 : 1)
                .allowsHitTesting(!isDocked)
                .animation(isDocked ? .easeOut(duration: 0.18) : .easeIn(duration: 0.24).delay(0.07), value: isDocked)

            // Dock 悬浮球内容：贴靠侧边时柔和浮现
            dockIndicatorContent
                .opacity(isDocked ? 1 : 0)
                .scaleEffect(isDocked ? 1 : 0.94)
                .allowsHitTesting(isDocked)
                .animation(isDocked ? .easeIn(duration: 0.24).delay(0.07) : .easeOut(duration: 0.18), value: isDocked)
        }
        .frame(width: width, height: height)
        .background {
            ZStack {
                TogetherBlurBackdrop()
                TogetherSpec.capsuleSurface
            }
        }
        .clipShape(capsuleShape(for: dockSide))
        .overlay(
            capsuleShape(for: dockSide)
                .strokeBorder(TogetherSpec.capsuleBorder, lineWidth: 1)
        )
        .overlay(
            capsuleShape(for: dockSide)
                .strokeBorder(TogetherSpec.capsuleOuter, lineWidth: 1)
                .padding(-1)
        )
        .shadow(
            color: Color.black.opacity(isDocked ? 0.08 : 0.06),
            radius: isDocked ? 8 : 16,
            x: isDocked ? (dockSide == .left ? 2 : -2) : 0,
            y: isDocked ? 3 : 12
        )
        .shadow(
            color: Color.black.opacity(0.02),
            radius: isDocked ? 2 : 4,
            x: 0,
            y: 2
        )
        .contentShape(Rectangle())
        .onTapGesture {
            TogetherHaptics.select()
            if isDocked {
                withAnimation(TogetherCurve.springPhysics) {
                    dockSide = nil
                    dockYOffset = 0
                    dockDragX = 0
                    dockDragY = 0
                }
            } else {
                deckShown = true
            }
        }
    }

    private func capsuleShape(for side: TogetherCapsuleDockSide?) -> UnevenRoundedRectangle {
        switch side {
        case .left:
            return UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 20,
                topTrailingRadius: 20,
                style: .continuous
            )
        case .right:
            return UnevenRoundedRectangle(
                topLeadingRadius: 20,
                bottomLeadingRadius: 20,
                bottomTrailingRadius: 0,
                topTrailingRadius: 0,
                style: .continuous
            )
        case .none:
            return UnevenRoundedRectangle(
                topLeadingRadius: 24,
                bottomLeadingRadius: 24,
                bottomTrailingRadius: 24,
                topTrailingRadius: 24,
                style: .continuous
            )
        }
    }

    private func activeGesture(totalWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { val in
                isDraggingCapsule = true
                if dockSide != nil {
                    dockDragX = val.translation.width
                    dockDragY = val.translation.height
                } else {
                    pillDragX = val.translation.width
                }
            }
            .onEnded { val in
                isDraggingCapsule = false
                if let side = dockSide {
                    let totalX = val.translation.width
                    if (side == .left && totalX > 35) || (side == .right && totalX < -35) {
                        TogetherHaptics.select()
                        withAnimation(TogetherCurve.springPhysics) {
                            dockSide = nil
                            dockDragX = 0
                            dockDragY = 0
                            dockYOffset = 0
                        }
                    } else {
                        withAnimation(TogetherCurve.springPhysics) {
                            dockYOffset = max(-450, min(0, dockYOffset + val.translation.height))
                            dockDragX = 0
                            dockDragY = 0
                        }
                    }
                } else {
                    let w = val.translation.width
                    let v = val.predictedEndTranslation.width
                    // 中心点语义：胶囊静止时居中，松手时中心 = 条宽一半 + 平移量。
                    // 吸边判定读中心落点，不只读手指移动量。70pt 边缘区在当前
                    // 屏宽下已被 45pt 位移阈值包含，留作显式规则，不改行为。
                    // 速度继承如实说明：predictedEndTranslation 只是 SwiftUI 的
                    // 速度估计，不是松手真速度；Animation.spring 没有初速度参数，
                    // 本次不手写弹簧驱动器，仍用 TogetherCurve.springPhysics。
                    let releaseCenterX = totalWidth / 2 + w
                    let predictedCenterX = totalWidth / 2 + v
                    let crossedLeftEdgeZone = releaseCenterX < 70 || predictedCenterX < 70
                    let crossedRightEdgeZone = releaseCenterX > totalWidth - 70 || predictedCenterX > totalWidth - 70
                    if w < -45 || v < -80 || crossedLeftEdgeZone {
                        TogetherHaptics.select()
                        withAnimation(TogetherCurve.springPhysics) {
                            dockSide = .left
                            pillDragX = 0
                        }
                    } else if w > 45 || v > 80 || crossedRightEdgeZone {
                        TogetherHaptics.select()
                        withAnimation(TogetherCurve.springPhysics) {
                            dockSide = .right
                            pillDragX = 0
                        }
                    } else {
                        withAnimation(TogetherCurve.springPhysics) {
                            pillDragX = 0
                        }
                    }
                }
            }
    }

    // MARK: - Dock ghost preview (dragging only)

    /// 拖拽时最近边缘的 58x40 轮廓预览：只在未吸边拖拽中出现，
    /// 距边 140pt 内按接近程度淡入，松手即消失。抽成独立 helper，
    /// 不进 body 的类型推断链。
    private func ghostPreview(totalWidth: CGFloat) -> some View {
        Group {
            if isDraggingCapsule, dockSide == nil, let ghost = ghostState(totalWidth: totalWidth) {
                ghostCapsule(side: ghost.side)
                    .frame(width: 58, height: 40)
                    .offset(x: ghost.offsetX)
                    .opacity(ghost.opacity)
                    .allowsHitTesting(false)
            }
        }
    }

    private func ghostState(totalWidth: CGFloat) -> (side: TogetherCapsuleDockSide, offsetX: CGFloat, opacity: CGFloat)? {
        // 胶囊条占满聊天区宽度，条内中心 x 即屏幕方向的中心 x，
        // 不另做 global 帧上报（上报会比手势滞后一帧）。
        let centerX = totalWidth / 2 + pillDragX
        let edgeDistance = min(centerX, totalWidth - centerX)
        guard edgeDistance < 140 else { return nil }
        let side: TogetherCapsuleDockSide = centerX <= totalWidth / 2 ? .left : .right
        let offsetX = side == .left ? -(totalWidth / 2 - 29) : (totalWidth / 2 - 29)
        let opacity = max(0, min(1, 1 - edgeDistance / 140))
        return (side: side, offsetX: offsetX, opacity: opacity)
    }

    private func ghostCapsule(side: TogetherCapsuleDockSide) -> some View {
        ZStack {
            TogetherBlurBackdrop()
            Color.white.opacity(0.55)
        }
        .clipShape(capsuleShape(for: side))
        .overlay(
            capsuleShape(for: side)
                .strokeBorder(Color.white.opacity(0.9), lineWidth: 1)
        )
        .overlay(
            capsuleShape(for: side)
                .strokeBorder(TogetherSpec.capsuleOuter, lineWidth: 1)
                .padding(-1)
        )
        .shadow(color: .black.opacity(0.08), radius: 12, x: side == .left ? 2 : -2, y: 6)
    }

    private var dockIndicatorContent: some View {
        HStack(spacing: 6) {
            if dockSide == .left {
                dockVinylRing
                dockPulseBars
            } else {
                dockPulseBars
                dockVinylRing
            }
        }
        .padding(dockSide == .left ? EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 8) : EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 6))
        .frame(width: 58, height: 40)
    }

    private var dockVinylRing: some View {
        ZStack {
            Circle()
                .stroke(TogetherSpec.charcoal.opacity(0.12), lineWidth: 1.5)
            Circle()
                .trim(from: 0, to: max(0.01, min(1, progressRatio)))
                .stroke(TogetherSpec.charcoal, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            TogetherVinylDisc(size: 26, spinning: player.isPlaying)
        }
        .frame(width: 30, height: 30)
    }

    private var dockPulseBars: some View {
        TogetherEQLed(barCount: 2, active: player.isPlaying)
    }

    private var pillContent: some View {
        HStack(spacing: 10) {
            TogetherVinylDisc(size: 32, spinning: player.isPlaying)
                .contentShape(Circle())
                .onTapGesture { deckShown = true }

            marqueeBlock
                .contentShape(Rectangle())
                .onTapGesture { deckShown = true }

            TogetherEQLed(barCount: 3, active: player.isPlaying)

            Button {
                TogetherHaptics.tap()
                player.userToggle()
            } label: {
                ZStack {
                    Circle()
                        .fill(Color.white)
                        .overlay(Circle().strokeBorder(Color.black.opacity(0.08), lineWidth: 1))
                        .shadow(color: .black.opacity(0.06), radius: 3, x: 0, y: 2)
                    Image(systemName: player.showsPauseControl ? "pause.fill" : "play.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(TogetherSpec.charcoal)
                }
                .frame(width: 30, height: 30)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(player.showsPauseControl ? TogetherCopy.a11yPause : TogetherCopy.a11yPlay)
        }
        .padding(.horizontal, 10)
        .frame(width: capsuleWidth, height: capsuleHeight)
    }

    /// .pill-marquee：标题 14.5 衬线斜体 / 副行 11.5，高对比深炭黑，歌词清晰柔和
    /// 标题只在溢出时滚动（TogetherCapsuleMarqueeTitle），副行逻辑原样不动。
    private var marqueeBlock: some View {
        VStack(alignment: .leading, spacing: 1.5) {
            TogetherCapsuleMarqueeTitle(
                title: player.track?.title ?? TogetherCopy.title,
                isDragging: isDraggingCapsule
            )
            Text(subtitle)
                .font(ChatFont.font(11.5, weight: .medium))
                .tracking(0.2)
                .foregroundStyle(TogetherSpec.charcoal.opacity(0.85))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: 0.90),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
    }

    private var subtitle: String {
        if let lyr = lyrics, lyr.timed,
           let line = lyr.line(at: player.currentTime)?.text,
           !line.trimmingCharacters(in: .whitespaces).isEmpty {
            return line
        }
        if let id = player.track?.id, let loop = hub.state.loopLines[id],
           !loop.trimmingCharacters(in: .whitespaces).isEmpty {
            return loop
        }
        let artist = player.track?.artist ?? ""
        return artist.isEmpty ? TogetherCopy.title : artist
    }

    private var progressRatio: CGFloat {
        let d = max(player.duration, 1)
        return CGFloat(min(1, max(0, player.currentTime / d)))
    }

    private func loadLyrics() {
        lyrics = player.track.flatMap { TogetherStore.shared.lyrics(for: $0) }
    }
}

// MARK: - Capsule marquee title (scrolls only on overflow)

private struct TogetherMarqueeTextWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// 曲名跑马灯：只在标题宽于容器时滚动，短标题静止。
/// 量宽走 GeometryReader + PreferenceKey：测得的宽只决定
/// 是否滚动与滚动距离，不回填进被测文字自身的宽，不产生布局循环。
/// 拖拽与减动效时停止滚动（停在起点，不做半程冻结——SwiftUI 的
/// repeatForever 动画没有暂停接口，松手后从起点重滚）。
/// 速度约 28pt/s，时长按 HTML 夹在 6...20 秒。
private struct TogetherCapsuleMarqueeTitle: View {
    let title: String
    let isDragging: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var offset: CGFloat = 0
    @State private var isAnimating = false
    @State private var animatedDistance: CGFloat = 0

    private var shouldScroll: Bool {
        !reduceMotion && !isDragging && containerWidth > 0 && textWidth > containerWidth + 1
    }

    private var scrollDistance: CGFloat { textWidth + 28 }

    private var scrollDuration: Double {
        max(6, min(20, Double(scrollDistance) / 28))
    }

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 28) {
                marqueeLabel
                if shouldScroll {
                    marqueeLabel
                }
            }
            .offset(x: offset)
            .onAppear {
                containerWidth = proxy.size.width
            }
            .onChange(of: proxy.size.width) { newWidth in
                containerWidth = newWidth
                syncMarquee()
            }
            .onPreferenceChange(TogetherMarqueeTextWidthKey.self) { newWidth in
                textWidth = newWidth
                syncMarquee()
            }
            .onChange(of: title) { _ in
                stopMarquee()
                syncMarquee()
            }
            .onChange(of: shouldScroll) { _ in
                syncMarquee()
            }
            .onChange(of: isDragging) { _ in
                syncMarquee()
            }
        }
        .frame(height: 20, alignment: .leading)
        .clipped()
    }

    private var marqueeLabel: some View {
        Text(title)
            .font(ChatFont.font(14.5, weight: .semibold, design: .serif))
            .italic()
            .tracking(0.3)
            .foregroundStyle(TogetherSpec.charcoal)
            .lineLimit(1)
            .fixedSize()
            .background(
                GeometryReader { labelProxy in
                    Color.clear.preference(
                        key: TogetherMarqueeTextWidthKey.self,
                        value: labelProxy.size.width
                    )
                }
            )
    }

    private func syncMarquee() {
        guard shouldScroll else {
            stopMarquee()
            return
        }
        guard !isAnimating || abs(animatedDistance - scrollDistance) > 0.5 else { return }
        stopMarquee()
        animatedDistance = scrollDistance
        isAnimating = true
        withAnimation(.linear(duration: scrollDuration).repeatForever(autoreverses: false)) {
            offset = -scrollDistance
        }
    }

    private func stopMarquee() {
        guard isAnimating || offset != 0 else { return }
        isAnimating = false
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            offset = 0
        }
    }
}

// MARK: - Equalizer bars (decorative, playing only)

struct TogetherEQBars: View {
    let barCount: Int
    let isPlaying: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animate = false

    private let pattern: [CGFloat] = [13, 9, 12]

    var body: some View {
        HStack(alignment: .center, spacing: 2.5) {
            ForEach(0..<barCount, id: \.self) { i in
                Capsule()
                    .fill(CSSThemeVariables.textMain(scope: .chat))
                    .frame(width: 2, height: barHeight(i))
                    .opacity(isPlaying && !reduceMotion ? 0.85 : 0.35)
                    .animation(barAnimation(i), value: animate)
            }
        }
        .frame(height: 14)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { animate = isPlaying && !reduceMotion }
        .onChange(of: isPlaying) { playing in animate = playing && !reduceMotion }
        .onChange(of: reduceMotion) { reduced in animate = isPlaying && !reduced }
    }

    private func barHeight(_ i: Int) -> CGFloat {
        guard isPlaying, !reduceMotion, animate else { return 3 }
        return pattern[i % pattern.count]
    }

    private func barAnimation(_ i: Int) -> Animation {
        guard isPlaying, !reduceMotion else { return .easeOut(duration: 0.2) }
        let durations: [Double] = [0.55, 0.75, 0.65]
        return .easeInOut(duration: durations[i % durations.count])
            .repeatForever(autoreverses: true)
            .delay(Double(i) * 0.12)
    }
}

// MARK: - Refined vinyl (deck + pill)

private final class TogetherSpinAngle {
    var angle: Double = 0
}

private struct TogetherSpinRotationModifier: AnimatableModifier {
    var angle: Double
    var tracker: TogetherSpinAngle

    var animatableData: Double {
        get { angle }
        set {
            angle = newValue
            tracker.angle = newValue
        }
    }

    func body(content: Content) -> some View {
        content.rotationEffect(.degrees(angle))
    }
}

struct TogetherRefinedVinylView: View {
    let size: CGFloat
    let isPlaying: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spinning = false
    @State private var baseAngle: Double = 0
    @State private var spinTracker = TogetherSpinAngle()

    var body: some View {
        ZStack {
            rotatingGroup

            // Static rim + sheen: outside the rotating group
            Circle()
                .strokeBorder(Color.white.opacity(0.9), lineWidth: 1.5)
            Circle()
                .fill(
                    LinearGradient(
                        colors: [Color.white.opacity(0.35), Color.white.opacity(0.0),
                                 Color.white.opacity(0.15)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        }
        .frame(width: size, height: size)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { syncSpin() }
        .onChange(of: isPlaying) { _ in syncSpin() }
        .onChange(of: reduceMotion) { _ in syncSpin() }
    }

    private var rotatingGroup: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color(white: 0.55), Color(white: 0.3), Color(white: 0.16)],
                        center: .center,
                        startRadius: 1,
                        endRadius: size / 2
                    )
                )
            grooves
            hub
        }
        .frame(width: size, height: size)
        .modifier(
            TogetherSpinRotationModifier(
                angle: spinning ? baseAngle + 360 : baseAngle,
                tracker: spinTracker
            )
        )
        .animation(
            spinning ? .linear(duration: 7).repeatForever(autoreverses: false) : nil,
            value: spinning
        )
    }

    private var grooves: some View {
        ZStack {
            ForEach(1..<7, id: \.self) { i in
                Circle()
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(0.22), Color.black.opacity(0.12)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.8
                    )
                    .padding(size * 0.5 * CGFloat(i) / 7 * 0.94)
            }
        }
    }

    private var hub: some View {
        ZStack {
            Circle()
                .fill(.regularMaterial)
                .frame(width: size * 0.44, height: size * 0.44)
            Circle()
                .fill(CSSThemeVariables.textDim(scope: .chat))
                .frame(width: 3, height: 3)
                .offset(x: size * 0.13)
            Circle()
                .fill(Color.black.opacity(0.45))
                .frame(width: 5, height: 5)
        }
    }

    private func syncSpin() {
        if isPlaying, !reduceMotion {
            spinning = true
        } else if spinning {
            let frozen = spinTracker.angle.truncatingRemainder(dividingBy: 360)
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                baseAngle = frozen < 0 ? frozen + 360 : frozen
                spinning = false
            }
        }
    }
}

// MARK: - Deck (Expanded Card)

// MARK: - Deck overlay (floating card over blurred backdrop)

struct TogetherDeckOverlay: View {

    let sessionPersonaId: String?
    var onOpenPanel: () -> Void = {}
    var onClose: () -> Void = {}

    @State private var curtainShown = false

    var body: some View {
        GeometryReader { geo in
            let drawerHeight = geo.size.height * 0.82
            ZStack(alignment: .bottom) {
                Color.black.opacity(curtainShown ? 0.3 : 0.26)
                    .background(TogetherBlurBackdrop(style: .systemUltraThinMaterial))
                    .ignoresSafeArea()
                    .onTapGesture {
                        if curtainShown {
                            withAnimation(TogetherCurve.springPhysics) { curtainShown = false }
                        } else {
                            onClose()
                        }
                    }

                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    TogetherDeckView(
                        sessionPersonaId: sessionPersonaId,
                        onOpenPanel: {
                            onClose()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { onOpenPanel() }
                        },
                        onOpenCurtain: {
                            withAnimation(TogetherCurve.springPhysics) { curtainShown = true }
                        },
                        onCollapse: { onClose() }
                    )
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 15)

                // 82vh 固定抽屉：滑上来就不动，手指只滚歌词
                TogetherLyricDrawer(isPresented: $curtainShown, sessionPersonaId: sessionPersonaId)
                    .frame(height: drawerHeight)
                    .offset(y: curtainShown ? 0 : drawerHeight + 60)
                    .animation(TogetherCurve.springPhysics, value: curtainShown)
                    .allowsHitTesting(curtainShown)
            }
            .ignoresSafeArea(edges: .bottom)
        }
    }
}

struct TogetherDeckView: View {

    let sessionPersonaId: String?
    var onOpenPanel: () -> Void = {}
    var onOpenCurtain: () -> Void = {}
    var onCollapse: () -> Void = {}

    @ObservedObject private var player = TogetherPlayer.shared
    @ObservedObject private var hub = TogetherStateHub.shared

    @State private var lyrics: TogetherLyrics?
    @State private var thumbVisible = false
    @State private var dotPulse = false
    @State private var whisperIndex = 0

    @State private var whisperOpacity: Double = 1.0
    @State private var avatarScale: CGFloat = 1.0

    private let whispers: [String] = [
        "在听呢，手一直给你牵着。",
        "刚才这句词我也很喜欢。",
        "靠在我怀里慢慢听，别想别的。",
        "这首的前奏很舒服吧？",
        "心跳同频中 · 别光戳我，看歌词。",
        "温度刚好，窝着别乱动。",
        "今天想听多久，我都陪你挂机。",
        "不许摘耳机。我在呢。"
    ]

    private var state: TogetherState { hub.state }
    private var aiName: String { ChatAddressing.assistant(sessionPersonaId: sessionPersonaId) }

    var body: some View {
        VStack(spacing: 10) {
            header
            lyricBox
            progressSection
            controlsRow
            resonanceDock
        }
        .padding(EdgeInsets(top: 16, leading: 18, bottom: 14, trailing: 18))
        .frame(width: 360)
        .background {
            ZStack {
                TogetherBlurBackdrop()
                TogetherSpec.capsuleSurface
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(TogetherSpec.capsuleBorder, lineWidth: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(TogetherSpec.capsuleOuter, lineWidth: 1)
                .padding(-1)
        )
        .shadow(color: .black.opacity(0.12), radius: 28, x: 0, y: 26)
        .shadow(color: .black.opacity(0.04), radius: 10, x: 0, y: 6)
        .onAppear { loadLyrics() }
        .onChange(of: player.track?.id) { _ in loadLyrics() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            TogetherVinylDisc(size: 44, spinning: player.isPlaying)

            VStack(alignment: .leading, spacing: 0) {
                Text(player.track?.title ?? TogetherCopy.title)
                    .font(ChatFont.font(20, weight: .medium, design: .serif))
                    .italic()
                    .tracking(0.5)
                    .foregroundStyle(TogetherSpec.charcoal)
                    .lineLimit(1)
                    .truncationMode(.tail)
                artistRow
                    .padding(.top, 3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                deckIconButton(lines: 3, label: TogetherCopy.a11yOpenLyrics) {
                    onOpenCurtain()
                }
                deckIconButton(lines: 1, label: TogetherCopy.a11yCollapse) {
                    onCollapse()
                }
            }
        }
    }

    private var artistRow: some View {
        HStack(spacing: 8) {
            Text((player.track?.artist ?? "").uppercased())
                .font(ChatFont.font(10.5, design: .monospaced))
                .tracking(1)
                .foregroundStyle(TogetherSpec.sub)
                .lineLimit(1)
            silverBadge
        }
    }

    private var silverBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(TogetherSpec.charcoal)
                .frame(width: 3.5, height: 3.5)
                .opacity(dotPulse ? 1 : 0.3)
                .scaleEffect(dotPulse ? 1.3 : 0.8)
            Text("TOGETHER")
                .font(ChatFont.font(8.5, design: .monospaced))
                .tracking(0.6)
                .foregroundStyle(TogetherSpec.charcoal)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color.black.opacity(0.04)))
        .overlay(Capsule().strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5))
        .fixedSize()
        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: dotPulse)
        .onAppear { dotPulse = true }
        .accessibilityHidden(true)
    }

    /// .icon-btn 28×28 / r8 / 1px 描边 / 13pt 线稿
    private func deckIconButton(lines: Int, label: String, action: @escaping () -> Void) -> some View {
        Button {
            TogetherHaptics.select()
            action()
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.black.opacity(0.04))
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.06), lineWidth: 1)
                VStack(spacing: 3.6) {
                    ForEach(0..<lines, id: \.self) { _ in
                        Capsule()
                            .fill(TogetherSpec.sub)
                            .frame(width: 13, height: 1.4)
                    }
                }
            }
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    // MARK: Lyric box

    private var lyricBox: some View {
        Button {
            TogetherHaptics.select()
            onOpenCurtain()
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 8) {
                    Text(currentLyricText)
                        .font(ChatFont.font(16, weight: .medium, design: .serif))
                        .italic()
                        .tracking(0.4)
                        .lineSpacing(4)
                        .foregroundStyle(TogetherSpec.charcoal)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.up")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(TogetherSpec.sub)
                        .opacity(0.3)
                        .padding(.top, 4)
                }
                if let sub = subLyricText, !sub.isEmpty {
                    Text(sub)
                        .font(ChatFont.font(11))
                        .tracking(0.2)
                        .lineSpacing(2)
                        .foregroundStyle(TogetherSpec.muted)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 3)
                }
            }
            .padding(EdgeInsets(top: 11, leading: 14, bottom: 10, trailing: 14))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white.opacity(0.62))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.05), lineWidth: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(0.9), .clear],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: .black.opacity(0.02), radius: 4, x: 0, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(currentLyricText)
        .accessibilityHint(TogetherCopy.a11yOpenLyrics)
    }

    private var currentLyricText: String {
        if let lyr = lyrics, lyr.timed,
           let line = lyr.line(at: player.currentTime)?.text,
           !line.trimmingCharacters(in: .whitespaces).isEmpty {
            return "“\(line)”"
        }
        if let id = player.track?.id, let loop = state.loopLines[id],
           !loop.trimmingCharacters(in: .whitespaces).isEmpty {
            return "“\(loop)”"
        }
        return TogetherCopy.noLyrics
    }

    private var subLyricText: String? {
        if let lyr = lyrics, lyr.timed {
            let idx = lyr.index(at: player.currentTime)
            if idx >= 0, let next = lyr.nextLine(after: idx) {
                return next.text
            }
            return nil
        }
        if let id = player.track?.id, state.loopLines[id] != nil {
            return TogetherCopy.noLyricsHint
        }
        return nil
    }

    // MARK: Progress

    private var progressSection: some View {
        VStack(spacing: 2) {
            GeometryReader { geo in
                let width = geo.size.width
                let ratio = progressRatio
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.black.opacity(0.06))
                        .frame(height: 4)
                    Capsule()
                        .fill(TogetherSpec.charcoal)
                        .frame(width: max(0, width * ratio), height: 4)
                    Circle()
                        .fill(Color.white)
                        .overlay(Circle().strokeBorder(TogetherSpec.charcoal, lineWidth: 1.5))
                        .frame(width: 10, height: 10)
                        .shadow(color: .black.opacity(0.15), radius: 2, x: 0, y: 1)
                        .offset(x: max(0, min(width - 10, width * ratio - 5)))
                        .scaleEffect(thumbVisible ? 1 : 0.01)
                        .animation(.easeInOut(duration: 0.15), value: thumbVisible)
                }
                .frame(height: 16)
                .contentShape(Rectangle())
                .onTapGesture(coordinateSpace: .local) { point in
                    let r = min(1, max(0, point.x / max(width, 1)))
                    commitSeek(to: Double(r) * max(player.duration, 1))
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(TogetherCopy.progressLabel)
                .accessibilityValue("\(togetherMMSS(player.currentTime)) / \(togetherMMSS(player.duration))")
            }
            .frame(height: 16)

            HStack {
                Text(togetherMMSS(player.currentTime))
                Spacer()
                Text(togetherMMSS(player.duration))
            }
            .font(ChatFont.font(9.5, design: .monospaced))
            .tracking(0.5)
            .foregroundStyle(TogetherSpec.muted)
        }
    }

    private var progressRatio: CGFloat {
        let d = max(player.duration, 1)
        return CGFloat(min(1, max(0, player.currentTime / d)))
    }

    private func commitSeek(to target: Double) {
        player.seek(to: target)
        TogetherStore.shared.seek(to: target, by: .user)
        hub.refreshNow()
        TogetherHaptics.tap()
        thumbVisible = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { thumbVisible = false }
    }

    // MARK: Controls

    private var controlsRow: some View {
        HStack(spacing: 24) {
            Button {
                TogetherHaptics.select()
                player.previousTrack()
                hub.refreshNow()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(TogetherSpec.charcoal)
                    .opacity(0.65)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(TogetherCopy.a11yPrevious)

            Button {
                TogetherHaptics.tap()
                player.userToggle()
                hub.refreshNow()
            } label: {
                ZStack {
                    Circle()
                        .fill(TogetherSpec.charcoal)
                        .frame(width: 44, height: 44)
                        .shadow(color: .black.opacity(0.16), radius: 9, x: 0, y: 6)
                    Image(systemName: player.showsPauseControl ? "pause.fill" : "play.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(.white)
                }
                .frame(width: 44, height: 44)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(player.showsPauseControl ? TogetherCopy.a11yPause : TogetherCopy.a11yPlay)

            Button {
                TogetherHaptics.select()
                player.nextTrack()
                hub.refreshNow()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(TogetherSpec.charcoal)
                    .opacity(0.65)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(TogetherCopy.a11yNext)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Resonance dock

    private var resonanceDock: some View {
        Button {
            TogetherHaptics.tap()
            withAnimation(.easeOut(duration: 0.15)) {
                whisperOpacity = 0.2
                avatarScale = 1.15
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                whisperIndex = (whisperIndex + 1) % whispers.count
                withAnimation(.easeIn(duration: 0.2)) {
                    whisperOpacity = 1.0
                    avatarScale = 1.0
                }
            }
            hub.refreshNow()
        } label: {
            HStack(spacing: 0) {
                HStack(spacing: 8) {
                    resonanceAvatar
                        .scaleEffect(avatarScale)
                    Text(dockLine)
                        .font(ChatFont.font(11, weight: .medium))
                        .tracking(0.2)
                        .foregroundStyle(TogetherSpec.sub)
                        .opacity(whisperOpacity)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipped()

                Text("RESONANCE")
                    .font(ChatFont.font(8, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(TogetherSpec.muted)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(Color.black.opacity(0.1), lineWidth: 0.5)
                    )
                    .fixedSize()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.7))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.06), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(dockLine)
    }

    private var resonanceAvatar: some View {
        let iconRef = TogetherIdentity.aiIcon(sessionPersonaId: sessionPersonaId)
        let uiImage = iconRef.flatMap { SoulIconImage.decode($0) }
        return Group {
            if let img = uiImage {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Circle().fill(TogetherSpec.charcoal)
                    Text(String(aiName.prefix(1)))
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: 17, height: 17)
        .clipShape(Circle())
        .padding(1.5)
        .overlay(Circle().strokeBorder(Color.black.opacity(0.12), lineWidth: 1))
        .frame(width: 22, height: 22)
    }

    private var activeTimedNote: TogetherNote? {
        guard let trackId = player.track?.id else { return nil }
        let cur = player.currentTime
        // 查找当前曲目里在当前秒数（允许往前找最近10秒内）的最新留言
        return state.notes
            .filter { $0.trackId == trackId && $0.at <= cur && (cur - $0.at) <= 10 }
            .sorted { $0.at > $1.at }
            .first
    }

    private var dockLine: String {
        // 1. 优先展示曲目里在该时间点留下的专属互动/留言 (xx分xx秒刻字)
        if let note = activeTimedNote {
            let author = note.from == TogetherActor.ai.rawValue ? aiName : TogetherCopy.youDriving
            let mmss = togetherMMSS(note.at)
            return "\(author) [\(mmss)]：\(note.text)"
        }
        // 2. 其次展示双人/人设心动共振私语
        if let whisper = state.resonance?.whisper,
           !whisper.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "\(aiName)：\(whisper)"
        }
        // 3. 再次展示谁在掌控 / 你来带 / 心情词
        if let line = driverLineText, !line.isEmpty {
            return line
        }
        // 4. 轮换小梦陪伴情话
        return "\(aiName)：\(whispers[whisperIndex % whispers.count])"
    }

    private var driverLineText: String? {
        let mood = state.me.presence.mood?.word.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let by = state.playback.by
        let driverText: String? = by == TogetherActor.ai.rawValue ? TogetherCopy.driving(aiName)
            : by == TogetherActor.user.rawValue ? TogetherCopy.youDriving : nil
        if driverText == nil, mood.isEmpty { return nil }
        if let driverText, !mood.isEmpty { return "\(driverText) · \(mood)" }
        return driverText ?? mood
    }

    private func loadLyrics() {
        lyrics = player.track.flatMap { TogetherStore.shared.lyrics(for: $0) }
    }
}
// MARK: - Lyric drawer (82vh 固定抽屉，不可拖动)

struct TogetherLyricDrawer: View {
    @Binding var isPresented: Bool
    let sessionPersonaId: String?

    @ObservedObject private var player = TogetherPlayer.shared
    @ObservedObject private var hub = TogetherStateHub.shared

    @State private var lyrics: TogetherLyrics?
    @State private var followPaused = false

    private var timedLines: [TogetherLyricLine]? {
        guard let lyr = lyrics, lyr.timed, !lyr.lines.isEmpty else { return nil }
        return lyr.lines
    }

    private var currentIndex: Int {
        lyrics?.index(at: player.currentTime) ?? -1
    }

    private var curtainArtist: String {
        let artist = player.track?.artist ?? ""
        return artist.isEmpty ? TogetherCopy.title : "\(artist) · \(TogetherCopy.title)"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle()
                .fill(Color.black.opacity(0.06))
                .frame(height: 1)
                .padding(.bottom, 0)
            scrollArea
        }
        .padding(EdgeInsets(top: 24, leading: 24, bottom: 40, trailing: 24))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            ZStack {
                TogetherBlurBackdrop(style: .systemThinMaterialLight)
                Color.white.opacity(0.94)
            }
        }
        .clipShape(
            UnevenRoundedRectangle(
                topLeadingRadius: 32,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: 32,
                style: .continuous
            )
        )
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.black.opacity(0.08))
                .frame(height: 1)
        }
        .shadow(color: .black.opacity(0.12), radius: 30, x: 0, y: -20)
        .onAppear { loadLyrics() }
        .onChange(of: player.track?.id) { _ in loadLyrics() }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(player.track?.title ?? TogetherCopy.title)
                    .font(ChatFont.font(24, design: .serif))
                    .italic()
                    .tracking(0.6)
                    .foregroundStyle(TogetherSpec.charcoal)
                    .lineLimit(1)
                Text(curtainArtist.uppercased())
                    .font(ChatFont.font(11, design: .monospaced))
                    .tracking(1.5)
                    .foregroundStyle(TogetherSpec.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            Button {
                TogetherHaptics.select()
                isPresented = false
            } label: {
                ZStack {
                    Circle()
                        .fill(Color.black.opacity(0.04))
                        .overlay(Circle().strokeBorder(Color.black.opacity(0.08), lineWidth: 1))
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(TogetherSpec.sub)
                }
                .frame(width: 32, height: 32)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(TogetherCopy.a11yCloseLyrics)
        }
        .padding(.bottom, 20)
    }

    private var scrollArea: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    if let lines = timedLines {
                        ForEach(lines.indices, id: \.self) { idx in
                            lyricLine(text: lines[idx].text, active: idx == currentIndex, time: lines[idx].at)
                                .id(idx)
                        }
                    } else {
                        lyricLine(text: TogetherCopy.noLyrics, active: true, time: nil)
                        if let loop = loopLine {
                            lyricLine(text: "“\(loop)”", active: false, time: nil)
                        }
                    }
                }
                .padding(.top, 40)
                .padding(.bottom, 120)
            }
            .scrollDisabled(false)
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.15),
                        .init(color: .black, location: 0.85),
                        .init(color: .clear, location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .onChange(of: currentIndex) { idx in
                guard !followPaused, idx >= 0 else { return }
                withAnimation(.easeInOut(duration: 0.35)) {
                    proxy.scrollTo(idx, anchor: .center)
                }
            }
        }
    }

    private func lyricLine(text: String, active: Bool, time: Double?) -> some View {
        Button {
            guard let t = time else { return }
            TogetherHaptics.select()
            player.seek(to: t)
            TogetherStore.shared.seek(to: t, by: .user)
            hub.refreshNow()
        } label: {
            Text(text)
                .font(ChatFont.font(active ? 25 : 19, weight: active ? .medium : .regular, design: .serif))
                .italic(active)
                .tracking(0.4)
                .lineSpacing(6)
                .foregroundStyle(active ? TogetherSpec.charcoal : TogetherSpec.muted)
                .opacity(active ? 1 : 0.55)
                .scaleEffect(active ? 1.02 : 1, anchor: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 10)
                .animation(.easeInOut(duration: 0.35), value: active)
        }
        .buttonStyle(.plain)
    }

    private var loopLine: String? {
        guard let id = player.track?.id else { return nil }
        let loop = hub.state.loopLines[id]
        return loop?.trimmingCharacters(in: .whitespaces).isEmpty == false ? loop : nil
    }

    private func loadLyrics() {
        lyrics = player.track.flatMap { TogetherStore.shared.lyrics(for: $0) }
    }
}

// MARK: - Design Kit (merged for project target build)

//
//  TogetherCapsuleKit.swift
//  MinisApp
//
//  胶囊设计稿 1:1 零件库。数值全部照抄 胶囊设计稿.html，
//  不在这里做任何"审美判断"。
//


import UIKit

// MARK: - 变量（对应 html :root）

enum TogetherSpec {
    static let charcoal = Color(red: 0x18/255, green: 0x18/255, blue: 0x1b/255)
    static let sub      = Color(red: 0x52/255, green: 0x52/255, blue: 0x5b/255)
    static let muted    = Color(red: 0x8e/255, green: 0x8e/255, blue: 0x93/255)

    static let capsuleSurface = Color.white.opacity(0.85)
    static let capsuleBorder  = Color.white.opacity(0.95)
    static let capsuleOuter   = Color(red: 0x18/255, green: 0x18/255, blue: 0x1b/255).opacity(0.07)
}

/// 复刻苹果原生物理质感：高阻尼无震荡柔和弹簧，彻底消除残影与突兀抖动
enum TogetherCurve {
    static var springPhysics: Animation {
        .spring(response: 0.44, dampingFraction: 0.88, blendDuration: 0.1)
    }
    static var springPhysicsShort: Animation {
        .spring(response: 0.32, dampingFraction: 0.90, blendDuration: 0.08)
    }
}

// MARK: - backdrop-filter: blur() saturate()

struct TogetherBlurBackdrop: UIViewRepresentable {
    var style: UIBlurEffect.Style = .systemUltraThinMaterialLight

    func makeUIView(context: Context) -> UIVisualEffectView {
        let view = UIVisualEffectView(effect: UIBlurEffect(style: style))
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: UIVisualEffectView, context: Context) {
        uiView.effect = UIBlurEffect(style: style)
    }
}

// MARK: - 唱片（Boutique Ceramic Vinyl Disc）

struct TogetherVinylDisc: View {
    var size: CGFloat = 32
    var spinning: Bool = false

    @State private var angle: Double = 0

    private var label: CGFloat { size <= 32 ? 10 : 14 }
    private var ringWidth: CGFloat { size <= 32 ? 1.5 : 1.5 }

    var body: some View {
        ZStack {
            // 盘面：同心细纹 + 径向渐变
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color(red: 0x2e/255, green: 0x2e/255, blue: 0x33/255),
                            Color(red: 0x1c/255, green: 0x1c/255, blue: 0x1f/255),
                            Color(red: 0x2a/255, green: 0x2a/255, blue: 0x2e/255),
                            Color(red: 0x14/255, green: 0x14/255, blue: 0x17/255)
                        ],
                        center: .center,
                        startRadius: size * 0.1,
                        endRadius: size * 0.5
                    )
                )
            // 细纹
            ForEach(1..<6, id: \.self) { i in
                Circle()
                    .strokeBorder(Color.white.opacity(0.05), lineWidth: 0.6)
                    .frame(width: size * CGFloat(i) / 6.0, height: size * CGFloat(i) / 6.0)
            }
            // 中心标
            Circle()
                .fill(Color(red: 0xfa/255, green: 0xf8/255, blue: 0xf5/255))
                .frame(width: label, height: label)
                .overlay(
                    Circle().strokeBorder(Color(red: 0x1c/255, green: 0x1c/255, blue: 0x1f/255), lineWidth: 2)
                )
                .shadow(color: .black.opacity(0.4), radius: 1.5)
            // 油光
            Circle()
                .fill(
                    LinearGradient(
                        colors: [Color.white.opacity(0.4), .clear, Color.white.opacity(0.2)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        }
        .frame(width: size, height: size)
        .overlay(
            Circle().strokeBorder(Color.white.opacity(0.9), lineWidth: ringWidth)
        )
        .shadow(color: .black.opacity(0.18), radius: 5, x: 0, y: 3)
        .rotationEffect(.degrees(angle))
        .onAppear { spinIfNeeded() }
        .onChange(of: spinning) { _ in spinIfNeeded() }
    }

    private func spinIfNeeded() {
        if spinning {
            withAnimation(.linear(duration: 7).repeatForever(autoreverses: false)) {
                angle = angle.truncatingRemainder(dividingBy: 360) + 360
            }
        } else {
            withAnimation(.linear(duration: 0)) {
                angle = angle.truncatingRemainder(dividingBy: 360)
            }
        }
    }
}

// MARK: - 律动柱（.equalizer-bars / .eq-bar）

struct TogetherEQLed: View {
    var barCount: Int = 3
    var active: Bool

    /// 每根柱子的动画时长与延迟，照抄 CSS
    private let durations: [Double] = [0.75, 0.55, 0.8]
    private let delays: [Double] = [0.0, 0.2, 0.35]

    var body: some View {
        HStack(alignment: .center, spacing: 2.5) {
            ForEach(0..<barCount, id: \.self) { i in
                TogetherEQBar(
                    active: active,
                    duration: durations[i % durations.count],
                    delay: delays[i % delays.count]
                )
            }
        }
        .frame(height: 14)
        .padding(.trailing, 2)
        .animation(.easeInOut(duration: 0.2), value: active)
        .accessibilityHidden(true)
    }
}

private struct TogetherEQBar: View {
    var active: Bool
    var duration: Double
    var delay: Double

    @State private var up = false

    var body: some View {
        Capsule()
            .fill(TogetherSpec.charcoal)
            .frame(width: 2, height: (active && up) ? 13 : 3)
            .opacity((active && up) ? 0.9 : 0.3)
            .onAppear { run() }
            .onChange(of: active) { _ in run() }
    }

    private func run() {
        guard active else {
            withAnimation(.easeInOut(duration: 0.2)) { up = false }
            return
        }
        up = false
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard active else { return }
            withAnimation(.easeInOut(duration: duration).repeatForever(autoreverses: true)) {
                up = true
            }
        }
    }
}
