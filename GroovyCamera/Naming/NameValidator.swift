import Foundation

/// One line of text read off a record, with what's needed to judge how prominent it is.
struct TextLine: Codable, Equatable, Sendable {
    var text: String
    /// Share of the photo's height, so bigger type scores higher.
    var height: Double
    /// Share of the photo's height from the top.
    var top: Double
}

/// Stops the language model filling in a plausible album from its own knowledge: a name only counts
/// if the words really are on the record.
enum NameValidator {
    /// Most of a name's words must appear, because stylized type often costs a word.
    private static let requiredShare = 0.75
    private static let shortestFuzzyWord = 5

    static func isValid(artist: String, title: String, in lines: [TextLine]) -> Bool {
        let available = Set(lines.flatMap { words(in: $0.text) })
        return appears(artist, in: available) && appears(title, in: available)
    }

    /// A name is only complete with an album distinct from the artist. Covers often print the band
    /// large and the title small, and then the model repeats the band as the title.
    static func isComplete(artist: String, title: String) -> Bool {
        let artistWords = Set(words(in: artist))
        let titleWords = Set(words(in: title))
        guard !artistWords.isEmpty, !titleWords.isEmpty else { return false }
        guard !ProminentTextRule.isBoilerplate(title) else { return false }
        return !titleWords.isSubset(of: artistWords) && !artistWords.isSubset(of: titleWords)
    }

    private static func appears(_ value: String, in available: Set<String>) -> Bool {
        let wanted = words(in: value)
        guard !wanted.isEmpty else { return false }
        let found = wanted.filter { word in
            available.contains(word) || (word.count >= shortestFuzzyWord && available.contains { isOneEditAway($0, word) })
        }
        return Double(found.count) / Double(wanted.count) >= requiredShare
    }

    /// Letters and digits only, in plain Latin, so accents and punctuation can't cause a miss.
    private static func words(in text: String) -> [String] {
        let plain = text.applyingTransform(StringTransform("Any-Latin; Latin-ASCII"), reverse: false) ?? text
        return plain.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    /// Text recognition often gets one letter of a stylized word wrong.
    private static func isOneEditAway(_ first: String, _ second: String) -> Bool {
        let a = Array(first)
        let b = Array(second)
        guard abs(a.count - b.count) <= 1 else { return false }
        var i = 0
        var j = 0
        var edits = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] {
                i += 1
                j += 1
                continue
            }
            edits += 1
            if edits > 1 { return false }
            if a.count > b.count {
                i += 1
            } else if b.count > a.count {
                j += 1
            } else {
                i += 1
                j += 1
            }
        }
        return edits + (a.count - i) + (b.count - j) <= 1
    }
}

/// The fallback when the model refuses or its answer doesn't check out: covers usually print the
/// name largest, with the artist above the title.
enum ProminentTextRule {
    /// Printed on many sleeves but never part of an album's name.
    private static let ignoredLines: Set<String> = ["stereo", "mono", "monaural", "living stereo", "high fidelity", "lp"]
    private static let shortestUsefulLetters = 3

    static func name(from lines: [TextLine]) -> String? {
        let candidates = lines.filter(isUseful).sorted { $0.height > $1.height }.prefix(2)
        guard !candidates.isEmpty else { return nil }
        return candidates.sorted { $0.top < $1.top }.map(\.text).joined(separator: " — ")
    }

    static func isBoilerplate(_ text: String) -> Bool {
        ignoredLines.contains(text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    static func isUseful(_ line: TextLine) -> Bool {
        let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isBoilerplate(text) else { return false }
        // Catalog numbers such as LSC-2608 are mostly digits.
        let letters = text.filter(\.isLetter).count
        let digits = text.filter(\.isNumber).count
        return letters >= shortestUsefulLetters && digits <= letters / 2
    }
}
