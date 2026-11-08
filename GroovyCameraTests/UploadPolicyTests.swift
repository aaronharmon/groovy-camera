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
