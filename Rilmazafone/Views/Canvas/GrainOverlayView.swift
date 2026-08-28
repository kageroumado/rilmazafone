import CoreGraphics
import SwiftUI

/// The document's grain, laid over the canvas the way the build lays it over the baked
/// background: the same generated image, composited source-over.
///
/// It sits above the item panels and below the icons because that is where the build
/// puts it — grain is a film over the finished background, not something a panel's glass
/// picks up and blurs. Drawn `.resizable()` into the same frame as the backdrop beneath
/// it, so at any zoom the two are resampled alike and at 100% both are exact.
struct GrainOverlayView: View, Equatable {
    let grain: GrainConfiguration
    let pointSize: CGSize

    nonisolated static func == (lhs: GrainOverlayView, rhs: GrainOverlayView) -> Bool {
        lhs.grain == rhs.grain && lhs.pointSize == rhs.pointSize
    }

    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(grain.size > 1 ? .none : .low)
            }
        }
        .allowsHitTesting(false)
        .task(id: cacheKey) {
            await refresh()
        }
    }

    private var cacheKey: GrainImageCache.Key {
        GrainImageCache.Key(grain: grain, pointSize: pointSize)
    }

    private func refresh() async {
        guard grain.enabled, grain.amount > 0 else {
            image = nil
            return
        }

        if let cached = GrainImageCache.image(for: cacheKey) {
            image = cached
            return
        }

        let request = (grain: grain, pointSize: pointSize)
        let rendered = await Task.detached(name: "Grain Overlay", priority: .userInitiated) {
            CompositeRenderer.renderGrainImage(
                grain: request.grain,
                pointSize: request.pointSize,
                scale: CanvasBackdrop.renderScale,
            )
        }.value

        guard let rendered else { return }
        GrainImageCache.insert(rendered, for: cacheKey)
        if !Task.isCancelled {
            image = rendered
        }
    }
}

/// Holds the last few grain images. Generating one walks every pixel, so scrubbing the
/// amount slider back and forth should not regenerate a size it has already drawn.
@MainActor
private enum GrainImageCache {
    struct Key: Hashable {
        let grain: GrainConfiguration
        let width: Int
        let height: Int

        init(grain: GrainConfiguration, pointSize: CGSize) {
            self.grain = grain
            width = Int(pointSize.width.rounded())
            height = Int(pointSize.height.rounded())
        }
    }

    private static let capacity = 8
    private static var store: [Key: CGImage] = [:]
    private static var insertionOrder: [Key] = []

    static func image(for key: Key) -> CGImage? {
        store[key]
    }

    static func insert(_ image: CGImage, for key: Key) {
        guard store[key] == nil else { return }
        store[key] = image
        insertionOrder.append(key)
        if insertionOrder.count > capacity {
            let evicted = insertionOrder.removeFirst()
            store[evicted] = nil
        }
    }
}
