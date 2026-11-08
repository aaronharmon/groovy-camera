import Foundation

/// How long photos stay on the phone once R2 has them. Set in Settings.
enum LocalCopies {
    static let dayRange = 0...30
    private static let daysKey = "keepUploadedDays"
    private static let originalsKey = "keepOriginals"

    /// Days to keep a photo after its upload is confirmed. Zero clears it straight away.
    static var keepDays: Int {
        get { min(max(UserDefaults.standard.integer(forKey: daysKey), dayRange.lowerBound), dayRange.upperBound) }
        set { UserDefaults.standard.set(newValue, forKey: daysKey) }
    }

    /// Keeps full-size originals for re-running the image pipeline on real photos. On until edge
    /// detection (M4) is done, because it's measured on them.
    static var keepOriginals: Bool {
        get { UserDefaults.standard.object(forKey: originalsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: originalsKey) }
    }

    static func isDue(uploadedAt: Date, keepDays: Int, now: Date) -> Bool {
        now.timeIntervalSince(uploadedAt) >= Double(keepDays) * 24 * 60 * 60
    }
}
