import Foundation

/// What the map's nesting follows (View ▸ Group By).
enum GroupMode: String, CaseIterable, Identifiable, Sendable {
    /// The folder hierarchy on disk.
    case folder
    /// Every file below the displayed folder, gathered by kind (see `ExtensionGroups`).
    case fileExtension

    var id: String { rawValue }

    var title: String {
        switch self {
        case .folder: "Folder"
        case .fileExtension: "File Extension"
        }
    }
}

/// The files below a folder, gathered for `GroupMode.fileExtension`: one group per file type
/// family (the `FileCategory` colors, with every hashed slot folded into "Other extensions",
/// as in the legend), each holding one group per extension, each holding its files. Files
/// without an extension sit directly in their family. Groups have no node in the tree, so cells
/// refer to them with pseudo node indices (`node(for:)`).
struct ExtensionGroups: Sendable {
    struct Group: Sendable {
        /// The family's name, or the extension with its dot (".jpg").
        var title: String
        /// Index of the enclosing family, or nil for a family.
        var parent: Int?
        var size: Int64
        var fileCount: Int
        /// Extension groups' pseudo nodes (in a family) or file indices, largest first.
        var members: [Int32]
    }

    /// What the status bar shows for a hovered group.
    struct Summary: Equatable, Sendable {
        var path: String
        var size: Int64
        var fileCount: Int
    }

    private(set) var groups: [Group] = []
    /// Pseudo nodes of the families, largest first.
    private(set) var families: [Int32] = []

    /// Group pseudo nodes count down from here, clear of the volume pseudo nodes.
    static let firstNode: Int32 = -16

    static func node(for group: Int) -> Int32 { firstNode - Int32(group) }

    static func index(of node: Int32) -> Int? { node <= firstNode ? Int(firstNode - node) : nil }

    func group(_ node: Int32) -> Group? {
        guard let index = Self.index(of: node), index < groups.count else { return nil }
        return groups[index]
    }

    func summary(of node: Int32) -> Summary? {
        guard let group = group(node) else { return nil }
        let path = group.parent.map { "\(groups[$0].title) › \(group.title)" } ?? group.title
        return Summary(path: path, size: group.size, fileCount: group.fileCount)
    }

    /// One pass over the index's files, which are already sorted: no sorting or hashing per
    /// file, so re-grouping on every zoom stays cheap even for millions of files.
    init(index: ExtensionIndex, root: Int32) {
        let first = index.preorder[Int(root)]
        guard first >= 0 else { return }
        let end = index.subtreeEnd[Int(root)]
        var groupOfFamily = [Int](repeating: -1, count: index.familyTitles.count)
        var groupOfExtension = [Int](repeating: -1, count: index.extensionTitles.count)
        var groups: [Group] = []

        index.files.withUnsafeBufferPointer { files in
            index.preorder.withUnsafeBufferPointer { preorder in
                for position in files.indices {
                    let file = files[position]
                    let order = preorder[Int(file.node)]
                    guard order >= first, order < end else { continue }
                    let size = Int64(file.size)
                    var family = groupOfFamily[Int(file.family)]
                    if family < 0 {
                        family = groups.count
                        groupOfFamily[Int(file.family)] = family
                        groups.append(Group(title: index.familyTitles[Int(file.family)], parent: nil, size: 0, fileCount: 0, members: []))
                    }
                    groups[family].size += size
                    groups[family].fileCount += 1
                    guard file.fileExtension >= 0 else {
                        groups[family].members.append(file.node)
                        continue
                    }
                    var group = groupOfExtension[Int(file.fileExtension)]
                    if group < 0 {
                        group = groups.count
                        groupOfExtension[Int(file.fileExtension)] = group
                        groups.append(Group(title: index.extensionTitles[Int(file.fileExtension)], parent: family, size: 0, fileCount: 0, members: []))
                        groups[family].members.append(Self.node(for: group))
                    }
                    groups[group].size += size
                    groups[group].fileCount += 1
                    groups[group].members.append(file.node)
                }
            }
        }

        // Files arrive largest first, so only a family's extension groups (a few hundred at
        // most) need sorting, then merging with the family's own files.
        for family in groups.indices where groups[family].parent == nil {
            let members = groups[family].members
            let files = members.filter { $0 >= 0 }
            let extensions = members.filter { $0 < 0 }.sorted { groups[Self.index(of: $0)!].size > groups[Self.index(of: $1)!].size }
            guard !files.isEmpty, !extensions.isEmpty else {
                groups[family].members = files.isEmpty ? extensions : files
                continue
            }
            var merged: [Int32] = []
            merged.reserveCapacity(members.count)
            var fileIndex = 0, extensionIndex = 0
            while fileIndex < files.count || extensionIndex < extensions.count {
                let takeFile = extensionIndex == extensions.count || (fileIndex < files.count
                    && index.size(of: files[fileIndex]) >= groups[Self.index(of: extensions[extensionIndex])!].size)
                if takeFile {
                    merged.append(files[fileIndex])
                    fileIndex += 1
                } else {
                    merged.append(extensions[extensionIndex])
                    extensionIndex += 1
                }
            }
            groups[family].members = merged
        }
        families = groups.indices.filter { groups[$0].parent == nil }
            .sorted { groups[$0].size > groups[$1].size }
            .map(Self.node(for:))
        self.groups = groups
    }

    init(tree: FileTree, root: Int32, sizeMode: SizeMode) {
        self.init(index: ExtensionIndex(tree: tree, sizeMode: sizeMode), root: root)
    }
}

/// What `ExtensionGroups` needs from a tree, computed once per tree and size mode (the slow
/// part: it sorts every file): the files largest first with their family and extension, and a
/// preorder numbering so "is this file below that folder" is two comparisons.
struct ExtensionIndex: Sendable {
    struct File: Sendable {
        var node: Int32
        /// Index into `extensionTitles`, or -1 for files without an extension.
        var fileExtension: Int32
        var size: UInt64
        /// Index into `familyTitles`.
        var family: UInt8
    }

    let files: [File]
    /// Per node: its position in a depth-first walk, or -1 if the walk never reached it (inside
    /// an empty or trashed folder).
    let preorder: [Int32]
    /// Per node: the preorder position just past its last descendant.
    let subtreeEnd: [Int32]
    let familyTitles: [String]
    let extensionTitles: [String]
    private let sizeMode: SizeMode
    private let tree: FileTree

    func size(of node: Int32) -> Int64 { tree[node].size(sizeMode) }

    init(tree: FileTree, sizeMode: SizeMode) {
        self.tree = tree
        self.sizeMode = sizeMode
        let otherSlot = Int(FileCategory.hashedSlots.lowerBound)
        familyTitles = FileCategory.titles + ["Other extensions"]
        var extensionOfHash: [UInt32: Int32] = [:]
        var extensionTitles: [String] = []
        var files: [File] = []
        var preorder = [Int32](repeating: -1, count: tree.count)
        var subtreeEnd = [Int32](repeating: -1, count: tree.count)

        tree.nodes.withUnsafeBufferPointer { nodes in
            tree.names.withUnsafeBufferPointer { names in
                // Negative entries close a folder: -1 - node.
                var stack: [Int32] = [FileTree.rootIndex]
                var next: Int32 = 0
                while let entry = stack.popLast() {
                    if entry < 0 {
                        subtreeEnd[Int(-1 - entry)] = next
                        continue
                    }
                    let node = nodes[Int(entry)]
                    let size = node.size(sizeMode)
                    // Trashed folders are zeroed but keep their contents: skipping empty folders
                    // leaves those out too.
                    guard size > 0 || entry == FileTree.rootIndex else { continue }
                    preorder[Int(entry)] = next
                    next += 1
                    if node.isDirectory {
                        stack.append(-1 - entry)
                        stack.append(contentsOf: node.firstChild ..< node.firstChild + node.childCount)
                        continue
                    }
                    subtreeEnd[Int(entry)] = next
                    let start = Int(node.nameOffset)
                    let name = UnsafeBufferPointer(rebasing: names[start ..< start + Int(node.nameLength)])
                    var fileExtension: Int32 = -1
                    if node.category != FileCategory.noExtension, let hash = FileCategory.extensionHash(forName: name) {
                        if let existing = extensionOfHash[hash] {
                            fileExtension = existing
                        } else {
                            fileExtension = Int32(extensionTitles.count)
                            extensionOfHash[hash] = fileExtension
                            extensionTitles.append("." + (tree.fileExtension(entry) ?? ""))
                        }
                    }
                    files.append(File(node: entry, fileExtension: fileExtension, size: UInt64(size), family: UInt8(min(Int(node.category), otherSlot))))
                }
            }
        }
        files.sort { $0.size > $1.size }
        self.files = files
        self.preorder = preorder
        self.subtreeEnd = subtreeEnd
        self.extensionTitles = extensionTitles
    }
}
