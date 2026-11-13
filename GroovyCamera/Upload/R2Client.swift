import Foundation

/// What the app needs to reach the owner's R2 bucket. Entered in Settings and kept in the
/// Keychain. Never logged, and never built into the app.
struct R2Credentials: Codable, Equatable, Sendable {
    var accountID = ""
    var bucket = ""
    var accessKeyID = ""
    var secretAccessKey = ""

    var isComplete: Bool {
        ![accountID, bucket, accessKeyID, secretAccessKey].contains { $0.trimmingCharacters(in: .whitespaces).isEmpty }
    }
}

/// Builds signed requests for R2's S3-compatible API. The app only ever writes under `records/`,
/// plus the spreadsheet, `photos.csv`, at the bucket's root.
struct R2Client: Sendable {
    let credentials: R2Credentials

    static let prefix = "records/"
    /// The most S3 allows, so a photo can wait out a long offline stretch.
    static let urlLifetime = 7 * 24 * 60 * 60
    /// Signed into every photo upload, so photos display in a browser rather than download. A day
    /// rather than forever, so a photo replaced by hand in R2 shows the new version within a day.
    static let photoHeaders = [
        "Content-Type": "image/jpeg",
        "Cache-Control": "public, max-age=86400",
    ]

    /// Where a record's photo goes, such as `records/2026-11-07-143205/2026-11-07-143205-01-front.jpg`.
    static func key(folder: String, slot: Slot) -> String {
        "\(prefix)\(folder)/\(RecordFolder.fileName(folder: folder, slot: slot))"
    }

    /// A signed upload of one photo, with the headers it was signed with. Nil for a key outside
    /// `records/`.
    func photoUpload(key: String, date: Date = Date()) -> URLRequest? {
        request(method: "PUT", key: key, headers: Self.photoHeaders, date: date)
    }

    func request(method: String, key: String, headers: [String: String] = [:], date: Date = Date()) -> URLRequest? {
        guard Self.isAllowed(key) else { return nil }
        let account = credentials.accountID.trimmingCharacters(in: .whitespaces)
        let bucket = credentials.bucket.trimmingCharacters(in: .whitespaces)
        let url = S3Signer.presignedURL(
            method: method,
            host: "\(account).r2.cloudflarestorage.com",
            path: "/\(bucket)/\(key)",
            headers: headers,
            credentials: S3Signer.Credentials(
                accessKeyID: credentials.accessKeyID.trimmingCharacters(in: .whitespaces),
                secretAccessKey: credentials.secretAccessKey.trimmingCharacters(in: .whitespaces)
            ),
            region: "auto",
            date: date,
            expires: Self.urlLifetime
        )
        var request = URLRequest(url: url)
        request.httpMethod = method
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        return request
    }

    static func isAllowed(_ key: String) -> Bool {
        if key == PhotoIndex.key { return true }
        return key.hasPrefix(prefix) && !key.split(separator: "/").contains("..") && key.count > prefix.count
    }

    /// Uploads and deletes a small file under `records/`, so Settings can show whether the bucket
    /// and token work before any photos depend on them.
    func checkConnection() async -> String? {
        let key = "\(Self.prefix)connection-check.txt"
        guard let put = request(method: "PUT", key: key, headers: ["Content-Type": "text/plain"]),
              let delete = request(method: "DELETE", key: key) else { return "Couldn't build a request." }
        do {
            let (_, putResponse) = try await URLSession.shared.upload(for: put, from: Data("ok".utf8))
            if let problem = Self.problem(putResponse, action: "Uploading") { return problem }
            let (_, deleteResponse) = try await URLSession.shared.data(for: delete)
            return Self.problem(deleteResponse, action: "Deleting")
        } catch {
            return "Couldn't reach R2: \(error.localizedDescription)"
        }
    }

    /// Says what went wrong without repeating the URL, which carries a signature.
    private static func problem(_ response: URLResponse, action: String) -> String? {
        guard let status = (response as? HTTPURLResponse)?.statusCode else { return "\(action) got no response." }
        switch status {
        case 200..<300: return nil
        case 403: return "\(action) was refused (403). Check the access key, secret and that the token covers this bucket with object read and write."
        case 404: return "\(action) failed (404). Check the account ID and bucket name."
        default: return "\(action) failed with HTTP \(status)."
        }
    }
}
