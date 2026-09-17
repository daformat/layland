import Compression
import Foundation

/// Reads and writes scans as `.layland` files: a small JSON manifest followed by the node and
/// name arrays, each LZFSE-compressed. Loading is a decompress plus two memcpys.
public enum ScanArchive {
    public static let fileExtension = "layland"
    public static let typeIdentifier = "com.matjouhet.layland.scan"

    private static let magic: UInt64 = 0x4752_4E44_5343_414E // "GRNDSCAN"
    private static let version: UInt32 = 1

    private struct Manifest: Codable {
        var rootPath: String
        var date: Date
        var duration: TimeInterval
        var statistics: ScanStatistics
        var cancelled: Bool
        var volumeSize: Int64
        var freeSpace: Int64
        var nodeCount: Int
        var nodeStride: Int
        var namesCount: Int
        var compression: String
    }

    public enum ArchiveError: Error, LocalizedError {
        case notAnArchive
        case unsupportedVersion(UInt32)
        case corrupt
        case unsupportedCompression(String)

        public var errorDescription: String? {
            switch self {
            case .notAnArchive: "This is not a Layland scan file."
            case let .unsupportedVersion(version): "This scan was saved by a newer Layland (format \(version))."
            case .corrupt: "The scan file is damaged."
            case let .unsupportedCompression(name): "This scan uses unsupported compression (\(name))."
            }
        }
    }

    public static func write(_ result: ScanResult, to url: URL) throws {
        let tree = result.tree
        let manifest = Manifest(
            rootPath: tree.rootPath, date: result.date, duration: result.duration, statistics: result.statistics,
            cancelled: result.cancelled, volumeSize: result.volumeSize, freeSpace: result.freeSpace,
            nodeCount: tree.count, nodeStride: MemoryLayout<FileNode>.stride, namesCount: tree.names.count,
            compression: compressionName
        )
        let manifestData = try JSONEncoder().encode(manifest)
        let nodesData = tree.nodes.withUnsafeBufferPointer { compress(UnsafeRawBufferPointer($0)) }
        let namesData = tree.names.withUnsafeBufferPointer { compress(UnsafeRawBufferPointer($0)) }

        var data = Data()
        data.reserveCapacity(24 + manifestData.count + nodesData.count + namesData.count)
        append(magic, to: &data)
        append(version, to: &data)
        append(UInt32(manifestData.count), to: &data)
        data.append(manifestData)
        append(UInt64(nodesData.count), to: &data)
        data.append(nodesData)
        append(UInt64(namesData.count), to: &data)
        data.append(namesData)
        try data.write(to: url, options: .atomic)
    }

    public static func read(from url: URL) throws -> ScanResult {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        var cursor = 0
        guard data.count >= 16, load(UInt64.self, from: data, at: &cursor) == magic else { throw ArchiveError.notAnArchive }
        let fileVersion = load(UInt32.self, from: data, at: &cursor)
        guard fileVersion == version else { throw ArchiveError.unsupportedVersion(fileVersion) }

        let manifestLength = Int(load(UInt32.self, from: data, at: &cursor))
        let manifest = try JSONDecoder().decode(Manifest.self, from: try slice(data, at: &cursor, length: manifestLength))
        guard manifest.nodeStride == MemoryLayout<FileNode>.stride else { throw ArchiveError.unsupportedVersion(fileVersion) }
        guard manifest.compression == compressionName else { throw ArchiveError.unsupportedCompression(manifest.compression) }

        let nodesLength = Int(load(UInt64.self, from: data, at: &cursor))
        let nodesData = try slice(data, at: &cursor, length: nodesLength)
        let namesLength = Int(load(UInt64.self, from: data, at: &cursor))
        let namesData = try slice(data, at: &cursor, length: namesLength)

        let nodes = try [FileNode](unsafeUninitializedCapacity: manifest.nodeCount) { buffer, count in
            let raw = UnsafeMutableRawBufferPointer(buffer)
            guard decompress(nodesData, into: raw) == raw.count else { throw ArchiveError.corrupt }
            count = manifest.nodeCount
        }
        let names = try [UInt8](unsafeUninitializedCapacity: manifest.namesCount) { buffer, count in
            let raw = UnsafeMutableRawBufferPointer(buffer)
            guard decompress(namesData, into: raw) == raw.count else { throw ArchiveError.corrupt }
            count = manifest.namesCount
        }
        // Sanity-check the structure before trusting indices.
        for node in nodes {
            guard node.parent < Int32(nodes.count), node.firstChild < Int32(nodes.count),
                  node.childCount >= 0, Int(node.nameOffset) + Int(node.nameLength) <= names.count
            else { throw ArchiveError.corrupt }
        }
        let tree = FileTree(rootPath: manifest.rootPath, nodes: nodes, names: names)
        return ScanResult(
            tree: tree, date: manifest.date, duration: manifest.duration, statistics: manifest.statistics,
            cancelled: manifest.cancelled, volumeSize: manifest.volumeSize, freeSpace: manifest.freeSpace
        )
    }

    private static let algorithm = COMPRESSION_LZFSE
    private static let compressionName = "lzfse"

    /// One-shot compression into a fresh buffer.
    private static func compress(_ source: UnsafeRawBufferPointer) -> Data {
        guard let base = source.baseAddress, !source.isEmpty else { return Data() }
        let capacity = source.count + 4096
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        let written = compression_encode_buffer(destination, capacity, base.assumingMemoryBound(to: UInt8.self), source.count, nil, algorithm)
        defer { destination.deallocate() }
        return Data(bytes: destination, count: written)
    }

    /// Decompresses `source` into `destination`, returning the number of bytes produced.
    private static func decompress(_ source: Data, into destination: UnsafeMutableRawBufferPointer) -> Int {
        guard let base = destination.baseAddress, !destination.isEmpty else { return 0 }
        return source.withUnsafeBytes { bytes -> Int in
            guard let start = bytes.baseAddress, !bytes.isEmpty else { return 0 }
            return compression_decode_buffer(base.assumingMemoryBound(to: UInt8.self), destination.count, start.assumingMemoryBound(to: UInt8.self), bytes.count, nil, algorithm)
        }
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }

    private static func load<T: FixedWidthInteger>(_ type: T.Type, from data: Data, at cursor: inout Int) -> T {
        let size = MemoryLayout<T>.size
        guard cursor + size <= data.count else { cursor = data.count; return 0 }
        let value = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: cursor, as: T.self) }
        cursor += size
        return T(littleEndian: value)
    }

    private static func slice(_ data: Data, at cursor: inout Int, length: Int) throws -> Data {
        guard length >= 0, cursor + length <= data.count else { throw ArchiveError.corrupt }
        defer { cursor += length }
        return data.subdata(in: cursor ..< cursor + length)
    }
}
