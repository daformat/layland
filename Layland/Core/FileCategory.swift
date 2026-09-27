import Foundation

/// Coarse file classification by extension, computed once per file during the scan and stored
/// in `FileNode.category`. Well-known families get fixed slots; any other extension is hashed
/// into the remaining slots so files of one kind still share a color.
public enum FileCategory {
    public static let slotCount = 20
    public static let noExtension: UInt8 = 0
    static let hashedSlots: Range<UInt8> = 11 ..< 20

    /// FNV-1a of the lower-cased extension → slot.
    private static let known: [UInt32: UInt8] = {
        let groups: [(UInt8, [String])] = [
            (1, ["jpg", "jpeg", "png", "gif", "heic", "heif", "tif", "tiff", "bmp", "webp", "svg", "psd", "raw", "cr2", "cr3", "nef", "arw", "dng", "ai", "sketch"]),
            (2, ["mov", "mp4", "m4v", "mkv", "avi", "webm", "wmv", "flv", "mts", "m2ts", "mpg", "mpeg"]),
            (3, ["mp3", "m4a", "wav", "flac", "aac", "aif", "aiff", "ogg", "opus", "wma", "alac", "caf"]),
            (4, ["zip", "tar", "gz", "tgz", "bz2", "xz", "zst", "7z", "rar", "dmg", "iso", "pkg", "xip", "jar", "whl", "crate"]),
            (5, ["pdf", "doc", "docx", "pages", "xls", "xlsx", "numbers", "ppt", "pptx", "key", "txt", "md", "rtf", "epub", "odt", "tex"]),
            (6, ["swift", "c", "cc", "cpp", "cxx", "h", "hpp", "m", "mm", "js", "jsx", "ts", "tsx", "mjs", "cjs", "py", "rb", "go", "rs", "java", "kt", "kts", "scala", "php", "cs", "html", "css", "scss", "vue", "svelte", "sh", "zsh", "lua", "pl", "r", "dart", "ex", "exs", "erl", "hs", "ml", "clj", "sql"]),
            (7, ["dylib", "so", "a", "o", "exe", "dll", "bin", "wasm", "bc", "framework", "bundle", "elf", "node"]),
            (8, ["json", "xml", "yml", "yaml", "toml", "plist", "csv", "tsv", "sqlite", "db", "sqlite3", "realm", "parquet", "arrow", "log", "ndjson", "proto"]),
            (9, ["ttf", "otf", "woff", "woff2", "ttc"]),
            (10, ["nib", "storyboardc", "car", "strings", "loctable", "xcassets", "xcodeproj", "xcworkspace", "pbxproj"]),
        ]
        var map: [UInt32: UInt8] = [:]
        for (slot, extensions) in groups {
            for ext in extensions {
                map[hash(Array(ext.utf8)[...])] = slot
            }
        }
        return map
    }()

    public static let titles: [String] = [
        "No extension", "Images", "Video", "Audio", "Archives & disk images", "Documents", "Source code",
        "Binaries & libraries", "Data", "Fonts", "App resources",
    ]

    /// Slot for a file name. Works on raw bytes, no allocation.
    public static func slot(forName name: UnsafeBufferPointer<UInt8>) -> UInt8 {
        guard let hash = extensionHash(forName: name) else { return noExtension }
        if let slot = known[hash] { return slot }
        return hashedSlots.lowerBound + UInt8(hash % UInt32(hashedSlots.count))
    }

    /// Case-insensitive hash of the extension the slot is derived from, or nil when the name
    /// counts as having none (no dot, a leading dot only, or an extension over 12 bytes).
    public static func extensionHash(forName name: UnsafeBufferPointer<UInt8>) -> UInt32? {
        guard let dot = name.lastIndex(of: UInt8(ascii: ".")), dot > 0, dot < name.count - 1, name.count - dot - 1 <= 12 else {
            return nil
        }
        return hash(name[(dot + 1)...])
    }

    public static func slot(forName name: ArraySlice<UInt8>) -> UInt8 {
        name.withUnsafeBufferPointer { slot(forName: $0) }
    }

    /// FNV-1a over ASCII-lower-cased bytes.
    private static func hash<C: Collection>(_ bytes: C) -> UInt32 where C.Element == UInt8 {
        var hash: UInt32 = 2_166_136_261
        for byte in bytes {
            hash ^= UInt32(byte >= 65 && byte <= 90 ? byte + 32 : byte)
            hash = hash &* 16_777_619
        }
        return hash
    }
}
