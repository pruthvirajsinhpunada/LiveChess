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

    var body: some View {
        HStack(spacing: Chess.Space.xxl) {
            // Persistent rail — its OWN floating glass capsule, set
            // apart from the content panel (not merged into it). Stays
            // put while the panel swaps and while child screens push.
            NavRailView(viewModel: homeViewModel)

            // Content panel. Its own NavigationStack so screens that
            // push detail (GameReviewRoute) or set a navigation title
            // keep working without the rail scrolling away.
            NavigationStack {
                detailView
                    .navigationDestination(for: GameReviewRoute.self) { route in
                        GameReviewDetailView(game: route.game, username: route.username)
                    }
            }
        }
        .padding(Chess.Space.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            // 1. Make sure the home VM can read the signed-in account.
            homeViewModel.attach(session: appModel.lichess)
            // 2. Open the lobby socket that feeds the global "players
            //    online" count to the sidebar. Idempotent; auto-
            //    reconnects on drop.
            appModel.onlineCount.start()
            // 3. Cold-start the Lichess session if it hasn't run yet.
            //    Idempotent if already signed in.
            await appModel.lichess.bootstrap()
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
        case .settings:   SettingsPlaceholderView()
        case .notifications: NotificationsPlaceholderView()
        }
    }
}

#Preview(windowStyle: .automatic) {
    ContentView()
        .environment(AppModel())
}
