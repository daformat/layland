import CoreGraphics
import Foundation
import os

/// Runs layout + rasterisation off the main thread, one request at a time, always working on
/// the most recent request: requests that arrive while one is in flight replace each other, so a
/// burst of resize events costs at most one wasted render.
final class TreemapRenderer: @unchecked Sendable {
    struct Request: @unchecked Sendable {
        var tree: FileTree
        var root: Int32
        var sizeMode: SizeMode
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
            tree === other.tree && root == other.root && sizeMode == other.sizeMode
                && version == other.version && pixelSize == other.pixelSize && dark == other.dark
                && margin == other.margin && palette == other.palette
                && referenceTime == other.referenceTime && volume == other.volume && shape == other.shape
        }
    }

    struct Result: @unchecked Sendable {
        var request: Request
        var layout: TreemapLayout
        var image: CGImage
        var duration: TimeInterval
    }

    private static let log = Logger(subsystem: "com.matjouhet.Layland", category: "treemap")

    private let lock = NSLock()
    private var pending: Request?
    private var running = false
    private let queue = DispatchQueue(label: "com.matjouhet.Layland.treemap", qos: .userInteractive)
    private let deliver: @MainActor @Sendable (Result) -> Void

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
                referenceTime: request.referenceTime, volume: request.volume
            )
            let laidOut = ContinuousClock.now
            guard let image = CushionRenderer.render(layout, palette: TreemapPalette(spec: request.palette, dark: request.dark)) else { continue }
            let done = ContinuousClock.now
            let duration = seconds(done - start)
            Self.log.info("treemap \(Int(request.pixelSize.width))x\(Int(request.pixelSize.height)) px, \(layout.cells.count) cells: layout \(seconds(laidOut - start) * 1000, format: .fixed(precision: 1)) ms, raster \(seconds(done - laidOut) * 1000, format: .fixed(precision: 1)) ms")

            let result = Result(request: request, layout: layout, image: image, duration: duration)
            let deliver = deliver
            Task { @MainActor in deliver(result) }
        }
    }
}

private func seconds(_ duration: Duration) -> TimeInterval {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
}
