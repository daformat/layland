import Foundation

/// Which notion of "size" to display.
public enum SizeMode: String, CaseIterable, Sendable, Identifiable {
    /// Logical file length (what `ls -l` reports).
    case logical
    /// Blocks actually allocated on disk (honours APFS compression and sparse files).
    case allocated

    public var id: String { rawValue }

    /// Index into per-mode caches.
    var ordinal: Int { self == .logical ? 0 : 1 }

    public var title: String {
        switch self {
        case .logical: "Logical size"
        case .allocated: "Size on disk"
        }
    }
}

public enum NodeKind: UInt8, Sendable {
    case directory = 0
    case file = 1
    case symlink = 2
    case other = 3
}

public struct NodeFlags: OptionSet, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    /// Directory could not be opened (permissions, TCC, ...).
    public static let inaccessible = NodeFlags(rawValue: 1 << 0)
    /// Another node with the same (device, inode) already accounts for this file's size.
    public static let hardLinkDuplicate = NodeFlags(rawValue: 1 << 1)
    /// Directory is a mount point for another volume and was not entered.
    public static let mountPoint = NodeFlags(rawValue: 1 << 2)
    /// Directory is an APFS firmlink (e.g. `/Users` on the system volume).
    public static let firmlink = NodeFlags(rawValue: 1 << 3)
    /// Listing the directory failed part-way through, or the entry's attributes could not be read.
    public static let readError = NodeFlags(rawValue: 1 << 4)
    /// The item was moved to the Trash after the scan.
    public static let deleted = NodeFlags(rawValue: 1 << 5)
}

/// One entry of the scanned tree. Nodes live in a flat array; a directory's children occupy the
/// contiguous index range `firstChild ..< firstChild + childCount`, and every node's index is
/// greater than its parent's, which makes bottom-up aggregation a single reverse pass.
public struct FileNode: Sendable {
    /// Own size for files; total of the subtree for directories (after aggregation).
    public var logicalSize: Int64
    public var allocatedSize: Int64
    /// Index of the parent node, or -1 for the root.
    public var parent: Int32
    public var firstChild: Int32
    public var childCount: Int32
    /// Offset of the name in `FileTree.names`.
    public var nameOffset: UInt32
    /// Number of descendants of any kind (directories: after aggregation; files: 0).
    public var itemCount: UInt32
    /// Modification time as seconds since 1970 (clamped to 32 bits).
    public var modTime: UInt32
    public var nameLength: UInt16
    public var kind: NodeKind
    public var flags: NodeFlags
    /// `FileCategory` slot (files only; 0 otherwise).
    public var category: UInt8

    public init(
        parent: Int32, nameOffset: UInt32, nameLength: UInt16, kind: NodeKind,
        logicalSize: Int64 = 0, allocatedSize: Int64 = 0, modTime: UInt32 = 0, flags: NodeFlags = []
    ) {
        self.logicalSize = logicalSize
        self.allocatedSize = allocatedSize
        self.parent = parent
        self.firstChild = -1
        self.childCount = 0
        self.nameOffset = nameOffset
        self.itemCount = 0
        self.modTime = modTime
        self.nameLength = nameLength
        self.kind = kind
        self.flags = flags
        self.category = 0
    }

    public var isDirectory: Bool { kind == .directory }

    public func size(_ mode: SizeMode) -> Int64 {
        switch mode {
        case .logical: logicalSize
        case .allocated: allocatedSize
        }
    }
}

/// The result of a scan: a compact, index-addressed tree. Immutable except for `markDeleted`,
/// which must only be called from the thread that owns the tree (the main thread in the app).
public final class FileTree: @unchecked Sendable {
    public static let rootIndex: Int32 = 0

    public let rootPath: String
    public private(set) var nodes: [FileNode]
    public let names: [UInt8]
    /// Per size mode, a permutation of node indices in which every directory's children occupy
    /// their usual index range but sorted by descending size. Computed once so treemap layouts
    /// never sort.
    private var childOrder: [[Int32]]

    init(rootPath: String, nodes: [FileNode], names: [UInt8]) {
        self.rootPath = rootPath
        self.nodes = nodes
        self.names = names
        childOrder = SizeMode.allCases.map { Self.buildChildOrder(nodes: nodes, mode: $0) }
    }

    private static func buildChildOrder(nodes: [FileNode], mode: SizeMode) -> [Int32] {
        var order = [Int32](unsafeUninitializedCapacity: nodes.count) { buffer, count in
            for index in 0 ..< nodes.count { buffer[index] = Int32(index) }
            count = nodes.count
        }
        nodes.withUnsafeBufferPointer { nodes in
            order.withUnsafeMutableBufferPointer { order in
                for index in 0 ..< nodes.count {
                    let node = nodes[index]
                    guard node.childCount > 1 else { continue }
                    let range = Int(node.firstChild) ..< Int(node.firstChild + node.childCount)
                    order[range].sort { nodes[Int($0)].size(mode) > nodes[Int($1)].size(mode) }
                }
            }
        }
        return order
    }

    private func resortChildren(of index: Int32) {
        let node = nodes[Int(index)]
        guard node.childCount > 1 else { return }
        let range = Int(node.firstChild) ..< Int(node.firstChild + node.childCount)
        for mode in SizeMode.allCases {
            childOrder[mode.ordinal][range].sort { nodes[Int($0)].size(mode) > nodes[Int($1)].size(mode) }
        }
    }

    public var count: Int { nodes.count }

    public subscript(index: Int32) -> FileNode {
        nodes[Int(index)]
    }

    public func children(of index: Int32) -> Range<Int32> {
        let node = nodes[Int(index)]
        guard node.childCount > 0 else { return 0..<0 }
        return node.firstChild ..< node.firstChild + node.childCount
    }

    public func nameBytes(_ index: Int32) -> ArraySlice<UInt8> {
        let node = nodes[Int(index)]
        let start = Int(node.nameOffset)
        return names[start ..< start + Int(node.nameLength)]
    }

    public func name(_ index: Int32) -> String {
        String(decoding: nameBytes(index), as: UTF8.self)
    }

    /// Lower-cased extension without the dot, or nil for names like `Makefile` or `.zshrc`.
    public func fileExtension(_ index: Int32) -> String? {
        let bytes = nameBytes(index)
        guard let dot = bytes.lastIndex(of: UInt8(ascii: ".")), dot > bytes.startIndex, dot < bytes.endIndex - 1 else {
            return nil
        }
        return String(decoding: bytes[(dot + 1)...], as: UTF8.self).lowercased()
    }

    /// Indices from the root down to `index`, inclusive.
    public func ancestors(of index: Int32) -> [Int32] {
        var chain: [Int32] = []
        var current = index
        while current >= 0 {
            chain.append(current)
            current = nodes[Int(current)].parent
        }
        chain.reverse()
        return chain
    }

    public func isAncestor(_ ancestor: Int32, of index: Int32) -> Bool {
        var current = nodes[Int(index)].parent
        while current >= 0 {
            if current == ancestor { return true }
            current = nodes[Int(current)].parent
        }
        return false
    }

    /// Absolute path of a node. The root node's name is the full root path.
    public func path(_ index: Int32) -> String {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(256)
        for (position, node) in ancestors(of: index).enumerated() {
            let name = nameBytes(node)
            if position > 0, bytes.last != UInt8(ascii: "/") {
                bytes.append(UInt8(ascii: "/"))
            }
            bytes.append(contentsOf: name)
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    public func url(_ index: Int32) -> URL {
        URL(fileURLWithPath: path(index), isDirectory: nodes[Int(index)].isDirectory)
    }

    /// All children of `index`, largest first (zero-sized ones at the end). No allocation.
    public func orderedChildren(of index: Int32, by mode: SizeMode) -> ArraySlice<Int32> {
        let node = nodes[Int(index)]
        guard node.childCount > 0 else { return [] }
        let start = Int(node.firstChild)
        return childOrder[mode.ordinal][start ..< start + Int(node.childCount)]
    }

    /// Children of `index` with a non-zero size, largest first.
    public func sortedChildren(of index: Int32, by mode: SizeMode) -> [Int32] {
        Array(orderedChildren(of: index, by: mode).prefix { nodes[Int($0)].size(mode) > 0 })
    }

    /// Indices of all nodes whose name contains `query`, case-insensitively for ASCII letters.
    /// Works on the raw name bytes, so a few million names take tens of milliseconds.
    public func search(_ query: String) -> [Int32] {
        let pattern = Array(query.utf8).map(Self.lowercased)
        guard !pattern.isEmpty else { return [] }
        var matches: [Int32] = []
        names.withUnsafeBufferPointer { names in
            nodes.withUnsafeBufferPointer { nodes in
                for index in 0 ..< nodes.count {
                    let node = nodes[index]
                    let length = Int(node.nameLength)
                    guard length >= pattern.count else { continue }
                    let start = Int(node.nameOffset)
                    var position = start
                    let last = start + length - pattern.count
                    search: while position <= last {
                        if Self.lowercased(names[position]) == pattern[0] {
                            var offset = 1
                            while offset < pattern.count, Self.lowercased(names[position + offset]) == pattern[offset] { offset += 1 }
                            if offset == pattern.count {
                                matches.append(Int32(index))
                                break search
                            }
                        }
                        position += 1
                    }
                }
            }
        }
        return matches
    }

    /// Levels below the root: 0 for the root, 1 for its children, and so on.
    public func depth(_ index: Int32) -> Int {
        var depth = 0
        var current = nodes[Int(index)].parent
        while current >= 0 {
            depth += 1
            current = nodes[Int(current)].parent
        }
        return depth
    }

    /// True if the node, or a folder containing it, was moved to the Trash.
    public func isRemoved(_ index: Int32) -> Bool {
        var current = index
        while current >= 0 {
            if nodes[Int(current)].flags.contains(.deleted) { return true }
            current = nodes[Int(current)].parent
        }
        return false
    }

    @inline(__always)
    private static func lowercased(_ byte: UInt8) -> UInt8 {
        byte >= 65 && byte <= 90 ? byte + 32 : byte
    }

    /// Removes a subtree's contribution after the item was trashed, so the treemap can be
    /// re-laid out without a rescan.
    public func markDeleted(_ index: Int32) {
        let removed = nodes[Int(index)]
        guard !removed.flags.contains(.deleted) else { return }
        nodes[Int(index)].flags.insert(.deleted)
        nodes[Int(index)].logicalSize = 0
        nodes[Int(index)].allocatedSize = 0
        var current = removed.parent
        while current >= 0 {
            nodes[Int(current)].logicalSize -= removed.logicalSize
            nodes[Int(current)].allocatedSize -= removed.allocatedSize
            nodes[Int(current)].itemCount -= removed.itemCount + 1
            resortChildren(of: current)
            current = nodes[Int(current)].parent
        }
    }
}
