import Foundation

/// What a cell's colour encodes.
enum ColorMode: String, CaseIterable, Identifiable, Sendable {
    case fileType
    case modified

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fileType: "File Type"
        case .modified: "Last Modified"
        }
    }
}

/// Age buckets for `ColorMode.modified`, most recent first.
enum ModifiedBucket {
    struct Definition: Sendable {
        var maxAge: TimeInterval
        var title: String
    }

    private static let day: TimeInterval = 86_400

    static let definitions: [Definition] = [
        Definition(maxAge: day, title: "Today"),
        Definition(maxAge: 7 * day, title: "This week"),
        Definition(maxAge: 30 * day, title: "This month"),
        Definition(maxAge: 91 * day, title: "3 months"),
        Definition(maxAge: 182 * day, title: "6 months"),
        Definition(maxAge: 365 * day, title: "1 year"),
        Definition(maxAge: 730 * day, title: "2 years"),
        Definition(maxAge: 1826 * day, title: "5 years"),
        Definition(maxAge: .infinity, title: "Older"),
    ]

    static var count: Int { definitions.count }

    /// Bucket index for a modification time (seconds since 1970) relative to `reference`.
    static func index(modTime: UInt32, reference: TimeInterval) -> Int {
        let age = reference - TimeInterval(modTime)
        for (index, definition) in definitions.enumerated() where age < definition.maxAge {
            return index
        }
        return definitions.count - 1
    }
}
