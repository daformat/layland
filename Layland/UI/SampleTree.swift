import Foundation

/// A synthetic tree that exercises every colour slot, shown while the palette editor is open.
///
/// Shaped like real data — categories of very different totals, log-normal file sizes with a
/// long tail of small files, irregular nesting — but weighted so that even the smallest
/// category still gets a couple of percent of the area and stays visible.
enum SampleTree {
    static let shared: FileTree = build()

    private struct Entry {
        var name: String
        var kind: NodeKind
        var size: Int64
        var category: UInt8
    }

    private static let extensions: [String] = [
        "", "jpg", "mov", "mp3", "zip", "pdf", "swift", "dylib", "json", "ttf", "car",
        "misc1", "misc2", "misc3", "misc4", "misc5", "misc6", "misc7", "misc8", "misc9",
    ]

    /// Relative total size per category slot (video and images dominate, fonts are tiny).
    private static let weights: [Double] = [
        1.4, 3.2, 6.0, 2.2, 2.6, 1.3, 1.6, 2.4, 1.9, 0.6, 0.8,
        0.9, 1.2, 0.7, 1.5, 0.8, 1.1, 0.6, 1.3, 1.0,
    ]

    private static func build() -> FileTree {
        let builder = TreeBuilder(rootPath: "Sample Data")
        var random = SplitMix64(seed: 0x5EED)

        let groups: [(String, [UInt8])] = [
            ("Documents", [5, 8, 0, 11, 12]),
            ("Media", [1, 2, 3, 13, 14]),
            ("Code", [6, 7, 9, 15, 16]),
            ("System", [10, 4, 17, 18, 19]),
        ]
        let groupNodes = append(to: builder, parent: FileTree.rootIndex, entries: groups.map {
            Entry(name: $0.0, kind: .directory, size: 0, category: 0)
        })

        for (groupIndex, group) in groups.enumerated() {
            let folders = group.1.map { slot in
                Entry(name: TreemapPalette.slotTitles[Int(slot)], kind: .directory, size: 0, category: slot)
            }
            let folderNodes = append(to: builder, parent: groupNodes[groupIndex], entries: folders)
            for (folderIndex, slot) in group.1.enumerated() {
                let budget = weights[Int(slot)] * 4_000_000_000
                populate(builder, folder: folderNodes[folderIndex], slot: slot, budget: budget, depth: 0, random: &random)
            }
        }
        return builder.finish(rootPath: "Sample Data", hardLinks: [])
    }

    private static let folderNames = ["src", "assets", "cache", "build", "2024", "2025", "archive", "exports", "lib", "tmp", "vendor", "samples"]

    /// Fills `folder` with about `budget` bytes: some files here, the rest in nested folders.
    private static func populate(_ builder: TreeBuilder, folder: Int32, slot: UInt8, budget: Double, depth: Int, random: inout SplitMix64) {
        let ext = extensions[Int(slot)]
        let subfolderCount = depth >= 3 ? 0 : random.next(in: depth == 0 ? 1 ... 3 : 0 ... 2)
        let fileShare = subfolderCount == 0 ? 1.0 : random.uniform(in: 0.25 ... 0.7)

        // Files: log-normal sizes (a few large, many small), scaled to the file budget.
        let fileCount = random.next(in: 8 ... 45)
        var sizes = (0 ..< fileCount).map { _ in exp(random.normal() * 1.6) }
        let scale = budget * fileShare / sizes.reduce(0, +)
        sizes = sizes.map { $0 * scale }

        var entries: [Entry] = []
        for (index, size) in sizes.enumerated() {
            let name = ext.isEmpty ? "item-\(depth)-\(index)" : "item-\(depth)-\(index).\(ext)"
            entries.append(Entry(name: name, kind: .file, size: Int64(size), category: slot))
        }
        var subfolderShares: [Double] = []
        if subfolderCount > 0 {
            subfolderShares = (0 ..< subfolderCount).map { _ in random.uniform(in: 0.3 ... 1.0) }
            let total = subfolderShares.reduce(0, +)
            subfolderShares = subfolderShares.map { $0 / total * (1 - fileShare) }
            for index in 0 ..< subfolderCount {
                let name = folderNames[random.next(in: 0 ... folderNames.count - 1)] + (index > 0 ? "-\(index)" : "")
                entries.append(Entry(name: name, kind: .directory, size: 0, category: slot))
            }
        }
        let nodes = append(to: builder, parent: folder, entries: entries)
        for (index, share) in subfolderShares.enumerated() {
            populate(builder, folder: nodes[fileCount + index], slot: slot, budget: budget * share, depth: depth + 1, random: &random)
        }
    }

    /// Appends `entries` as children of `parent`; returns their node indices.
    private static func append(to builder: TreeBuilder, parent: Int32, entries: [Entry]) -> [Int32] {
        var names: [UInt8] = []
        var nodes: [FileNode] = []
        for entry in entries {
            let bytes = Array(entry.name.utf8)
            var node = FileNode(
                parent: parent, nameOffset: UInt32(names.count), nameLength: UInt16(bytes.count), kind: entry.kind,
                logicalSize: entry.size, allocatedSize: entry.size
            )
            node.category = entry.category
            // Spread modification times over ~8 years so age colouring has something to show.
            var hash = UInt64(bitPattern: Int64(entry.size)) &* 0x9E37_79B9_7F4A_7C15
            hash ^= hash >> 29
            let daysAgo = Double(hash % 3000) * (hash % 3 == 0 ? 0.01 : 1)
            node.modTime = UInt32(clamping: Int(Date().timeIntervalSince1970 - daysAgo * 86_400))
            names.append(contentsOf: bytes)
            nodes.append(node)
        }
        let base = builder.appendChildren(of: parent, &nodes, names: names)
        return (0 ..< Int32(entries.count)).map { base + $0 }
    }

    private struct SplitMix64 {
        var state: UInt64
        init(seed: UInt64) { state = seed }

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }

        mutating func next(in range: ClosedRange<Int>) -> Int {
            range.lowerBound + Int(next() % UInt64(range.count))
        }

        mutating func uniform(in range: ClosedRange<Double>) -> Double {
            range.lowerBound + Double(next() >> 11) / Double(1 << 53) * (range.upperBound - range.lowerBound)
        }

        /// Approximately standard normal (Irwin–Hall of 12 uniforms).
        mutating func normal() -> Double {
            (0 ..< 12).reduce(0.0) { sum, _ in sum + uniform(in: 0 ... 1) } - 6
        }
    }
}
