import Foundation

// layland-bench: scans a directory with the Layland scanner and reports timing.
//
//   layland-bench [--threads N] [--top K] [--allocated] [--cross-mounts] [--quiet] <path>

var path: String?
var options = ScanOptions()
var top = 10
var sizeMode = SizeMode.logical
var quiet = false
var savePath: String?

var arguments = CommandLine.arguments.dropFirst().makeIterator()
while let argument = arguments.next() {
    switch argument {
    case "--threads":
        guard let value = arguments.next(), let count = Int(value) else { fail("--threads needs a number") }
        options.threadCount = count
    case "--top":
        guard let value = arguments.next(), let count = Int(value) else { fail("--top needs a number") }
        top = count
    case "--allocated":
        sizeMode = .allocated
    case "--cross-mounts":
        options.crossMountPoints = true
    case "--quiet":
        quiet = true
    case "--save":
        guard let value = arguments.next() else { fail("--save needs a file path") }
        savePath = value
    case "--attrs":
        guard let value = arguments.next() else { fail("--attrs needs common,dir,file in hex") }
        let parts = value.split(separator: ",").map { UInt32($0, radix: 16) }
        guard parts.count == 3, let common = parts[0], let dir = parts[1], let file = parts[2] else { fail("--attrs needs common,dir,file in hex") }
        options.attributeOverride = (common, dir, file)
    case "-h", "--help":
        print("usage: layland-bench [--threads N] [--top K] [--allocated] [--cross-mounts] [--quiet] [--save file.layland] <path>")
        exit(0)
    default:
        path = argument
    }
}

guard let path else { fail("missing path") }

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(2)
}

nonisolated func bytes(_ value: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    return formatter.string(fromByteCount: value)
}

nonisolated func count(_ value: Int64) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
}

let scanner = DiskScanner(rootPath: path, options: options)
print("scanning \(scanner.rootPath) with \(options.threadCount) threads…")

let showProgress = !quiet
let progressThread = Thread {
    while true {
        Thread.sleep(forTimeInterval: 0.5)
        let progress = scanner.progress()
        if showProgress {
            let line = "  \(count(progress.files)) files, \(count(progress.directories)) dirs, \(bytes(progress.logicalBytes))  \(progress.currentPath.suffix(60))"
            FileHandle.standardError.write(Data("\r\u{1B}[K\(line)".utf8))
        }
    }
}
progressThread.start()

do {
    let result = try scanner.run()
    let stats = result.statistics
    FileHandle.standardError.write(Data("\r\u{1B}[K".utf8))
    let itemsPerSecond = Double(stats.files + stats.directories + stats.symlinks + stats.others) / max(result.duration, 0.001)
    print(String(format: "done in %.3f s  (%@ entries/s)", result.duration, count(Int64(itemsPerSecond))))
    print("  files:        \(count(stats.files))")
    print("  directories:  \(count(stats.directories))")
    print("  symlinks:     \(count(stats.symlinks))   other: \(count(stats.others))   compressed files: \(count(stats.compressedFiles))")
    print("  logical:      \(bytes(stats.logicalBytes))  (\(count(stats.logicalBytes)) bytes)")
    print("  allocated:    \(bytes(stats.allocatedBytes))  (\(count(stats.allocatedBytes)) bytes)")
    print("  unreadable dirs: \(count(stats.inaccessibleDirectories)) (permission: \(count(stats.permissionDenied)))  read errors: \(count(stats.readErrors))")
    let treeRoot = result.tree[FileTree.rootIndex]
    print("  tree total (hard links deduplicated): logical \(bytes(treeRoot.logicalSize)) (\(count(treeRoot.logicalSize)) bytes), allocated \(bytes(treeRoot.allocatedSize)) (\(count(treeRoot.allocatedSize)) bytes)")
    print("  nodes: \(count(Int64(result.tree.count)))  names: \(bytes(Int64(result.tree.names.count)))  node memory: \(bytes(Int64(result.tree.count * MemoryLayout<FileNode>.stride)))")

    if let savePath {
        let url = URL(fileURLWithPath: (savePath as NSString).expandingTildeInPath)
        let clock = ContinuousClock()
        let writeStart = clock.now
        try ScanArchive.write(result, to: url)
        let written = clock.now
        let loaded = try ScanArchive.read(from: url)
        let read = clock.now
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        func ms(_ d: Duration) -> String { String(format: "%.0f ms", Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15) }
        print("\nsaved \(bytes(size)) to \(url.lastPathComponent): write \(ms(written - writeStart)), read \(ms(read - written)), \(count(Int64(loaded.tree.count))) nodes")
    }

    if top > 0 {
        let tree = result.tree
        let root = tree[FileTree.rootIndex]
        print("\nlargest entries in \(tree.rootPath) (\(sizeMode.rawValue), total \(bytes(root.size(sizeMode)))):")
        for child in tree.sortedChildren(of: FileTree.rootIndex, by: sizeMode).prefix(top) {
            let node = tree[child]
            let share = root.size(sizeMode) > 0 ? Double(node.size(sizeMode)) * 100 / Double(root.size(sizeMode)) : 0
            let suffix = node.isDirectory ? "/" : ""
            var notes: [String] = []
            if node.flags.contains(.inaccessible) { notes.append("unreadable") }
            if node.flags.contains(.mountPoint) { notes.append("mount point") }
            if node.flags.contains(.firmlink) { notes.append("firmlink") }
            print(String(format: "  %10@  %5.1f%%  %@%@%@", bytes(node.size(sizeMode)), share, tree.name(child), suffix,
                         notes.isEmpty ? "" : "  [\(notes.joined(separator: ", "))]"))
        }
    }
} catch {
    fail("\(error)")
}
