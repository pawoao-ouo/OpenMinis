//
//  TogetherMiniBar.swift
//  MinisApp
//
//  Together capsule system: pill, deck, docked ball, lyric curtain.
//
//  One capsule, three presentations, one transition map:
//    pill   --tap pill content/vinyl--> deck
//    deck   --collapse--> pill | --minimize--> ball | --lyric button/box--> curtain
//    ball   --tap--> deck | --drag inward past 60pt--> pill | --drag release near an edge--> ball (that edge)
//    curtain --close button / backdrop tap--> deck (the deck underneath stays put)
//    deck   --open-panel button--> full Together panel (chat menu entry still works too)
//  The pill stays mounted above the input bar while the deck is open, and
//  togetherBarInset stays at stackHeight, so opening the deck never moves
//  the chat list. While docked, the pill is hidden and the inset is 0.
//
//  The deck has NO drag gesture and the curtain has NO drag gesture; the
//  ball alone keeps drag + edge snap. Nothing here posts notifications,
//  touches TogetherStore locking, or invents state: every readout and
//  every control reads/writes the existing TogetherPlayer /
//  TogetherStateHub / TogetherStore paths, exactly as TogetherPanelView
//  does. The persona name and avatar come from the session persona via
//  ChatAddressing / TogetherIdentity (Soul metadata); no name or avatar
//  is hardcoded anywhere in this file.
//

import SwiftUI

/// Which edge the capsule is docked to.
enum TogetherCapsuleDockSide: Equatable {
    case left, right
}

/// Capsule presentation. Presentation state only (no persistence, no
/// state.json field): it lives in the chat view and resets to pill when
/// the app restarts or the full panel opens.
enum TogetherCapsulePresentation: Equatable {
    case pill
    case deck
    case docked(TogetherCapsuleDockSide)

    var isDocked: Bool {
        if case .docked = self { return true }
        return false
    }

    var dockSide: TogetherCapsuleDockSide? {
        if case let .docked(side) = self { return side }
        return nil
    }
}

private func togetherMMSS(_ s: Double) -> String {
    let total = max(0, Int(s.rounded()))
    return String(format: "%02d:%02d", total / 60, total % 60)
}

// MARK: - Pill

struct TogetherMiniBar: View {

    /// The full stack height (48pt capsule + 2pt gap to the input bar).
    /// The chat view's message list, floating buttons, and popup all take
    /// their inset from this one number; change the capsule height only
    /// here.
    static let stackHeight: CGFloat = 50

    @Binding var presentation: TogetherCapsulePresentation

    @ObservedObject private var player = TogetherPlayer.shared
    @ObservedObject private var hub = TogetherStateHub.shared

    /// Current track's lyrics: read once per track change, never polled.
    @State private var lyrics: TogetherLyrics?

    private let capsuleHeight: CGFloat = 48

    var body: some View {
        HStack(spacing: 4) {
            openButton

            Button {
                TogetherHaptics.tap()
                player.userToggle()
            } label: {
                Image(systemName: player.showsPauseControl ? "pause.fill" : "play.fill")
                    .font(ChatFont.font(15, weight: .semibold))
                    .foregroundStyle(CSSThemeVariables.textMain(scope: .chat))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .togetherPress()
            .accessibilityLabel(player.showsPauseControl ? TogetherCopy.a11yPause : TogetherCopy.a11yPlay)

            Button {
                TogetherHaptics.select()
                player.nextTrack()
            } label: {
                Image(systemName: "forward.fill")
                    .font(ChatFont.font(14, weight: .medium))
                    .foregroundStyle(CSSThemeVariables.textMain(scope: .chat))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .togetherPress()
            .accessibilityLabel(TogetherCopy.a11yNext)
        }
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .frame(height: capsuleHeight)
        .frame(maxWidth: .infinity)
        // System glass capsule: same language as the panel tab bar.
        // One glass element only, no container glass, no shadow.
        .glassEffect(.regular.interactive(), in: .capsule)
        .overlay(alignment: .bottom) { progressBar }
        .padding(.horizontal, 16)
        .onAppear { loadLyrics() }
        .onChange(of: player.track?.id) { _ in loadLyrics() }
    }

    /// Open area: one sibling Button whose label fills the full height
    /// and the full width up to the transport cluster. The Spacer lives
    /// INSIDE the label, so there is no dead band between the text and
    /// the play button. Tap opens the deck, never the full panel.
    private var openButton: some View {
        Button {
            TogetherHaptics.select()
            withAnimation(.easeInOut(duration: 0.28)) {
                presentation = .deck
            }
        } label: {
            HStack(spacing: 10) {
                miniVinyl

                VStack(alignment: .leading, spacing: 2) {
                    Text(player.track?.title ?? TogetherCopy.title)
                        .font(ChatFont.font(13, weight: .semibold))
                        .foregroundStyle(CSSThemeVariables.textMain(scope: .chat))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(ChatFont.font(11))
                        .foregroundStyle(CSSThemeVariables.textDim(scope: .chat))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Spacer(minLength: 0)

                TogetherEQBars(barCount: 3, isPlaying: player.isPlaying)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .togetherPress()
        .accessibilityLabel("\(TogetherCopy.title): \(player.track?.title ?? "")")
        .accessibilityValue(presentation == .pill ? TogetherCopy.a11yCollapsed : TogetherCopy.a11yExpanded)
    }

    /// Static small vinyl: neutral grey, never spins, never takes a theme
    /// colour. The pill is a glanceable strip; only the deck vinyl spins.
    private var miniVinyl: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color(white: 0.55), Color(white: 0.3), Color(white: 0.16)],
                        center: .center,
                        startRadius: 1,
                        endRadius: 12
                    )
                )
            Circle()
                .fill(Color(white: 0.12))
                .frame(width: 7, height: 7)
        }
        .frame(width: 24, height: 24)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Second line: the lyric line being sung, else the loop line, else
    /// the artist. The title always stays on the first line.
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

    /// Bottom hairline: progress display only, no gesture (scrubbing
    /// lives in the deck progress bar and the full panel).
    private var progressBar: some View {
        GeometryReader { geo in
            Capsule()
                .fill(CSSThemeVariables.accent(scope: .chat).opacity(0.6))
                .frame(width: max(0, (geo.size.width - 48) * progressRatio), height: 2)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(.leading, 24)
                .padding(.bottom, 4)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
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

/// Small pulse bars. They animate only while playing; paused (or Reduce
/// Motion) they sit still at minimum height. Never a TimelineView: one
/// repeating animation per bar, driven by the playing flag.
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

// MARK: - Refined vinyl (deck + ball)

/// Porcelain-hub vinyl with grooves. The grooves and hub rotate as one
/// group while playing (7s linear); the sheen overlay stays static so a
/// pause never has to unwind a gradient. Rotation is a single repeating
/// animation toggled by the playing flag — never a TimelineView tick.
/// Pausing freezes by snapping the (near-symmetric) disc to its rest
/// angle with animations disabled for that one transition; the grooves
/// are concentric, so the snap reads as the disc stopping, not jumping.
struct TogetherRefinedVinylView: View {
    let size: CGFloat
    let isPlaying: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spinning = false

    var body: some View {
        ZStack {
            rotatingGroup

            // Static rim + sheen: outside the rotating group on purpose.
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
        .rotationEffect(.degrees(spinning ? 360 : 0))
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

    /// Porcelain hub: system material disc, centre hole, and one small
    /// offset mark so the spin is perceptible.
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
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { spinning = false }
        }
    }
}

// MARK: - Deck (medium card)

/// The expanded card. Fixed and centred within the safe area, intrinsic
/// height (never fixed), no drag gesture at all. The pill underneath
/// stays mounted, so opening or closing the deck never shifts the chat.
struct TogetherDeckView: View {
    @Binding var presentation: TogetherCapsulePresentation
    @Binding var curtainShown: Bool
    /// Session persona id for the dynamic name/avatar; nil falls back to
    /// the global current persona, exactly as the full panel does.
    let sessionPersonaId: String?
    /// Side the minimize button docks to (the ball's last docked side).
    let dockSide: TogetherCapsuleDockSide
    var onOpenPanel: () -> Void = {}

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

    private var state: TogetherState { hub.state }
    private var aiName: String { ChatAddressing.assistant(sessionPersonaId: sessionPersonaId) }

    var body: some View {
        GeometryReader { geo in
            let safe = geo.safeAreaInsets
            let centerY = safe.top + (geo.size.height - safe.top - safe.bottom) / 2
            card
                .frame(width: min(360, max(0, geo.size.width - 32)))
                .frame(maxHeight: geo.size.height * 0.6)
                .position(x: geo.size.width / 2, y: centerY)
        }
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
    }

    // MARK: Header

    private var header: some View {
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

            HStack(spacing: 2) {
                headerButton(
                    systemName: "music.note.list",
                    label: TogetherCopy.a11yOpenLyrics
                ) {
                    withAnimation(.easeInOut(duration: 0.28)) { curtainShown = true }
                }
                headerButton(
                    systemName: "arrow.up.left.and.arrow.down.right",
                    label: TogetherCopy.a11yOpenPlayer
                ) {
                    onOpenPanel()
                }
                headerButton(
                    systemName: "arrow.down.right.and.arrow.up.left",
                    label: TogetherCopy.a11yMinimize
                ) {
                    withAnimation(.easeInOut(duration: 0.28)) {
                        presentation = .docked(dockSide)
                    }
                }
                headerButton(
                    systemName: "chevron.down",
                    label: TogetherCopy.a11yCollapse,
                    accessibilityValue: TogetherCopy.a11yExpanded
                ) {
                    withAnimation(.easeInOut(duration: 0.28)) {
                        presentation = .pill
                    }
                }
            }
        }
    }

    /// Pulsing-dot TOGETHER badge. Decorative: presence itself is carried
    /// by the resonance dock line below, which VoiceOver reads.
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

    /// Current lyric, wrapping onto as many lines as it needs — no fixed
    /// height, no line limit, no truncation. The box grows the deck
    /// intrinsically (scrolling internally only past 160pt, so the
    /// controls below can never be pushed off the card).
    private var lyricBox: some View {
        Button {
            TogetherHaptics.select()
            withAnimation(.easeInOut(duration: 0.28)) { curtainShown = true }
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(CSSThemeVariables.optionBg(scope: .chat))
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
                .frame(maxHeight: 160)
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
            return line
        }
        if let id = player.track?.id, let loop = state.loopLines[id],
           !loop.trimmingCharacters(in: .whitespaces).isEmpty {
            return loop
        }
        return TogetherCopy.noLyrics
    }

    /// The next timed line (in bilingual LRC files this is usually the
    /// translation of the current line). When there is no timed lyric
    /// but a loop line exists, the hint under it instead.
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

    /// One seek path, shared with the panel and the lyric curtain: local
    /// player seek + shared-state seek (the AI can see the jump) + hub
    /// refresh. No duplicated seek logic, no new write path.
    private func commitSeek(to target: Double) {
        player.seek(to: target)
        TogetherStore.shared.seek(to: target, by: .user)
        hub.refreshNow()
        TogetherHaptics.tap()
    }

    // MARK: Controls

    private var controlsRow: some View {
        HStack(spacing: 24) {
            // Previous: the SAME handler the panel uses (3-second rule
            // lives in TogetherPlayer.skipTrack; nothing is duplicated
            // here and TogetherPlayer is not modified).
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

    // MARK: Resonance dock

    /// The resonance dock. The line is read-only real state: the stored
    /// resonance whisper when one exists (written by the panel heartbeat
    /// or the AI), else the driver + mood line from hub state, else the
    /// artist. Tapping gives haptic + ripple + a hub re-read (so a
    /// whisper that landed meanwhile shows up); it writes nothing, posts
    /// nothing to chat, and invents no text.
    private var resonanceDock: some View {
        Button {
            TogetherHaptics.select()
            burstGen += 1
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
                    .fill(CSSThemeVariables.optionBg(scope: .chat))
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(CSSThemeVariables.accent(scope: .chat).opacity(burstOpacity), lineWidth: 2)
                    .scaleEffect(burstScale)
                HStack(spacing: 8) {
                    PersonaAvatarView(
                        iconRef: TogetherIdentity.aiIcon(sessionPersonaId: sessionPersonaId),
                        size: 22
                    )
                    .overlay(
                        Circle().strokeBorder(CSSThemeVariables.divider(scope: .chat), lineWidth: 0.5)
                    )
                    Text(dockLine)
                        .font(ChatFont.font(11))
                        .foregroundStyle(CSSThemeVariables.textDim(scope: .chat))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .togetherPress()
        .accessibilityLabel(dockLine)
    }

    private var dockLine: String {
        if let whisper = state.resonance?.whisper,
           !whisper.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return whisper
        }
        if let line = driverLineText, !line.isEmpty {
            return line
        }
        return player.track?.artist ?? ""
    }

    /// Driver + mood, the same line the panel shows under the duo header:
    /// who is driving, plus his mood word when he left one. Nothing is
    /// defaulted: no driver and no mood means no line.
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

// MARK: - Docked ball

/// The minimized orb: a 52x38 docked tab at a screen edge with the
/// refined vinyl (grooves, porcelain hub), a thin progress ring, and
/// pulse bars. The ONLY capsule surface with a drag gesture: drag
/// repositions it, release near an edge docks it, dragging inward past
/// 60pt undocks back to the pill. Tap opens the deck. While a track
/// exists and the panel is closed, the ball stays mounted with this
/// tap-to-expand path, so it can never strand the user.
struct TogetherDockedBallView: View {
    @Binding var presentation: TogetherCapsulePresentation
    @Binding var dockSide: TogetherCapsuleDockSide
    @Binding var yOffset: CGFloat
    /// Space to keep clear at the bottom (input bar + floating buttons).
    let bottomClearance: CGFloat

    @ObservedObject private var player = TogetherPlayer.shared

    @State private var dragOffset: CGSize = .zero
    @State private var isDragging = false

    var body: some View {
        GeometryReader { geo in
            let side = presentation.dockSide ?? dockSide
            let safe = geo.safeAreaInsets
            let anchorX = side == .left
                ? safe.leading + 26
                : geo.size.width - safe.trailing - 26
            let anchorY = safe.top + (geo.size.height - safe.top - safe.bottom) * 0.45
            let minY = safe.top + 22
            let maxY = max(minY, geo.size.height - safe.bottom - bottomClearance - 22)
            let minX = safe.leading + 26
            let maxX = max(minX, geo.size.width - safe.trailing - 26)
            let centerX = min(max(minX, anchorX + dragOffset.width), maxX)
            let centerY = min(max(minY, anchorY + yOffset + dragOffset.height), maxY)
            ballContent(side: side)
                .frame(width: 52, height: 44)
                .position(x: centerX, y: centerY)
                .gesture(ballDrag(
                    geo: geo, side: side,
                    anchorX: anchorX, anchorY: anchorY,
                    minY: minY, maxY: maxY
                ))
        }
    }

    private func ballContent(side: TogetherCapsuleDockSide) -> some View {
        ZStack {
            HStack(spacing: 6) {
                progressRingVinyl
                TogetherEQBars(barCount: 2, isPlaying: player.isPlaying)
            }
            .padding(.horizontal, 6)
        }
        .frame(width: 52, height: 38)
        .glassEffect(
            .regular.interactive(),
            in: ballShape(side: side, dragging: isDragging)
        )
        .contentShape(Rectangle())
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("\(TogetherCopy.a11yExpandCapsule), \(player.track?.title ?? TogetherCopy.title)")
        .accessibilityAction {
            withAnimation(.easeInOut(duration: 0.28)) { presentation = .deck }
        }
    }

    /// Flat on the docked edge, fully rounded while dragging.
    private func ballShape(side: TogetherCapsuleDockSide, dragging: Bool) -> UnevenRoundedRectangle {
        if dragging {
            return UnevenRoundedRectangle(
                topLeadingRadius: 19, bottomLeadingRadius: 19,
                bottomTrailingRadius: 19, topTrailingRadius: 19,
                style: .continuous
            )
        }
        switch side {
        case .left:
            return UnevenRoundedRectangle(
                topLeadingRadius: 0, bottomLeadingRadius: 0,
                bottomTrailingRadius: 19, topTrailingRadius: 19,
                style: .continuous
            )
        case .right:
            return UnevenRoundedRectangle(
                topLeadingRadius: 19, bottomLeadingRadius: 19,
                bottomTrailingRadius: 0, topTrailingRadius: 0,
                style: .continuous
            )
        }
    }

    private var progressRingVinyl: some View {
        ZStack {
            Circle()
                .strokeBorder(
                    CSSThemeVariables.textDim(scope: .chat).opacity(0.3),
                    lineWidth: 2
                )
                .frame(width: 30, height: 30)
            Circle()
                .trim(from: 0, to: progressRatio)
                .stroke(
                    CSSThemeVariables.accent(scope: .chat),
                    style: StrokeStyle(lineWidth: 2, lineCap: .round)
                )
                .frame(width: 30, height: 30)
                .rotationEffect(.degrees(-90))
            TogetherRefinedVinylView(size: 24, isPlaying: player.isPlaying)
        }
        .frame(width: 30, height: 30)
        .accessibilityHidden(true)
    }

    private var progressRatio: CGFloat {
        let d = max(player.duration, 1)
        return CGFloat(min(1, max(0, player.currentTime / d)))
    }

    /// The single DragGesture in the capsule system. A short tap (under
    /// 8pt of movement) opens the deck; a release within 70pt of an edge
    /// docks to that edge; dragging inward past 60pt from the docked
    /// edge undocks back to the pill; anything else snaps back.
    private func ballDrag(
        geo: GeometryProxy,
        side: TogetherCapsuleDockSide,
        anchorX: CGFloat,
        anchorY: CGFloat,
        minY: CGFloat,
        maxY: CGFloat
    ) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                isDragging = true
                let safe = geo.safeAreaInsets
                let minX = safe.leading + 26
                let maxX = max(minX, geo.size.width - safe.trailing - 26)
                dragOffset = CGSize(
                    width: min(max(value.translation.width, minX - anchorX), maxX - anchorX),
                    height: min(
                        max(value.translation.height, minY - (anchorY + yOffset)),
                        maxY - (anchorY + yOffset)
                    )
                )
            }
            .onEnded { value in
                isDragging = false
                let dx = value.translation.width
                let dy = value.translation.height
                let distance = (dx * dx + dy * dy).squareRoot()
                let finalX = anchorX + dragOffset.width
                if distance < 8 {
                    dragOffset = .zero
                    TogetherHaptics.select()
                    withAnimation(.easeInOut(duration: 0.28)) {
                        presentation = .deck
                    }
                    return
                }
                let width = geo.size.width
                var newSide: TogetherCapsuleDockSide?
                if finalX < 70 {
                    newSide = .left
                } else if finalX > width - 70 {
                    newSide = .right
                }
                let inward: CGFloat = side == .left ? dragOffset.width : -dragOffset.width
                if let newSide {
                    TogetherHaptics.select()
                    dockSide = newSide
                    yOffset = min(max(yOffset + dragOffset.height, minY - anchorY), maxY - anchorY)
                    withAnimation(.easeInOut(duration: 0.28)) {
                        dragOffset = .zero
                        presentation = .docked(newSide)
                    }
                } else if inward > 60 {
                    TogetherHaptics.select()
                    yOffset = 0
                    withAnimation(.easeInOut(duration: 0.28)) {
                        dragOffset = .zero
                        presentation = .pill
                    }
                } else {
                    yOffset = min(max(yOffset + dragOffset.height, minY - anchorY), maxY - anchorY)
                    withAnimation(.easeInOut(duration: 0.28)) {
                        dragOffset = .zero
                    }
                }
            }
    }
}

// MARK: - Lyric curtain

/// Full lyric drawer: bottom sheet, 82% of screen height, dimmed blurred
/// backdrop. NO drag gesture anywhere: dismiss only via the close button
/// or a backdrop tap. Scrolling scrolls lyrics only, never the sheet.
///
/// Auto-follow rule: the active line scrolls into view unless the user
/// has scrolled manually (followPaused). Follow resumes on the next
/// user-initiated seek — tapping a line, a progress seek (a >2s jump in
/// playback position), or a track change. Follow never fights a manual
/// scroll.
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
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                Color.black.opacity(0.28)
                    .ignoresSafeArea()
                    .onTapGesture { dismiss() }
                    .accessibilityHidden(true)

                VStack(spacing: 0) {
                    header
                    Rectangle()
                        .fill(CSSThemeVariables.divider(scope: .chat))
                        .frame(height: 0.5)
                    lyricArea
                }
                .frame(height: geo.size.height * 0.82)
                .frame(maxWidth: .infinity)
                .background(CSSThemeVariables.bg(scope: .chat))
                .clipShape(
                    UnevenRoundedRectangle(
                        topLeadingRadius: 32, bottomLeadingRadius: 0,
                        bottomTrailingRadius: 0, topTrailingRadius: 32,
                        style: .continuous
                    )
                )
            }
        }
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
            // A jump of more than 2s is a seek (tap a line, progress
            // seek, AI seek): follow resumes. Ordinary playback advances
            // 0.5s at a time and never trips this.
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
                dismiss()
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
                        // Her hand on the list: auto-follow stops until
                        // the next seek. A programmatic scroll (the
                        // follow itself) reports .animating, not
                        // .interacting, so it never pauses itself.
                        if newPhase == .interacting {
                            followPaused = true
                        }
                    }
                }
            } else {
                // No timed lyrics: the loop line when one exists, else
                // the no-lyrics line, with the same hint the panel
                // shows. No invented lyric data, ever.
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

    /// Scrolls the active line into view unless the user is browsing.
    /// Generation-guarded like the panel: a stale delayed scroll from
    /// before a track change or a recenter never fires.
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

    /// Same seek path as the deck and the panel.
    private func commitSeek(to target: Double) {
        player.seek(to: target)
        TogetherStore.shared.seek(to: target, by: .user)
        hub.refreshNow()
        TogetherHaptics.tap()
    }

    private func dismiss() {
        TogetherHaptics.select()
        withAnimation(.easeInOut(duration: 0.28)) {
            isPresented = false
        }
    }

    private func loadLyrics() {
        lyrics = player.track.flatMap { TogetherStore.shared.lyrics(for: $0) }
    }
}
