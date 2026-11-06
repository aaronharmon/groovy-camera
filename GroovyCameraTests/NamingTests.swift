import Foundation
import SwiftData
import Testing
@testable import GroovyCamera

struct SlugTests {
    @Test(arguments: [
        ("Miles Davis — Kind of Blue", "miles-davis-kind-of-blue"),
        ("Björk", "bjork"),
        ("AC/DC", "ac-dc"),
        ("Simon & Garfunkel", "simon-and-garfunkel"),
        ("Don't Stop", "dont-stop"),
        ("Don’t Stop", "dont-stop"),
        ("  --Spaced   Out!!  ", "spaced-out"),
        ("Sigur Rós — Ágætis byrjun", "sigur-ros-agaetis-byrjun"),
        ("坂本龍一", "ban-ben-long-yi"),
        ("Кино", "kino"),
    ])
    func makes(name: String, slug: String) {
        #expect(Slug.make(from: name) == slug)
    }

    @Test func nothingUsableIsEmpty() {
        #expect(Slug.make(from: "!!! ---").isEmpty)
    }

    @Test func staysAReasonableLengthWithoutATrailingHyphen() {
        let slug = Slug.make(from: String(repeating: "abcd ", count: 60))
        #expect(slug.count <= 100)
        #expect(!slug.hasSuffix("-"))
    }

    @Test func addsANumberWhenTaken() {
        let date = Date()
        #expect(Slug.folder(for: "Kind of Blue", taken: [], date: date) == "kind-of-blue")
        #expect(Slug.folder(for: "Kind of Blue", taken: ["kind-of-blue"], date: date) == "kind-of-blue-2")
        #expect(Slug.folder(for: "Kind of Blue", taken: ["kind-of-blue", "kind-of-blue-2"], date: date) == "kind-of-blue-3")
    }

    @Test func noUsableNameCountsUpWithinTheDay() {
        let date = Date(timeIntervalSince1970: 1_793_000_000)
        let day = date.formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day())
        #expect(Slug.folder(for: nil, taken: [], date: date) == "untitled-\(day)-1")
        #expect(Slug.folder(for: "???", taken: ["untitled-\(day)-1"], date: date) == "untitled-\(day)-2")
    }
}

struct NameValidatorTests {
    private func lines(_ texts: String...) -> [TextLine] {
        texts.map { TextLine(text: $0, height: 0.05, top: 0.1) }
    }

    @Test func acceptsWordsOnTheRecord() {
        #expect(NameValidator.isValid(artist: "Electric Light Orchestra", title: "On The Third Day", in: lines("ELECTRIC LIGHT", "ORCHESTRA", "\"On The Third Day\"")))
    }

    @Test func rejectsAnAlbumTheModelMadeUp() {
        #expect(!NameValidator.isValid(artist: "Electric Light Orchestra", title: "Out of the Blue", in: lines("ELECTRIC LIGHT", "ORCHESTRA", "On The Third Day")))
    }

    @Test func allowsOneWrongLetterInALongWord() {
        #expect(NameValidator.isValid(artist: "Berlioz", title: "Symphonie Fantastique", in: lines("BERLIOZ", "SYMPHONIE", "FANTASTIOUE")))
    }

    @Test func doesntAllowAWrongLetterInAShortWord() {
        #expect(!NameValidator.isValid(artist: "Abba", title: "Gold", in: lines("Abba", "Cold")))
    }

    @Test func allowsAMissedWordInALongName() {
        #expect(NameValidator.isValid(artist: "Boston Symphony Orchestra", title: "Fantastique", in: lines("BOSTON SYMPHONY", "ORCHESTRA", "FANTASTIQUE")))
        #expect(NameValidator.isValid(artist: "The Boston Symphony Orchestra", title: "Fantastique", in: lines("BOSTON SYMPHONY", "ORCHESTRA", "FANTASTIQUE")))
    }

    @Test func emptyValuesFail() {
        #expect(!NameValidator.isValid(artist: "", title: "Gold", in: lines("Gold")))
        #expect(!NameValidator.isValid(artist: "Abba", title: " ", in: lines("Abba")))
    }

    @Test func ignoresAccentsAndCase() {
        #expect(NameValidator.isValid(artist: "Björk", title: "Debut", in: lines("BJORK", "DÉBUT")))
    }
}

struct CompleteNameTests {
    @Test(arguments: [
        ("Miles Davis", "Kind of Blue", true),
        ("Berlioz", "Symphonie Fantastique", true),
        ("Electric Light Orchestra", "On The Third Day", true),
        ("Electric Light Orchestra", "Electric Light Orchestra", false),
        ("Electric Light Orchestra", "Electric Light", false),
        ("Electric Light", "ELECTRIC LIGHT ORCHESTRA", false),
        ("Berlioz", "Living Stereo", false),
        ("Miles Davis", "", false),
        ("", "Kind of Blue", false),
    ])
    func judges(artist: String, title: String, isComplete: Bool) {
        #expect(NameValidator.isComplete(artist: artist, title: title) == isComplete)
    }
}

struct ProminentTextRuleTests {
    @Test func takesTheTwoLargestInReadingOrder() {
        let lines = [
            TextLine(text: "Stereo", height: 0.2, top: 0.0),
            TextLine(text: "Small print about the record", height: 0.01, top: 0.9),
            TextLine(text: "Kind of Blue", height: 0.06, top: 0.3),
            TextLine(text: "Miles Davis", height: 0.08, top: 0.1),
            TextLine(text: "CL 1355", height: 0.09, top: 0.2),
        ]
        #expect(ProminentTextRule.name(from: lines) == "Miles Davis — Kind of Blue")
    }

    @Test func nothingUsefulIsNil() {
        #expect(ProminentTextRule.name(from: [TextLine(text: "LSC-2608", height: 0.1, top: 0)]) == nil)
        #expect(ProminentTextRule.name(from: []) == nil)
    }
}

private let sampleFront = [TextLine(text: "MILES DAVIS", height: 0.08, top: 0.1), TextLine(text: "KIND OF BLUE", height: 0.06, top: 0.3)]

struct NameExtractorPromptTests {
    @Test func labelsTheLargestTypeInReadingOrder() {
        let filler = String(repeating: "small print ", count: 200)
        let lines = [
            TextLine(text: filler, height: 0.01, top: 0.9),
            TextLine(text: "FANTASTIQUE", height: 0.09, top: 0.4),
            TextLine(text: "SYMPHONIE", height: 0.05, top: 0.3),
            TextLine(text: "On The Third Day", height: 0.02, top: 0.5),
            TextLine(text: "LSC-2608", height: 0.02, top: 0.1),
        ]
        #expect(NameExtractor.promptText(from: lines) == "[medium] SYMPHONIE\n[large] FANTASTIQUE\n[small] On The Third Day")
    }
}

/// Uses stand-ins for text reading and the language model, whose real results only count on a phone.
@MainActor
struct NamingControllerTests {
    private static var keptOpen: [ModelContainer] = []
    private let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    private let container: ModelContainer
    private var context: ModelContext { container.mainContext }
    private var files: PhotoFiles { PhotoFiles(directory: directory) }

    init() throws {
        container = try ModelContainer(for: Record.self, Photo.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        Self.keptOpen.append(container)
    }

    private func naming(
        toast: Duration = .milliseconds(10),
        timeout: Duration = .seconds(5),
        reader: @escaping NamingController.Reader = { _ in sampleFront },
        extractor: @escaping NamingController.Extractor = { _ in ("Miles Davis", "Kind of Blue") }
    ) -> NamingController {
        NamingController(context: context, files: files, toastDuration: toast, extractionTimeout: timeout, reader: reader, extractor: extractor)
    }

    @discardableResult
    private func makeRecord(slots: [Slot] = [.sleeveFront, .sleeveBack], isOpen: Bool = true, state: Photo.State = .processed) throws -> Record {
        let record = Record(sessionID: UUID().uuidString)
        record.isOpen = isOpen
        context.insert(record)
        for slot in slots {
            let photo = Photo(slot: slot)
            photo.state = state
            photo.record = record
            context.insert(photo)
        }
        try context.save()
        return record
    }

    /// Waits for the reads, and for the toast to come and go.
    private func settle(_ naming: NamingController) async throws {
        for _ in 0..<200 {
            await naming.waitUntilIdle()
            if naming.toastRecord == nil, try context.fetch(FetchDescriptor<Record>()).allSatisfy({ $0.isOpen || $0.isNameFinal }) {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("naming never settled")
    }

    @Test func namesTheOpenRecordFromTheFront() async throws {
        let record = try makeRecord()
        let naming = naming()
        await naming.waitUntilIdle()
        #expect(record.name == "Miles Davis — Kind of Blue")
        #expect(!record.isNameFinal, "still open")
    }

    @Test func stopsReadingOnceItHasAName() async throws {
        let reads = Counter()
        let record = try makeRecord()
        let naming = naming(reader: { _ in reads.add(); return sampleFront })
        await naming.waitUntilIdle()
        #expect(reads.value == 1)
        #expect(record.name != nil)
    }

    @Test func goesOnToTheBackWhenTheFrontIsJustArtwork() async throws {
        let reads = Counter()
        let record = try makeRecord()
        let naming = naming(reader: { _ in
            reads.add()
            return reads.value == 1 ? [] : sampleFront
        })
        await naming.waitUntilIdle()
        #expect(reads.value == 2)
        #expect(record.name == "Miles Davis — Kind of Blue")
    }

    @Test func rejectsANameThatIsntOnTheRecord() async throws {
        let record = try makeRecord()
        let naming = naming(extractor: { _ in ("Miles Davis", "Bitches Brew") })
        await naming.waitUntilIdle()
        #expect(record.name == nil)
    }

    @Test func anArtistAloneKeepsReadingForTheAlbum() async throws {
        let reads = Counter()
        let record = try makeRecord()
        let naming = naming(
            reader: { _ in reads.add(); return sampleFront },
            extractor: { _ in reads.value == 1 ? ("Miles Davis", "Miles Davis") : ("Miles Davis", "Kind of Blue") }
        )
        await naming.waitUntilIdle()
        #expect(reads.value == 2)
        #expect(record.name == "Miles Davis — Kind of Blue")
    }

    @Test func aSelfTitledAlbumIsKeptWhenNothingBetterTurnsUp() async throws {
        let record = try makeRecord(isOpen: false)
        let naming = naming(extractor: { _ in ("Miles Davis", "Miles Davis") })
        try await settle(naming)
        #expect(record.name == "Miles Davis — Miles Davis")
        #expect(record.folderSlug == "miles-davis-miles-davis")
    }

    @Test func theFrontsTextComesBeforeTheBacks() async throws {
        let seen = Recorder()
        let record = try makeRecord()
        let naming = naming(
            reader: { _ in [TextLine(text: "WORD", height: 0.05, top: 0.5)] },
            extractor: { lines in seen.keep(lines); return nil }
        )
        await naming.waitUntilIdle()
        #expect(record.name == nil)
        #expect(seen.lines.map(\.top) == [0.5, 1.5])
    }

    @Test func aTypedNameIsNeverOverwritten() async throws {
        let record = try makeRecord()
        record.name = "My Name"
        record.isNameEdited = true
        try context.save()
        let reads = Counter()
        let naming = naming(reader: { _ in reads.add(); return sampleFront })
        await naming.waitUntilIdle()
        #expect(record.name == "My Name")
        #expect(reads.value == 0)
    }

    @Test func aStuckModelTimesOut() async throws {
        let record = try makeRecord(slots: [.sleeveFront, .sleeveBack], isOpen: false)
        let naming = naming(timeout: .milliseconds(20), extractor: { _ in
            try? await Task.sleep(for: .seconds(30))
            return nil
        })
        try await settle(naming)
        #expect(record.isNameFinal)
        #expect(record.name == "MILES DAVIS — KIND OF BLUE", "falls back to the largest text")
    }

    @Test func doneLocksTheNameAfterTheToast() async throws {
        let record = try makeRecord(isOpen: false)
        let naming = naming()
        try await settle(naming)
        #expect(record.isNameFinal)
        #expect(record.folderSlug == "miles-davis-kind-of-blue")
    }

    @Test func aSecondCopyGetsItsOwnFolder() async throws {
        let first = try makeRecord(isOpen: false)
        let second = try makeRecord(isOpen: false)
        let naming = naming()
        try await settle(naming)
        #expect(Set([first.folderSlug, second.folderSlug]) == ["miles-davis-kind-of-blue", "miles-davis-kind-of-blue-2"])
    }

    @Test func fallsBackToTheLargestTextAtDone() async throws {
        let record = try makeRecord(isOpen: false)
        let naming = naming(extractor: { _ in nil })
        try await settle(naming)
        #expect(record.name == "MILES DAVIS — KIND OF BLUE")
        #expect(record.folderSlug == "miles-davis-kind-of-blue")
    }

    @Test func noReadableTextEndsUpUntitled() async throws {
        let record = try makeRecord(isOpen: false)
        let naming = naming(reader: { _ in [] }, extractor: { _ in nil })
        try await settle(naming)
        #expect(record.name == nil)
        #expect(record.folderSlug?.hasPrefix("untitled-") == true)
    }

    @Test func doneWaitsForPhotosStillBeingProcessed() async throws {
        let record = try makeRecord(isOpen: false, state: .pending)
        let naming = naming(extractor: { _ in nil })
        await naming.waitUntilIdle()
        naming.wake()
        #expect(naming.toastRecord == nil)
        #expect(!record.isNameFinal)

        record.photos.forEach { $0.state = .processed }
        try context.save()
        naming.wake()
        try await settle(naming)
        #expect(record.isNameFinal)
    }

    @Test func editingDuringTheToastHoldsItAndSetsTheName() async throws {
        let record = try makeRecord(isOpen: false)
        let naming = naming(toast: .seconds(30))
        for _ in 0..<200 where naming.toastRecord == nil {
            await naming.waitUntilIdle()
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(naming.toastRecord == record)
        naming.beginEditingToast()
        #expect(!record.isNameFinal)

        naming.setName("Fixed Name", for: record)
        naming.endEditingToast()
        #expect(record.isNameEdited)
        #expect(record.isNameFinal)
        #expect(record.folderSlug == "fixed-name")
        #expect(naming.toastRecord == nil)
    }

    @Test func aRelaunchNeverHoldsUploadsForAToast() throws {
        let record = try makeRecord(isOpen: false)
        record.name = "Miles Davis — Kind of Blue"
        try context.save()
        _ = naming(toast: .seconds(30))
        #expect(record.isNameFinal)
        #expect(record.folderSlug == "miles-davis-kind-of-blue")
    }

    @Test func aRelaunchCarriesOnReading() async throws {
        let record = try makeRecord()
        let front = try #require(record.photos.first { $0.slot == .sleeveFront })
        front.isTextRead = true
        front.recognizedLines = []
        try context.save()

        let naming = naming()
        await naming.waitUntilIdle()
        #expect(record.name == "Miles Davis — Kind of Blue")
    }

    @Test func discardingDuringAReadIsHarmless() async throws {
        let record = try makeRecord()
        let naming = naming()
        context.delete(record)
        try context.save()
        await naming.waitUntilIdle()
        #expect(try context.fetch(FetchDescriptor<Record>()).isEmpty)
    }

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var kept: [TextLine] = []
        var lines: [TextLine] { lock.withLock { kept } }
        func keep(_ lines: [TextLine]) { lock.withLock { kept = lines } }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.withLock { count } }
        func add() { lock.withLock { count += 1 } }
    }
}

/// Reports naming accuracy on real photos, using a git-ignored list of what each one should say:
/// `Fixtures/originals/names.json` maps `session/file.jpg` to the words its folder must contain.
/// Runs only when that's present, and the language model's results only count on a phone.
struct NamingFixtureTests {
    @Test func reportsAccuracyOnRealPhotosIfPresent() async throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "Fixtures/originals")
        guard let data = try? Data(contentsOf: root.appending(path: "names.json")) else { return }
        let expected = try JSONDecoder().decode([String: [String]].self, from: data)
        var named = 0
        var viaModel = 0
        for (file, words) in expected.sorted(by: { $0.key < $1.key }) {
            let lines = TextReader.read(url: root.appending(path: file))
            let answer = await NameExtractor.extract(from: lines)
            let isValid = answer.map { NameValidator.isValid(artist: $0.artist, title: $0.title, in: lines) } ?? false
            let name = isValid ? answer.map { "\($0.artist) — \($0.title)" } : ProminentTextRule.name(from: lines)
            let slug = Slug.folder(for: name, taken: [], date: Date())
            let isRight = words.allSatisfy(slug.contains)
            if isRight { named += 1 }
            if isValid { viaModel += 1 }
            print("NAMING \(isRight ? "ok " : "BAD") \(isValid ? "model" : "rule ") \(file) -> \(slug) | model said: \(answer.map { "\($0.artist) / \($0.title)" } ?? "nothing")")
        }
        print("NAMING score \(named)/\(expected.count), \(viaModel) by the model")
    }
}
