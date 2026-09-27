import CoreGraphics
import Foundation
import os

/// Runs layout + rasterization off the main thread, one request at a time, always working on
/// the most recent request: requests that arrive while one is in flight replace each other, so a
/// burst of resize events costs at most one wasted render.
final class TreemapRenderer: @unchecked Sendable {
    struct Request: @unchecked Sendable {
        var tree: FileTree
        var root: Int32
        var sizeMode: SizeMode
        var groupMode: GroupMode
        var version: Int
        var pixelSize: CGSize
        var dark: Bool
        var margin: Int
        var palette: PaletteSpec
        var referenceTime: TimeInterval
        var volume: TreemapLayout.VolumeInfo?
        var shape: CushionShape
        var generation: Int

        /// Same output, regardless of when it was asked for.
        func producesSameImage(as other: Request) -> Bool {
            tree === other.tree && root == other.root && sizeMode == other.sizeMode && groupMode == other.groupMode
                && version == other.version && pixelSize == other.pixelSize && dark == other.dark
                && margin == other.margin && palette == other.palette
                && referenceTime == other.referenceTime && volume == other.volume && shape == other.shape
        }
    }

    struct Result: @unchecked Sendable {
        var request: Request
        var layout: TreemapLayout
        /// `layout.cellIndex()`, built off the main thread.
        var cellIndex: [Int32: Int]
        var image: CGImage
        var duration: TimeInterval
    }

    private static let log = Logger(subsystem: "com.matjouhet.Layland", category: "treemap")

    private let lock = NSLock()
    private var pending: Request?
    private var running = false
    private let queue = DispatchQueue(label: "com.matjouhet.Layland.treemap", qos: .userInteractive)
    private let deliver: @MainActor @Sendable (Result) -> Void
    /// The extension index and the last grouping computed from it, reused while the tree and
    /// size mode (and root, for the grouping) stay the same. Only touched from `queue`.
    private var cachedIndex: (tree: FileTree, sizeMode: SizeMode, version: Int, index: ExtensionIndex)?
    private var cachedGroups: (root: Int32, groups: ExtensionGroups)?

    init(deliver: @escaping @MainActor @Sendable (Result) -> Void) {
        self.deliver = deliver
    }

    func submit(_ request: Request) {
        lock.lock()
        pending = request
        let shouldStart = !running
        running = true
        lock.unlock()
        if shouldStart {
            queue.async { self.drain() }
        }
    }

    private func drain() {
        while true {
            lock.lock()
            let next = pending
            pending = nil
            if next == nil { running = false }
            lock.unlock()
            guard let request = next else { return }

            let start = ContinuousClock.now
            let layout = TreemapLayout(
                tree: request.tree, root: request.root, pixelSize: request.pixelSize, sizeMode: request.sizeMode,
                shape: request.shape, margin: request.margin, colorMode: request.palette.mode,
                referenceTime: request.referenceTime, groups: groups(for: request), volume: request.volume
            )
            let laidOut = ContinuousClock.now
            guard let image = CushionRenderer.render(layout, palette: TreemapPalette(spec: request.palette, dark: request.dark)) else { continue }
            let done = ContinuousClock.now
            let duration = seconds(done - start)
            Self.log.info("treemap \(Int(request.pixelSize.width))x\(Int(request.pixelSize.height)) px, \(layout.cells.count) cells: layout \(seconds(laidOut - start) * 1000, format: .fixed(precision: 1)) ms, raster \(seconds(done - laidOut) * 1000, format: .fixed(precision: 1)) ms")

            let result = Result(request: request, layout: layout, cellIndex: layout.cellIndex(), image: image, duration: duration)
            let deliver = deliver
            Task { @MainActor in deliver(result) }
        }
    }
}

extension TreemapRenderer {
    private func groups(for request: Request) -> ExtensionGroups? {
        guard request.groupMode == .fileExtension else { return nil }
        let start = ContinuousClock.now
        let index: ExtensionIndex
        if let cached = cachedIndex, cached.tree === request.tree, cached.sizeMode == request.sizeMode, cached.version == request.version {
            index = cached.index
            if let cachedGroups, cachedGroups.root == request.root { return cachedGroups.groups }
        } else {
            index = ExtensionIndex(tree: request.tree, sizeMode: request.sizeMode)
            cachedIndex = (request.tree, request.sizeMode, request.version, index)
            Self.log.info("extension index: \(index.files.count) files in \(seconds(ContinuousClock.now - start) * 1000, format: .fixed(precision: 1)) ms")
        }
        let grouped = ContinuousClock.now
        let groups = ExtensionGroups(index: index, root: request.root)
        Self.log.info("grouped by extension: \(groups.groups.count) groups in \(seconds(ContinuousClock.now - grouped) * 1000, format: .fixed(precision: 1)) ms")
        cachedGroups = (request.root, groups)
        return groups
    }
}

private func seconds(_ duration: Duration) -> TimeInterval {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
}
