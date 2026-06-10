//
//  LiveChessApp.swift
//  LiveChess
//
//  Created by Francesco Albano on 08/05/26.
//

import SwiftUI

@main
struct LiveChessApp: App {

    @State private var appModel = AppModel()
    /// Source of truth for the immersive's style. Mirrored to
    /// `appModel.selectedEnvironment` — any virtual env (dwarven hall,
    /// balcony, auditorium) needs full immersion; AR keeps passthrough
    /// mixed. `ImmersionStyle` without `any`/`some` is the existential
    /// the modifier expects for multi-style selection.
    @State private var immersionStyle: ImmersionStyle = MixedImmersionStyle()

    var body: some Scene {
        // Explicit `id` so we can dismiss / reopen the menu window
        // when the immersive scene opens / closes (otherwise the
        // floating panel stays in front of the chessboard).
        WindowGroup(id: Self.menuWindowID) {
            ContentView()
                .environment(appModel)
        }
        // `.plain` removes the system glass substrate behind the whole
        // window. Each screen (Home dashboard, Puzzles, Profile, …)
        // already supplies its own `.glassBackgroundEffect()` panel,
        // and the rail is its own glass capsule — so the substrate was
        // redundant. It was also what made the in-window 3-D piece
        // previews project those big floating rounded-rect volume
        // outlines; dropping it removes them.
        .windowStyle(.plain)

        // (The Pieces & Board customization screen used to live in its
        // own WindowGroup here. It's now pushed inside the main
        // window's NavigationStack — see `CustomizeRoute` — so it
        // renders like every other screen instead of spawning a second
        // floating window over the home panel.)

        ImmersiveSpace(id: appModel.immersiveSpaceID) {
            ImmersiveSceneHost(appModel: appModel)
                .onChange(of: appModel.selectedEnvironment) { _, env in
                    immersionStyle = env.isVirtual
                        ? FullImmersionStyle()
                        : MixedImmersionStyle()
                }
        }
        .immersionStyle(selection: $immersionStyle, in: .mixed, .full)
    }

    /// Window-group id for the Main Menu panel.
    static let menuWindowID = "MainMenu"
}

/// Wrapper around `ImmersiveView` that owns the window-management
/// side-effects. Lives inside the immersive scene so it has access to
/// `dismissWindow` / `openWindow` (which are `@Environment` values and
/// therefore only available inside a `View`, not directly in `App`).
///
/// On open: stamps state + dismisses the floating Main Menu window so
/// the chessboard isn't competing with a UI panel.
/// On close: stamps state + re-opens the Main Menu window so the user
/// lands back on the home screen.
///
/// `pendingReopen` (set by the virtual-env toggle flow) short-circuits
/// the dismiss/reopen cycle — that flow needs the menu window kept
/// alive across the immersive dismiss + re-open.
private struct ImmersiveSceneHost: View {

    let appModel: AppModel

    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ImmersiveView()
            .environment(appModel)
            .onAppear {
                appModel.immersiveSpaceState = .open
                if !appModel.pendingReopen {
                    dismissWindow(id: LiveChessApp.menuWindowID)
                }
            }
            .onDisappear {
                appModel.immersiveSpaceState = .closed
                if !appModel.pendingReopen {
                    // Closing the space mid-game = abandoning it.
                    // Resign (or abort, for move-zero games) so the
                    // opponent isn't left hanging and no "ongoing"
                    // zombie game lingers on the account to confuse
                    // the next matchmaking search. Finished games
                    // (result already set) are left untouched.
                    if case .online(let session) = appModel.activeSession,
                       session.result == nil {
                        Task {
                            await session.resign()
                            if session.result == nil { await session.abort() }
                            await session.disconnect()
                        }
                        appModel.activeSession = nil
                    }
                    // Same rule for an in-flight seek: closing the
                    // space cancels matchmaking outright.
                    if appModel.matchmaking != nil {
                        appModel.lichessLobby?.cancelSeek()
                        appModel.matchmaking = nil
                    }
                    // And for puzzles: closing the space mid-solve is
                    // a rated fail, same as the in-HUD Exit button —
                    // otherwise the Digital Crown is a free skip.
                    if case .puzzle(let session) = appModel.activeSession {
                        session.abandonIfSolving()
                        appModel.activeSession = nil
                    }
                    openWindow(id: LiveChessApp.menuWindowID)
                }
            }
    }
}
