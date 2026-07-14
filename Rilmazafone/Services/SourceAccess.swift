import Foundation

/// Security-scoped access to canvas item sources.
///
/// Under the sandboxed App Store build (`APPSTORE`), items carry a security-scoped
/// bookmark (`CanvasItem.sourceBookmark`) so a saved document can reopen its sources
/// without re-prompting. This type centralizes the three operations around that data:
/// creating bookmarks at item-add time, reconciling them on document open/save, and
/// wrapping every source read in a balanced
/// `startAccessingSecurityScopedResource`/`stopAccessingSecurityScopedResource` pair.
///
/// Under the GitHub build every function degrades to a plain path passthrough:
/// `makeBookmark` returns `nil` and `withScope` hands the caller the raw path URL.
nonisolated enum SourceAccess {
    // MARK: - Bookmark Creation

    /// Creates a security-scoped bookmark for a source URL.
    ///
    /// Prefers a document-scoped bookmark (`relativeTo: documentURL`) so the grant
    /// travels with the document, falling back to an app-scoped bookmark when that
    /// fails. The fallback covers two real cases: an untitled document has no URL
    /// yet (``reconcile(bookmark:documentURL:)`` upgrades the bookmark to document
    /// scope after the first save), and macOS security policy disallows
    /// document-scoped bookmarks to directories — which includes `.app` bundles,
    /// the most common source kind — so those remain app-scoped permanently
    /// ("Item URL disallowed by security policy", verified on macOS 26).
    ///
    /// Returns `nil` in the unsandboxed GitHub build, which relies on raw paths.
    static func makeBookmark(for url: URL, documentURL: URL?) -> Data? {
        #if APPSTORE
            if let documentURL,
               let data = try? url.bookmarkData(
                   options: [.withSecurityScope],
                   includingResourceValuesForKeys: nil,
                   relativeTo: documentURL
               ) {
                return data
            }
            return try? url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        #else
            _ = url
            _ = documentURL
            return nil
        #endif
    }

    // MARK: - Reconciliation

    /// The outcome of reconciling a stored bookmark against the current document URL.
    struct Reconciliation: Sendable {
        /// The source URL the bookmark resolved to.
        let url: URL
        /// A replacement bookmark when the stored one was stale or app-scoped
        /// while a document URL exists; `nil` when the stored data is still current.
        let refreshedBookmark: Data?
    }

    /// Resolves a stored bookmark, re-creating it when it is stale and upgrading
    /// it to document scope when possible.
    ///
    /// Resolution tries document scope first (when `documentURL` is known), then
    /// app scope — the fallback order matching `makeBookmark`. An app-scoped
    /// bookmark is upgraded only when document-scoped creation actually succeeds;
    /// directory targets (`.app` bundles) are disallowed at document scope by
    /// macOS policy and deliberately stay app-scoped rather than being churned on
    /// every open. Returns `nil` when the bookmark no longer resolves (source
    /// deleted or volume gone).
    static func reconcile(bookmark: Data, documentURL: URL?) -> Reconciliation? {
        #if APPSTORE
            var isStale = false
            var isDocumentScoped = true
            var resolved: URL?

            if let documentURL {
                resolved = try? URL(
                    resolvingBookmarkData: bookmark,
                    options: [.withSecurityScope, .withoutUI],
                    relativeTo: documentURL,
                    bookmarkDataIsStale: &isStale
                )
            }
            if resolved == nil {
                isDocumentScoped = false
                isStale = false
                resolved = try? URL(
                    resolvingBookmarkData: bookmark,
                    options: [.withSecurityScope, .withoutUI],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
            }
            guard let url = resolved else { return nil }

            let wantsUpgrade = !isDocumentScoped && documentURL != nil
            guard isStale || wantsUpgrade else {
                return Reconciliation(url: url, refreshedBookmark: nil)
            }

            let started = url.startAccessingSecurityScopedResource()
            defer { if started { url.stopAccessingSecurityScopedResource() } }

            if let documentURL,
               let documentScoped = try? url.bookmarkData(
                   options: [.withSecurityScope],
                   includingResourceValuesForKeys: nil,
                   relativeTo: documentURL
               ) {
                return Reconciliation(url: url, refreshedBookmark: documentScoped)
            }
            if isStale {
                let appScoped = try? url.bookmarkData(
                    options: [.withSecurityScope],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
                return Reconciliation(url: url, refreshedBookmark: appScoped)
            }
            return Reconciliation(url: url, refreshedBookmark: nil)
        #else
            _ = bookmark
            _ = documentURL
            return nil
        #endif
    }

    // MARK: - Scoped Access

    /// Runs `body` with the item's source URL, holding security-scoped access for
    /// the closure's duration when the item carries a resolvable bookmark.
    ///
    /// When no bookmark exists or it fails to resolve (including always, in the
    /// GitHub build), `body` receives the raw `sourcePath` URL — or `nil` when the
    /// item has no source — and no scope calls are made.
    static func withScope<T>(
        bookmark: Data?,
        path: String?,
        documentURL: URL?,
        _ body: (URL?) throws -> T
    ) rethrows -> T {
        #if APPSTORE
            if let bookmark, let url = resolveForAccess(bookmark, documentURL: documentURL) {
                let started = url.startAccessingSecurityScopedResource()
                defer { if started { url.stopAccessingSecurityScopedResource() } }
                return try body(url)
            }
        #endif
        return try body(path.map { URL(fileURLWithPath: $0) })
    }

    /// Async overload of ``withScope(bookmark:path:documentURL:_:)`` for operations
    /// that must hold the scope across suspension points (e.g. icon composition
    /// reading inside the app bundle).
    static func withScope<T>(
        bookmark: Data?,
        path: String?,
        documentURL: URL?,
        _ body: (URL?) async throws -> T
    ) async rethrows -> T {
        #if APPSTORE
            if let bookmark, let url = resolveForAccess(bookmark, documentURL: documentURL) {
                let started = url.startAccessingSecurityScopedResource()
                defer { if started { url.stopAccessingSecurityScopedResource() } }
                return try await body(url)
            }
        #endif
        return try await body(path.map { URL(fileURLWithPath: $0) })
    }

    /// Convenience overload taking the item directly.
    static func withScope<T>(
        item: CanvasItem,
        documentURL: URL?,
        _ body: (URL?) throws -> T
    ) rethrows -> T {
        try withScope(
            bookmark: item.sourceBookmark,
            path: item.sourcePath,
            documentURL: documentURL,
            body
        )
    }

    /// Async convenience overload taking the item directly.
    static func withScope<T>(
        item: CanvasItem,
        documentURL: URL?,
        _ body: (URL?) async throws -> T
    ) async rethrows -> T {
        try await withScope(
            bookmark: item.sourceBookmark,
            path: item.sourcePath,
            documentURL: documentURL,
            body
        )
    }

    // MARK: - Availability

    /// Whether the item's copy-source is currently reachable.
    ///
    /// Items that do not copy a source (the Applications symlink, symlink-type
    /// items) are always available. For copy items the source is available when
    /// its bookmark resolves to an existing file, or — for bookmark-less items,
    /// including documents created by the GitHub build — when the raw path exists.
    static func isSourceAvailable(item: CanvasItem, documentURL: URL?) -> Bool {
        guard item.requiresSource else { return true }
        return withScope(item: item, documentURL: documentURL) { url in
            guard let url else { return false }
            return FileManager.default.fileExists(atPath: url.path)
        }
    }

    // MARK: - Private

    #if APPSTORE
        /// Resolves a bookmark for scoped access, trying document scope then app scope.
        private static func resolveForAccess(_ bookmark: Data, documentURL: URL?) -> URL? {
            var isStale = false
            if let documentURL,
               let url = try? URL(
                   resolvingBookmarkData: bookmark,
                   options: [.withSecurityScope, .withoutUI],
                   relativeTo: documentURL,
                   bookmarkDataIsStale: &isStale
               ) {
                return url
            }
            return try? URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        }
    #endif
}
