import CoreGraphics
import Foundation

/// A small, lock-guarded cache of rendered images, keyed on whatever determines them.
///
/// `CompositeRenderer` is `nonisolated` and runs on whatever executor its caller is on —
/// detached render tasks, the build pipeline, test threads — so its memo tables have to
/// carry their own lock rather than rely on an actor.
final nonisolated class ImageCache<Key: Hashable>: @unchecked Sendable {
    private let capacity: Int
    private let lock = NSLock()
    private var store: [Key: CGImage] = [:]
    private var insertionOrder: [Key] = []

    init(capacity: Int) {
        self.capacity = capacity
    }

    func value(for key: Key) -> CGImage? {
        lock.lock()
        defer { lock.unlock() }
        return store[key]
    }

    func insert(_ image: CGImage, for key: Key) {
        lock.lock()
        defer { lock.unlock() }
        guard store[key] == nil else { return }
        store[key] = image
        insertionOrder.append(key)
        if insertionOrder.count > capacity {
            store[insertionOrder.removeFirst()] = nil
        }
    }
}
