import Foundation

/// Files a record under the local date and time of its first shot, so every photo of it carries
/// the same stamp and they group together in any listing, with or without their folder:
/// `records/2026-11-07-143205/2026-11-07-143205-01-front.jpg`.
enum RecordFolder {
    /// Local time, or a record shot in the evening could be filed under tomorrow.
    static func stamp(for date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(
            format: "%04d-%02d-%02d-%02d%02d%02d",
            parts.year ?? 0, parts.month ?? 0, parts.day ?? 0, parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0
        )
    }

    /// Two records can't really start in the same second, but a clock change could repeat a stamp,
    /// and a repeat would overwrite the earlier record's photos.
    static func folder(for date: Date, taken: Set<String>, timeZone: TimeZone = .current) -> String {
        let base = stamp(for: date, timeZone: timeZone)
        guard taken.contains(base) else { return base }
        var number = 2
        while taken.contains("\(base)-\(number)") { number += 1 }
        return "\(base)-\(number)"
    }

    /// The slot number keeps a record's photos in shot order when sorted by name.
    static func fileName(folder: String, slot: Slot) -> String {
        "\(folder)-" + String(format: "%02d", slot.number) + "-\(slot.fileLabel).jpg"
    }
}
