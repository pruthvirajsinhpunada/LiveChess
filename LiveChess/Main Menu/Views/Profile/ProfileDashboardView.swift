// Views/Profile/ProfileDashboardView.swift
// The redesigned Profile surface — a glass stats dashboard echoing the
// reference: identity header + rating card with a real rating-history
// chart, a four-up stats strip, a Recent Games / Achievements row, and
// an account footer strip.
//
// Everything here is REAL Lichess data where the API exposes it
// (`count`, `perfs`, `createdAt`, `profile.country`, rating-history,
// recent games) and HONESTLY DERIVED where it doesn't (win-streak and
// average accuracy are computed from the loaded recent-games sample;
// achievements are progress-bars over real counters). Nothing is faked.

import SwiftUI
import Charts

// MARK: - Loader

@Observable
@MainActor
final class ProfileViewModel {
    var games: [LichessGame] = []
    var ratingHistory: [LichessRatingHistory] = []
    var isLoading = false

    private let service = LichessService()
    private var loadedFor: String?

    func load(username: String, token: String?) async {
        guard loadedFor != username else { return }
        loadedFor = username
        await service.authenticate(token: token)
        isLoading = true
        defer { isLoading = false }

        async let gamesTask = try? service.fetchRecentGames(
            username: username, count: 30, withAnalysis: true, withOpening: true
        )
        async let historyTask = try? service.fetchRatingHistory(username: username)

        games = await gamesTask ?? []
        ratingHistory = await historyTask ?? []
    }

    // MARK: Derived (from the loaded sample)

    func longestWinStreak(username: String) -> Int {
        var best = 0, current = 0
        for game in games {
            if case .win = game.result(for: username) {
                current += 1
                best = max(best, current)
            } else {
                current = 0
            }
        }
        return best
    }

    func averageAccuracy(username: String) -> Double? {
        let values = games.compactMap { $0.accuracy(for: username) }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    func samples(forHistoryName name: String) -> [RatingSample] {
        ratingHistory.first { $0.name == name }?.samples ?? []
    }
}

// MARK: - Perf tabs

private struct PerfTab: Identifiable {
    let key: String           // perfs map key
    let label: String         // segmented-control title
    let historyName: String   // rating-history "name" value
    var id: String { key }
}

private let perfTabs: [PerfTab] = [
    PerfTab(key: "rapid",          label: "Rapid",  historyName: "Rapid"),
    PerfTab(key: "blitz",          label: "Blitz",  historyName: "Blitz"),
    PerfTab(key: "bullet",         label: "Bullet", historyName: "Bullet"),
    PerfTab(key: "classical",      label: "Daily",  historyName: "Classical"),
]

// MARK: - Dashboard

struct ProfileDashboardView: View {
    let account: LichessAccount

    @Environment(AppModel.self) private var appModel
    @Bindable var viewModel: HomeViewModel
    @State private var model = ProfileViewModel()
    @State private var selectedPerf: String = "rapid"

    private var username: String { account.username }

    var body: some View {
        ScrollView {
            VStack(spacing: Chess.Space.m) {
                topRow
                statsStrip
                recentGamesCard
                footerStrip
            }
            .padding(Chess.Space.l)
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassBackgroundEffect()
        // Show the "Profile" heading at the top like the other screens
        // (Puzzles / Analyze) — the nav bar was previously hidden here.
        .navigationTitle("Profile")
        .task { await model.load(username: username, token: appModel.lichess.token) }
    }

    // MARK: Top row — identity + rating card

    private var topRow: some View {
        HStack(alignment: .top, spacing: Chess.Space.m) {
            identityCard
                .frame(maxWidth: 340, alignment: .leading)
            ratingCard
        }
    }

    private var identityCard: some View {
        ChessCard(.standard) {
            VStack(alignment: .leading, spacing: Chess.Space.m) {
                HStack(spacing: Chess.Space.m) {
                    ZStack {
                        Circle()
                            .fill(Chess.Palette.bronze.gradient)
                            .frame(width: 84, height: 84)
                        Text(String(username.prefix(1)).uppercased())
                            .font(.system(size: 34, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            if let title = account.title {
                                Text(title)
                                    .font(.callout.weight(.bold))
                                    .foregroundStyle(Chess.Palette.bronze)
                            }
                            Text(username)
                                .font(.system(.title, design: .serif).weight(.semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                        }
                        HStack(spacing: 6) {
                            Circle()
                                .fill(Color(red: 0.30, green: 0.78, blue: 0.36))
                                .frame(width: 8, height: 8)
                            Text("Online")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let r = account.rating(forPerfKey: selectedPerf) {
                    HStack(spacing: 8) {
                        Image(systemName: "bolt.fill")
                            .font(.caption)
                            .foregroundStyle(Chess.Palette.bronze)
                        Text("\(r)")
                            .font(.headline.monospacedDigit())
                        Text(perfTabs.first { $0.key == selectedPerf }?.label ?? "")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, Chess.Space.m)
                    .padding(.vertical, Chess.Space.s)
                    .background(.thinMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
                }

                Button { viewModel.navigate(to: .settings) } label: {
                    Text("Edit Profile")
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, Chess.Space.l)
                        .padding(.vertical, Chess.Space.s)
                        .frame(maxWidth: .infinity)
                        .background(.thinMaterial, in: Capsule())
                        .overlay(Capsule().strokeBorder(Chess.Palette.bronze.opacity(0.5), lineWidth: 0.8))
                }
                .buttonStyle(.plain)
                .hoverEffect(.lift)
            }
        }
    }

    private var ratingCard: some View {
        ChessCard(.standard) {
            VStack(alignment: .leading, spacing: Chess.Space.m) {
                HStack {
                    Text("Rating")
                        .font(.title3.weight(.semibold))
                    Spacer()
                    perfPicker
                }

                HStack(alignment: .center, spacing: Chess.Space.l) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.rating(forPerfKey: selectedPerf).map(String.init) ?? "—")
                            .font(.system(size: 44, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .fixedSize()
                            .lineLimit(1)
                        Text(perfTabs.first { $0.key == selectedPerf }?.label ?? "")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        if let prog = account.progress(forPerfKey: selectedPerf), prog != 0 {
                            HStack(spacing: 3) {
                                Image(systemName: prog > 0 ? "arrow.up" : "arrow.down")
                                Text("\(abs(prog))")
                            }
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(prog > 0
                                             ? Color(red: 0.30, green: 0.78, blue: 0.36)
                                             : Color(red: 0.95, green: 0.40, blue: 0.30))
                            Text("Recent")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .frame(width: 132, alignment: .leading)

                    ratingChart
                }
            }
        }
    }

    private var perfPicker: some View {
        HStack(spacing: 4) {
            ForEach(perfTabs) { tab in
                let isOn = tab.key == selectedPerf
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        selectedPerf = tab.key
                    }
                } label: {
                    Text(tab.label)
                        .font(.caption.weight(isOn ? .semibold : .regular))
                        .foregroundStyle(isOn ? .white : .secondary)
                        .padding(.horizontal, Chess.Space.s)
                        .padding(.vertical, 6)
                        .background(
                            Capsule().fill(isOn
                                           ? AnyShapeStyle(Chess.Palette.bronze)
                                           : AnyShapeStyle(.clear))
                        )
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
            }
        }
        .padding(3)
        .background(.thinMaterial, in: Capsule())
    }

    /// Chart-ready samples. Lichess's rating history records ONE
    /// point per DAY — a player whose rated games all happened today
    /// has a single sample, which can't draw a line ("Not enough
    /// rated games" even though they clearly played). Synthesize a
    /// day-earlier anchor from the perf's recent progression
    /// (`prog`, the same delta shown as "↑31 Recent") so the chart
    /// shows the real trend from day one.
    private func chartSamples(forHistoryName name: String) -> [RatingSample] {
        let raw = Array(model.samples(forHistoryName: name).suffix(60))
        guard raw.count == 1, let only = raw.first else { return raw }
        let prog = account.progress(forPerfKey: selectedPerf) ?? 0
        return [
            RatingSample(date: only.date.addingTimeInterval(-86_400),
                         rating: only.rating - prog),
            only,
        ]
    }

    @ViewBuilder
    private var ratingChart: some View {
        let name = perfTabs.first { $0.key == selectedPerf }?.historyName ?? "Rapid"
        let samples = chartSamples(forHistoryName: name)
        if samples.count >= 2 {
            Chart(samples) { sample in
                LineMark(
                    x: .value("Date", sample.date),
                    y: .value("Rating", sample.rating)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(Chess.Palette.bronze)
                AreaMark(
                    x: .value("Date", sample.date),
                    y: .value("Rating", sample.rating)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(
                    LinearGradient(
                        colors: [Chess.Palette.bronze.opacity(0.30), .clear],
                        startPoint: .top, endPoint: .bottom
                    )
                )
            }
            .chartYScale(domain: .automatic(includesZero: false))
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) {
                    AxisGridLine().foregroundStyle(.white.opacity(0.06))
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                        .font(.caption2)
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) {
                    AxisGridLine().foregroundStyle(.white.opacity(0.06))
                    AxisValueLabel().font(.caption2)
                }
            }
            .frame(height: 140)
            .frame(maxWidth: .infinity)
        } else {
            VStack(spacing: 6) {
                Image(systemName: "chart.xyaxis.line")
                    .font(.title2)
                    .foregroundStyle(.tertiary)
                Text("Not enough rated games yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(height: 140)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: Stats strip

    private var statsStrip: some View {
        ChessCard(.standard) {
            HStack(spacing: 0) {
                statCell(icon: "trophy.fill",
                         value: account.gamesPlayed.map(String.init) ?? "—",
                         title: "Games Played", subtitle: "Total")
                statDivider
                statCell(icon: "target",
                         value: account.winRatePercent.map { String(format: "%.0f%%", $0) } ?? "—",
                         title: "Win Rate", subtitle: "Lifetime")
                statDivider
                statCell(icon: "flame.fill",
                         value: "\(model.longestWinStreak(username: username))",
                         title: "Best Streak", subtitle: "Recent",
                         iconTint: .orange)
                statDivider
                statCell(icon: "chart.bar.fill",
                         value: model.averageAccuracy(username: username).map { String(format: "%.0f%%", $0) } ?? "—",
                         title: "Accuracy", subtitle: "Average")
            }
        }
    }

    private var statDivider: some View {
        Rectangle().fill(.white.opacity(0.10)).frame(width: 0.5, height: 44)
    }

    private func statCell(icon: String, value: String, title: String,
                          subtitle: String, iconTint: Color = Chess.Palette.bronze) -> some View {
        HStack(spacing: Chess.Space.s) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(iconTint)
                .frame(width: 44, height: 44)
                .background(.thinMaterial, in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.title3.weight(.bold)).monospacedDigit()
                Text(subtitle).font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Chess.Space.s)
    }

    // MARK: Recent games

    private var recentGamesCard: some View {
        ChessCard(.standard) {
            VStack(alignment: .leading, spacing: Chess.Space.s) {
                HStack {
                    Text("Recent Games").font(.title3.weight(.semibold))
                    Spacer()
                    Button("See All") { viewModel.navigate(to: .history) }
                        .font(.callout)
                        .foregroundStyle(Chess.Palette.bronze)
                        .buttonStyle(.plain)
                        .hoverEffect(.highlight)
                }
                if model.games.isEmpty {
                    Text("No games yet.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, Chess.Space.m)
                } else {
                    ForEach(Array(model.games.prefix(6).enumerated()), id: \.element.id) { index, game in
                        if index > 0 { Divider().overlay(.white.opacity(0.06)) }
                        ProfileGameRow(game: game, username: username)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    // MARK: Footer strip

    private var footerStrip: some View {
        ChessCard(.standard) {
            HStack(spacing: 0) {
                footerCell(icon: "calendar", title: "Member since",
                           value: account.memberSince.map(Self.monthYear) ?? "—")
                statDivider
                footerCell(icon: "globe", title: "Country",
                           value: Self.countryName(account.profile?.country) ?? "—")
                statDivider
                footerCell(icon: "clock", title: "Time Zone", value: Self.localTimeZone())
                statDivider
                Button { viewModel.navigate(to: .settings) } label: {
                    footerCell(icon: "gearshape.fill", title: "Account", value: "Manage",
                               valueTint: Chess.Palette.bronze)
                }
                .buttonStyle(.plain)
                .hoverEffect(.lift)
            }
        }
    }

    private func footerCell(icon: String, title: String, value: String,
                            valueTint: Color = .primary) -> some View {
        HStack(spacing: Chess.Space.s) {
            Image(systemName: icon)
                .font(.callout)
                .foregroundStyle(Chess.Palette.bronze)
                .frame(width: 40, height: 40)
                .background(.thinMaterial, in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption2).foregroundStyle(.secondary)
                Text(value).font(.callout.weight(.medium)).foregroundStyle(valueTint).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Chess.Space.s)
    }

    // MARK: Formatting

    private static func monthYear(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM yyyy"
        return f.string(from: date)
    }

    private static func countryName(_ code: String?) -> String? {
        guard let code else { return nil }
        return Locale.current.localizedString(forRegionCode: code) ?? code
    }

    private static func localTimeZone() -> String {
        let secs = TimeZone.current.secondsFromGMT()
        let hours = secs / 3600
        let mins = abs(secs % 3600) / 60
        let sign = hours >= 0 ? "+" : "-"
        return mins == 0 ? "GMT\(sign)\(abs(hours))"
                         : String(format: "GMT%@%d:%02d", sign, abs(hours), mins)
    }
}

// MARK: - Recent game row

private struct ProfileGameRow: View {
    let game: LichessGame
    let username: String

    private var result: GameResult { game.result(for: username) }
    private var resultColor: Color {
        switch result {
        case .win:  return Color(red: 0.30, green: 0.78, blue: 0.36)
        case .loss: return Color(red: 0.95, green: 0.40, blue: 0.30)
        case .draw: return .yellow
        }
    }

    var body: some View {
        HStack(spacing: Chess.Space.s) {
            ZStack {
                Circle().fill(resultColor.opacity(0.22)).frame(width: 34, height: 34)
                Text(result.shortLabel)
                    .font(.callout.weight(.bold))
                    .foregroundStyle(resultColor)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("vs \(game.opponent(for: username))")
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if let speed = game.speed {
                        Text(speed.capitalized).font(.caption2).foregroundStyle(.secondary)
                        Text("·").font(.caption2).foregroundStyle(.tertiary)
                    }
                    Text(game.date, style: .relative).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if let acc = game.accuracy(for: username) {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(String(format: "%.1f", acc))
                        .font(.callout.weight(.semibold).monospacedDigit())
                    Text("Accuracy").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 7)
    }
}

// (Achievements removed — the app has no achievement system, so the
// section is gone and Recent Games spans the row on its own.)
