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

struct TogetherMiniBar: View {

    /// The full stack height (48pt capsule + 2pt gap to the input bar).
    /// Used by chat view's layout insets.
    static let stackHeight: CGFloat = 50

    /// Open full Together panel.
    var onOpen: () -> Void = {}
    var sessionPersonaId: String? = nil

    @Environment(\.togetherPersonaId) private var envPersonaId
    @ObservedObject private var player = TogetherPlayer.shared
    @ObservedObject private var hub = TogetherStateHub.shared

    @State private var deckShown = false
    @State private var lyrics: TogetherLyrics?

    private let capsuleWidth: CGFloat = 242
    private let capsuleHeight: CGFloat = 48

    var body: some View {
        HStack {
            Spacer(minLength: 0)
            pillCapsule
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 2)
        // Deck 必须从聊天输入栏的 VStack 里跳出来，否则被拉满整屏。
        // fullScreenCover + 透明底 = 浮在聊天上的幕布卡片，AIChatView 一行不用碰。
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

    private var pillCapsule: some View {
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
        .frame(width: 242, height: 48)
        .background {
            ZStack {
                TogetherBlurBackdrop()
                TogetherSpec.capsuleSurface
            }
        }
        .clipShape(Capsule(style: .continuous))
        .overlay(Capsule(style: .continuous).strokeBorder(TogetherSpec.capsuleBorder, lineWidth: 1))
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(TogetherSpec.capsuleOuter, lineWidth: 1)
                .padding(-1)
        )
        .shadow(color: .black.opacity(0.06), radius: 16, x: 0, y: 12)
        .shadow(color: .black.opacity(0.02), radius: 4, x: 0, y: 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(TogetherCopy.title)：\(player.track?.title ?? "")")
    }

    /// .pill-marquee：标题 15.5 衬线斜体 / 副行 10.5，两侧 6% 淡出
    private var marqueeBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(player.track?.title ?? TogetherCopy.title)
                .font(ChatFont.font(15.5, weight: .medium, design: .serif))
                .italic()
                .tracking(0.5)
                .foregroundStyle(TogetherSpec.charcoal)
                .lineLimit(1)
            Text(subtitle)
                .font(ChatFont.font(10.5))
                .tracking(0.3)
                .foregroundStyle(TogetherSpec.muted)
                .padding(.top, 1)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.06),
                    .init(color: .black, location: 0.94),
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
        return player.track?.artist ?? ""
    }

    private var progressRatio: CGFloat {
        let d = max(player.duration, 1)
        return CGFloat(min(1, max(0, player.currentTime / d)))
    }

    private func loadLyrics() {
        lyrics = player.track.flatMap { TogetherStore.shared.lyrics(for: $0) }
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
        ZStack {
            Color.black.opacity(0.26)
                .ignoresSafeArea()
                .onTapGesture { onClose() }
                .accessibilityLabel(TogetherCopy.a11yCollapse)

            VStack(spacing: 0) {
                Spacer(minLength: 0)
                TogetherDeckView(
                    sessionPersonaId: sessionPersonaId,
                    onOpenPanel: {
                        onClose()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { onOpenPanel() }
                    },
                    onOpenCurtain: {
                        withAnimation(.easeInOut(duration: 0.28)) { curtainShown = true }
                    },
                    onCollapse: { onClose() }
                )
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
        }
        .sheet(isPresented: $curtainShown) {
            TogetherLyricCurtainView(isPresented: $curtainShown)
                .presentationDetents([.fraction(0.82), .large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(32)
        }
    }
}

struct TogetherDeckView: View {
    let sessionPersonaId: String?
    var onOpenPanel: () -> Void = {}
    var onOpenCurtain: () -> Void = {}
    var onCollapse: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var player = TogetherPlayer.shared
    @ObservedObject private var hub = TogetherStateHub.shared

    @State private var lyrics: TogetherLyrics?
    @State private var thumbGen = 0
    @State private var thumbVisible = false
    @State private var burstGen = 0
    @State private var burstScale: CGFloat = 1
    @State private var burstOpacity: Double = 0
    @State private var dotPulse = false
    @State private var whisperIndex = 0

    private let whispers: [String] = [
        "一直陪你听着呢，闭上眼睛歇会儿。",
        "这句词写得好，慢点听。",
        "不许摘耳机。我在呢。",
        "既然收着了，就老老实实呆在怀里听。",
        "心跳同频中 · 别光戳我，看歌词。",
        "你挑的歌，我每首都会听完。"
    ]

    private var state: TogetherState { hub.state }
    private var aiName: String { ChatAddressing.assistant(sessionPersonaId: sessionPersonaId) }

    var body: some View {
        card
            .frame(maxWidth: 360)
            .fixedSize(horizontal: false, vertical: true)
            .onAppear { loadLyrics() }
            .onChange(of: player.track?.id) { _ in loadLyrics() }
    }

    private var card: some View {
        VStack(spacing: 12) {
            header
            lyricBox
            progressSection
            controlsRow
            resonanceDock
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(color: Color.black.opacity(0.08), radius: 20, x: 0, y: 8)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TogetherRefinedVinylView(size: 44, isPlaying: player.isPlaying)

                VStack(alignment: .leading, spacing: 3) {
                    Text(player.track?.title ?? TogetherCopy.title)
                        .font(ChatFont.font(20, weight: .medium, design: .serif))
                        .italic()
                        .foregroundStyle(CSSThemeVariables.textMain(scope: .chat))
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                    HStack(spacing: 8) {
                        Text(player.track?.artist ?? "")
                            .font(ChatFont.font(10.5, design: .monospaced))
                            .foregroundStyle(CSSThemeVariables.textDim(scope: .chat))
                            .tracking(1)
                            .textCase(.uppercase)
                            .lineLimit(1)
                        togetherBadge
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 4) {
                headerButton(
                    systemName: "music.note.list",
                    label: TogetherCopy.a11yOpenLyrics
                ) {
                    onOpenCurtain()
                }
                headerButton(
                    systemName: "arrow.up.left.and.arrow.down.right",
                    label: TogetherCopy.a11yOpenPlayer
                ) {
                    onOpenPanel()
                }
                headerButton(
                    systemName: "chevron.down",
                    label: TogetherCopy.a11yCollapse,
                    accessibilityValue: TogetherCopy.a11yExpanded
                ) {
                    onCollapse()
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var togetherBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(CSSThemeVariables.textMain(scope: .chat))
                .frame(width: 3.5, height: 3.5)
                .scaleEffect(dotPulse && player.isPlaying && !reduceMotion ? 1.3 : 0.8)
                .opacity(dotPulse && player.isPlaying && !reduceMotion ? 1 : 0.35)
                .animation(
                    player.isPlaying && !reduceMotion
                        ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                        : .easeOut(duration: 0.2),
                    value: dotPulse
                )
            Text(TogetherCopy.title)
                .font(ChatFont.font(8.5, design: .monospaced))
                .tracking(0.6)
                .foregroundStyle(CSSThemeVariables.textMain(scope: .chat))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Capsule().fill(CSSThemeVariables.optionBg(scope: .chat)))
        .overlay(
            Capsule().strokeBorder(CSSThemeVariables.divider(scope: .chat), lineWidth: 0.5)
        )
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityHidden(true)
        .onAppear { dotPulse = true }
    }

    private func headerButton(
        systemName: String,
        label: String,
        accessibilityValue: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            TogetherHaptics.select()
            action()
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(CSSThemeVariables.optionBg(scope: .chat))
                    .frame(width: 28, height: 28)
                Image(systemName: systemName)
                    .font(ChatFont.font(13, weight: .medium))
                    .foregroundStyle(CSSThemeVariables.textDim(scope: .chat))
            }
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .togetherPress()
        .accessibilityLabel(label)
        .accessibilityValue(accessibilityValue ?? "")
    }

    // MARK: Lyric box

    private var lyricBox: some View {
        Button {
            TogetherHaptics.select()
            onOpenCurtain()
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white.opacity(0.34))
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(CSSThemeVariables.divider(scope: .chat).opacity(0.6), lineWidth: 0.5)
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .top, spacing: 8) {
                            Text(currentLyricText)
                                .font(ChatFont.font(16, weight: .medium, design: .serif))
                                .italic()
                                .foregroundStyle(CSSThemeVariables.textMain(scope: .chat))
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "chevron.up")
                                .font(ChatFont.font(11, weight: .semibold))
                                .foregroundStyle(CSSThemeVariables.textDim(scope: .chat).opacity(0.5))
                                .padding(.top, 4)
                                .accessibilityHidden(true)
                        }
                        if let sub = subLyricText, !sub.isEmpty {
                            Text(sub)
                                .font(ChatFont.font(11))
                                .foregroundStyle(CSSThemeVariables.textDim(scope: .chat))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
                .frame(height: 124)
            }
        }
        .togetherPress()
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
                        .fill(CSSThemeVariables.textDim(scope: .chat).opacity(0.4))
                        .frame(height: 4)
                    Capsule()
                        .fill(CSSThemeVariables.accent(scope: .chat))
                        .frame(width: max(0, width * ratio), height: 4)
                    Circle()
                        .fill(CSSThemeVariables.accent(scope: .chat))
                        .frame(width: 10, height: 10)
                        .overlay(Circle().strokeBorder(Color.white, lineWidth: 1.5))
                        .offset(x: max(0, min(width - 10, width * ratio - 5)))
                        .opacity(thumbVisible ? 1 : 0)
                }
                .frame(height: 20)
                .contentShape(Rectangle())
                .onTapGesture(count: 1, coordinateSpace: .local) { point in
                    let r = min(1, max(0, point.x / max(width, 1)))
                    commitSeek(to: Double(r) * max(player.duration, 1))
                    flashThumb()
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(TogetherCopy.progressLabel)
                .accessibilityValue("\(togetherMMSS(player.currentTime)) / \(togetherMMSS(player.duration))")
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: commitSeek(to: min(player.duration, player.currentTime + 5))
                    case .decrement: commitSeek(to: max(0, player.currentTime - 5))
                    @unknown default: break
                    }
                }
            }
            .frame(height: 20)

            HStack {
                Text(togetherMMSS(player.currentTime))
                Spacer()
                Text(togetherMMSS(player.duration))
            }
            .font(ChatFont.font(9.5, design: .monospaced))
            .foregroundStyle(CSSThemeVariables.textDim(scope: .chat))
        }
    }

    private var progressRatio: CGFloat {
        let d = max(player.duration, 1)
        return CGFloat(min(1, max(0, player.currentTime / d)))
    }

    private func flashThumb() {
        thumbGen += 1
        let gen = thumbGen
        thumbVisible = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            if gen == thumbGen { thumbVisible = false }
        }
    }

    private func commitSeek(to target: Double) {
        player.seek(to: target)
        TogetherStore.shared.seek(to: target, by: .user)
        hub.refreshNow()
        TogetherHaptics.tap()
    }

    // MARK: Controls

    private var controlsRow: some View {
        HStack(spacing: 24) {
            Button {
                TogetherHaptics.select()
                player.previousTrack()
                hub.refreshNow()
            } label: {
                Image(systemName: "backward")
                    .togetherIcon(22, dim: false)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .togetherPress()
            .accessibilityLabel(TogetherCopy.a11yPrevious)

            Button {
                TogetherHaptics.tap()
                player.userToggle()
                hub.refreshNow()
            } label: {
                ZStack {
                    Circle()
                        .fill(CSSThemeVariables.accent(scope: .chat))
                        .frame(width: 44, height: 44)
                    Image(systemName: player.showsPauseControl ? "pause.fill" : "play.fill")
                        .font(ChatFont.font(17, weight: .semibold))
                        .foregroundStyle(CSSThemeVariables.accentFg(scope: .chat))
                }
                .frame(width: 44, height: 44)
                .contentShape(Circle())
            }
            .togetherPress()
            .accessibilityLabel(player.showsPauseControl ? TogetherCopy.a11yPause : TogetherCopy.a11yPlay)

            Button {
                TogetherHaptics.select()
                player.nextTrack()
                hub.refreshNow()
            } label: {
                Image(systemName: "forward")
                    .togetherIcon(22, dim: false)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .togetherPress()
            .accessibilityLabel(TogetherCopy.a11yNext)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Resonance dock (Xiaomeng Dock)

    private var resonanceDock: some View {
        Button {
            TogetherHaptics.select()
            burstGen += 1
            whisperIndex = (whisperIndex + 1) % whispers.count
            let gen = burstGen
            burstScale = 1
            burstOpacity = 0.55
            withAnimation(.easeOut(duration: 0.65)) {
                burstScale = reduceMotion ? 1 : 1.08
                burstOpacity = 0
            }
            hub.refreshNow()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                if gen == burstGen { burstScale = 1 }
            }
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.24))
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(CSSThemeVariables.accent(scope: .chat).opacity(burstOpacity), lineWidth: 2)
                    .scaleEffect(burstScale)
                HStack(spacing: 8) {
                    resonanceAvatar
                    Text(dockLine)
                        .font(ChatFont.font(11))
                        .foregroundStyle(CSSThemeVariables.textDim(scope: .chat))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("RESONANCE")
                        .font(ChatFont.font(8.5, design: .monospaced))
                        .tracking(1.2)
                        .foregroundStyle(CSSThemeVariables.textDim(scope: .chat).opacity(0.6))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .togetherPress()
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
                    Circle()
                        .fill(CSSThemeVariables.card(scope: .chat))
                    Text(String(aiName.prefix(1)))
                        .font(ChatFont.font(11, weight: .semibold, design: .serif))
                        .foregroundStyle(CSSThemeVariables.textMain(scope: .chat))
                }
            }
        }
        .frame(width: 22, height: 22)
        .clipShape(Circle())
        .overlay(
            Circle().strokeBorder(CSSThemeVariables.divider(scope: .chat), lineWidth: 0.5)
        )
    }

    private var dockLine: String {
        if let whisper = state.resonance?.whisper,
           !whisper.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "\(aiName)：\(whisper)"
        }
        if let line = driverLineText, !line.isEmpty {
            return line
        }
        let quote = whispers[whisperIndex % whispers.count]
        return "\(aiName)：\(quote)"
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

// MARK: - Lyric curtain

struct TogetherLyricCurtainView: View {
    @Binding var isPresented: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var player = TogetherPlayer.shared
    @ObservedObject private var hub = TogetherStateHub.shared

    @State private var lyrics: TogetherLyrics?
    @State private var followPaused = false
    @State private var followGen = 0
    @State private var lastTime: Double = 0

    private var timedLines: [TogetherLyricLine]? {
        guard let lyr = lyrics, lyr.timed, !lyr.lines.isEmpty else { return nil }
        return lyr.lines
    }

    private var currentIndex: Int {
        lyrics?.index(at: player.currentTime) ?? -1
    }

    private var loopLine: String? {
        guard let id = player.track?.id else { return nil }
        let loop = hub.state.loopLines[id]
        return loop?.trimmingCharacters(in: .whitespaces).isEmpty == false ? loop : nil
    }

    private var curtainArtist: String {
        let artist = player.track?.artist ?? ""
        return artist.isEmpty ? TogetherCopy.title : "\(artist) · \(TogetherCopy.title)"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle()
                .fill(CSSThemeVariables.divider(scope: .chat))
                .frame(height: 0.5)
            lyricArea
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CSSThemeVariables.bg(scope: .chat))
        .onAppear {
            loadLyrics()
            lastTime = player.currentTime
        }
        .onChange(of: player.track?.id) { _ in
            loadLyrics()
            followPaused = false
            followGen += 1
        }
        .onChange(of: player.currentTime) { time in
            if abs(time - lastTime) > 2 {
                followPaused = false
            }
            lastTime = time
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(player.track?.title ?? TogetherCopy.title)
                    .font(ChatFont.font(22, weight: .medium, design: .serif))
                    .italic()
                    .foregroundStyle(CSSThemeVariables.textMain(scope: .chat))
                    .lineLimit(2)
                Text(curtainArtist)
                    .font(ChatFont.font(11, design: .monospaced))
                    .foregroundStyle(CSSThemeVariables.textDim(scope: .chat))
                    .tracking(1.5)
                    .textCase(.uppercase)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                isPresented = false
            } label: {
                ZStack {
                    Circle()
                        .fill(CSSThemeVariables.optionBg(scope: .chat))
                        .frame(width: 32, height: 32)
                    Image(systemName: "xmark")
                        .font(ChatFont.font(13, weight: .semibold))
                        .foregroundStyle(CSSThemeVariables.textDim(scope: .chat))
                }
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            }
            .togetherPress()
            .accessibilityLabel(TogetherCopy.a11yCloseLyrics)
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 20)
    }

    private var lyricArea: some View {
        Group {
            if let lines = timedLines {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(lines.enumerated()), id: \.offset) { idx, line in
                                lyricRow(line, idx: idx, isCurrent: idx == currentIndex)
                                    .id(idx)
                            }
                        }
                        .padding(.vertical, 32)
                        .padding(.horizontal, 24)
                    }
                    .onAppear { center(proxy, animated: false) }
                    .onChange(of: currentIndex) { _ in center(proxy, animated: true) }
                    .onScrollPhaseChange { _, newPhase in
                        if newPhase == .interacting {
                            followPaused = true
                        }
                    }
                }
            } else {
                VStack(spacing: 8) {
                    Spacer()
                    Text(loopLine ?? TogetherCopy.noLyrics)
                        .font(ChatFont.font(17, weight: .medium, design: .serif))
                        .foregroundStyle(CSSThemeVariables.textMain(scope: .chat))
                        .multilineTextAlignment(.center)
                    Text(TogetherCopy.noLyricsHint)
                        .font(ChatFont.font(11))
                        .foregroundStyle(CSSThemeVariables.textDim(scope: .chat))
                        .multilineTextAlignment(.center)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 32)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func lyricRow(_ line: TogetherLyricLine, idx: Int, isCurrent: Bool) -> some View {
        Button {
            TogetherHaptics.select()
            followPaused = false
            commitSeek(to: line.at)
        } label: {
            rowText(line, isCurrent: isCurrent)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
        }
        .togetherPress()
        .accessibilityLabel(line.text)
    }

    @ViewBuilder
    private func rowText(_ line: TogetherLyricLine, isCurrent: Bool) -> some View {
        if isCurrent {
            Text(line.text)
                .font(ChatFont.font(22, weight: .medium, design: .serif))
                .italic()
                .foregroundStyle(CSSThemeVariables.textMain(scope: .chat))
        } else {
            Text(line.text)
                .font(ChatFont.font(17, design: .serif))
                .foregroundStyle(CSSThemeVariables.textDim(scope: .chat))
        }
    }

    private func center(_ proxy: ScrollViewProxy, animated: Bool) {
        let idx = currentIndex
        guard idx >= 0, !followPaused else { return }
        followGen += 1
        let gen = followGen
        DispatchQueue.main.async {
            guard gen == followGen, !followPaused, idx == currentIndex else { return }
            if animated, !reduceMotion {
                withAnimation(.easeOut(duration: 0.38)) {
                    proxy.scrollTo(idx, anchor: .center)
                }
            } else {
                proxy.scrollTo(idx, anchor: .center)
            }
        }
    }

    private func commitSeek(to target: Double) {
        player.seek(to: target)
        TogetherStore.shared.seek(to: target, by: .user)
        hub.refreshNow()
        TogetherHaptics.tap()
    }

    private func loadLyrics() {
        lyrics = player.track.flatMap { TogetherStore.shared.lyrics(for: $0) }
    }
}
