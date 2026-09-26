import Darwin
import Foundation
import Synchronization

public struct ScanOptions: Sendable {
    /// Number of scanning threads. Listing a directory typically costs one or two 4 KB metadata
    /// reads that APFS does not keep cached across scans, so the scan is bound by disk latency
    /// rather than CPU: oversubscribing the cores ~4x keeps the SSD's queue full and measured
    /// ~5x faster than `du` on a 3.8M-entry home folder.
    public var threadCount: Int = ScanOptions.defaultThreadCount
    /// Follow APFS firmlinks (e.g. `/Users` on the system volume points into the Data volume).
    public var followFirmlinks = true
    /// Descend into directories that are mount points of other volumes.
    public var crossMountPoints = false
    /// Debug override for the requested attribute groups (common, dir, file).
    var attributeOverride: (common: UInt32, dir: UInt32, file: UInt32)?

    public init() {}

    public static var defaultThreadCount: Int {
        max(8, min(64, ProcessInfo.processInfo.activeProcessorCount * 4))
    }
}

public struct ScanProgress: Sendable {
    public var files: Int64 = 0
    public var directories: Int64 = 0
    public var logicalBytes: Int64 = 0
    public var allocatedBytes: Int64 = 0
    public var errors: Int64 = 0
    public var currentPath: String = ""
    /// Estimated completion in 0…1. Each directory carries an equal share of its parent's
    /// share (like GrandPerspective's estimate), so it tracks directory structure, not bytes.
    public var fraction: Double = 0
}

public struct ScanStatistics: Sendable, Codable {
    public var files: Int64 = 0
    public var directories: Int64 = 0
    public var symlinks: Int64 = 0
    public var others: Int64 = 0
    public var logicalBytes: Int64 = 0
    public var allocatedBytes: Int64 = 0
    /// Directories that could not be opened at all.
    public var inaccessibleDirectories: Int64 = 0
    /// Subset of `inaccessibleDirectories` refused with EPERM/EACCES — typically TCC-protected
    /// folders when the app lacks Full Disk Access.
    public var permissionDenied: Int64 = 0
    /// Entries whose attributes could not be read, or listings that failed part-way.
    public var readErrors: Int64 = 0
    /// Regular files with the UF_COMPRESSED flag (transparent decmpfs compression).
    public var compressedFiles: Int64 = 0
}

public struct ScanResult: Sendable {
    public var tree: FileTree
    /// When the scan finished; the reference for age-based coloring.
    public var date: Date
    public var duration: TimeInterval
    public var statistics: ScanStatistics
    public var cancelled: Bool
    /// Capacity and free space of the volume holding the root, in bytes (0 if unknown).
    public var volumeSize: Int64
    public var freeSpace: Int64
}

public enum ScanError: Error, LocalizedError {
    case cannotOpen(String, errno: Int32)
    case notADirectory(String)
    case alreadyStarted

    public var errorDescription: String? {
        switch self {
        case let .cannotOpen(path, code): "Cannot open \(path): \(String(cString: strerror(code)))"
        case let .notADirectory(path): "\(path) is not a directory"
        case .alreadyStarted: "This scanner has already been run"
        }
    }
}

/// Parallel directory scanner built on `getattrlistbulk(2)`.
///
/// One syscall returns a batch of entries with name, type, sizes, inode and link count, so no
/// per-file `stat` is ever issued. Directories are independent units of work distributed over a
/// pool of threads, and results are committed to a shared flat arena one directory at a time.
public final class DiskScanner: Sendable {
    public let rootPath: String
    public let options: ScanOptions

    let builder: TreeBuilder
    let queue = WorkQueue()

    private let started = Atomic<Bool>(false)
    private let cancelled = Atomic<Bool>(false)
    private let currentPath = Mutex<[UInt8]>([])
    private let hardLinks = Mutex<[HardLinkRef]>([])
    private let completedWeight = Mutex<Double>(0)

    let filesCount = Atomic<Int64>(0)
    let directoriesCount = Atomic<Int64>(0)
    let symlinksCount = Atomic<Int64>(0)
    let othersCount = Atomic<Int64>(0)
    let logicalBytes = Atomic<Int64>(0)
    let allocatedBytes = Atomic<Int64>(0)
    let inaccessibleDirectories = Atomic<Int64>(0)
    let permissionDenied = Atomic<Int64>(0)
    let readErrors = Atomic<Int64>(0)
    let compressedFiles = Atomic<Int64>(0)

    public init(rootPath: String, options: ScanOptions = ScanOptions()) {
        var path = (rootPath as NSString).expandingTildeInPath
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        self.rootPath = path
        self.options = options
        self.builder = TreeBuilder(rootPath: path)
    }

    public var isCancelled: Bool { cancelled.load(ordering: .relaxed) }

    /// Stops the scan as soon as each worker finishes its current directory. `run()` then returns
    /// the partial tree with `cancelled == true`.
    public func cancel() {
        cancelled.store(true, ordering: .relaxed)
        queue.close()
    }

    public func progress() -> ScanProgress {
        ScanProgress(
            files: filesCount.load(ordering: .relaxed),
            directories: directoriesCount.load(ordering: .relaxed),
            logicalBytes: logicalBytes.load(ordering: .relaxed),
            allocatedBytes: allocatedBytes.load(ordering: .relaxed),
            errors: inaccessibleDirectories.load(ordering: .relaxed) + readErrors.load(ordering: .relaxed),
            currentPath: currentPath.withLock { String(decoding: $0.dropLast(), as: UTF8.self) },
            fraction: min(1, completedWeight.withLock { $0 })
        )
    }

    /// Runs the scan to completion on the calling thread.
    public func run() throws -> ScanResult {
        guard !started.exchange(true, ordering: .acquiringAndReleasing) else { throw ScanError.alreadyStarted }

        var info = stat()
        guard stat(rootPath, &info) == 0 else { throw ScanError.cannotOpen(rootPath, errno: errno) }
        guard (info.st_mode & S_IFMT) == S_IFDIR else { throw ScanError.notADirectory(rootPath) }

        let clock = ContinuousClock()
        let start = clock.now

        raiseFileDescriptorLimit()
        queue.push(WorkItem(node: FileTree.rootIndex, path: Array(rootPath.utf8) + [0], nameStart: 0, parent: nil, weight: 1))

        let group = DispatchGroup()
        for index in 0 ..< max(1, options.threadCount) {
            group.enter()
            let thread = Thread { [self] in
                ScanWorker(scanner: self).run()
                group.leave()
            }
            thread.name = "layland.scan.\(index)"
            thread.qualityOfService = .userInitiated
            thread.stackSize = 1 << 20
            thread.start()
        }
        group.wait()

        let tree = builder.finish(rootPath: rootPath, hardLinks: hardLinks.withLock { $0 })
        let elapsed = clock.now - start
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18

        var volumeSize: Int64 = 0, freeSpace: Int64 = 0
        if let values = try? URL(fileURLWithPath: rootPath).resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey]) {
            volumeSize = Int64(values.volumeTotalCapacity ?? 0)
            freeSpace = Int64(values.volumeAvailableCapacity ?? 0)
        }
        return ScanResult(
            tree: tree, date: Date(), duration: seconds, statistics: statistics(), cancelled: isCancelled,
            volumeSize: volumeSize, freeSpace: freeSpace
        )
    }

    /// Runs the scan on a dedicated thread so callers in Swift concurrency don't block the
    /// cooperative pool.
    public func runAsync() async throws -> ScanResult {
        try await withCheckedThrowingContinuation { continuation in
            let thread = Thread { [self] in
                continuation.resume(with: Result { try run() })
            }
            thread.name = "layland.scan.coordinator"
            thread.qualityOfService = .userInitiated
            thread.start()
        }
    }

    private func statistics() -> ScanStatistics {
        ScanStatistics(
            files: filesCount.load(ordering: .relaxed),
            directories: directoriesCount.load(ordering: .relaxed),
            symlinks: symlinksCount.load(ordering: .relaxed),
            others: othersCount.load(ordering: .relaxed),
            logicalBytes: logicalBytes.load(ordering: .relaxed),
            allocatedBytes: allocatedBytes.load(ordering: .relaxed),
            inaccessibleDirectories: inaccessibleDirectories.load(ordering: .relaxed),
            permissionDenied: permissionDenied.load(ordering: .relaxed),
            readErrors: readErrors.load(ordering: .relaxed),
            compressedFiles: compressedFiles.load(ordering: .relaxed)
        )
    }

    /// Pending work items keep their parent directory open; make sure a wide tree doesn't run
    /// into the default 256-descriptor limit. Workers fall back to path-based `open` on EMFILE.
    private func raiseFileDescriptorLimit() {
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { return }
        for candidate: rlim_t in [65536, 10240] where candidate > limit.rlim_cur {
            var raised = limit
            raised.rlim_cur = min(candidate, limit.rlim_max)
            if setrlimit(RLIMIT_NOFILE, &raised) == 0 { return }
        }
    }

    // MARK: - Worker callbacks

    func noteCurrentPath(_ path: [UInt8]) {
        currentPath.withLock { $0 = path }
    }

    func completeWeight(_ weight: Double) {
        completedWeight.withLock { $0 += weight }
    }

    func mergeHardLinks(_ links: [HardLinkRef]) {
        guard !links.isEmpty else { return }
        hardLinks.withLock { $0.append(contentsOf: links) }
    }
}

// MARK: - Attribute constants (sys/attr.h, sys/stat.h, sys/vnode.h)

private enum Attr {
    static let bitmapCount: UInt16 = 5

    static let cmnReturnedAttrs: UInt32 = 0x8000_0000
    static let cmnError: UInt32 = 0x2000_0000
    static let cmnName: UInt32 = 0x0000_0001
    static let cmnDevID: UInt32 = 0x0000_0002
    static let cmnObjType: UInt32 = 0x0000_0008
    static let cmnModTime: UInt32 = 0x0000_0400
    static let cmnFlags: UInt32 = 0x0004_0000
    static let cmnFileID: UInt32 = 0x0200_0000

    static let dirMountStatus: UInt32 = 0x0000_0004

    static let fileLinkCount: UInt32 = 0x0000_0001
    static let fileAllocSize: UInt32 = 0x0000_0004
    static let fileDataLength: UInt32 = 0x0000_0200

    static let mountStatusMountPoint: UInt32 = 0x1
    static let flagFirmlink: UInt32 = 0x0080_0000
    static let flagCompressed: UInt32 = 0x0000_0020 // UF_COMPRESSED

    // enum vtype
    static let typeRegular: UInt32 = 1
    static let typeDirectory: UInt32 = 2
    static let typeSymlink: UInt32 = 5
}

/// One directory entry, decoded from either `getattrlistbulk` or the `readdir` fallback.
private struct RawEntry {
    var name: UnsafePointer<UInt8>
    var nameLength: Int
    var error: UInt32 = 0
    var device: Int32 = 0
    var objectType: UInt32 = 0
    var modTime: Int64 = 0
    var flags: UInt32 = 0
    var fileID: UInt64 = 0
    var mountStatus: UInt32 = 0
    var linkCount: UInt32 = 0
    var allocatedSize: Int64 = 0
    var dataLength: Int64 = 0
}

/// Per-thread scanning state. Owns a reusable syscall buffer and the staging arrays for the
/// directory currently being listed.
private final class ScanWorker {
    private unowned let scanner: DiskScanner
    private let bufferSize = 256 * 1024
    private let buffer: UnsafeMutableRawPointer
    private var attributes: attrlist

    private var childNodes: [FileNode] = []
    private var childNames: [UInt8] = []
    private var subdirectories: [(local: Int32, nameStart: Int, nameLength: Int)] = []
    private var pendingItems: [WorkItem] = []
    private var hardLinks: [HardLinkRef] = []

    private var files: Int64 = 0
    private var directories: Int64 = 0
    private var symlinks: Int64 = 0
    private var others: Int64 = 0
    private var logicalBytes: Int64 = 0
    private var allocatedBytes: Int64 = 0
    private var readErrors: Int64 = 0
    private var compressed: Int64 = 0

    init(scanner: DiskScanner) {
        self.scanner = scanner
        buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 8)
        let override = scanner.options.attributeOverride
        attributes = attrlist(
            bitmapcount: Attr.bitmapCount,
            reserved: 0,
            commonattr: override?.common ?? (Attr.cmnReturnedAttrs | Attr.cmnError | Attr.cmnName | Attr.cmnDevID
                | Attr.cmnObjType | Attr.cmnModTime | Attr.cmnFlags | Attr.cmnFileID),
            volattr: 0,
            dirattr: override?.dir ?? Attr.dirMountStatus,
            fileattr: override?.file ?? (Attr.fileLinkCount | Attr.fileAllocSize | Attr.fileDataLength),
            forkattr: 0
        )
        childNodes.reserveCapacity(1024)
        childNames.reserveCapacity(32 * 1024)
    }

    deinit {
        buffer.deallocate()
    }

    func run() {
        let queue = scanner.queue
        while let item = queue.pop() {
            // Keep one child directory for ourselves instead of round-tripping it through the
            // queue; siblings go to the pool.
            var next: WorkItem? = item
            while let current = next {
                next = process(current)
            }
            queue.finish()
        }
        scanner.mergeHardLinks(hardLinks)
    }

    /// Lists one directory, commits its children, and returns a child directory to continue with.
    private func process(_ item: WorkItem) -> WorkItem? {
        guard !scanner.isCancelled else { return nil }
        scanner.noteCurrentPath(item.path)

        let openFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        var fd: Int32 = -1
        if let parent = item.parent {
            fd = item.path.withUnsafeBufferPointer { bytes in
                bytes.withMemoryRebound(to: CChar.self) { chars in
                    openat(parent.fd, chars.baseAddress! + item.nameStart, openFlags)
                }
            }
        }
        if fd < 0, item.parent == nil || errno == EMFILE || errno == ENFILE {
            fd = item.path.withUnsafeBufferPointer { bytes in
                bytes.withMemoryRebound(to: CChar.self) { chars in
                    open(chars.baseAddress!, openFlags)
                }
            }
        }
        guard fd >= 0 else {
            let code = errno
            scanner.builder.insertFlags(.inaccessible, at: item.node)
            scanner.inaccessibleDirectories.wrappingAdd(1, ordering: .relaxed)
            if code == EPERM || code == EACCES {
                scanner.permissionDenied.wrappingAdd(1, ordering: .relaxed)
            }
            scanner.completeWeight(item.weight)
            return nil
        }
        // Stays open while child directories are pending (see DirectoryHandle).
        let handle = DirectoryHandle(fd: fd)

        childNodes.removeAll(keepingCapacity: true)
        childNames.removeAll(keepingCapacity: true)
        subdirectories.removeAll(keepingCapacity: true)
        let hardLinkStart = hardLinks.count
        files = 0; directories = 0; symlinks = 0; others = 0
        logicalBytes = 0; allocatedBytes = 0; readErrors = 0; compressed = 0

        let status = listWithBulk(fd: fd)
        if status == ENOTSUP || status == EINVAL {
            // Filesystem without getattrlistbulk support; fall back to readdir + fstatat.
            childNodes.removeAll(keepingCapacity: true)
            childNames.removeAll(keepingCapacity: true)
            subdirectories.removeAll(keepingCapacity: true)
            hardLinks.removeSubrange(hardLinkStart...)
            files = 0; directories = 0; symlinks = 0; others = 0
            logicalBytes = 0; allocatedBytes = 0; readErrors = 0; compressed = 0
            if !listWithReaddir(fd: fd) {
                readErrors += 1
                scanner.builder.insertFlags(.readError, at: item.node)
            }
        } else if status != 0 {
            readErrors += 1
            scanner.builder.insertFlags(.readError, at: item.node)
        }

        let base = scanner.builder.appendChildren(of: item.node, &childNodes, names: childNames)
        for index in hardLinkStart ..< hardLinks.count {
            hardLinks[index].node += base
        }

        scanner.filesCount.wrappingAdd(files, ordering: .relaxed)
        scanner.directoriesCount.wrappingAdd(directories, ordering: .relaxed)
        scanner.symlinksCount.wrappingAdd(symlinks, ordering: .relaxed)
        scanner.othersCount.wrappingAdd(others, ordering: .relaxed)
        scanner.logicalBytes.wrappingAdd(logicalBytes, ordering: .relaxed)
        scanner.allocatedBytes.wrappingAdd(allocatedBytes, ordering: .relaxed)
        if readErrors > 0 {
            scanner.readErrors.wrappingAdd(readErrors, ordering: .relaxed)
        }
        if compressed > 0 {
            scanner.compressedFiles.wrappingAdd(compressed, ordering: .relaxed)
        }

        pendingItems.removeAll(keepingCapacity: true)
        var continueWith: WorkItem?
        let slash = UInt8(ascii: "/")
        if subdirectories.isEmpty {
            scanner.completeWeight(item.weight)
        }
        let childWeight = item.weight / Double(max(1, subdirectories.count))
        for (position, sub) in subdirectories.enumerated() {
            var path = item.path
            path.removeLast() // NUL
            if path.last != slash { path.append(slash) }
            let nameStart = path.count
            path.append(contentsOf: childNames[sub.nameStart ..< sub.nameStart + sub.nameLength])
            path.append(0)
            let work = WorkItem(node: base + sub.local, path: path, nameStart: nameStart, parent: handle, weight: childWeight)
            if position == subdirectories.count - 1 {
                continueWith = work
            } else {
                pendingItems.append(work)
            }
        }
        scanner.queue.push(contentsOf: pendingItems)
        return continueWith
    }

    // MARK: getattrlistbulk

    /// Returns 0 on success or the errno of the failed call.
    private func listWithBulk(fd: Int32) -> Int32 {
        while true {
            let count = getattrlistbulk(fd, &attributes, buffer, bufferSize, 0)
            if count < 0 {
                let code = errno
                if code == EINTR { continue }
                return code
            }
            if count == 0 { return 0 }

            var cursor = UnsafeRawPointer(buffer)
            for _ in 0 ..< Int(count) {
                let length = Int(cursor.loadUnaligned(as: UInt32.self))
                if let entry = Self.decode(cursor) {
                    consume(entry)
                } else {
                    readErrors += 1
                }
                cursor += length
            }
        }
    }

    /// Decodes one packed attribute group. Fields are 4-byte aligned and appear in bit order
    /// within each attribute group, present only when the returned-attributes bitmap says so.
    @inline(__always)
    private static func decode(_ base: UnsafeRawPointer) -> RawEntry? {
        let common = base.loadUnaligned(fromByteOffset: 4, as: UInt32.self)
        let dir = base.loadUnaligned(fromByteOffset: 12, as: UInt32.self)
        let file = base.loadUnaligned(fromByteOffset: 16, as: UInt32.self)
        var offset = 4 + 5 * 4 // length + attribute_set_t

        var error: UInt32 = 0
        if common & Attr.cmnError != 0 {
            error = base.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
            offset += 4
        }
        guard common & Attr.cmnName != 0 else { return nil }
        let reference = base + offset
        let dataOffset = Int(reference.loadUnaligned(as: Int32.self))
        let dataLength = Int(reference.loadUnaligned(fromByteOffset: 4, as: UInt32.self))
        let name = (reference + dataOffset).assumingMemoryBound(to: UInt8.self)
        offset += 8

        var entry = RawEntry(name: name, nameLength: strnlen(name, dataLength), error: error)
        if common & Attr.cmnDevID != 0 {
            entry.device = base.loadUnaligned(fromByteOffset: offset, as: Int32.self)
            offset += 4
        }
        if common & Attr.cmnObjType != 0 {
            entry.objectType = base.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
            offset += 4
        }
        if common & Attr.cmnModTime != 0 {
            entry.modTime = base.loadUnaligned(fromByteOffset: offset, as: Int64.self)
            offset += 16 // struct timespec
        }
        if common & Attr.cmnFlags != 0 {
            entry.flags = base.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
            offset += 4
        }
        if common & Attr.cmnFileID != 0 {
            entry.fileID = base.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
            offset += 8
        }
        if dir & Attr.dirMountStatus != 0 {
            entry.mountStatus = base.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
            offset += 4
        }
        if file & Attr.fileLinkCount != 0 {
            entry.linkCount = base.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
            offset += 4
        }
        if file & Attr.fileAllocSize != 0 {
            entry.allocatedSize = base.loadUnaligned(fromByteOffset: offset, as: Int64.self)
            offset += 8
        }
        if file & Attr.fileDataLength != 0 {
            entry.dataLength = base.loadUnaligned(fromByteOffset: offset, as: Int64.self)
            offset += 8
        }
        return entry
    }

    // MARK: readdir fallback

    private func listWithReaddir(fd: Int32) -> Bool {
        var parentInfo = stat()
        let parentDevice: Int32? = fstat(fd, &parentInfo) == 0 ? parentInfo.st_dev : nil

        let duplicate = dup(fd)
        guard duplicate >= 0 else { return false }
        guard let directory = fdopendir(duplicate) else {
            close(duplicate)
            return false
        }
        defer { closedir(directory) }

        let nameFieldOffset = MemoryLayout<dirent>.offset(of: \.d_name)!
        var info = stat()
        while let record = readdir(directory) {
            let name = (UnsafeRawPointer(record) + nameFieldOffset).assumingMemoryBound(to: UInt8.self)
            let nameLength = Int(record.pointee.d_namlen)
            if nameLength == 1, name[0] == UInt8(ascii: ".") { continue }
            if nameLength == 2, name[0] == UInt8(ascii: "."), name[1] == UInt8(ascii: ".") { continue }

            var entry = RawEntry(name: name, nameLength: nameLength)
            let result = name.withMemoryRebound(to: CChar.self, capacity: nameLength + 1) {
                fstatat(fd, $0, &info, AT_SYMLINK_NOFOLLOW)
            }
            if result != 0 {
                entry.error = UInt32(errno)
            } else {
                entry.device = info.st_dev
                switch info.st_mode & S_IFMT {
                case S_IFDIR: entry.objectType = Attr.typeDirectory
                case S_IFREG: entry.objectType = Attr.typeRegular
                case S_IFLNK: entry.objectType = Attr.typeSymlink
                default: entry.objectType = 0
                }
                entry.modTime = Int64(info.st_mtimespec.tv_sec)
                entry.flags = info.st_flags
                entry.fileID = info.st_ino
                entry.linkCount = UInt32(info.st_nlink)
                entry.allocatedSize = Int64(info.st_blocks) * 512
                entry.dataLength = Int64(info.st_size)
                if let parentDevice, info.st_dev != parentDevice, entry.objectType == Attr.typeDirectory {
                    entry.mountStatus = Attr.mountStatusMountPoint
                }
            }
            consume(entry)
        }
        return true
    }

    // MARK: Entry → node

    @inline(__always)
    private func consume(_ entry: RawEntry) {
        let nameStart = childNames.count
        childNames.append(contentsOf: UnsafeBufferPointer(start: entry.name, count: entry.nameLength))

        var node = FileNode(
            parent: -1,
            nameOffset: UInt32(nameStart),
            nameLength: UInt16(clamping: entry.nameLength),
            kind: .other,
            modTime: UInt32(clamping: entry.modTime)
        )
        if entry.error != 0 {
            node.flags.insert(.readError)
            readErrors += 1
        }

        switch entry.objectType {
        case Attr.typeDirectory:
            node.kind = .directory
            directories += 1
            var enter = entry.error == 0
            if entry.flags & Attr.flagFirmlink != 0 {
                node.flags.insert(.firmlink)
                enter = enter && scanner.options.followFirmlinks
            } else if entry.mountStatus & Attr.mountStatusMountPoint != 0 {
                node.flags.insert(.mountPoint)
                enter = enter && scanner.options.crossMountPoints
            }
            if enter {
                subdirectories.append((Int32(childNodes.count), nameStart, entry.nameLength))
            }
        case Attr.typeRegular:
            node.kind = .file
            node.logicalSize = entry.dataLength
            node.allocatedSize = entry.allocatedSize
            node.category = FileCategory.slot(forName: UnsafeBufferPointer(start: entry.name, count: entry.nameLength))
            files += 1
            if entry.flags & Attr.flagCompressed != 0 { compressed += 1 }
            if entry.linkCount > 1 {
                hardLinks.append(HardLinkRef(device: entry.device, inode: entry.fileID, node: Int32(childNodes.count)))
            }
        case Attr.typeSymlink:
            node.kind = .symlink
            node.logicalSize = entry.dataLength
            node.allocatedSize = entry.allocatedSize
            symlinks += 1
        default:
            node.kind = .other
            node.logicalSize = entry.dataLength
            node.allocatedSize = entry.allocatedSize
            others += 1
        }
        logicalBytes += node.logicalSize
        allocatedBytes += node.allocatedSize
        childNodes.append(node)
    }
}
