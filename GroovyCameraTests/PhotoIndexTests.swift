import Foundation
import Testing
@testable import GroovyCamera

struct PhotoIndexTests {
    @Test func namesEachRecordOnItsFirstRowOnly() {
        let entries = [
            PhotoIndex.Entry(folder: "2026-11-08-102210", slot: Slot(number: 1)),
            PhotoIndex.Entry(folder: "2026-11-08-101530", slot: Slot(number: 3)),
            PhotoIndex.Entry(folder: "2026-11-08-101530", slot: Slot(number: 1)),
            PhotoIndex.Entry(folder: "2026-11-08-101530", slot: Slot(number: 2)),
        ]
        let csv = PhotoIndex.csv(entries, domain: "https://photos.example.com")
        let base = "https://photos.example.com/records"
        #expect(csv == [
            "Record,Photo,URL",
            "2026-11-08-101530,front,\(base)/2026-11-08-101530/2026-11-08-101530-01-front.jpg",
            ",back,\(base)/2026-11-08-101530/2026-11-08-101530-02-back.jpg",
            ",side-a,\(base)/2026-11-08-101530/2026-11-08-101530-03-side-a.jpg",
            "2026-11-08-102210,front,\(base)/2026-11-08-102210/2026-11-08-102210-01-front.jpg",
            "",
        ].joined(separator: "\r\n"))
    }

    @Test func listsOnlyRecordsStartedSinceItWasCleared() {
        let cleared = Date(timeIntervalSince1970: 1_000_000)
        #expect(PhotoIndexStart.lists(recordCreatedAt: cleared.addingTimeInterval(-1), clearedAt: nil))
        #expect(!PhotoIndexStart.lists(recordCreatedAt: cleared.addingTimeInterval(-1), clearedAt: cleared))
        #expect(PhotoIndexStart.lists(recordCreatedAt: cleared.addingTimeInterval(1), clearedAt: cleared))
    }

    @Test func acceptsTheDomainHoweverItsTyped() {
        #expect(PhotoIndex.baseURL("photos.example.com/") == "https://photos.example.com")
        #expect(PhotoIndex.baseURL(" https://photos.example.com ") == "https://photos.example.com")
        #expect(PhotoIndex.url(domain: "")?.absoluteString == nil)
        #expect(PhotoIndex.url(domain: "photos.example.com")?.absoluteString == "https://photos.example.com/photos.csv")
    }

    @Test func isOnlyHeadersWithNothingUploaded() {
        #expect(PhotoIndex.csv([], domain: "photos.example.com") == "Record,Photo,URL\r\n")
    }
}
