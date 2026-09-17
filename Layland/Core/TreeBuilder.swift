import Foundation
import Synchronization

/// A file that has more than one hard link; used to count shared inodes only once.
struct HardLinkRef {
    var device: Int32
    var inode: UInt64
    var node: Int32
}

/// Accumulates nodes from many scanning threads. Workers list a directory into thread-local
/// arrays and then commit the whole batch in one critical section, so the lock is taken once per
/// directory rather than once per file.
final class TreeBuilder: Sendable {
    private struct Storage {
        var nodes: [FileNode] = []
        var names: [UInt8] = []
    }

    private let storage: Mutex<Storage>

    init(rootPath: String) {
        var initial = Storage()
        initial.nodes.reserveCapacity(1 << 16)
        initial.names.reserveCapacity(1 << 20)
        let rootName = Array(rootPath.utf8)
        initial.names.append(contentsOf: rootName)
        initial.nodes.append(FileNode(
            parent: -1, nameOffset: 0, nameLength: UInt16(clamping: rootName.count), kind: .directory
        ))
        storage = Mutex(initial)
    }

    /// Appends `children` as the children of `parent`. `children[i].nameOffset` must be relative
    /// to `childNames`; it is rebased in place. Returns the index of the first appended child.
    func appendChildren(of parent: Int32, _ children: inout [FileNode], names childNames: [UInt8]) -> Int32 {
        storage.withLock { storage in
            let base = Int32(storage.nodes.count)
            let nameBase = UInt32(storage.names.count)
            for i in children.indices {
                children[i].parent = parent
                children[i].nameOffset &+= nameBase
            }
            storage.nodes.append(contentsOf: children)
            storage.names.append(contentsOf: childNames)
            storage.nodes[Int(parent)].firstChild = base
            storage.nodes[Int(parent)].childCount = Int32(children.count)
            return base
        }
    }

    func insertFlags(_ flags: NodeFlags, at index: Int32) {
        storage.withLock { _ = $0.nodes[Int(index)].flags.insert(flags) }
    }

    /// Resolves hard links, aggregates sizes and counts bottom-up, and produces the final tree.
    func finish(rootPath: String, hardLinks: [HardLinkRef]) -> FileTree {
        let (nodes, names) = storage.withLock { storage -> ([FileNode], [UInt8]) in
            var nodes = storage.nodes
            storage.nodes = []
            let names = storage.names
            storage.names = []

            var links = hardLinks
            links.sort {
                ($0.device, $0.inode, $0.node) < ($1.device, $1.inode, $1.node)
            }
            var previous: HardLinkRef?
            for link in links {
                if let previous, previous.device == link.device, previous.inode == link.inode {
                    nodes[Int(link.node)].logicalSize = 0
                    nodes[Int(link.node)].allocatedSize = 0
                    nodes[Int(link.node)].flags.insert(.hardLinkDuplicate)
                } else {
                    previous = link
                }
            }

            // Every node's index is greater than its parent's, so one reverse pass aggregates.
            nodes.withUnsafeMutableBufferPointer { buffer in
                var i = buffer.count - 1
                while i > 0 {
                    let node = buffer[i]
                    let parent = Int(node.parent)
                    buffer[parent].logicalSize &+= node.logicalSize
                    buffer[parent].allocatedSize &+= node.allocatedSize
                    buffer[parent].itemCount &+= node.itemCount &+ 1
                    i -= 1
                }
            }
            return (nodes, names)
        }
        return FileTree(rootPath: rootPath, nodes: nodes, names: names)
    }
}

/// An open directory descriptor shared by the work items of its child directories, so they can
/// be opened with `openat(2)` (one cached component lookup) instead of a full path walk. The
/// descriptor closes when the last pending child releases it.
final class DirectoryHandle: @unchecked Sendable {
    let fd: Int32

    init(fd: Int32) {
        self.fd = fd
    }

    deinit {
        close(fd)
    }
}

/// A directory waiting to be listed. `path` is NUL-terminated so it can be handed to `open(2)`;
/// the last component starts at `nameStart`.
struct WorkItem {
    var node: Int32
    var path: [UInt8]
    var nameStart: Int
    var parent: DirectoryHandle?
    /// Share of the whole scan this directory stands for (root = 1); split equally among its
    /// subdirectories, and credited to the progress estimate when a leaf directory finishes.
    var weight: Double
}

/// LIFO work queue shared by the scanning threads. LIFO keeps the traversal depth-first-ish,
/// which bounds the queue size and keeps recently touched directories hot in the kernel's caches.
final class WorkQueue: @unchecked Sendable {
    private let condition = NSCondition()
    private var items: [WorkItem] = []
    private var active = 0
    private var closed = false

    func push(_ item: WorkItem) {
        condition.lock()
        items.append(item)
        condition.signal()
        condition.unlock()
    }

    func push(contentsOf newItems: [WorkItem]) {
        guard !newItems.isEmpty else { return }
        condition.lock()
        items.append(contentsOf: newItems)
        if newItems.count == 1 { condition.signal() } else { condition.broadcast() }
        condition.unlock()
    }

    /// Blocks until an item is available. Returns nil once the queue is drained and no worker is
    /// still processing (so nothing more can be pushed), or after `close()`.
    func pop() -> WorkItem? {
        condition.lock()
        defer { condition.unlock() }
        while true {
            if closed { return nil }
            if let item = items.popLast() {
                active += 1
                return item
            }
            if active == 0 {
                closed = true
                condition.broadcast()
                return nil
            }
            condition.wait()
        }
    }

    /// Must be called once per successful `pop()` when the worker is done with that item.
    func finish() {
        condition.lock()
        active -= 1
        if active == 0, items.isEmpty {
            closed = true
            condition.broadcast()
        }
        condition.unlock()
    }

    func close() {
        condition.lock()
        closed = true
        items.removeAll()
        condition.broadcast()
        condition.unlock()
    }
}
