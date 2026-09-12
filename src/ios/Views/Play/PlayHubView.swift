import SwiftUI

// MARK: - Play Hub (玩法)
//
// [T-play-hub 09-12] 醒醒 4：「我想要在里面封点和ai互动的好玩的功能，比如一起
// 听歌，ai日记可视化，还有别的，我会一点点往里加，入口放在首页底部栏里多一个
// 选项。到时候去 github 看看，直接照搬一些进去……每个进去都是一个新世界，但是
// 都和小梦联动的那种。」
//
// This is the CONTAINER. Each玩法 = a card on this page; tapping pushes that
// play's dedicated page. New玩法 get added here one by one (GitHub ports land
// as their own Views registered in playCards). The two named plays start as
// "coming soon" placeholders that respond with a friendly sheet — real
// implementations get wired when the ports land.

struct PlayHubView: View {
    /// One entry on the hub.
    struct PlayCard: Identifiable {
        let id: String
        let title: LocalizedStringKey
        let subtitle: LocalizedStringKey
        let systemImage: String
        /// nil = coming soon (card taps show the placeholder sheet).
        var destination: PlayDestination?
    }

    enum PlayDestination: Hashable {
        case listenTogether
        case aiDiary
    }

    private var playCards: [PlayCard] {
        [
            PlayCard(
                id: "listen-together",
                title: "Listen Together",
                subtitle: "Share one queue with your AI — it reacts to what's playing",
                systemImage: "music.note.house.fill",
                destination: .listenTogether
            ),
            PlayCard(
                id: "ai-diary",
                title: "AI Diary",
                subtitle: "Your days, visualized by the memories you two made",
                systemImage: "book.closed.fill",
                destination: .aiDiary
            )
        ]
    }

    @State private var pendingPlay: PlayCard?

    var body: some View {
        List {
            Section {
                ForEach(playCards) { card in
                    Button {
                        pendingPlay = card
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: card.systemImage)
                                .font(.system(size: 26))
                                .frame(width: 44, height: 44)
                                .background(MinisThemeList.accent.opacity(0.12))
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(card.title)
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(MinisThemeList.accent)
                                Text(card.subtitle)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 6)
                    }
                }
            } footer: {
                Text("Each one is a small world shared with your AI. More lands here as they're built.")
            }
        }
        .navigationTitle(AppLocalized("Play", comment: "Play hub page title"))
        .navigationBarTitleDisplayMode(.large)
        .background(AppearanceStudio.shared.color(.canvas, scope: .home).ignoresSafeArea())
        // Placeholder until the real pages land: a friendly "on its way" sheet.
        .sheet(item: $pendingPlay) { card in
            PlayComingSoonSheet(title: card.title)
        }
    }
}

/// Shown when a play's real page isn't wired yet.
private struct PlayComingSoonSheet: View {
    let title: LocalizedStringKey
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "sparkles")
                .font(.system(size: 40))
                .foregroundStyle(MinisThemeList.accent)
                .padding(.top, 48)
            Text(title)
                .font(.system(size: 20, weight: .bold))
            Text("This world is being built — it'll open up here soon.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                dismiss()
            } label: {
                Text("OK")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(MinisThemeList.accent.clipShape(Capsule()))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 32)
        }
        .presentationDetents([.height(300)])
    }
}
