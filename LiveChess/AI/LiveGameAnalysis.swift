import Foundation
import Observation

/// Analyzes the game WHILE it's being played, so the post-game
/// "Analyze Game" review opens with most (often all) classifications
/// already computed instead of staring at a spinner.
///
/// Quality contract: this uses the SAME `GameAnalyzer` code path,
/// depth, and MultiPV as the post-game batch — identical
/// classifications. Only the *timing* changes: the work happens
/// during the opponent's (and your) thinking time instead of after
/// the game. The one knob that differs is the thread budget (3 cores
/// instead of all spare cores) so gameplay + RealityKit rendering
/// keep headroom — thread count affects speed, never search results.
///
/// Lifecycle: `AppModel` creates one per live game (local or online),
/// feeds it via 1 Hz polling of the session's move list (polling
/// keeps the game plumbing untouched — a depth-15 ply takes seconds
/// anyway, so sub-second move latency is irrelevant), and harvests
/// `validatedResults(for:)` when the user opens the review.
@MainActor
@Observable
final class LiveGameAnalysis {

    /// Must match `ReviewSession`'s batch depth — same searches,
    /// same classifications, interchangeable results.
    static let depth = 15

    /// Per-ply classifications in absolute ply order (ids match).
    private(set) var results: [MoveAnalysis] = []

    private let analyzer: GameAnalyzer
    private let rules: any RulesEngine
    private var knownMoves: [Move] = []
    private var pumping = false
    private var feedTask: Task<Void, Never>?
    private var consecutiveFailures = 0

    init(rules: any RulesEngine = ChessKitRulesEngine()) {
        self.rules = rules
        self.analyzer = GameAnalyzer(multiPV: 3, coreCount: 3)
    }

    /// Starts polling `movesProvider` once a second, queueing any new
    /// plies for analysis.
    func startFeeding(_ movesProvider: @escaping @MainActor () -> [Move]) {
        feedTask?.cancel()
        feedTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.sync(moves: movesProvider())
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stopFeeding() {
        feedTask?.cancel()
        feedTask = nil
    }

    /// The analyzed prefix, returned only if it matches the final
    /// move list ply-for-ply — guards against takebacks / desyncs
    /// silently seeding a review with wrong classifications.
    func validatedResults(for moves: [Move]) -> [MoveAnalysis] {
        let prefix = results.prefix(moves.count)
        for (index, analysis) in prefix.enumerated() {
            guard analysis.playedUCI == moves[index].uci else { return [] }
        }
        return Array(prefix)
    }

    func shutdown() {
        stopFeeding()
        let engine = analyzer
        Task { await engine.shutdown() }
    }

    // MARK: - Pump

    private func sync(moves: [Move]) {
        guard moves.count > knownMoves.count else { return }
        // Takeback / rewind protection: only extend on a clean
        // append. On mismatch we stop feeding — the review's batch
        // pass re-analyzes from scratch and `validatedResults`
        // rejects the stale prefix.
        guard moves.prefix(knownMoves.count).map(\.uci)
                == knownMoves.map(\.uci) else {
            stopFeeding()
            return
        }
        knownMoves = moves
        pump()
    }

    private func pump() {
        guard !pumping,
              results.count < knownMoves.count,
              consecutiveFailures < 3 else { return }
        pumping = true

        let firstIndex = results.count
        let chunk = Array(knownMoves[firstIndex...])
        let startPosition = position(afterPly: firstIndex)

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let stream = await self.analyzer.analyzeStream(
                    startPosition: startPosition,
                    moves: chunk,
                    depth: Self.depth,
                    rules: self.rules,
                    firstPlyIndex: firstIndex
                )
                for try await analysis in stream {
                    self.results.append(analysis)
                }
                self.consecutiveFailures = 0
            } catch {
                // Engine hiccup — keep what we have. The review's
                // batch pass finishes whatever is missing. Bounded
                // retries so a dead engine can't spin the pump.
                self.consecutiveFailures += 1
            }
            self.pumping = false
            self.pump()   // more moves may have arrived meanwhile
        }
    }

    /// Position before ply `count` — replayed from the start. Cheap
    /// (pure rules application) even for long games.
    private func position(afterPly count: Int) -> Position {
        var position = Position.standardStart
        for move in knownMoves.prefix(count) {
            position = (try? rules.apply(move, to: position)) ?? position
        }
        return position
    }
}
