import CoreGraphics

/// Where one canvas item's icon, label, and panel sit, in canvas points.
///
/// Four surfaces have to agree on this layout — the editing canvas, the baked DMG
/// background, template thumbnails, and label legibility analysis — and a disagreement
/// between any two of them shows up as a panel that sits differently in the built DMG
/// than it did on the canvas. They all measure it here.
nonisolated enum ItemGeometry {
    /// Padding around the icon inside its cell.
    static let iconCellPadding: CGFloat = 10

    /// Gap between the icon cell and the label beneath it.
    static let textGap: CGFloat = 4

    /// Label height assumed for layout, matching Finder's single-line label.
    static let estimatedTextHeight: CGFloat = 20

    /// Height of the icon and its surrounding padding.
    static func cellHeight(iconSize: CGFloat) -> CGFloat {
        iconSize + iconCellPadding * 2
    }

    /// Height of the icon cell plus the label beneath it — the content a panel wraps.
    static func blockHeight(iconSize: CGFloat) -> CGFloat {
        cellHeight(iconSize: iconSize) + textGap + estimatedTextHeight
    }

    /// Side length of the square panel behind an item.
    static func panelSide(iconSize: CGFloat, padding: CGFloat) -> CGFloat {
        blockHeight(iconSize: iconSize) + padding * 2
    }

    /// Panel rect in the canvas's y-down point space, where `center` is `CanvasItem.position`.
    static func panelRect(center: CGPoint, iconSize: CGFloat, padding: CGFloat) -> CGRect {
        let side = panelSide(iconSize: iconSize, padding: padding)
        return CGRect(
            x: center.x - side / 2,
            y: center.y - side / 2,
            width: side,
            height: side,
        )
    }

    /// Panel rect in the y-up point space the baked background is drawn in.
    static func panelRectFlipped(
        center: CGPoint,
        iconSize: CGFloat,
        padding: CGFloat,
        canvasHeight: CGFloat,
    ) -> CGRect {
        let rect = panelRect(center: center, iconSize: iconSize, padding: padding)
        return CGRect(
            x: rect.minX,
            y: canvasHeight - center.y - rect.height / 2,
            width: rect.width,
            height: rect.height,
        )
    }
}
