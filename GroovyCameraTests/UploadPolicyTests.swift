import Foundation
import Testing
@testable import GroovyCamera

struct UploadPolicyTests {
    private let now = Date(timeIntervalSince1970: 1_794_090_725)
    private var justSigned: Date { now.addingTimeInterval(-30) }
    private var signedLastWeek: Date { now.addingTimeInterval(-7 * 24 * 60 * 60) }

    @Test func uploadedOnlyWhenR2HasTheSameFile() {
        #expect(UploadPolicy.next(status: 200, etagMatches: true, signedAt: justSigned, now: now, attempts: 1) == .uploaded)
        #expect(UploadPolicy.next(status: 200, etagMatches: false, signedAt: justSigned, now: now, attempts: 1) == .retry)
    }

    @Test func signsAgainWhenAnOldURLHasExpired() {
        #expect(UploadPolicy.next(status: 403, etagMatches: false, signedAt: signedLastWeek, now: now, attempts: 1) == .retry)
    }

    @Test func stopsWhenAFreshlySignedURLIsRefused() {
        // The token was revoked or mistyped, so signing again with it wouldn't help.
        #expect(UploadPolicy.next(status: 403, etagMatches: false, signedAt: justSigned, now: now, attempts: 1) == .needsAttention)
        #expect(UploadPolicy.next(status: 404, etagMatches: false, signedAt: justSigned, now: now, attempts: 1) == .needsAttention)
    }

    @Test func retriesServerErrorsAFewTimes() {
        #expect(UploadPolicy.next(status: 503, etagMatches: false, signedAt: justSigned, now: now, attempts: 1) == .retry)
        #expect(UploadPolicy.next(status: nil, etagMatches: false, signedAt: justSigned, now: now, attempts: 4) == .retry)
        #expect(UploadPolicy.next(status: 503, etagMatches: false, signedAt: justSigned, now: now, attempts: UploadPolicy.maxAttempts) == .needsAttention)
    }

    @Test func comparesTheETagWithTheFilesMD5() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "\(UUID()).jpg")
        try Data("hello".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(UploadPolicy.etag("\"5D41402ABC4B2A76B9719D911017C592\"", matches: file))
        #expect(!UploadPolicy.etag("\"00000000000000000000000000000000\"", matches: file))
        #expect(!UploadPolicy.etag(nil, matches: file))
    }
}

struct LocalCopiesTests {
    private let uploaded = Date(timeIntervalSince1970: 1_794_090_725)

    @Test func clearsStraightAwayWhenKeepingNoDays() {
        #expect(LocalCopies.isDue(uploadedAt: uploaded, keepDays: 0, now: uploaded))
    }

    @Test func waitsTheDaysSetBeforeClearing() {
        let day = 24.0 * 60 * 60
        #expect(!LocalCopies.isDue(uploadedAt: uploaded, keepDays: 3, now: uploaded.addingTimeInterval(2.9 * day)))
        #expect(LocalCopies.isDue(uploadedAt: uploaded, keepDays: 3, now: uploaded.addingTimeInterval(3 * day)))
    }

    @Test func clearingKeepsTheOriginalWhenAsked() throws {
        let files = PhotoFiles(directory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: files.directory) }
        let location = PhotoLocation(sessionID: "session", photoID: UUID())
        try files.saveOriginal(Data([1]), for: location)
        try PhotoFiles.write(Data([2]), to: files.finishedURL(location))
        try PhotoFiles.write(Data([3]), to: files.thumbnailURL(location))

        files.removeUploaded(location, keepingOriginal: true)
        #expect(FileManager.default.fileExists(atPath: files.originalURL(location).path()))
        #expect(!FileManager.default.fileExists(atPath: files.finishedURL(location).path()))
        #expect(!FileManager.default.fileExists(atPath: files.thumbnailURL(location).path()))

        files.removeUploaded(location, keepingOriginal: false)
        #expect(!FileManager.default.fileExists(atPath: files.originalURL(location).path()))
    }
}
