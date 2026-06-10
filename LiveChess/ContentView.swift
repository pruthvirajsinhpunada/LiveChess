//
//  ContentView.swift
//  LiveChess
//
//  Created by Francesco Albano on 08/05/26.
//

import SwiftUI

/// Window root. Shows the redesigned Main Menu — a floating glass
/// `NavRailView` on the left and a content panel on the right — as the
/// first thing the user sees on launch. The rail wires straight into
/// the existing `LobbyView` / `LichessSession` plumbing: Online Game,
/// Local Game, Puzzles, and Analyze each route through
/// `HomeViewModel.navigate(to:)` into the matching screen.
struct ContentView: View {

    @Environment(AppModel.self) private var appModel

    @State private var homeViewModel = HomeViewModel()

    /// Explicit stack path so rail navigation can POP pushed screens
    /// (Customize, game review). Without it, tapping Home on the rail
    /// swapped the stack's ROOT while the pushed screen stayed on top,
    /// covering it — the rail appeared dead from the Customize page.
    @State private var navPath = NavigationPath()

    var body: some View {
        HStack(spacing: Chess.Space.xxl) {
            // Persistent rail — its OWN floating glass capsule, set
            // apart from the content panel (not merged into it). Stays
            // put while the panel swaps and while child screens push.
            NavRailView(viewModel: homeViewModel)

            // Content panel. Its own NavigationStack so screens that
            // push detail (GameReviewRoute) or set a navigation title
            // keep working without the rail scrolling away.
            NavigationStack(path: $navPath) {
                detailView
                    .navigationDestination(for: GameReviewRoute.self) { route in
                        GameReviewDetailView(game: route.game, username: route.username)
                    }
                    // Pieces & Board customization — pushed in-window
                    // (with the system back chevron) instead of the
                    // old separate WindowGroup, so it renders inside
                    // the same panel as every other screen.
                    .navigationDestination(for: CustomizeRoute.self) { _ in
                        PieceCustomizationView()
                    }
            }
        }
        .padding(Chess.Space.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            // 0. Prewarm the shared 3-D assets — the 12 piece USDZ
            //    templates and the preview light environment — in
            //    PARALLEL with the network work below. HeroKingView
            //    used to start this load only when it appeared, so
            //    the king popped in seconds after the rest of the
            //    home screen.
            Task {
                await PieceMeshFactory.preload()
                _ = await PreviewLighting.uniformEnvironment()
            }
            // 1. Make sure the home VM can read the signed-in account.
            homeViewModel.attach(session: appModel.lichess)
            // 2. Open the lobby socket that feeds the global "players
            //    online" count to the sidebar. Idempotent; auto-
            //    reconnects on drop.
            appModel.onlineCount.start()
            // 3. Cold-start the Lichess session if it hasn't run yet.
            //    Idempotent if already signed in.
            await appModel.lichess.bootstrap()
            // 3b. Puzzle ratings are PER ACCOUNT (mirroring
            //     lichess.org) — load the signed-in user's profile.
            appModel.puzzleProgress.switchAccount(
                appModel.lichess.account?.username
            )
            // 4. Now that the bearer token (if any) is loaded, fetch
            //    the home screen's data.
            await homeViewModel.loadInitialData()
        }
        // Re-fetch the home tiles whenever the user signs in / out so
        // the games list belongs to the current account (or empties
        // out on sign-out). Comparing on `isSignedIn` is enough — we
        // don't need to re-fetch on every `.error`/`.signingIn` flip.
        .onChange(of: appModel.lichess.isSignedIn) { _, _ in
            Task { await homeViewModel.loadInitialData() }
        }
        // Sign-in / sign-out / account change → swap to that
        // account's puzzle profile (rating, history, daily lock) and
        // seed a fresh profile from its Lichess puzzle perf.
        .onChange(of: appModel.lichess.account?.username) { _, newUsername in
            appModel.puzzleProgress.switchAccount(newUsername)
            let perf = appModel.lichess.account?.perfs?["puzzle"]
            appModel.puzzleProgress.seedFromLichess(
                rating: perf?.rating,
                rd: perf?.rd
            )
        }
        // Rail navigation always lands on the destination's root —
        // pop any pushed screen first or it would keep covering the
        // newly selected destination.
        .onChange(of: homeViewModel.selectedDestination) { _, _ in
            navPath = NavigationPath()
        }
    }

    @ViewBuilder
    private var detailView: some View {
        // Fall back to `.home` when nothing is selected (e.g. the user
        // taps an already-selected sidebar row, which on visionOS
        // clears the selection set).
        switch homeViewModel.selectedDestination ?? .home {
        case .home:
            HomeDashboardView(viewModel: homeViewModel)

        // All three Play sub-modes deep-link into the existing lobby
        // with the matching configuration card pre-selected. `.id` is
        // attached so SwiftUI re-creates `LobbyView` (and its
        // `@State selectedMode`) when the user switches between Play
        // sub-items — otherwise the first preselection would stick.
        case .playOnline:
            // Scope to the ONLINE group so the rail hides Local /
            // Lichess Bot — the sidebar already implies which top-level
            // bucket the user picked.
            LobbyView(initialMode: .quickPair, scope: .online)
                .id(AppDestination.playOnline)
        case .playLocal:
            LobbyView(initialMode: .local, scope: .local)
                .id(AppDestination.playLocal)
        case .playBot:
            LobbyView(initialMode: .lichessBot, scope: .local)
                .id(AppDestination.playBot)

        case .puzzles:    PuzzlesPlaceholderView()
        case .learn:
            ComingSoonView(
                icon: "book.fill",
                title: "Learn",
                description: "Guided lessons and opening trainers are on the way.",
                accentColor: Chess.Palette.bronze
            )
        case .gameReview: GameReviewPlaceholderView()
        case .history:    HistoryPlaceholderView()
        case .profile:    ProfilePlaceholderView(viewModel: homeViewModel)
        case .settings:   SettingsPlaceholderView(viewModel: homeViewModel)
        case .notifications: NotificationsPlaceholderView()
        }
    }
}

#Preview(windowStyle: .automatic) {
    ContentView()
        .environment(AppModel())
}
