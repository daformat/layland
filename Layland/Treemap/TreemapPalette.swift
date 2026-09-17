import Foundation

/// The built-in colour schemes.
enum PaletteScheme: String, CaseIterable, Identifiable, Sendable {
    case vivid, pastel, nord, retro, jewel

    /// Used when nothing (or a since-removed scheme) is stored.
    static let fallback: PaletteScheme = .jewel

    var id: String { rawValue }

    var title: String {
        switch self {
        case .vivid: "Vivid"
        case .pastel: "Pastel"
        case .nord: "Nord"
        case .retro: "Retro"
        case .jewel: "Jewel"
        }
    }
}

/// A palette the user saved from the editor.
struct UserPalette: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var name: String
    var colors: [UInt32]
}

/// What View ▸ Color Palette points at.
enum PaletteSelection: Hashable, Sendable {
    case builtIn(PaletteScheme)
    case user(UUID)
    /// The live working copy edited in the palette editor.
    case custom

    /// Stable string form for UserDefaults.
    var storageKey: String {
        switch self {
        case let .builtIn(scheme): scheme.rawValue
        case let .user(id): "user:\(id.uuidString)"
        case .custom: "custom"
        }
    }

    init(storageKey: String) {
        if let scheme = PaletteScheme(rawValue: storageKey) {
            self = .builtIn(scheme)
        } else if storageKey.hasPrefix("user:"), let id = UUID(uuidString: String(storageKey.dropFirst(5))) {
            self = .user(id)
        } else if storageKey == "custom" {
            self = .custom
        } else {
            self = .builtIn(.fallback)
        }
    }
}

/// The resolved colours of a palette, independent of light/dark appearance.
struct PaletteSpec: Equatable, Sendable {
    var mode: ColorMode
    /// One 0xRRGGBB value per `FileCategory` slot (used in `.fileType` mode).
    var colors: [UInt32]
}

/// Colours for the treemap as plain RGB triples (0…1), safe to use from any thread.
///
/// Each scheme lists one colour per `FileCategory` slot: the 11 named families first (no
/// extension, images, video, audio, archives, documents, code, binaries, data, fonts, app
/// resources), then 9 colours shared by hashed unknown extensions.
struct TreemapPalette: Sendable {
    static let fileSlotCount = FileCategory.slotCount

    /// Slots above the per-mode range, shared by every mode.
    static let emptyDirectorySlot: Int32 = 61
    static let freeSpaceSlot: Int32 = 62
    static let otherSpaceSlot: Int32 = 63
    static let slotCount = 64

    /// Age colours for `ColorMode.modified`, hot (recent) to cool (old), one per `ModifiedBucket`.
    static let modifiedColors: [UInt32] = [
        0xFF4D4D, 0xFF8A3D, 0xFFC13D, 0xE4E04A, 0x9ED65A, 0x4FC7A0, 0x3FA3D6, 0x4D6FD6, 0x6C5CB8,
    ]

    /// Indexed by colour slot (see the slot constants above).
    let colors: [SIMD3<Float>]
    let background: SIMD3<Float>

    /// Preset colours per scheme, one per slot.
    static let presetColors: [PaletteScheme: [UInt32]] = [
        // HSB-generated: saturation 0.62, brightness 1.0.
        .vivid: [
            0x94BFFF, 0xFF61AD, 0xCC61FF, 0x8161FF, 0xFFAD61, 0xFFE661, 0x61FFE3, 0x618DFF, 0x64FF61, 0xFF7D61, 0x61E3FF,
            0xDFFF61, 0xB0FF61, 0x81FF61, 0x61FF8D, 0x61FFB3, 0x6167FF, 0xFF61EF, 0xFF61D3, 0xFF617D,
        ],
        // Tailwind-style 300s: light, soft, but every family a different hue.
        .pastel: [
            0xCBD5E1, 0xF9A8D4, 0xD8B4FE, 0xC4B5FD, 0xFDBA74, 0xFCD34D, 0x5EEAD4, 0x7DD3FC, 0xBEF264, 0xFCA5A5, 0x67E8F9,
            0xFDA4AF, 0xFDE047, 0x86EFAC, 0x6EE7B7, 0xA5B4FC, 0xF0ABFC, 0x93C5FD, 0xD6D3D1, 0xFDE68A,
        ],
        // Nord: frost blues and aurora accents, muted but distinct.
        .nord: [
            0xD8DEE9, 0xB48EAD, 0xBF616A, 0xD08770, 0xEBCB8B, 0xA3BE8C, 0x88C0D0, 0x5E81AC, 0x8FBCBB, 0x81A1C1, 0xB9CFA5,
            0xC9826B, 0xD9B36A, 0x7FA1C8, 0x9FB8A0, 0xC58CA0, 0x6FB3B0, 0xE3A6A0, 0x97B3D4, 0xB5A58F,
        ],
        // Seventies: terracotta, mustard, sage, cream.
        .retro: [
            0xE8DCC4, 0xE07A5F, 0xC1666B, 0xB56576, 0xD9A066, 0xE9C46A, 0x81B29A, 0x6B9080, 0xA4C3B2, 0xF2CC8F, 0x8AA6A3,
            0xCC8B62, 0xD6B45C, 0x7B9E87, 0xA8735D, 0xB8A46A, 0x9BB08A, 0xC29B7A, 0x6E8B7E, 0xDDB892,
        ],
        // Jewel tones: rich, saturated, not neon.
        .jewel: [
            0x9AA5B1, 0xC75B8F, 0x8E5EA2, 0x5B5FC7, 0xE0A030, 0xD9B34A, 0x2B9EB3, 0x3F72AF, 0x2E9E6B, 0xB4473C, 0x4CAF7D,
            0xD64161, 0xE07B39, 0x6A8FD1, 0x3DA58A, 0xA26BC2, 0xD98DB0, 0xC9A227, 0x4C86C6, 0x7A7F8A,
        ],
    ]

    /// Human-readable name per slot, for the palette editor.
    static let slotTitles: [String] = FileCategory.titles + (1 ... FileCategory.hashedSlots.count).map { "Other extensions \($0)" }

    /// Legend entries for a mode: (slot, title). File-type mode folds the hashed slots into one.
    static func legend(for mode: ColorMode) -> [(slot: Int32, title: String)] {
        switch mode {
        case .fileType:
            FileCategory.titles.enumerated().map { (Int32($0.offset), $0.element) }
                + [(Int32(FileCategory.hashedSlots.lowerBound), "Other extensions")]
        case .modified:
            ModifiedBucket.definitions.enumerated().map { (Int32($0.offset), $0.element.title) }
        }
    }

    init(spec: PaletteSpec, dark: Bool) {
        let source: [UInt32]
        switch spec.mode {
        case .fileType: source = spec.colors.count == Self.fileSlotCount ? spec.colors : Self.presetColors[PaletteScheme.fallback]!
        case .modified: source = Self.modifiedColors
        }
        // The renderer keeps flat areas at the palette colour; dim slightly on dark backgrounds.
        let lift: Float = dark ? 0.92 : 1.0
        var colors = [SIMD3<Float>](repeating: SIMD3(repeating: 0.5), count: Self.slotCount)
        for (slot, value) in source.enumerated() {
            let rgb = SIMD3<Float>(Float((value >> 16) & 0xFF), Float((value >> 8) & 0xFF), Float(value & 0xFF)) / 255
            colors[slot] = pointwiseMin(rgb * lift, SIMD3(repeating: 1))
        }
        colors[Int(Self.emptyDirectorySlot)] = SIMD3(repeating: dark ? 0.55 : 0.70)
        // Volume cells are hatched (see CushionRenderer) in tones close to the background, so they
        // read as empty rather than as data.
        colors[Int(Self.freeSpaceSlot)] = dark ? SIMD3(0.150, 0.155, 0.165) : SIMD3(0.885, 0.890, 0.900)
        colors[Int(Self.otherSpaceSlot)] = dark ? SIMD3(0.215, 0.205, 0.195) : SIMD3(0.800, 0.790, 0.775)
        self.colors = colors
        background = SIMD3(repeating: dark ? 0.12 : 0.93)
    }

    func color(_ slot: Int32) -> SIMD3<Float> {
        colors[min(max(Int(slot), 0), colors.count - 1)]
    }

    /// On-screen colour of a flat area of a cell (the renderer keeps it at the palette colour).
    func displayedColor(_ slot: Int32) -> SIMD3<Float> {
        color(slot)
    }

    var isDark: Bool { background.x < 0.5 }
}
