import SwiftUI
import Combine    // MatchmakingHUDView's elapsed-time ticker uses Timer.publish

/// Pre-match lobby. Lets the user pick a game mode (local Stockfish,
/// online Quick Pair, friend challenge, Lichess Stockfish) and configures
/// it before opening the immersive space.
///
/// Layout philosophy: only one configuration card is visible at a time.
/// A single 4-chip mode picker at the top swaps the card below. The
/// Lichess profile + incoming challenges + active games sit above the
/// picker so they always have visibility regardless of which mode is
/// active.
struct LobbyView: View {

    @Environment(AppModel.self) private var appModel
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    /// App-owned lobby controller (see `AppModel.lichessLobby` for why
    /// it must NOT be view @State: the menu window is dismissed while
    /// the immersive is open, and a view-owned controller died with it
    /// mid-matchmaking, orphaning the seek's `gameStart` event).
    private var lichessLobby: LichessLobbyController? { appModel.lichessLobby }

    /// Whether the piece-customisation sheet is presented. Bound to
    /// the "Pieces" button in the header.
    @State private var showingPieceCustomization: Bool = false

    /// Currently selected mode (drives which configuration card is
    /// visible). Defaults to `.local` so first-time users without a
    /// Lichess account can play immediately. The Main Menu sidebar
    /// can override this via the `initialMode` initializer parameter
    /// so deep-linking to a specific Play sub-item works.
    @State private var selectedMode: GameMode

    /// Legacy entry-point hint. The mode tab strip now always shows
    /// every mode (sign-in gating lives in the action column instead
    /// of hiding tabs), so `scope` no longer filters anything — it's
    /// kept only so existing `ContentView` call sites keep compiling.
    enum Scope { case local, online, both }
    private let scope: Scope

    /// Designated initializer. The optional `initialMode` overrides the
    /// default landing tab — used by the Main Menu's
    /// Online Game / Local Game / Play with Bot entries.
    init(initialMode: GameMode? = nil, scope: Scope = .both) {
        _selectedMode = State(initialValue: initialMode ?? .quickPair)
        self.scope = scope
    }

    /// Selected time control for the online configuration cards.
    @State private var selectedTimeControl: LichessTimeControlSpec =
        .realTime(limitSeconds: 600, incrementSeconds: 0)
    @State private var selectedColor: LichessChallengeColor = .random
    @State private var selectedRated: Bool = false
    @State private var selectedAILevel: Int = 3
    @State private var friendUsername: String = ""
    /// In-app Fair Play sheet (replaces the old lichess.org Safari link).
    @State private var showingFairPlay: Bool = false

    /// Case order == tab order in the mode strip (Quick Match first —
    /// it's the marquee "just play" path the Play Now button lands on).
    enum GameMode: String, Hashable, CaseIterable {
        case quickPair, friend, lichessBot, local

        var label: String {
            switch self {
            case .quickPair:   return "Quick Match"
            case .friend:      return "Play a Friend"
            case .lichessBot:  return "Play vs AI"
            case .local:       return "Local Match"
            }
        }

        /// One-line pitch under the tab title.
        var blurb: String {
            switch self {
            case .quickPair:   return "Find a player of your level"
            case .friend:      return "Challenge by username"
            case .lichessBot:  return "Improve with Lichess AI"
            case .local:       return "Offline, on this device"
            }
        }

        var icon: String {
            switch self {
            case .quickPair:   return "bolt.fill"
            case .friend:      return "person.2.fill"
            case .lichessBot:  return "cpu"
            case .local:       return "house.fill"
            }
        }

        /// True for any mode that requires a Lichess account.
        var requiresSignIn: Bool {
            switch self {
            case .local: return false
            default: return true
            }
        }
    }

    var body: some View {
        // "Choose your match" layout: hero heading, a full-width
        // horizontal mode tab strip, then a three-column configuration
        // panel (Time Control · Play As · Your Rating + CTA) and a
        // Fair Play footer. Replaces the previous Settings-style
        // two-column rail — this reads as a destination, not a form.
        ScrollView {
            VStack(alignment: .leading, spacing: Chess.Space.l) {
                slimHeader
                heroBlock
                modeTabStrip

                // Incoming challenges stay above the config panel so
                // "someone's waiting on you" signals jump out.
                // (NO active-games / resume list: product rule is
                // "not in the game = game over" — orphans are
                // auto-resigned by `refreshActiveGames`, so there is
                // never anything to resume.)
                if let lobby = lichessLobby,
                   !lobby.incomingChallenges.isEmpty {
                    incomingChallengesSection(lobby)
                }

                if let action = lichessLobby?.pendingAction {
                    pendingActionRow(action)
                } else {
                    environmentToolbar
                    configPanel
                }

                if let error = lichessLobby?.lastError {
                    Label(humanReadable(error),
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                fairPlayFooter
            }
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Chess.Space.xl)
            .padding(.top, Chess.Space.l)
            .padding(.bottom, Chess.Space.xl)
        }
        .scrollIndicators(.hidden)
        .sheet(isPresented: $showingFairPlay) {
            fairPlaySheet
        }
        .task {
            await appModel.lichess.bootstrap()
            ensureLichessLobby()
            // Back in the 2-D lobby, any "Found X! Opening board…"
            // strip is stale by definition (the immersive either
            // opened and was closed, or failed) — clear it so the
            // user sees the mode picker, not a zombie progress row.
            if case .openingMatch = lichessLobby?.pendingAction {
                lichessLobby?.clearPending()
            }
            await lichessLobby?.refreshActiveGames()
            // Cheap belt-and-braces refresh while the lobby is visible.
            // Doubles as the auto-open fallback for matches that
            // weren't routed via `gameStart` (event-stream gap, etc.) —
            // see `LichessLobbyController.refreshActiveGames`.
            // 5 s while seeking; 30 s otherwise.
            while !Task.isCancelled {
                let interval: Duration =
                    (lichessLobby?.pendingAction).flatMap {
                        if case .seeking = $0 { return Duration.seconds(5) }
                        return nil
                    } ?? .seconds(30)
                try? await Task.sleep(for: interval)
                await lichessLobby?.refreshActiveGames()
            }
        }
        .onChange(of: appModel.lichess.isSignedIn) { _, _ in
            ensureLichessLobby()
        }
        .onChange(of: appModel.immersiveSpaceState) { _, newState in
            // Once the immersive space is open the lobby's "Found!"
            // indicator has done its job — clear it so the next time
            // the user comes back from the immersive they see the
            // mode picker, not a stale "opening match…" row.
            if newState == .open {
                lichessLobby?.clearPending()
            }
        }
        // (Pieces & Board is pushed onto the window's NavigationStack
        // via `CustomizeRoute` — see the slim header's NavigationLink.)
    }

    // MARK: - Slim header (top bar of the right column)

    /// Brand wordmark on the left, single link on the right that
    /// pushes the Customize screen onto the window's NavigationStack
    /// (in-window, with the system back chevron — no second window).
    private var slimHeader: some View {
        HStack(spacing: Chess.Space.s) {
            // 36 pt (was 26) — keeps the wordmark in proportion with
            // the serif "Choose your match" hero below, matching the
            // home screen's 40 pt mark.
            BrandMark(.wordmark(size: 36))
            Spacer()
            NavigationLink(value: CustomizeRoute()) {
                Label("Pieces & board", systemImage: "paintbrush.fill")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
        }
    }

    // MARK: - Hero

    /// "Choose your match" heading block — eyebrow, serif display
    /// title, supporting line. Same hero language as the home
    /// dashboard so Play reads as a sibling destination.
    private var heroBlock: some View {
        VStack(alignment: .leading, spacing: Chess.Space.xs) {
            Text("Play")
                .font(Chess.Typography.eyebrow())
                .foregroundStyle(Chess.Palette.bronze)
            Text("Choose your match")
                .font(.system(size: 44, weight: .semibold, design: .serif))
                .foregroundStyle(Chess.Palette.accent)
            Text("Play your way. Anytime, anywhere.")
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .padding(.top, Chess.Space.xs)
    }

    // MARK: - Mode tab strip

    /// Full-width horizontal strip of mode tabs (icon + title + blurb),
    /// one per `GameMode`. All modes stay visible and selectable
    /// regardless of `scope` — sign-in gating happens in the action
    /// column, not by hiding tabs — so the strip always matches the
    /// "Choose your match" promise.
    private var modeTabStrip: some View {
        HStack(spacing: Chess.Space.xs) {
            ForEach(GameMode.allCases, id: \.self) { mode in
                modeTab(mode)
            }
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: Chess.Radius.card, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Chess.Radius.card, style: .continuous)
                .strokeBorder(.white.opacity(0.10), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private func modeTab(_ mode: GameMode) -> some View {
        let isSelected = mode == selectedMode

        Button {
            selectedMode = mode
            syncDefaultsForMode(mode)
        } label: {
            HStack(spacing: Chess.Space.s) {
                Image(systemName: mode.icon)
                    .font(.title3)
                    .foregroundStyle(isSelected ? Chess.Palette.bronze : .secondary)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(mode.label)
                        .font(.callout.weight(isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? .white : .primary)
                    Text(mode.blurb)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Chess.Space.s)
            .padding(.vertical, Chess.Space.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Chess.Radius.row, style: .continuous)
                    .fill(isSelected
                          ? AnyShapeStyle(Chess.Palette.cream.opacity(0.16))
                          : AnyShapeStyle(Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Chess.Radius.row, style: .continuous)
                    .strokeBorder(isSelected
                                  ? Chess.Palette.bronze.opacity(0.5)
                                  : Color.clear,
                                  lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
    }

    // MARK: - Environment picker

    /// Single-row picker for the immersive backdrop (AR vs one of the
    /// bundled USDZ environments). Read at the moment the user opens
    /// the immersive space — `ChessSceneView` dispatches on
    /// `appModel.selectedEnvironment` to mount the right scene. Also
    /// drives `immersionStyle` in `LiveChessApp` so virtual envs go
    /// full-immersion and AR stays mixed.
    /// Compact horizontal toolbar that sits directly above the active
    /// config card. Lists every environment as a small chip so the
    /// user can scan options at a glance instead of opening a menu.
    @ViewBuilder
    private var environmentToolbar: some View {
        @Bindable var appModel = appModel
        VStack(alignment: .leading, spacing: 6) {
            Text("Environment")
                .font(Chess.Typography.eyebrow())
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Chess.Space.xs) {
                    ForEach(SceneEnvironment.allCases) { env in
                        envChip(env,
                                isSelected: env == appModel.selectedEnvironment) {
                            appModel.selectedEnvironment = env
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func envChip(_ env: SceneEnvironment,
                         isSelected: Bool,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                // Leading checkmark on the selected chip — the
                // single strongest "you picked this" signal in
                // Apple's HIG. Wider gap from the icon when shown
                // so the chip doesn't look cramped.
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                }
                Image(systemName: env.systemImage)
                Text(env.displayName)
                    .lineLimit(1)
            }
            .font(.caption.weight(isSelected ? .bold : .regular))
            .foregroundStyle(isSelected ? .white : .primary)
            .padding(.horizontal, isSelected ? Chess.Space.m : Chess.Space.s)
            .padding(.vertical, 7)
            .background(
                Capsule().fill(isSelected
                               // SOLID bronze fill for the picked
                               // chip — was a 18%-opacity cream wash
                               // before, which read as 'maybe a tiny
                               // bit different shade?' on the
                               // material background. Now it's
                               // unmistakable.
                               ? AnyShapeStyle(Chess.Palette.bronze)
                               : AnyShapeStyle(.thinMaterial))
            )
            .overlay(
                Capsule().strokeBorder(isSelected
                                       ? Color.white.opacity(0.35)
                                       : .white.opacity(0.12),
                                       lineWidth: isSelected ? 1 : 0.5)
            )
            .shadow(color: isSelected
                        ? Chess.Palette.bronze.opacity(0.45)
                        : .clear,
                    radius: isSelected ? 6 : 0)
        }
        .buttonStyle(.plain)
        .hoverEffect(.lift)
    }

    // MARK: - Config panel (three columns)

    /// One glass panel with three columns, mockup-style:
    ///   1. Time Control (or Difficulty for the local engine)
    ///   2. Play As / Match Type
    ///   3. Your Rating + primary CTA
    /// All four modes share the same skeleton so switching tabs only
    /// swaps column contents, never the page shape.
    private var configPanel: some View {
        ChessCard(.standard) {
            HStack(alignment: .top, spacing: Chess.Space.l) {
                switch selectedMode {
                case .quickPair:
                    column("Time Control") {
                        timeControlList(allowed: .quickPairAllowed)
                    }
                    column("Match Type") {
                        matchTypeCards
                        Text("Colors are assigned automatically in the quick pool.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                case .friend:
                    column("Time Control") {
                        timeControlList(allowed: .friendAllowed)
                    }
                    column("Play As") {
                        playAsCards
                        matchTypeCards
                    }
                case .lichessBot:
                    column("Time Control") {
                        timeControlList(allowed: .friendAllowed)
                    }
                    column("Play As") {
                        playAsCards
                        aiLevelBlock
                    }
                case .local:
                    column("Difficulty") {
                        localDifficultyControls
                    }
                    column("Play As") {
                        localPlayAsCards
                    }
                }

                actionColumn
            }
        }
    }

    /// Titled column wrapper — equal flexible width, top-aligned.
    private func column<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Chess.Space.s) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            content()
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    // MARK: - Column 1 · Time Control / Difficulty

    /// Radio-style preset list. Quick Pair's 6 presets fit a single
    /// column (like the mockup); the full 12-preset set for friend /
    /// bot challenges wraps to a compact 2-column grid.
    @ViewBuilder
    private func timeControlList(allowed: TimePresetSet) -> some View {
        let presets = TimePreset.all.filter { allowed.contains($0.speed) }
        let columnCount = presets.count > 7 ? 2 : 1
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: Chess.Space.xs),
                           count: columnCount),
            spacing: Chess.Space.xs
        ) {
            ForEach(presets, id: \.label) { preset in
                timeControlRow(preset, compact: columnCount == 2)
            }
        }
    }

    @ViewBuilder
    private func timeControlRow(_ preset: TimePreset, compact: Bool) -> some View {
        let isSelected = preset.spec == selectedTimeControl
        Button {
            selectedTimeControl = preset.spec
        } label: {
            HStack(spacing: Chess.Space.xs) {
                Image(systemName: "clock")
                    .font(compact ? .caption : .callout)
                    .foregroundStyle(isSelected ? Chess.Palette.bronze : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(preset.label)
                        .font(.callout.weight(isSelected ? .semibold : .regular))
                        .monospacedDigit()
                    Text(speedName(preset.speed))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                radioMark(isSelected)
            }
            .padding(.horizontal, Chess.Space.s)
            .padding(.vertical, compact ? 7 : 10)
            .modifier(SelectableRowChrome(isSelected: isSelected))
        }
        .buttonStyle(.plain)
        .hoverEffect(.lift)
    }

    /// Stockfish strength + thinking time, lifted from the old local
    /// card — they ARE the local mode's "time control" equivalent.
    private var localDifficultyControls: some View {
        @Bindable var appModel = appModel
        return VStack(alignment: .leading, spacing: Chess.Space.m) {
            skillSlider(for: $appModel.matchSettings.aiSettings.skillLevel)
            thinkingTimeSlider(for: $appModel.matchSettings.aiSettings.thinkingTime)
        }
        .padding(Chess.Space.s)
        .modifier(SelectableRowChrome(isSelected: false))
    }

    // MARK: - Column 2 · Play As / Match Type / AI level

    /// Side preference cards for online challenges (friend / bot).
    private var playAsCards: some View {
        VStack(spacing: Chess.Space.xs) {
            sideRow(.random,
                    isSelected: selectedColor == .random) { selectedColor = .random }
            sideRow(.white,
                    isSelected: selectedColor == .white) { selectedColor = .white }
            sideRow(.black,
                    isSelected: selectedColor == .black) { selectedColor = .black }
        }
    }

    /// Same cards bound to the local match's human color.
    private var localPlayAsCards: some View {
        @Bindable var appModel = appModel
        return VStack(spacing: Chess.Space.xs) {
            sideRow(.random,
                    isSelected: appModel.matchSettings.humanColor == .random) {
                appModel.matchSettings.humanColor = .random
            }
            sideRow(.white,
                    isSelected: appModel.matchSettings.humanColor == .white) {
                appModel.matchSettings.humanColor = .white
            }
            sideRow(.black,
                    isSelected: appModel.matchSettings.humanColor == .black) {
                appModel.matchSettings.humanColor = .black
            }
        }
    }

    /// Which side the player takes. Shared row visual for both the
    /// online (`LichessChallengeColor`) and local (`HumanColor`) pickers.
    private enum SideOption {
        case random, white, black

        var title: String {
            switch self {
            case .random: return "Random"
            case .white:  return "White"
            case .black:  return "Black"
            }
        }

        var subtitle: String {
            switch self {
            case .random: return "Let fate decide"
            case .white:  return "Move first"
            case .black:  return "Counter-attack"
            }
        }
    }

    @ViewBuilder
    private func sideRow(_ option: SideOption,
                         isSelected: Bool,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Chess.Space.s) {
                sideBadge(option)
                VStack(alignment: .leading, spacing: 1) {
                    Text(option.title)
                        .font(.callout.weight(isSelected ? .semibold : .regular))
                    Text(option.subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                radioMark(isSelected)
            }
            .padding(Chess.Space.s)
            .modifier(SelectableRowChrome(isSelected: isSelected))
        }
        .buttonStyle(.plain)
        .hoverEffect(.lift)
    }

    /// Little pawn coin — white pawn on dark glass, black pawn on
    /// cream, shuffle glyph for random. `\u{FE0E}` forces the text
    /// (non-emoji) presentation of the pawn glyph.
    @ViewBuilder
    private func sideBadge(_ option: SideOption) -> some View {
        ZStack {
            switch option {
            case .random:
                Circle().fill(.thinMaterial)
                Image(systemName: "shuffle")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Chess.Palette.bronze)
            case .white:
                Circle().fill(Color.black.opacity(0.45))
                Text("♟\u{FE0E}")
                    .font(.system(size: 17))
                    .foregroundStyle(.white)
            case .black:
                Circle().fill(Chess.Palette.cream.opacity(0.85))
                Text("♟\u{FE0E}")
                    .font(.system(size: 17))
                    .foregroundStyle(.black)
            }
        }
        .frame(width: 34, height: 34)
        .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
    }

    /// Casual / Rated selection (replaces the old Toggle).
    private var matchTypeCards: some View {
        VStack(spacing: Chess.Space.xs) {
            matchTypeRow(rated: false,
                         title: "Casual",
                         subtitle: "Just for fun — no rating change",
                         icon: "face.smiling")
            matchTypeRow(rated: true,
                         title: "Rated",
                         subtitle: "Counts toward your Lichess rating",
                         icon: "trophy.fill")
        }
    }

    @ViewBuilder
    private func matchTypeRow(rated: Bool,
                              title: String,
                              subtitle: String,
                              icon: String) -> some View {
        let isSelected = selectedRated == rated
        Button {
            selectedRated = rated
        } label: {
            HStack(spacing: Chess.Space.s) {
                Image(systemName: icon)
                    .font(.callout)
                    .foregroundStyle(isSelected ? Chess.Palette.bronze : .secondary)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.callout.weight(isSelected ? .semibold : .regular))
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                radioMark(isSelected)
            }
            .padding(Chess.Space.s)
            .modifier(SelectableRowChrome(isSelected: isSelected))
        }
        .buttonStyle(.plain)
        .hoverEffect(.lift)
    }

    /// Lichess Stockfish level 1–8 chip grid (bot mode only).
    private var aiLevelBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("AI Level")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(selectedAILevel) / 8")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4),
                spacing: 6
            ) {
                ForEach(1...8, id: \.self) { level in
                    levelChip(level)
                }
            }
        }
        .padding(.top, Chess.Space.xs)
    }

    /// Shared trailing radio indicator for selectable rows.
    private func radioMark(_ isSelected: Bool) -> some View {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.callout)
            .foregroundStyle(isSelected
                             ? Chess.Palette.bronze
                             : Color.secondary.opacity(0.4))
    }

    // MARK: - Column 3 · Rating + CTA

    /// "Your Rating" (or engine identity for local) + the mode's
    /// primary action + a one-line status. The only column with a
    /// prominent button, so the eye always lands here last.
    private var actionColumn: some View {
        VStack(alignment: .leading, spacing: Chess.Space.s) {
            Text(selectedMode == .local ? "Your Game" : "Your Rating")
                .font(.subheadline.weight(.semibold))
            ratingCard
            if selectedMode == .friend {
                usernameField
            }
            primaryCTA
            statusLine
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var ratingCard: some View {
        VStack(spacing: 4) {
            if selectedMode == .local {
                Image(systemName: "cpu")
                    .font(.title3)
                    .foregroundStyle(Chess.Palette.bronze)
                Text("Stockfish 17")
                    .font(.system(size: 28, weight: .semibold, design: .serif))
                Text("Runs on this device")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "bolt.fill")
                    .font(.title3)
                    .foregroundStyle(Chess.Palette.bronze)
                Text(ratingText)
                    .font(.system(size: 40, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(ratingCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Chess.Space.m)
        .modifier(SelectableRowChrome(isSelected: false))
    }

    /// Speed of the currently selected time-control preset — drives
    /// which Lichess perf rating the card shows (Rapid pick → Rapid
    /// rating, Blitz pick → Blitz rating, …).
    private var selectedSpeed: LichessSpeed {
        TimePreset.all.first { $0.spec == selectedTimeControl }?.speed ?? .rapid
    }

    private var ratingText: String {
        guard let rating = appModel.lichess.account?
            .rating(forPerfKey: selectedSpeed.rawValue) else { return "—" }
        return "\(rating)"
    }

    private var ratingCaption: String {
        guard appModel.lichess.isSignedIn else { return "Sign in to see your rating" }
        return appModel.lichess.account?
            .rating(forPerfKey: selectedSpeed.rawValue) == nil
            ? "\(speedName(selectedSpeed)) · Unrated"
            : speedName(selectedSpeed)
    }

    private func speedName(_ speed: LichessSpeed) -> String {
        switch speed {
        case .ultraBullet:    return "UltraBullet"
        case .bullet:         return "Bullet"
        case .blitz:          return "Blitz"
        case .rapid:          return "Rapid"
        case .classical:      return "Classical"
        case .correspondence: return "Daily"
        }
    }

    private var usernameField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Opponent username")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("e.g. magnuscarlsen", text: $friendUsername)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
    }

    /// The one prominent button on the page. Online modes collapse to
    /// a sign-in CTA when there's no Lichess session — tabs stay
    /// selectable so the user can still see what each mode offers.
    @ViewBuilder
    private var primaryCTA: some View {
        if selectedMode.requiresSignIn && !appModel.lichess.isSignedIn {
            Button {
                Task { await appModel.lichess.signIn() }
            } label: {
                Label("Sign in with Lichess",
                      systemImage: "person.crop.circle.badge.checkmark")
                    .frame(maxWidth: .infinity)
                    .fontWeight(.semibold)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(Chess.Palette.bronze)
        } else {
            switch selectedMode {
            case .quickPair:
                Button {
                    guard let lobby = lichessLobby else { return }
                    // Open the immersive immediately into the chosen
                    // environment with the matchmaking HUD overlaid;
                    // the actual seek + game-ready handoff happen in
                    // the background.
                    Task { await startMatchmakingFlow(lobby: lobby) }
                } label: {
                    Label("Find Match", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                        .fontWeight(.semibold)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .tint(Chess.Palette.bronze)

            case .friend:
                Button {
                    guard let lobby = lichessLobby else { return }
                    wireOnGameSessionReadyAndOpenImmersive(lobby)
                    Task {
                        await lobby.challengeFriend(
                            username: friendUsername,
                            rated: selectedRated,
                            timeControl: selectedTimeControl,
                            color: selectedColor
                        )
                    }
                } label: {
                    Label("Send Challenge", systemImage: "paperplane.fill")
                        .frame(maxWidth: .infinity)
                        .fontWeight(.semibold)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .tint(Chess.Palette.bronze)
                .disabled(friendUsername
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            case .lichessBot:
                Button {
                    guard let lobby = lichessLobby else { return }
                    wireOnGameSessionReadyAndOpenImmersive(lobby)
                    Task {
                        await lobby.challengeAI(
                            level: selectedAILevel,
                            timeControl: selectedTimeControl,
                            color: selectedColor
                        )
                    }
                } label: {
                    Label("Challenge Bot", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                        .fontWeight(.semibold)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .tint(Chess.Palette.bronze)

            case .local:
                Button {
                    Task { await openLocalMatch() }
                } label: {
                    Label(
                        appModel.immersiveSpaceState == .open
                            ? "Close Board" : "Open Board",
                        systemImage: appModel.immersiveSpaceState == .open
                            ? "xmark.circle" : "play.fill"
                    )
                    .frame(maxWidth: .infinity)
                    .fontWeight(.semibold)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .tint(Chess.Palette.bronze)
                .disabled(appModel.immersiveSpaceState == .inTransition)
            }
        }
    }

    /// Honest stand-in for the mockup's "2,341 players online" — we
    /// don't have a pool count, so show the signed-in identity (or
    /// the offline guarantee for local).
    private var statusLine: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusIsPositive ? Color.green : Color.secondary.opacity(0.5))
                .frame(width: 7, height: 7)
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    private var statusIsPositive: Bool {
        selectedMode == .local || appModel.lichess.isSignedIn
    }

    private var statusText: String {
        if selectedMode == .local {
            return "Fully offline — no account needed"
        }
        if let name = appModel.lichess.account?.username {
            return "Playing as \(name) on Lichess"
        }
        return "A free Lichess account is required"
    }

    // MARK: - Fair Play footer

    private var fairPlayFooter: some View {
        ChessCard(.row) {
            HStack(spacing: Chess.Space.s) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.title3)
                    .foregroundStyle(Chess.Palette.bronze)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Fair Play")
                        .font(.callout.weight(.semibold))
                    Text("We care about a fair and respectful community.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: Chess.Space.s)
                // In-app sheet, NOT a lichess.org Safari hand-off —
                // the user never leaves the headset experience.
                Button {
                    showingFairPlay = true
                } label: {
                    HStack(spacing: 4) {
                        Text("Learn more")
                        Image(systemName: "chevron.right")
                            .font(.caption)
                    }
                    .font(.callout)
                    .foregroundStyle(Chess.Palette.bronze)
                }
                .buttonStyle(.plain)
                .hoverEffect()
            }
        }
    }

    // MARK: - Fair Play sheet (in-app)

    private var fairPlaySheet: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Chess.Space.m) {
                HStack(spacing: Chess.Space.s) {
                    Image(systemName: "shield.lefthalf.filled")
                        .font(.largeTitle)
                        .foregroundStyle(Chess.Palette.bronze)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Fair Play")
                            .font(.system(size: 30, weight: .semibold, design: .serif))
                        Text("Online games are played on Lichess, a free and open community.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.bottom, Chess.Space.xs)

                fairPlayRule(
                    icon: "brain.head.profile",
                    title: "Play your own moves",
                    body: "Never use chess engines, books, databases, or another person's advice during a game. Every move must be yours alone."
                )
                fairPlayRule(
                    icon: "person.crop.circle.badge.checkmark",
                    title: "One account, your account",
                    body: "Play under a single account and never let anyone else play on it. Artificially inflating or deflating your rating is against the rules."
                )
                fairPlayRule(
                    icon: "flag.checkered",
                    title: "Finish your games",
                    body: "Leaving games without resigning, stalling on lost positions, or letting the clock run down wastes your opponent's time. In Chess+, closing the board resigns the game for you."
                )
                fairPlayRule(
                    icon: "heart",
                    title: "Be respectful",
                    body: "Treat every opponent with respect, win or lose. Harassment, hate speech, and unsporting behaviour are never acceptable."
                )
                fairPlayRule(
                    icon: "exclamationmark.shield",
                    title: "Violations have consequences",
                    body: "Lichess detects engine assistance, sandbagging, and abuse. Violations can mark or close your Lichess account — which this app signs in with."
                )

                Text("These are the same standards as the Lichess Fair Play policy, which governs all online games played through Chess+.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.top, Chess.Space.xs)
            }
            .padding(Chess.Space.xl)
            .frame(maxWidth: 640, alignment: .leading)
        }
        .scrollIndicators(.hidden)
        .overlay(alignment: .topTrailing) {
            Button {
                showingFairPlay = false
            } label: {
                Image(systemName: "xmark")
                    .font(.callout.weight(.semibold))
                    .padding(10)
            }
            .buttonStyle(.bordered)
            .clipShape(Circle())
            .padding(Chess.Space.m)
        }
    }

    private func fairPlayRule(icon: String, title: String, body text: String) -> some View {
        HStack(alignment: .top, spacing: Chess.Space.s) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(Chess.Palette.bronze)
                .frame(width: 34, height: 34)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: Chess.Radius.chip, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.semibold))
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func skillSlider(for level: Binding<Int>) -> some View {
        let bounds = Double(AISettings.minSkillLevel)...Double(AISettings.maxSkillLevel)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Stockfish strength")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(level.wrappedValue) / \(AISettings.maxSkillLevel)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: Binding(
                    get: { Double(level.wrappedValue) },
                    set: { level.wrappedValue = Int($0.rounded()) }
                ),
                in: bounds,
                step: 1
            )
            HStack {
                Text("Beginner").font(.caption2)
                Spacer()
                Text("Maximum").font(.caption2)
            }
            .foregroundStyle(.secondary)
        }
    }

    private func thinkingTimeSlider(for time: Binding<Duration>) -> some View {
        let seconds = Binding(
            get: { Self.duration(time.wrappedValue, asSeconds: ()) },
            set: { time.wrappedValue = .milliseconds(Int($0 * 1000)) }
        )
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Thinking time")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(Self.formatSeconds(seconds.wrappedValue))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: seconds, in: 0.5...10.0, step: 0.5)
            HStack {
                Text("0.5 s").font(.caption2)
                Spacer()
                Text("10 s").font(.caption2)
            }
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - AI level chip

    @ViewBuilder
    private func levelChip(_ level: Int) -> some View {
        let isSelected = level == selectedAILevel
        Button {
            selectedAILevel = level
        } label: {
            Text("\(level)")
                .font(.callout.weight(isSelected ? .semibold : .regular))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(SelectionButtonStyle(isSelected: isSelected))
        .hoverEffect()
    }

    // MARK: - Pending action / found-match strip

    @ViewBuilder
    private func pendingActionRow(_ action: LichessLobbyController.PendingAction) -> some View {
        HStack(spacing: 12) {
            // Use a checkmark for the matched-state to give a clearer
            // visual signal of "found, opening now" vs the spinner-only
            // "still waiting" states.
            if case .openingMatch = action {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.green)
            } else {
                ProgressView().controlSize(.small)
            }
            Text(label(for: action))
                .font(.callout)
                .foregroundStyle(.primary)
            Spacer()
            switch action {
            case .seeking:
                Button("Cancel") {
                    lichessLobby?.cancelSeek()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            case .waitingForOpponent:
                Button("Cancel") {
                    Task { await lichessLobby?.cancelFriendChallenge() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            default:
                EmptyView()
            }
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func label(for action: LichessLobbyController.PendingAction) -> String {
        switch action {
        case .creatingAIChallenge(let level):
            return "Creating challenge with Stockfish L\(level)…"
        case .creatingUserChallenge(let username):
            return "Sending challenge to \(username)…"
        case .waitingForOpponent(let id):
            return "Waiting for \(id) to accept…"
        case .seeking(_, let label):
            return "Searching for opponent · \(label)…"
        case .openingMatch(let opponent):
            return "Found \(opponent)! Opening board…"
        }
    }

    // MARK: - Incoming challenges + active games

    @ViewBuilder
    private func incomingChallengesSection(_ lobby: LichessLobbyController) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Incoming challenges")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            ForEach(lobby.incomingChallenges, id: \.id) { challenge in
                incomingChallengeRow(challenge, lobby: lobby)
            }
        }
    }

    @ViewBuilder
    private func incomingChallengeRow(
        _ challenge: LichessChallenge,
        lobby: LichessLobbyController
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Circle()
                    .fill(.tint.opacity(0.18))
                    .frame(width: 32, height: 32)
                    .overlay(
                        Text(String((challenge.challenger?.name ?? "?").prefix(1)).uppercased())
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.tint)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        if let title = challenge.challenger?.title {
                            Text(title)
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.orange)
                        }
                        Text(challenge.challenger?.name ?? "Unknown")
                            .font(.callout.weight(.medium))
                        if let rating = challenge.challenger?.rating {
                            Text("(\(rating))")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(challengeDescription(challenge))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            HStack(spacing: 8) {
                Button {
                    wireOnGameSessionReadyAndOpenImmersive(lobby)
                    Task { await lobby.acceptIncoming(challenge.id) }
                } label: {
                    Label("Accept", systemImage: "checkmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Button(role: .destructive) {
                    Task { await lobby.declineIncoming(challenge.id, reason: nil) }
                } label: {
                    Label("Decline", systemImage: "xmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // (Active-games list removed deliberately: "not in the game =
    // game over". `refreshActiveGames` resigns orphans server-side,
    // so there is never a resumable game to show.)

    private func challengeDescription(_ challenge: LichessChallenge) -> String {
        let speedLabel = englishSpeed(challenge.speed)
        let timing = challenge.timeControl.show ?? speedLabel
        let kind = challenge.rated ? "rated" : "casual"
        return "\(speedLabel) · \(timing) · \(kind)"
    }

    private func englishSpeed(_ raw: String) -> String {
        switch raw.lowercased() {
        case "ultrabullet":   return "UltraBullet"
        case "bullet":        return "Bullet"
        case "blitz":         return "Blitz"
        case "rapid":         return "Rapid"
        case "classical":     return "Classical"
        case "correspondence": return "Correspondence"
        default: return raw
        }
    }

    // MARK: - Errors

    private func humanReadable(_ error: LichessError) -> String {
        switch error {
        case .notAuthenticated:  return "Lichess session not authenticated."
        case .tokenExpired:      return "Lichess session expired — sign in again."
        case .scopeInsufficient: return "Insufficient Lichess permissions."
        case .rateLimited:       return "Lichess is rate-limiting — try again in a minute."
        case .clientError(let s, _): return "Lichess error (\(s))."
        case .serverError:       return "Lichess is not responding right now."
        case .decoding:          return "Unrecognized Lichess response."
        case .network:           return "No connection to Lichess."
        case .invalidResponse:   return "Invalid Lichess response."
        }
    }

    // MARK: - Mode default state sync

    /// Sets sensible default time control / colour / level when the user
    /// switches to a different mode chip.
    private func syncDefaultsForMode(_ mode: GameMode) {
        switch mode {
        case .local:
            // Local has its own bindings on AppModel.matchSettings;
            // nothing to sync here.
            break
        case .quickPair:
            selectedTimeControl = .realTime(limitSeconds: 600, incrementSeconds: 0)
            selectedRated = false
        case .friend:
            selectedTimeControl = .realTime(limitSeconds: 300, incrementSeconds: 3)
            selectedRated = false
            selectedColor = .random
        case .lichessBot:
            selectedTimeControl = .realTime(limitSeconds: 600, incrementSeconds: 0)
            selectedColor = .white
            selectedAILevel = 3
        }
    }

    // MARK: - Match opening flows

    private func openLocalMatch() async {
        if appModel.immersiveSpaceState == .open {
            appModel.immersiveSpaceState = .inTransition
            await dismissImmersiveSpace()
            return
        }
        let rules = ChessKitRulesEngine()
        let humanSide = appModel.matchSettings.resolvedHumanSide()
        let whiteController: MatchCoordinator.SideController =
            humanSide == .white ? .human : .ai(appModel.matchSettings.aiSettings)
        let blackController: MatchCoordinator.SideController =
            humanSide == .black ? .human : .ai(appModel.matchSettings.aiSettings)
        let coordinator = MatchCoordinator(
            match: Match(),
            rules: rules,
            ai: StockfishEngine(),
            white: whiteController,
            black: blackController
        )
        appModel.activeSession = .local(coordinator)
        appModel.immersiveSpaceState = .inTransition
        switch await openImmersiveSpace(id: appModel.immersiveSpaceID) {
        case .opened:
            break
        case .userCancelled, .error:
            appModel.immersiveSpaceState = .closed
            appModel.activeSession = nil
        @unknown default:
            appModel.immersiveSpaceState = .closed
            appModel.activeSession = nil
        }
    }

    /// Matchmaking flow used by the Quick Pair "Find opponent" button.
    ///
    /// chess.com-style UX: instead of waiting in the 2D lobby card, we
    /// dive into the chosen environment immediately and float a
    /// `MatchmakingHUDView` over the board while the seek runs. When
    /// Lichess returns a paired game, `wireOnGameSessionReadyAndOpenImmersive`
    /// clears the matchmaking state and the immersive rebuilds with
    /// the real online session.
    private func startMatchmakingFlow(lobby: LichessLobbyController) async {
        wireOnGameSessionReadyAndOpenImmersive(lobby)

        // Populate the HUD state — what the user picked + their own
        // identity so the "You" side of the vs panel reads correctly.
        let label: String = {
            if case .realTime(let limit, let inc) = selectedTimeControl {
                return "\(limit/60)+\(inc)"
            }
            return "Custom"
        }()
        appModel.matchmaking = MatchmakingState(
            timeControlLabel: label,
            rated: selectedRated,
            selfUsername: appModel.lichess.account?.username ?? "You",
            selfRating: appModel.lichess.account?.perfs?["rapid"]?.rating
        )

        // Open the immersive into the chosen env. No activeSession yet —
        // ChessSceneView falls back to a default local renderer so the
        // user sees their environment + starting board with the HUD on
        // top. The real game rebuilds the scene when it arrives.
        appModel.immersiveSpaceState = .inTransition
        switch await openImmersiveSpace(id: appModel.immersiveSpaceID) {
        case .opened:
            lobby.quickPair(rated: selectedRated, timeControl: selectedTimeControl)
        case .userCancelled, .error:
            appModel.immersiveSpaceState = .closed
            appModel.matchmaking = nil
        @unknown default:
            appModel.immersiveSpaceState = .closed
            appModel.matchmaking = nil
        }
    }

    /// Sets up `lobby.onGameSessionReady` to flip `appModel.activeSession`
    /// and open the immersive space when the game is built.
    ///
    /// Crucial detail for the multi-game lifecycle: if an immersive is
    /// already open from a previous game, we MUST dismiss it before
    /// opening the new one. RealityView's `make` closure runs once and
    /// captures the active session at that time — toggling
    /// `appModel.activeSession` later doesn't trigger a rebuild, so a
    /// new session would render against the previous board state and
    /// be non-interactive (the drag handler still references the dead
    /// session). Dismiss-then-open forces a clean rebuild.
    private func wireOnGameSessionReadyAndOpenImmersive(
        _ lobby: LichessLobbyController
    ) {
        lobby.onGameSessionReady = {
            @MainActor [weak appModel = appModel] matchSession in
            guard let appModel else { return }
            Task { @MainActor in
                if case .online(let old) = appModel.activeSession {
                    await old.disconnect()
                }
                if appModel.immersiveSpaceState == .open {
                    appModel.immersiveSpaceState = .inTransition
                    await dismissImmersiveSpace()
                }

                appModel.activeSession = .online(matchSession)
                // Game is here — tear down the matchmaking HUD before
                // we rebuild the scene with the real online session.
                appModel.matchmaking = nil
                appModel.immersiveSpaceState = .inTransition
                switch await openImmersiveSpace(id: appModel.immersiveSpaceID) {
                case .opened:
                    break
                case .userCancelled, .error:
                    appModel.immersiveSpaceState = .closed
                    appModel.activeSession = nil
                @unknown default:
                    appModel.immersiveSpaceState = .closed
                    appModel.activeSession = nil
                }
            }
        }
    }

    /// Lazily instantiate the app-owned Lichess lobby controller once
    /// the session is signed in. Tears it down on sign-out.
    private func ensureLichessLobby() {
        if appModel.lichess.isSignedIn {
            if appModel.lichessLobby == nil {
                let lobby = LichessLobbyController(session: appModel.lichess)
                lobby.startEventStreamIfNeeded()
                lobby.onGameFinishReceived = { @MainActor [weak appModel = appModel] info in
                    guard let appModel else { return }
                    guard case .online(let session) = appModel.activeSession else { return }
                    guard session.gameID == info.gameId else { return }
                    session.applyRatingDiff(info.ratingDiff)
                }
                // A failed seek must also tear down the matchmaking
                // HUD floating in the immersive — otherwise it spins
                // forever over a seek that no longer exists.
                lobby.onSeekFailed = { @MainActor [weak appModel = appModel] _ in
                    appModel?.matchmaking = nil
                }
                appModel.lichessLobby = lobby
                Task { await lobby.refreshActiveGames() }
            }
        } else {
            if let lobby = appModel.lichessLobby {
                Task { await lobby.stopEventStream() }
                appModel.lichessLobby = nil
            }
        }
    }

    // MARK: - Number formatting helpers

    private static func duration(_ d: Duration, asSeconds: Void) -> Double {
        Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    private static func formatSeconds(_ s: Double) -> String {
        s == s.rounded() ? "\(Int(s)) s" : String(format: "%.1f s", s)
    }
}

// MARK: - Time-control presets

private struct TimePreset: Hashable {
    let label: String
    let spec: LichessTimeControlSpec
    let speed: LichessSpeed

    static let all: [TimePreset] = [
        // Bullet
        .init(label: "1+0",   spec: .realTime(limitSeconds: 60, incrementSeconds: 0),   speed: .bullet),
        .init(label: "2+1",   spec: .realTime(limitSeconds: 120, incrementSeconds: 1),  speed: .bullet),
        // Blitz
        .init(label: "3+0",   spec: .realTime(limitSeconds: 180, incrementSeconds: 0),  speed: .blitz),
        .init(label: "3+2",   spec: .realTime(limitSeconds: 180, incrementSeconds: 2),  speed: .blitz),
        .init(label: "5+0",   spec: .realTime(limitSeconds: 300, incrementSeconds: 0),  speed: .blitz),
        .init(label: "5+3",   spec: .realTime(limitSeconds: 300, incrementSeconds: 3),  speed: .blitz),
        // Rapid
        .init(label: "10+0",  spec: .realTime(limitSeconds: 600, incrementSeconds: 0),  speed: .rapid),
        .init(label: "10+5",  spec: .realTime(limitSeconds: 600, incrementSeconds: 5),  speed: .rapid),
        .init(label: "15+10", spec: .realTime(limitSeconds: 900, incrementSeconds: 10), speed: .rapid),
        // Classical
        .init(label: "30+0",  spec: .realTime(limitSeconds: 1800, incrementSeconds: 0),  speed: .classical),
        .init(label: "30+20", spec: .realTime(limitSeconds: 1800, incrementSeconds: 20), speed: .classical),
        // Correspondence
        .init(label: "Daily", spec: .correspondence(daysPerTurn: 3), speed: .correspondence),
    ]
}

private struct TimePresetSet {
    let speeds: Set<LichessSpeed>

    func contains(_ speed: LichessSpeed) -> Bool {
        speeds.contains(speed)
    }

    /// Quick Pair pool — Bullet/Blitz blocked server-side for OAuth
    /// Board API consumers (`SetupForm.scala:isBoardCompatible`).
    static let quickPairAllowed = TimePresetSet(speeds: [.rapid, .classical, .correspondence])

    /// Friend challenges + AI challenges — full set.
    static let friendAllowed = TimePresetSet(speeds: [.bullet, .blitz, .rapid, .classical, .correspondence])
}

// MARK: - Selectable row chrome

/// Shared background + stroke for the lobby's radio-style rows (time
/// control, play-as, match type). Selected: lit-marble cream wash +
/// bronze stroke. Unselected: plain glass. One modifier so every row
/// family stays visually identical.
private struct SelectableRowChrome: ViewModifier {
    let isSelected: Bool

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Chess.Radius.row, style: .continuous)
                    .fill(isSelected
                          ? AnyShapeStyle(Chess.Palette.cream.opacity(0.16))
                          : AnyShapeStyle(.thinMaterial))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Chess.Radius.row, style: .continuous)
                    .strokeBorder(isSelected
                                  ? Chess.Palette.bronze.opacity(0.55)
                                  : .white.opacity(0.10),
                                  lineWidth: isSelected ? 1 : 0.5)
            )
    }
}

// MARK: - Selection chip style

/// Toggle-like chip used by the lobby's preset / colour / level / mode
/// selectors. Used in place of `.borderedProminent` vs `.bordered`
/// because the system distinction is too subtle on visionOS for a
/// dense grid where the active option needs to be unmissable.
///
/// Selected: filled accent background + white text + slight scale on
/// press. Unselected: hollow tertiary background + primary text.
private struct SelectionButtonStyle: ButtonStyle {
    enum Shape: Equatable {
        case capsule
        case roundedRect(cornerRadius: CGFloat)
    }

    let isSelected: Bool
    var shape: Shape = .capsule

    func makeBody(configuration: Configuration) -> some View {
        let fill = isSelected
            ? AnyShapeStyle(Chess.Palette.cream.opacity(0.20))
            : AnyShapeStyle(Color.gray.opacity(0.18))
        let stroke: AnyShapeStyle = isSelected
            ? AnyShapeStyle(Chess.Palette.bronze.opacity(0.45))
            : AnyShapeStyle(Color.secondary.opacity(0.25))
        return configuration.label
            .foregroundStyle(.primary)
            .fontWeight(isSelected ? .semibold : .regular)
            .background {
                switch shape {
                case .capsule:
                    Capsule().fill(fill)
                case .roundedRect(let r):
                    RoundedRectangle(cornerRadius: r, style: .continuous).fill(fill)
                }
            }
            .overlay {
                switch shape {
                case .capsule:
                    Capsule().stroke(stroke, lineWidth: isSelected ? 1 : 0.5)
                case .roundedRect(let r):
                    RoundedRectangle(cornerRadius: r, style: .continuous)
                        .stroke(stroke, lineWidth: isSelected ? 1 : 0.5)
                }
            }
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

#Preview(windowStyle: .automatic) {
    LobbyView()
        .environment(AppModel())
}

// MARK: - Matchmaking HUD

/// Floating panel rendered over the immersive board while we wait for
/// Lichess to pair us. Shows the user on the left and an honest
/// "searching the pool" placeholder on the right (NO fake opponent
/// names — the old cycling carousel of invented usernames read as
/// "found an opponent, then discarded them" over and over). The time
/// control + rated flag sit below, with a cancel button.
/// Auto-disappears when `appModel.matchmaking` is cleared (when
/// `onGameSessionReady` fires, the seek fails, or the user cancels).
@MainActor
struct MatchmakingHUDView: View {
    let state: MatchmakingState
    var onCancel: () -> Void
    /// Offered after 30 s of an unmatched RATED seek — Board-API
    /// seeks are lobby hooks, and rated hooks pair far slower than
    /// casual ones (which every lobby visitor can take).
    var onSwitchToCasual: (() -> Void)? = nil

    @State private var elapsed: Int = 0
    private let elapsedTimer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: Chess.Space.m) {
            Text("Finding opponent…")
                .font(.system(.title2, design: .serif).weight(.semibold))
                .foregroundStyle(Chess.Palette.accent)

            HStack(spacing: Chess.Space.l) {
                avatarColumn(name: state.selfUsername,
                             rating: state.selfRating,
                             pulse: true,
                             tag: "YOU")
                Text("vs")
                    .font(.system(.title, design: .serif).weight(.semibold))
                    .foregroundStyle(Chess.Palette.bronze)
                seekingColumn
            }

            HStack(spacing: Chess.Space.s) {
                metaChip(state.timeControlLabel, icon: "clock.fill")
                metaChip(state.rated ? "Rated" : "Casual",
                         icon: state.rated ? "trophy.fill" : "circle.dashed")
                metaChip("\(elapsed)s",
                         icon: "hourglass")
            }

            // After 30 s of unmatched RATED seeking, surface the
            // casual escape hatch — same time control, far busier
            // visibility (anonymous lobby visitors can take it).
            if state.rated, elapsed >= 30, let onSwitchToCasual {
                VStack(spacing: 6) {
                    Text("Rated seeks can take a while — casual pairs much faster.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button {
                        onSwitchToCasual()
                    } label: {
                        Label("Switch to Casual", systemImage: "bolt.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Chess.Palette.bronze)
                    .controlSize(.regular)
                }
            }

            Button(role: .cancel) {
                onCancel()
            } label: {
                Label("Cancel", systemImage: "xmark")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
        .padding(Chess.Space.l)
        .frame(width: 480)
        .background(.regularMaterial,
                    in: RoundedRectangle(cornerRadius: Chess.Radius.hero,
                                         style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Chess.Radius.hero,
                             style: .continuous)
                .strokeBorder(Chess.Palette.bronze.opacity(0.45), lineWidth: 1)
        )
        .onReceive(elapsedTimer) { _ in elapsed += 1 }
    }

    /// Honest right-hand column: a pulsing search badge instead of
    /// invented opponents. The real opponent only ever appears via
    /// `gameStart` → `onGameSessionReady`, which replaces this HUD
    /// with the actual game.
    private var seekingColumn: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(Chess.Palette.cream.opacity(0.10))
                Circle()
                    .strokeBorder(Chess.Palette.bronze.opacity(0.40), lineWidth: 1.5)
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(Chess.Palette.bronze)
            }
            .frame(width: 84, height: 84)
            .modifier(PulseModifier(active: true))

            Text("SEEKING")
                .font(Chess.Typography.eyebrow())
                .foregroundStyle(.secondary)
            Text("Searching the pool…")
                .font(.callout.weight(.semibold))
                .lineLimit(1)
            Text("Lichess pairs by rating")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
    }

    private func avatarColumn(name: String, rating: Int?, pulse: Bool, tag: String) -> some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(Chess.Palette.cream.opacity(0.18))
                Circle()
                    .strokeBorder(Chess.Palette.bronze.opacity(0.55), lineWidth: 1.5)
                Text(String(name.prefix(1)).uppercased())
                    .font(.system(.largeTitle, design: .serif).weight(.semibold))
                    .foregroundStyle(Chess.Palette.bronze)
            }
            .frame(width: 84, height: 84)
            .scaleEffect(pulse ? 1.0 : 0.96)
            .modifier(PulseModifier(active: pulse))

            Text(tag)
                .font(Chess.Typography.eyebrow())
                .foregroundStyle(.secondary)
            Text(name)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
            if let r = rating {
                Text("\(r)")
                    .font(.caption)
                    .foregroundStyle(Chess.Palette.bronze)
            } else {
                Text("—")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func metaChip(_ text: String, icon: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .foregroundStyle(Chess.Palette.bronze)
            Text(text)
                .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.thinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Chess.Palette.bronze.opacity(0.35), lineWidth: 0.5))
    }
}

/// Slow breathing pulse for the "you" avatar — repeats forever.
private struct PulseModifier: ViewModifier {
    let active: Bool
    @State private var on = false
    func body(content: Content) -> some View {
        content
            .scaleEffect(on && active ? 1.04 : 1.0)
            .onAppear {
                guard active else { return }
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                    on = true
                }
            }
    }
}
