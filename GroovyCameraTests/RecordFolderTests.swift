import Foundation
import Testing
@testable import GroovyCamera

struct RecordFolderTests {
    private let zone = TimeZone(identifier: "America/Los_Angeles")!

    /// 2026-11-07 14:32:05 in Los Angeles.
    private let date = Date(timeIntervalSince1970: 1_794_090_725)

    @Test func usesTheLocalDateAndTimeOfTheFirstShot() {
        #expect(RecordFolder.stamp(for: date, timeZone: zone) == "2026-11-07-143205")
        // The same moment is already the next day in UTC, which is why local time is used.
        #expect(RecordFolder.stamp(for: date.addingTimeInterval(10 * 3600), timeZone: zone) == "2026-11-08-003205")
    }

    @Test func neverReusesAFolder() {
        #expect(RecordFolder.folder(for: date, taken: [], timeZone: zone) == "2026-11-07-143205")
        #expect(RecordFolder.folder(for: date, taken: ["2026-11-07-143205"], timeZone: zone) == "2026-11-07-143205-2")
        #expect(RecordFolder.folder(for: date, taken: ["2026-11-07-143205", "2026-11-07-143205-2"], timeZone: zone) == "2026-11-07-143205-3")
    }

    @Test(arguments: [
        (1, "2026-11-07-143205-01-front.jpg"),
        (2, "2026-11-07-143205-02-back.jpg"),
        (3, "2026-11-07-143205-03-side-a.jpg"),
        (4, "2026-11-07-143205-04-side-b.jpg"),
        (8, "2026-11-07-143205-08-side-f.jpg"),
        (9, "2026-11-07-143205-09-gatefold.jpg"),
        (10, "2026-11-07-143205-10-extra.jpg"),
        (12, "2026-11-07-143205-12-extra.jpg"),
    ])
    func namesEachPhotoAfterItsRecordAndSlot(number: Int, name: String) {
        #expect(RecordFolder.fileName(folder: "2026-11-07-143205", slot: Slot(number: number)) == name)
    }
}
