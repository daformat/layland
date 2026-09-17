import Foundation
import Testing
@testable import Layland

/// Builds a small directory tree in a temporary location:
///
///     root/
///       a/
///         file1      (100 bytes)
///         file2      (2048 bytes)
///         nested/
///           deep.txt (10 bytes)
///       b/           (empty)
///       c/
///         link1      (hard link to a/file1)
///         sym2       (symlink to ../a/file2)
///       .hidden      (1 byte)
struct Fixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaylandTests-\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("a/nested"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("b"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("c"), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 100).write(to: root.appendingPathComponent("a/file1"))
        try Data(repeating: 2, count: 2048).write(to: root.appendingPathComponent("a/file2"))
        try Data(repeating: 3, count: 10).write(to: root.appendingPathComponent("a/nested/deep.txt"))
        try Data(repeating: 4, count: 1).write(to: root.appendingPathComponent(".hidden"))
        try fm.linkItem(at: root.appendingPathComponent("a/file1"), to: root.appendingPathComponent("c/link1"))
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("c/sym2").path, withDestinationPath: "../a/file2")
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

extension FileTree {
    /// Finds a node by slash-separated path relative to the root.
    func node(at relativePath: String) -> Int32? {
        var current = FileTree.rootIndex
        for component in relativePath.split(separator: "/") {
            guard let next = children(of: current).first(where: { name($0) == component }) else { return nil }
            current = next
        }
        return current
    }
}

@Suite("DiskScanner")
struct DiskScannerTests {
    @Test("scans a small tree with correct sizes, kinds and counts")
    func scansSmallTree() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let result = try DiskScanner(rootPath: fixture.root.path).run()
        let tree = result.tree
        #expect(!result.cancelled)
        #expect(result.statistics.files == 5) // file1, file2, deep.txt, .hidden, link1
        #expect(result.statistics.directories == 4) // a, b, c, nested
        #expect(result.statistics.symlinks == 1)
        #expect(result.statistics.inaccessibleDirectories == 0)

        let file2 = try #require(tree.node(at: "a/file2"))
        #expect(tree[file2].kind == .file)
        #expect(tree[file2].logicalSize == 2048)
        #expect(tree[file2].allocatedSize >= 2048)
        #expect(tree.fileExtension(file2) == nil)

        let deep = try #require(tree.node(at: "a/nested/deep.txt"))
        #expect(tree.fileExtension(deep) == "txt")
        #expect(tree[deep].logicalSize == 10)

        // a/file1 is hard-linked from c/link1; whichever the scan met first keeps the 100 bytes.
        let file1 = try #require(tree.node(at: "a/file1"))
        let a = try #require(tree.node(at: "a"))
        #expect(tree[a].isDirectory)
        #expect(tree[a].logicalSize == tree[file1].logicalSize + 2048 + 10)
        #expect(tree[a].itemCount == 4) // file1, file2, nested, deep.txt

        let b = try #require(tree.node(at: "b"))
        #expect(tree.children(of: b).isEmpty)
        #expect(tree[b].logicalSize == 0)

        let sym = try #require(tree.node(at: "c/sym2"))
        #expect(tree[sym].kind == .symlink)
        #expect(tree[sym].logicalSize == "../a/file2".utf8.count)

        let hidden = try #require(tree.node(at: ".hidden"))
        #expect(tree[hidden].logicalSize == 1)
        #expect(tree.fileExtension(hidden) == nil)
    }

    @Test("counts a hard-linked file only once")
    func deduplicatesHardLinks() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let tree = try DiskScanner(rootPath: fixture.root.path).run().tree
        let file1 = try #require(tree.node(at: "a/file1"))
        let link1 = try #require(tree.node(at: "c/link1"))
        let duplicates = [file1, link1].filter { tree[$0].flags.contains(.hardLinkDuplicate) }
        #expect(duplicates.count == 1)
        #expect(tree[file1].logicalSize + tree[link1].logicalSize == 100)

        let root = tree[FileTree.rootIndex]
        let symlinkLength = Int64("../a/file2".utf8.count)
        #expect(root.logicalSize == 100 + 2048 + 10 + 1 + symlinkLength)
        #expect(root.itemCount == 10)
    }

    @Test("reconstructs absolute paths and ancestry")
    func reconstructsPaths() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let tree = try DiskScanner(rootPath: fixture.root.path + "/").run().tree
        #expect(tree.rootPath == fixture.root.path)
        let deep = try #require(tree.node(at: "a/nested/deep.txt"))
        #expect(tree.path(deep) == fixture.root.path + "/a/nested/deep.txt")
        #expect(FileManager.default.fileExists(atPath: tree.path(deep)))

        let ancestors = tree.ancestors(of: deep).map { tree.name($0) }
        #expect(ancestors == [fixture.root.path, "a", "nested", "deep.txt"])
        let a = try #require(tree.node(at: "a"))
        #expect(tree.isAncestor(a, of: deep))
        #expect(!tree.isAncestor(deep, of: a))
        #expect(tree.isAncestor(FileTree.rootIndex, of: a))
    }

    @Test("every node's index is greater than its parent's")
    func parentsPrecedeChildren() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let tree = try DiskScanner(rootPath: fixture.root.path).run().tree
        for index in 1 ..< tree.count {
            let node = tree.nodes[index]
            #expect(node.parent >= 0 && Int(node.parent) < index)
            if node.isDirectory, node.childCount > 0 {
                #expect(Int(node.firstChild) > index)
            }
        }
    }

    @Test("flags unreadable directories instead of failing")
    func flagsUnreadableDirectories() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let locked = fixture.root.appendingPathComponent("b")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }

        let result = try DiskScanner(rootPath: fixture.root.path).run()
        let b = try #require(result.tree.node(at: "b"))
        #expect(result.tree[b].flags.contains(.inaccessible))
        #expect(result.statistics.inaccessibleDirectories == 1)
        #expect(result.statistics.permissionDenied == 1)
    }

    @Test("markDeleted removes a subtree's contribution from its ancestors")
    func markDeleted() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let tree = try DiskScanner(rootPath: fixture.root.path).run().tree
        let before = tree[FileTree.rootIndex]
        let a = try #require(tree.node(at: "a"))
        let aSize = tree[a].logicalSize
        tree.markDeleted(a)
        #expect(tree[a].flags.contains(.deleted))
        #expect(tree[FileTree.rootIndex].logicalSize == before.logicalSize - aSize)
        #expect(tree[FileTree.rootIndex].itemCount == before.itemCount - 5)
    }

    @Test("progress estimate ends at 100%")
    func progressCompletes() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let scanner = DiskScanner(rootPath: fixture.root.path)
        #expect(scanner.progress().fraction == 0)
        _ = try scanner.run()
        #expect(abs(scanner.progress().fraction - 1) < 1e-9)
    }

    @Test("rejects a file path as root")
    func rejectsFileRoot() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        #expect(throws: ScanError.self) {
            try DiskScanner(rootPath: fixture.root.appendingPathComponent(".hidden").path).run()
        }
    }
}

@Suite("FileCategory")
struct FileCategoryTests {
    private func slot(_ name: String) -> UInt8 {
        FileCategory.slot(forName: Array(name.utf8)[...])
    }

    @Test("known extensions map to their family, case-insensitively")
    func knownExtensions() {
        #expect(slot("photo.JPG") == 1)
        #expect(slot("photo.jpeg") == 1)
        #expect(slot("clip.mov") == 2)
        #expect(slot("archive.tar.gz") == 4)
        #expect(slot("main.swift") == 6)
        #expect(slot("libfoo.dylib") == 7)
    }

    @Test("names without a usable extension get slot 0")
    func noExtension() {
        #expect(slot("Makefile") == 0)
        #expect(slot(".zshrc") == 0)
        #expect(slot("trailing.") == 0)
        #expect(slot("weird.extensionthatistoolong") == 0)
    }

    @Test("unknown extensions hash into the shared slots, deterministically")
    func unknownExtensions() {
        let slot = slot("data.qwertz")
        #expect(FileCategory.hashedSlots.contains(slot))
        #expect(slot == self.slot("other.QWERTZ"))
    }

    @Test("the scanner stores the category on file nodes")
    func storedOnNodes() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let tree = try DiskScanner(rootPath: fixture.root.path).run().tree
        #expect(tree[try #require(tree.node(at: "a/nested/deep.txt"))].category == 5)
        #expect(tree[try #require(tree.node(at: "a/file1"))].category == 0)
    }
}

@Suite("ScanArchive")
struct ScanArchiveTests {
    @Test("a scan survives a save/load round trip")
    func roundTrip() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let original = try DiskScanner(rootPath: fixture.root.path).run()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("roundtrip-\(UUID().uuidString).layland")
        defer { try? FileManager.default.removeItem(at: file) }

        try ScanArchive.write(original, to: file)
        let loaded = try ScanArchive.read(from: file)

        #expect(loaded.tree.rootPath == original.tree.rootPath)
        #expect(loaded.tree.count == original.tree.count)
        #expect(loaded.tree.names == original.tree.names)
        #expect(loaded.statistics.files == original.statistics.files)
        #expect(abs(loaded.date.timeIntervalSince(original.date)) < 0.001)
        #expect(loaded.volumeSize == original.volumeSize)
        for index in 0 ..< original.tree.count {
            let a = original.tree.nodes[index], b = loaded.tree.nodes[index]
            #expect(a.parent == b.parent && a.firstChild == b.firstChild && a.childCount == b.childCount)
            #expect(a.logicalSize == b.logicalSize && a.allocatedSize == b.allocatedSize && a.category == b.category)
        }
        let deep = try #require(loaded.tree.node(at: "a/nested/deep.txt"))
        #expect(loaded.tree.sortedChildren(of: FileTree.rootIndex, by: .logical).first == original.tree.sortedChildren(of: FileTree.rootIndex, by: .logical).first)
        #expect(loaded.tree.path(deep) == original.tree.path(try #require(original.tree.node(at: "a/nested/deep.txt"))))
    }

    @Test("garbage is rejected")
    func rejectsGarbage() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("garbage-\(UUID().uuidString).layland")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("not a scan".utf8).write(to: file)
        #expect(throws: ScanArchive.ArchiveError.self) { try ScanArchive.read(from: file) }
    }
}

@Suite("FileTree search")
struct FileTreeSearchTests {
    @Test("matches names case-insensitively, files and folders alike")
    func search() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let tree = try DiskScanner(rootPath: fixture.root.path).run().tree

        let files = Set(tree.search("FILE").map { tree.name($0) })
        #expect(files == ["file1", "file2"])
        #expect(tree.search("deep").map { tree.name($0) } == ["deep.txt"])
        #expect(tree.search("NESTED").map { tree.name($0) } == ["nested"])
        #expect(tree.search(".txt").count == 1)
        #expect(tree.search("zzz").isEmpty)
        #expect(tree.search("").isEmpty)
        #expect(tree.search("file1234567890").isEmpty)
    }
}
