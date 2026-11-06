import Foundation
import FoundationModels

/// Asks Apple's on-device language model to pick the artist and title out of a record's text.
enum NameExtractor {
    @Generable
    struct AlbumName {
        @Guide(description: "The recording artist, band, composer or performer, in normal capitalization.")
        var artist: String
        @Guide(description: "The complete album title, in normal capitalization.")
        var title: String
    }

    @Generable
    struct AlbumTitle {
        @Guide(description: "The complete album title, in normal capitalization. It is never the artist's name.")
        var title: String
    }

    /// Back covers can hold hundreds of words of liner notes, and the model's context is small.
    /// The largest type is what names a record, so that's what gets kept. It's then put back in
    /// reading order, because sorting by size swaps the words of a title set in uneven type.
    private static let maxCharacters = 1500

    /// Nil if the model is unavailable or refuses, which its safety filters can do over album titles.
    static func extract(from lines: [TextLine]) async -> (artist: String, title: String)? {
        guard SystemLanguageModel.default.isAvailable else { return nil }
        do {
            let response = try await makeSession().respond(
                to: "Text from the record, in reading order, each line labeled by its type size:\n\(promptText(from: lines))",
                generating: AlbumName.self,
                options: GenerationOptions(sampling: .greedy)
            )
            let name = (artist: response.content.artist, title: response.content.title)
            if NameValidator.isComplete(artist: name.artist, title: name.title) { return name }

            // The model sometimes gives the band twice, so ask directly for what's missing.
            let retry = try await makeSession().respond(
                to: """
                    The artist is "\(name.artist)". What is the album title? \
                    Text from the record, in reading order, each line labeled by its type size:
                    \(promptText(from: lines))
                    """,
                generating: AlbumTitle.self,
                options: GenerationOptions(sampling: .greedy)
            )
            return (name.artist, retry.content.title)
        } catch {
            return nil
        }
    }

    private static func makeSession() -> LanguageModelSession {
        LanguageModelSession(instructions: """
            You read the text printed on a vinyl record's sleeve and label, and identify the artist \
            and the album title. These are nearly always two different things. \
            The artist's name is usually large and may fill several lines. The title may be much \
            smaller, and is often in quotation marks. Small print is otherwise rarely either. \
            Use only words that appear in the text. Never use outside knowledge of music. \
            Ignore catalog numbers, record labels, track lists, credits and liner notes. \
            A title or an artist's name may run across several lines, so join those lines in order.
            """)
    }

    /// Labels each line by size rather than dropping small type, because some covers print the
    /// band huge and the album title tiny, and the model needs to see both.
    static func promptText(from lines: [TextLine]) -> String {
        let useful = lines.filter(ProminentTextRule.isUseful)
        let largest = useful.map(\.height).max() ?? 0
        var kept: [TextLine] = []
        var characters = 0
        for line in useful.sorted(by: { $0.height > $1.height }) {
            guard characters + line.text.count < maxCharacters else { break }
            characters += line.text.count + 1
            kept.append(line)
        }
        return kept.sorted { $0.top < $1.top }.map { line in
            let share = largest > 0 ? line.height / largest : 0
            let size = share >= 0.6 ? "large" : share >= 0.3 ? "medium" : "small"
            return "[\(size)] \(line.text)"
        }.joined(separator: "\n")
    }
}
