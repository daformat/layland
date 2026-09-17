import Foundation

enum Format {
    static func bytes(_ value: Int64) -> String {
        value.formatted(.byteCount(style: .file))
    }

    static func count(_ value: some BinaryInteger) -> String {
        Int64(value).formatted(.number)
    }

    static func percent(_ part: Int64, of whole: Int64) -> String {
        guard whole > 0 else { return "0%" }
        let ratio = Double(part) / Double(whole)
        return ratio.formatted(.percent.precision(.fractionLength(ratio < 0.01 ? 2 : 1)))
    }

    static func duration(_ seconds: TimeInterval) -> String {
        seconds < 10 ? String(format: "%.2f s", seconds) : String(format: "%.1f s", seconds)
    }
}
