import CryptoKit
import Foundation

/// AWS Signature Version 4 query-string signing ("presigned URLs"), which R2 accepts.
///
/// A presigned URL carries its own signature, so iOS can send a background upload long after the
/// app has stopped running, without asking the app to sign anything. The body isn't signed
/// (`UNSIGNED-PAYLOAD`), so a large photo never has to be hashed or held in memory to sign it;
/// R2's ETag confirms what arrived instead.
enum S3Signer {
    struct Credentials: Sendable {
        var accessKeyID: String
        var secretAccessKey: String
    }

    /// - Parameters:
    ///   - path: The object's path, starting with `/`, before percent-encoding.
    ///   - headers: Headers the request must send exactly as given. `host` is always signed.
    ///   - expires: Seconds the URL stays valid. S3 allows at most 7 days.
    static func presignedURL(
        method: String,
        host: String,
        path: String,
        headers: [String: String] = [:],
        credentials: Credentials,
        region: String,
        service: String = "s3",
        date: Date,
        expires: Int
    ) -> URL {
        let amzDate = timestamp(date, format: "yyyyMMdd'T'HHmmss'Z'")
        let day = String(amzDate.prefix(8))
        let scope = "\(day)/\(region)/\(service)/aws4_request"

        var signed = Dictionary(uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value.trimmingCharacters(in: .whitespaces)) })
        signed["host"] = host
        let names = signed.keys.sorted()
        let signedHeaders = names.joined(separator: ";")

        let query = [
            ("X-Amz-Algorithm", "AWS4-HMAC-SHA256"),
            ("X-Amz-Credential", "\(credentials.accessKeyID)/\(scope)"),
            ("X-Amz-Date", amzDate),
            ("X-Amz-Expires", String(expires)),
            ("X-Amz-SignedHeaders", signedHeaders),
        ]
        .map { (encode($0.0), encode($0.1)) }
        .sorted { $0.0 < $1.0 }
        .map { "\($0.0)=\($0.1)" }
        .joined(separator: "&")

        let encodedPath = path.split(separator: "/", omittingEmptySubsequences: false)
            .map { encode(String($0)) }
            .joined(separator: "/")

        let canonicalRequest = [
            method,
            encodedPath,
            query,
            names.map { "\($0):\(signed[$0]!)\n" }.joined(),
            signedHeaders,
            "UNSIGNED-PAYLOAD",
        ].joined(separator: "\n")

        let stringToSign = [
            "AWS4-HMAC-SHA256",
            amzDate,
            scope,
            hex(SHA256.hash(data: Data(canonicalRequest.utf8))),
        ].joined(separator: "\n")

        var key = SymmetricKey(data: Data("AWS4\(credentials.secretAccessKey)".utf8))
        for part in [day, region, service, "aws4_request"] {
            key = SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: Data(part.utf8), using: key)))
        }
        let signature = hex(HMAC<SHA256>.authenticationCode(for: Data(stringToSign.utf8), using: key))

        return URL(string: "https://\(host)\(encodedPath)?\(query)&X-Amz-Signature=\(signature)")!
    }

    /// Percent-encodes everything except the characters S3 leaves alone.
    static func encode(_ value: String) -> String {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")
        return value.addingPercentEncoding(withAllowedCharacters: unreserved)!
    }

    private static func timestamp(_ date: Date, format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = format
        return formatter.string(from: date)
    }

    private static func hex<D: Sequence>(_ bytes: D) -> String where D.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
