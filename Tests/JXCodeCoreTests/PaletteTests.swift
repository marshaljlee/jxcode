import XCTest
@testable import JXCodeCore

/// The palette rule, and the values it governs.
///
/// These tests exist because the app target has no test target: `Theme` cannot
/// be reached from here, so any rule stated only in `Theme.swift` is a comment
/// nobody can enforce. `Palette` holds the governed values precisely so the rule
/// can be asserted, and the assertions below are written to fail if the rule is
/// ever loosened rather than only if a value moves.
///
/// The interesting tests are the negative ones. `testTheSampledWarningFailsTheRule`
/// and `testWhiteInkIsRejectedOnTheLightDots` pin values that the palette *used to
/// contain*, so a future edit that reinstates them fails the suite. Without those,
/// a rule that accepted everything would pass every other test in this file.
final class PaletteTests: XCTestCase {

    // MARK: - The rule has teeth

    /// The sampled warning was `#B07511`. It is the value the light half of the
    /// palette was darkened to satisfy this rule, so the rule must still reject
    /// it — otherwise the darkening was unnecessary and the tests below prove
    /// nothing.
    func testTheSampledWarningFailsTheRule() {
        let sampled: UInt32 = 0xB07511
        for surface in Palette.LightSurface.all {
            XCTAssertLessThan(
                Palette.contrastRatio(sampled, surface),
                Palette.minimumTextContrast,
                "the sampled warning unexpectedly passes on \(hex(surface)) — "
                + "either the rule is too loose or the palette was darkened for no reason"
            )
        }
    }

    /// White on the three light dots is what `IconTile` used to do unconditionally.
    func testWhiteInkIsRejectedOnTheLightDots() {
        for fill in [Palette.Tile.amber, Palette.Tile.orange, Palette.Tile.green] {
            XCTAssertLessThan(
                Palette.contrastRatio(Palette.inkLight, fill),
                Palette.minimumGraphicContrast,
                "white on \(hex(fill)) unexpectedly clears the graphic floor"
            )
            XCTAssertEqual(
                Palette.ink(on: fill), Palette.inkDark,
                "\(hex(fill)) should take the dark ink"
            )
        }
    }

    /// ...and the other four still want white. This is the other half of the
    /// guard: a rule that always returned the dark ink would pass the test above.
    func testTheDarkDotsKeepWhiteInk() {
        for fill in [Palette.Tile.blue, Palette.Tile.teal,
                     Palette.Tile.pink, Palette.Tile.purple] {
            XCTAssertGreaterThanOrEqual(
                Palette.contrastRatio(Palette.inkLight, fill),
                Palette.minimumGraphicContrast,
                "white on \(hex(fill)) does not clear the graphic floor"
            )
            XCTAssertEqual(
                Palette.ink(on: fill), Palette.inkLight,
                "\(hex(fill)) should keep white"
            )
        }
    }

    /// The ramp is only useful if both inks are actually reachable — otherwise
    /// `ink(on:)` has collapsed to a constant and the two tests above are
    /// describing a function with one output.
    func testTheRampNeedsBothInks() {
        let inks = Set(Palette.Tile.all.map { Palette.ink(on: $0) })
        XCTAssertEqual(inks.count, 2,
                       "the ramp resolves to a single ink, so the rule is not doing anything")
    }

    // MARK: - The governed values

    func testEveryStatusColourClearsTextContrastOnEveryLightSurface() {
        for colour in Palette.StatusLight.all {
            for surface in Palette.LightSurface.all {
                let ratio = Palette.contrastRatio(colour, surface)
                XCTAssertGreaterThanOrEqual(
                    ratio, Palette.minimumTextContrast,
                    "\(hex(colour)) on \(hex(surface)) is \(rounded(ratio)):1, "
                    + "below the \(Palette.minimumTextContrast):1 floor"
                )
            }
        }
    }

    /// A colour can pass on the card and fail on its own tint, which is why the
    /// wash is part of the rule rather than an afterthought.
    func testEveryStatusColourClearsTextContrastOnItsOwnWash() {
        for colour in Palette.StatusLight.all {
            for alpha in Palette.statusWashes {
                let wash = Palette.composite(colour, over: Palette.LightSurface.card,
                                             alpha: alpha)
                let ratio = Palette.contrastRatio(colour, wash)
                XCTAssertGreaterThanOrEqual(
                    ratio, Palette.minimumTextContrast,
                    "\(hex(colour)) on its own \(Int(alpha * 100))% wash \(hex(wash)) "
                    + "is \(rounded(ratio)):1, below the floor"
                )
            }
        }
    }

    func testEveryTileCarriesAGlyphAtTheGraphicFloor() {
        for fill in Palette.Tile.all {
            let ink = Palette.ink(on: fill)
            let ratio = Palette.contrastRatio(ink, fill)
            XCTAssertGreaterThanOrEqual(
                ratio, Palette.minimumGraphicContrast,
                "ink \(hex(ink)) on \(hex(fill)) is \(rounded(ratio)):1, "
                + "below the \(Palette.minimumGraphicContrast):1 graphic floor"
            )
        }
    }

    /// The washes are read off the call sites. If a new alpha appears in the app
    /// and is not added here, the rule silently stops covering it — so pin the
    /// ones that exist and make a change to this list deliberate.
    func testTheWashListCoversTheAlphasTheAppUses() {
        XCTAssertEqual(Palette.statusWashes.sorted(), [0.10, 0.14, 0.18])
    }

    // MARK: - The maths

    func testRelativeLuminanceOfTheExtremes() {
        XCTAssertEqual(Palette.relativeLuminance(0x000000), 0, accuracy: 0.0001)
        XCTAssertEqual(Palette.relativeLuminance(0xFFFFFF), 1, accuracy: 0.0001)
    }

    func testContrastRatioOfAColourWithItselfIsOne() {
        for colour in Palette.Tile.all + Palette.StatusLight.all {
            XCTAssertEqual(Palette.contrastRatio(colour, colour), 1, accuracy: 0.0001)
        }
    }

    func testContrastRatioIsSymmetric() {
        XCTAssertEqual(
            Palette.contrastRatio(Palette.Tile.amber, Palette.Tile.purple),
            Palette.contrastRatio(Palette.Tile.purple, Palette.Tile.amber),
            accuracy: 0.0001
        )
    }

    func testBlackOnWhiteIsTheMaximum() {
        XCTAssertEqual(Palette.contrastRatio(0x000000, 0xFFFFFF), 21, accuracy: 0.01)
    }

    func testCompositeAtFullAlphaIsTheForeground() {
        XCTAssertEqual(
            Palette.composite(0x123456, over: 0xFEFEFE, alpha: 1),
            0x123456
        )
    }

    func testCompositeAtZeroAlphaIsTheBackground() {
        XCTAssertEqual(
            Palette.composite(0x123456, over: 0xFEFEFE, alpha: 0),
            0xFEFEFE
        )
    }

    /// The wash has to be a real mix, not a rounding accident that returns one
    /// of the two inputs at a partial alpha.
    func testCompositeAtHalfAlphaSitsBetweenTheTwo() {
        let mixed = Palette.composite(0x000000, over: 0xFFFFFF, alpha: 0.5)
        XCTAssertEqual(mixed, 0x808080, "expected a genuine 50% mix, got \(hex(mixed))")
    }

    // MARK: - Text tiers

    func testSecondaryTextClearsTheTextFloorInLightMode() {
        for surface in Palette.LightSurface.all {
            let ratio = Palette.contrastRatio(Palette.TextLight.secondary, surface)
            XCTAssertGreaterThanOrEqual(
                ratio, Palette.minimumTextContrast,
                "secondary text \(hex(Palette.TextLight.secondary)) on \(hex(surface)) "
                + "is \(rounded(ratio)):1"
            )
        }
    }

    func testSecondaryTextClearsTheTextFloorInDarkMode() {
        for surface in Palette.DarkSurface.all {
            let ratio = Palette.contrastRatio(Palette.TextDark.secondary, surface)
            XCTAssertGreaterThanOrEqual(
                ratio, Palette.minimumTextContrast,
                "secondary text \(hex(Palette.TextDark.secondary)) on \(hex(surface)) "
                + "is \(rounded(ratio)):1"
            )
        }
    }

    /// Tertiary is the inactive tier — unselected icons, placeholder glyphs — so
    /// it is held to the graphic floor, not the text floor. See `Palette.TextLight`.
    func testTertiaryTextClearsTheGraphicFloorInBothModes() {
        for (colour, surface) in zipSurfaces(Palette.TextLight.tertiary,
                                             Palette.LightSurface.all) {
            XCTAssertGreaterThanOrEqual(
                Palette.contrastRatio(colour, surface), Palette.minimumGraphicContrast,
                "tertiary \(hex(colour)) on \(hex(surface)) is below the graphic floor"
            )
        }
        for (colour, surface) in zipSurfaces(Palette.TextDark.tertiary,
                                             Palette.DarkSurface.all) {
            XCTAssertGreaterThanOrEqual(
                Palette.contrastRatio(colour, surface), Palette.minimumGraphicContrast,
                "tertiary \(hex(colour)) on \(hex(surface)) is below the graphic floor"
            )
        }
    }

    func testPrimaryTextHasAmpleHeadroomInBothModes() {
        for (colour, surfaces) in [(Palette.TextLight.primary, Palette.LightSurface.all),
                                   (Palette.TextDark.primary, Palette.DarkSurface.all)] {
            for surface in surfaces {
                XCTAssertGreaterThanOrEqual(
                    Palette.contrastRatio(colour, surface), 7.0,
                    "primary text should clear AAA, got "
                    + "\(rounded(Palette.contrastRatio(colour, surface))):1"
                )
            }
        }
    }

    /// The sampled secondary was 4.4996:1 on the page — under AA by four
    /// ten-thousandths. Pin that it fails, so "it passes" is a real result and
    /// not a rounding artefact in the threshold.
    func testTheSampledSecondaryFailsTheTextFloor() {
        let sampled: UInt32 = 0x6B6862
        let onPage = Palette.contrastRatio(sampled, Palette.LightSurface.page)
        XCTAssertLessThan(onPage, Palette.minimumTextContrast,
                          "the sampled secondary unexpectedly clears AA")
    }

    /// The sampled tertiary was 2.92:1 on a card: below even the graphic floor.
    func testTheSampledTertiaryFailsTheGraphicFloor() {
        let sampled: UInt32 = 0x9A968E
        XCTAssertLessThan(
            Palette.contrastRatio(sampled, Palette.LightSurface.card),
            Palette.minimumGraphicContrast,
            "the sampled tertiary unexpectedly clears the graphic floor"
        )
    }

    /// `textTertiary` was drawn at `.opacity(0.6)` for status dots and inactive
    /// icons in six places. The composite lands at **1.89–2.12:1** on every
    /// light surface, below the 3:1 graphic floor — the dots were barely
    /// visible. The fix was to drop the opacity: `textTertiary` at 1.0 clears
    /// 3.18. Pinning the composite failure so the opacity does not return.
    func testTextTertiaryAtOpacityZeroSixFailsTheGraphicFloor() {
        let rendered = Palette.composite(Palette.TextLight.tertiary,
                                         over: Palette.LightSurface.card,
                                         alpha: 0.6)
        XCTAssertLessThan(
            Palette.contrastRatio(rendered, Palette.LightSurface.card),
            Palette.minimumGraphicContrast,
            "textTertiary @0.6 unexpectedly clears the graphic floor — "
            + "the opacity modifier may have come back"
        )
    }

    // MARK: - Accent

    /// The accent foreground clears AA on every light surface — it is used as
    /// link text, icon tint, and selection state.
    func testAccentClearsTheTextFloorOnEveryLightSurface() {
        for surface in Palette.LightSurface.all {
            XCTAssertGreaterThanOrEqual(
                Palette.contrastRatio(Palette.AccentLight.foreground, surface),
                Palette.minimumTextContrast,
                "\(hex(Palette.AccentLight.foreground)) on "
                + "\(hex(surface)) = "
                + "\(rounded(Palette.contrastRatio(Palette.AccentLight.foreground, surface)))"
            )
        }
    }

    /// The "installing / retry / ready" badges draw accent text on an
    /// `accent@0.14` wash. That wash is necessarily close to the foreground in
    /// luminance, so it is the binding constraint — and a foreground that
    /// passes on the surface can still fail on its own wash.
    func testAccentClearsTheTextFloorOnItsOwnWashInLightMode() {
        for surface in Palette.LightSurface.all {
            let wash = Palette.composite(Palette.AccentLight.foreground,
                                         over: surface, alpha: 0.14)
            XCTAssertGreaterThanOrEqual(
                Palette.contrastRatio(Palette.AccentLight.foreground, wash),
                Palette.minimumTextContrast,
                "\(hex(Palette.AccentLight.foreground)) on wash \(hex(wash)) "
                + "= "
                + rounded(Palette.contrastRatio(Palette.AccentLight.foreground, wash))
            )
        }
    }

    /// Dark accent already clears in both rules.
    func testAccentClearsEveryRuleInDarkMode() {
        for surface in Palette.DarkSurface.all {
            XCTAssertGreaterThanOrEqual(
                Palette.contrastRatio(Palette.AccentDark.foreground, surface),
                Palette.minimumTextContrast,
                "\(hex(Palette.AccentDark.foreground)) on "
                + "\(hex(surface))"
            )
        }
        for surface in Palette.DarkSurface.all {
            let wash = Palette.composite(Palette.AccentDark.foreground,
                                         over: surface, alpha: 0.14)
            XCTAssertGreaterThanOrEqual(
                Palette.contrastRatio(Palette.AccentDark.foreground, wash),
                Palette.minimumTextContrast
            )
        }
    }

    /// The sampled accent was `#9A6200`. It was 4.13:1 on `page` and 3.48:1 on
    /// its own wash — both under AA. Pinning those two specific cases ensures
    /// the darkening has teeth: a future edit that restores the sampled value
    /// fails these tests, and a rule that accepted it would not be a rule.
    /// (It still passes on `card` — 5.05 — so the negative is intentionally
    /// scoped to where the failure actually was.)
    func testTheSampledAccentFailsTheTextFloor() {
        let sampled: UInt32 = 0x9A6200
        XCTAssertLessThan(
            Palette.contrastRatio(sampled, Palette.LightSurface.page),
            Palette.minimumTextContrast,
            "the sampled accent unexpectedly passes on \(hex(Palette.LightSurface.page))"
        )
        let washOverPage = Palette.composite(sampled,
                                             over: Palette.LightSurface.page,
                                             alpha: 0.14)
        XCTAssertLessThan(
            Palette.contrastRatio(sampled, washOverPage),
            Palette.minimumTextContrast,
            "the sampled accent unexpectedly passes on its wash over page"
        )
    }

    // MARK: - Chart segments

    /// A segment is drawn at `chartSegmentAlpha`, so the colour the user sees is
    /// the composite, not the constant. Asserting against the constant would
    /// pass on a bar that renders at 1.78:1.
    func testEveryChartSegmentClearsTheGraphicFloorInLightMode() {
        for colour in Palette.ChartLight.all {
            for surface in Palette.LightSurface.all {
                let rendered = Palette.composite(colour, over: surface,
                                                 alpha: Palette.chartSegmentAlpha)
                XCTAssertGreaterThanOrEqual(
                    Palette.contrastRatio(rendered, surface),
                    Palette.minimumGraphicContrast,
                    "\(hex(colour)) renders at "
                    + "\(rounded(Palette.contrastRatio(rendered, surface))) on "
                    + "\(hex(surface))"
                )
            }
        }
    }

    func testEveryChartSegmentClearsTheGraphicFloorInDarkMode() {
        for colour in Palette.ChartDark.all {
            for surface in Palette.DarkSurface.all {
                let rendered = Palette.composite(colour, over: surface,
                                                 alpha: Palette.chartSegmentAlpha)
                XCTAssertGreaterThanOrEqual(
                    Palette.contrastRatio(rendered, surface),
                    Palette.minimumGraphicContrast,
                    "\(hex(colour)) renders at "
                    + "\(rounded(Palette.contrastRatio(rendered, surface))) on "
                    + "\(hex(surface))"
                )
            }
        }
    }

    /// The floor alone is not the rule. Four colours solved independently for
    /// 3:1 all land on the same luminance, because the floor is what sets
    /// luminance — the bar then reads as one colour to anyone who cannot use
    /// hue. Adjacent pairs have to differ too.
    func testAdjacentChartSegmentsStayApartInLightMode() {
        assertAdjacentSegmentsStayApart(Palette.ChartLight.all,
                                        Palette.LightSurface.card)
    }

    func testAdjacentChartSegmentsStayApartInDarkMode() {
        assertAdjacentSegmentsStayApart(Palette.ChartDark.all,
                                        Palette.DarkSurface.card)
    }

    /// The bar originally drew `Tile.blue`, `Tile.teal`, `Tile.purple` and
    /// `Tile.orange`. All four fail the graphic floor in light mode at the alpha
    /// it draws them at — pinning them is what stops the tile ramp being used as
    /// a chart fill again.
    func testTheTileRampFailsAsAChartFillInLightMode() {
        let usedAsSegments: [UInt32] = [
            Palette.Tile.blue, Palette.Tile.teal,
            Palette.Tile.purple, Palette.Tile.orange,
        ]
        for colour in usedAsSegments {
            for surface in Palette.LightSurface.all {
                let rendered = Palette.composite(colour, over: surface,
                                                 alpha: Palette.chartSegmentAlpha)
                XCTAssertLessThan(
                    Palette.contrastRatio(rendered, surface),
                    Palette.minimumGraphicContrast,
                    "\(hex(colour)) unexpectedly clears the floor on \(hex(surface))"
                )
            }
        }
    }

    /// `Tile.purple` is the one that failed in *both* modes — 2.43:1 on
    /// `elevated` — so the dark half of this ramp is not simply the tiles.
    func testTilePurpleFailsAsAChartFillInDarkMode() {
        for surface in Palette.DarkSurface.all {
            let rendered = Palette.composite(Palette.Tile.purple, over: surface,
                                             alpha: Palette.chartSegmentAlpha)
            XCTAssertLessThan(
                Palette.contrastRatio(rendered, surface),
                Palette.minimumGraphicContrast,
                "tile purple unexpectedly clears the floor on \(hex(surface))"
            )
        }
    }

    // MARK: - Helpers

    /// Pairs one colour with each of several surfaces.
    private func zipSurfaces(_ colour: UInt32, _ surfaces: [UInt32])
        -> [(UInt32, UInt32)] {
        surfaces.map { (colour, $0) }
    }

    /// Adjacent segments, as rendered, must differ by `minimumSegmentSeparation`.
    ///
    /// This is the test that would have caught the first solve: every colour
    /// cleared 3:1 and the bar was still four identical greys.
    private func assertAdjacentSegmentsStayApart(_ ramp: [UInt32],
                                                 _ surface: UInt32,
                                                 file: StaticString = #filePath,
                                                 line: UInt = #line) {
        let rendered = ramp.map {
            Palette.composite($0, over: surface, alpha: Palette.chartSegmentAlpha)
        }
        for i in 0..<(rendered.count - 1) {
            let separation = Palette.contrastRatio(rendered[i], rendered[i + 1])
            XCTAssertGreaterThanOrEqual(
                separation, Palette.minimumSegmentSeparation,
                "\(hex(rendered[i])) and \(hex(rendered[i + 1])) differ by only "
                + "\(rounded(separation))",
                file: file, line: line
            )
        }
    }

    private func hex(_ value: UInt32) -> String {
        String(format: "#%06X", value)
    }

    private func rounded(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}
