// Views/Home/HomeDashboardView.swift
// The redesigned Home surface — the main glass panel that sits to the
// right of `NavRailView`. Three bands, top to bottom:
//
//   1. Top bar   — wordmark · search · notifications · profile avatar
//   2. Hero      — greeting + "Ready for your next move?" + Play Now,
//                  with the rotating 3-D golden king on the right
//   3. Continue  — "Continue where you left off" deck: Daily Puzzle,
//                  Quick Match, Last Analysis (real Lichess data)
//
// All actions route through the existing `HomeViewModel.navigate(to:)`
// so the redesign reuses the app's navigation + data wiring untouched.

import SwiftUI

struct HomeDashboardView: View {

    @Bindable var viewModel: HomeViewModel
    @Environment(AppModel.self) private var appModel

    @State private var isVisible = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            topBar
                .padding(.horizontal, Chess.Space.xl)
                .padding(.top, Chess.Space.l)
                .padding(.bottom, Chess.Space.m)

            ScrollView {
                VStack(alignment: .leading, spacing: Chess.Space.xl) {
                    HeroBand(viewModel: viewModel)
                    ContinueBand(viewModel: viewModel)
                    RecentGamesBand(viewModel: viewModel)
                }
                .padding(.horizontal, Chess.Space.xl)
                .padding(.bottom, Chess.Space.xl)
            }
            .scrollIndicators(.hidden)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glassBackgroundEffect()
        .opacity(isVisible ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
                isVisible = true
            }
        }
        .refreshable { await viewModel.refreshAll() }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: Chess.Space.m) {
            // 40 pt (was 30): the wordmark read undersized against
            // the hero headline below it. The coin logo scales with
            // the type automatically.
            BrandMark(.wordmark(size: 40))

            Spacer(minLength: Chess.Space.m)

            SearchBarView(text: $viewModel.searchText)
                .frame(maxWidth: 260)

            iconButton("bell") { viewModel.navigate(to: .notifications) }

            avatarButton
        }
    }

    private func iconButton(_ name: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 46, height: 46)
                .background(.thinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.10), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .hoverEffect(.lift)
    }

    private var avatarButton: some View {
        Button {
            viewModel.navigate(to: .profile)
        } label: {
            ZStack {
                Circle()
                    .fill(Chess.Palette.bronze.opacity(0.30))
                    .frame(width: 46, height: 46)
                    .overlay(Circle().strokeBorder(Chess.Palette.bronze.opacity(0.6), lineWidth: 1))
                if viewModel.isSignedIn {
                    Text(String(viewModel.displayUsername.prefix(1)).uppercased())
                        .font(.headline)
                        .foregroundStyle(.white)
                } else {
                    Image(systemName: "person.fill")
                        .font(.title3)
                        .foregroundStyle(.white)
                }
            }
        }
        .buttonStyle(.plain)
        .hoverEffect(.lift)
        .accessibilityLabel(viewModel.isSignedIn ? "Profile, \(viewModel.displayUsername)" : "Sign in")
    }
}

// MARK: - Hero band

private struct HeroBand: View {
    @Bindable var viewModel: HomeViewModel

    var body: some View {
        HStack(alignment: .center, spacing: Chess.Space.l) {

            VStack(alignment: .leading, spacing: Chess.Space.m) {
                Text(viewModel.isSignedIn
                     ? "Good to see you, \(viewModel.displayUsername)"
                     : "Good to see you,")
                    .font(.title3)
                    .foregroundStyle(.secondary)

                Text("Ready for\nyour next move?")
                    .font(.system(size: 52, weight: .bold))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Challenge yourself or find a new opponent around the world.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 420, alignment: .leading)

                PlayNowButton { viewModel.navigate(to: .playOnline) }
                    .padding(.top, Chess.Space.xs)
            }

            Spacer(minLength: Chess.Space.s)

            HeroKingView()
                .frame(width: 360, height: 360)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PlayNowButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Chess.Space.s) {
                Image(systemName: "play.fill")
                    .font(.headline)
                Text("Play Now")
                    .font(.title3.weight(.semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, Chess.Space.l)
            .padding(.vertical, Chess.Space.m)
            .background(
                LinearGradient(
                    colors: [
                        Chess.Palette.bronze,
                        Chess.Palette.bronze.opacity(0.78)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: Capsule()
            )
            .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
            .shadow(color: Chess.Palette.bronze.opacity(0.45), radius: 10, y: 4)
        }
        .buttonStyle(.plain)
        .hoverEffect(.lift)
    }
}

// MARK: - Continue band

private struct ContinueBand: View {
    @Bindable var viewModel: HomeViewModel
    @Environment(AppModel.self) private var appModel

    /// Most recent game that carries a real Lichess analysis summary —
    /// drives the "Last Analysis" card. `nil` for guests / un-analyzed
    /// histories, in which case the card shows its empty state.
    private var lastAnalyzed: LichessGame? {
        let name = viewModel.displayUsername
        return viewModel.games.first {
            $0.analysisSummary(for: name)?.accuracy != nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Chess.Space.m) {
            Text("Continue where you left off")
                .font(.title3.weight(.semibold))

            HStack(alignment: .top, spacing: Chess.Space.m) {
                DailyPuzzleCard(
                    puzzle: viewModel.puzzle,
                    solvedCount: appModel.puzzleProgress.solvedIDs.count
                ) { viewModel.navigate(to: .puzzles) }

                QuickMatchCard { viewModel.navigate(to: .playLocal) }

                LastAnalysisCard(
                    game: lastAnalyzed,
                    username: viewModel.displayUsername
                ) { viewModel.navigate(to: .gameReview) }
            }
        }
    }
}

// MARK: - Continue cards

/// Shared chrome for the three "Continue" cards: tall glass tile with a
/// header row (icon + title + subtitle + trailing accessory) and a
/// footer row separated by a hairline. The whole tile is the tap
/// target.
private struct ContinueCard<Header: View, Footer: View>: View {
    let action: () -> Void
    @ViewBuilder let header: () -> Header
    @ViewBuilder let footer: () -> Footer

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: Chess.Space.m) {
                header()
                Spacer(minLength: Chess.Space.s)
                Divider().overlay(.white.opacity(0.10))
                footer()
            }
            .padding(Chess.Space.m)
            .frame(maxWidth: .infinity, minHeight: 168, alignment: .topLeading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Chess.Radius.card, style: .continuous))
            .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: Chess.Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Chess.Radius.card, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .hoverEffect(.lift)
    }
}

/// Small circular icon badge used in each card header.
private struct CardIconBadge: View {
    let icon: String
    var body: some View {
        Image(systemName: icon)
            .font(.title3)
            .foregroundStyle(Chess.Palette.bronze)
            .frame(width: 44, height: 44)
            .background(Chess.Palette.bronze.opacity(0.18), in: Circle())
    }
}

/// Footer chevron + label used on cards without stat chips.
private struct CardFooterCue: View {
    let icon: String
    let text: String
    var tint: Color = Chess.Palette.bronze

    var body: some View {
        HStack(spacing: Chess.Space.xs) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(tint)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}

private struct DailyPuzzleCard: View {
    let puzzle: LichessPuzzle?
    let solvedCount: Int
    let action: () -> Void

    var body: some View {
        ContinueCard(action: action) {
            HStack(alignment: .top, spacing: Chess.Space.s) {
                VStack(alignment: .leading, spacing: 6) {
                    CardIconBadge(icon: "puzzlepiece.fill")
                    Text("Daily Puzzle")
                        .font(.headline)
                    Text("Solve and train your tactics every day.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                MiniChessBoardView(variant: .puzzle)
                    .frame(width: 76, height: 76)
            }
        } footer: {
            CardFooterCue(
                icon: "flame.fill",
                text: solvedCount > 0 ? "Solved: \(solvedCount)" : "Start solving",
                tint: .orange
            )
        }
    }
}

private struct QuickMatchCard: View {
    let action: () -> Void

    var body: some View {
        ContinueCard(action: action) {
            HStack(alignment: .top, spacing: Chess.Space.s) {
                VStack(alignment: .leading, spacing: 6) {
                    CardIconBadge(icon: "cpu")
                    Text("Quick Match")
                        .font(.headline)
                    Text("Play the on-device Stockfish engine on your board.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                MiniChessBoardView(variant: .review)
                    .frame(width: 76, height: 76)
            }
        } footer: {
            CardFooterCue(icon: "circle.fill", text: "Start now")
        }
    }
}

private struct LastAnalysisCard: View {
    let game: LichessGame?
    let username: String
    let action: () -> Void

    private var summary: LichessGame.GameAnalysis? {
        game?.analysisSummary(for: username)
    }

    var body: some View {
        ContinueCard(action: action) {
            HStack(alignment: .top, spacing: Chess.Space.s) {
                VStack(alignment: .leading, spacing: 6) {
                    CardIconBadge(icon: "chart.bar.fill")
                    Text("Last Analysis")
                        .font(.headline)
                    if let game {
                        Text("vs \(game.opponent(for: username))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text(game.date, style: .date)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    } else {
                        Text("Analyze a game to see your accuracy here.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                if let acc = summary?.accuracy {
                    AccuracyRing(value: acc / 100)
                        .frame(width: 72, height: 72)
                }
            }
        } footer: {
            if let s = summary {
                HStack(spacing: Chess.Space.xs) {
                    JudgmentChip(label: "Blunders", count: s.blunder ?? 0, tint: Color(red: 0.95, green: 0.40, blue: 0.30))
                    JudgmentChip(label: "Mistakes", count: s.mistake ?? 0, tint: .orange)
                    JudgmentChip(label: "Inacc.", count: s.inaccuracy ?? 0, tint: .yellow)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            } else {
                CardFooterCue(icon: "magnifyingglass", text: "Open Analyze")
            }
        }
    }
}

/// Compact "Label N" chip used for blunder/mistake/inaccuracy counts.
private struct JudgmentChip: View {
    let label: String
    let count: Int
    let tint: Color

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("\(count)")
                .font(.caption2.weight(.bold))
                .foregroundStyle(tint)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(.white.opacity(0.07), in: Capsule())
    }
}

/// Circular accuracy gauge — bronze ring + centred percentage, echoing
/// the reference design's "73% Accuracy" dial.
private struct AccuracyRing: View {
    /// 0…1.
    let value: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(.white.opacity(0.12), lineWidth: 6)
            Circle()
                .trim(from: 0, to: max(0, min(1, value)))
                .stroke(
                    Chess.Palette.bronze,
                    style: StrokeStyle(lineWidth: 6, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text("\(Int((value * 100).rounded()))%")
                    .font(.callout.weight(.bold).monospacedDigit())
                Text("Acc.")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityLabel("Accuracy \(Int((value * 100).rounded())) percent")
    }
}

// MARK: - Recently played band

/// Scroll-down section on Home: the user's recent Lichess games, each
/// with an Analyze button that opens that game on the immersive board
/// for review.
private struct RecentGamesBand: View {
    @Bindable var viewModel: HomeViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Chess.Space.m) {
            Text("Recently played")
                .font(.title3.weight(.semibold))

            if viewModel.isLoadingGames && viewModel.games.isEmpty {
                ForEach(0..<4, id: \.self) { _ in RecentGameSkeleton() }
            } else if viewModel.games.isEmpty {
                Text(viewModel.isSignedIn
                     ? "No recent games yet — play a game on Lichess to see it here."
                     : "Sign in with Lichess to see your games.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, Chess.Space.m)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(viewModel.filteredGames.prefix(8).enumerated()), id: \.element.id) { index, game in
                        if index > 0 { Divider().overlay(.white.opacity(0.06)) }
                        HomeRecentGameRow(game: game, username: viewModel.displayUsername)
                    }
                }
                .padding(.horizontal, Chess.Space.m)
                .padding(.vertical, Chess.Space.xs)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Chess.Radius.card, style: .continuous))
                .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: Chess.Radius.card, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Chess.Radius.card, style: .continuous)
                        .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct HomeRecentGameRow: View {
    let game: LichessGame
    let username: String

    private var result: GameResult { game.result(for: username) }

    var body: some View {
        HStack(spacing: Chess.Space.m) {
            ResultBadge(result: result)

            VStack(alignment: .leading, spacing: 2) {
                Text("vs \(game.opponent(for: username))")
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if let speed = game.speed {
                        Text(speed.capitalized).font(.caption).foregroundStyle(.secondary)
                        Text("·").font(.caption).foregroundStyle(.tertiary)
                    }
                    Text(game.date, style: .date).font(.caption).foregroundStyle(.secondary)
                    if let acc = game.accuracy(for: username) {
                        Text("·").font(.caption).foregroundStyle(.tertiary)
                        Text(String(format: "%.0f%% acc", acc)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Spacer(minLength: Chess.Space.s)

            HomeAnalyzeButton(game: game, username: username)
        }
        .padding(.vertical, Chess.Space.s)
    }
}

/// Per-row "Analyze" action — resolves the game's moves and opens the
/// immersive 3-D board with the game loaded for review. Mirrors the
/// review-launch flow used elsewhere so analysis happens on the same
/// board the user plays on.
@MainActor
private struct HomeAnalyzeButton: View {
    let game: LichessGame
    let username: String

    @Environment(AppModel.self) private var appModel
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @State private var isPreparing = false
    @State private var errorMessage: String?

    var body: some View {
        Button {
            Task { await launch() }
        } label: {
            HStack(spacing: 6) {
                if isPreparing {
                    ProgressView().controlSize(.mini).tint(Chess.Palette.bronze)
                } else {
                    Image(systemName: "chart.bar.fill").font(.caption)
                }
                Text(isPreparing ? "Loading…" : "Analyze")
                    .font(.callout.weight(.semibold))
            }
            .foregroundStyle(Chess.Palette.bronze)
            .padding(.horizontal, Chess.Space.m)
            .padding(.vertical, Chess.Space.xs)
            .background(Chess.Palette.bronze.opacity(0.16), in: Capsule())
            .overlay(Capsule().strokeBorder(Chess.Palette.bronze.opacity(0.4), lineWidth: 0.6))
        }
        .buttonStyle(.plain)
        .hoverEffect(.lift)
        .disabled(isPreparing)
        .alert(
            "Can't open analysis",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            ),
            presenting: errorMessage
        ) { _ in
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: { Text($0) }
    }

    private func launch() async {
        guard !isPreparing else { return }
        isPreparing = true
        defer { isPreparing = false }

        var resolved = game
        if (game.moves ?? "").isEmpty {
            let svc = LichessService()
            await svc.authenticate(token: appModel.lichess.token)
            do {
                resolved = try await svc.fetchGame(id: game.id)
            } catch {
                errorMessage = "Couldn't load this game from Lichess."
                return
            }
        }
        if (resolved.moves ?? "").isEmpty {
            errorMessage = "This game has no recorded moves to analyze."
            return
        }
        guard let session = ReviewSession(game: resolved, username: username) else {
            errorMessage = "Couldn't parse the moves of this game."
            return
        }

        appModel.activeSession = .review(session)
        appModel.immersiveSpaceState = .inTransition
        switch await openImmersiveSpace(id: appModel.immersiveSpaceID) {
        case .opened:
            break
        case .userCancelled:
            appModel.activeSession = nil
            appModel.immersiveSpaceState = .closed
        case .error:
            appModel.activeSession = nil
            appModel.immersiveSpaceState = .closed
            errorMessage = "The immersive space failed to open."
        @unknown default:
            appModel.activeSession = nil
            appModel.immersiveSpaceState = .closed
        }
    }
}

private struct RecentGameSkeleton: View {
    @State private var opacity = 0.4
    var body: some View {
        HStack(spacing: Chess.Space.m) {
            Circle().fill(.white.opacity(0.12)).frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 4) {
                Capsule().fill(.white.opacity(0.12)).frame(width: 150, height: 11)
                Capsule().fill(.white.opacity(0.08)).frame(width: 90, height: 9)
            }
            Spacer()
            Capsule().fill(.white.opacity(0.10)).frame(width: 92, height: 30)
        }
        .padding(.vertical, Chess.Space.s)
        .opacity(opacity)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                opacity = 0.85
            }
        }
    }
}

#Preview(windowStyle: .plain) {
    HomeDashboardView(viewModel: HomeViewModel())
        .environment(AppModel())
}
