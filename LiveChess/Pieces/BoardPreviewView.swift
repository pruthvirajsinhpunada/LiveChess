import SwiftUI
import RealityKit

// MARK: - Shared preview lighting

/// Uniform image-based light shared by the Customize previews (piece +
/// board). A flat-grey environment lights the model evenly from every
/// direction: true material colours, no directional hotspot, nothing
/// blown out — the "no light" look. Cached statically because the
/// piece preview rebuilds its whole RealityView per material change
/// (`.id(previewIdentity)`) and must re-attach the light instantly.
@MainActor
enum PreviewLighting {

    private static var cached: EnvironmentResource?

    static func uniformEnvironment() async -> EnvironmentResource? {
        if let cached { return cached }
        let width = 32, height = 16
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(red: 0.85, green: 0.85, blue: 0.85, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { return nil }
        cached = try? await EnvironmentResource(equirectangular: image)
        return cached
    }

    /// Synchronous variant for RealityView `make` closures — returns
    /// the environment only if a previous async call already built it.
    static var cachedEnvironment: EnvironmentResource? { cached }

    /// Attaches the environment as an IBL source on `lightRoot` and
    /// marks every model under `subjectRoot` as a receiver.
    /// `intensityExponent` scales the ambient level (2^x): the flat
    /// board preview runs it brighter and alone; the piece previews
    /// dim it and layer directional key/fill lights on top so curved
    /// geometry keeps real shading.
    static func apply(_ environment: EnvironmentResource,
                      lightRoot: Entity,
                      subjectRoot: Entity,
                      intensityExponent: Float = 0.3) {
        var ibl = ImageBasedLightComponent(source: .single(environment))
        ibl.intensityExponent = intensityExponent
        lightRoot.components.set(ibl)

        var stack: [Entity] = [subjectRoot]
        while let entity = stack.popLast() {
            if entity.components.has(ModelComponent.self) {
                entity.components.set(
                    ImageBasedLightReceiverComponent(imageBasedLight: lightRoot)
                )
            }
            stack.append(contentsOf: entity.children)
        }
    }
}

// MARK: - 3-D board preview

/// Live **3-D** preview of the board for the Customize screen — the
/// real `BoardSurface` entity (the exact board used in matches),
/// scaled to a miniature and tilted up toward the viewer like a board
/// held up for inspection, so the full square grid + frame are visible.
/// It spins slowly around its own surface normal (the face always
/// stays toward the viewer — only the grid orientation turns), on the
/// same turntable rig `PiecePreviewView` / `HeroKingView` use.
/// No pieces — this preview is about squares and frame only; piece
/// materials have their own preview on the Pieces tab.
///
/// Material changes apply IN PLACE via the same square/frame walk
/// `ChessRenderer.setBoardSurface` performs — no scene rebuild per
/// colour-picker tick.
///
/// IMPORTANT (glass-platter artifact): like the other windowed
/// RealityViews, this view must NOT be wrapped in a material
/// background / clip shape — visionOS would enclose its 3-D volume
/// in an oversized floating glass platter. Let it float directly on
/// the parent panel.
@MainActor
struct BoardPreview3DView: View {

    let material: PieceMaterial

    /// Spinning parent the board rides on.
    @State private var turntable = Entity()
    /// Stage root — held in @State so the IBL component (generated
    /// asynchronously) can be attached after the scene is built.
    @State private var stage = Entity()
    @State private var assetsReady = false
    /// Uniform light environment — generated once, then attached to
    /// the stage as an image-based light.
    @State private var iblEnvironment: EnvironmentResource?

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: false)) { context in
            RealityView { content in
                content.add(makeStage(turntable: turntable))
                installBoard(in: turntable)
                applyUniformLight()
            } update: { _ in
                // 32 s / revolution — slower than the piece preview;
                // a spinning board reads as restless above ~0.03 Hz.
                let seconds = context.date.timeIntervalSinceReferenceDate
                let phase = seconds.truncatingRemainder(dividingBy: 32.0) / 32.0
                turntable.transform.rotation = simd_quatf(
                    angle: Float(phase) * (2 * .pi),
                    axis: SIMD3<Float>(0, 1, 0)
                )
            }
        }
        .frame(height: 300)
        .task {
            // Wood/marble PBR maps. Until these land the board shows
            // the default materials; the walk re-runs on completion.
            await PieceMaterialFactory.preloadTextures()
            assetsReady = true
            applyMaterials()
            // Uniform IBL instead of any directional/spot light: a
            // flat board tilted at the camera turns every light
            // source into a washed-out specular blob across the
            // squares. An even all-directions environment lights
            // every square identically — true colours, no hotspot.
            if iblEnvironment == nil {
                iblEnvironment = await PreviewLighting.uniformEnvironment()
            }
            applyUniformLight()
        }
        .onChange(of: material) { _, _ in
            applyMaterials()
        }
        .accessibilityHidden(true)   // decorative — controls carry the state
    }

    /// Attaches the uniform environment as an image-based light on the
    /// stage and marks every board model as a receiver. Idempotent —
    /// callable from both the RealityView `make` and the async task,
    /// whichever lands last.
    private func applyUniformLight() {
        let env = iblEnvironment ?? PreviewLighting.cachedEnvironment
        guard let env, let board = boardEntity else { return }
        PreviewLighting.apply(env, lightRoot: stage, subjectRoot: board)
    }

    // MARK: Stage / board assembly

    private static let boardName = "PreviewBoard"
    /// In-game board is ~0.55 m wide; 0.29 shrinks it to a miniature
    /// that sits inside the preview column with comfortable margin.
    private static let boardScale: Float = 0.29

    private func installBoard(in turntable: Entity) {
        turntable.children
            .filter { $0.name == Self.boardName }
            .forEach { $0.removeFromParent() }

        let board = BoardSurface.makeEntity()
        board.name = Self.boardName
        board.scale = SIMD3<Float>(repeating: Self.boardScale)
        board.position = .zero
        turntable.addChild(board)

        applyMaterials()
    }

    /// Same walk as `ChessRenderer.setBoardSurface` — recolours the
    /// 64 squares + frame slab in place.
    private func applyMaterials() {
        guard let board = boardEntity else { return }
        let lightMat = PieceMaterialFactory.boardSquareMaterial(for: material, isLight: true)
        let darkMat  = PieceMaterialFactory.boardSquareMaterial(for: material, isLight: false)
        let frameMat = PieceMaterialFactory.boardFrameMaterial(for: material)

        var stack: [Entity] = [board]
        while let entity = stack.popLast() {
            if entity.name.hasPrefix("Square_"),
               var model = entity.components[ModelComponent.self] {
                let parts = entity.name.dropFirst("Square_".count).split(separator: "_")
                if parts.count == 2,
                   let file = Int(parts[0]),
                   let rank = Int(parts[1]) {
                    let isLight = !(file + rank).isMultiple(of: 2)
                    model.materials = [isLight ? lightMat : darkMat]
                    entity.components.set(model)
                }
            } else if entity.name == BoardSurface.frameName,
                      var model = entity.components[ModelComponent.self] {
                model.materials = [frameMat]
                entity.components.set(model)
            }
            stack.append(contentsOf: entity.children)
        }
    }

    private var boardEntity: Entity? {
        turntable.children.first { $0.name == Self.boardName }
    }

    /// Stage with the board tilted UP toward the viewer so its playing
    /// surface — squares + frame — fills the preview instead of
    /// showing an edge (or, worse, the unlit underside).
    ///
    /// NO directional / spot lights here, on purpose: any point-ish
    /// source reflects off the tilted flat board as a washed-out
    /// hotspot across the squares. Illumination comes exclusively
    /// from the uniform image-based light that `applyUniformLight()`
    /// attaches to this stage.
    private func makeStage(turntable: Entity) -> Entity {
        stage.name = "BoardPreviewStage"
        // Nudged left + down (not scaled): centred at x=0 the tilted
        // board's projection spilled past the panel's right edge.
        // -0.06 overshot into the controls column; -0.02 splits the
        // difference and keeps it centred on its own column.
        stage.position = SIMD3<Float>(-0.02, -0.02, -0.14)

        // Tilt ~63° toward the viewer (POSITIVE rotation about +X
        // swings the board's +Y surface normal toward +Z, i.e. toward
        // the camera — a negative angle here shows the black
        // underside). The turntable spins around the board's own
        // normal, so the face stays toward the viewer the whole
        // revolution; only the grid orientation turns.
        let tilt = Entity()
        tilt.name = "BoardTilt"
        tilt.transform.rotation = simd_quatf(angle: 1.1, axis: SIMD3<Float>(1, 0, 0))
        stage.addChild(tilt)

        turntable.name = "BoardTurntable"
        tilt.addChild(turntable)
        return stage
    }
}

/// Live 2-D swatch of the board, mirroring whatever
/// `PieceCustomization.current` currently has set for the squares
/// + frame + tint. Updates in real time as the user changes any
/// board control on the customization sheet — same role
/// `PiecePreviewView` plays for pieces.
///
/// Renders as a 4×4 mini chess board nested inside a rounded frame:
///   * `lightSquareColor` / `darkSquareColor` fill the 16 cells
///   * `frameColor` paints the surrounding border + a thin inner
///     groove (mimics the real 3-D board's frame inset)
///   * Two sample pieces (one per side) sit on the board so the
///     player can see how their selected piece tint reads against
///     the chosen square palette
///
/// Pure SwiftUI — no RealityView, no heavy resources. Cheap enough
/// to re-render on every slider tick.
struct BoardPreviewView: View {
    let material: PieceMaterial

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let frameWidth = side * 0.08
            let innerSide = side - frameWidth * 2
            let cell = innerSide / 4

            ZStack {
                // FRAME — outer rounded rectangle painted with the
                // user's frame colour. The squares sit on top of it
                // so the visible border is the frame.
                RoundedRectangle(cornerRadius: side * 0.06,
                                 style: .continuous)
                    .fill(material.frameColor.swiftUI)
                    .overlay(frameMaterialEffect)
                    .clipShape(RoundedRectangle(cornerRadius: side * 0.06,
                                                style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: side * 0.06,
                                         style: .continuous)
                            .strokeBorder(.white.opacity(0.18),
                                          lineWidth: 0.5)
                    )

                // INSET GROOVE — thin dark line between frame and
                // playable area, mirrors the real board's BoardGroove.
                RoundedRectangle(cornerRadius: side * 0.03,
                                 style: .continuous)
                    .stroke(Color.black.opacity(0.25), lineWidth: 0.6)
                    .frame(width: innerSide + 2, height: innerSide + 2)

                // PLAYABLE 4×4 GRID — light/dark squares.
                VStack(spacing: 0) {
                    ForEach(0..<4) { row in
                        HStack(spacing: 0) {
                            ForEach(0..<4) { col in
                                squareCell(row: row, col: col, cellSize: cell)
                            }
                        }
                    }
                }
                .frame(width: innerSide, height: innerSide)
                .clipShape(RoundedRectangle(cornerRadius: side * 0.025,
                                            style: .continuous))
            }
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(1, contentMode: .fit)
        .id(previewIdentity)
    }

    // MARK: - Square colouring

    private func squareColor(row: Int, col: Int) -> Color {
        let isLight = (row + col) % 2 == 0
        return isLight
            ? material.lightSquareColor.swiftUI
            : material.darkSquareColor.swiftUI
    }

    private var previewIdentity: String {
        [
            material.squareMaterial.rawValue,
            material.frameMaterial.rawValue,
            colorIdentity(material.lightSquareColor),
            colorIdentity(material.darkSquareColor),
            colorIdentity(material.frameColor),
            material.lightSquareWood.rawValue,
            material.darkSquareWood.rawValue,
            material.frameWood.rawValue
        ].joined(separator: "-")
    }

    private func colorIdentity(_ color: PieceColor) -> String {
        "\(color.red)-\(color.green)-\(color.blue)"
    }

    private func squareCell(row: Int, col: Int, cellSize: CGFloat) -> some View {
        let isLight = (row + col) % 2 == 0
        return ZStack {
            Rectangle()
                .fill(squareColor(row: row, col: col))
            boardMaterialEffect(
                material.squareMaterial,
                isLight: isLight,
                wood: isLight ? material.lightSquareWood : material.darkSquareWood
            )
            pieceGlyph(row: row, col: col, cellSize: cellSize)
        }
        .frame(width: cellSize, height: cellSize)
        .clipped()
    }

    @ViewBuilder
    private var frameMaterialEffect: some View {
        boardMaterialEffect(material.frameMaterial, isLight: false, wood: material.frameWood)
    }

    @ViewBuilder
    private func boardMaterialEffect(
        _ boardMaterial: BoardMaterial,
        isLight: Bool,
        wood: WoodType
    ) -> some View {
        switch boardMaterial {
        case .matte:
            Rectangle()
                .fill(.black.opacity(isLight ? 0.025 : 0.05))
        case .polished:
            ZStack {
                LinearGradient(
                    colors: [.white.opacity(0.26), .clear, .black.opacity(0.08)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                LinearGradient(
                    colors: [.clear, .white.opacity(0.18), .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            }
            .blendMode(.screen)
        case .wood:
            woodEffect(isLight: isLight, wood: wood)
        case .marble:
            marbleEffect(isLight: isLight)
        }
    }

    private func woodEffect(isLight: Bool, wood: WoodType) -> some View {
        ZStack {
            LinearGradient(
                colors: woodGradient(wood),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            GeometryReader { proxy in
                ForEach(0..<7, id: \.self) { index in
                    Capsule()
                        .fill(.black.opacity(isLight ? 0.10 : 0.18))
                        .frame(width: proxy.size.width * 1.25, height: 1)
                        .rotationEffect(.degrees(index.isMultiple(of: 2) ? 8 : -6))
                        .offset(
                            x: -proxy.size.width * 0.10,
                            y: proxy.size.height * CGFloat(index) / 6.0
                        )
                }
            }
        }
        .blendMode(.multiply)
    }

    private func marbleEffect(isLight: Bool) -> some View {
        ZStack {
            LinearGradient(
                colors: isLight
                    ? [.white.opacity(0.42), .gray.opacity(0.16), .white.opacity(0.22)]
                    : [.white.opacity(0.16), .black.opacity(0.12), .white.opacity(0.10)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            GeometryReader { proxy in
                ForEach(0..<4, id: \.self) { index in
                    Capsule()
                        .fill(.white.opacity(isLight ? 0.34 : 0.20))
                        .frame(width: proxy.size.width * 1.15, height: 1.2)
                        .rotationEffect(.degrees(index.isMultiple(of: 2) ? -24 : 18))
                        .offset(
                            x: -proxy.size.width * 0.08,
                            y: proxy.size.height * (CGFloat(index) + 0.8) / 4.5
                        )
                }
            }
        }
        .blendMode(.screen)
    }

    private func woodGradient(_ wood: WoodType) -> [Color] {
        switch wood {
        case .oak:
            return [
                Color(red: 0.82, green: 0.62, blue: 0.34).opacity(0.45),
                Color(red: 0.48, green: 0.31, blue: 0.14).opacity(0.32)
            ]
        case .walnut:
            return [
                Color(red: 0.42, green: 0.24, blue: 0.12).opacity(0.50),
                Color(red: 0.20, green: 0.11, blue: 0.06).opacity(0.42)
            ]
        case .rosewood:
            return [
                Color(red: 0.54, green: 0.20, blue: 0.12).opacity(0.48),
                Color(red: 0.25, green: 0.08, blue: 0.05).opacity(0.42)
            ]
        case .ebony:
            return [
                Color(red: 0.12, green: 0.10, blue: 0.08).opacity(0.52),
                Color.black.opacity(0.50)
            ]
        }
    }

    /// Two sample pieces — a white king on (3, 0) and a black king
    /// on (0, 3) — so the player sees how each side's tint sits on
    /// each square colour at the same time.
    @ViewBuilder
    private func pieceGlyph(row: Int, col: Int, cellSize: CGFloat) -> some View {
        if row == 3 && col == 0 {
            Text("\u{2654}")     // ♔ white king
                .font(.system(size: cellSize * 0.85))
                .foregroundStyle(material.whiteColor.swiftUI)
        } else if row == 0 && col == 3 {
            Text("\u{265A}")     // ♚ black king
                .font(.system(size: cellSize * 0.85))
                .foregroundStyle(material.blackColor.swiftUI)
        }
    }
}
