import Foundation

/// Turns a record's name into its folder name on R2.
enum Slug {
    /// Long enough for any real album, short enough that a bad read can't make an absurd path.
    private static let maxLength = 100

    /// `Björk` becomes `bjork`, `AC/DC` becomes `ac-dc` and `&` becomes `and`. Other alphabets are
    /// transliterated. Empty when nothing usable is left, which callers treat as having no name.
    static func make(from name: String) -> String {
        let latin = name
            .replacingOccurrences(of: "&", with: " and ")
            .applyingTransform(StringTransform("Any-Latin; Latin-ASCII"), reverse: false) ?? name

        var slug = ""
        for scalar in latin.lowercased().unicodeScalars {
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) {
                slug.unicodeScalars.append(scalar)
            } else if scalar == "'" || scalar == "\u{2019}" {
                continue // "Don't" reads better as "dont" than "don-t".
            } else if !slug.isEmpty, !slug.hasSuffix("-") {
                slug.append("-")
            }
        }
        let trimmed = String(slug.prefix(maxLength))
        return trimmed.hasSuffix("-") ? String(trimmed.dropLast()) : trimmed
    }

    /// The folder for a record, which never reuses one already taken. With no usable name it's
    /// `untitled-2026-11-04-1`, counting up within the day.
    static func folder(for name: String?, taken: Set<String>, date: Date) -> String {
        let slug = name.map(make(from:)) ?? ""
        guard slug.isEmpty else {
            return unique(slug, firstSuffix: nil, taken: taken)
        }
        // The local date, or a record shot in the evening could be filed under tomorrow.
        let day = date.formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day())
        return unique("untitled-\(day)", firstSuffix: 1, taken: taken)
    }

    private static func unique(_ base: String, firstSuffix: Int?, taken: Set<String>) -> String {
        if firstSuffix == nil, !taken.contains(base) { return base }
        var number = firstSuffix ?? 2
        while taken.contains("\(base)-\(number)") { number += 1 }
        return "\(base)-\(number)"
    }
}
