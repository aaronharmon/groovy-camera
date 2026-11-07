import Foundation
import SwiftData
import Testing
@testable import GroovyCamera

struct SessionStateTests {
    private func shooting(_ numbers: [Int]) -> SessionState {
        var state = SessionState()
        numbers.forEach { state.recordShot(in: Slot(number: $0)) }
        return state
    }

    @Test func runsThroughTheSleeveThenTheSides() {
        var state = SessionState()
        for number in 1...8 {
            #expect(state.currentSlot == Slot(number: number))
            state.recordShot(in: Slot(number: number))
        }
        #expect(state.currentSlot == nil)
    }

    @Test func namesTheSlots() {
        #expect(Slot.sleeveFront.title == "01 · Sleeve front")
        #expect(Slot(number: 4).title == "04 · Side B")
        #expect(Slot(number: 8).title == "08 · Side F")
        #expect(Slot(number: 9).title == "09 · Gatefold")
        #expect(Slot(number: 11).title == "11 · Extra")
    }

    @Test func theSleeveCantBeSkipped() {
        var state = SessionState()
        #expect(!state.canSkip)
        state.skipCurrent()
        #expect(state.currentSlot == .sleeveFront)

        state = shooting([1])
        #expect(!state.canSkip)
    }

    @Test func skippingMovesToTheNextSide() {
        var state = shooting([1, 2])
        #expect(state.canSkip)
        state.skipCurrent()
        #expect(state.currentSlot == Slot(number: 4))
    }

    @Test func aSkippedSlotCanStillBeShot() {
        var state = shooting([1, 2])
        state.skipCurrent()
        state.target = .slot(Slot(number: 3))
        #expect(state.currentSlot == Slot(number: 3))
        state.recordShot(in: Slot(number: 3))
        #expect(state.skipped.isEmpty)
        #expect(state.currentSlot == Slot(number: 4))
    }

    @Test func aRetakeReturnsToWhereTheRecordWas() {
        var state = shooting([1, 2, 3])
        state.target = .slot(.sleeveFront)
        #expect(state.currentSlot == .sleeveFront)
        #expect(!state.canSkip)
        state.recordShot(in: .sleeveFront)
        #expect(state.currentSlot == Slot(number: 4))
    }

    @Test func extrasNumberUpFromTen() {
        var state = SessionState()
        state.target = .extra
        #expect(state.currentSlot == Slot(number: 10))
        state.recordShot(in: Slot(number: 10))
        #expect(state.currentSlot == .sleeveFront)
        state.target = .extra
        #expect(state.currentSlot == Slot(number: 11))
    }

    @Test func doneNeedsBothSleevePhotos() {
        #expect(!SessionState().canFinish)
        #expect(!shooting([1]).canFinish)
        #expect(!shooting([2, 3]).canFinish)
        #expect(shooting([1, 2]).canFinish)
    }
}

/// Uses an in-memory store and a stand-in for the image pipeline, so this covers crash recovery and
/// file handling without a camera. A "crash" is a new controller opening the same store and folder.
@MainActor
struct SessionControllerTests {
    private let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    private let container: ModelContainer
    private var files: PhotoFiles { PhotoFiles(directory: directory) }

    init() throws {
        container = try ModelContainer(
            for: Record.self, Photo.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        Self.keptOpen.append(container)
    }

    /// Some tests end with the queue still working. The app's store stays open for its whole life,
    /// so a test's store mustn't close underneath the queue either.
    private static var keptOpen: [ModelContainer] = []

    private func controller(
        keepOriginals: Bool = true,
        processor: @escaping SessionController.Processor = Self.fakeProcessor
    ) -> SessionController {
        SessionController(context: container.mainContext, files: files, keepOriginals: keepOriginals, processor: processor)
    }

    private static let fakeProcessor: SessionController.Processor = { job in
        try? PhotoFiles.write(Data([1]), to: job.finished)
        try? PhotoFiles.write(Data([1]), to: job.thumbnail)
        return .sleeve
    }

    /// Takes a shot the way the camera does: the row first, then the file.
    @discardableResult
    private func shoot(_ session: SessionController) throws -> CaptureTicket {
        let ticket = try #require(session.beginCapture())
        try files.saveOriginal(Data([0]), for: ticket.location)
        session.captureFinished(ticket, didSave: true)
        return ticket
    }

    private var fileCount: Int {
        FileManager.default.enumerator(atPath: directory.path())?.allObjects.compactMap { path -> String? in
            guard let path = path as? String else { return nil }
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: directory.appending(path: path).path(), isDirectory: &isDirectory)
            return isDirectory.boolValue ? nil : path
        }.count ?? 0
    }

    private func photos() throws -> [Photo] {
        try container.mainContext.fetch(FetchDescriptor<Photo>())
    }

    @Test func advancesAsSoonAsTheShutterFires() throws {
        let session = controller()
        let ticket = try #require(session.beginCapture())
        #expect(ticket.slot == .sleeveFront)
        #expect(session.state.currentSlot == .sleeveBack)
        #expect(try photos().first?.state == .capturing)
    }

    @Test func processesEachPhotoAndFillsItsThumbnail() async throws {
        let session = controller()
        let ticket = try shoot(session)
        await session.waitUntilProcessed()
        #expect(try photos().first?.state == .processed)
        #expect(try photos().first?.cropKind == .sleeve)
        #expect(session.tiles.first?.thumbnail == files.thumbnailURL(ticket.location))
    }

    @Test func handlesOneShotAtATimeInOrder() async throws {
        let log = Log()
        let session = controller { job in
            log.begin(job.location.photoID)
            Thread.sleep(forTimeInterval: 0.02)
            log.end()
            return .sleeve
        }
        let tickets = try (0..<4).map { _ in try shoot(session) }
        await session.waitUntilProcessed()
        #expect(log.mostAtOnce == 1)
        #expect(log.order == tickets.map(\.location.photoID))
    }

    @Test func deletesTheOriginalAfterProcessingWhenNotKeepingIt() async throws {
        let session = controller(keepOriginals: false)
        let ticket = try shoot(session)
        await session.waitUntilProcessed()
        #expect(!FileManager.default.fileExists(atPath: files.originalURL(ticket.location).path()))
        #expect(FileManager.default.fileExists(atPath: files.finishedURL(ticket.location).path()))
    }

    @Test func filesTheRecordUnderItsFirstShotsTime() throws {
        let session = controller()
        let before = Date()
        try shoot(session)
        try shoot(session)
        let record = try #require(session.currentRecord)
        #expect(record.folder == RecordFolder.stamp(for: record.createdAt))
        #expect(record.createdAt >= before.addingTimeInterval(-1))
        #expect(record.photos.allSatisfy { $0.record?.folder == record.folder })
    }

    @Test func aFailedShotLeavesTheSlotOpen() throws {
        let session = controller()
        let ticket = try #require(session.beginCapture())
        session.captureFinished(ticket, didSave: false)
        #expect(session.captureFailed)
        #expect(session.state.currentSlot == .sleeveFront)
        #expect(try photos().isEmpty)
    }

    // MARK: - Retakes

    @Test func aRetakeReplacesTheOldPhotoOnlyOnceItsSaved() async throws {
        let session = controller()
        let first = try shoot(session)
        await session.waitUntilProcessed()
        session.select(.sleeveFront)
        let retake = try #require(session.beginCapture())
        #expect(retake.slot == .sleeveFront)
        #expect(session.state.currentSlot == .sleeveBack)
        #expect(FileManager.default.fileExists(atPath: files.finishedURL(first.location).path()))

        try files.saveOriginal(Data([0]), for: retake.location)
        session.captureFinished(retake, didSave: true)
        #expect(!FileManager.default.fileExists(atPath: files.finishedURL(first.location).path()))
        await session.waitUntilProcessed()
        #expect(try photos().map(\.id) == [retake.location.photoID])
    }

    @Test func aFailedRetakeKeepsTheOldPhoto() async throws {
        let session = controller()
        let first = try shoot(session)
        await session.waitUntilProcessed()
        session.select(.sleeveFront)
        let retake = try #require(session.beginCapture())
        session.captureFinished(retake, didSave: false)
        #expect(try photos().map(\.id) == [first.location.photoID])
        #expect(session.state.shot.contains(.sleeveFront))
        #expect(session.tiles.first?.thumbnail == files.thumbnailURL(first.location))
    }

    // MARK: - Done and discard

    @Test func doneClosesTheRecordAndOpensANewSession() throws {
        let session = controller()
        try shoot(session)
        session.finish()
        #expect(try container.mainContext.fetch(FetchDescriptor<Record>()).first?.isOpen == true, "needs both sleeve photos")
        try shoot(session)
        session.finish()
        #expect(session.state == SessionState())
        #expect(session.tiles.isEmpty)
        #expect(try container.mainContext.fetch(FetchDescriptor<Record>()).first?.isOpen == false)
    }

    @Test func discardLeavesNoFilesOrRowsBehind() async throws {
        let session = controller()
        try shoot(session)
        try shoot(session)
        await session.waitUntilProcessed()
        #expect(fileCount > 0)

        session.discard()
        #expect(fileCount == 0)
        #expect(try photos().isEmpty)
        #expect(try container.mainContext.fetch(FetchDescriptor<Record>()).isEmpty)
        #expect(!session.canDiscard)
    }

    @Test func aPhotoStillBeingTakenAtDiscardLeavesNoFileBehind() throws {
        let session = controller()
        let ticket = try #require(session.beginCapture())
        session.discard()
        try files.saveOriginal(Data([0]), for: ticket.location)
        session.captureFinished(ticket, didSave: true)
        #expect(fileCount == 0)
    }

    @Test func aPhotoBeingProcessedAtDiscardLeavesNoFileBehind() async throws {
        let session = controller()
        try shoot(session)
        session.discard()
        await session.waitUntilProcessed()
        #expect(fileCount == 0)
    }

    // MARK: - Crash recovery

    @Test func aRelaunchResumesTheOpenSession() throws {
        let session = controller()
        try shoot(session)
        session.select(.sleeveFront)

        let reopened = controller()
        #expect(reopened.state.currentSlot == .sleeveBack)
        #expect(reopened.state.shot == [.sleeveFront])
        #expect(reopened.tiles.count == 1)
    }

    @Test func aRelaunchRemembersSkippedSides() throws {
        let session = controller()
        try shoot(session)
        try shoot(session)
        session.skip()

        let reopened = controller()
        #expect(reopened.state.currentSlot == Slot(number: 4))
    }

    @Test func aRelaunchFinishesPhotosStillWaiting() async throws {
        let blocked = controller { _ in nil }
        let ticket = try #require(blocked.beginCapture())
        try files.saveOriginal(Data([0]), for: ticket.location)
        // Nothing is run yet: the queue only starts once the camera reports the file saved.
        let photo = try #require(try photos().first)
        photo.state = .pending
        photo.attempts = 1
        try container.mainContext.save()

        let reopened = controller()
        await reopened.waitUntilProcessed()
        #expect(try photos().first?.state == .processed)
    }

    @Test func aPhotoOnDiskIsKeptIfTheAppDiedBeforeNotingIt() async throws {
        let session = controller()
        let ticket = try #require(session.beginCapture())
        try files.saveOriginal(Data([0]), for: ticket.location)

        let reopened = controller()
        await reopened.waitUntilProcessed()
        #expect(try photos().first?.state == .processed)
        #expect(reopened.state.shot == [.sleeveFront])
    }

    @Test func aShotThatNeverReachedTheDiskIsForgotten() throws {
        let session = controller()
        _ = try #require(session.beginCapture())

        let reopened = controller()
        #expect(try photos().isEmpty)
        #expect(reopened.state.currentSlot == .sleeveFront)
    }

    @Test func aRetakeInterruptedAfterSavingReplacesTheOldPhoto() async throws {
        let session = controller()
        let first = try shoot(session)
        await session.waitUntilProcessed()
        session.select(.sleeveFront)
        let retake = try #require(session.beginCapture())
        try files.saveOriginal(Data([0]), for: retake.location)

        let reopened = controller()
        await reopened.waitUntilProcessed()
        #expect(try photos().map(\.id) == [retake.location.photoID])
        #expect(!FileManager.default.fileExists(atPath: files.originalURL(first.location).path()))
    }

    @Test func aRecordClosedWithPhotosWaitingStillFinishesThem() async throws {
        let session = controller()
        try shoot(session)
        try shoot(session)
        session.finish()
        await session.waitUntilProcessed()
        #expect(try photos().allSatisfy { $0.state == .processed })
    }

    @Test func aPhotoThatKeepsCrashingStopsBeingTried() async throws {
        let session = controller { _ in nil }
        let ticket = try #require(session.beginCapture())
        try files.saveOriginal(Data([0]), for: ticket.location)
        let photo = try #require(try photos().first)
        photo.state = .pending
        photo.attempts = 3
        try container.mainContext.save()

        let runs = Log()
        let reopened = controller { job in
            runs.begin(job.location.photoID)
            runs.end()
            return .sleeve
        }
        await reopened.waitUntilProcessed()
        #expect(runs.order.isEmpty)
        #expect(try photos().first?.state == .failed)
        #expect(FileManager.default.fileExists(atPath: files.originalURL(ticket.location).path()), "the original must survive")
    }

    /// Notes what the stand-in processor did, from whichever thread it ran on.
    private final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var running = 0
        private(set) var mostAtOnce = 0
        private(set) var order: [UUID] = []

        func begin(_ id: UUID) {
            lock.withLock {
                running += 1
                mostAtOnce = max(mostAtOnce, running)
                order.append(id)
            }
        }

        func end() {
            lock.withLock { running -= 1 }
        }
    }
}
