// Views/Home/NavRailView.swift
// The left navigation rail for the redesigned home dashboard.
//
// Replaces the old `List`-style `SidebarView`. A slim floating glass
// capsule of icon buttons — Home / Puzzles / Learn / Analyze — plus a
// "More" menu at the bottom that exposes the secondary destinations
// (Play modes, History, Profile, Settings, Notifications) without
// crowding the rail. Active item gets a bronze-lit disc so the user
// always knows where they are.

import SwiftUI

struct NavRailView: View {

    @Bindable var viewModel: HomeViewModel

    /// Drives the "Log out" action in the More menu.
    @Environment(AppModel.self) private var appModel

    /// Primary rail destinations, top-to-bottom: Home, Puzzles,
    /// Analyze, Profile.
    private let items: [Item] = [
        Item(destination: .home,       title: "Home",     icon: "house.fill"),
        Item(destination: .puzzles,    title: "Puzzles",  icon: "puzzlepiece.fill"),
        Item(destination: .gameReview, title: "Analyze",  icon: "chart.bar.fill"),
        Item(destination: .profile,    title: "Profile",  icon: "person.fill"),
    ]

    var body: some View {
        VStack(spacing: Chess.Space.l) {

            VStack(spacing: Chess.Space.m) {
                ForEach(items) { item in
                    NavRailButton(
                        item: item,
                        isSelected: isSelected(item.destination)
                    ) {
                        viewModel.navigate(to: item.destination)
                    }
                }
            }

            Spacer(minLength: Chess.Space.m)

            // Secondary destinations live behind a "More" menu so the
            // rail stays to four primary glyphs like the reference.
            moreMenu
                .padding(.bottom, Chess.Space.s)
        }
        .frame(width: 100)
        .padding(.vertical, Chess.Space.m)
        // Its OWN raised glass panel — a separate floating capsule to
        // the left of the content window, not merged into it. The
        // visionOS glass effect gives it real depth + shadow so it
        // reads as a distinct surface.
        .glassBackgroundEffect(in: Capsule(style: .continuous))
    }

    /// Treat a `nil` selection (visionOS clears it when you re-tap the
    /// active row) as Home so the Home disc never goes dark.
    private func isSelected(_ destination: AppDestination) -> Bool {
        (viewModel.selectedDestination ?? .home) == destination
    }

    // MARK: - More menu

    private var moreMenu: some View {
        Menu {
            Section {
                Button {
                    viewModel.navigate(to: .notifications)
                } label: {
                    Label("Notifications", systemImage: "bell.fill")
                }
                Button {
                    viewModel.navigate(to: .settings)
                } label: {
                    Label("Settings", systemImage: "gearshape.fill")
                }
            }
            // Sign out only makes sense when there's a session to end.
            if appModel.lichess.isSignedIn {
                Section {
                    Button(role: .destructive) {
                        Task { await appModel.lichess.signOut() }
                    } label: {
                        Label("Log out", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }
            }
        } label: {
            VStack(spacing: 6) {
                Image(systemName: "ellipsis")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 52, height: 52)
                    .background(.thinMaterial, in: Circle())
                    .overlay(Circle().strokeBorder(.white.opacity(0.10), lineWidth: 0.5))
                Text("More")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .hoverEffect(.lift)
    }

    // MARK: - Item model

    struct Item: Identifiable {
        let destination: AppDestination
        let title: String
        let icon: String
        var id: AppDestination { destination }
    }
}

// MARK: - Rail button

private struct NavRailButton: View {
    let item: NavRailView.Item
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(isSelected
                              ? AnyShapeStyle(Chess.Palette.bronze.opacity(0.28))
                              : AnyShapeStyle(.thinMaterial))
                        .frame(width: 52, height: 52)
                        .overlay(
                            Circle().strokeBorder(
                                isSelected
                                    ? Chess.Palette.bronze.opacity(0.85)
                                    : .white.opacity(0.10),
                                lineWidth: isSelected ? 1.2 : 0.5
                            )
                        )
                        // Soft bronze glow on the active disc — the
                        // "lit" cue from the reference.
                        .shadow(color: isSelected
                                ? Chess.Palette.bronze.opacity(0.55)
                                : .clear,
                                radius: 8)

                    Image(systemName: item.icon)
                        .font(.title3)
                        .foregroundStyle(isSelected ? Chess.Palette.bronze : .white)
                }

                Text(item.title)
                    .font(.caption2.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.lift)
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

#Preview {
    NavRailView(viewModel: HomeViewModel())
        .environment(AppModel())
        .padding(40)
}
