import AppKit
import CoreGraphics
import Foundation

// MARK: - Appearance Mode

/// The two Finder appearances a DMG's static background must stay legible in.
///
/// Finder colors icon labels by system appearance — black in Light Mode, white in
/// Dark Mode — while a DMG background is a single static image with no
/// per-appearance variant.
nonisolated enum LabelAppearanceMode: String, CaseIterable, Hashable {
    case light
    case dark

    var displayName: String {
        switch self {
        case .light: "Light Mode"
        case .dark: "Dark Mode"
        }
    }

    /// WCAG relative luminance of the label color Finder uses in this appearance.
    var labelLuminance: Double {
        switch self {
        case .light: 0 // black labels
        case .dark: 1 // white labels
        }
    }
}

// MARK: - Warning

/// One item's label flagged as potentially unreadable in one Finder appearance.
nonisolated struct LegibilityWarning: Hashable {
    let itemID: UUID
    let mode: LabelAppearanceMode
}

// MARK: - Analysis Input

/// Bundles everything a full legibility pass needs so it can cross to a background
/// task in one hop.
///
/// `@unchecked Sendable` because of the `NSImage` values; they are treated as
/// immutable after import (the document never mutates a loaded layer image),
/// matching `CanvasBackdrop`'s precedent for shipping render inputs off-main.
nonisolated struct LegibilityAnalysisInput: @unchecked Sendable {
    let configuration: DMGConfiguration
    let layerImages: [UUID: NSImage]
}

// MARK: - Analyzer

/// Samples the composited DMG background beneath each item's label and flags
/// labels whose WCAG contrast against Finder's label color falls below a
/// legibility threshold, per appearance mode.
///
/// The core (`analyze(composite:items:iconSize:textSize:windowSize:)`) is pure and
/// nonisolated: it takes only Sendable inputs and touches no shared state, so it
/// runs on any executor. Callers debounce it off the main thread.
nonisolated enum LabelContrastAnalyzer {
    // MARK: - Tuning

    /// Threshold and model constants.
    ///
    /// Tuned against deliberately constructed configurations (the bundled templates
    /// were not present in this tree at tuning time):
    /// - **White background** (L = 1.0): light ratio 21:1 (pass), dark ratio 1:1 (flag).
    /// - **Black background** (L = 0.0): the inverse.
    /// - **Mid-gray** (encoded 0.5, L ≈ 0.214): light 5.3:1, dark 4.0:1 — passes both
    ///   flat, matching how mid-gray genuinely stays readable in Finder.
    /// - **Busy checker** (encoded 0.10/0.75, mean L ≈ 0.266, stddev ≈ 0.256): the
    ///   variance ramp raises the effective threshold to 4.5:1, so its dark ratio of
    ///   3.3:1 flags — while a flat gray at the same mean luminance passes at the
    ///   3.0:1 base.
    enum Tuning {
        /// Minimum WCAG contrast ratio for a flat background (WCAG "large text" tier;
        /// icon labels are short and bold-adjacent, so 3.0:1 avoids over-flagging).
        static let baseContrastThreshold: Double = 3.0

        /// Effective threshold ceiling for maximally busy regions — WCAG's normal-text
        /// tier, because visual noise erodes effective contrast.
        static let busyContrastThreshold: Double = 4.5

        /// Luminance standard deviation at which the effective threshold saturates at
        /// ``busyContrastThreshold``. A 50/50 black-and-white mix has stddev 0.5;
        /// photographic "busy" regions typically land in 0.15–0.30.
        static let stddevSaturation: Double = 0.25

        /// Encoded sRGB gray Finder shows behind transparent composite pixels in
        /// Light Mode (the default window background).
        static let lightModeWindowBackdrop: Double = 1.0

        /// Encoded sRGB gray of Finder's Dark Mode window background (≈ #1E1E1E).
        static let darkModeWindowBackdrop: Double = 0.12
    }

    /// Pixel density the full pipeline composites at — matches the baked `@2x`
    /// background representation Finder shows on Retina displays.
    static let analysisScale: CGFloat = 2

    // MARK: - Label Geometry

    /// Label-rect geometry, mirroring `CanvasItemView` and
    /// `CompositeRenderer.renderItemBackgrounds`: an icon cell with 10 pt padding,
    /// a 4 pt gap, then up to two lines of label text.
    enum LabelGeometry {
        static let iconCellPadding: CGFloat = 10
        static let textGap: CGFloat = 4
        /// Single-line text-height estimate used for vertical block centering —
        /// the same value `CompositeRenderer.renderItemBackgrounds` uses.
        static let estimatedTextHeight: CGFloat = 20
        /// `maxLabelWidth = iconSize + 40` in `CanvasItemView`.
        static let labelWidthMargin: CGFloat = 40
        /// Approximate line height as a multiple of the font point size.
        static let lineHeightFactor: CGFloat = 1.3
        /// Labels wrap to at most two lines (`lineLimit(2)`); sample both.
        static let sampledLineCount: CGFloat = 2
    }

    /// The region of the background an item's label renders over, in canvas points
    /// with a top-left origin (the `CanvasItem.position` coordinate space).
    static func labelRect(
        position: CGPoint,
        iconSize: CGFloat,
        textSize: CGFloat,
    ) -> CGRect {
        let cellHeight = iconSize + LabelGeometry.iconCellPadding * 2
        let blockHeight = cellHeight + LabelGeometry.textGap + LabelGeometry.estimatedTextHeight
        let labelTop = position.y - blockHeight / 2 + cellHeight + LabelGeometry.textGap
        let width = iconSize + LabelGeometry.labelWidthMargin
        let lineHeight = (textSize * LabelGeometry.lineHeightFactor).rounded(.up)
        return CGRect(
            x: position.x - width / 2,
            y: labelTop,
            width: width,
            height: lineHeight * LabelGeometry.sampledLineCount,
        )
    }

    // MARK: - Full Pipeline

    /// Composites the full background (including baked item panels — they are the
    /// remediation, so they must count) and analyzes every item's label region.
    ///
    /// Placeholder items are analyzed too: once filled, their label renders in
    /// Finder at the same position.
    static func analyze(input: LegibilityAnalysisInput) -> Set<LegibilityWarning> {
        let configuration = input.configuration
        guard !configuration.items.isEmpty else { return [] }
        guard let composite = CompositeRenderer.renderAnalysisComposite(
            configuration: configuration,
            layerImages: input.layerImages,
            scale: analysisScale,
        ) else { return [] }

        return analyze(
            composite: composite,
            items: configuration.items,
            iconSize: configuration.iconSize,
            textSize: configuration.textSize,
            windowSize: CGSize(
                width: configuration.window.width,
                height: configuration.window.height,
            ),
        )
    }

    // MARK: - Core

    /// Analyzes label legibility against an already-composited background.
    ///
    /// - Parameters:
    ///   - composite: The full DMG background composite (any uniform pixel scale).
    ///   - items: Canvas items to check; each contributes its label rect.
    ///   - iconSize: Configured icon size in canvas points.
    ///   - textSize: Configured label text size in canvas points.
    ///   - windowSize: DMG window size in canvas points; defines the mapping from
    ///     item coordinates onto `composite` pixels.
    /// - Returns: One warning per (item, mode) whose contrast ratio against
    ///   Finder's label color falls below the variance-adjusted threshold.
    static func analyze(
        composite: CGImage,
        items: [CanvasItem],
        iconSize: CGFloat,
        textSize: CGFloat,
        windowSize: CGSize,
    ) -> Set<LegibilityWarning> {
        guard windowSize.width > 0, windowSize.height > 0, !items.isEmpty,
              let buffer = PixelBuffer(normalizing: composite)
        else { return [] }

        let scale = CGFloat(composite.width) / windowSize.width
        let imageBounds = CGRect(x: 0, y: 0, width: composite.width, height: composite.height)

        var warnings: Set<LegibilityWarning> = []
        for item in items {
            let rect = labelRect(position: item.position, iconSize: iconSize, textSize: textSize)
            let pixelRect = rect
                .applying(CGAffineTransform(scaleX: scale, y: scale))
                .integral
                .intersection(imageBounds)
            guard !pixelRect.isEmpty,
                  let statistics = buffer.luminanceStatistics(in: pixelRect)
            else { continue }

            for mode in LabelAppearanceMode.allCases {
                let s = statistics[mode]
                let ratio = contrastRatio(s.mean, mode.labelLuminance)
                if ratio < effectiveThreshold(stddev: s.stddev) {
                    warnings.insert(LegibilityWarning(itemID: item.id, mode: mode))
                }
            }
        }
        return warnings
    }

    // MARK: - Contrast Model

    /// WCAG contrast ratio between two relative luminances: `(L1 + 0.05) / (L2 + 0.05)`.
    static func contrastRatio(_ a: Double, _ b: Double) -> Double {
        let lighter = max(a, b)
        let darker = min(a, b)
        return (lighter + 0.05) / (darker + 0.05)
    }

    /// The contrast threshold a region must meet, rising linearly from
    /// ``Tuning/baseContrastThreshold`` toward ``Tuning/busyContrastThreshold`` as
    /// the region's luminance standard deviation grows — busy regions flag earlier.
    static func effectiveThreshold(stddev: Double) -> Double {
        let busyness = min(max(stddev, 0) / Tuning.stddevSaturation, 1)
        return Tuning.baseContrastThreshold
            + (Tuning.busyContrastThreshold - Tuning.baseContrastThreshold) * busyness
    }

    // MARK: - Pixel Sampling

    struct LuminanceStatistics {
        let mean: Double
        let stddev: Double
    }

    struct ModeStatistics {
        let light: LuminanceStatistics
        let dark: LuminanceStatistics

        subscript(mode: LabelAppearanceMode) -> LuminanceStatistics {
            switch mode {
            case .light: light
            case .dark: dark
            }
        }
    }

    /// Owns a normalized RGBA8 (premultiplied-last, sRGB) copy of a composite and
    /// computes per-mode luminance statistics over pixel rects.
    ///
    /// Transparent pixels are composited over each mode's Finder window backdrop
    /// before luminance is computed, so a `.none` background correctly reads as
    /// "Finder default" (legible in both modes) rather than as black.
    struct PixelBuffer {
        private let data: [UInt8]
        private let width: Int
        private let height: Int
        private let bytesPerRow: Int

        /// WCAG-linearized sRGB values for every encoded byte.
        private static let linearized: [Double] = (0 ..< 256).map { value in
            linearize(Double(value) / 255)
        }

        static func linearize(_ encoded: Double) -> Double {
            encoded <= 0.03928 ? encoded / 12.92 : pow((encoded + 0.055) / 1.055, 2.4)
        }

        static func luminance(red: Double, green: Double, blue: Double) -> Double {
            0.2126 * red + 0.7152 * green + 0.0722 * blue
        }

        init?(normalizing composite: CGImage) {
            let width = composite.width
            let height = composite.height
            guard width > 0, height > 0,
                  let context = CompositeRenderer.makeBitmapContext(
                      pixelsWide: width, pixelsHigh: height,
                  )
            else { return nil }

            context.draw(composite, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let base = context.data else { return nil }

            self.width = width
            self.height = height
            self.bytesPerRow = context.bytesPerRow
            self.data = [UInt8](
                UnsafeRawBufferPointer(start: base, count: context.bytesPerRow * height),
            )
        }

        /// Mean and standard deviation of WCAG relative luminance over `pixelRect`
        /// (top-left-origin pixel coordinates), per appearance mode.
        func luminanceStatistics(in pixelRect: CGRect) -> ModeStatistics? {
            let minX = max(Int(pixelRect.minX), 0)
            let minY = max(Int(pixelRect.minY), 0)
            let maxX = min(Int(pixelRect.maxX), width)
            let maxY = min(Int(pixelRect.maxY), height)
            guard maxX > minX, maxY > minY else { return nil }

            let lightBase = Tuning.lightModeWindowBackdrop
            let darkBase = Tuning.darkModeWindowBackdrop
            var lightSum = 0.0
            var lightSumSquares = 0.0
            var darkSum = 0.0
            var darkSumSquares = 0.0

            data.withUnsafeBufferPointer { pointer in
                guard let base = pointer.baseAddress else { return }
                for y in minY ..< maxY {
                    let row = base + y * bytesPerRow
                    for x in minX ..< maxX {
                        let pixel = row + x * 4
                        let alphaByte = pixel[3]

                        if alphaByte == 255 {
                            let luminance = Self.luminance(
                                red: Self.linearized[Int(pixel[0])],
                                green: Self.linearized[Int(pixel[1])],
                                blue: Self.linearized[Int(pixel[2])],
                            )
                            lightSum += luminance
                            lightSumSquares += luminance * luminance
                            darkSum += luminance
                            darkSumSquares += luminance * luminance
                        } else {
                            let alpha = Double(alphaByte) / 255
                            let red = Double(pixel[0]) / 255
                            let green = Double(pixel[1]) / 255
                            let blue = Double(pixel[2]) / 255

                            let lightLuminance = Self.luminance(
                                red: Self.linearize(red + lightBase * (1 - alpha)),
                                green: Self.linearize(green + lightBase * (1 - alpha)),
                                blue: Self.linearize(blue + lightBase * (1 - alpha)),
                            )
                            let darkLuminance = Self.luminance(
                                red: Self.linearize(red + darkBase * (1 - alpha)),
                                green: Self.linearize(green + darkBase * (1 - alpha)),
                                blue: Self.linearize(blue + darkBase * (1 - alpha)),
                            )
                            lightSum += lightLuminance
                            lightSumSquares += lightLuminance * lightLuminance
                            darkSum += darkLuminance
                            darkSumSquares += darkLuminance * darkLuminance
                        }
                    }
                }
            }

            let count = Double((maxX - minX) * (maxY - minY))
            return ModeStatistics(
                light: Self.statistics(sum: lightSum, sumSquares: lightSumSquares, count: count),
                dark: Self.statistics(sum: darkSum, sumSquares: darkSumSquares, count: count),
            )
        }

        private static func statistics(
            sum: Double,
            sumSquares: Double,
            count: Double,
        ) -> LuminanceStatistics {
            let mean = sum / count
            let variance = max(sumSquares / count - mean * mean, 0)
            return LuminanceStatistics(mean: mean, stddev: variance.squareRoot())
        }
    }
}
