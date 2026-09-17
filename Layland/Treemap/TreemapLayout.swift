import CoreGraphics
import Foundation

/// One rectangle of a laid-out treemap, in device pixels.
struct TreemapCell: Sendable {
    /// Pseudo node for the volume's free space (see `TreemapLayout.VolumeInfo`).
    static let freeSpaceNode: Int32 = -2
    /// Pseudo node for space on the volume used outside the scanned tree.
    static let otherSpaceNode: Int32 = -3

    /// A tree node index, or one of the pseudo nodes above.
    var node: Int32
    /// Integer-aligned pixel rectangle. Leaves tile their parent exactly, with no gaps.
    var rect: CGRect
    var depth: Int32
    var isDirectory: Bool
    /// Leaves are what gets painted: files, and directories too small to expand.
    var isLeaf: Bool
    var colorSlot: Int32
    /// Sides along which this cell gives up `margin` pixels when painted (see `TreemapLayout.margin`).
    var gapEdges: GapEdges
    /// Accumulated cushion surface gradient coefficients (s1x, s2x, s1y, s2y): the surface
    /// slope at pixel (x, y) is (s1x·x + s2x, s1y·y + s2y). See `CushionRenderer`.
    var cushion: SIMD4<Float>
}

struct GapEdges: OptionSet, Sendable {
    let rawValue: UInt8
    static let left = GapEdges(rawValue: 1)
    static let top = GapEdges(rawValue: 2)
    static let right = GapEdges(rawValue: 4)
    static let bottom = GapEdges(rawValue: 8)
    static let all: GapEdges = [.left, .top, .right, .bottom]
}

/// View ▸ Cushion Strength.
enum CushionStrength: String, CaseIterable, Identifiable, Sendable {
    case flat, subtle, normal, strong

    var id: String { rawValue }

    var title: String {
        switch self {
        case .flat: "Flat"
        case .subtle: "Subtle"
        case .normal: "Normal"
        case .strong: "Strong"
        }
    }

    var shape: CushionShape {
        switch self {
        case .flat: CushionShape(height: 0)
        case .subtle: CushionShape(height: 0.14)
        case .normal: CushionShape()
        case .strong: CushionShape(height: 0.5, falloff: 0.78)
        }
    }
}

/// Parameters of the cushion shape (van Wijk & van de Wetering, "Cushion Treemaps", 1999).
struct CushionShape: Equatable, Sendable {
    /// Edge slope of a top-level cell's pillow; deeper levels are scaled by `falloff^depth`.
    var height: Float = 0.28
    var falloff: Float = 0.72
    /// Cells wider than this get proportionally gentler pillows so a huge cell doesn't become a
    /// vignette over the whole window.
    var maxWidth: Float = 220
}

/// Lays out a subtree into pixel-aligned cells with cushion coefficients. Directories smaller
/// than a few pixels are left as leaves, so the cell count is bounded by the pixel area.
struct TreemapLayout: Sendable {
    /// Volume capacity and free space, shown as two extra top-level cells so the scanned tree
    /// appears in proportion to the whole disk.
    struct VolumeInfo: Equatable, Sendable {
        var size: Int64
        var free: Int64
    }

    /// Cells in depth-first order: every directory precedes its contents.
    private(set) var cells: [TreemapCell] = []
    let root: Int32
    let pixelSize: CGSize
    let sizeMode: SizeMode
    let shape: CushionShape
    let colorMode: ColorMode
    /// Reference time for `ColorMode.modified`, seconds since 1970.
    let referenceTime: TimeInterval
    /// Half of the gap, in pixels, between "large" things. A cell at least `marginThreshold` on
    /// both axes gives up `margin` on all four sides; a smaller cell gives it up only on sides
    /// where it touches the boundary of a large enclosing directory. Folders never inset their
    /// contents, so every gap is exactly two half-margins wide — the same between two files,
    /// between a file and a cluster of tiny files, or between two clusters. Zero disables it.
    let margin: Int

    /// Below this width or height (in pixels) a directory is not expanded.
    static let minimumExpandSize: CGFloat = 3
    /// Minimum cell width and height (in pixels) for the margin to apply.
    static let marginThreshold: CGFloat = 12

    init(
        tree: FileTree, root: Int32, pixelSize: CGSize, sizeMode: SizeMode, shape: CushionShape = CushionShape(),
        margin: Int = 0, colorMode: ColorMode = .fileType, referenceTime: TimeInterval = Date().timeIntervalSince1970,
        volume: VolumeInfo? = nil
    ) {
        self.root = root
        self.pixelSize = CGSize(width: pixelSize.width.rounded(.down), height: pixelSize.height.rounded(.down))
        self.sizeMode = sizeMode
        self.shape = shape
        self.margin = max(0, margin)
        self.colorMode = colorMode
        self.referenceTime = referenceTime
        cells.reserveCapacity(1 << 14)

        let bounds = CGRect(origin: .zero, size: self.pixelSize)
        let rootNode = tree[root]
        let cushion = parabola(for: bounds, depth: 0)
        var items = Self.items(of: root, tree: tree, sizeMode: sizeMode)
        // Free and other space only make sense next to the whole scanned tree.
        if let volume, root == FileTree.rootIndex, volume.size > 0 {
            let scanned = rootNode.size(sizeMode)
            items.append((TreemapCell.freeSpaceNode, Double(max(0, volume.free))))
            items.append((TreemapCell.otherSpaceNode, Double(max(0, volume.size - volume.free - scanned))))
            items.sort { $0.weight > $1.weight }
        }
        let expand = rootNode.isDirectory && items.contains { $0.weight > 0 }
        let edges: GapEdges = isLarge(bounds) ? .all : []
        cells.append(TreemapCell(
            node: root, rect: bounds, depth: 0, isDirectory: rootNode.isDirectory, isLeaf: !expand,
            colorSlot: expand ? 0 : colorSlot(for: root, tree: tree), gapEdges: edges, cushion: cushion
        ))
        if expand {
            layoutItems(items, in: bounds, edges: edges, depth: 1, parentCushion: cushion, tree: tree)
        }
    }

    /// Non-empty children of a directory, largest first.
    private static func items(of directory: Int32, tree: FileTree, sizeMode: SizeMode) -> [(node: Int32, weight: Double)] {
        var items: [(node: Int32, weight: Double)] = []
        for child in tree.orderedChildren(of: directory, by: sizeMode) {
            let size = tree[child].size(sizeMode)
            guard size > 0 else { break } // sorted descending
            items.append((child, Double(size)))
        }
        return items
    }

    private func isLarge(_ rect: CGRect) -> Bool {
        margin > 0 && rect.width >= Self.marginThreshold && rect.height >= Self.marginThreshold
    }

    /// The sides of `rect` that lie on the corresponding sides of `parent`.
    private static func touchingEdges(of rect: CGRect, in parent: CGRect) -> GapEdges {
        var edges: GapEdges = []
        if rect.minX == parent.minX { edges.insert(.left) }
        if rect.minY == parent.minY { edges.insert(.top) }
        if rect.maxX == parent.maxX { edges.insert(.right) }
        if rect.maxY == parent.maxY { edges.insert(.bottom) }
        return edges
    }

    /// The area a leaf paints: its rect minus the margin along its gap edges.
    func paintRect(of cell: TreemapCell) -> CGRect {
        guard margin > 0, !cell.gapEdges.isEmpty else { return cell.rect }
        let inset = CGFloat(margin)
        var rect = cell.rect
        if cell.gapEdges.contains(.left) { rect.origin.x += inset; rect.size.width -= inset }
        if cell.gapEdges.contains(.right) { rect.size.width -= inset }
        if cell.gapEdges.contains(.top) { rect.origin.y += inset; rect.size.height -= inset }
        if cell.gapEdges.contains(.bottom) { rect.size.height -= inset }
        return rect
    }

    private mutating func layoutChildren(of directory: Int32, in rect: CGRect, edges parentEdges: GapEdges, depth: Int32, parentCushion: SIMD4<Float>, tree: FileTree) {
        layoutItems(Self.items(of: directory, tree: tree, sizeMode: sizeMode), in: rect, edges: parentEdges, depth: depth, parentCushion: parentCushion, tree: tree)
    }

    private mutating func layoutItems(_ items: [(node: Int32, weight: Double)], in rect: CGRect, edges parentEdges: GapEdges, depth: Int32, parentCushion: SIMD4<Float>, tree: FileTree) {
        guard !items.isEmpty else { return }
        let rects = Squarify.layout(weights: items.map(\.weight), in: rect)
        for (item, raw) in zip(items, rects) {
            let child = item.node
            // Snap to the pixel grid. Neighbours share edges, so rounding both ends the same way
            // keeps the tiling gap-free; sub-pixel cells simply vanish into their neighbours.
            let x0 = raw.minX.rounded(), x1 = raw.maxX.rounded()
            let y0 = raw.minY.rounded(), y1 = raw.maxY.rounded()
            guard x1 > x0, y1 > y0 else { continue }
            let cellRect = CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
            let edges: GapEdges = isLarge(cellRect) ? .all : parentEdges.intersection(Self.touchingEdges(of: cellRect, in: rect))

            if child < 0 {
                // Volume pseudo cells: flat (no ridge of their own), never expanded.
                let slot = child == TreemapCell.freeSpaceNode ? TreemapPalette.freeSpaceSlot : TreemapPalette.otherSpaceSlot
                cells.append(TreemapCell(
                    node: child, rect: cellRect, depth: depth, isDirectory: false, isLeaf: true,
                    colorSlot: slot, gapEdges: edges, cushion: parentCushion
                ))
                continue
            }

            let node = tree[child]
            let cushion = parentCushion + parabola(for: cellRect, depth: depth)
            let expand = node.isDirectory && node.childCount > 0
                && cellRect.width >= Self.minimumExpandSize && cellRect.height >= Self.minimumExpandSize
            cells.append(TreemapCell(
                node: child, rect: cellRect, depth: depth, isDirectory: node.isDirectory, isLeaf: !expand,
                colorSlot: expand ? 0 : colorSlot(for: child, tree: tree), gapEdges: edges, cushion: cushion
            ))
            if expand {
                layoutChildren(of: child, in: cellRect, edges: edges, depth: depth + 1, parentCushion: cushion, tree: tree)
            }
        }
    }

    /// Gradient coefficients of the parabolic ridge z = 4h(x - x0)(x1 - x)/w² over the rect, per
    /// axis: dz/dx = -8h/w² · x + 4h(x0 + x1)/w².
    private func parabola(for rect: CGRect, depth: Int32) -> SIMD4<Float> {
        let level = shape.height * Float(pow(Double(shape.falloff), Double(depth)))
        func coefficients(_ start: CGFloat, _ end: CGFloat) -> (Float, Float) {
            let width = Float(end - start)
            guard width > 0 else { return (0, 0) }
            let height = level * min(width, shape.maxWidth)
            return (-8 * height / (width * width), 4 * height * Float(start + end) / (width * width))
        }
        let (s1x, s2x) = coefficients(rect.minX, rect.maxX)
        let (s1y, s2y) = coefficients(rect.minY, rect.maxY)
        return SIMD4(s1x, s2x, s1y, s2y)
    }

    /// Colour of a leaf: a file's own category or age, or that of a collapsed directory's
    /// largest descendant.
    private func colorSlot(for index: Int32, tree: FileTree) -> Int32 {
        var current = index
        for _ in 0 ..< 64 {
            let node = tree[current]
            guard node.isDirectory else {
                switch colorMode {
                case .fileType: return Int32(node.category)
                case .modified: return Int32(ModifiedBucket.index(modTime: node.modTime, reference: referenceTime))
                }
            }
            guard let largest = tree.orderedChildren(of: current, by: sizeMode).first,
                  tree[largest].size(sizeMode) > 0
            else { return TreemapPalette.emptyDirectorySlot }
            current = largest
        }
        return TreemapPalette.emptyDirectorySlot
    }

    /// The painted cell that represents `node`: its own leaf cell, or the collapsed directory
    /// cell it is hidden in. Nil when the node is outside the displayed subtree, or was culled
    /// as sub-pixel inside an expanded directory (its area belongs to visible siblings).
    func visibleCell(for node: Int32, tree: FileTree, index: [Int32: Int]) -> TreemapCell? {
        var current = node
        while current >= 0 {
            if let position = index[current] {
                let cell = cells[position]
                return cell.isLeaf ? cell : nil
            }
            current = tree[current].parent
        }
        return nil
    }

    /// Node → position in `cells`, for repeated lookups.
    func cellIndex() -> [Int32: Int] {
        var index: [Int32: Int] = [:]
        index.reserveCapacity(cells.count)
        for (position, cell) in cells.enumerated() { index[cell.node] = position }
        return index
    }

    /// The deepest cell containing `point` (in pixels): a leaf, or the enclosing directory when
    /// the point falls in a margin gap. Directories precede their contents, so the first hit
    /// scanning backwards is the deepest.
    func cell(at point: CGPoint) -> TreemapCell? {
        var index = cells.count - 1
        while index >= 0 {
            let cell = cells[index]
            if cell.rect.contains(point) { return cell }
            index -= 1
        }
        return nil
    }

    func cell(for node: Int32) -> TreemapCell? {
        cells.first { $0.node == node }
    }
}
