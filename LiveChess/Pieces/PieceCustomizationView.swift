import SwiftUI

/// Navigation token for pushing the Customize screen onto the main
/// window's NavigationStack (`ContentView` registers the matching
/// `navigationDestination`). A value type with no payload — the screen
/// reads everything it needs from `AppModel` in the environment.
struct CustomizeRoute: Hashable {}

/// "Customize" screen (pushed in-window from the lobby's Pieces
/// button). Mockup-style layout:
///
///   * LEFT  — "Settings / Customize" hero, a Pieces|Board tab
///     switcher, then the active tab's controls: piece style cards +
///     material swatches + tints (Pieces), or board color presets +
///     squares/frame controls (Board).
///   * RIGHT — live preview card (3-D piece or 2-D board, follows the
///     active tab) with a White/Black/piece segment bar, the Apply
///     Changes CTA and Reset to Default.
///
/// Persistence is handled by `PieceCustomization`: every change to
/// `appModel.pieceCustomization.current` flushes to UserDefaults
/// transparently, so "Apply Changes" just pops back to the lobby —
/// the label promises the same thing the mockup does, and the caption
/// under it tells the truth ("changes apply live").
@MainActor
struct PieceCustomizationView: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var appModel

    /// True when pushed via `CustomizeRoute` (Apply pops back to the
    /// lobby). False when embedded in Settings → Board & Pieces, where
    /// there is nothing to pop — calling `dismiss()` at a navigation
    /// root would close the whole window, so the button is hidden and
    /// only Reset to Default remains.
    var showsApplyButton: Bool = true

    /// Local state so the user can flip between previewing the white
    /// piece and the black piece without affecting the persisted
    /// material. Starts on white because users usually pick the "main"
    /// colour for white first.
    @State private var previewSide: Side = .white
    /// Which piece is rendered in the preview window. Default king —
    /// most ornate silhouette, best canvas for material judgement.
    @State private var previewKind: PieceKind = .king

    /// Pieces | Board content switcher (mockup's segmented pill).
    private enum Tab: String, CaseIterable {
        case pieces = "Pieces"
        case board  = "Board"
    }
    @State private var tab: Tab = .pieces

    var body: some View {
        @Bindable var customization = appModel.pieceCustomization

        HStack(alignment: .top, spacing: Chess.Space.l) {

            // LEFT — header + tab switcher + active tab's controls.
            ScrollView {
                VStack(alignment: .leading, spacing: Chess.Space.l) {
                    headerBlock
                    tabSwitcher

                    switch tab {
                    case .pieces:
                        piecesTab(customization)
                    case .board:
                        boardTab(customization)
                    }
                }
                .padding(.bottom, Chess.Space.l)
            }
            .scrollIndicators(.hidden)

            // RIGHT — preview + actions.
            previewColumn(customization)
                .frame(width: 380)
        }
        .padding(Chess.Space.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Same panel treatment as every other screen in the main
        // window (Home, Puzzles, Profile, …): one glass background
        // effect on the screen root. No hand-rolled material +
        // stroke — that combination is also what projected the
        // oversized floating borders around the 3-D previews.
        .glassBackgroundEffect()
        .navigationBarBackButtonHidden(false)
    }

    // MARK: - Header

    private var headerBlock: some View {
        VStack(alignment: .leading, spacing: Chess.Space.xs) {
            Text("Settings")
                .font(Chess.Typography.eyebrow())
                .foregroundStyle(Chess.Palette.bronze)
            Text("Customize")
                .font(.system(size: 40, weight: .semibold, design: .serif))
                .foregroundStyle(Chess.Palette.accent)
            Text("Personalize your pieces and board.")
                .font(.body)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Tab switcher (Pieces | Board)

    private var tabSwitcher: some View {
        HStack(spacing: 4) {
            ForEach(Tab.allCases, id: \.self) { candidate in
                tabSegment(candidate)
            }
        }
        .padding(4)
        .background(Capsule().fill(.ultraThinMaterial))
        .overlay(Capsule().strokeBorder(.white.opacity(0.10), lineWidth: 0.5))
        .frame(maxWidth: 460)
    }

    @ViewBuilder
    private func tabSegment(_ candidate: Tab) -> some View {
        let isSelected = tab == candidate
        Button {
            tab = candidate
        } label: {
            Text(candidate.rawValue)
                .font(.callout.weight(isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? .white : .secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(
                    Capsule().fill(isSelected
                                   ? AnyShapeStyle(Chess.Palette.cream.opacity(0.16))
                                   : AnyShapeStyle(Color.clear))
                )
                .overlay(
                    Capsule().strokeBorder(isSelected
                                           ? Chess.Palette.bronze.opacity(0.5)
                                           : Color.clear,
                                           lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
    }

    /// Titled control group — "Piece Style", "Material", "Board Color"…
    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Chess.Space.s) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            content()
        }
    }

    // MARK: - PIECES tab

    @ViewBuilder
    private func piecesTab(_ customization: PieceCustomization) -> some View {
        section("Piece Style") {
            HStack(spacing: Chess.Space.s) {
                ForEach(PieceStyleOption.allCases) { style in
                    styleCard(style, customization: customization)
                }
            }
        }

        section("Material") {
            materialSwatchGrid(customization)
        }

        section("Tint") {
            HStack(alignment: .top, spacing: Chess.Space.l) {
                colorPicker(
                    title: "White pieces",
                    binding: bindingFor(\.whiteColor, in: customization)
                )
                colorPicker(
                    title: "Black pieces",
                    binding: bindingFor(\.blackColor, in: customization)
                )
            }
            if customization.current.preset == .wood
                || customization.current.preset == .marble {
                Text("Tint multiplies the texture — near-white keeps the natural look, a bold tint repaints the material.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }

        if customization.current.preset == .wood {
            section("Wood Species") {
                woodPair(
                    leftLabel: "White pieces",
                    leftSelected: customization.current.whitePieceWood,
                    leftPick: { customization.current.whitePieceWood = $0 },
                    rightLabel: "Black pieces",
                    rightSelected: customization.current.blackPieceWood,
                    rightPick: { customization.current.blackPieceWood = $0 }
                )
            }
        }
    }

    // MARK: Piece style cards

    /// The mockup's three hero cards, mapped onto real material
    /// presets: each card is a curated quick-pick that snaps the
    /// preset (+ its default colour pair). The Material swatches
    /// below remain the full fine-grained selector — picking e.g.
    /// Pearl there simply deselects all three cards.
    private enum PieceStyleOption: String, CaseIterable, Identifiable {
        case staunton, wooden, minimal

        var id: String { rawValue }

        var title: String {
            switch self {
            case .staunton: return "Staunton"
            case .wooden:   return "Wooden"
            case .minimal:  return "Minimal"
            }
        }

        var tagline: String {
            switch self {
            case .staunton: return "Classic"
            case .wooden:   return "Timeless"
            case .minimal:  return "Modern"
            }
        }

        var preset: PieceMaterial.Preset {
            switch self {
            case .staunton: return .plasticGlossy
            case .wooden:   return .wood
            case .minimal:  return .brushedMetal
            }
        }

        /// Glyph colour treatment so each card's ♚♛♝ trio hints at
        /// the material it applies.
        var glyphStyle: AnyShapeStyle {
            switch self {
            case .staunton:
                return AnyShapeStyle(LinearGradient(
                    colors: [Color(red: 0.97, green: 0.95, blue: 0.90),
                             Color(red: 0.78, green: 0.74, blue: 0.66)],
                    startPoint: .top, endPoint: .bottom
                ))
            case .wooden:
                return AnyShapeStyle(LinearGradient(
                    colors: [Color(red: 0.62, green: 0.42, blue: 0.24),
                             Color(red: 0.34, green: 0.20, blue: 0.10)],
                    startPoint: .top, endPoint: .bottom
                ))
            case .minimal:
                return AnyShapeStyle(LinearGradient(
                    colors: [Color(white: 0.92), Color(white: 0.55)],
                    startPoint: .top, endPoint: .bottom
                ))
            }
        }
    }

    @ViewBuilder
    private func styleCard(
        _ style: PieceStyleOption,
        customization: PieceCustomization
    ) -> some View {
        let isSelected = customization.current.preset == style.preset
        Button {
            customization.selectPreset(style.preset)
        } label: {
            VStack(spacing: Chess.Space.s) {
                Text("♚♛♝")
                    .font(.system(size: 38))
                    .foregroundStyle(style.glyphStyle)
                    .padding(.top, Chess.Space.xs)
                VStack(spacing: 1) {
                    Text(style.title)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(style.tagline)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Chess.Space.m)
            .background(
                RoundedRectangle(cornerRadius: Chess.Radius.card, style: .continuous)
                    .fill(isSelected
                          ? AnyShapeStyle(Chess.Palette.cream.opacity(0.14))
                          : AnyShapeStyle(.thinMaterial))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Chess.Radius.card, style: .continuous)
                    .strokeBorder(isSelected
                                  ? Chess.Palette.bronze.opacity(0.6)
                                  : .white.opacity(0.10),
                                  lineWidth: isSelected ? 1 : 0.5)
            )
            .overlay(alignment: .topTrailing) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.callout)
                        .foregroundStyle(Chess.Palette.bronze)
                        .padding(Chess.Space.xs)
                }
            }
        }
        .buttonStyle(.plain)
        .hoverEffect(.lift)
    }

    // MARK: Material swatch grid

    /// Circular material samples with labels (mockup's Ivory / Ebony /
    /// Walnut row) — one per real preset, selected = bronze ring.
    @ViewBuilder
    private func materialSwatchGrid(_ customization: PieceCustomization) -> some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: Chess.Space.s),
                           count: 5),
            spacing: Chess.Space.s
        ) {
            ForEach(PieceMaterial.Preset.allCases) { preset in
                materialSwatchCell(preset, customization: customization)
            }
        }
        // Room for the selection ring (drawn 3 pt outside the circle)
        // so first-column swatches don't clip at the scroll edge.
        .padding(.horizontal, 4)
        .padding(.top, 4)
    }

    @ViewBuilder
    private func materialSwatchCell(
        _ preset: PieceMaterial.Preset,
        customization: PieceCustomization
    ) -> some View {
        let isSelected = customization.current.preset == preset
        Button {
            customization.selectPreset(preset)
        } label: {
            VStack(spacing: 6) {
                MaterialSwatch(preset: preset)
                    .frame(width: 46, height: 46)
                    .overlay(
                        Circle().strokeBorder(
                            isSelected ? Chess.Palette.bronze : .clear,
                            lineWidth: 2
                        )
                        .padding(-3)
                    )
                Text(preset.displayName)
                    .font(.caption2.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .hoverEffect(.lift)
    }

    // MARK: - BOARD tab

    @ViewBuilder
    private func boardTab(_ customization: PieceCustomization) -> some View {
        section("Board Color") {
            HStack(alignment: .top, spacing: Chess.Space.s) {
                ForEach(BoardColorPreset.all) { preset in
                    boardColorCell(preset, customization: customization)
                }
            }
            // Ring room — see boardMaterialSwatchRow.
            .padding(.horizontal, 4)
            .padding(.top, 4)
            Text("Quick palettes for the playing surface. Fine-tune below.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }

        section("Squares") {
            boardMaterialSwatchRow(
                selected: customization.current.squareMaterial,
                onPick: { customization.current.squareMaterial = $0 }
            )
            if customization.current.squareMaterial == .wood {
                woodPair(
                    leftLabel: "Light wood",
                    leftSelected: customization.current.lightSquareWood,
                    leftPick: { customization.current.lightSquareWood = $0 },
                    rightLabel: "Dark wood",
                    rightSelected: customization.current.darkSquareWood,
                    rightPick: { customization.current.darkSquareWood = $0 }
                )
            }
            HStack(alignment: .top, spacing: Chess.Space.l) {
                colorPicker(
                    title: "Light squares",
                    binding: bindingFor(\.lightSquareColor, in: customization)
                )
                colorPicker(
                    title: "Dark squares",
                    binding: bindingFor(\.darkSquareColor, in: customization)
                )
            }
        }

        section("Frame") {
            boardMaterialSwatchRow(
                selected: customization.current.frameMaterial,
                onPick: { customization.current.frameMaterial = $0 }
            )
            if customization.current.frameMaterial == .wood {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Frame wood")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    woodTypeChips(
                        selected: customization.current.frameWood,
                        onPick: { customization.current.frameWood = $0 }
                    )
                }
            }
            colorPicker(
                title: "Frame colour",
                binding: bindingFor(\.frameColor, in: customization)
            )
            .frame(maxWidth: 200, alignment: .leading)
        }
    }

    // MARK: Board color presets

    /// Curated square palettes (the mockup's Maple / Walnut / Green /
    /// Slate / Marble row). Each applies light + dark + frame colours
    /// and the matching surface material in one tap.
    private struct BoardColorPreset: Identifiable {
        let name: String
        let light: PieceColor
        let dark: PieceColor
        let frame: PieceColor
        let material: BoardMaterial
        let lightWood: WoodType
        let darkWood: WoodType

        var id: String { name }

        static let all: [BoardColorPreset] = [
            // Chess+ == the app default — brand cream / bronze board
            // (tracks `PieceMaterial.default*` so it always means
            // "the theme look").
            .init(name: "Chess+",
                  light: PieceMaterial.defaultLightSquareColor,
                  dark: PieceMaterial.defaultDarkSquareColor,
                  frame: PieceMaterial.defaultFrameColor,
                  material: .wood, lightWood: .oak, darkWood: .walnut),
            .init(name: "Walnut",
                  light: .init(0.82, 0.66, 0.46),
                  dark: .init(0.26, 0.15, 0.09),
                  frame: .init(0.16, 0.10, 0.06),
                  material: .wood, lightWood: .walnut, darkWood: .ebony),
            .init(name: "Green",
                  light: .init(0.93, 0.93, 0.82),
                  dark: .init(0.30, 0.47, 0.34),
                  frame: .init(0.16, 0.24, 0.18),
                  material: .matte, lightWood: .oak, darkWood: .walnut),
            .init(name: "Slate",
                  light: .init(0.80, 0.81, 0.84),
                  dark: .init(0.28, 0.31, 0.36),
                  frame: .init(0.15, 0.17, 0.20),
                  material: .matte, lightWood: .oak, darkWood: .walnut),
            .init(name: "Marble",
                  light: .init(0.95, 0.93, 0.90),
                  dark: .init(0.42, 0.41, 0.43),
                  frame: .init(0.28, 0.27, 0.29),
                  material: .marble, lightWood: .oak, darkWood: .walnut),
        ]

        @MainActor
        func apply(to customization: PieceCustomization) {
            customization.current.lightSquareColor = light
            customization.current.darkSquareColor = dark
            customization.current.frameColor = frame
            customization.current.squareMaterial = material
            customization.current.frameMaterial = material
            customization.current.lightSquareWood = lightWood
            customization.current.darkSquareWood = darkWood
        }

        @MainActor
        func isActive(in customization: PieceCustomization) -> Bool {
            customization.current.lightSquareColor == light
                && customization.current.darkSquareColor == dark
                && customization.current.squareMaterial == material
        }
    }

    @ViewBuilder
    private func boardColorCell(
        _ preset: BoardColorPreset,
        customization: PieceCustomization
    ) -> some View {
        let isSelected = preset.isActive(in: customization)
        Button {
            preset.apply(to: customization)
        } label: {
            VStack(spacing: 6) {
                Circle()
                    // Hard-stop diagonal split — light square colour
                    // top-left, dark bottom-right — so the swatch
                    // reads as "a board palette", not a single colour.
                    .fill(LinearGradient(
                        stops: [
                            .init(color: preset.light.swiftUI, location: 0.5),
                            .init(color: preset.dark.swiftUI, location: 0.5),
                        ],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
                    .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
                    .overlay(
                        Circle().strokeBorder(
                            isSelected ? Chess.Palette.bronze : .clear,
                            lineWidth: 2
                        )
                        .padding(-3)
                    )
                    .frame(width: 46, height: 46)
                Text(preset.name)
                    .font(.caption2.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .hoverEffect(.lift)
    }

    // MARK: Board material swatches

    @ViewBuilder
    private func boardMaterialSwatchRow(
        selected: BoardMaterial,
        onPick: @escaping (BoardMaterial) -> Void
    ) -> some View {
        // Leading inset: the bronze selection ring is drawn 3 pt
        // OUTSIDE the circle (negative padding) — flush against the
        // scroll view's left edge it gets clipped on the first swatch.
        HStack(spacing: Chess.Space.m) {
            ForEach(BoardMaterial.allCases) { material in
                let isSelected = material == selected
                Button {
                    onPick(material)
                } label: {
                    VStack(spacing: 6) {
                        Circle()
                            .fill(boardMaterialFill(material))
                            .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
                            .overlay(
                                Circle().strokeBorder(
                                    isSelected ? Chess.Palette.bronze : .clear,
                                    lineWidth: 2
                                )
                                .padding(-3)
                            )
                            .frame(width: 40, height: 40)
                        Text(material.displayName)
                            .font(.caption2.weight(isSelected ? .semibold : .regular))
                            .foregroundStyle(isSelected ? .primary : .secondary)
                    }
                }
                .buttonStyle(.plain)
                .hoverEffect(.lift)
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 4)
    }

    private func boardMaterialFill(_ material: BoardMaterial) -> AnyShapeStyle {
        switch material {
        case .matte:
            return AnyShapeStyle(Color(white: 0.55))
        case .polished:
            return AnyShapeStyle(LinearGradient(
                colors: [Color(white: 0.90), Color(white: 0.50)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            ))
        case .wood:
            return AnyShapeStyle(LinearGradient(
                colors: [Color(red: 0.55, green: 0.36, blue: 0.18),
                         Color(red: 0.32, green: 0.18, blue: 0.08)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            ))
        case .marble:
            return AnyShapeStyle(LinearGradient(
                colors: [Color(white: 0.96), Color(white: 0.78)],
                startPoint: .top, endPoint: .bottom
            ))
        }
    }

    // MARK: - RIGHT column · preview + actions

    @ViewBuilder
    private func previewColumn(_ customization: PieceCustomization) -> some View {
        VStack(spacing: Chess.Space.m) {

            // 3-D preview — spinning piece (Pieces tab) or miniature
            // board (Board tab). DELIBERATELY no card chrome here:
            // wrapping a windowed RealityView whose content has real
            // 3-D depth in a material background / clip shape makes
            // visionOS enclose the reserved volume in an oversized
            // floating glass platter that projects beyond the panel
            // (same reason HeroKingView floats bare on the home
            // hero). The piece/board float directly on the screen's
            // glass panel instead.
            switch tab {
            case .pieces:
                PiecePreviewView(
                    material: customization.current,
                    previewSide: $previewSide,
                    previewKind: $previewKind
                )
            case .board:
                BoardPreview3DView(material: customization.current)
            }

            // Control strips below the preview (the mockup's
            // Day / Studio / Night bar) — previewed side on top, the
            // six piece kinds inline underneath. Inline chips instead
            // of a Menu: the system pop-up opened UPWARD from down
            // here and covered the 3-D piece. Plain capsule glass is
            // safe — it wraps ordinary 2-D controls, not the
            // RealityView. The board preview shows both palettes at
            // once, so no controls.
            if tab == .pieces {
                previewSegmentBar
                    .background(Capsule().fill(.ultraThinMaterial))
                    .overlay(Capsule().strokeBorder(.white.opacity(0.10),
                                                    lineWidth: 0.5))
                pieceKindStrip
                    .background(Capsule().fill(.ultraThinMaterial))
                    .overlay(Capsule().strokeBorder(.white.opacity(0.10),
                                                    lineWidth: 0.5))
            }

            Spacer(minLength: 0)

            // Mockup CTA — settings persist live, so "apply" simply
            // pops back to the lobby; the caption keeps it honest.
            VStack(spacing: Chess.Space.xs) {
                if showsApplyButton {
                    Button {
                        dismiss()
                    } label: {
                        Text("Apply Changes")
                            .font(.callout.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .tint(Chess.Palette.bronze)
                }

                Text("Changes apply live to any open game.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                Button {
                    // Restore the factory look AND the preview state.
                    // Deliberately does NOT switch tabs — resetting
                    // from the Board tab must keep showing the board
                    // so the user sees the reset land.
                    customization.resetToDefault()
                    previewSide = .white
                    previewKind = .king
                } label: {
                    Label("Reset to Default",
                          systemImage: "arrow.counterclockwise")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                        .padding(.horizontal, Chess.Space.s)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .hoverEffect()
                .padding(.top, Chess.Space.xs)
            }
        }
        .frame(maxHeight: .infinity)
    }

    /// White | Black strip — two equal segments separated by a
    /// hairline, like the mockup's lighting bar.
    private var previewSegmentBar: some View {
        HStack(spacing: 0) {
            previewSegment(
                icon: "circle.fill",
                label: "White",
                isSelected: previewSide == .white
            ) { previewSide = .white }

            segmentDivider

            previewSegment(
                icon: "circle",
                label: "Black",
                isSelected: previewSide == .black
            ) { previewSide = .black }
        }
    }

    /// Inline piece-kind selector — six glyph chips in one strip.
    /// Replaces the old `Menu`: anchored this close to the window's
    /// bottom edge, the system pop-up opened upward and covered the
    /// 3-D preview. Inline chips never overlap anything.
    private var pieceKindStrip: some View {
        HStack(spacing: 0) {
            ForEach(PieceKind.allCases, id: \.self) { kind in
                let isSelected = previewKind == kind
                Button {
                    previewKind = kind
                } label: {
                    VStack(spacing: 2) {
                        Text(glyph(for: kind))
                            .font(.system(size: 20))
                            .foregroundStyle(isSelected
                                             ? Chess.Palette.bronze
                                             : .secondary)
                        Text(displayName(for: kind))
                            .font(.system(size: 9, weight: isSelected ? .semibold : .regular))
                            .foregroundStyle(isSelected ? .primary : .secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Chess.Space.xs)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
            }
        }
    }

    /// Filled chess glyphs with the text (non-emoji) presentation so
    /// they tint via `foregroundStyle`.
    private func glyph(for kind: PieceKind) -> String {
        switch kind {
        case .pawn:   return "♟\u{FE0E}"
        case .knight: return "♞\u{FE0E}"
        case .bishop: return "♝\u{FE0E}"
        case .rook:   return "♜\u{FE0E}"
        case .queen:  return "♛\u{FE0E}"
        case .king:   return "♚\u{FE0E}"
        }
    }

    private var segmentDivider: some View {
        Rectangle()
            .fill(.white.opacity(0.10))
            .frame(width: 0.5)
            .padding(.vertical, Chess.Space.s)
    }

    @ViewBuilder
    private func previewSegment(
        icon: String,
        label: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.callout)
                    .foregroundStyle(isSelected ? Chess.Palette.bronze : .secondary)
                Text(label)
                    .font(.caption.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Chess.Space.s)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
    }

    // MARK: - Shared small controls

    /// Two side-by-side labelled wood-type chip rows, used by the
    /// piece wood section (white / black side) and the squares wood
    /// section (light / dark squares).
    @ViewBuilder
    private func woodPair(
        leftLabel: String,
        leftSelected: WoodType,
        leftPick: @escaping (WoodType) -> Void,
        rightLabel: String,
        rightSelected: WoodType,
        rightPick: @escaping (WoodType) -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(leftLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                woodTypeChips(selected: leftSelected, onPick: leftPick)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(rightLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                woodTypeChips(selected: rightSelected, onPick: rightPick)
            }
        }
    }

    /// Compact chip selector for `WoodType`.
    @ViewBuilder
    private func woodTypeChips(
        selected: WoodType,
        onPick: @escaping (WoodType) -> Void
    ) -> some View {
        HStack(spacing: 6) {
            ForEach(WoodType.allCases) { wood in
                let isSelected = wood == selected
                Button {
                    onPick(wood)
                } label: {
                    Text(wood.displayName)
                        .font(.caption.weight(isSelected ? .semibold : .regular))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 10)
                        .background {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(isSelected
                                      ? AnyShapeStyle(Chess.Palette.cream.opacity(0.16))
                                      : AnyShapeStyle(Color.gray.opacity(0.10)))
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(isSelected
                                        ? Chess.Palette.bronze.opacity(0.55)
                                        : Color.secondary.opacity(0.20),
                                        lineWidth: isSelected ? 1.0 : 0.5)
                        }
                }
                .buttonStyle(.plain)
                .hoverEffect()
            }
        }
    }

    private func bindingFor(
        _ keyPath: WritableKeyPath<PieceMaterial, PieceColor>,
        in customization: PieceCustomization
    ) -> Binding<Color> {
        Binding(
            get: { customization.current[keyPath: keyPath].swiftUI },
            set: { newColor in
                customization.current[keyPath: keyPath] = PieceColor(newColor)
            }
        )
    }

    private func colorPicker(title: String, binding: Binding<Color>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            ColorPicker("", selection: binding, supportsOpacity: false)
                .labelsHidden()
            // Visual swatch under the picker so the user sees what
            // they have selected at a glance — visionOS's ColorPicker
            // surface hides the chosen colour behind a system menu.
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(binding.wrappedValue)
                .frame(height: 28)
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(.secondary.opacity(0.4), lineWidth: 0.5)
                }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func displayName(for kind: PieceKind) -> String {
        switch kind {
        case .pawn:   return "Pawn"
        case .knight: return "Knight"
        case .bishop: return "Bishop"
        case .rook:   return "Rook"
        case .queen:  return "Queen"
        case .king:   return "King"
        }
    }
}

// MARK: - Material swatch

/// Tiny visual preview of a `PieceMaterial.Preset`, shown as the
/// circular sample in the Material grid. Uses solid / gradient fills
/// that approximate what the material will look like on the 3-D
/// piece, so the grid is scannable at a glance instead of label-only.
private struct MaterialSwatch: View {
    let preset: PieceMaterial.Preset

    var body: some View {
        Circle()
            .fill(fill)
            .overlay(
                Circle().strokeBorder(.white.opacity(0.25),
                                      lineWidth: 0.5)
            )
            .overlay(
                // Subtle highlight crescent — sells the "sphere"
                // illusion so each chip reads as a polished material
                // sample rather than a flat colour blob.
                Circle()
                    .trim(from: 0.55, to: 0.85)
                    .stroke(.white.opacity(0.45), lineWidth: 1.2)
                    .padding(2)
            )
    }

    private var fill: AnyShapeStyle {
        switch preset {
        case .plasticMatte:
            return AnyShapeStyle(Color(red: 0.92, green: 0.92, blue: 0.92))
        case .plasticGlossy:
            return AnyShapeStyle(LinearGradient(
                colors: [Color.white, Color(white: 0.78)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            ))
        case .lacquered:
            return AnyShapeStyle(LinearGradient(
                colors: [Color(red: 0.78, green: 0.16, blue: 0.18),
                         Color(red: 0.45, green: 0.05, blue: 0.07)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            ))
        case .polishedMetal:
            return AnyShapeStyle(LinearGradient(
                colors: [Color(white: 0.95), Color(white: 0.55)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            ))
        case .brushedMetal:
            return AnyShapeStyle(Color(white: 0.70))
        case .ceramic:
            return AnyShapeStyle(LinearGradient(
                colors: [Color(red: 0.97, green: 0.96, blue: 0.93),
                         Color(red: 0.85, green: 0.83, blue: 0.78)],
                startPoint: .top, endPoint: .bottom
            ))
        case .pearl:
            return AnyShapeStyle(AngularGradient(
                colors: [.pink.opacity(0.6), .cyan.opacity(0.4),
                         .white, .yellow.opacity(0.5), .pink.opacity(0.6)],
                center: .center
            ))
        case .glass:
            return AnyShapeStyle(LinearGradient(
                colors: [Color.cyan.opacity(0.35),
                         Color.blue.opacity(0.45)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            ))
        case .wood:
            return AnyShapeStyle(LinearGradient(
                colors: [Color(red: 0.55, green: 0.36, blue: 0.18),
                         Color(red: 0.32, green: 0.18, blue: 0.08)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            ))
        case .marble:
            return AnyShapeStyle(LinearGradient(
                colors: [Color(white: 0.96), Color(white: 0.78)],
                startPoint: .top, endPoint: .bottom
            ))
        }
    }
}
