import Foundation

/// What a cell's color encodes.
enum ColorMode: String, CaseIterable, Identifiable, Sendable {
    case fileType
    case modified

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fileType: L("File Type", comment: "View ▸ Color By: color each file by its kind")
        case .modified: L("Last Modified", comment: "View ▸ Color By: color each file by how long ago it was modified")
        }
    }
}

/// Age buckets for `ColorMode.modified`, most recent first.
enum ModifiedBucket {
    private static let day: TimeInterval = 86_400

    /// Each bucket's upper bound. Read per cell, so it holds numbers only.
    private static let maxAges: [TimeInterval] = [day, 7 * day, 30 * day, 91 * day, 182 * day, 365 * day, 730 * day, 1826 * day, .infinity]

    /// The buckets' names, looked up when read so a change of language reaches them.
    static var titles: [String] { [
        L("Today", comment: "Legend, coloring by last modified: modified today"),
        L("This week", comment: "Legend, coloring by last modified: within the last 7 days"),
        L("This month", comment: "Legend, coloring by last modified: within the last 30 days"),
        L("3 months", comment: "Legend, coloring by last modified: within the last 3 months"),
        L("6 months", comment: "Legend, coloring by last modified: within the last 6 months"),
        L("1 year", comment: "Legend, coloring by last modified: within the last year"),
        L("2 years", comment: "Legend, coloring by last modified: within the last 2 years"),
        L("5 years", comment: "Legend, coloring by last modified: within the last 5 years"),
        L("Older", comment: "Legend, coloring by last modified: more than 5 years ago"),
    ] }

    static var count: Int { maxAges.count }

    /// Bucket index for a modification time (seconds since 1970) relative to `reference`.
    static func index(modTime: UInt32, reference: TimeInterval) -> Int {
        let age = reference - TimeInterval(modTime)
        for (index, maxAge) in maxAges.enumerated() where age < maxAge {
            return index
        }
        return maxAges.count - 1
    }
}
