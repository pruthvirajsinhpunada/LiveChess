// Views/Home/HeroKingView.swift
// The slowly-rotating golden king that anchors the home hero, echoing
// the reference design. Renders the real `king_white.usdz` (baked gold
// material, no override) on a small lit stage inside the 2-D window —
// the same RealityView turntable technique the piece-customization
// preview uses, so the highlight rolls across the gold as it spins.

import SwiftUI
import RealityKit

@MainActor
struct HeroKingView: View {

    /// Spinning parent the king rides on; lights stay on the stage so
    /// the highlight travels across the surface as it turns.
    @State private var turntable = Entity()
    @State private var assetsReady = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: false)) { context in
            RealityView { content in
                content.add(makeStage(turntable: turntable))
                if assetsReady { installKing(in: turntable) }
            } update: { _ in
                // 22 s / revolution — a stately museum turntable, slow
                // enough to read as ambient, fast enough to keep the
                // gold alive.
                let seconds = context.date.timeIntervalSinceReferenceDate
                let phase = seconds.truncatingRemainder(dividingBy: 22.0) / 22.0
                turntable.transform.rotation = simd_quatf(
                    angle: Float(phase) * (2 * .pi),
                    axis: SIMD3<Float>(0, 1, 0)
                )
            }
        }
        .task {
            await PieceMeshFactory.preload()
            assetsReady = true
            installKing(in: turntable)
        }
        .accessibilityHidden(true)   // decorative
    }

    private func installKing(in turntable: Entity) {
        turntable.children
            .filter { $0.name == "HeroKing" }
            .forEach { $0.removeFromParent() }

        // nil override → keep the USDZ's baked gold material, which is
        // exactly the look we want for the hero.
        let king = PieceMeshFactory.makeEntity(
            for: Piece(.king, .white),
            materialOverride: nil
        )
        king.name = "HeroKing"
        king.position = .zero
        // Pieces are ~5 cm tall in-game; scale up so the king fills the
        // hero frame the way the reference render does.
        king.scale = SIMD3<Float>(repeating: 2.1)
        turntable.addChild(king)

        // Pieces author their origin at the base, so the tall king
        // drifts up. Re-centre vertically on its bounding box so it
        // sits in the middle of the frame.
        let bounds = king.visualBounds(relativeTo: turntable)
        king.position.y -= bounds.center.y
    }

    /// Pedestal-free stage: a warm bronze key from the front-right and
    /// a cool fill from the left so the gold reads as metal rather than
    /// a flat yellow. 2-D-window RealityViews get no automatic IBL, so
    /// without explicit lights the shadow side is pitch black.
    private func makeStage(turntable: Entity) -> Entity {
        let stage = Entity()
        stage.name = "HeroStage"
        stage.position = SIMD3<Float>(0, -0.01, -0.18)

        let fill = DirectionalLightComponent(
            color: .init(red: 0.86, green: 0.90, blue: 1.0, alpha: 1.0),
            intensity: 700
        )
        let fillEntity = Entity()
        fillEntity.components.set(fill)
        fillEntity.look(
            at: .zero,
            from: SIMD3<Float>(-0.40, 0.45, 0.30),
            relativeTo: stage
        )
        stage.addChild(fillEntity)

        var key = SpotLightComponent(
            color: .init(red: 1.0, green: 0.91, blue: 0.74, alpha: 1.0),
            intensity: 28_000
        )
        key.attenuationRadius = 1.6
        key.innerAngleInDegrees = 45
        key.outerAngleInDegrees = 115
        let keyEntity = Entity()
        keyEntity.components.set(key)
        keyEntity.look(
            at: SIMD3<Float>(0, 0.10, 0),
            from: SIMD3<Float>(0.28, 0.45, 0.35),
            relativeTo: stage
        )
        stage.addChild(keyEntity)

        turntable.name = "HeroTurntable"
        stage.addChild(turntable)
        return stage
    }
}

#Preview {
    HeroKingView()
        .frame(width: 360, height: 380)
}
