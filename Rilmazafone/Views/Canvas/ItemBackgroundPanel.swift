import SwiftUI

struct ItemBackgroundPanel: View, Equatable {
    let item: CanvasItem
    let bg: ItemBackground
    let currentZoom: CGFloat
    let iconSize: CGFloat
    let backdrop: CanvasBackdrop?

    nonisolated static func == (lhs: ItemBackgroundPanel, rhs: ItemBackgroundPanel) -> Bool {
        lhs.item == rhs.item
            && lhs.bg == rhs.bg
            && lhs.currentZoom == rhs.currentZoom
            && lhs.iconSize == rhs.iconSize
            && lhs.backdrop == rhs.backdrop
    }

    @State private var bevelImage: NSImage?

    private static let iconCellPadding: CGFloat = 10
    private static let textGap: CGFloat = 4
    private static let estimatedTextHeight: CGFloat = 20

    private var contentHeight: CGFloat {
        iconSize + Self.iconCellPadding * 2 + Self.textGap + Self.estimatedTextHeight
    }

    private var bgSide: CGFloat {
        (contentHeight + bg.padding * 2) * currentZoom
    }

    private var cr: CGFloat {
        bg.cornerRadius * currentZoom
    }

    private var panelShadowColor: Color {
        guard let shadow = bg.shadow, shadow.enabled else { return .clear }
        return Color(
            red: shadow.color.red,
            green: shadow.color.green,
            blue: shadow.color.blue
        ).opacity(shadow.opacity)
    }

    private var panelShadowRadius: CGFloat {
        guard let shadow = bg.shadow, shadow.enabled else { return 0 }
        return shadow.radius * currentZoom
    }

    private var panelShadowOffset: CGSize {
        guard let shadow = bg.shadow, shadow.enabled else { return .zero }
        return CGSize(
            width: shadow.offsetX * currentZoom,
            height: shadow.offsetY * currentZoom
        )
    }

    /// Panel rect in canvas points (top-left origin), the crop the public glass
    /// preview blurs out of the composited backdrop.
    private var panelRect: CGRect {
        let side = contentHeight + bg.padding * 2
        return CGRect(
            x: item.position.x - side / 2,
            y: item.position.y - side / 2,
            width: side,
            height: side
        )
    }

    /// The unmasked blur layer: the public CIGaussianBlur preview in the App Store
    /// build, the private CABackdropLayer path in the GitHub build (unless
    /// `GlassPreview.usesPublicPath` is forced on for A/B comparison).
    @ViewBuilder
    private var blurSource: some View {
        #if APPSTORE
        CanvasBackdropBlurView(backdrop: backdrop, rect: panelRect, blurRadius: bg.blurRadius)
        #else
        if GlassPreview.usesPublicPath {
            CanvasBackdropBlurView(backdrop: backdrop, rect: panelRect, blurRadius: bg.blurRadius)
        } else {
            BackdropBlurView(blurRadius: bg.blurRadius * currentZoom)
        }
        #endif
    }

    private var bevelFingerprint: Int {
        var hasher = Hasher()
        hasher.combine(bg.bevel)
        hasher.combine(Int(bgSide))
        hasher.combine(Int(bg.cornerRadius * 100))
        return hasher.finalize()
    }

    var body: some View {
        ZStack {
            if bg.enabled {
                if bg.blurRadius > 0 {
                    if bg.blurFeather > 0 {
                        let featherPx = bgSide * bg.blurFeather * 0.5
                        blurSource
                            .mask {
                                RoundedRectangle(cornerRadius: max(cr - featherPx, 0))
                                    .fill(.white)
                                    .padding(featherPx)
                                    .blur(radius: featherPx)
                            }
                    } else {
                        blurSource
                    }
                }

                RoundedRectangle(cornerRadius: cr)
                    .fill(Color(
                        red: bg.color.red,
                        green: bg.color.green,
                        blue: bg.color.blue
                    ).opacity(bg.opacity))
                    .blendMode(bg.blendMode.swiftUIBlendMode)
                    .mask {
                        if bg.blurFeather > 0 {
                            let featherPx = bgSide * bg.blurFeather * 0.5
                            RoundedRectangle(cornerRadius: max(cr - featherPx, 0))
                                .fill(.white)
                                .padding(featherPx)
                                .blur(radius: featherPx)
                        } else {
                            Rectangle()
                        }
                    }
            }

            if let bevelImg = bevelImage {
                Image(nsImage: bevelImg)
                    .resizable()
                    .frame(width: bgSide, height: bgSide)
                    .blendMode(.softLight)
            }
        }
        .frame(width: bgSide, height: bgSide)
        .clipShape(RoundedRectangle(cornerRadius: cr))
        .shadow(
            color: panelShadowColor,
            radius: panelShadowRadius,
            x: panelShadowOffset.width,
            y: panelShadowOffset.height
        )
        .position(
            x: item.position.x * currentZoom,
            y: item.position.y * currentZoom
        )
        .allowsHitTesting(false)
        .task(id: bevelFingerprint) {
            guard let bevel = bg.bevel, bevel.enabled else {
                bevelImage = nil
                return
            }
            let logicalSide = contentHeight + bg.padding * 2
            let size = CGSize(width: logicalSide, height: logicalSide)
            bevelImage = CompositeRenderer.renderBevelImage(
                size: size,
                cornerRadius: bg.cornerRadius,
                bevel: bevel
            )
        }
    }
}
