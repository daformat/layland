import Foundation

/// Sizes, counts, dates and durations, in the app's language (`AppLocale`) rather than the
/// one the process started in, which a change in Settings ▸ Language moves away from.
enum Format {
    private static var locale: Locale { AppLocale.shared.locale }

    static func bytes(_ value: Int64) -> String {
        value.formatted(.byteCount(style: .file).locale(locale))
    }

    static func count(_ value: some BinaryInteger) -> String {
        Int64(value).formatted(.number.locale(locale))
    }

    // Counts of things, with the noun in the form the count takes in the app's language
    // (Russian's 3 файла and 5 файлов): the number goes in as a number, grouped by the locale.

    static func files(_ value: some BinaryInteger) -> String {
        L("\(Int(value)) files")
    }

    static func folders(_ value: some BinaryInteger) -> String {
        L("\(Int(value)) folders")
    }

    static func items(_ value: some BinaryInteger) -> String {
        L("\(Int(value)) items", comment: "What a folder holds: files and folders together")
    }

    static func matches(_ value: some BinaryInteger) -> String {
        L("\(Int(value)) matches", comment: "Search results")
    }

    static func percent(_ part: Int64, of whole: Int64) -> String {
        guard whole > 0 else { return 0.0.formatted(.percent.locale(locale)) }
        let ratio = Double(part) / Double(whole)
        return ratio.formatted(.percent.precision(.fractionLength(ratio < 0.01 ? 2 : 1)).locale(locale))
    }

    /// A fraction done, as a whole percentage: "42%".
    static func progress(_ fraction: Double) -> String {
        fraction.formatted(.percent.precision(.fractionLength(0)).locale(locale))
    }

    /// "1.25s", "12.5s".
    static func duration(_ seconds: TimeInterval) -> String {
        Measurement(value: seconds, unit: UnitDuration.seconds)
            .formatted(.measurement(width: .narrow, numberFormatStyle: .number.precision(.fractionLength(seconds < 10 ? 2 : 1))).locale(locale))
    }

    static func date(_ date: Date, time: Bool) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: time ? .shortened : .omitted).locale(locale))
    }
}
