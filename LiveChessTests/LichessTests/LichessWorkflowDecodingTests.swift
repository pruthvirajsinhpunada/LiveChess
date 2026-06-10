import Testing
import Foundation
@testable import LiveChess

/// Regression suite for the online-play workflow decode bugs.
///
/// Root cause of "finding real opponent not working": Lichess sends
/// `status` in THREE different shapes depending on endpoint — string
/// label (game stream), `{id, name}` object (event stream +
/// account/playing), bare int id (legacy game JSON). The old
/// string-only `LichessStatus` made every `gameStart` / `gameFinish`
/// event line undecodable, and `NDJSON` silently drops undecodable
/// lines — so paired matches never opened and finishes never landed.
///
/// Fixtures below are the REAL wire shapes (Lichess OpenAPI examples,
/// trimmed to the keys our models touch). If any of these fail, the
/// matchmaking / friend-challenge / finish pipeline is broken again.
@Suite("Lichess workflow decoding")
struct LichessWorkflowDecodingTests {

    // MARK: LichessStatus — all three wire shapes

    @Test func statusDecodesFromStringLabel() throws {
        let status = try JSONDecoder().decode(LichessStatus.self, from: Data(#""mate""#.utf8))
        #expect(status == .mate)
        #expect(status.isFinished)
    }

    @Test func statusDecodesFromBareIntID() throws {
        let status = try JSONDecoder().decode(LichessStatus.self, from: Data("20".utf8))
        #expect(status == .started)
        #expect(!status.isFinished)
    }

    @Test func statusDecodesFromObjectShape() throws {
        let status = try JSONDecoder().decode(
            LichessStatus.self,
            from: Data(#"{"id":34,"name":"draw"}"#.utf8)
        )
        #expect(status == .draw)
        #expect(status.isFinished)
    }

    @Test func unknownStatusLabelDegradesInsteadOfThrowing() throws {
        let status = try JSONDecoder().decode(
            LichessStatus.self,
            from: Data(#""someFutureStatus""#.utf8)
        )
        #expect(status == .unknownFinish)
    }

    // MARK: Event stream — gameStart / gameFinish (object status!)

    /// Verbatim shape of a `gameStart` frame on `/api/stream/event`.
    /// THE regression: `status` is an object here, not a string.
    @Test func gameStartEventDecodes() throws {
        let line = #"""
        {"type":"gameStart","game":{"fullId":"rCRw1AuOfan1","gameId":"rCRw1AuO","fen":"rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1","color":"white","lastMove":"","source":"lobby","status":{"id":20,"name":"started"},"variant":{"key":"standard","name":"Standard"},"speed":"rapid","perf":"rapid","rated":true,"hasMoved":false,"opponent":{"id":"philippe","username":"Philippe","rating":1790},"isMyTurn":true,"secondsLeft":600,"compat":{"bot":false,"board":true},"id":"rCRw1AuO"}}
        """#
        let event = try JSONDecoder().decode(LichessEvent.self, from: Data(line.utf8))
        guard case .gameStart(let info) = event else {
            Issue.record("Expected .gameStart, got \(event)")
            return
        }
        #expect(info.gameId == "rCRw1AuO")
        #expect(info.color == .white)
        #expect(info.rated)
        #expect(info.status == .started)
        #expect(info.opponent.username == "Philippe")
        #expect(info.opponent.rating == 1790)
    }

    /// `gameFinish` carries the result + ratingDiff the post-game
    /// banner needs. Same object-status shape.
    @Test func gameFinishEventDecodes() throws {
        let line = #"""
        {"type":"gameFinish","game":{"fullId":"rCRw1AuOfan1","gameId":"rCRw1AuO","fen":"r1bqkbnr/pppp2pp/2n1pp2/8/8/3PP3/PPPB1PPP/RN1QKBNR w KQkq - 2 4","color":"white","lastMove":"e7f8","source":"lobby","status":{"id":31,"name":"resign"},"variant":{"key":"standard","name":"Standard"},"speed":"rapid","perf":"rapid","rated":true,"hasMoved":true,"opponent":{"id":"philippe","username":"Philippe","rating":1790,"ratingDiff":-8},"isMyTurn":false,"winner":"white","ratingDiff":8,"id":"rCRw1AuO"}}
        """#
        let event = try JSONDecoder().decode(LichessEvent.self, from: Data(line.utf8))
        guard case .gameFinish(let info) = event else {
            Issue.record("Expected .gameFinish, got \(event)")
            return
        }
        #expect(info.status == .resign)
        #expect(info.winner == .white)
        #expect(info.ratingDiff == 8)
    }

    // MARK: /api/account/playing — the seek-completion fallback path

    /// The poll that opens a freshly paired game when the event stream
    /// misses `gameStart`. Note `status` object inside each item.
    @Test func accountPlayingDecodes() throws {
        let json = #"""
        {"nowPlaying":[{"fullId":"rCRw1AuOfan1","gameId":"rCRw1AuO","fen":"rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1","color":"white","lastMove":"","source":"lobby","status":{"id":20,"name":"started"},"variant":{"key":"standard","name":"Standard"},"speed":"rapid","perf":"rapid","rated":true,"hasMoved":false,"opponent":{"id":"philippe","username":"Philippe","rating":1790},"isMyTurn":true,"secondsLeft":597}]}
        """#
        let playing = try JSONDecoder().decode(LichessNowPlaying.self, from: Data(json.utf8))
        #expect(playing.nowPlaying.count == 1)
        #expect(playing.nowPlaying[0].gameId == "rCRw1AuO")
        #expect(playing.nowPlaying[0].opponent.username == "Philippe")
        #expect(playing.nowPlaying[0].isMyTurn)
    }

    // MARK: Challenge flows

    /// `/api/challenge/ai` — the created-game response. `status` here
    /// has shipped as object, int, AND string across API eras; all
    /// three must decode ("Unrecognized Lichess response" regression).
    @Test(arguments: [
        #"{"id":"q7ZvsdUF","rated":false,"variant":{"key":"standard","name":"Standard"},"speed":"rapid","perf":"rapid","createdAt":1706185076073,"fullId":"q7ZvsdUFkkXz","player":"white","status":{"id":20,"name":"started"},"fen":"rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"}"#,
        #"{"id":"q7ZvsdUF","rated":false,"variant":{"key":"standard","name":"Standard"},"speed":"rapid","perf":"rapid","player":"white","status":20}"#,
        #"{"id":"q7ZvsdUF","rated":false,"variant":{"key":"standard","name":"Standard"},"speed":"rapid","perf":"rapid","player":"white","status":"started"}"#,
    ])
    func aiChallengeCreatedGameDecodes(json: String) throws {
        let game = try JSONDecoder().decode(LichessAICreatedGame.self, from: Data(json.utf8))
        #expect(game.id == "q7ZvsdUF")
        #expect(game.status == .started)
        #expect(game.player == "white")
    }

    /// `POST /api/challenge/{username}` — flat challenge JSON.
    @Test func friendChallengeCreatedDecodes() throws {
        let json = #"""
        {"id":"VU0nyvsW","url":"https://lichess.org/VU0nyvsW","status":"created","challenger":{"id":"raja102","name":"RAJA102","rating":1500,"provisional":true,"online":true},"destUser":{"id":"philippe","name":"Philippe","rating":1790,"online":true},"variant":{"key":"standard","name":"Standard","short":"Std"},"rated":false,"speed":"rapid","timeControl":{"type":"clock","limit":300,"increment":3,"show":"5+3"},"color":"random","perf":{"icon":"#","name":"Rapid"},"direction":"out"}
        """#
        let challenge = try JSONDecoder().decode(LichessChallenge.self, from: Data(json.utf8))
        #expect(challenge.id == "VU0nyvsW")
        #expect(challenge.status == "created")
        #expect(challenge.destUser?.name == "Philippe")
        #expect(challenge.timeControl.limit == 300)
    }

    // MARK: Outbound seek body

    /// `/api/board/seek` wants `time` in MINUTES — canonical integer
    /// formatting ("10", not "10.0") for whole-minute controls.
    @Test func seekBodyUsesIntegerMinutes() {
        let keys = LichessFormBody.seekClockKeys(
            for: .realTime(limitSeconds: 600, incrementSeconds: 0)
        )
        #expect(keys["time"] == "10")
        #expect(keys["increment"] == "0")
    }

    @Test func seekBodyKeepsFractionForSubMinute() {
        let keys = LichessFormBody.seekClockKeys(
            for: .realTime(limitSeconds: 90, incrementSeconds: 1)
        )
        #expect(keys["time"] == "1.5")
        #expect(keys["increment"] == "1")
    }

    @Test func seekBodyCorrespondenceUsesDays() {
        let keys = LichessFormBody.seekClockKeys(for: .correspondence(daysPerTurn: 3))
        #expect(keys["days"] == "3")
        #expect(keys["time"] == nil)
    }
}
