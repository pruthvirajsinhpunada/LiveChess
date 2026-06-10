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

    /// Spinning parent the king rides on.
    @State private var turntable = Entity()
    /// Stage root — kept so the async-generated uniform IBL can be
    /// attached after the scene is built.
    @State private var stage = Entity()
    @State private var assetsReady = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: false)) { context in
            RealityView { content in
                content.add(makeStage(turntable: turntable))
                if assetsReady { installKing(in: turntable) }
                applyUniformLight()
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
            // Uniform IBL (shared with the Customize previews) — the
            // old warm key spot + cool fill striped a hard white
            // highlight across the king.
            _ = await PreviewLighting.uniformEnvironment()
            applyUniformLight()
        }
        .accessibilityHidden(true)   // decorative
    }

    private func installKing(in turntable: Entity) {
        turntable.children
            .filter { $0.name == "HeroKing" }
            .forEach { $0.removeFromParent() }

        // Brand-bronze metal (#C3AE8E — the Play Now / accent colour)
        // so the hero king carries the app's theme instead of the
        // USDZ's pale baked material. Mid metallic + low-mid
        // roughness reads as brushed bronze: enough diffuse to keep
        // form under the ambient, enough specular for the key light
        // to roll a living highlight across it as it spins.
        var bronze = PhysicallyBasedMaterial()
        bronze.baseColor = .init(tint: UIColor(
            red: 0.765, green: 0.682, blue: 0.557, alpha: 1.0   // #C3AE8E
        ))
        bronze.metallic = .init(floatLiteral: 0.85)
        bronze.roughness = .init(floatLiteral: 0.30)
        bronze.specular = .init(floatLiteral: 0.6)

        let king = PieceMeshFactory.makeEntity(
            for: Piece(.king, .white),
            materialOverride: bronze
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

    /// Attaches the shared uniform environment (see `PreviewLighting`)
    /// to the stage and marks the king as a receiver. Dimmed so it's
    /// the ambient base under the key/fill — metal needs directional
    /// light to look like metal; uniform light alone reads as putty.
    private func applyUniformLight() {
        guard let env = PreviewLighting.cachedEnvironment else { return }
        PreviewLighting.apply(env,
                              lightRoot: stage,
                              subjectRoot: turntable,
                              intensityExponent: -0.4)
    }

    /// Hero rig for the bronze king: dimmed uniform ambient + warm
    /// key from the upper right + faint cool fill from the left. The
    /// key intensity is moderate — the old 28k spot striped a hard
    /// white band across the piece; this rolls a soft bronze sheen.
    private func makeStage(turntable: Entity) -> Entity {
        stage.name = "HeroStage"
        stage.position = SIMD3<Float>(0, -0.01, -0.18)

        let key = DirectionalLightComponent(
            color: .init(red: 1.0, green: 0.93, blue: 0.80, alpha: 1.0),
            intensity: 800
        )
        let keyEntity = Entity()
        keyEntity.components.set(key)
        keyEntity.look(
            at: .zero,
            from: SIMD3<Float>(0.40, 0.50, 0.40),
            relativeTo: stage
        )
        stage.addChild(keyEntity)

        let fill = DirectionalLightComponent(
            color: .init(red: 0.85, green: 0.90, blue: 1.0, alpha: 1.0),
            intensity: 240
        )
        let fillEntity = Entity()
        fillEntity.components.set(fill)
        fillEntity.look(
            at: .zero,
            from: SIMD3<Float>(-0.45, 0.25, 0.30),
            relativeTo: stage
        )
        stage.addChild(fillEntity)

        turntable.name = "HeroTurntable"
        stage.addChild(turntable)
        return stage
    }
}

#Preview {
    HeroKingView()
        .frame(width: 360, height: 380)
}
