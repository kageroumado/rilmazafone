import AppKit
import QuartzCore
import SwiftUI

struct BackdropBlurView: NSViewRepresentable, Equatable {
    let blurRadius: CGFloat

    init(blurRadius: CGFloat = 20) {
        self.blurRadius = blurRadius
    }

    func makeNSView(context _: Context) -> NSView {
        let view = BackdropBlurNSView()
        view.wantsLayer = true
        view.blurRadius = blurRadius
        return view
    }

    func updateNSView(_ nsView: NSView, context _: Context) {
        guard let view = nsView as? BackdropBlurNSView else { return }
        view.blurRadius = blurRadius
    }
}

final class BackdropBlurNSView: NSView {
    private let groupName = UUID().uuidString
    private var blurFilter: CAFilter?

    var blurRadius: CGFloat = 10 {
        didSet {
            updateBlurRadius()
        }
    }

    override var wantsUpdateLayer: Bool {
        true
    }

    override func makeBackingLayer() -> CALayer {
        let layer = CABackdropLayer()
        blurFilter = createGaussianBlurFilter()
        return layer
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            configureBackdropLayer()
        }
    }

    override func updateLayer() {
        configureBackdropLayer()
    }

    private func configureBackdropLayer() {
        guard let layer = layer as? CABackdropLayer else { return }

        layer.windowServerAware = true
        layer.groupName = groupName
        layer.scale = 1.0
        layer.bleedAmount = 0.5
        layer.disablesOccludedBackdropBlurs = false
        layer.ignoresOffscreenGroups = false

        layer.allowsGroupBlending = true
        layer.allowsGroupOpacity = true
        layer.allowsEdgeAntialiasing = false
        layer.allowsInPlaceFiltering = false

        if let blur = blurFilter {
            layer.filters = [blur]
        }
    }

    private func updateBlurRadius() {
        // Recreate the filter entirely — CABackdropLayer doesn't reliably pick up
        // in-place filter mutations via setValue/setNeedsDisplay.
        blurFilter = createGaussianBlurFilter()
        configureBackdropLayer()
    }

    private func createGaussianBlurFilter() -> CAFilter? {
        guard let filter = CAFilter(name: "gaussianBlur") else { return nil }

        filter.setValue(true, forKey: "inputNormalizeEdges")
        filter.setValue(blurRadius, forKey: "inputRadius")

        return filter
    }
}
