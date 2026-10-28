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
        VStack(spacing: 10) {
            header
            lyricBox
            progressSection
            controlsRow
            resonanceDock
        }
        .padding(EdgeInsets(top: 16, leading: 18, bottom: 14, trailing: 18))
        .frame(width: 360, alignment: .top)
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
            TogetherHaptics.select()
            whisperIndex = (whisperIndex + 1) % whispers.count
            hub.refreshNow()
        } label: {
            HStack(spacing: 0) {
                HStack(spacing: 8) {
                    resonanceAvatar
                    Text(dockLine)
                        .font(ChatFont.font(11))
                        .tracking(0.2)
                        .foregroundStyle(TogetherSpec.sub)
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

    private var dockLine: String {
        if let whisper = state.resonance?.whisper,
           !whisper.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "\(aiName)：\(whisper)"
        }
        if let line = driverLineText, !line.isEmpty {
            return line
        }
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
                        ForEach(Array(lines.enumerated()), id: \.offset) { idx, line in
                            lyricLine(text: line.text, active: idx == currentIndex, time: line.at)
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