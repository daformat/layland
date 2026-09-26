import CoreGraphics
import Foundation
import Testing
@testable import Layland

@Suite("TreemapLayout")
struct TreemapLayoutTests {
    @Test("leaves tile the whole image with no gaps or overlaps")
    func leavesTile() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let tree = try DiskScanner(rootPath: fixture.root.path).run().tree

        for size in [CGSize(width: 200, height: 120), CGSize(width: 7, height: 5), CGSize(width: 1, height: 1)] {
            let layout = TreemapLayout(tree: tree, root: FileTree.rootIndex, pixelSize: size, sizeMode: .logical)
            let leaves = layout.cells.filter(\.isLeaf)
            let covered = leaves.reduce(0.0) { $0 + $1.rect.width * $1.rect.height }
            #expect(covered == size.width * size.height, "covered \(covered) of \(size)")
            for leaf in leaves {
                #expect(leaf.rect.minX == leaf.rect.minX.rounded() && leaf.rect.width == leaf.rect.width.rounded())
                #expect(CGRect(origin: .zero, size: size).contains(leaf.rect))
            }
            for i in leaves.indices {
                for j in leaves.indices where i < j {
                    #expect(!leaves[i].rect.intersects(leaves[j].rect), "\(leaves[i].rect) overlaps \(leaves[j].rect)")
                }
            }
            for y in stride(from: 0.5, to: size.height, by: 1) {
                for x in stride(from: 0.5, to: size.width, by: 1) {
                    #expect(layout.cell(at: CGPoint(x: x, y: y))?.isLeaf == true)
                }
            }
        }
    }

    @Test("margins give every gap the same width")
    func margins() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let tree = try DiskScanner(rootPath: fixture.root.path).run().tree
        let size = CGSize(width: 400, height: 300)
        let layout = TreemapLayout(tree: tree, root: FileTree.rootIndex, pixelSize: size, sizeMode: .logical, margin: 2)

        // Folders never inset their contents: leaves still tile the whole image.
        let leaves = layout.cells.filter(\.isLeaf)
        #expect(leaves.reduce(0.0) { $0 + $1.rect.width * $1.rect.height } == size.width * size.height)

        func isLarge(_ rect: CGRect) -> Bool {
            rect.width >= TreemapLayout.marginThreshold && rect.height >= TreemapLayout.marginThreshold
        }
        for leaf in leaves {
            let painted = layout.paintRect(of: leaf)
            if isLarge(leaf.rect) {
                #expect(painted == leaf.rect.insetBy(dx: 2, dy: 2))
            } else {
                // A small leaf recedes on a side exactly when a large enclosing folder shares it.
                let largeAncestors = tree.ancestors(of: leaf.node).dropLast()
                    .compactMap { layout.cell(for: $0)?.rect }.filter(isLarge)
                #expect(painted.minX == leaf.rect.minX + (largeAncestors.contains { $0.minX == leaf.rect.minX } ? 2 : 0))
                #expect(painted.maxX == leaf.rect.maxX - (largeAncestors.contains { $0.maxX == leaf.rect.maxX } ? 2 : 0))
                #expect(painted.minY == leaf.rect.minY + (largeAncestors.contains { $0.minY == leaf.rect.minY } ? 2 : 0))
                #expect(painted.maxY == leaf.rect.maxY - (largeAncestors.contains { $0.maxY == leaf.rect.maxY } ? 2 : 0))
            }
        }
        // Without a margin nothing recedes.
        let plain = TreemapLayout(tree: tree, root: FileTree.rootIndex, pixelSize: size, sizeMode: .logical, margin: 0)
        for leaf in plain.cells where leaf.isLeaf {
            #expect(plain.paintRect(of: leaf) == leaf.rect)
        }
    }

    @Test("search highlighting resolves to painted cells only")
    func visibleCells() throws {
        // root: big.bin (1 MB), tiny/x.txt (6 kB → a 2 px sliver, collapsed), and 200 one-byte
        // files of which most are culled as sub-pixel.
        let builder = TreeBuilder(rootPath: "/synthetic")
        func add(_ parent: Int32, _ entries: [(String, NodeKind, Int64)]) -> [Int32] {
            var names: [UInt8] = []
            var nodes: [FileNode] = []
            for (name, kind, size) in entries {
                let bytes = Array(name.utf8)
                nodes.append(FileNode(parent: parent, nameOffset: UInt32(names.count), nameLength: UInt16(bytes.count), kind: kind, logicalSize: size, allocatedSize: size))
                names.append(contentsOf: bytes)
            }
            let base = builder.appendChildren(of: parent, &nodes, names: names)
            return (0 ..< Int32(entries.count)).map { base + $0 }
        }
        let specks = (0 ..< 200).map { ("speck-\($0).txt", NodeKind.file, Int64(1)) }
        let top = add(FileTree.rootIndex, [("big.bin", .file, 1_000_000), ("tiny", .directory, 0)] + specks)
        let x = add(top[1], [("x.txt", .file, 6_000)])[0]
        let tree = builder.finish(rootPath: "/synthetic", hardLinks: [])

        let layout = TreemapLayout(tree: tree, root: FileTree.rootIndex, pixelSize: CGSize(width: 400, height: 300), sizeMode: .logical)
        let index = layout.cellIndex()

        // A visible file resolves to itself.
        #expect(layout.visibleCell(for: top[0], tree: tree, index: index)?.node == top[0])
        // A file hidden in a collapsed folder resolves to that folder's leaf cell.
        #expect(layout.cell(for: top[1])?.isLeaf == true)
        #expect(layout.visibleCell(for: x, tree: tree, index: index)?.node == top[1])
        // A culled file under an expanded folder (the root) resolves to nothing.
        let culled = try #require(top[2...].first { layout.cell(for: $0) == nil })
        #expect(layout.visibleCell(for: culled, tree: tree, index: index) == nil)
        // An expanded folder is never returned, even for its own node.
        #expect(layout.visibleCell(for: FileTree.rootIndex, tree: tree, index: index) == nil)
    }

    @Test("directories precede their contents and carry their parents' cushions")
    func depthFirstWithCushions() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let tree = try DiskScanner(rootPath: fixture.root.path).run().tree
        let layout = TreemapLayout(tree: tree, root: FileTree.rootIndex, pixelSize: CGSize(width: 400, height: 300), sizeMode: .logical)

        #expect(layout.cells.first?.node == FileTree.rootIndex)
        #expect(layout.cells.first?.isLeaf == false)
        let a = try #require(tree.node(at: "a"))
        let nested = try #require(tree.node(at: "a/nested"))
        let aCell = try #require(layout.cell(for: a))
        let nestedCell = try #require(layout.cell(for: nested))
        #expect(nestedCell.depth == 2)
        #expect(aCell.rect.contains(nestedCell.rect))
        // The deeper cell's surface is its parents' surface plus its own ridge.
        #expect(nestedCell.cushion != aCell.cushion)
        // Whether `nested` (10 bytes) gets a sliver or a real cell depends on which hard link of
        // file1 kept its size; either way the rule holds: a collapsed folder takes its largest
        // file's color (deep.txt → documents slot), an expanded one shows the file itself.
        let deep = try #require(tree.node(at: "a/nested/deep.txt"))
        if nestedCell.isLeaf {
            #expect(nestedCell.colorSlot == 5)
            #expect(layout.cell(for: deep) == nil)
        } else {
            #expect(layout.cell(for: deep)?.colorSlot == 5)
        }
    }
}

@Suite("Color modes and volume")
struct ColorModeTests {
    @Test("modification times fall into the expected age buckets")
    func buckets() {
        let now = Date().timeIntervalSince1970
        func bucket(daysAgo: Double) -> Int {
            ModifiedBucket.index(modTime: UInt32(now - daysAgo * 86_400), reference: now)
        }
        #expect(bucket(daysAgo: 0.1) == 0)
        #expect(bucket(daysAgo: 3) == 1)
        #expect(bucket(daysAgo: 20) == 2)
        #expect(bucket(daysAgo: 60) == 3)
        #expect(bucket(daysAgo: 150) == 4)
        #expect(bucket(daysAgo: 300) == 5)
        #expect(bucket(daysAgo: 600) == 6)
        #expect(bucket(daysAgo: 1500) == 7)
        #expect(bucket(daysAgo: 4000) == 8)
        #expect(ModifiedBucket.index(modTime: 0, reference: now) == ModifiedBucket.count - 1)
        #expect(TreemapPalette.modifiedColors.count == ModifiedBucket.count)
        #expect(TreemapPalette.legend(for: .modified).count == ModifiedBucket.count)
    }

    @Test("modified mode colors leaves by age, file-type mode by category")
    func colorSlots() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let tree = try DiskScanner(rootPath: fixture.root.path).run().tree
        let size = CGSize(width: 400, height: 300)
        let byType = TreemapLayout(tree: tree, root: FileTree.rootIndex, pixelSize: size, sizeMode: .logical, colorMode: .fileType)
        let byAge = TreemapLayout(tree: tree, root: FileTree.rootIndex, pixelSize: size, sizeMode: .logical, colorMode: .modified)
        let file2 = try #require(tree.node(at: "a/file2"))
        #expect(try #require(byType.cell(for: file2)).colorSlot == 0)
        #expect(try #require(byAge.cell(for: file2)).colorSlot == 0) // just created → "Today"
    }

    @Test("volume info adds free and other space cells at the root only")
    func volumeCells() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let tree = try DiskScanner(rootPath: fixture.root.path).run().tree
        let size = CGSize(width: 400, height: 300)
        let scanned = tree[FileTree.rootIndex].logicalSize
        let volume = TreemapLayout.VolumeInfo(size: scanned * 10, free: scanned * 4)
        let layout = TreemapLayout(tree: tree, root: FileTree.rootIndex, pixelSize: size, sizeMode: .logical, volume: volume)

        let free = try #require(layout.cells.first { $0.node == TreemapCell.freeSpaceNode })
        let other = try #require(layout.cells.first { $0.node == TreemapCell.otherSpaceNode })
        #expect(free.isLeaf && other.isLeaf && free.colorSlot == TreemapPalette.freeSpaceSlot && other.colorSlot == TreemapPalette.otherSpaceSlot)
        // Areas: free = 4/10, other = 5/10, scanned = 1/10 of the image.
        let area = size.width * size.height
        #expect(abs(free.rect.width * free.rect.height / area - 0.4) < 0.02)
        #expect(abs(other.rect.width * other.rect.height / area - 0.5) < 0.02)
        let leaves = layout.cells.filter(\.isLeaf)
        #expect(leaves.reduce(0.0) { $0 + $1.rect.width * $1.rect.height } == area)
        #expect(layout.cell(at: CGPoint(x: free.rect.midX, y: free.rect.midY))?.node == TreemapCell.freeSpaceNode)

        // Zoomed into a folder: no pseudo cells.
        let a = try #require(tree.node(at: "a"))
        let zoomed = TreemapLayout(tree: tree, root: a, pixelSize: size, sizeMode: .logical, volume: volume)
        #expect(!zoomed.cells.contains { $0.node < 0 })
    }
}

struct AgeRampTests {
    @Test("every palette yields a full age ramp, and grays fall back to the default")
    func ramps() {
        for scheme in PaletteScheme.allCases {
            let ramp = TreemapPalette.ageRamp(from: TreemapPalette.presetColors[scheme]!)
            #expect(ramp.count == ModifiedBucket.count)
            #expect(Set(ramp).count > 3, "\(scheme) ramp is too flat")
        }
        #expect(TreemapPalette.ageRamp(from: Array(repeating: 0x808080, count: 20)) == TreemapPalette.modifiedColors)
    }
}
