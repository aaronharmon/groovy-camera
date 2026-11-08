import Foundation

/// The spreadsheet of every uploaded photo's link, kept at `records/photos.csv` in the bucket.
///
/// One row per photo, with the record's folder only on its first row, so each record reads as a
/// block. Records run oldest first, so new ones land at the bottom. It's rebuilt from this phone's
/// records, so photos uploaded by an earlier install of the app aren't listed.
enum PhotoIndex {
    static let key = "\(R2Client.prefix)photos.csv"
    /// Short, so the spreadsheet's link shows new rows within a minute.
    static let headers = [
        "Content-Type": "text/csv; charset=utf-8",
        "Cache-Control": "public, max-age=60",
    ]

    struct Entry: Equatable, Sendable {
        var folder: String
        var slot: Slot
    }

    /// - Parameter domain: The bucket's public domain, such as `https://photos.example.com`.
    static func csv(_ entries: [Entry], domain: String) -> String {
        let base = baseURL(domain)
        var rows = [["Record", "Photo", "URL"]]
        let byFolder = Dictionary(grouping: entries, by: \.folder)
        for folder in byFolder.keys.sorted() {
            for (index, entry) in byFolder[folder]!.sorted(by: { $0.slot < $1.slot }).enumerated() {
                rows.append([
                    index == 0 ? folder : "",
                    entry.slot.fileLabel,
                    "\(base)/\(R2Client.key(folder: folder, slot: entry.slot))",
                ])
            }
        }
        return rows.map { $0.map(escape).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }

    /// Accepts the domain with or without `https://` and a trailing slash.
    static func baseURL(_ domain: String) -> String {
        var base = domain.trimmingCharacters(in: .whitespaces)
        while base.hasSuffix("/") { base.removeLast() }
        if !base.isEmpty, !base.contains("://") { base = "https://\(base)" }
        return base
    }

    /// The spreadsheet's own public link, or nil without a domain.
    static func url(domain: String) -> URL? {
        let base = baseURL(domain)
        return base.isEmpty ? nil : URL(string: "\(base)/\(key)")
    }

    private static func escape(_ field: String) -> String {
        guard field.contains(where: { ",\"\r\n".contains($0) }) else { return field }
        return "\"\(field.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}

/// The bucket's public domain, for links in the spreadsheet. Entered in Settings and kept only on
/// this phone, because it's specific to the owner's account.
enum PhotoDomain {
    private static let key = "photoDomain"

    static func load(from defaults: UserDefaults = .standard) -> String {
        defaults.string(forKey: key) ?? ""
    }

    static func save(_ domain: String, to defaults: UserDefaults = .standard) {
        defaults.set(domain.trimmingCharacters(in: .whitespaces), forKey: key)
    }
}
