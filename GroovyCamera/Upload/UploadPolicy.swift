import CryptoKit
import Foundation

/// Decides what happens to a photo after one upload attempt. Kept apart from URLSession so the
/// rules can be tested.
enum UploadPolicy {
    enum Next: Equatable {
        case uploaded
        /// Sign a new URL and try again.
        case retry
        case needsAttention
    }

    /// Enough to ride out a few server errors without retrying a broken photo forever.
    static let maxAttempts = 5
    /// A URL refused within this long of being signed wasn't expired, so the token itself is
    /// wrong. Signing again with the same token wouldn't help.
    static let freshlySigned: TimeInterval = 60 * 60

    /// - Parameters:
    ///   - status: The HTTP status, or nil when no response arrived.
    ///   - attempts: Attempts made so far, including this one.
    static func next(status: Int?, etagMatches: Bool, signedAt: Date, now: Date, attempts: Int) -> Next {
        let retryOrGiveUp: Next = attempts < maxAttempts ? .retry : .needsAttention
        switch status {
        case let status? where (200..<300).contains(status):
            // Arrived, but not intact.
            return etagMatches ? .uploaded : retryOrGiveUp
        case 400, 401, 403:
            // R2 refuses an expired URL this way, and also a revoked or rotated token.
            return now.timeIntervalSince(signedAt) > freshlySigned ? retryOrGiveUp : .needsAttention
        case 404:
            // The bucket or account is wrong, which only Settings can fix.
            return .needsAttention
        default:
            return retryOrGiveUp
        }
    }

    /// For a single-part upload, R2's ETag is the MD5 of what it stored, in quotes.
    static func etag(_ header: String?, matches file: URL) -> Bool {
        guard let header, let data = try? Data(contentsOf: file) else { return false }
        let md5 = Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return header.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")).lowercased() == md5
    }
}
