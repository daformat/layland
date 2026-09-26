import AppKit
import Quartz

/// Shows a `FileTree` subtree as a cushion treemap.
///
/// The view is layer-backed and never draws on the main thread: a `TreemapRenderer` produces the
/// image in the background and the layer stretches the previous image meanwhile, so resizing
/// stays fluid however large the tree. Hover, selection and search highlighting are shape
/// layers on top. It is also the Quick Look controller for the selected item.
@MainActor
final class TreemapView: NSView {
    struct Configuration: Equatable {
        var root: Int32 = FileTree.rootIndex
        var sizeMode: SizeMode = .logical
        var margin = 0
        var palette = PaletteSpec(mode: .fileType, colors: [])
        var referenceTime: TimeInterval = 0
        var volume: TreemapLayout.VolumeInfo?
        var shape = CushionShape()
        var version = 0
    }

    var onHover: ((Int32?) -> Void)?
    var onSelect: ((Int32?) -> Void)?
    var onOpen: ((Int32) -> Void)?
    /// Called when an image of the current tree at the view's current size is on screen.
    var onRender: (() -> Void)?
    /// ⌫ with an item selected.
    var onDelete: ((Int32) -> Void)?
    /// Items whose details the free tier hides: no Quick Look for them.
    var isLocked: ((Int32) -> Bool)?
    /// Quick Look was asked for on a locked item.
    var onLocked: ((Int32) -> Void)?

    private(set) var tree: FileTree?
    private(set) var configuration = Configuration()

    var selection: Int32? {
        didSet {
            guard selection != oldValue else { return }
            updateSelectionOverlay()
            if let panel = activePreviewPanel { panel.reloadData() }
        }
    }

    /// Nodes matched by the current search; everything else is dimmed. Nil when not searching.
    var highlightedNodes: [Int32]? {
        didSet { updateHighlightOverlay() }
    }

    private var renderer: TreemapRenderer!
    private var generation = 0
    private var current: TreemapRenderer.Result?
    private var cellIndex: [Int32: Int]?
    private var hoveredCell: TreemapCell?
    private var trackingArea: NSTrackingArea?
    private let highlightLayer = CAShapeLayer()
    private let hoverAncestorsLayer = CAShapeLayer()
    private let hoverLayer = CAShapeLayer()
    private let selectionAncestorsLayer = CAShapeLayer()
    private let selectionLayer = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        highlightLayer.fillRule = .evenOdd
        highlightLayer.isHidden = true
        highlightLayer.actions = ["path": NSNull(), "hidden": NSNull(), "fillColor": NSNull()]
        layer?.addSublayer(highlightLayer)
        for overlay in [selectionAncestorsLayer, hoverAncestorsLayer, selectionLayer, hoverLayer] {
            overlay.fillColor = nil
            overlay.lineJoin = .miter
            overlay.actions = ["path": NSNull(), "hidden": NSNull(), "strokeColor": NSNull()]
            overlay.isHidden = true
            layer?.addSublayer(overlay)
        }
        hoverLayer.lineWidth = 2
        hoverAncestorsLayer.lineWidth = 2
        selectionLayer.lineWidth = 3
        selectionAncestorsLayer.lineWidth = 2
        renderer = TreemapRenderer { [weak self] result in
            self?.apply(result)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    func configure(tree: FileTree?, _ configuration: Configuration) {
        guard tree !== self.tree || configuration != self.configuration else { return }
        self.tree = tree
        self.configuration = configuration
        requestRender()
    }

    // MARK: Rendering

    private var isDark: Bool {
        effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    private func requestRender() {
        guard let tree, bounds.width >= 1, bounds.height >= 1 else {
            current = nil
            cellIndex = nil
            setHovered(nil)
            updateSelectionOverlay()
            updateHighlightOverlay()
            needsDisplay = true
            return
        }
        generation += 1
        let request = TreemapRenderer.Request(
            tree: tree, root: configuration.root, sizeMode: configuration.sizeMode, version: configuration.version,
            pixelSize: pixelSize,
            dark: isDark, margin: configuration.margin, palette: configuration.palette,
            referenceTime: configuration.referenceTime, volume: configuration.volume, shape: configuration.shape, generation: generation
        )
        if let current, current.request.producesSameImage(as: request) { return }
        renderer.submit(request)
    }

    private var pixelSize: CGSize {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        return CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
    }

    private func apply(_ result: TreemapRenderer.Result) {
        // A slower, older render must not replace a newer one that already arrived.
        if let current, current.request.generation > result.request.generation { return }
        current = result
        cellIndex = nil
        needsDisplay = true
        updateSelectionOverlay()
        updateHighlightOverlay()
        refreshHover()
        if result.request.tree === tree, result.request.pixelSize == pixelSize {
            onRender?()
        }
    }

    override func updateLayer() {
        guard let layer else { return }
        layer.backgroundColor = NSColor.windowBackgroundColor.cgColor
        layer.contents = current?.image
        layer.contentsGravity = .resize
        layer.magnificationFilter = .linear
        layer.minificationFilter = .linear
    }

    // MARK: Geometry and environment changes

    override func layout() {
        super.layout()
        geometryDidChange()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        geometryDidChange()
    }

    /// Overlays are in view coordinates: after any geometry change they must follow the
    /// (possibly stretched) image, hover included, even if the mouse hasn't moved.
    private var overlayLayers: [CAShapeLayer] {
        [highlightLayer, hoverAncestorsLayer, hoverLayer, selectionAncestorsLayer, selectionLayer]
    }

    private func geometryDidChange() {
        let scale = window?.backingScaleFactor ?? 2
        for overlay in overlayLayers {
            overlay.frame = bounds
            overlay.contentsScale = scale // shape layers default to 1x and blur thin lines on Retina
        }
        updateSelectionOverlay()
        updateHighlightOverlay()
        refreshHover()
        requestRender()
    }

    private var windowObservers: [NSObjectProtocol] = []

    private func observeWindow(_ window: NSWindow?) {
        windowObservers.forEach { NotificationCenter.default.removeObserver($0) }
        windowObservers = []
        guard let window else { return }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSWindow.didEndLiveResizeNotification] {
            windowObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshHover() }
            })
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
        requestRender()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        requestRender()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeWindow(window)
        requestRender()
        // Keyboard navigation should work right away.
        if let window, window.firstResponder === window || window.firstResponder == nil {
            window.makeFirstResponder(self)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    // MARK: Coordinate mapping

    /// The displayed image is stretched to the bounds, so map through the image's pixel size
    /// rather than the backing scale; this stays correct while a new render is pending.
    private func layoutPoint(from viewPoint: CGPoint, in layout: TreemapLayout) -> CGPoint {
        CGPoint(
            x: viewPoint.x / bounds.width * layout.pixelSize.width,
            y: (bounds.height - viewPoint.y) / bounds.height * layout.pixelSize.height
        )
    }

    private func viewRect(for pixelRect: CGRect, in layout: TreemapLayout) -> CGRect {
        let sx = bounds.width / layout.pixelSize.width
        let sy = bounds.height / layout.pixelSize.height
        let height = pixelRect.height * sy
        return CGRect(x: pixelRect.minX * sx, y: bounds.height - pixelRect.minY * sy - height, width: pixelRect.width * sx, height: height)
    }

    private func index(for layout: TreemapLayout) -> [Int32: Int] {
        if let cellIndex { return cellIndex }
        let index = layout.cellIndex()
        cellIndex = index
        return index
    }

    // MARK: Overlays

    /// Outlines of every ancestor folder of `node` that has a cell, up to (excluding) the
    /// displayed root — like GrandPerspective, so you can see where an item sits.
    private func ancestorsPath(of node: Int32, in layout: TreemapLayout) -> CGPath? {
        guard let tree, node >= 0 else { return nil }
        let index = index(for: layout)
        let path = CGMutablePath()
        var current = tree[node].parent
        while current >= 0, current != layout.root {
            if let position = index[current] {
                path.addRect(viewRect(for: layout.cells[position].rect, in: layout).insetBy(dx: 1, dy: 1))
            }
            current = tree[current].parent
        }
        return path.isEmpty ? nil : path
    }

    private func updateSelectionOverlay() {
        guard let current, let selection, selection >= 0, let cell = current.layout.cell(for: selection) else {
            selectionLayer.isHidden = true
            selectionAncestorsLayer.isHidden = true
            return
        }
        let color = NSColor.controlAccentColor
        selectionLayer.strokeColor = color.cgColor
        selectionLayer.path = CGPath(rect: viewRect(for: cell.rect, in: current.layout).insetBy(dx: 1.5, dy: 1.5), transform: nil)
        selectionLayer.isHidden = false
        selectionAncestorsLayer.strokeColor = color.cgColor
        selectionAncestorsLayer.path = ancestorsPath(of: selection, in: current.layout)
        selectionAncestorsLayer.isHidden = selectionAncestorsLayer.path == nil
    }

    private func updateHoverOverlay() {
        guard let current, let hoveredCell else {
            hoverLayer.isHidden = true
            hoverAncestorsLayer.isHidden = true
            return
        }
        let color = isDark ? NSColor.white : NSColor.black
        hoverLayer.strokeColor = color.withAlphaComponent(0.85).cgColor
        hoverLayer.path = CGPath(rect: viewRect(for: hoveredCell.rect, in: current.layout).insetBy(dx: 1, dy: 1), transform: nil)
        hoverLayer.isHidden = false
        hoverAncestorsLayer.strokeColor = hoverLayer.strokeColor
        hoverAncestorsLayer.path = ancestorsPath(of: hoveredCell.node, in: current.layout)
        hoverAncestorsLayer.isHidden = hoverAncestorsLayer.path == nil
    }

    /// Matches inside collapsed directories light up that directory's cell instead. Only leaf
    /// cells are added: they never overlap, which keeps the even-odd dimming path correct.
    private static let highlightLimit = 20_000

    private func updateHighlightOverlay() {
        guard let current, let tree, let highlightedNodes else {
            highlightLayer.isHidden = true
            return
        }
        let layout = current.layout
        let index = index(for: layout)
        let path = CGMutablePath()
        path.addRect(bounds)
        var seen = Set<Int>()
        for node in highlightedNodes.prefix(Self.highlightLimit) {
            guard let cell = layout.visibleCell(for: node, tree: tree, index: index) else { continue }
            guard let position = index[cell.node], seen.insert(position).inserted else { continue }
            path.addRect(viewRect(for: cell.rect, in: layout))
        }
        highlightLayer.fillColor = (isDark ? NSColor.black : NSColor.white).withAlphaComponent(isDark ? 0.62 : 0.7).cgColor
        highlightLayer.path = path
        highlightLayer.isHidden = false
    }

    // MARK: Mouse

    private func cell(at viewPoint: CGPoint) -> TreemapCell? {
        guard let current else { return nil }
        return current.layout.cell(at: layoutPoint(from: viewPoint, in: current.layout))
    }

    private func refreshHover() {
        guard let window, window.isKeyWindow else {
            setHovered(nil)
            return
        }
        let location = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        setHovered(bounds.contains(location) ? cell(at: location) : nil)
    }

    private func setHovered(_ cell: TreemapCell?) {
        // Always adopt the new cell: even for the same node its rect belongs to the current
        // layout, and the previous one may have come from a render of a different size.
        let changed = cell?.node != hoveredCell?.node
        hoveredCell = cell
        updateHoverOverlay()
        if changed { onHover?(cell?.node) }
    }

    override func mouseMoved(with event: NSEvent) {
        setHovered(cell(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseEntered(with event: NSEvent) {
        setHovered(cell(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseExited(with event: NSEvent) {
        setHovered(nil)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let cell = cell(at: convert(event.locationInWindow, from: nil))
        if event.clickCount == 2, let cell, cell.node >= 0 {
            onOpen?(cell.node)
        } else {
            onSelect?(cell.map { $0.node >= 0 ? $0.node : nil } ?? nil)
        }
    }

    // MARK: Keyboard

    enum Direction {
        case left, right, up, down
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 49: toggleQuickLook() // space
        case 53: // escape
            if selection != nil { onSelect?(nil) } else { super.keyDown(with: event) }
        case 51, 117: // delete, forward delete
            if let selection, selection >= 0 { onDelete?(selection) } else { super.keyDown(with: event) }
        case 123: moveSelection(.left)
        case 124: moveSelection(.right)
        case 126: moveSelection(.up)
        case 125: moveSelection(.down)
        default: super.keyDown(with: event)
        }
    }

    /// Moves the selection to the neighboring cell in `direction`, probing just past the edge
    /// of the current cell at its center line. Very small neighbors may be skipped.
    func moveSelection(_ direction: Direction) {
        guard let current else { return }
        let layout = current.layout
        guard let selection, let cell = layout.cell(for: selection) else {
            if let first = layout.cells.first(where: { $0.isLeaf && $0.node >= 0 }) { onSelect?(first.node) }
            return
        }
        let rect = cell.rect
        let probe: CGPoint
        switch direction {
        case .left: probe = CGPoint(x: rect.minX - 1, y: rect.midY)
        case .right: probe = CGPoint(x: rect.maxX + 1, y: rect.midY)
        case .up: probe = CGPoint(x: rect.midX, y: rect.minY - 1)
        case .down: probe = CGPoint(x: rect.midX, y: rect.maxY + 1)
        }
        guard let target = layout.cell(at: probe), target.node >= 0, target.node != selection else { return }
        onSelect?(target.node)
    }

    // MARK: Quick Look

    private var activePreviewPanel: QLPreviewPanel? {
        guard QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.isVisible,
              panel.dataSource === self
        else { return nil }
        return panel
    }

    func toggleQuickLook() {
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            if let selection, isLocked?(selection) == true {
                onLocked?(selection)
                return
            }
            window?.makeFirstResponder(self)
            panel.makeKeyAndOrderFront(nil)
        }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        true
    }

    // These NSResponder overrides are declared nonisolated by the SDK but are always called on
    // the main thread.
    override nonisolated func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = self
            panel.delegate = self
        }
    }

    override nonisolated func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = nil
            panel.delegate = nil
        }
    }
}

extension TreemapView: @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        tree != nil && selection != nil ? 1 : 0
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        guard let tree, let selection, selection >= 0, isLocked?(selection) != true else { return nil }
        return tree.url(selection) as NSURL
    }

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        // Let arrow keys walk the selection while the panel is up.
        guard event.type == .keyDown, [123, 124, 125, 126].contains(event.keyCode) else { return false }
        keyDown(with: event)
        return true
    }

    func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: QLPreviewItem!) -> NSRect {
        guard let current, let selection, let cell = current.layout.cell(for: selection), let window else { return .zero }
        let rect = viewRect(for: cell.rect, in: current.layout)
        return window.convertToScreen(convert(rect, to: nil))
    }
}
